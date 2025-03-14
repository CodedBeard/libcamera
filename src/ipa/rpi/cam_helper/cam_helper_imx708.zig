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

const CamHelperImx708 = struct {
    const frameIntegrationDiff: i32 = 48;
    const frameLengthMax: i32 = 0xffdc;
    const longExposureShiftMax: i32 = 7;
    const pdafStatsRows: u32 = 12;
    const pdafStatsCols: u32 = 16;

    fn init() CamHelperImx708 {
        return CamHelperImx708{};
    }

    fn gainCode(self: *const CamHelperImx708, gain: f64) u32 {
        return @intCast(u32, 1024 - 1024 / gain);
    }

    fn gain(self: *const CamHelperImx708, gainCode: u32) f64 {
        return 1024.0 / (1024 - gainCode);
    }

    fn prepare(self: *CamHelperImx708, buffer: []const u8, metadata: *Metadata) void {
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

    fn process(self: *CamHelperImx708, stats: *StatisticsPtr, metadata: *Metadata) void {
        if (self.aeHistValid) {
            self.putAGCStatistics(stats);
        }
    }

    fn getBlanking(self: *CamHelperImx708, exposure: *Duration, minFrameDuration: Duration, maxFrameDuration: Duration) !std.builtin.Pair(u32, u32) {
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

    fn sensorEmbeddedDataPresent(self: *CamHelperImx708) bool {
        return true;
    }

    fn getModeSensitivity(self: *CamHelperImx708, mode: CameraMode) f64 {
        return (mode.width > 2304) ? 1.0 : 2.0;
    }

    fn hideFramesModeSwitch(self: *CamHelperImx708) u32 {
        if (self.mode.width == 2304 and self.mode.height == 1296 and self.mode.minFrameDuration > 1.0s / 32) {
            return 1;
        } else {
            return 0;
        }
    }

    fn hideFramesStartup(self: *CamHelperImx708) u32 {
        return self.hideFramesModeSwitch();
    }

    fn populateMetadata(self: *CamHelperImx708, registers: MdParser.RegisterMap, metadata: *Metadata) void {
        var deviceStatus: DeviceStatus = undefined;

        deviceStatus.lineLength = self.lineLengthPckToDuration(registers.get(lineLengthHiReg) * 256 + registers.get(lineLengthLoReg));
        deviceStatus.exposureTime = self.exposure(registers.get(expHiReg) * 256 + registers.get(expLoReg), deviceStatus.lineLength);
        deviceStatus.analogueGain = self.gain(registers.get(gainHiReg) * 256 + registers.get(gainLoReg));
        deviceStatus.frameLength = registers.get(frameLengthHiReg) * 256 + registers.get(frameLengthLoReg);
        deviceStatus.sensorTemperature = std.math.clamp(registers.get(temperatureReg), -20, 80);

        metadata.set("device.status", &deviceStatus);
    }

    fn parsePdafData(self: *CamHelperImx708, ptr: []const u8, len: usize, bpp: u32, pdaf: *PdafRegions) bool {
        var step = bpp >> 1;

        if (bpp < 10 or bpp > 14 or len < 194 * step or ptr[0] != 0 or ptr[1] >= 0x40) {
            log.error("PDAF data in unsupported format");
            return false;
        }

        pdaf.init({ pdafStatsCols, pdafStatsRows });

        ptr += 2 * step;
        for (var i: u32 = 0; i < pdafStatsRows; i += 1) {
            for (var j: u32 = 0; j < pdafStatsCols; j += 1) {
                var c = (ptr[0] << 3) | (ptr[1] >> 5);
                var p = (((ptr[1] & 0x0F) - (ptr[1] & 0x10)) << 6) | (ptr[2] >> 2);
                var pdafData: PdafData = undefined;
                pdafData.conf = c;
                pdafData.phase = c ? p : 0;
                pdaf.set(libcamera.Point{ .x = j, .y = i }, { pdafData, 1, 0 });
                ptr += step;
            }
        }

        return true;
    }

    fn parseAEHist(self: *CamHelperImx708, ptr: []const u8, len: usize, bpp: u32) bool {
        const PipelineBits: u32 = Statistics.NormalisationFactorPow2;

        var count: u64 = 0;
        var sum: u64 = 0;
        var step = bpp >> 1;
        var hist: [128]u32 = undefined;

        if (len < 144 * step) {
            return false;
        }

        for (var i: u32 = 0; i < 128; i += 1) {
            if (ptr[3] != 0x55) {
                return false;
            }
            var c = (ptr[0] << 14) + (ptr[1] << 6) + (ptr[2] >> 2);
            hist[i] = c >> 2;
            if (i != 0) {
                count += c;
                sum += c * (i * (1 << (PipelineBits - 7)) + (1 << (PipelineBits - 8)));
            }
            ptr += step;
        }

        for (var i: u32 = 0; i < 9; i += 1) {
            if (ptr[3] != 0x55) {
                return false;
            }
            var c = (ptr[0] << 14) + (ptr[1] << 6) + (ptr[2] >> 2);
            count += c;
            sum += c * ((3 << PipelineBits) >> (17 - i));
            ptr += step;
        }

        if ((ptr[0] << 12) + (ptr[1] << 4) + (ptr[2] >> 4) != hist[1]) {
            log.error("Lin/Log histogram mismatch");
            return false;
        }

        self.aeHistLinear = Histogram(hist, 128);
        self.aeHistAverage = count ? (sum / count) : 0;

        return count != 0;
    }

    fn putAGCStatistics(self: *CamHelperImx708, stats: *StatisticsPtr) void {
        stats.yHist = self.aeHistLinear;

        const HdrHeadroomFactor: u32 = 4;
        var v = HdrHeadroomFactor * self.aeHistAverage;
        for (var region in stats.agcRegions) {
            region.val.rSum = region.val.gSum = region.val.bSum = region.counted * v;
        }
    }

    aeHistLinear: Histogram,
    aeHistAverage: u32,
    aeHistValid: bool,
};

fn create() *CamHelper {
    return CamHelperImx708.init();
}

const RegisterCamHelper = @import("register_cam_helper.zig");
RegisterCamHelper.register("imx708", create);
RegisterCamHelper.register("imx708_wide", create);
RegisterCamHelper.register("imx708_noir", create);
RegisterCamHelper.register("imx708_wide_noir", create);
