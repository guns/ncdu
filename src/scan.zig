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

    // Cast any integer type to the target type, clamping the value to the supported maximum if necessary.
    fn castClamp(comptime T: type, x: anytype) T {
        // (adapted from std.math.cast)
        if (std.math.maxInt(@TypeOf(x)) > std.math.maxInt(T) and x > std.math.maxInt(T)) {
            return std.math.maxInt(T);
        } else if (std.math.minInt(@TypeOf(x)) < std.math.minInt(T) and x < std.math.minInt(T)) {
            return std.math.minInt(T);
        } else {
            return @intCast(T, x);
        }
    }

    // Cast any integer type to the target type, truncating if necessary.
    fn castTruncate(comptime T: type, x: anytype) T {
        const Ti = @typeInfo(T).Int;
        const Xi = @typeInfo(@TypeOf(x)).Int;
        const nx = if (Xi.signedness != Ti.signedness) @bitCast(std.meta.Int(Ti.signedness, Xi.bits), x) else x;
        return if (Xi.bits > Ti.bits) @truncate(T, nx) else nx;
    }

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

const Context = struct {
    parents: model.Parents = .{},
    path: std.ArrayList(u8) = std.ArrayList(u8).init(main.allocator),
    path_indices: std.ArrayList(usize) = std.ArrayList(usize).init(main.allocator),
    items_seen: u32 = 1,

    // 0-terminated name of the top entry, points into 'path', invalid after popPath().
    // This is a workaround to Zig's directory iterator not returning a [:0]const u8.
    name: [:0]const u8 = undefined,

    last_error: ?[:0]u8 = null,

    const Self = @This();

    fn pushPath(self: *Self, name: []const u8) !void {
        try self.path_indices.append(self.path.items.len);
        if (self.path.items.len > 1) try self.path.append('/');
        const start = self.path.items.len;
        try self.path.appendSlice(name);

        try self.path.append(0);
        self.name = self.path.items[start..self.path.items.len-1:0];
        self.path.items.len -= 1;
    }

    fn popPath(self: *Self) void {
        self.path.items.len = self.path_indices.items[self.path_indices.items.len-1];
        self.path_indices.items.len -= 1;
    }

    fn pathZ(self: *Self) [:0]const u8 {
        self.path.append(0) catch unreachable;
        defer self.path.items.len -= 1;
        return self.path.items[0..self.path.items.len-1:0];
    }

    // Insert the current path as an error entry
    fn setError(self: *Self) !void {
        var e = try model.Entry.create(.file, false, self.name);
        e.insert(&self.parents) catch unreachable;
        e.set_err(&self.parents);

        if (self.last_error) |p| main.allocator.free(p);
        self.last_error = try main.allocator.dupeZ(u8, self.path.items);
    }
};

// Context that is currently being used for scanning.
var active_context: ?*Context = null;

// Read and index entries of the given dir. The entry for the directory is already assumed to be in 'ctx.parents'.
// (TODO: shouldn't error on OOM but instead call a function that waits or something)
fn scanDir(ctx: *Context, dir: std.fs.Dir) std.mem.Allocator.Error!void {
    var it = dir.iterate();
    while(true) {
        const entry = it.next() catch {
            ctx.parents.top().entry.set_err(&ctx.parents);
            return;
        } orelse break;
        ctx.items_seen += 1;

        try ctx.pushPath(entry.name);
        try main.handleEvent(false, false);
        defer ctx.popPath();

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
            var e = try model.Entry.create(.file, false, entry.name);
            e.file().?.excluded = true;
            e.insert(&ctx.parents) catch unreachable;
            continue;
        }

        var stat = Stat.read(dir, ctx.name, false) catch {
            try ctx.setError();
            continue;
        };

        if (main.config.same_fs and stat.dev != model.getDev(ctx.parents.top().dev)) {
            try ctx.setError();
            continue;
        }

        if (main.config.follow_symlinks and stat.symlink) {
            if (Stat.read(dir, ctx.name, true)) |nstat| {
                if (!nstat.dir) {
                    stat = nstat;
                    // Symlink targets may reside on different filesystems,
                    // this will break hardlink detection and counting so let's disable it.
                    if (stat.nlink > 1 and stat.dev != model.getDev(ctx.parents.top().dev))
                        stat.nlink = 1;
                }
            } else |_| {}
        }

        var edir =
            if (stat.dir) dir.openDirZ(ctx.name, .{ .access_sub_paths = true, .iterate = true, .no_follow = true }) catch {
                try ctx.setError();
                continue;
            } else null;
        defer if (edir != null) edir.?.close();

        if (std.builtin.os.tag == .linux and main.config.exclude_kernfs and stat.dir and isKernfs(edir.?, stat.dev)) {
            var e = try model.Entry.create(.file, false, entry.name);
            e.file().?.kernfs = true;
            e.insert(&ctx.parents) catch unreachable;
            continue;
        }

        if (main.config.exclude_caches and stat.dir) {
            if (edir.?.openFileZ("CACHEDIR.TAG", .{})) |f| {
                const sig = "Signature: 8a477f597d28d172789f06886806bc55";
                var buf: [sig.len]u8 = undefined;
                if (f.reader().readAll(&buf)) |len| {
                    if (len == sig.len and std.mem.eql(u8, &buf, sig)) {
                        var e = try model.Entry.create(.file, false, entry.name);
                        e.file().?.excluded = true;
                        e.insert(&ctx.parents) catch unreachable;
                        continue;
                    }
                } else |_| {}
            } else |_| {}
        }

        const etype = if (stat.dir) model.EType.dir else if (stat.nlink > 1) model.EType.link else model.EType.file;
        var e = try model.Entry.create(etype, main.config.extended, entry.name);
        e.blocks = stat.blocks;
        e.size = stat.size;
        if (e.dir()) |d| d.dev = try model.getDevId(stat.dev);
        if (e.file()) |f| f.notreg = !stat.dir and !stat.reg;
        if (e.link()) |l| {
            l.ino = stat.ino;
            l.nlink = stat.nlink;
        }
        if (e.ext()) |ext| ext.* = stat.ext;
        try e.insert(&ctx.parents);

        if (e.dir()) |d| {
            try ctx.parents.push(d);
            try scanDir(ctx, edir.?);
            ctx.parents.pop();
        }
    }
}

pub fn scanRoot(path: []const u8) !void {
    const full_path = std.fs.realpathAlloc(main.allocator, path) catch path;
    model.root = (try model.Entry.create(.dir, false, full_path)).dir().?;

    const stat = try Stat.read(std.fs.cwd(), model.root.entry.name(), true);
    if (!stat.dir) return error.NotADirectory;
    model.root.entry.blocks = stat.blocks;
    model.root.entry.size = stat.size;
    model.root.dev = try model.getDevId(stat.dev);
    if (model.root.entry.ext()) |ext| ext.* = stat.ext;

    var ctx = Context{};
    try ctx.pushPath(full_path);
    const dir = try std.fs.cwd().openDirZ(model.root.entry.name(), .{ .access_sub_paths = true, .iterate = true });

    active_context = &ctx;
    defer active_context = null;
    try scanDir(&ctx, dir);
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

    if (width > 48 and true) { // TODO: When not exporting to file
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
            if (false) { // TODO: When exporting to file; no total size known
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
