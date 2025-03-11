const std = @import("std");

const CamHelper = @import("cam_helper.zig").CamHelper;
const RegisterCamHelper = @import("cam_helper.zig").RegisterCamHelper;

const CamHelperImx415 = struct {
    pub const frameIntegrationDiff = 8;

    pub fn init() CamHelperImx415 {
        return CamHelperImx415{};
    }

    pub fn gainCode(self: *CamHelperImx415, gain: f64) u32 {
        const code = @intCast(u32, 66.6667 * std.math.log10(gain));
        return std.math.max(0, std.math.min(code, 0xf0));
    }

    pub fn gain(self: *CamHelperImx415, gainCode: u32) f64 {
        return std.math.pow(10, 0.015 * gainCode);
    }

    pub fn hideFramesStartup(self: *CamHelperImx415) u32 {
        // On startup, we seem to get 1 bad frame.
        return 1;
    }

    pub fn hideFramesModeSwitch(self: *CamHelperImx415) u32 {
        // After a mode switch, we seem to get 1 bad frame.
        return 1;
    }
};

fn create() *CamHelper {
    return CamHelperImx415.init();
}

test "RegisterCamHelper" {
    const reg = RegisterCamHelper.init("imx415", create);
}
