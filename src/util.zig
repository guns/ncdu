// SPDX-FileCopyrightText: 2021 Yoran Heling <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn saturateAdd(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    std.debug.assert(@typeInfo(@TypeOf(a)).Int.signedness == .unsigned);
    return std.math.add(@TypeOf(a), a, b) catch std.math.maxInt(@TypeOf(a));
}

pub fn saturateSub(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    std.debug.assert(@typeInfo(@TypeOf(a)).Int.signedness == .unsigned);
    return std.math.sub(@TypeOf(a), a, b) catch std.math.minInt(@TypeOf(a));
}

// Cast any integer type to the target type, clamping the value to the supported maximum if necessary.
pub fn castClamp(comptime T: type, x: anytype) T {
    // (adapted from std.math.cast)
    if (std.math.maxInt(@TypeOf(x)) > std.math.maxInt(T) and x > std.math.maxInt(T)) {
        return std.math.maxInt(T);
    } else if (std.math.minInt(@TypeOf(x)) < std.math.minInt(T) and x < std.math.minInt(T)) {
        return std.math.minInt(T);
    } else {
        return @intCast(T, x);
    }
}

// Cast any integer type to the target type, truncating if necessary.
pub fn castTruncate(comptime T: type, x: anytype) T {
    const Ti = @typeInfo(T).Int;
    const Xi = @typeInfo(@TypeOf(x)).Int;
    const nx = if (Xi.signedness != Ti.signedness) @bitCast(std.meta.Int(Ti.signedness, Xi.bits), x) else x;
    return if (Xi.bits > Ti.bits) @truncate(T, nx) else nx;
}

// Multiplies by 512, saturating.
pub fn blocksToSize(b: u64) u64 {
    return if (b & 0xFF80000000000000 > 0) std.math.maxInt(u64) else b << 9;
}

// Ensure the given arraylist buffer gets zero-terminated and returns a slice
// into the buffer. The returned buffer is invalidated whenever the arraylist
// is freed or written to.
pub fn arrayListBufZ(buf: *std.ArrayList(u8)) [:0]const u8 {
    buf.append(0) catch unreachable;
    defer buf.items.len -= 1;
    return buf.items[0..buf.items.len-1:0];
}
