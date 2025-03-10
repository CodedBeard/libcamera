const std = @import("std");
const linux = @import("linux");
const libcamera = @import("libcamera");
const RPiController = @import("RPiController");

const Duration = libcamera.utils.Duration;
const Span = libcamera.utils.Span;
const Metadata = RPiController.Metadata;
const StatisticsPtr = RPiController.StatisticsPtr;
const CameraMode = RPiController.CameraMode;
const Controller = RPiController.Controller;
const MdParser = RPiController.MdParser;
const DeviceStatus = RPiController.DeviceStatus;

fn camHelpers() *std.HashMap([]const u8, CamHelperCreateFunc) {
    return &std.HashMap([]const u8, CamHelperCreateFunc).init(std.heap.page_allocator);
}

pub fn CamHelper_create(camName: []const u8) ?*CamHelper {
    for (camHelpers().iterator()) |entry| {
        if (std.mem.indexOf(u8, camName, entry.key) != null) {
            return entry.value();
        }
    }
    return null;
}

pub fn CamHelper(
    parser: ?*MdParser,
    frameIntegrationDiff: u32,
) !*CamHelper {
    return &CamHelper{
        .parser = parser,
        .frameIntegrationDiff = frameIntegrationDiff,
    };
}

pub fn CamHelper_deinit(self: *CamHelper) void {}

pub fn CamHelper_prepare(
    self: *CamHelper,
    buffer: Span(const u8),
    metadata: *Metadata,
) void {
    self.parseEmbeddedData(buffer, metadata);
}

pub fn CamHelper_process(
    self: *CamHelper,
    stats: ?*StatisticsPtr,
    metadata: *Metadata,
) void {}

pub fn CamHelper_exposureLines(
    self: *CamHelper,
    exposure: Duration,
    lineLength: Duration,
) u32 {
    return exposure / lineLength;
}

pub fn CamHelper_exposure(
    self: *CamHelper,
    exposureLines: u32,
    lineLength: Duration,
) Duration {
    return exposureLines * lineLength;
}

pub fn CamHelper_getBlanking(
    self: *CamHelper,
    exposure: *Duration,
    minFrameDuration: Duration,
    maxFrameDuration: Duration,
) !std.pair(u32, u32) {
    var frameLengthMin: u32 = minFrameDuration / self.mode.minLineLength;
    var frameLengthMax: u32 = maxFrameDuration / self.mode.minLineLength;
    var lineLength: Duration = self.mode.minLineLength;

    var exposureLines: u32 = std.math.min(
        self.exposureLines(*exposure, lineLength),
        std.math.maxInt(u32) - self.frameIntegrationDiff,
    );
    var frameLengthLines: u32 = std.math.clamp(
        exposureLines + self.frameIntegrationDiff,
        frameLengthMin,
        frameLengthMax,
    );

    if (frameLengthLines > self.mode.maxFrameLength) {
        var lineLengthAdjusted: Duration = lineLength * frameLengthLines / self.mode.maxFrameLength;
        lineLength = std.math.min(self.mode.maxLineLength, lineLengthAdjusted);
        frameLengthLines = self.mode.maxFrameLength;
    }

    var hblank: u32 = self.lineLengthToHblank(lineLength);
    var vblank: u32 = frameLengthLines - self.mode.height;

    exposureLines = std.math.min(
        frameLengthLines - self.frameIntegrationDiff,
        self.exposureLines(*exposure, lineLength),
    );
    *exposure = self.exposure(exposureLines, lineLength);

    return std.pair(vblank, hblank);
}

pub fn CamHelper_hblankToLineLength(
    self: *CamHelper,
    hblank: u32,
) Duration {
    return (self.mode.width + hblank) * (1.0s / self.mode.pixelRate);
}

pub fn CamHelper_lineLengthToHblank(
    self: *CamHelper,
    lineLength: Duration,
) u32 {
    return (lineLength * self.mode.pixelRate / 1.0s) - self.mode.width;
}

pub fn CamHelper_lineLengthPckToDuration(
    self: *CamHelper,
    lineLengthPck: u32,
) Duration {
    return lineLengthPck * (1.0s / self.mode.pixelRate);
}

pub fn CamHelper_setCameraMode(
    self: *CamHelper,
    mode: CameraMode,
) void {
    self.mode = mode;
    if (self.parser) |parser| {
        parser.reset();
        parser.setBitsPerPixel(mode.bitdepth);
        parser.setLineLengthBytes(0);
    }
}

pub fn CamHelper_setHwConfig(
    self: *CamHelper,
    hwConfig: Controller.HardwareConfig,
) void {
    self.hwConfig = hwConfig;
}

pub fn CamHelper_sensorEmbeddedDataPresent(
    self: *CamHelper,
) bool {
    return false;
}

pub fn CamHelper_getModeSensitivity(
    self: *CamHelper,
    mode: CameraMode,
) f64 {
    return 1.0;
}

pub fn CamHelper_hideFramesStartup(
    self: *CamHelper,
) u32 {
    return 0;
}

pub fn CamHelper_hideFramesModeSwitch(
    self: *CamHelper,
) u32 {
    return 0;
}

pub fn CamHelper_mistrustFramesStartup(
    self: *CamHelper,
) u32 {
    return 1;
}

pub fn CamHelper_mistrustFramesModeSwitch(
    self: *CamHelper,
) u32 {
    return 0;
}

pub fn CamHelper_parseEmbeddedData(
    self: *CamHelper,
    buffer: Span(const u8),
    metadata: *Metadata,
) void {
    var registers: MdParser.RegisterMap = undefined;
    var parsedMetadata: Metadata = undefined;

    if (buffer.len == 0) return;

    if (self.parser.parse(buffer, &registers) != MdParser.Status.OK) {
        log.error("Embedded data buffer parsing failed");
        return;
    }

    self.populateMetadata(registers, &parsedMetadata);
    metadata.merge(parsedMetadata);

    var deviceStatus: DeviceStatus = undefined;
    var parsedDeviceStatus: DeviceStatus = undefined;
    if (metadata.get("device.status", &deviceStatus) != 0 ||
        parsedMetadata.get("device.status", &parsedDeviceStatus) != 0) {
        log.error("DeviceStatus not found");
        return;
    }

    deviceStatus.exposureTime = parsedDeviceStatus.exposureTime;
    deviceStatus.analogueGain = parsedDeviceStatus.analogueGain;
    deviceStatus.frameLength = parsedDeviceStatus.frameLength;
    deviceStatus.lineLength = parsedDeviceStatus.lineLength;
    if (parsedDeviceStatus.sensorTemperature) |sensorTemperature| {
        deviceStatus.sensorTemperature = sensorTemperature;
    }

    log.debug("Metadata updated - {}", deviceStatus);

    metadata.set("device.status", deviceStatus);
}

pub fn CamHelper_populateMetadata(
    self: *CamHelper,
    registers: MdParser.RegisterMap,
    metadata: *Metadata,
) void {}

pub fn RegisterCamHelper(
    camName: []const u8,
    createFunc: CamHelperCreateFunc,
) void {
    camHelpers().put(camName, createFunc);
}
