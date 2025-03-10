const std = @import("std");
const assert = std.debug.assert;

const RPiController = @import("RPiController");

const gainReg: u32 = 0x157;
const expHiReg: u32 = 0x15a;
const expLoReg: u32 = 0x15b;
const frameLengthHiReg: u32 = 0x160;
const frameLengthLoReg: u32 = 0x161;
const lineLengthHiReg: u32 = 0x162;
const lineLengthLoReg: u32 = 0x163;

const registerList = [_]u32{ expHiReg, expLoReg, gainReg, frameLengthHiReg, frameLengthLoReg, lineLengthHiReg, lineLengthLoReg };

const frameIntegrationDiff: i32 = 4;

const CamHelperImx219 = struct {
    base: RPiController.CamHelper,

    pub fn new() CamHelperImx219 {
        return CamHelperImx219{
            .base = RPiController.CamHelper.init(),
        };
    }

    pub fn gainCode(self: *const CamHelperImx219, gain: f64) u32 {
        return @intCast(u32, 256 - 256 / gain);
    }

    pub fn gain(self: *const CamHelperImx219, gainCode: u32) f64 {
        return 256.0 / (256 - gainCode);
    }

    pub fn mistrustFramesModeSwitch(self: *const CamHelperImx219) u32 {
        return 1;
    }

    pub fn sensorEmbeddedDataPresent(self: *const CamHelperImx219) bool {
        return false;
    }

    pub fn populateMetadata(self: *const CamHelperImx219, registers: RPiController.MdParser.RegisterMap, metadata: *RPiController.Metadata) void {
        var deviceStatus = RPiController.DeviceStatus{};
        deviceStatus.lineLength = self.base.lineLengthPckToDuration(registers.get(lineLengthHiReg) * 256 + registers.get(lineLengthLoReg));
        deviceStatus.exposureTime = self.base.exposure(registers.get(expHiReg) * 256 + registers.get(expLoReg), deviceStatus.lineLength);
        deviceStatus.analogueGain = self.gain(registers.get(gainReg));
        deviceStatus.frameLength = registers.get(frameLengthHiReg) * 256 + registers.get(frameLengthLoReg);

        metadata.set("device.status", deviceStatus);
    }
};

fn create() *RPiController.CamHelper {
    return CamHelperImx219.new();
}

const reg = RPiController.RegisterCamHelper{
    .camName = "imx219",
    .createFunc = create,
};
