const std = @import("std");

pub const DenoiseMode = enum {
    Off,
    ColourOff,
    ColourFast,
    ColourHighQuality,
};

pub const DenoiseAlgorithm = struct {
    controller: *Controller,

    pub fn init(controller: *Controller) DenoiseAlgorithm {
        return DenoiseAlgorithm{ .controller = controller };
    }

    pub fn setMode(self: *DenoiseAlgorithm, mode: DenoiseMode) void {
        // Implementation here
    }

    pub fn setConfig(self: *DenoiseAlgorithm, name: []const u8) void {
        // Implementation here
    }
};
