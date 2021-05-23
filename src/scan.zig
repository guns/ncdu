const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
usingnamespace @import("util.zig");
const c_statfs = @cImport(@cInclude("sys/vfs.h"));
const c_fnmatch = @cImport(@cInclude("fnmatch.h"));


// Concise stat struct for fields we're interested in, with the types used by the model.
const Stat = struct {
    blocks: u61,
    size: u64,
    dev: u64,
    ino: u64,
    nlink: u32,
    dir: bool,
    reg: bool,
    symlink: bool,
    ext: model.Ext,

    fn clamp(comptime T: type, comptime field: anytype, x: anytype) std.meta.fieldInfo(T, field).field_type {
        return castClamp(std.meta.fieldInfo(T, field).field_type, x);
    }

    fn truncate(comptime T: type, comptime field: anytype, x: anytype) std.meta.fieldInfo(T, field).field_type {
        return castTruncate(std.meta.fieldInfo(T, field).field_type, x);
    }

    fn read(parent: std.fs.Dir, name: [:0]const u8, follow: bool) !Stat {
        const stat = try std.os.fstatatZ(parent.fd, name, if (follow) 0 else std.os.AT_SYMLINK_NOFOLLOW);
        return Stat{
            .blocks = clamp(Stat, .blocks, stat.blocks),
            .size = clamp(Stat, .size, stat.size),
            .dev = truncate(Stat, .dev, stat.dev),
            .ino = truncate(Stat, .ino, stat.ino),
            .nlink = clamp(Stat, .nlink, stat.nlink),
            .dir = std.os.system.S_ISDIR(stat.mode),
            .reg = std.os.system.S_ISREG(stat.mode),
            .symlink = std.os.system.S_ISLNK(stat.mode),
            .ext = .{
                .mtime = clamp(model.Ext, .mtime, stat.mtime().tv_sec),
                .uid = truncate(model.Ext, .uid, stat.uid),
                .gid = truncate(model.Ext, .gid, stat.gid),
                .mode = truncate(model.Ext, .mode, stat.mode),
            },
        };
    }
};

var kernfs_cache: std.AutoHashMap(u64,bool) = std.AutoHashMap(u64,bool).init(main.allocator);

// This function only works on Linux
fn isKernfs(dir: std.fs.Dir, dev: u64) bool {
    if (kernfs_cache.get(dev)) |e| return e;
    var buf: c_statfs.struct_statfs = undefined;
    if (c_statfs.fstatfs(dir.fd, &buf) != 0) return false; // silently ignoring errors isn't too nice.
    const iskern = switch (buf.f_type) {
        // These numbers are documented in the Linux 'statfs(2)' man page, so I assume they're stable.
        0x42494e4d, // BINFMTFS_MAGIC
        0xcafe4a11, // BPF_FS_MAGIC
        0x27e0eb, // CGROUP_SUPER_MAGIC
        0x63677270, // CGROUP2_SUPER_MAGIC
        0x64626720, // DEBUGFS_MAGIC
        0x1cd1, // DEVPTS_SUPER_MAGIC
        0x9fa0, // PROC_SUPER_MAGIC
        0x6165676c, // PSTOREFS_MAGIC
        0x73636673, // SECURITYFS_MAGIC
        0xf97cff8c, // SELINUX_MAGIC
        0x62656572, // SYSFS_MAGIC
        0x74726163 // TRACEFS_MAGIC
        => true,
        else => false,
    };
    kernfs_cache.put(dev, iskern) catch {};
    return iskern;
}

// Output a JSON string.
// Could use std.json.stringify(), but that implementation is "correct" in that
// it refuses to encode non-UTF8 slices as strings. Ncdu dumps aren't valid
// JSON if we have non-UTF8 filenames, such is life...
fn writeJsonString(wr: anytype, s: []const u8) !void {
    try wr.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '\n' => try wr.writeAll("\\n"),
            '\r' => try wr.writeAll("\\r"),
            0x8  => try wr.writeAll("\\b"),
            '\t' => try wr.writeAll("\\t"),
            0xC  => try wr.writeAll("\\f"),
            '\\' => try wr.writeAll("\\\\"),
            '"'  => try wr.writeAll("\\\""),
            0...7, 0xB, 0xE...0x1F, 127 => try wr.print("\\u00{x:02}", .{ch}),
            else => try wr.writeByte(ch)
        }
    }
    try wr.writeByte('"');
}

// Scan/import context. Entries are added in roughly the following way:
//
//   ctx.pushPath(name)
//   ctx.stat = ..;
//   ctx.addSpecial() or ctx.addStat()
//   if (is_dir) {
//      // ctx.enterDir() is implicit in ctx.addStat() for directory entries.
//      // repeat top-level steps for files in dir, recursively.
//      ctx.leaveDir();
//   }
//   ctx.popPath();
//
// (Multithreaded scanning note: when scanning to RAM, we can support multiple
// of these Contexts in parallel, just need to make sure to lock any access to
// model.* related functions. Parallel scanning to a file will require major
// changes to the export format or buffering with specially guided scanning to
// avoid buffering /everything/... neither seems fun)
const Context = struct {
    // When scanning to RAM
    parents: ?*model.Parents = null,
    // When scanning to a file
    wr: ?std.io.BufferedWriter(4096, std.fs.File.Writer).Writer = null,

    path: std.ArrayList(u8) = std.ArrayList(u8).init(main.allocator),
    path_indices: std.ArrayList(usize) = std.ArrayList(usize).init(main.allocator),
    items_seen: u32 = 1,

    // 0-terminated name of the top entry, points into 'path', invalid after popPath().
    // This is a workaround to Zig's directory iterator not returning a [:0]const u8.
    name: [:0]const u8 = undefined,

    last_error: ?[:0]u8 = null,

    stat: Stat = undefined,

    const Self = @This();

    // Add the name of the file/dir entry we're currently inspecting
    fn pushPath(self: *Self, name: []const u8) !void {
        try self.path_indices.append(self.path.items.len);
        if (self.path.items.len > 1) try self.path.append('/');
        const start = self.path.items.len;
        try self.path.appendSlice(name);

        try self.path.append(0);
        self.name = self.path.items[start..self.path.items.len-1:0];
        self.path.items.len -= 1;

        self.items_seen += 1;
        self.stat.dir = false; // used by addSpecial(); if we've failed to stat() then don't consider it a dir.
    }

    fn popPath(self: *Self) void {
        self.path.items.len = self.path_indices.items[self.path_indices.items.len-1];
        self.path_indices.items.len -= 1;
    }

    fn pathZ(self: *Self) [:0]const u8 {
        return arrayListBufZ(&self.path) catch unreachable;
    }

    // Set a flag to indicate that there was an error listing file entries in the current directory.
    // (Such errors are silently ignored when exporting to a file, as the directory metadata has already been written)
    fn setDirlistError(self: *Self) void {
        if (self.parents) |p| p.top().entry.set_err(p);
    }

    const Special = enum { err, other_fs, kernfs, excluded };

    // Insert the current path as a special entry (i.e. a file/dir that is not counted)
    fn addSpecial(self: *Self, t: Special) !void {
        if (t == .err) {
            if (self.last_error) |p| main.allocator.free(p);
            self.last_error = try main.allocator.dupeZ(u8, self.path.items);
        }

        if (self.parents) |p| {
            var e = try model.Entry.create(.file, false, self.name);
            e.insert(p) catch unreachable;
            var f = e.file().?;
            switch (t) {
                .err => e.set_err(p),
                .other_fs => f.other_fs = true,
                .kernfs => f.kernfs = true,
                .excluded => f.excluded = true,
            }
        }

        if (self.wr) |w| {
            try w.writeAll(",\n");
            if (self.stat.dir) try w.writeByte('[');
            try w.writeAll("{\"name\":");
            try writeJsonString(w, self.name);
            switch (t) {
                .err => try w.writeAll(",\"read_error\":true"),
                .other_fs => try w.writeAll(",\"excluded\":\"othfs\""),
                .kernfs => try w.writeAll(",\"excluded\":\"kernfs\""),
                .excluded => try w.writeAll(",\"excluded\":\"pattern\""),
            }
            try w.writeByte('}');
            if (self.stat.dir) try w.writeByte(']');
        }
    }

    // Insert current path as a counted file/dir/hardlink, with information from self.stat
    fn addStat(self: *Self, dir_dev: u64) !void {
        if (self.parents) |p| {
            const etype = if (self.stat.dir) model.EType.dir
                          else if (self.stat.nlink > 1) model.EType.link
                          else model.EType.file;
            var e = try model.Entry.create(etype, main.config.extended, self.name);
            e.blocks = self.stat.blocks;
            e.size = self.stat.size;
            if (e.dir()) |d| d.dev = try model.getDevId(self.stat.dev);
            if (e.file()) |f| f.notreg = !self.stat.dir and !self.stat.reg;
            if (e.link()) |l| {
                l.ino = self.stat.ino;
                l.nlink = self.stat.nlink;
            }
            if (e.ext()) |ext| ext.* = self.stat.ext;
            try e.insert(p);

            if (e.dir()) |d| try p.push(d); // Enter the directory
        }

        if (self.wr) |w| {
            try w.writeAll(",\n");
            if (self.stat.dir) try w.writeByte('[');
            try w.writeAll("{\"name\":");
            try writeJsonString(w, self.name);
            if (self.stat.size > 0) try w.print(",\"asize\":{d}", .{ self.stat.size });
            if (self.stat.blocks > 0) try w.print(",\"dsize\":{d}", .{ blocksToSize(self.stat.blocks) });
            if (self.stat.dir and self.stat.dev != dir_dev) try w.print(",\"dev\":{d}", .{ self.stat.dev });
            if (!self.stat.dir and self.stat.nlink > 1) try w.print(",\"ino\":{d},\"hlnkc\":true,\"nlink\":{d}", .{ self.stat.ino, self.stat.nlink });
            if (!self.stat.dir and !self.stat.reg) try w.writeAll(",\"notreg\":true");
            if (main.config.extended)
                try w.print(",\"uid\":{d},\"gid\":{d},\"mode\":{d},\"mtime\":{d}",
                    .{ self.stat.ext.uid, self.stat.ext.gid, self.stat.ext.mode, self.stat.ext.mtime });
            try w.writeByte('}');
        }
    }

    fn leaveDir(self: *Self) !void {
        if (self.parents) |p| p.pop();
        if (self.wr) |w| try w.writeByte(']');
    }

    fn deinit(self: *Self) void {
        if (self.last_error) |p| main.allocator.free(p);
        if (self.parents) |p| p.deinit();
        self.path.deinit();
        self.path_indices.deinit();
    }
};

// Context that is currently being used for scanning.
var active_context: ?*Context = null;

// Read and index entries of the given dir.
// (TODO: shouldn't error on OOM but instead call a function that waits or something)
fn scanDir(ctx: *Context, dir: std.fs.Dir, dir_dev: u64) (std.fs.File.Writer.Error || std.mem.Allocator.Error)!void {
    var it = dir.iterate();
    while(true) {
        const entry = it.next() catch {
            ctx.setDirlistError();
            return;
        } orelse break;

        try ctx.pushPath(entry.name);
        defer ctx.popPath();
        try main.handleEvent(false, false);

        // XXX: This algorithm is extremely slow, can be optimized with some clever pattern parsing.
        const excluded = blk: {
            for (main.config.exclude_patterns.items) |pat| {
                var path = ctx.pathZ();
                while (path.len > 0) {
                    if (c_fnmatch.fnmatch(pat, path, 0) == 0) break :blk true;
                    if (std.mem.indexOfScalar(u8, path, '/')) |idx| path = path[idx+1..:0]
                    else break;
                }
            }
            break :blk false;
        };
        if (excluded) {
            try ctx.addSpecial(.excluded);
            continue;
        }

        ctx.stat = Stat.read(dir, ctx.name, false) catch {
            try ctx.addSpecial(.err);
            continue;
        };

        if (main.config.same_fs and ctx.stat.dev != dir_dev) {
            try ctx.addSpecial(.other_fs);
            continue;
        }

        if (main.config.follow_symlinks and ctx.stat.symlink) {
            if (Stat.read(dir, ctx.name, true)) |nstat| {
                if (!nstat.dir) {
                    ctx.stat = nstat;
                    // Symlink targets may reside on different filesystems,
                    // this will break hardlink detection and counting so let's disable it.
                    if (ctx.stat.nlink > 1 and ctx.stat.dev != dir_dev)
                        ctx.stat.nlink = 1;
                }
            } else |_| {}
        }

        var edir =
            if (ctx.stat.dir) dir.openDirZ(ctx.name, .{ .access_sub_paths = true, .iterate = true, .no_follow = true }) catch {
                try ctx.addSpecial(.err);
                continue;
            } else null;
        defer if (edir != null) edir.?.close();

        if (std.builtin.os.tag == .linux and main.config.exclude_kernfs and ctx.stat.dir and isKernfs(edir.?, ctx.stat.dev)) {
            try ctx.addSpecial(.kernfs);
            continue;
        }

        if (main.config.exclude_caches and ctx.stat.dir) {
            if (edir.?.openFileZ("CACHEDIR.TAG", .{})) |f| {
                const sig = "Signature: 8a477f597d28d172789f06886806bc55";
                var buf: [sig.len]u8 = undefined;
                if (f.reader().readAll(&buf)) |len| {
                    if (len == sig.len and std.mem.eql(u8, &buf, sig)) {
                        try ctx.addSpecial(.excluded);
                        continue;
                    }
                } else |_| {}
            } else |_| {}
        }

        try ctx.addStat(dir_dev);

        if (ctx.stat.dir) {
            try scanDir(ctx, edir.?, ctx.stat.dev);
            try ctx.leaveDir();
        }
    }
}

pub fn scanRoot(path: []const u8, out: ?std.fs.File) !void {
    const full_path = std.fs.realpathAlloc(main.allocator, path) catch path;
    defer main.allocator.free(full_path);

    var ctx = Context{};
    defer ctx.deinit();
    try ctx.pushPath(full_path);
    active_context = &ctx;
    defer active_context = null;

    ctx.stat = try Stat.read(std.fs.cwd(), ctx.pathZ(), true);
    if (!ctx.stat.dir) return error.NotADirectory;

    var parents = model.Parents{};
    var buf = if (out) |f| std.io.bufferedWriter(f.writer()) else undefined;

    if (out) |f| {
        ctx.wr = buf.writer();
        try ctx.wr.?.writeAll("[1,2,{\"progname\":\"ncdu\",\"progver\":\"" ++ main.program_version ++ "\",\"timestamp\":");
        try ctx.wr.?.print("{d}", .{std.time.timestamp()});
        try ctx.wr.?.writeByte('}');
        try ctx.addStat(0);

    } else {
        ctx.parents = &parents;
        model.root = (try model.Entry.create(.dir, false, full_path)).dir().?;
        model.root.entry.blocks = ctx.stat.blocks;
        model.root.entry.size = ctx.stat.size;
        model.root.dev = try model.getDevId(ctx.stat.dev);
        if (model.root.entry.ext()) |ext| ext.* = ctx.stat.ext;
    }

    var dir = try std.fs.cwd().openDirZ(ctx.pathZ(), .{ .access_sub_paths = true, .iterate = true });
    defer dir.close();
    try scanDir(&ctx, dir, ctx.stat.dev);
    if (out != null) {
        try ctx.leaveDir();
        try ctx.wr.?.writeByte(']');
        try buf.flush();
    }
}

var animation_pos: u32 = 0;
var need_confirm_quit = false;

fn drawBox() !void {
    ui.init();
    const ctx = active_context.?;
    const width = saturateSub(ui.cols, 5);
    const box = ui.Box.create(10, width, "Scanning...");
    box.move(2, 2);
    ui.addstr("Total items: ");
    ui.addnum(.default, ctx.items_seen);

    if (width > 48 and ctx.parents != null) {
        box.move(2, 30);
        ui.addstr("size: ");
        ui.addsize(.default, blocksToSize(model.root.entry.blocks));
    }

    box.move(3, 2);
    ui.addstr("Current item: ");
    ui.addstr(try ui.shorten(try ui.toUtf8(ctx.pathZ()), saturateSub(width, 18)));

    if (ctx.last_error) |path| {
        box.move(5, 2);
        ui.style(.bold);
        ui.addstr("Warning: ");
        ui.style(.default);
        ui.addstr("error scanning ");
        ui.addstr(try ui.shorten(try ui.toUtf8(path), saturateSub(width, 28)));
        box.move(6, 3);
        ui.addstr("some directory sizes may not be correct.");
    }

    if (need_confirm_quit) {
        box.move(8, saturateSub(width, 20));
        ui.addstr("Press ");
        ui.style(.key);
        ui.addch('y');
        ui.style(.default);
        ui.addstr(" to confirm");
    } else {
        box.move(8, saturateSub(width, 18));
        ui.addstr("Press ");
        ui.style(.key);
        ui.addch('q');
        ui.style(.default);
        ui.addstr(" to abort");
    }

    if (main.config.update_delay < std.time.ns_per_s and width > 40) {
        const txt = "Scanning...";
        animation_pos += 1;
        if (animation_pos >= txt.len*2) animation_pos = 0;
        if (animation_pos < txt.len) {
            var i: u32 = 0;
            box.move(8, 2);
            while (i <= animation_pos) : (i += 1) ui.addch(txt[i]);
        } else {
            var i: u32 = txt.len-1;
            while (i > animation_pos-txt.len) : (i -= 1) {
                box.move(8, 2+i);
                ui.addch(txt[i]);
            }
        }
    }
}

pub fn draw() !void {
    switch (main.config.scan_ui) {
        .none => {},
        .line => {
            var buf: [256]u8 = undefined;
            var line: []const u8 = undefined;
            if (active_context.?.parents == null) {
                line = std.fmt.bufPrint(&buf, "\x1b7\x1b[J{s: <63} {d:>9} files\x1b8",
                    .{ ui.shorten(active_context.?.pathZ(), 63), active_context.?.items_seen }
                ) catch return;
            } else {
                const r = ui.FmtSize.fmt(blocksToSize(model.root.entry.blocks));
                line = std.fmt.bufPrint(&buf, "\x1b7\x1b[J{s: <51} {d:>9} files / {s}{s}\x1b8",
                    .{ ui.shorten(active_context.?.pathZ(), 51), active_context.?.items_seen, r.num(), r.unit }
                ) catch return;
            }
            _ = std.io.getStdErr().write(line) catch {};
        },
        .full => try drawBox(),
    }
}

pub fn key(ch: i32) !void {
    if (need_confirm_quit) {
        switch (ch) {
            'y', 'Y' => if (need_confirm_quit) ui.quit(),
            else => need_confirm_quit = false,
        }
        return;
    }
    switch (ch) {
        'q' => if (main.config.confirm_quit) { need_confirm_quit = true; } else ui.quit(),
        else => need_confirm_quit = false,
    }
}
