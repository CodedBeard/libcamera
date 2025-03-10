const std = @import("std");

const CamHelper = @import("cam_helper.zig").CamHelper;
const RegisterCamHelper = @import("cam_helper.zig").RegisterCamHelper;

const CamHelperImx283 = struct {
    const frameIntegrationDiff: u32 = 4;

    pub fn new() CamHelperImx283 {
        return CamHelperImx283{};
    }

    pub fn gainCode(self: CamHelperImx283, gain: f64) u32 {
        return @intCast(u32, 2048.0 - 2048.0 / gain);
    }

    pub fn gain(self: CamHelperImx283, gainCode: u32) f64 {
        return 2048.0 / (2048 - gainCode);
    }

    pub fn hideFramesModeSwitch(self: CamHelperImx283) u32 {
        return 1;
    }
};

fn create() *CamHelper {
    return std.heap.page_allocator.create(CamHelperImx283) catch unreachable;
}

test "CamHelperImx283" {
    var helper = CamHelperImx283.new();
    try std.testing.expect(helper.gainCode(2.0) == 1024);
    try std.testing.expect(std.math.abs(helper.gain(1024) - 2.0) < 0.0001);
    try std.testing.expect(helper.hideFramesModeSwitch() == 1);
}

const reg = RegisterCamHelper{
    .camName = "imx283",
    .createFunc = create,
};
