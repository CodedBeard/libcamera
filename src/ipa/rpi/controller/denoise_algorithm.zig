const std = @import("std");

const DenoiseMode = enum {
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
        // To be implemented by the specific algorithm
    }

    pub fn setConfig(self: *DenoiseAlgorithm, name: []const u8) void {
        // Default implementation, can be overridden by specific algorithms
    }
};
