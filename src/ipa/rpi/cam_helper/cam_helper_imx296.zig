const std = @import("std");
const math = @import("std").math;

const Duration = std.time.Duration;

const CamHelper = @import("cam_helper.zig").CamHelper;
const RegisterCamHelper = @import("cam_helper.zig").RegisterCamHelper;

const minExposureLines: u32 = 1;
const maxGainCode: u32 = 239;
const timePerLine: Duration = std.time.ns_per_s * 550 / 37_125_000;

const frameIntegrationDiff: i32 = 4;

const CamHelperImx296 = struct {
    pub fn new() CamHelperImx296 {
        return CamHelperImx296{};
    }

    pub fn gainCode(self: *const CamHelperImx296, gain: f64) u32 {
        const code = @intCast(u32, 20 * math.log10(gain) * 10);
        return math.min(code, maxGainCode);
    }

    pub fn gain(self: *const CamHelperImx296, gainCode: u32) f64 {
        return math.pow(10.0, gainCode / 200.0);
    }

    pub fn exposureLines(self: *const CamHelperImx296, exposure: Duration, lineLength: Duration) u32 {
        return math.max(minExposureLines, @intCast(u32, (exposure - 14.26 * std.time.us_per_s) / timePerLine));
    }

    pub fn exposure(self: *const CamHelperImx296, exposureLines: u32, lineLength: Duration) Duration {
        return math.max(minExposureLines, exposureLines) * timePerLine + 14.26 * std.time.us_per_s;
    }
};

fn create() *CamHelper {
    return CamHelperImx296.new();
}

const reg = RegisterCamHelper{
    .camName = "imx296",
    .createFunc = create,
};
