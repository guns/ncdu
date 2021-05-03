const std = @import("std");
const main = @import("main.zig");
const ui = @import("ui.zig");

pub fn draw() void {
    ui.style(.hd);
    _ = ui.c.mvhline(0, 0, ' ', ui.cols);
    _ = ui.c.mvaddstr(0, 0, "ncdu " ++ main.program_version ++ " ~ Use the arrow keys to navigate, press ");
    ui.style(.key_hd);
    _ = ui.c.addch('?');
    ui.style(.hd);
    _ = ui.c.addstr(" for help");
    // TODO: [imported]/[readonly] indicators

    ui.style(.default);
    _ = ui.c.mvhline(1, 0, ' ', ui.cols);
    // TODO: path

    ui.style(.hd);
    _ = ui.c.mvhline(ui.rows-1, 0, ' ', ui.cols);
    _ = ui.c.mvaddstr(ui.rows-1, 1, "No items to display.");
}
