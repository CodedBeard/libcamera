const std = @import("std");
const RPiController = @import("RPiController");

const frameIntegrationDiff = 2;

const CamHelperImx290 = struct {
    pub fn new() CamHelperImx290 {
        return CamHelperImx290{};
    }

    pub fn gainCode(self: CamHelperImx290, gain: f64) u32 {
        return @intCast(u32, 66.6667 * std.math.log10(gain));
    }

    pub fn gain(self: CamHelperImx290, gainCode: u32) f64 {
        return std.math.pow(10, 0.015 * gainCode);
    }

    pub fn hideFramesStartup(self: CamHelperImx290) u32 {
        return 1;
    }

    pub fn hideFramesModeSwitch(self: CamHelperImx290) u32 {
        return 1;
    }
};

fn create() *RPiController.CamHelper {
    return std.heap.page_allocator.create(CamHelperImx290) catch unreachable;
}

const reg_imx290 = RPiController.RegisterCamHelper{
    .camName = "imx290",
    .createFunc = create,
};

const reg_imx327 = RPiController.RegisterCamHelper{
    .camName = "imx327",
    .createFunc = create,
};

const reg_imx462 = RPiController.RegisterCamHelper{
    .camName = "imx462",
    .createFunc = create,
};
