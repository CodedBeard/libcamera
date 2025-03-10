const std = @import("std");
const log = @import("log");

const gainReg = 0x0204;
const expHiReg = 0x0202;
const expLoReg = 0x0203;
const gainHiReg = 0x0204;
const gainLoReg = 0x0205;
const frameLengthHiReg = 0x0340;
const frameLengthLoReg = 0x0341;
const lineLengthHiReg = 0x0342;
const lineLengthLoReg = 0x0343;
const registerList = [_]u32{expHiReg, expLoReg, gainHiReg, gainLoReg, frameLengthHiReg, frameLengthLoReg, lineLengthHiReg, lineLengthLoReg};

const CamHelper = @import("cam_helper.zig").CamHelper;
const MdParser = @import("md_parser.zig").MdParser;
const Metadata = @import("metadata.zig").Metadata;
const DeviceStatus = @import("device_status.zig").DeviceStatus;

const CamHelperImx519 = struct {
    const frameIntegrationDiff = 32;
    const frameLengthMax = 0xffdc;
    const longExposureShiftMax = 7;

    fn init() CamHelperImx519 {
        return CamHelperImx519{
            .base = CamHelper.init(std.heap.page_allocator, registerList, frameIntegrationDiff),
        };
    }

    fn gainCode(self: *CamHelperImx519, gain: f64) u32 {
        return @intCast(u32, 1024 - 1024 / gain);
    }

    fn gain(self: *CamHelperImx519, gainCode: u32) f64 {
        return 1024.0 / (1024 - gainCode);
    }

    fn prepare(self: *CamHelperImx519, buffer: []const u8, metadata: *Metadata) void {
        var deviceStatus: DeviceStatus = undefined;

        if (metadata.get("device.status", &deviceStatus)) {
            log.error("DeviceStatus not found from DelayedControls");
            return;
        }

        self.base.parseEmbeddedData(buffer, metadata);

        if (deviceStatus.frameLength > frameLengthMax) {
            var parsedDeviceStatus: DeviceStatus = undefined;

            metadata.get("device.status", &parsedDeviceStatus);
            parsedDeviceStatus.exposureTime = deviceStatus.exposureTime;
            parsedDeviceStatus.frameLength = deviceStatus.frameLength;
            metadata.set("device.status", &parsedDeviceStatus);

            log.debug("Metadata updated for long exposure: {}", .{parsedDeviceStatus});
        }
    }

    fn getBlanking(self: *CamHelperImx519, exposure: *Duration, minFrameDuration: Duration, maxFrameDuration: Duration) !std.builtin.Pair(u32, u32) {
        var frameLength: u32 = undefined;
        var exposureLines: u32 = undefined;
        var shift: u32 = 0;

        var blanking = self.base.getBlanking(exposure, minFrameDuration, maxFrameDuration);
        frameLength = self.base.mode.height + blanking.first;
        var lineLength = self.base.hblankToLineLength(blanking.second);

        while (frameLength > frameLengthMax) {
            if (shift += 1 > longExposureShiftMax) {
                shift = longExposureShiftMax;
                frameLength = frameLengthMax;
                break;
            }
            frameLength >>= 1;
        }

        if (shift != 0) {
            frameLength <<= shift;
            exposureLines = self.base.exposureLines(*exposure, lineLength);
            exposureLines = std.math.min(exposureLines, frameLength - frameIntegrationDiff);
            *exposure = self.base.exposure(exposureLines, lineLength);
        }

        return std.builtin.Pair(u32, u32){ .first = frameLength - self.base.mode.height, .second = blanking.second };
    }

    fn sensorEmbeddedDataPresent(self: *CamHelperImx519) bool {
        return true;
    }

    fn populateMetadata(self: *CamHelperImx519, registers: MdParser.RegisterMap, metadata: *Metadata) void {
        var deviceStatus: DeviceStatus = undefined;

        deviceStatus.lineLength = self.base.lineLengthPckToDuration(registers.get(lineLengthHiReg) * 256 + registers.get(lineLengthLoReg));
        deviceStatus.exposureTime = self.base.exposure(registers.get(expHiReg) * 256 + registers.get(expLoReg), deviceStatus.lineLength);
        deviceStatus.analogueGain = self.gain(registers.get(gainHiReg) * 256 + registers.get(gainLoReg));
        deviceStatus.frameLength = registers.get(frameLengthHiReg) * 256 + registers.get(frameLengthLoReg);

        metadata.set("device.status", &deviceStatus);
    }
};

fn create() *CamHelper {
    return std.heap.page_allocator.create(CamHelperImx519).?;
}

test "CamHelperImx519" {
    var helper = CamHelperImx519.init();
    defer helper.deinit();

    // Add your test cases here
}
