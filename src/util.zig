const std = @import("std");

pub fn saturateAdd(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    std.debug.assert(@typeInfo(@TypeOf(a)).Int.signedness == .unsigned);
    return std.math.add(@TypeOf(a), a, b) catch std.math.maxInt(@TypeOf(a));
}

pub fn saturateSub(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    std.debug.assert(@typeInfo(@TypeOf(a)).Int.signedness == .unsigned);
    return std.math.sub(@TypeOf(a), a, b) catch std.math.minInt(@TypeOf(a));
}

// Multiplies by 512, saturating.
pub fn blocksToSize(b: u64) u64 {
    return if (b & 0xFF80000000000000 > 0) std.math.maxInt(u64) else b << 9;
}
