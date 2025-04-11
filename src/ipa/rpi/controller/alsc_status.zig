const std = @import("std");

pub const AlscStatus = struct {
    r: std.ArrayList(f64),
    g: std.ArrayList(f64),
    b: std.ArrayList(f64),
    rows: u32,
    cols: u32,
};
