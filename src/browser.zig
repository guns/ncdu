const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");

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
    // TODO: [imported]/[readonly] indicators

    ui.style(.default);
    ui.move(1,0);
    ui.hline('-', ui.cols);
    ui.move(1,3);
    ui.addch(' ');
    ui.addstr(try ui.shorten(try ui.toUtf8(model.root.entry.name()), std.math.sub(u32, ui.cols, 5) catch 4));
    ui.addch(' ');

    ui.style(.hd);
    ui.move(ui.rows-1, 0);
    ui.hline(' ', ui.cols);
    ui.move(ui.rows-1, 1);
    ui.addstr("No items to display.");
}
