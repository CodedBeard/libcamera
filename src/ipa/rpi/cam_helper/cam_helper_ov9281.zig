const std = @import("std");
const RPiController = @import("RPiController");

const frameIntegrationDiff = 25;

const CamHelperOv9281 = struct {
    pub fn new() CamHelperOv9281 {
        return CamHelperOv9281{};
    }

    pub fn gainCode(self: CamHelperOv9281, gain: f64) u32 {
        return @intCast(u32, gain * 16.0);
    }

    pub fn gain(self: CamHelperOv9281, gainCode: u32) f64 {
        return @intCast(f64, gainCode) / 16.0;
    }
};

pub fn create() *CamHelper {
    return CamHelperOv9281.new();
}

pub fn register() void {
    RPiController.camHelpers().put("ov9281", create);
}
