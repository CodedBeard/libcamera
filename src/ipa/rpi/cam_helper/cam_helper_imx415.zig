const std = @import("std");
const RPiController = @import("RPiController");

const CamHelper = RPiController.CamHelper;

const frameIntegrationDiff = 8;

const CamHelperImx415 = struct {
    pub fn new() CamHelperImx415 {
        return CamHelperImx415{};
    }

    pub fn gainCode(self: CamHelperImx415, gain: f64) u32 {
        const code = @intCast(u32, 66.6667 * std.math.log10(gain));
        return std.math.clamp(code, 0, 0xf0);
    }

    pub fn gain(self: CamHelperImx415, gainCode: u32) f64 {
        return std.math.pow(10, 0.015 * gainCode);
    }

    pub fn hideFramesStartup(self: CamHelperImx415) u32 {
        return 1;
    }

    pub fn hideFramesModeSwitch(self: CamHelperImx415) u32 {
        return 1;
    }
};

fn create() *CamHelper {
    return std.heap.page_allocator.create(CamHelperImx415) catch unreachable;
}

const reg = RPiController.RegisterCamHelper{
    .camName = "imx415",
    .createFunc = create,
};
