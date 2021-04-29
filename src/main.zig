const std = @import("std");
const model = @import("model.zig");
const scan = @import("scan.zig");

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = &general_purpose_allocator.allocator;

pub const Config = struct {
    same_fs: bool = true,
    extended: bool = false,
    exclude_caches: bool = false,
    follow_symlinks: bool = false,
    exclude_kernfs: bool = false,
    // TODO: exclude patterns

    update_delay: u32 = 100,
    si: bool = false,
    // TODO: color scheme

    read_only: bool = false,
    can_shell: bool = true,
    confirm_quit: bool = false,
};

pub var config = Config{};

// For debugging
fn writeTree(out: anytype, e: *model.Entry, indent: u32) @TypeOf(out).Error!void {
    var i: u32 = 0;
    while (i<indent) {
        try out.writeByte(' ');
        i += 1;
    }
    try out.print("{s}  blocks={d}  size={d}", .{ e.name(), e.blocks, e.size });

    if (e.dir()) |d| {
        try out.print("  blocks={d}-{d}  size={d}-{d}  items={d}-{d}  dev={x}", .{
            d.total_blocks, d.shared_blocks,
            d.total_size, d.shared_size,
            d.total_items, d.shared_items, d.dev
        });
        if (d.err) try out.writeAll("  err");
        if (d.suberr) try out.writeAll("  suberr");
    } else if (e.file()) |f| {
        if (f.err) try out.writeAll("  err");
        if (f.excluded) try out.writeAll("  excluded");
        if (f.other_fs) try out.writeAll("  other_fs");
        if (f.kernfs) try out.writeAll("  kernfs");
        if (f.notreg) try out.writeAll("  notreg");
    } else if (e.link()) |l| {
        try out.print("  ino={x}  nlinks={d}", .{ l.ino, l.nlink });
    }

    try out.writeByte('\n');
    if (e.dir()) |d| {
        var s = d.sub;
        while (s) |sub| {
            try writeTree(out, sub, indent+4);
            s = sub.next;
        }
    }
}

pub fn main() anyerror!void {
    std.log.info("align={}, Entry={}, Dir={}, Link={}, File={}.",
        .{@alignOf(model.Dir), @sizeOf(model.Entry), @sizeOf(model.Dir), @sizeOf(model.Link), @sizeOf(model.File)});
    try scan.scanRoot("/");
    
    //var out = std.io.bufferedWriter(std.io.getStdOut().writer());
    //try writeTree(out.writer(), &model.root.entry, 0);
    //try out.flush();
}
