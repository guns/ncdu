const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
usingnamespace @import("util.zig");
const c_statfs = @cImport(@cInclude("sys/vfs.h"));
const c_fnmatch = @cImport(@cInclude("fnmatch.h"));


// Concise stat struct for fields we're interested in, with the types used by the model.
const Stat = struct {
    blocks: u61 = 0,
    size: u64 = 0,
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u32 = 0,
    hlinkc: bool = false,
    dir: bool = false,
    reg: bool = true,
    symlink: bool = false,
    ext: model.Ext = .{},

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
            .hlinkc = stat.nlink > 1 and !std.os.system.S_ISDIR(stat.mode),
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
//   if (ctx.stat.dir) {
//      // repeat top-level steps for files in dir, recursively.
//   }
//   ctx.popPath();
//
const Context = struct {
    // When scanning to RAM
    parents: ?model.Parents = null,
    // When scanning to a file
    wr: ?*Writer = null,

    path: std.ArrayList(u8) = std.ArrayList(u8).init(main.allocator),
    path_indices: std.ArrayList(usize) = std.ArrayList(usize).init(main.allocator),
    items_seen: u32 = 0,

    // 0-terminated name of the top entry, points into 'path', invalid after popPath().
    // This is a workaround to Zig's directory iterator not returning a [:0]const u8.
    name: [:0]const u8 = undefined,

    last_error: ?[:0]u8 = null,

    stat: Stat = undefined,

    const Writer = std.io.BufferedWriter(4096, std.fs.File.Writer);
    const Self = @This();

    fn initFile(out: std.fs.File) !Self {
        var buf = try main.allocator.create(Writer);
        errdefer main.allocator.destroy(buf);
        buf.* = std.io.bufferedWriter(out.writer());
        var wr = buf.writer();
        try wr.writeAll("[1,2,{\"progname\":\"ncdu\",\"progver\":\"" ++ main.program_version ++ "\",\"timestamp\":");
        try wr.print("{d}", .{std.time.timestamp()});
        try wr.writeByte('}');
        return Self{ .wr = buf };
    }

    fn initMem() Self {
        return Self{ .parents = model.Parents{} };
    }

    fn final(self: *Self) !void {
        if (self.wr) |wr| {
            try wr.writer().writeByte(']');
            try wr.flush();
        }
    }

    // Add the name of the file/dir entry we're currently inspecting
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

        if (self.stat.dir) {
            if (self.parents) |*p| if (p.top() != model.root) p.pop();
            if (self.wr) |w| w.writer().writeByte(']') catch ui.die("Error writing to file.", .{});
        } else
            self.stat.dir = true; // repeated popPath()s mean we're closing parent dirs.
    }

    fn pathZ(self: *Self) [:0]const u8 {
        return arrayListBufZ(&self.path) catch unreachable;
    }

    // Set a flag to indicate that there was an error listing file entries in the current directory.
    // (Such errors are silently ignored when exporting to a file, as the directory metadata has already been written)
    fn setDirlistError(self: *Self) void {
        if (self.parents) |*p| p.top().entry.set_err(p);
    }

    const Special = enum { err, other_fs, kernfs, excluded };

    // Insert the current path as a special entry (i.e. a file/dir that is not counted)
    // Ignores self.stat except for the 'dir' option.
    fn addSpecial(self: *Self, t: Special) !void {
        std.debug.assert(self.items_seen > 0); // root item can't be a special

        if (t == .err) {
            if (self.last_error) |p| main.allocator.free(p);
            self.last_error = try main.allocator.dupeZ(u8, self.path.items);
        }

        if (self.parents) |*p| {
            var e = try model.Entry.create(.file, false, self.name);
            e.insert(p) catch unreachable;
            var f = e.file().?;
            switch (t) {
                .err => e.set_err(p),
                .other_fs => f.other_fs = true,
                .kernfs => f.kernfs = true,
                .excluded => f.excluded = true,
            }

        } else if (self.wr) |wr| {
            var w = wr.writer();
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
        self.items_seen += 1;
    }

    // Insert current path as a counted file/dir/hardlink, with information from self.stat
    fn addStat(self: *Self, dir_dev: u64) !void {
        if (self.parents) |*p| {
            const etype = if (self.stat.dir) model.EType.dir
                          else if (self.stat.hlinkc) model.EType.link
                          else model.EType.file;
            var e = try model.Entry.create(etype, main.config.extended, self.name);
            e.blocks = self.stat.blocks;
            e.size = self.stat.size;
            if (e.dir()) |d| d.dev = try model.getDevId(self.stat.dev);
            if (e.file()) |f| f.notreg = !self.stat.dir and !self.stat.reg;
            // TODO: Handle the scenario where we don't know the hard link count
            // (i.e. on imports from old ncdu versions that don't have the "nlink" field)
            if (e.link()) |l| {
                l.ino = self.stat.ino;
                l.nlink = self.stat.nlink;
            }
            if (e.ext()) |ext| ext.* = self.stat.ext;

            if (self.items_seen == 0)
                model.root = e.dir().?
            else {
                try e.insert(p);
                if (e.dir()) |d| try p.push(d); // Enter the directory
            }

        } else if (self.wr) |wr| {
            var w = wr.writer();
            try w.writeAll(",\n");
            if (self.stat.dir) try w.writeByte('[');
            try w.writeAll("{\"name\":");
            try writeJsonString(w, self.name);
            if (self.stat.size > 0) try w.print(",\"asize\":{d}", .{ self.stat.size });
            if (self.stat.blocks > 0) try w.print(",\"dsize\":{d}", .{ blocksToSize(self.stat.blocks) });
            if (self.stat.dir and self.stat.dev != dir_dev) try w.print(",\"dev\":{d}", .{ self.stat.dev });
            if (self.stat.hlinkc) try w.print(",\"ino\":{d},\"hlnkc\":true,\"nlink\":{d}", .{ self.stat.ino, self.stat.nlink });
            if (!self.stat.dir and !self.stat.reg) try w.writeAll(",\"notreg\":true");
            if (main.config.extended)
                try w.print(",\"uid\":{d},\"gid\":{d},\"mode\":{d},\"mtime\":{d}",
                    .{ self.stat.ext.uid, self.stat.ext.gid, self.stat.ext.mode, self.stat.ext.mtime });
            try w.writeByte('}');
        }

        self.items_seen += 1;
    }

    fn deinit(self: *Self) void {
        if (self.last_error) |p| main.allocator.free(p);
        if (self.parents) |*p| p.deinit();
        if (self.wr) |p| main.allocator.destroy(p);
        self.path.deinit();
        self.path_indices.deinit();
    }
};

// Context that is currently being used for scanning.
var active_context: ?*Context = null;

// Read and index entries of the given dir.
// (TODO: shouldn't error on OOM but instead call a function that waits or something)
fn scanDir(ctx: *Context, dir: std.fs.Dir, dir_dev: u64) (std.fs.File.Writer.Error || std.mem.Allocator.Error)!void {
    // XXX: The iterator allocates 8k+ bytes on the stack, may want to do heap allocation here?
    var it = dir.iterate();
    while(true) {
        const entry = it.next() catch {
            ctx.setDirlistError();
            return;
        } orelse break;

        ctx.stat.dir = false;
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
        if (ctx.stat.dir) try scanDir(ctx, edir.?, ctx.stat.dev);
    }
}

pub fn scanRoot(path: []const u8, out: ?std.fs.File) !void {
    var ctx = if (out) |f| try Context.initFile(f) else Context.initMem();
    active_context = &ctx;
    defer active_context = null;
    defer ctx.deinit();

    const full_path = std.fs.realpathAlloc(main.allocator, path) catch null;
    defer if (full_path) |p| main.allocator.free(p);
    try ctx.pushPath(full_path orelse path);

    ctx.stat = try Stat.read(std.fs.cwd(), ctx.pathZ(), true);
    if (!ctx.stat.dir) return error.NotADirectory;
    try ctx.addStat(0);

    var dir = try std.fs.cwd().openDirZ(ctx.pathZ(), .{ .access_sub_paths = true, .iterate = true });
    defer dir.close();
    try scanDir(&ctx, dir, ctx.stat.dev);
    ctx.popPath();
    try ctx.final();
}

// Using a custom recursive descent JSON parser here. std.json is great, but
// has two major downsides:
// - It does strict UTF-8 validation. Which is great in general, but not so
//   much for ncdu dumps that may contain non-UTF-8 paths encoded as strings.
// - The streaming parser requires complex and overly large buffering in order
//   to read strings, which doesn't work so well in our case.
//
// TODO: This code isn't very elegant and is likely contains bugs. It may be
// worth factoring out the JSON parts into a separate abstraction for which
// tests can be written.
const Import = struct {
    ctx: Context,
    rd: std.io.BufferedReader(4096, std.fs.File.Reader),
    ch: u8 = 0, // last read character, 0 = EOF (or invalid null byte, who cares)
    byte: u64 = 1,
    line: u64 = 1,
    namebuf: [32*1024]u8 = undefined,

    const Self = @This();

    fn die(self: *Self, str: []const u8) noreturn {
        ui.die("Error importing file on line {}:{}: {s}.\n", .{ self.line, self.byte, str });
    }

    // Advance to the next byte, sets ch.
    fn con(self: *Self) void {
        // XXX: This indirection through a BufferedReader to just read 1 byte
        // at a time may have some extra overhead. Wrapping our own LinearFifo
        // may or may not be worth it, needs benchmarking.
        self.ch = self.rd.reader().readByte() catch |e| switch (e) {
            error.EndOfStream => 0,
            error.InputOutput => self.die("I/O error"),
            // TODO: This one can be retried
            error.SystemResources => self.die("out of memory"),
            else => unreachable,
        };
        self.byte += 1;
    }

    // Advance to the next non-whitespace byte.
    fn conws(self: *Self) void {
        while (true) {
            switch (self.ch) {
                '\n' => {
                    self.line += 1;
                    self.byte = 1;
                },
                ' ', '\t', '\r' => {},
                else => break,
            }
            self.con();
        }
    }

    // Returns the current byte and advances to the next.
    fn next(self: *Self) u8 {
        defer self.con();
        return self.ch;
    }

    fn hexdig(self: *Self) u16 {
        return switch (self.ch) {
            '0'...'9' => self.next() - '0',
            'a'...'f' => self.next() - 'a' + 10,
            'A'...'F' => self.next() - 'A' + 10,
            else => self.die("invalid hex digit"),
        };
    }

    // Read a string into buf.
    // Any characters beyond the size of the buffer are consumed but otherwise discarded.
    // (May store fewer characters in the case of \u escapes, it's not super precise)
    fn string(self: *Self, buf: []u8) []u8 {
        std.debug.assert(self.ch == '"');
        if (self.next() != '"') self.die("expected '\"'");
        var n: u64 = 0;
        while (true) {
            const ch = self.next();
            switch (ch) {
                '"' => break,
                '\\' => switch (self.next()) {
                    '"' => if (n < buf.len) { buf[n] = '"'; n += 1; },
                    '\\'=> if (n < buf.len) { buf[n] = '\\';n += 1; },
                    '/' => if (n < buf.len) { buf[n] = '/'; n += 1; },
                    'b' => if (n < buf.len) { buf[n] = 0x8; n += 1; },
                    'f' => if (n < buf.len) { buf[n] = 0xc; n += 1; },
                    'n' => if (n < buf.len) { buf[n] = 0xa; n += 1; },
                    'r' => if (n < buf.len) { buf[n] = 0xd; n += 1; },
                    't' => if (n < buf.len) { buf[n] = 0x9; n += 1; },
                    'u' => {
                        const char = (self.hexdig()<<12) + (self.hexdig()<<8) + (self.hexdig()<<4) + self.hexdig();
                        if (n + 6 < buf.len)
                            n += std.unicode.utf8Encode(char, buf[n..n+5]) catch unreachable;
                    },
                    else => self.die("invalid escape sequence"),
                },
                0x20, 0x21, 0x23...0x5b, 0x5d...0xff => if (n < buf.len) { buf[n] = ch; n += 1; },
                else => self.die("invalid character in string"),
            }
        }
        return buf[0..n];
    }

    fn uint(self: *Self, T: anytype) T {
        if (self.ch == '0') {
            self.con();
            return 0;
        }
        var v: T = 0;
        while (self.ch >= '0' and self.ch <= '9') {
            const newv = v *% 10 +% (self.ch - '0');
            if (newv < v) self.die("integer out of range");
            v = newv;
            self.con();
        }
        if (v == 0) self.die("expected number");
        return v;
    }

    fn boolean(self: *Self) bool {
        switch (self.next()) {
            't' => {
                if (self.next() == 'r' and self.next() == 'u' and self.next() == 'e')
                    return true;
            },
            'f' => {
                if (self.next() == 'a' and self.next() == 'l' and self.next() == 's' and self.next() == 'e')
                    return false;
            },
            else => {}
        }
        self.die("expected boolean");
    }

    // Consume and discard any JSON value.
    fn conval(self: *Self) void {
        switch (self.ch) {
            't' => _ = self.boolean(),
            'f' => _ = self.boolean(),
            'n' => {
                self.con();
                if (!(self.next() == 'u' and self.next() == 'l' and self.next() == 'l'))
                    self.die("invalid JSON value");
            },
            '"' => _ = self.string(&[0]u8{}),
            '{' => {
                self.con();
                self.conws();
                if (self.ch == '}') { self.con(); return; }
                while (true) {
                    self.conws();
                    _ = self.string(&[0]u8{});
                    self.conws();
                    if (self.next() != ':') self.die("expected ':'");
                    self.conws();
                    self.conval();
                    self.conws();
                    switch (self.next()) {
                        ',' => continue,
                        '}' => break,
                        else => self.die("expected ',' or '}'"),
                    }
                }
            },
            '[' => {
                self.con();
                self.conws();
                if (self.ch == ']') { self.con(); return; }
                while (true) {
                    self.conws();
                    self.conval();
                    self.conws();
                    switch (self.next()) {
                        ',' => continue,
                        ']' => break,
                        else => self.die("expected ',' or ']'"),
                    }
                }
            },
            '-', '0'...'9' => {
                self.con();
                // Numbers are kind of annoying, this "parsing" is invalid and ultra-lazy.
                while (true) {
                    switch (self.ch) {
                        '-', '+', 'e', 'E', '.', '0'...'9' => self.con(),
                        else => return,
                    }
                }
            },
            else => self.die("invalid JSON value"),
        }
    }

    fn itemkey(self: *Self, key: []const u8, name: *?[]u8, special: *?Context.Special) void {
        const eq = std.mem.eql;
        switch (if (key.len > 0) key[0] else @as(u8,0)) {
            'a' => {
                if (eq(u8, key, "asize")) {
                    self.ctx.stat.size = self.uint(u64);
                    return;
                }
            },
            'd' => {
                if (eq(u8, key, "dsize")) {
                    self.ctx.stat.blocks = @intCast(u61, self.uint(u64)>>9);
                    return;
                }
                if (eq(u8, key, "dev")) {
                    self.ctx.stat.dev = self.uint(u64);
                    return;
                }
            },
            'e' => {
                if (eq(u8, key, "excluded")) {
                    var buf: [32]u8 = undefined;
                    const typ = self.string(&buf);
                    // "frmlnk" is also possible, but currently considered equivalent to "pattern".
                    if (eq(u8, typ, "otherfs")) special.* = .other_fs
                    else if (eq(u8, typ, "kernfs")) special.* = .kernfs
                    else special.* = .excluded;
                }
            },
            'g' => {
                if (eq(u8, key, "gid")) {
                    self.ctx.stat.ext.gid = self.uint(u32);
                    return;
                }
            },
            'h' => {
                if (eq(u8, key, "hlinkc")) {
                    self.ctx.stat.hlinkc = true;
                    return;
                }
            },
            'i' => {
                if (eq(u8, key, "ino")) {
                    self.ctx.stat.ino = self.uint(u64);
                    return;
                }
            },
            'm' => {
                if (eq(u8, key, "mode")) {
                    self.ctx.stat.ext.mode = self.uint(u16);
                    return;
                }
                if (eq(u8, key, "mtime")) {
                    self.ctx.stat.ext.mtime = self.uint(u64);
                    // Accept decimal numbers, but discard the fractional part because our data model doesn't support it.
                    if (self.ch == '.') {
                        self.con();
                        while (self.ch >= '0' and self.ch <= '9')
                            self.con();
                    }
                    return;
                }
            },
            'n' => {
                if (eq(u8, key, "name")) {
                    if (name.* != null) self.die("duplicate key");
                    name.* = self.string(&self.namebuf);
                    if (name.*.?.len > self.namebuf.len-5) self.die("too long file name");
                    return;
                }
                if (eq(u8, key, "nlink")) {
                    self.ctx.stat.nlink = self.uint(u32);
                    if (!self.ctx.stat.dir and self.ctx.stat.nlink > 1)
                        self.ctx.stat.hlinkc = true;
                    return;
                }
                if (eq(u8, key, "notreg")) {
                    self.ctx.stat.reg = !self.boolean();
                    return;
                }
            },
            'r' => {
                if (eq(u8, key, "read_error")) {
                    if (self.boolean())
                        special.* = .err;
                    return;
                }
            },
            'u' => {
                if (eq(u8, key, "uid")) {
                    self.ctx.stat.ext.uid = self.uint(u32);
                    return;
                }
            },
            else => {},
        }
        self.conval();
    }

    fn iteminfo(self: *Self, dir_dev: u64) void {
        if (self.next() != '{') self.die("expected '{'");
        self.ctx.stat.dev = dir_dev;
        var name: ?[]u8 = null;
        var special: ?Context.Special = null;
        while (true) {
            self.conws();
            var keybuf: [32]u8 = undefined;
            const key = self.string(&keybuf);
            self.conws();
            if (self.next() != ':') self.die("expected ':'");
            self.conws();
            self.itemkey(key, &name, &special);
            self.conws();
            switch (self.next()) {
                ',' => continue,
                '}' => break,
                else => self.die("expected ',' or '}'"),
            }
        }
        if (name) |n| self.ctx.pushPath(n) catch unreachable
        else self.die("missing \"name\" field");
        if (special) |s| self.ctx.addSpecial(s) catch unreachable
        else self.ctx.addStat(dir_dev) catch unreachable;
    }

    fn item(self: *Self, dev: u64) void {
        self.ctx.stat = .{};
        if (self.ch == '[') {
            self.ctx.stat.dir = true;
            self.con();
            self.conws();
        }

        self.iteminfo(dev);

        self.conws();
        if (self.ctx.stat.dir) {
            const ndev = self.ctx.stat.dev;
            while (self.ch == ',') {
                self.con();
                self.conws();
                self.item(ndev);
                self.conws();
            }
            if (self.next() != ']') self.die("expected ',' or ']'");
        }
        self.ctx.popPath();

        if ((self.ctx.items_seen & 1023) == 0)
            main.handleEvent(false, false) catch unreachable;
    }

    fn root(self: *Self) void {
        self.con();
        self.conws();
        if (self.next() != '[') self.die("expected '['");
        self.conws();
        if (self.uint(u16) != 1) self.die("incompatible major format version");
        self.conws();
        if (self.next() != ',') self.die("expected ','");
        self.conws();
        _ = self.uint(u16); // minor version, ignored for now
        self.conws();
        if (self.next() != ',') self.die("expected ','");
        self.conws();
        // metadata object
        if (self.ch != '{') self.die("expected '{'");
        self.conval(); // completely discarded
        self.conws();
        if (self.next() != ',') self.die("expected ','");
        self.conws();
        // root element
        if (self.ch != '[') self.die("expected '['"); // top-level entry must be a dir
        self.item(0);
        self.conws();
        // any trailing elements
        while (self.ch == ',') {
            self.con();
            self.conws();
            self.conval();
            self.conws();
        }
        if (self.next() != ']') self.die("expected ',' or ']'");
        self.conws();
        if (self.ch != 0) self.die("trailing garbage");
    }
};

pub fn importRoot(path: [:0]const u8, out: ?std.fs.File) !void {
    var fd = if (std.mem.eql(u8, "-", path)) std.io.getStdIn()
             else try std.fs.cwd().openFileZ(path, .{});
    defer fd.close();

    var imp = Import{
        .ctx = if (out) |f| try Context.initFile(f) else Context.initMem(),
        .rd = std.io.bufferedReader(fd.reader()),
    };
    active_context = &imp.ctx;
    defer active_context = null;
    defer imp.ctx.deinit();
    imp.root();
    try imp.ctx.final();
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

pub fn keyInput(ch: i32) !void {
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
