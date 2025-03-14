const std = @import("std");
const RPiController = @import("RPiController");

const frameIntegrationDiff = 4;

const CamHelperOv7251 = struct {
    pub fn new() CamHelperOv7251 {
        return CamHelperOv7251{};
    }

    pub fn gainCode(self: CamHelperOv7251, gain: f64) u32 {
        return @intCast(u32, gain * 16.0);
    }

    pub fn gain(self: CamHelperOv7251, gainCode: u32) f64 {
        return @intToFloat(f64, gainCode) / 16.0;
    }
};

fn create() *CamHelper {
    return std.heap.page_allocator.create(CamHelperOv7251);
}

const reg = RPiController.RegisterCamHelper{
    .camName = "ov7251",
    .createFunc = create,
};
