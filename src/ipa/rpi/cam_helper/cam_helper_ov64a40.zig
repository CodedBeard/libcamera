const std = @import("std");
const RPiController = @import("rpi_controller");

const CamHelper = RPiController.CamHelper;
const CameraMode = RPiController.CameraMode;
const RegisterCamHelper = RPiController.RegisterCamHelper;

const frameIntegrationDiff = 32;

const CamHelperOv64a40 = struct {
    pub fn new() CamHelperOv64a40 {
        return CamHelperOv64a40{};
    }

    pub fn gainCode(self: *const CamHelperOv64a40, gain: f64) u32 {
        return @intCast(u32, gain * 128.0);
    }

    pub fn gain(self: *const CamHelperOv64a40, gainCode: u32) f64 {
        return @intToFloat(f64, gainCode) / 128.0;
    }

    pub fn getModeSensitivity(self: *const CamHelperOv64a40, mode: CameraMode) f64 {
        if (mode.binX >= 2 and mode.scaleX >= 4) {
            return 4.0;
        } else if (mode.binX >= 2 and mode.scaleX >= 2) {
            return 2.0;
        } else {
            return 1.0;
        }
    }
};

fn create() *CamHelper {
    return std.heap.page_allocator.create(CamHelperOv64a40);
}

const reg = RegisterCamHelper{
    .camName = "ov64a40",
    .createFunc = create,
};
