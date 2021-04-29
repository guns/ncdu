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
    ext: model.Ext,
};

// Cast any integer type to the target type, clamping the
// value to the supported maximum if necessary.
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

// Cast any integer type to the unsigned target type, wrapping/truncating as necessary.
fn castWrap(comptime T: type, x: anytype) T {
    return @intCast(T, x); // TODO
}

fn clamp(comptime T: type, comptime field: anytype, x: anytype) std.meta.fieldInfo(T, field).field_type {
    return castClamp(std.meta.fieldInfo(T, field).field_type, x);
}

fn wrap(comptime T: type, comptime field: anytype, x: anytype) std.meta.fieldInfo(T, field).field_type {
    return castWrap(std.meta.fieldInfo(T, field).field_type, x);
}

fn readStat(parent: std.fs.Dir, name: [:0]const u8) !Stat {
    const stat = try std.os.fstatatZ(parent.fd, name, 0);
    return Stat{
        .blocks = clamp(Stat, .blocks, stat.blocks),
        .size = clamp(Stat, .size, stat.size),
        .dev = wrap(Stat, .dev, stat.dev),
        .ino = wrap(Stat, .ino, stat.ino),
        .nlink = clamp(Stat, .nlink, stat.nlink),
        .dir = std.os.system.S_ISDIR(stat.mode),
        .reg = std.os.system.S_ISREG(stat.mode),
        .ext = .{
            .mtime = clamp(model.Ext, .mtime, stat.mtime().tv_sec),
            .uid = wrap(model.Ext, .uid, stat.uid),
            .gid = wrap(model.Ext, .gid, stat.gid),
            .mode = clamp(model.Ext, .mode, stat.mode & 0xffff),
        },
    };
}

// Read and index entries of the dir identified by parent/parents.top().
// (TODO: shouldn't error on OOM but instead call a function that waits or something)
fn scanDir(parents: *model.Parents, parent: std.fs.Dir) std.mem.Allocator.Error!void {
    var dir = parent.openDirZ(parents.top().entry.name(), .{ .access_sub_paths = true, .iterate = true, .no_follow = true }) catch {
        parents.top().entry.set_err(parents);
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while(true) {
        const entry = it.next() catch {
            parents.top().entry.set_err(parents);
            return;
        } orelse break;

        // TODO: Check for exclude patterns

        // XXX: Surely the name already has a trailing \0 in the buffer received by the OS?
        const name_z = std.os.toPosixPath(entry.name) catch undefined;
        const stat = readStat(dir, &name_z) catch {
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

        // TODO Check for kernfs
        // TODO Follow symlink if that option is enabled
        // TODO Check for CACHEDIR.TAG if that option is enabled and this is a dir

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
        if (e.ext()) |ext| ext.* = stat.ext;
        if (e.link()) |l| {
            l.ino = stat.ino;
            l.nlink = stat.nlink;
        }
        try e.insert(parents);

        if (e.dir()) |d| {
            try parents.push(d);
            try scanDir(parents, dir);
            parents.pop();
        }
    }
}

pub fn scanRoot(path: []const u8) !void {
    // XXX: Both realpathAlloc() and toPosixPath are limited to PATH_MAX.
    // Oh well, I suppose we can accept that as limitation for the top-level dir we're scanning.
    const full_path = try std.os.toPosixPath(try std.fs.realpathAlloc(main.allocator, path));

    const stat = try readStat(std.fs.cwd(), &full_path);
    if (!stat.dir) return error.NotADirectory;
    model.root = (try model.Entry.create(.dir, false, &full_path)).dir().?;
    model.root.entry.blocks = stat.blocks;
    model.root.entry.size = stat.size;
    model.root.dev = try model.getDevId(stat.dev);
    if (model.root.entry.ext()) |ext| ext.* = stat.ext;

    var parents = model.Parents{};
    try scanDir(&parents, std.fs.cwd());
}
