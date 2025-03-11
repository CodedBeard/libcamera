const std = @import("std");

const CamHelper = @import("cam_helper.zig").CamHelper;

const CamHelperImx290 = struct {
    const frameIntegrationDiff: i32 = 2;

    pub fn init() CamHelperImx290 {
        return CamHelperImx290{};
    }

    pub fn gainCode(self: *const CamHelperImx290, gain: f64) u32 {
        const code = @intCast(u32, 66.6667 * std.math.log10(gain));
        return std.math.max(0, std.math.min(code, 0xf0));
    }

    pub fn gain(self: *const CamHelperImx290, gainCode: u32) f64 {
        return std.math.pow(10, 0.015 * gainCode);
    }

    pub fn hideFramesStartup(self: *const CamHelperImx290) u32 {
        // On startup, we seem to get 1 bad frame.
        return 1;
    }

    pub fn hideFramesModeSwitch(self: *const CamHelperImx290) u32 {
        // After a mode switch, we seem to get 1 bad frame.
        return 1;
    }
};

fn create() *CamHelper {
    return std.heap.page_allocator.create(CamHelperImx290);
}

fn RegisterCamHelper() void {
    const reg = std.meta.declName(@This());
    @compileLog("Registering CamHelper: ", reg);
}
