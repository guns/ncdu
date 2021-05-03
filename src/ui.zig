// Ncurses wrappers and TUI helper functions.

const std = @import("std");
const main = @import("main.zig");

pub const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("curses.h");
});

var inited: bool = false;

pub var rows: i32 = undefined;
pub var cols: i32 = undefined;

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    deinit();
    _ = std.io.getStdErr().writer().print(fmt, args) catch {};
    std.process.exit(1);
}

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

pub fn style(s: Style) void {
    _ = c.attr_set(styles[@enumToInt(s)].style().attr, @enumToInt(s)+1, null);
}

fn updateSize() void {
    // getmax[yx] macros are marked as "legacy", but Zig can't deal with the "proper" getmaxyx macro.
    rows = c.getmaxy(c.stdscr);
    cols = c.getmaxx(c.stdscr);
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
