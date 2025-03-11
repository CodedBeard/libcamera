const std = @import("std");
const CamHelper = @import("cam_helper").CamHelper;
const RegisterCamHelper = @import("cam_helper").RegisterCamHelper;

const CamHelperOv7251 = struct {
    pub const frameIntegrationDiff: i32 = 4;

    pub fn init() CamHelperOv7251 {
        return CamHelperOv7251{};
    }

    pub fn gainCode(self: *const CamHelperOv7251, gain: f64) u32 {
        return @intCast(u32, gain * 16.0);
    }

    pub fn gain(self: *const CamHelperOv7251, gainCode: u32) f64 {
        return @intCast(f64, gainCode) / 16.0;
    }
};

fn create() *CamHelper {
    return std.heap.c_allocator.create(CamHelperOv7251).?;
}

test "CamHelperOv7251" {
    var helper = CamHelperOv7251.init();
    try std.testing.expect(helper.gainCode(2.0) == 32);
    try std.testing.expect(helper.gain(32) == 2.0);
}

RegisterCamHelper.register("ov7251", create);
