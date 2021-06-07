const std = @import("std");
const main = @import("main.zig");
const ui = @import("ui.zig");
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

    pub fn create(etype: EType, isext: bool, ename: []const u8) *Entry {
        const base_size = nameOffset(etype) + ename.len + 1;
        const size = (if (isext) std.mem.alignForward(base_size, @alignOf(Ext))+@sizeOf(Ext) else base_size);
        var ptr = blk: {
            while (true) {
                if (allocator.allocator.allocWithOptions(u8, size, @alignOf(Entry), null)) |p|
                    break :blk p
                else |_| {}
                ui.oom();
            }
        };
        std.mem.set(u8, ptr, 0); // kind of ugly, but does the trick
        var e = @ptrCast(*Entry, ptr);
        e.etype = etype;
        e.isext = isext;
        var name_ptr = @intToPtr([*]u8, @ptrToInt(e) + nameOffset(etype));
        std.mem.copy(u8, name_ptr[0..ename.len], ename);
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

    fn addStats(self: *Entry, parents: *const Parents) void {
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
            p.items = saturateAdd(p.items, 1);

            // Hardlink in a subdirectory with a different device, only count it the first time.
            if (self.etype == .link and dev != p.dev) {
                add_total = new_hl;

            } else if (self.link()) |l| {
                const n = devices.HardlinkNode{ .ino = l.ino, .dir = p };
                var d = devices.list.items[dev].hardlinks.getOrPut(n) catch unreachable;
                new_hl = !d.found_existing;
                // First time we encounter this file in this dir, count it.
                if (!d.found_existing) {
                    d.value_ptr.* = 1;
                    add_total = true;
                    p.shared_size = saturateAdd(p.shared_size, self.size);
                    p.shared_blocks = saturateAdd(p.shared_blocks, self.blocks);
                } else {
                    d.value_ptr.* += 1;
                    // Encountered this file in this dir the same number of times as its link count, meaning it's not shared with other dirs.
                    if(d.value_ptr.* == l.nlink) {
                        p.shared_size = saturateSub(p.shared_size, self.size);
                        p.shared_blocks = saturateSub(p.shared_blocks, self.blocks);
                    }
                }

            } else
                add_total = true;
            if(add_total) {
                p.entry.size = saturateAdd(p.entry.size, self.size);
                p.entry.blocks = saturateAdd(p.entry.blocks, self.blocks);
            }
        }
    }

    // Insert this entry into the tree at the given directory, updating parent sizes and item counts.
    pub fn insert(self: *Entry, parents: *const Parents) void {
        self.next = parents.top().sub;
        parents.top().sub = self;
        if (self.dir()) |d| std.debug.assert(d.sub == null);

        // Links with nlink == 0 are counted after we're done scanning.
        if (if (self.link()) |l| l.nlink == 0 else false)
            link_count.add(parents.top().dev, self.link().?.ino)
        else
            self.addStats(parents);
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
    items: u32,

    // Indexes into the global 'devices.list' array
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
    // dev is inherited from the parent Dir
    ino: u64,
    // Special value '0' means: "This link hasn't been counted in the parent
    // sizes yet because we only know that it's a hard link but not how many
    // links it has". These are added to the tree structure first and are
    // counted after the scan is complete (see link_count below).
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
    mtime: u64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    mode: u16 = 0,
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
//
// Problem: A file's st_nlink count may have changed during a scan and hence be
//   inconsistent with other entries for the same file. Not ~too~ common so a
//   few glitches are fine, but I haven't worked out the impact of this yet.


pub const devices = struct {
    var list: std.ArrayList(Device) = std.ArrayList(Device).init(main.allocator);
    // dev -> id
    var lookup: std.AutoHashMap(u64, DevId) = std.AutoHashMap(u64, DevId).init(main.allocator);

    // 20 bytes per hardlink/Dir entry, 16 for the key + 4 for the value.
    //
    // Potential problem: HashMap uses a 32bit item counter, which may be exceeded in extreme scenarios.
    // (ncdu 1.x doesn't support more than 31bit-counted files, but this table is hardlink_count*parent_dirs and may grow a bit)
    const HardlinkNode = struct { ino: u64, dir: *Dir };
    const Hardlinks = std.AutoHashMap(HardlinkNode, u32);

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
    };

    pub fn getId(dev: u64) DevId {
        var d = lookup.getOrPut(dev) catch unreachable;
        if (!d.found_existing) {
            d.value_ptr.* = @intCast(DevId, list.items.len);
            list.append(.{ .dev = dev }) catch unreachable;
        }
        return d.value_ptr.*;
    }

    pub fn getDev(id: DevId) u64 {
        return list.items[id].dev;
    }
};

// Special hash table for counting hard links with nlink=0.
pub const link_count = struct {
    var nodes = std.HashMap(Node, void, HashContext, 80).init(main.allocator);

    // Single node for both key (dev,ino) and value (count), in order to prevent padding between hash table node entries.
    const Node = struct {
        ino: u64,
        dev: u32, // DevId, but 32-bits for easier hashing
        count: u32,
    };

    const HashContext = struct {
        pub fn hash(self: @This(), v: Node) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&v.dev));
            h.update(std.mem.asBytes(&v.ino));
            return h.final();
        }

        pub fn eql(self: @This(), a: Node, b: Node) bool {
            return a.ino == b.ino and a.dev == b.dev;
        }
    };

    pub fn add(dev: DevId, ino: u64) void {
        const n = Node{ .dev = dev, .ino = ino, .count = 1 };
        var d = nodes.getOrPut(n) catch unreachable;
        if (d.found_existing) d.key_ptr.*.count += 1;
    }

    var final_dir: Parents = undefined;

    fn final_rec() void {
        var it = final_dir.top().sub;
        while (it) |e| : (it = e.next) {
            if (e.dir()) |d| {
                final_dir.push(d);
                final_rec();
                final_dir.pop();
                continue;
            }
            const l = e.link() orelse continue;
            if (l.nlink > 0) continue;
            const s = Node{ .dev = final_dir.top().dev, .ino = l.ino, .count = 0 };
            if (nodes.getEntry(s)) |n| {
                l.nlink = n.key_ptr.*.count;
                e.addStats(&final_dir);
            }
        }
    }

    // Called when all files have been added, will traverse the directory to
    // find all links, update their nlink count and parent sizes.
    pub fn final() void {
        if (nodes.count() == 0) return;
        final_dir = Parents{};
        final_rec();
        nodes.clearAndFree();
        final_dir.deinit();
    }
};

pub var root: *Dir = undefined;

// Stack of parent directories, convenient helper when constructing and traversing the tree.
// The 'root' node is always implicitely at the bottom of the stack.
pub const Parents = struct {
    stack: std.ArrayList(*Dir) = std.ArrayList(*Dir).init(main.allocator),

    const Self = @This();

    pub fn push(self: *Self, dir: *Dir) void {
        return self.stack.append(dir) catch unreachable;
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

    // Append the path to the given arraylist. The list is assumed to use main.allocator, so it can't fail.
    pub fn path(self: *const Self, out: *std.ArrayList(u8)) void {
        const r = root.entry.name();
        out.appendSlice(r) catch unreachable;
        var i: usize = 0;
        while (i < self.stack.items.len) {
            if (i != 0 or r[r.len-1] != '/') out.append('/') catch unreachable;
            out.appendSlice(self.stack.items[i].entry.name()) catch unreachable;
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
