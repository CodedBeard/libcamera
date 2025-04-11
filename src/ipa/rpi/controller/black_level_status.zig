const std = @import("std");

pub const BlackLevelStatus = struct {
    blackLevelR: u16, // out of 16 bits
    blackLevelG: u16,
    blackLevelB: u16,
};
