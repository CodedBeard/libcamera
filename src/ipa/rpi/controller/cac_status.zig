const std = @import("std");

pub const CacStatus = struct {
    lutRx: std.ArrayList(f64),
    lutRy: std.ArrayList(f64),
    lutBx: std.ArrayList(f64),
    lutBy: std.ArrayList(f64),
};
