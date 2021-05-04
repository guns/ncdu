// Ncurses wrappers and TUI helper functions.

const std = @import("std");
const main = @import("main.zig");

pub const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("curses.h");
    @cDefine("_X_OPEN_SOURCE", "1");
    @cInclude("wchar.h");
    @cInclude("locale.h");
});

var inited: bool = false;

pub var rows: u32 = undefined;
pub var cols: u32 = undefined;

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    deinit();
    _ = std.io.getStdErr().writer().print(fmt, args) catch {};
    std.process.exit(1);
}

var to_utf8_buf = std.ArrayList(u8).init(main.allocator);

fn toUtf8BadChar(ch: u8) bool {
    return switch (ch) {
        0...0x1F, 0x7F => true,
        else => false
    };
}

// Utility function to convert a string to valid (mostly) printable UTF-8.
// Invalid codepoints will be encoded as '\x##' strings.
// Returns the given string if it's already valid, otherwise points to an
// internal buffer that will be invalidated on the next call.
// (Doesn't check for non-printable Unicode characters)
// (This program assumes that the console locale is UTF-8, but file names may not be)
pub fn toUtf8(in: [:0]const u8) ![:0]const u8 {
    const hasBadChar = blk: {
        for (in) |ch| if (toUtf8BadChar(ch)) break :blk true;
        break :blk false;
    };
    if (!hasBadChar and std.unicode.utf8ValidateSlice(in)) return in;
    var i: usize = 0;
    to_utf8_buf.shrinkRetainingCapacity(0);
    while (i < in.len) {
        if (std.unicode.utf8ByteSequenceLength(in[i])) |cp_len| {
            if (!toUtf8BadChar(in[i]) and i + cp_len <= in.len) {
                if (std.unicode.utf8Decode(in[i .. i + cp_len])) |_| {
                    try to_utf8_buf.appendSlice(in[i .. i + cp_len]);
                    i += cp_len;
                    continue;
                } else |_| {}
            }
        } else |_| {}
        try to_utf8_buf.writer().print("\\x{X:0>2}", .{in[i]});
        i += 1;
    }
    return try to_utf8_buf.toOwnedSliceSentinel(0);
}

var shorten_buf = std.ArrayList(u8).init(main.allocator);

// Shorten the given string to fit in the given number of columns.
// If the string is too long, only the prefix and suffix will be printed, with '...' in between.
// Input is assumed to be valid UTF-8.
// Return value points to the input string or to an internal buffer that is
// invalidated on a subsequent call.
pub fn shorten(in: [:0]const u8, max_width: u32) ![:0] const u8 {
    if (max_width < 4) return "...";
    var total_width: u32 = 0;
    var prefix_width: u32 = 0;
    var prefix_end: u32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(in).iterator();
    while (it.nextCodepoint()) |cp| {
        // XXX: libc assumption: wchar_t is a Unicode point. True for most modern libcs?
        // (The "proper" way is to use mbtowc(), but I'd rather port the musl wcwidth implementation to Zig so that I *know* it'll be Unicode.
        // On the other hand, ncurses also use wcwidth() so that would cause duplicated code. Ugh)
        const cp_width_ = c.wcwidth(cp);
        const cp_width = @intCast(u32, if (cp_width_ < 0) 1 else cp_width_);
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        total_width += cp_width;
        if (prefix_width + cp_width <= @divFloor(max_width-1, 2)-1) {
            prefix_width += cp_width;
            prefix_end += cp_len;
            continue;
        }
    }
    if (total_width <= max_width) return in;

    shorten_buf.shrinkRetainingCapacity(0);
    try shorten_buf.appendSlice(in[0..prefix_end]);
    try shorten_buf.appendSlice("...");

    var start_width: u32 = prefix_width;
    var start_len: u32 = prefix_end;
    it = std.unicode.Utf8View.initUnchecked(in[prefix_end..]).iterator();
    while (it.nextCodepoint()) |cp| {
        const cp_width_ = c.wcwidth(cp);
        const cp_width = @intCast(u32, if (cp_width_ < 0) 1 else cp_width_);
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        start_width += cp_width;
        start_len += cp_len;
        if (total_width - start_width <= max_width - prefix_width - 3) {
            try shorten_buf.appendSlice(in[start_len..]);
            break;
        }
    }
    return try shorten_buf.toOwnedSliceSentinel(0);
}

fn shortenTest(in: [:0]const u8, max_width: u32, out: [:0]const u8) void {
    std.testing.expectEqualStrings(out, shorten(in, max_width) catch unreachable);
}

test "shorten" {
    _ = c.setlocale(c.LC_ALL, ""); // libc wcwidth() may not recognize Unicode without this
    const t = shortenTest;
    t("abcde", 3, "...");
    t("abcde", 5, "abcde");
    t("abcde", 4, "...e");
    t("abcdefgh", 6, "a...gh");
    t("abcdefgh", 7, "ab...gh");
    t("ＡＢＣＤＥＦＧＨ", 16, "ＡＢＣＤＥＦＧＨ");
    t("ＡＢＣＤＥＦＧＨ", 7, "Ａ...Ｈ");
    t("ＡＢＣＤＥＦＧＨ", 8, "Ａ...Ｈ");
    t("ＡＢＣＤＥＦＧＨ", 9, "Ａ...ＧＨ");
    t("ＡaＢＣＤＥＦＧＨ", 8, "Ａ...Ｈ"); // could optimize this, but w/e
    t("ＡＢＣＤＥＦＧaＨ", 8, "Ａ...aＨ");
    t("ＡＢＣＤＥＦＧＨ", 15, "ＡＢＣ...ＦＧＨ");
}

// ncurses_refs.c
extern fn ncdu_acs_ulcorner() c.chtype;
extern fn ncdu_acs_llcorner() c.chtype;
extern fn ncdu_acs_urcorner() c.chtype;
extern fn ncdu_acs_lrcorner() c.chtype;
extern fn ncdu_acs_hline()    c.chtype;
extern fn ncdu_acs_vline()    c.chtype;

pub fn acs_ulcorner() c.chtype { return ncdu_acs_ulcorner(); }
pub fn acs_llcorner() c.chtype { return ncdu_acs_llcorner(); }
pub fn acs_urcorner() c.chtype { return ncdu_acs_urcorner(); }
pub fn acs_lrcorner() c.chtype { return ncdu_acs_lrcorner(); }
pub fn acs_hline()    c.chtype { return ncdu_acs_hline()   ; }
pub fn acs_vline()    c.chtype { return ncdu_acs_vline()   ; }

const StyleAttr = struct { fg: i16, bg: i16, attr: u32 };
const StyleDef = struct {
    name: []const u8,
    off: StyleAttr,
    dark: StyleAttr,
    fn style(self: *const @This()) StyleAttr {
        return switch (main.config.ui_color) {
            .off => self.off,
            .dark => self.dark,
        };
    }
};

const styles = [_]StyleDef{
    .{  .name = "default",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark = .{ .fg = -1,              .bg = -1,             .attr = 0 } },
    .{  .name = "box_title",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_BOLD },
        .dark = .{ .fg = c.COLOR_BLUE,    .bg = -1,             .attr = c.A_BOLD } },
    .{  .name = "hd", // header + footer
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_BLACK,   .bg = c.COLOR_CYAN,   .attr = 0 } },
    .{  .name = "sel",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_WHITE,   .bg = c.COLOR_GREEN,  .attr = c.A_BOLD } },
    .{  .name = "num",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark = .{ .fg = c.COLOR_YELLOW,  .bg = -1,             .attr = c.A_BOLD } },
    .{  .name = "num_hd",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_CYAN,   .attr = c.A_BOLD } },
    .{  .name = "num_sel",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_GREEN,  .attr = c.A_BOLD } },
    .{  .name = "key",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_BOLD },
        .dark = .{ .fg = c.COLOR_YELLOW,  .bg = -1,             .attr = c.A_BOLD } },
    .{  .name = "key_hd",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_BOLD|c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_CYAN,   .attr = c.A_BOLD } },
    .{  .name = "dir",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark = .{ .fg = c.COLOR_BLUE,    .bg = -1,             .attr = c.A_BOLD } },
    .{  .name = "dir_sel",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_BLUE,    .bg = c.COLOR_GREEN,  .attr = c.A_BOLD } },
    .{  .name = "flag",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark = .{ .fg = c.COLOR_RED,     .bg = -1,             .attr = 0 } },
    .{  .name = "flag_sel",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_RED,     .bg = c.COLOR_GREEN,  .attr = 0 } },
    .{  .name = "graph",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark = .{ .fg = c.COLOR_MAGENTA, .bg = -1,             .attr = 0 } },
    .{  .name = "graph_sel",
        .off  = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_MAGENTA, .bg = c.COLOR_GREEN,  .attr = 0 } },
};

const Style = lbl: {
    var fields: [styles.len]std.builtin.TypeInfo.EnumField = undefined;
    var decls = [_]std.builtin.TypeInfo.Declaration{};
    inline for (styles) |s, i| {
        fields[i] = .{
            .name = s.name,
            .value = i,
        };
    }
    break :lbl @Type(.{
        .Enum = .{
            .layout = .Auto,
            .tag_type = u8,
            .fields = &fields,
            .decls = &decls,
            .is_exhaustive = true,
        }
    });
};

fn updateSize() void {
    // getmax[yx] macros are marked as "legacy", but Zig can't deal with the "proper" getmaxyx macro.
    rows = @intCast(u32, c.getmaxy(c.stdscr));
    cols = @intCast(u32, c.getmaxx(c.stdscr));
}

pub fn init() void {
    if (inited) return;
    if (main.config.nc_tty) {
        var tty = c.fopen("/dev/tty", "r+");
        if (tty == null) die("Error opening /dev/tty: {s}.\n", .{ c.strerror(std.c.getErrno(-1)) });
        var term = c.newterm(null, tty, tty);
        if (term == null) die("Error initializing ncurses.\n", .{});
        _ = c.set_term(term);
    } else {
        if (!std.io.getStdIn().isTty()) die("Standard input is not a TTY. Did you mean to import a file using '-f -'?\n", .{});
        if (c.initscr() == null) die("Error initializing ncurses.\n", .{});
    }
    updateSize();
    _ = c.cbreak();
    _ = c.noecho();
    _ = c.curs_set(0);
    _ = c.keypad(c.stdscr, true);

    _ = c.start_color();
    _ = c.use_default_colors();
    for (styles) |s, i| _ = c.init_pair(@intCast(i16, i+1), s.style().fg, s.style().bg);

    inited = true;
}

pub fn deinit() void {
    if (!inited) return;
    _ = c.erase();
    _ = c.refresh();
    _ = c.endwin();
    inited = false;
}

pub fn style(s: Style) void {
    _ = c.attr_set(styles[@enumToInt(s)].style().attr, @enumToInt(s)+1, null);
}

pub fn move(y: u32, x: u32) void {
    _ = c.move(@intCast(i32, y), @intCast(i32, x));
}

// Wraps to the next line if the text overflows, not sure how to disable that.
// (Well, addchstr() does that, but not entirely sure I want to go that way.
// Does that even work with UTF-8? Or do I really need to go wchar madness?)
pub fn addstr(s: [:0]const u8) void {
    _ = c.addstr(s);
}

pub fn addch(ch: c.chtype) void {
    _ = c.addch(ch);
}

pub fn hline(ch: c.chtype, len: u32) void {
    _ = c.hline(ch, @intCast(i32, len));
}
