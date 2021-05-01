const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");


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
};

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

fn readStat(parent: std.fs.Dir, name: [:0]const u8, follow: bool) !Stat {
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

// Read and index entries of the given dir. The entry for the directory is already assumed to be in 'parents'.
// (TODO: shouldn't error on OOM but instead call a function that waits or something)
fn scanDir(parents: *model.Parents, dir: std.fs.Dir) std.mem.Allocator.Error!void {
    var it = dir.iterate();
    while(true) {
        const entry = it.next() catch {
            parents.top().entry.set_err(parents);
            return;
        } orelse break;

        // TODO: Check for exclude patterns

        // XXX: Surely the name already has a trailing \0 in the buffer received by the OS?
        // XXX#2: Does this allocate PATH_MAX bytes on the stack for each level of recursion!?
        const name_z = std.os.toPosixPath(entry.name) catch undefined;
        var stat = readStat(dir, &name_z, false) catch {
            var e = try model.Entry.create(.file, false, entry.name);
            e.insert(parents) catch unreachable;
            e.set_err(parents);
            continue;
        };

        if (main.config.same_fs and stat.dev != model.getDev(parents.top().dev)) {
            var e = try model.Entry.create(.file, false, entry.name);
            e.file().?.other_fs = true;
            e.insert(parents) catch unreachable;
            continue;
        }

        if (main.config.follow_symlinks and stat.symlink) {
            if (readStat(dir, &name_z, true)) |nstat| {
                if (!nstat.dir) {
                    stat = nstat;
                    // Symlink targets may reside on different filesystems,
                    // this will break hardlink detection and counting so let's disable it.
                    if (stat.nlink > 1 and stat.dev != model.getDev(parents.top().dev))
                        stat.nlink = 1;
                }
            } else |_| {}
        }

        // TODO: Check for kernfs; Zig has no wrappers for fstatfs() yet and calling the syscall directly doesn't seem too trivial. :(

        var edir =
            if (stat.dir) dir.openDirZ(&name_z, .{ .access_sub_paths = true, .iterate = true, .no_follow = true }) catch {
                var e = try model.Entry.create(.file, false, entry.name);
                e.insert(parents) catch unreachable;
                e.set_err(parents);
                continue;
            } else null;
        defer if (edir != null) edir.?.close();

        if (main.config.exclude_caches and stat.dir) {
            if (edir.?.openFileZ("CACHEDIR.TAG", .{})) |f| {
                const sig = "Signature: 8a477f597d28d172789f06886806bc55";
                var buf: [sig.len]u8 = undefined;
                if (f.reader().readAll(&buf)) |len| {
                    if (len == sig.len and std.mem.eql(u8, &buf, sig)) {
                        var e = try model.Entry.create(.file, false, entry.name);
                        e.file().?.excluded = true;
                        e.insert(parents) catch unreachable;
                        continue;
                    }
                } else |_| {}
            } else |_| {}
        }

        const etype = if (stat.dir) model.EType.dir else if (stat.nlink > 1) model.EType.link else model.EType.file;
        var e = try model.Entry.create(etype, main.config.extended, entry.name);
        e.blocks = stat.blocks;
        e.size = stat.size;
        if (e.dir()) |d| {
            d.dev = try model.getDevId(stat.dev);
            // The dir entry itself also counts.
            d.total_blocks = stat.blocks;
            d.total_size = stat.size;
            d.total_items = 1;
        }
        if (e.file()) |f| f.notreg = !stat.dir and !stat.reg;
        if (e.link()) |l| {
            l.ino = stat.ino;
            l.nlink = stat.nlink;
        }
        if (e.ext()) |ext| ext.* = stat.ext;
        try e.insert(parents);

        if (e.dir()) |d| {
            try parents.push(d);
            try scanDir(parents, edir.?);
            parents.pop();
        }
    }
}

pub fn scanRoot(path: []const u8) !void {
    const full_path = std.fs.realpathAlloc(main.allocator, path) catch path;
    model.root = (try model.Entry.create(.dir, false, full_path)).dir().?;

    const stat = try readStat(std.fs.cwd(), model.root.entry.name(), true);
    if (!stat.dir) return error.NotADirectory;
    model.root.entry.blocks = stat.blocks;
    model.root.entry.size = stat.size;
    model.root.dev = try model.getDevId(stat.dev);
    if (model.root.entry.ext()) |ext| ext.* = stat.ext;

    var parents = model.Parents{};
    const dir = try std.fs.cwd().openDirZ(model.root.entry.name(), .{ .access_sub_paths = true, .iterate = true });
    try scanDir(&parents, dir);
}
