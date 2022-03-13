// SPDX-FileCopyrightText: 2021-2022 Yoran Heling <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("ncdu", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addCSourceFile("src/ncurses_refs.c", &[_][]const u8{});
    exe.linkLibC();
    exe.linkSystemLibrary("ncursesw");
    exe.pie = true;
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tst = b.addTest("src/main.zig");
    tst.linkLibC();
    tst.linkSystemLibrary("ncursesw");
    tst.addCSourceFile("src/ncurses_refs.c", &[_][]const u8{});
    const tst_step = b.step("test", "Run tests");
    tst_step.dependOn(&tst.step);
}
