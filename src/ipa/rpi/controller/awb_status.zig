const std = @import("std");

pub const AwbStatus = struct {
    mode: [32]u8,
    temperatureK: f64,
    gainR: f64,
    gainG: f64,
    gainB: f64,
};
