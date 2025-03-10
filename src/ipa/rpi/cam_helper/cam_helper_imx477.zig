const std = @import("std");
const log = @import("log");
const Duration = @import("duration");

const expHiReg: u32 = 0x0202;
const expLoReg: u32 = 0x0203;
const gainHiReg: u32 = 0x0204;
const gainLoReg: u32 = 0x0205;
const frameLengthHiReg: u32 = 0x0340;
const frameLengthLoReg: u32 = 0x0341;
const lineLengthHiReg: u32 = 0x0342;
const lineLengthLoReg: u32 = 0x0343;
const temperatureReg: u32 = 0x013a;
const registerList = [_]u32{ expHiReg, expLoReg, gainHiReg, gainLoReg, frameLengthHiReg, frameLengthLoReg, lineLengthHiReg, lineLengthLoReg, temperatureReg };

const CamHelper = @import("cam_helper.zig");
const MdParser = @import("md_parser.zig");

const CamHelperImx477 = struct {
    const frameIntegrationDiff: i32 = 22;
    const frameLengthMax: i32 = 0xffdc;
    const longExposureShiftMax: i32 = 7;

    fn init() CamHelperImx477 {
        return CamHelperImx477{};
    }

    fn gainCode(self: *const CamHelperImx477, gain: f64) u32 {
        return @intCast(u32, 1024 - 1024 / gain);
    }

    fn gain(self: *const CamHelperImx477, gainCode: u32) f64 {
        return 1024.0 / (1024 - gainCode);
    }

    fn prepare(self: *CamHelperImx477, buffer: []const u8, metadata: *Metadata) void {
        var registers: MdParser.RegisterMap = undefined;
        var deviceStatus: DeviceStatus = undefined;

        if (metadata.get("device.status", &deviceStatus)) {
            log.error("DeviceStatus not found from DelayedControls");
            return;
        }

        self.parseEmbeddedData(buffer, metadata);

        if (deviceStatus.frameLength > frameLengthMax) {
            var parsedDeviceStatus: DeviceStatus = undefined;

            metadata.get("device.status", &parsedDeviceStatus);
            parsedDeviceStatus.exposureTime = deviceStatus.exposureTime;
            parsedDeviceStatus.frameLength = deviceStatus.frameLength;
            metadata.set("device.status", &parsedDeviceStatus);

            log.debug("Metadata updated for long exposure: {}", .{parsedDeviceStatus});
        }
    }

    fn getBlanking(self: *const CamHelperImx477, exposure: *Duration, minFrameDuration: Duration, maxFrameDuration: Duration) !std.builtin.Pair(u32, u32) {
        var frameLength: u32 = 0;
        var exposureLines: u32 = 0;
        var shift: u32 = 0;

        var blanking = try CamHelper.getBlanking(self, exposure, minFrameDuration, maxFrameDuration);
        var vblank = blanking.first;
        var hblank = blanking.second;

        frameLength = self.mode.height + vblank;
        var lineLength = self.hblankToLineLength(hblank);

        while (frameLength > frameLengthMax) {
            if (++shift > longExposureShiftMax) {
                shift = longExposureShiftMax;
                frameLength = frameLengthMax;
                break;
            }
            frameLength >>= 1;
        }

        if (shift != 0) {
            frameLength <<= shift;
            exposureLines = self.exposureLines(*exposure, lineLength);
            exposureLines = std.math.min(exposureLines, frameLength - frameIntegrationDiff);
            *exposure = self.exposure(exposureLines, lineLength);
        }

        return std.builtin.Pair(u32, u32){ .first = frameLength - self.mode.height, .second = hblank };
    }

    fn sensorEmbeddedDataPresent(self: *const CamHelperImx477) bool {
        return true;
    }

    fn populateMetadata(self: *const CamHelperImx477, registers: MdParser.RegisterMap, metadata: *Metadata) void {
        var deviceStatus: DeviceStatus = undefined;

        deviceStatus.lineLength = self.lineLengthPckToDuration(registers.get(lineLengthHiReg) * 256 + registers.get(lineLengthLoReg));
        deviceStatus.exposureTime = self.exposure(registers.get(expHiReg) * 256 + registers.get(expLoReg), deviceStatus.lineLength);
        deviceStatus.analogueGain = self.gain(registers.get(gainHiReg) * 256 + registers.get(gainLoReg));
        deviceStatus.frameLength = registers.get(frameLengthHiReg) * 256 + registers.get(frameLengthLoReg);
        deviceStatus.sensorTemperature = std.math.clamp(registers.get(temperatureReg), -20, 80);

        metadata.set("device.status", &deviceStatus);
    }
};

fn create() *CamHelper {
    return CamHelperImx477.init();
}

const RegisterCamHelper = @import("register_cam_helper.zig");
RegisterCamHelper.register("imx477", create);
