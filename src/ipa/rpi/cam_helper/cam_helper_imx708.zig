const std = @import("std");
const libcamera = @import("libcamera");
const RPiController = @import("RPiController");
const MdParser = @import("md_parser");

const expHiReg = 0x0202;
const expLoReg = 0x0203;
const gainHiReg = 0x0204;
const gainLoReg = 0x0205;
const frameLengthHiReg = 0x0340;
const frameLengthLoReg = 0x0341;
const lineLengthHiReg = 0x0342;
const lineLengthLoReg = 0x0343;
const temperatureReg = 0x013a;
const registerList = [_]u32{ expHiReg, expLoReg, gainHiReg, gainLoReg, lineLengthHiReg, lineLengthLoReg, frameLengthHiReg, frameLengthLoReg, temperatureReg };

const frameIntegrationDiff = 48;
const frameLengthMax = 0xffdc;
const longExposureShiftMax = 7;
const pdafStatsRows = 12;
const pdafStatsCols = 16;

const CamHelperImx708 = struct {
    base: RPiController.CamHelper,
    aeHistLinear: RPiController.Histogram,
    aeHistAverage: u32,
    aeHistValid: bool,

    pub fn init() CamHelperImx708 {
        return CamHelperImx708{
            .base = RPiController.CamHelper.init(std.heap.page_allocator, registerList, frameIntegrationDiff),
            .aeHistLinear = RPiController.Histogram.init(),
            .aeHistAverage = 0,
            .aeHistValid = false,
        };
    }

    pub fn gainCode(self: *const CamHelperImx708, gain: f64) u32 {
        return @intCast(u32, 1024 - 1024 / gain);
    }

    pub fn gain(self: *const CamHelperImx708, gain_code: u32) f64 {
        return 1024.0 / (1024 - gain_code);
    }

    pub fn prepare(self: *CamHelperImx708, buffer: []const u8, metadata: *libcamera.Metadata) void {
        var registers = MdParser.RegisterMap.init(std.heap.page_allocator);
        var deviceStatus = RPiController.DeviceStatus.init();

        if (metadata.get("device.status", &deviceStatus) != 0) {
            std.log.err("DeviceStatus not found from DelayedControls", .{});
            return;
        }

        self.base.parseEmbeddedData(buffer, metadata);

        const bytesPerLine = (self.base.mode.width * self.base.mode.bitdepth) >> 3;

        if (buffer.len > 2 * bytesPerLine) {
            var pdaf = RPiController.PdafRegions.init();
            if (self.parsePdafData(&buffer[2 * bytesPerLine], buffer.len - 2 * bytesPerLine, self.base.mode.bitdepth, &pdaf)) {
                metadata.set("pdaf.regions", &pdaf);
            }
        }

        if (buffer.len > 3 * bytesPerLine) {
            self.aeHistValid = self.parseAEHist(&buffer[3 * bytesPerLine], buffer.len - 3 * bytesPerLine, self.base.mode.bitdepth);
        }

        if (deviceStatus.frameLength > frameLengthMax) {
            var parsedDeviceStatus = RPiController.DeviceStatus.init();
            metadata.get("device.status", &parsedDeviceStatus);
            parsedDeviceStatus.exposureTime = deviceStatus.exposureTime;
            parsedDeviceStatus.frameLength = deviceStatus.frameLength;
            metadata.set("device.status", &parsedDeviceStatus);
        }
    }

    pub fn process(self: *CamHelperImx708, stats: *RPiController.StatisticsPtr, metadata: *libcamera.Metadata) void {
        if (self.aeHistValid) {
            self.putAGCStatistics(stats);
        }
    }

    pub fn getBlanking(self: *const CamHelperImx708, exposure: *libcamera.Duration, minFrameDuration: libcamera.Duration, maxFrameDuration: libcamera.Duration) !std.pair.Pair(u32, u32) {
        var frameLength: u32 = 0;
        var exposureLines: u32 = 0;
        var shift: u32 = 0;

        var blanking = self.base.getBlanking(exposure, minFrameDuration, maxFrameDuration) catch return error.Invalid;
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

        return std.pair.Pair(u32, u32){ .first = frameLength - self.base.mode.height, .second = blanking.second };
    }

    pub fn sensorEmbeddedDataPresent(self: *const CamHelperImx708) bool {
        return true;
    }

    pub fn getModeSensitivity(self: *const CamHelperImx708, mode: *const RPiController.CameraMode) f64 {
        return if (mode.width > 2304) 1.0 else 2.0;
    }

    pub fn hideFramesModeSwitch(self: *const CamHelperImx708) u32 {
        if (self.base.mode.width == 2304 and self.base.mode.height == 1296 and self.base.mode.minFrameDuration > 1.0 / 32) {
            return 1;
        } else {
            return 0;
        }
    }

    pub fn hideFramesStartup(self: *const CamHelperImx708) u32 {
        return self.hideFramesModeSwitch();
    }

    pub fn populateMetadata(self: *const CamHelperImx708, registers: *const MdParser.RegisterMap, metadata: *libcamera.Metadata) void {
        var deviceStatus = RPiController.DeviceStatus.init();

        deviceStatus.lineLength = self.base.lineLengthPckToDuration(registers.get(lineLengthHiReg) * 256 + registers.get(lineLengthLoReg));
        deviceStatus.exposureTime = self.base.exposure(registers.get(expHiReg) * 256 + registers.get(expLoReg), deviceStatus.lineLength);
        deviceStatus.analogueGain = self.gain(registers.get(gainHiReg) * 256 + registers.get(gainLoReg));
        deviceStatus.frameLength = registers.get(frameLengthHiReg) * 256 + registers.get(frameLengthLoReg);
        deviceStatus.sensorTemperature = std.math.clamp(@intCast(i8, registers.get(temperatureReg)), -20, 80);

        metadata.set("device.status", &deviceStatus);
    }

    pub fn parsePdafData(self: *const CamHelperImx708, ptr: []const u8, len: usize, bpp: u32, pdaf: *RPiController.PdafRegions) bool {
        const step = bpp >> 1;

        if (bpp < 10 or bpp > 14 or len < 194 * step or ptr[0] != 0 or ptr[1] >= 0x40) {
            std.log.err("PDAF data in unsupported format", .{});
            return false;
        }

        pdaf.init(pdafStatsCols, pdafStatsRows);

        ptr += 2 * step;
        for (var i: u32 = 0; i < pdafStatsRows; ++i) {
            for (var j: u32 = 0; j < pdafStatsCols; ++j) {
                const c = (ptr[0] << 3) | (ptr[1] >> 5);
                const p = (((ptr[1] & 0x0F) - (ptr[1] & 0x10)) << 6) | (ptr[2] >> 2);
                var pdafData = RPiController.PdafData.init();
                pdafData.conf = c;
                pdafData.phase = c != 0 ? p : 0;
                pdaf.set(libcamera.Point.init(j, i), RPiController.PdafDataRegion{ .data = pdafData, .count = 1, .reserved = 0 });
                ptr += step;
            }
        }

        return true;
    }

    pub fn parseAEHist(self: *CamHelperImx708, ptr: []const u8, len: usize, bpp: u32) bool {
        const PipelineBits = RPiController.Statistics.NormalisationFactorPow2;

        var count: u64 = 0;
        var sum: u64 = 0;
        const step = bpp >> 1;
        var hist: [128]u32 = undefined;

        if (len < 144 * step) {
            return false;
        }

        for (var i: u32 = 0; i < 128; ++i) {
            if (ptr[3] != 0x55) {
                return false;
            }
            const c = (ptr[0] << 14) + (ptr[1] << 6) + (ptr[2] >> 2);
            hist[i] = c >> 2;
            if (i != 0) {
                count += c;
                sum += c * (i * (1 << (PipelineBits - 7)) + (1 << (PipelineBits - 8)));
            }
            ptr += step;
        }

        for (var i: u32 = 0; i < 9; ++i) {
            if (ptr[3] != 0x55) {
                return false;
            }
            const c = (ptr[0] << 14) + (ptr[1] << 6) + (ptr[2] >> 2);
            count += c;
            sum += c * ((3 << PipelineBits) >> (17 - i));
            ptr += step;
        }

        if ((ptr[0] << 12) + (ptr[1] << 4) + (ptr[2] >> 4) != hist[1]) {
            std.log.err("Lin/Log histogram mismatch", .{});
            return false;
        }

        self.aeHistLinear = RPiController.Histogram.initWithData(hist[0..128], 128);
        self.aeHistAverage = count != 0 ? @intCast(u32, sum / count) : 0;

        return count != 0;
    }

    pub fn putAGCStatistics(self: *CamHelperImx708, stats: *RPiController.StatisticsPtr) void {
        stats.yHist = self.aeHistLinear;

        const HdrHeadroomFactor = 4;
        const v = HdrHeadroomFactor * self.aeHistAverage;
        for (stats.agcRegions.items) |*region| {
            region.val.rSum = region.val.gSum = region.val.bSum = region.counted * v;
        }
    }
};

pub fn create() *RPiController.CamHelper {
    return CamHelperImx708.init();
}

pub fn register() void {
    RPiController.RegisterCamHelper("imx708", create);
    RPiController.RegisterCamHelper("imx708_wide", create);
    RPiController.RegisterCamHelper("imx708_noir", create);
    RPiController.RegisterCamHelper("imx708_wide_noir", create);
}

register();
