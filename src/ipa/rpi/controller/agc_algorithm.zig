const std = @import("std");
const libcamera = @import("libcamera");
const Algorithm = @import("algorithm");
const HdrStatus = @import("hdr_status");

pub const AgcAlgorithm = struct {
    algorithm: Algorithm,

    pub fn init(controller: *Controller) AgcAlgorithm {
        return AgcAlgorithm{ .algorithm = Algorithm.init(controller) };
    }

    pub fn getConvergenceFrames(self: *AgcAlgorithm) u32 {
        return 0;
    }

    pub fn getWeights(self: *AgcAlgorithm) []const f64 {
        return &[_]f64{};
    }

    pub fn setEv(self: *AgcAlgorithm, channel: u32, ev: f64) void {}

    pub fn setFlickerPeriod(self: *AgcAlgorithm, flickerPeriod: libcamera.utils.Duration) void {}

    pub fn setFixedExposureTime(self: *AgcAlgorithm, channel: u32, fixedExposureTime: libcamera.utils.Duration) void {}

    pub fn setMaxExposureTime(self: *AgcAlgorithm, maxExposureTime: libcamera.utils.Duration) void {}

    pub fn setFixedAnalogueGain(self: *AgcAlgorithm, channel: u32, fixedAnalogueGain: f64) void {}

    pub fn setMeteringMode(self: *AgcAlgorithm, meteringModeName: []const u8) void {}

    pub fn setExposureMode(self: *AgcAlgorithm, exposureModeName: []const u8) void {}

    pub fn setConstraintMode(self: *AgcAlgorithm, constraintModeName: []const u8) void {}

    pub fn enableAuto(self: *AgcAlgorithm) void {}

    pub fn disableAuto(self: *AgcAlgorithm) void {}

    pub fn setActiveChannels(self: *AgcAlgorithm, activeChannels: []const u32) void {}
};

pub const AgcStatus = struct {
    totalExposureValue: libcamera.utils.Duration,
    targetExposureValue: libcamera.utils.Duration,
    exposureTime: libcamera.utils.Duration,
    analogueGain: f64,
    exposureMode: []const u8,
    constraintMode: []const u8,
    meteringMode: []const u8,
    ev: f64,
    flickerPeriod: libcamera.utils.Duration,
    floatingRegionEnable: i32,
    fixedExposureTime: libcamera.utils.Duration,
    fixedAnalogueGain: f64,
    channel: u32,
    hdr: HdrStatus,
};

pub const AgcPrepareStatus = struct {
    digitalGain: f64,
    locked: i32,
};
