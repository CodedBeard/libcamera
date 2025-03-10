const std = @import("std");
const RPiController = @import("RPiController");

const CamHelper = RPiController.CamHelper;

const frameIntegrationDiff = 4;

const CamHelperOv5647 = struct {
    pub fn new() CamHelperOv5647 {
        return CamHelperOv5647{};
    }

    pub fn gainCode(self: CamHelperOv5647, gain: f64) u32 {
        return @intCast(u32, gain * 16.0);
    }

    pub fn gain(self: CamHelperOv5647, gainCode: u32) f64 {
        return @intToFloat(f64, gainCode) / 16.0;
    }

    pub fn hideFramesStartup(self: CamHelperOv5647) u32 {
        return 2;
    }

    pub fn hideFramesModeSwitch(self: CamHelperOv5647) u32 {
        return 2;
    }

    pub fn mistrustFramesStartup(self: CamHelperOv5647) u32 {
        return 2;
    }

    pub fn mistrustFramesModeSwitch(self: CamHelperOv5647) u32 {
        return 2;
    }
};

fn create() *CamHelper {
    return std.heap.page_allocator.create(CamHelperOv5647);
}

const reg = RPiController.RegisterCamHelper{
    .camName = "ov5647",
    .createFunc = create,
};
