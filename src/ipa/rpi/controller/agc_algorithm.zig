const std = @import("std");

pub const AgcAlgorithm = struct {
    controller: *Controller,

    pub fn init(controller: *Controller) AgcAlgorithm {
        return AgcAlgorithm{ .controller = controller };
    }

    pub fn getConvergenceFrames(self: *AgcAlgorithm) u32 {
        return 0;
    }

    pub fn getWeights(self: *AgcAlgorithm) []const f64 {
        return &[_]f64{};
    }

    pub fn setEv(self: *AgcAlgorithm, channel: u32, ev: f64) void {
    }

    pub fn setFlickerPeriod(self: *AgcAlgorithm, flickerPeriod: std.time.Duration) void {
    }

    pub fn setFixedExposureTime(self: *AgcAlgorithm, channel: u32, fixedExposureTime: std.time.Duration) void {
    }

    pub fn setMaxExposureTime(self: *AgcAlgorithm, maxExposureTime: std.time.Duration) void {
    }

    pub fn setFixedAnalogueGain(self: *AgcAlgorithm, channel: u32, fixedAnalogueGain: f64) void {
    }

    pub fn setMeteringMode(self: *AgcAlgorithm, meteringModeName: []const u8) void {
    }

    pub fn setExposureMode(self: *AgcAlgorithm, exposureModeName: []const u8) void {
    }

    pub fn setConstraintMode(self: *AgcAlgorithm, constraintModeName: []const u8) void {
    }

    pub fn enableAuto(self: *AgcAlgorithm) void {
    }

    pub fn disableAuto(self: *AgcAlgorithm) void {
    }

    pub fn setActiveChannels(self: *AgcAlgorithm, activeChannels: []const u32) void {
    }
};
