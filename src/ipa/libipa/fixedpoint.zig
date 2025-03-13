const std = @import("std");

pub fn floatingToFixedPoint(comptime I: u32, comptime F: u32, number: f64) u32 {
    const mask = (1 << (F + I)) - 1;
    const frac = @intCast(u32, @intCast(i32, std.math.round(number * (1 << F)))) & mask;
    return frac;
}

pub fn fixedToFloatingPoint(comptime I: u32, comptime F: u32, number: u32) f64 {
    const remaining_bits = @sizeOf(i32) * 8 - (I + F);
    const t = @intCast(i32, @intCast(u32, number) << remaining_bits) >> remaining_bits;
    return @intToFloat(f64, t) / @intToFloat(f64, 1 << F);
}
