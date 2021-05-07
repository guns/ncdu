const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
usingnamespace @import("util.zig");

// Sorted list of all items in the currently opened directory.
// (first item may be null to indicate the "parent directory" item)
var dir_items = std.ArrayList(?*model.Entry).init(main.allocator);

// Currently opened directory and its parents.
var dir_parents = model.Parents{};

var cursor_idx: usize = 0;
var window_top: usize = 0;

fn sortIntLt(a: anytype, b: @TypeOf(a)) ?bool {
    return if (a == b) null else if (main.config.sort_order == .asc) a < b else a > b;
}

fn sortLt(_: void, ap: ?*model.Entry, bp: ?*model.Entry) bool {
    const a = ap.?;
    const b = bp.?;

    if (main.config.sort_dirsfirst and (a.etype == .dir) != (b.etype == .dir))
        return a.etype == .dir;

    switch (main.config.sort_col) {
        .name => {}, // name sorting is the fallback
        .blocks => {
            if (sortIntLt(a.blocks, b.blocks)) |r| return r;
            if (sortIntLt(a.size, b.size)) |r| return r;
        },
        .size => {
            if (sortIntLt(a.size, b.size)) |r| return r;
            if (sortIntLt(a.blocks, b.blocks)) |r| return r;
        },
        .items => {
            const ai = if (a.dir()) |d| d.total_items else 0;
            const bi = if (b.dir()) |d| d.total_items else 0;
            if (sortIntLt(ai, bi)) |r| return r;
            if (sortIntLt(a.blocks, b.blocks)) |r| return r;
            if (sortIntLt(a.size, b.size)) |r| return r;
        },
        .mtime => {
            if (!a.isext or !b.isext) return a.isext;
            if (sortIntLt(a.ext().?.mtime, b.ext().?.mtime)) |r| return r;
        },
    }

    // TODO: Unicode-aware sorting might be nice (and slow)
    const an = a.name();
    const bn = b.name();
    return if (main.config.sort_order == .asc) std.mem.lessThan(u8, an, bn)
           else std.mem.lessThan(u8, bn, an) or std.mem.eql(u8, an, bn);
}

// Should be called when:
// - config.sort_* changes
// - dir_items changes (i.e. from loadDir())
// - files in this dir have changed in a way that affects their ordering
fn sortDir() void {
    // No need to sort the first item if that's the parent dir reference,
    // excluding that allows sortLt() to ignore null values.
    const lst = dir_items.items[(if (dir_items.items.len > 0 and dir_items.items[0] == null) @as(usize, 1) else 0)..];
    std.sort.sort(?*model.Entry, lst, @as(void, undefined), sortLt);
    // TODO: Fixup selected item index
}

// Must be called when:
// - dir_parents changes (i.e. we change directory)
// - config.show_hidden changes
// - files in this dir have been added or removed
fn loadDir() !void {
    dir_items.shrinkRetainingCapacity(0);
    if (dir_parents.top() != model.root)
        try dir_items.append(null);
    var it = dir_parents.top().sub;
    while (it) |e| {
        if (main.config.show_hidden) // fast path
            try dir_items.append(e)
        else {
            const excl = if (e.file()) |f| f.excluded else false;
            const name = e.name();
            if (!excl and name[0] != '.' and name[name.len-1] != '~')
                try dir_items.append(e);
        }
        it = e.next;
    }
    sortDir();
}

// Open the given dir for browsing; takes ownership of the Parents struct.
pub fn open(dir: model.Parents) !void {
    dir_parents.deinit();
    dir_parents = dir;
    try loadDir();

    window_top = 0;
    cursor_idx = 0;
    // TODO: Load view & cursor position if we've opened this dir before.
}

const Row = struct {
    row: u32,
    col: u32 = 0,
    bg: ui.Bg = .default,
    item: ?*model.Entry,

    const Self = @This();

    fn flag(self: *Self) !void {
        defer self.col += 2;
        const item = self.item orelse return;
        const ch: u7 = ch: {
            if (item.file()) |f| {
                if (f.err) break :ch '!';
                if (f.excluded) break :ch '<';
                if (f.other_fs) break :ch '>';
                if (f.kernfs) break :ch '^';
                if (f.notreg) break :ch '@';
            } else if (item.dir()) |d| {
                if (d.err) break :ch '!';
                if (d.suberr) break :ch '.';
                if (d.sub == null) break :ch 'e';
            } else if (item.link()) |_| break :ch 'H';
            return;
        };
        ui.move(self.row, self.col);
        self.bg.fg(.flag);
        ui.addch(ch);
    }

    fn size(self: *Self) !void {
        defer self.col += if (main.config.si) @as(u32, 9) else 10;
        const item = self.item orelse return;
        ui.move(self.row, self.col);
        ui.addsize(self.bg, if (main.config.show_blocks) blocksToSize(item.blocks) else item.size);
        // TODO: shared sizes
    }

    fn name(self: *Self) !void {
        ui.move(self.row, self.col);
        self.bg.fg(.default);
        if (self.item) |i| {
            ui.addch(if (i.etype == .dir) '/' else ' ');
            ui.addstr(try ui.shorten(try ui.toUtf8(i.name()), saturateSub(ui.cols, saturateSub(self.col, 1))));
        } else
            ui.addstr("/..");
    }

    fn draw(self: *Self) !void {
        if (self.bg == .sel) {
            self.bg.fg(.default);
            ui.move(self.row, 0);
            ui.hline(' ', ui.cols);
        }
        try self.flag();
        try self.size();
        try self.name();
    }
};

pub fn draw() !void {
    ui.style(.hd);
    ui.move(0,0);
    ui.hline(' ', ui.cols);
    ui.move(0,0);
    ui.addstr("ncdu " ++ main.program_version ++ " ~ Use the arrow keys to navigate, press ");
    ui.style(.key_hd);
    ui.addch('?');
    ui.style(.hd);
    ui.addstr(" for help");
    if (main.config.read_only) {
        ui.move(0, saturateSub(ui.cols, 10));
        ui.addstr("[readonly]");
    }
    // TODO: [imported] indicator

    ui.style(.default);
    ui.move(1,0);
    ui.hline('-', ui.cols);
    ui.move(1,3);
    ui.addch(' ');
    ui.addstr(try ui.shorten(try ui.toUtf8(model.root.entry.name()), saturateSub(ui.cols, 5)));
    ui.addch(' ');

    const numrows = saturateSub(ui.rows, 3);
    if (cursor_idx < window_top) window_top = cursor_idx;
    if (cursor_idx >= window_top + numrows) window_top = cursor_idx - numrows + 1;

    var i: u32 = 0;
    while (i < numrows) : (i += 1) {
        if (i+window_top >= dir_items.items.len) break;
        var row = Row{
            .row = i+2,
            .item = dir_items.items[i+window_top],
            .bg = if (i+window_top == cursor_idx) .sel else .default,
        };
        try row.draw();
    }

    ui.style(.hd);
    ui.move(ui.rows-1, 0);
    ui.hline(' ', ui.cols);
    ui.move(ui.rows-1, 1);
    ui.addstr("Total disk usage: ");
    ui.addsize(.hd, blocksToSize(dir_parents.top().entry.blocks));
    ui.addstr("  Apparent size: ");
    ui.addsize(.hd, dir_parents.top().entry.size);
    ui.addstr("  Items: ");
    ui.addnum(.hd, dir_parents.top().total_items);
}

fn sortToggle(col: main.SortCol, default_order: main.SortOrder) void {
    if (main.config.sort_col != col) main.config.sort_order = default_order
    else if (main.config.sort_order == .asc) main.config.sort_order = .desc
    else main.config.sort_order = .asc;
    main.config.sort_col = col;
    sortDir();
}

pub fn key(ch: i32) !void {
    switch (ch) {
        'q' => main.state = .quit,

        // Selection
        'j', ui.c.KEY_DOWN => {
            if (cursor_idx+1 < dir_items.items.len) cursor_idx += 1;
        },
        'k', ui.c.KEY_UP => {
            if (cursor_idx > 0) cursor_idx -= 1;
        },
        ui.c.KEY_HOME => cursor_idx = 0,
        ui.c.KEY_END, ui.c.KEY_LL => cursor_idx = saturateSub(dir_items.items.len, 1),
        ui.c.KEY_PPAGE => cursor_idx = saturateSub(cursor_idx, saturateSub(ui.rows, 3)),
        ui.c.KEY_NPAGE => cursor_idx = std.math.min(saturateSub(dir_items.items.len, 1), cursor_idx + saturateSub(ui.rows, 3)),

        // Sort & filter settings
        'n' => sortToggle(.name, .asc),
        's' => sortToggle(if (main.config.show_blocks) .blocks else .size, .desc),
        'C' => sortToggle(.items, .desc),
        'M' => if (main.config.extended) sortToggle(.mtime, .desc),
        'e' => {
            main.config.show_hidden = !main.config.show_hidden;
            try loadDir();
        },
        't' => {
            main.config.sort_dirsfirst = !main.config.sort_dirsfirst;
            sortDir();
        },
        'a' => {
            main.config.show_blocks = !main.config.show_blocks;
            if (main.config.show_blocks and main.config.sort_col == .size) {
                main.config.sort_col = .blocks;
                sortDir();
            }
            if (!main.config.show_blocks and main.config.sort_col == .blocks) {
                main.config.sort_col = .size;
                sortDir();
            }
        },

        else => {}
    }
}
