const std = @import("std");
const main = @import("main.zig");
usingnamespace @import("util.zig");

// While an arena allocator is optimimal for almost all scenarios in which ncdu
// is used, it doesn't allow for re-using deleted nodes after doing a delete or
// refresh operation, so a long-running ncdu session with regular refreshes
// will leak memory, but I'd say that's worth the efficiency gains.
// TODO: Can still implement a simple bucketed free list on top of this arena
// allocator to reuse nodes, if necessary.
var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub const EType = packed enum(u2) { dir, link, file };

// Memory layout:
//      Dir + name (+ alignment + Ext)
//  or: Link + name (+ alignment + Ext)
//  or: File + name (+ alignment + Ext)
//
// Entry is always the first part of Dir, Link and File, so a pointer cast to
// *Entry is always safe and an *Entry can be casted to the full type.
// (TODO: What are the aliassing rules for Zig? There is a 'noalias' keyword,
// but does that mean all unmarked pointers are allowed to alias?)
// (TODO: The 'alignment' in the layout above is a lie, none of these structs
// or fields have any sort of alignment. This is great for saving memory but
// perhaps not very great for code size or performance. Might want to
// experiment with setting some alignment and measure the impact)
// (TODO: Putting Ext before the Entry pointer may be a little faster; removes
// the need to iterate over the name)
pub const Entry = packed struct {
    etype: EType,
    isext: bool,
    blocks: u61, // 512-byte blocks
    size: u64,
    next: ?*Entry,

    const Self = @This();

    pub fn dir(self: *Self) ?*Dir {
        return if (self.etype == .dir) @ptrCast(*Dir, self) else null;
    }

    pub fn link(self: *Self) ?*Link {
        return if (self.etype == .link) @ptrCast(*Link, self) else null;
    }

    pub fn file(self: *Self) ?*File {
        return if (self.etype == .file) @ptrCast(*File, self) else null;
    }

    fn nameOffset(etype: EType) usize {
        return switch (etype) {
            .dir => @byteOffsetOf(Dir, "name"),
            .link => @byteOffsetOf(Link, "name"),
            .file => @byteOffsetOf(File, "name"),
        };
    }

    pub fn name(self: *const Self) [:0]const u8 {
        const ptr = @intToPtr([*:0]u8, @ptrToInt(self) + nameOffset(self.etype));
        return ptr[0..std.mem.lenZ(ptr) :0];
    }

    pub fn ext(self: *Self) ?*Ext {
        if (!self.isext) return null;
        const n = self.name();
        return @intToPtr(*Ext, std.mem.alignForward(@ptrToInt(self) + nameOffset(self.etype) + n.len + 1, @alignOf(Ext)));
    }

    pub fn create(etype: EType, isext: bool, ename: []const u8) !*Entry {
        const base_size = nameOffset(etype) + ename.len + 1;
        const size = (if (isext) std.mem.alignForward(base_size, @alignOf(Ext))+@sizeOf(Ext) else base_size);
        var ptr = try allocator.allocator.allocWithOptions(u8, size, @alignOf(Entry), null);
        std.mem.set(u8, ptr, 0); // kind of ugly, but does the trick
        var e = @ptrCast(*Entry, ptr);
        e.etype = etype;
        e.isext = isext;
        var name_ptr = @intToPtr([*]u8, @ptrToInt(e) + nameOffset(etype));
        std.mem.copy(u8, name_ptr[0..ename.len], ename);
        //std.debug.warn("{any}\n", .{ @ptrCast([*]u8, e)[0..size] });
        return e;
    }

    // Set the 'err' flag on Dirs and Files, propagating 'suberr' to parents.
    pub fn set_err(self: *Self, parents: *const Parents) void {
        if (self.dir()) |d| d.err = true
        else if (self.file()) |f| f.err = true
        else unreachable;
        var it = parents.iter();
        if (&parents.top().entry == self) _ = it.next();
        while (it.next()) |p| {
            if (p.suberr) break;
            p.suberr = true;
        }
    }

    // Insert this entry into the tree at the given directory, updating parent sizes and item counts.
    // (TODO: This function creates an unrecoverable mess on OOM, need to do something better)
    pub fn insert(self: *Entry, parents: *const Parents) !void {
        self.next = parents.top().sub;
        parents.top().sub = self;
        if (self.dir()) |d| std.debug.assert(d.sub == null);

        const dev = parents.top().dev;
        // Set if this is the first time we've found this hardlink in the bottom-most directory of the given dev.
        // Means we should count it for other-dev parent dirs, too.
        var new_hl = false;

        var it = parents.iter();
        while(it.next()) |p| {
            var add_total = false;

            if (self.ext()) |e|
                if (p.entry.ext()) |pe|
                    if (e.mtime > pe.mtime) { pe.mtime = e.mtime; };

            // Hardlink in a subdirectory with a different device, only count it the first time.
            if (self.link() != null and dev != p.dev) {
                add_total = new_hl;

            } else if (self.link()) |l| {
                const n = HardlinkNode{ .ino = l.ino, .dir = p, .num_files = 1 };
                var d = try devices.items[dev].hardlinks.getOrPut(n);
                new_hl = !d.found_existing;
                if (d.found_existing) d.entry.key.num_files += 1;
                // First time we encounter this file in this dir, count it.
                if (d.entry.key.num_files == 1) {
                    add_total = true;
                    p.shared_size = saturateAdd(p.shared_size, self.size);
                    p.shared_blocks = saturateAdd(p.shared_blocks, self.blocks);
                    p.shared_items = saturateAdd(p.shared_items, 1);
                // Encountered this file in this dir the same number of times as its link count, meaning it's not shared with other dirs.
                } else if(d.entry.key.num_files == l.nlink) {
                    p.shared_size = saturateSub(p.shared_size, self.size);
                    p.shared_blocks = saturateSub(p.shared_blocks, self.blocks);
                    p.shared_items = saturateSub(p.shared_items, 1);
                }
            } else {
                add_total = true;
            }
            if(add_total) {
                p.entry.size = saturateAdd(p.entry.size, self.size);
                p.entry.blocks = saturateAdd(p.entry.blocks, self.blocks);
                p.total_items = saturateAdd(p.total_items, 1);
            }
        }
    }
};

const DevId = u30; // Can be reduced to make room for more flags in Dir.

pub const Dir = packed struct {
    entry: Entry,

    sub: ?*Entry,

    // entry.{blocks,size}: Total size of all unique files + dirs. Non-shared hardlinks are counted only once.
    //   (i.e. the space you'll need if you created a filesystem with only this dir)
    // shared_*: Unique hardlinks that still have references outside of this directory.
    //   (i.e. the space you won't reclaim by deleting this dir)
    // (space reclaimed by deleting a dir =~ entry. - shared_)
    shared_blocks: u64,
    shared_size: u64,
    shared_items: u32,
    total_items: u32,
    // TODO: ncdu1 only keeps track of a total item count including duplicate hardlinks.
    // That number seems useful, too. Include it somehow?

    // Indexes into the global 'devices' array
    dev: DevId,

    err: bool,
    suberr: bool,

    // Only used to find the @byteOffsetOff, the name is written at this point as a 0-terminated string.
    // (Old C habits die hard)
    name: u8,
};

// File that's been hardlinked (i.e. nlink > 1)
pub const Link = packed struct {
    entry: Entry,
    ino: u64,
    // dev is inherited from the parent Dir
    nlink: u32,
    name: u8,
};

// Anything that's not an (indexed) directory or hardlink. Excluded directories are also "Files".
pub const File = packed struct {
    entry: Entry,

    err: bool,
    excluded: bool,
    other_fs: bool,
    kernfs: bool,
    notreg: bool,
    _pad: u3,

    name: u8,
};

pub const Ext = packed struct {
    mtime: u64,
    uid: u32,
    gid: u32,
    mode: u16,
};

comptime {
    std.debug.assert(@bitOffsetOf(Dir, "name") % 8 == 0);
    std.debug.assert(@bitOffsetOf(Link, "name") % 8 == 0);
    std.debug.assert(@bitOffsetOf(File, "name") % 8 == 0);
}


// Hardlink handling:
//
//   Global lookup table of dev -> (ino,*Dir) -> num_files
//
//   num_files is how many times the file has been found in the particular dir.
//   num_links is the file's st_nlink count.
//
//   Adding a hardlink: O(parents)
//
//     for dir in file.parents:
//       add to dir.total_* if it's not yet in the lookup table
//       add to num_files in the lookup table
//       add to dir.shared_* where num_files == 1
//
//   Removing a hardlink: O(parents)
//
//     for dir in file.parents:
//       subtract from num_files in the lookup table
//       subtract from dir.total_* if num_files == 0
//       subtract from dir.shared_* if num_files == num_links-1
//       remove from lookup table if num_files == 0
//
//   Re-calculating full hardlink stats (only possible when also storing sizes):
//
//     reset total_* and shared_* for all dirs
//     for (file,dir) in lookup_table:
//       dir.total_* += file
//       if file.num_links != dir.num_files:
//         dir.shared_* += file
//
// Problem: num_links is not available in ncdu JSON dumps, will have to assume
//   that there are no shared hardlinks outside of the given dump.
//
// Problem: This data structure does not provide a way to easily list all paths
//   with the same dev,ino. ncdu provides this list in the info window. Doesn't
//   seem too commonly used, can still be provided by a slow full scan of the
//   tree.


// 20 bytes per hardlink/Dir entry, everything in a single allocation.
// (Should really be aligned to 8 bytes and hence take up 24 bytes, but let's see how this works out)
//
// getEntry() allows modification of the key without re-insertion (this is unsafe in the general case, but works fine for modifying num_files)
//
// Potential problem: HashMap uses a 32bit item counter, which may be exceeded in extreme scenarios.
// (ncdu itself doesn't support more than 31bit-counted files, but this table is hardlink_count*parent_dirs and may grow a bit)

const HardlinkNode = packed struct {
    ino: u64,
    dir: *Dir,
    num_files: u32,

    const Self = @This();

    // hash() assumes a struct layout, hence the 'packed struct'
    fn hash(self: Self) u64 { return std.hash.Wyhash.hash(0, @ptrCast([*]const u8, &self)[0..@byteOffsetOf(Self, "dir")+@sizeOf(*Dir)]); }
    fn eql(a: Self, b: Self) bool { return a.ino == b.ino and a.dir == b.dir; }
};

// Device entry, this is used for two reasons:
// 1. st_dev ids are 64-bit, but in a typical filesystem there's only a few
//    unique ids, hence we can save RAM by only storing smaller DevId's in Dir
//    entries and using that as an index to a lookup table.
// 2. Keeping track of hardlink counts for each dir and inode, as described above.
//
// (Device entries are never deallocated)
const Device = struct {
    dev: u64,
    hardlinks: Hardlinks = Hardlinks.init(main.allocator),

    const Hardlinks = std.HashMap(HardlinkNode, void, HardlinkNode.hash, HardlinkNode.eql, 80);
};

var devices: std.ArrayList(Device) = std.ArrayList(Device).init(main.allocator);
var dev_lookup: std.AutoHashMap(u64, DevId) = std.AutoHashMap(u64, DevId).init(main.allocator);

pub fn getDevId(dev: u64) !DevId {
    var d = try dev_lookup.getOrPut(dev);
    if (!d.found_existing) {
        errdefer dev_lookup.removeAssertDiscard(dev);
        d.entry.value = @intCast(DevId, devices.items.len);
        try devices.append(.{ .dev = dev });
    }
    return d.entry.value;
}

pub fn getDev(id: DevId) u64 {
    return devices.items[id].dev;
}

pub var root: *Dir = undefined;

// Stack of parent directories, convenient helper when constructing and traversing the tree.
// The 'root' node is always implicitely at the bottom of the stack.
pub const Parents = struct {
    stack: std.ArrayList(*Dir) = std.ArrayList(*Dir).init(main.allocator),

    const Self = @This();

    pub fn push(self: *Self, dir: *Dir) !void {
        return self.stack.append(dir);
    }

    // Attempting to remove the root node is considered a bug.
    pub fn pop(self: *Self) void {
        _ = self.stack.pop();
    }

    pub fn top(self: *const Self) *Dir {
        return if (self.stack.items.len == 0) root else self.stack.items[self.stack.items.len-1];
    }

    pub const Iterator = struct {
        lst: *const Self,
        index: usize = 0, // 0 = top of the stack, counts upwards to go down

        pub fn next(it: *Iterator) ?*Dir {
            const len = it.lst.stack.items.len;
            if (it.index > len) return null;
            it.index += 1;
            return if (it.index > len) root else it.lst.stack.items[len-it.index];
        }
    };

    // Iterate from top to bottom of the stack.
    pub fn iter(self: *const Self) Iterator {
        return .{ .lst = self };
    }

    pub fn path(self: *const Self, wr: anytype) !void {
        const r = root.entry.name();
        try wr.writeAll(r);
        var i: usize = 0;
        while (i < self.stack.items.len) {
            if (i != 0 or r[r.len-1] != '/') try wr.writeByte('/');
            try wr.writeAll(self.stack.items[i].entry.name());
            i += 1;
        }
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
    }
};


test "entry" {
    var e = Entry.create(.file, false, "hello") catch unreachable;
    std.debug.assert(e.etype == .file);
    std.debug.assert(!e.isext);
    std.testing.expectEqualStrings(e.name(), "hello");
}
