const std = @import("std");

pub const AwbAlgorithm = struct {
    controller: *Controller,

    pub fn init(controller: *Controller) AwbAlgorithm {
        return AwbAlgorithm{ .controller = controller };
    }

    pub fn getConvergenceFrames(self: *AwbAlgorithm) u32 {
        return 0;
    }

    pub fn initialValues(self: *AwbAlgorithm, gainR: *f64, gainB: *f64) void {
    }

    pub fn setMode(self: *AwbAlgorithm, modeName: []const u8) void {
    }

    pub fn setManualGains(self: *AwbAlgorithm, manualR: f64, manualB: f64) void {
    }

    pub fn setColourTemperature(self: *AwbAlgorithm, temperatureK: f64) void {
    }

    pub fn enableAuto(self: *AwbAlgorithm) void {
    }

    pub fn disableAuto(self: *AwbAlgorithm) void {
    }
};

pub const AwbStatus = struct {
    mode: [32]u8,
    temperatureK: f64,
    gainR: f64,
    gainG: f64,
    gainB: f64,
};
