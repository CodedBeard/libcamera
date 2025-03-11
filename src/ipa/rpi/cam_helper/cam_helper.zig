const std = @import("std");
const linux = @import("linux");
const v4l2 = @import("libcamera.internal.v4l2_videodevice");
const MdParser = @import("md_parser");

const Duration = @import("libcamera.utils").Duration;
const Metadata = @import("metadata").Metadata;
const StatisticsPtr = @import("statistics").StatisticsPtr;
const CameraMode = @import("camera_mode").CameraMode;
const Controller = @import("controller").Controller;
const DeviceStatus = @import("device_status").DeviceStatus;

const IPARPI = @import("libcamera").IPARPI;

const CamHelper = struct {
    parser: ?*MdParser,
    frameIntegrationDiff: u32,
    mode: CameraMode,
    hwConfig: Controller.HardwareConfig,

    pub fn create(camName: []const u8) ?*CamHelper {
        for (p in camHelpers()) |helper| {
            if (std.mem.indexOf(u8, camName, helper.name) != null) {
                return helper.createFunc();
            }
        }
        return null;
    }

    pub fn init(parser: ?*MdParser, frameIntegrationDiff: u32) CamHelper {
        return CamHelper{
            .parser = parser,
            .frameIntegrationDiff = frameIntegrationDiff,
        };
    }

    pub fn deinit(self: *CamHelper) void {}

    pub fn prepare(self: *CamHelper, buffer: []const u8, metadata: *Metadata) void {
        self.parseEmbeddedData(buffer, metadata);
    }

    pub fn process(self: *CamHelper, stats: ?*StatisticsPtr, metadata: *Metadata) void {}

    pub fn exposureLines(self: *CamHelper, exposure: Duration, lineLength: Duration) u32 {
        return exposure / lineLength;
    }

    pub fn exposure(self: *CamHelper, exposureLines: u32, lineLength: Duration) Duration {
        return exposureLines * lineLength;
    }

    pub fn getBlanking(self: *CamHelper, exposure: *Duration, minFrameDuration: Duration, maxFrameDuration: Duration) !std.pair(u32, u32) {
        var frameLengthMin: u32 = minFrameDuration / self.mode.minLineLength;
        var frameLengthMax: u32 = maxFrameDuration / self.mode.minLineLength;
        var lineLength: Duration = self.mode.minLineLength;

        var exposureLines: u32 = std.math.min(self.exposureLines(*exposure, lineLength), std.math.maxInt(u32) - self.frameIntegrationDiff);
        var frameLengthLines: u32 = std.math.clamp(exposureLines + self.frameIntegrationDiff, frameLengthMin, frameLengthMax);

        if (frameLengthLines > self.mode.maxFrameLength) {
            var lineLengthAdjusted: Duration = lineLength * frameLengthLines / self.mode.maxFrameLength;
            lineLength = std.math.min(self.mode.maxLineLength, lineLengthAdjusted);
            frameLengthLines = self.mode.maxFrameLength;
        }

        var hblank: u32 = self.lineLengthToHblank(lineLength);
        var vblank: u32 = frameLengthLines - self.mode.height;

        exposureLines = std.math.min(frameLengthLines - self.frameIntegrationDiff, self.exposureLines(*exposure, lineLength));
        *exposure = self.exposure(exposureLines, lineLength);

        return std.pair(vblank, hblank);
    }

    pub fn hblankToLineLength(self: *CamHelper, hblank: u32) Duration {
        return (self.mode.width + hblank) * (1.0s / self.mode.pixelRate);
    }

    pub fn lineLengthToHblank(self: *CamHelper, lineLength: Duration) u32 {
        return (lineLength * self.mode.pixelRate / 1.0s) - self.mode.width;
    }

    pub fn lineLengthPckToDuration(self: *CamHelper, lineLengthPck: u32) Duration {
        return lineLengthPck * (1.0s / self.mode.pixelRate);
    }

    pub fn setCameraMode(self: *CamHelper, mode: CameraMode) void {
        self.mode = mode;
        if (self.parser) |parser| {
            parser.reset();
            parser.setBitsPerPixel(mode.bitdepth);
            parser.setLineLengthBytes(0);
        }
    }

    pub fn setHwConfig(self: *CamHelper, hwConfig: Controller.HardwareConfig) void {
        self.hwConfig = hwConfig;
    }

    pub fn sensorEmbeddedDataPresent(self: *CamHelper) bool {
        return false;
    }

    pub fn getModeSensitivity(self: *CamHelper, mode: CameraMode) f64 {
        return 1.0;
    }

    pub fn hideFramesStartup(self: *CamHelper) u32 {
        return 0;
    }

    pub fn hideFramesModeSwitch(self: *CamHelper) u32 {
        return 0;
    }

    pub fn mistrustFramesStartup(self: *CamHelper) u32 {
        return 1;
    }

    pub fn mistrustFramesModeSwitch(self: *CamHelper) u32 {
        return 0;
    }

    pub fn parseEmbeddedData(self: *CamHelper, buffer: []const u8, metadata: *Metadata) void {
        var registers: MdParser.RegisterMap = MdParser.RegisterMap.init();
        var parsedMetadata: Metadata = Metadata.init();

        if (buffer.len == 0) return;

        if (self.parser) |parser| {
            if (parser.parse(buffer, &registers) != MdParser.Status.OK) {
                IPARPI.error("Embedded data buffer parsing failed");
                return;
            }
        }

        self.populateMetadata(registers, &parsedMetadata);
        metadata.merge(parsedMetadata);

        var deviceStatus: DeviceStatus = DeviceStatus.init();
        var parsedDeviceStatus: DeviceStatus = DeviceStatus.init();
        if (metadata.get("device.status", &deviceStatus) || parsedMetadata.get("device.status", &parsedDeviceStatus)) {
            IPARPI.error("DeviceStatus not found");
            return;
        }

        deviceStatus.exposureTime = parsedDeviceStatus.exposureTime;
        deviceStatus.analogueGain = parsedDeviceStatus.analogueGain;
        deviceStatus.frameLength = parsedDeviceStatus.frameLength;
        deviceStatus.lineLength = parsedDeviceStatus.lineLength;
        if (parsedDeviceStatus.sensorTemperature) |sensorTemperature| {
            deviceStatus.sensorTemperature = sensorTemperature;
        }

        IPARPI.debug("Metadata updated - {}", deviceStatus);

        metadata.set("device.status", deviceStatus);
    }

    pub fn populateMetadata(self: *CamHelper, registers: MdParser.RegisterMap, metadata: *Metadata) void {}

    pub fn camHelpers() []CamHelper {
        return &[_]CamHelper{
            CamHelper{
                .name = "imx290",
                .createFunc = createImx290,
            },
            CamHelper{
                .name = "imx415",
                .createFunc = createImx415,
            },
            CamHelper{
                .name = "imx708",
                .createFunc = createImx708,
            },
            CamHelper{
                .name = "ov7251",
                .createFunc = createOv7251,
            },
        };
    }
};

fn createImx290() *CamHelper {
    return CamHelper.init(null, 2);
}

fn createImx415() *CamHelper {
    return CamHelper.init(null, 8);
}

fn createImx708() *CamHelper {
    return CamHelper.init(null, 48);
}

fn createOv7251() *CamHelper {
    return CamHelper.init(null, 4);
}
