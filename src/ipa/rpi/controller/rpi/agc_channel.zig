const std = @import("std");
const libcamera = @import("libcamera");
const RPiController = @import("RPiController");

const Duration = libcamera.utils.Duration;
const Metadata = RPiController.Metadata;
const StatisticsPtr = RPiController.StatisticsPtr;
const CameraMode = RPiController.CameraMode;
const DeviceStatus = RPiController.DeviceStatus;
const AwbStatus = RPiController.AwbStatus;
const AgcStatus = RPiController.AgcStatus;
const Histogram = RPiController.Histogram;
const LuxStatus = RPiController.LuxStatus;

const RPiAgc = libcamera.LogCategory("RPiAgc");

const AgcMeteringMode = struct {
    weights: std.ArrayList(f64),

    pub fn read(self: *AgcMeteringMode, params: libcamera.YamlObject) !void {
        const yamlWeights = params.get("weights").asList();
        for (yamlWeights) |p| {
            const value = p.get(f64);
            if (value == null) {
                return error.InvalidArgument;
            }
            try self.weights.append(value.?);
        }
    }
};

fn readMeteringModes(metering_modes: *std.HashMap([]const u8, AgcMeteringMode), params: libcamera.YamlObject) ![]const u8 {
    var first: []const u8 = "";
    for (params.asDict()) |entry| {
        var meteringMode = AgcMeteringMode{};
        try meteringMode.read(entry.value);
        try metering_modes.put(entry.key, meteringMode);
        if (first.len == 0) {
            first = entry.key;
        }
    }
    return first;
}

const AgcExposureMode = struct {
    exposureTime: std.ArrayList(Duration),
    gain: std.ArrayList(f64),

    pub fn read(self: *AgcExposureMode, params: libcamera.YamlObject) !void {
        const exposureTimeList = params.get("shutter").getList(f64);
        if (exposureTimeList == null) {
            return error.InvalidArgument;
        }
        for (exposureTimeList.?) |v| {
            try self.exposureTime.append(v * 1 * std.time.microsecond);
        }

        const gainList = params.get("gain").getList(f64);
        if (gainList == null) {
            return error.InvalidArgument;
        }
        self.gain = gainList.?;

        if (self.exposureTime.len < 2 or self.gain.len < 2) {
            RPiAgc.error("AgcExposureMode: must have at least two entries in exposure profile");
            return error.InvalidArgument;
        }

        if (self.exposureTime.len != self.gain.len) {
            RPiAgc.error("AgcExposureMode: expect same number of exposure and gain entries in exposure profile");
            return error.InvalidArgument;
        }
    }
};

fn readExposureModes(exposureModes: *std.HashMap([]const u8, AgcExposureMode), params: libcamera.YamlObject) ![]const u8 {
    var first: []const u8 = "";
    for (params.asDict()) |entry| {
        var exposureMode = AgcExposureMode{};
        try exposureMode.read(entry.value);
        try exposureModes.put(entry.key, exposureMode);
        if (first.len == 0) {
            first = entry.key;
        }
    }
    return first;
}

const AgcConstraint = struct {
    Bound = enum { LOWER, UPPER },
    bound: Bound,
    qLo: f64,
    qHi: f64,
    yTarget: libcamera.ipa.Pwl,

    pub fn read(self: *AgcConstraint, params: libcamera.YamlObject) !void {
        var boundString = params.get("bound").get([]const u8, "");
        std.mem.toUpper(boundString);
        if (boundString != "UPPER" and boundString != "LOWER") {
            RPiAgc.error("AGC constraint type should be UPPER or LOWER");
            return error.InvalidArgument;
        }
        self.bound = if (boundString == "UPPER") Bound.UPPER else Bound.LOWER;

        const qLoValue = params.get("q_lo").get(f64);
        if (qLoValue == null) {
            return error.InvalidArgument;
        }
        self.qLo = qLoValue.?;

        const qHiValue = params.get("q_hi").get(f64);
        if (qHiValue == null) {
            return error.InvalidArgument;
        }
        self.qHi = qHiValue.?;

        self.yTarget = params.get("y_target").get(libcamera.ipa.Pwl, libcamera.ipa.Pwl{});
        if (self.yTarget.empty()) {
            return error.InvalidArgument;
        }
    }
};

fn readConstraintMode(params: libcamera.YamlObject) !std.ArrayList(AgcConstraint) {
    var mode = std.ArrayList(AgcConstraint).init(std.heap.page_allocator);
    for (params.asList()) |p| {
        var constraint = AgcConstraint{};
        try constraint.read(p);
        try mode.append(constraint);
    }
    return mode;
}

fn readConstraintModes(constraintModes: *std.HashMap([]const u8, std.ArrayList(AgcConstraint)), params: libcamera.YamlObject) ![]const u8 {
    var first: []const u8 = "";
    for (params.asDict()) |entry| {
        const mode = try readConstraintMode(entry.value);
        try constraintModes.put(entry.key, mode);
        if (first.len == 0) {
            first = entry.key;
        }
    }
    return first;
}

const AgcChannelConstraint = struct {
    Bound = enum { LOWER, UPPER },
    bound: Bound,
    channel: u32,
    factor: f64,

    pub fn read(self: *AgcChannelConstraint, params: libcamera.YamlObject) !void {
        const channelValue = params.get("channel").get(u32);
        if (channelValue == null) {
            RPiAgc.error("AGC channel constraint must have a channel");
            return error.InvalidArgument;
        }
        self.channel = channelValue.?;

        var boundString = params.get("bound").get([]const u8, "");
        std.mem.toUpper(boundString);
        if (boundString != "UPPER" and boundString != "LOWER") {
            RPiAgc.error("AGC channel constraint type should be UPPER or LOWER");
            return error.InvalidArgument;
        }
        self.bound = if (boundString == "UPPER") Bound.UPPER else Bound.LOWER;

        const factorValue = params.get("factor").get(f64);
        if (factorValue == null) {
            RPiAgc.error("AGC channel constraint must have a factor");
            return error.InvalidArgument;
        }
        self.factor = factorValue.?;
    }
};

fn readChannelConstraints(channelConstraints: *std.ArrayList(AgcChannelConstraint), params: libcamera.YamlObject) !void {
    for (params.asList()) |p| {
        var constraint = AgcChannelConstraint{};
        try constraint.read(p);
        try channelConstraints.append(constraint);
    }
}

const AgcConfig = struct {
    meteringModes: std.HashMap([]const u8, AgcMeteringMode),
    exposureModes: std.HashMap([]const u8, AgcExposureMode),
    constraintModes: std.HashMap([]const u8, std.ArrayList(AgcConstraint)),
    channelConstraints: std.ArrayList(AgcChannelConstraint),
    yTarget: libcamera.ipa.Pwl,
    speed: f64,
    startupFrames: u16,
    convergenceFrames: u32,
    fastReduceThreshold: f64,
    baseEv: f64,
    defaultExposureTime: Duration,
    defaultAnalogueGain: f64,
    stableRegion: f64,
    desaturate: bool,
    defaultMeteringMode: []const u8,
    defaultExposureMode: []const u8,
    defaultConstraintMode: []const u8,

    pub fn read(self: *AgcConfig, params: libcamera.YamlObject) !void {
        RPiAgc.debug("AgcConfig");

        self.defaultMeteringMode = try readMeteringModes(&self.meteringModes, params.get("metering_modes"));
        self.defaultExposureMode = try readExposureModes(&self.exposureModes, params.get("exposure_modes"));
        self.defaultConstraintMode = try readConstraintModes(&self.constraintModes, params.get("constraint_modes"));

        if (params.contains("channel_constraints")) {
            try readChannelConstraints(&self.channelConstraints, params.get("channel_constraints"));
        }

        self.yTarget = params.get("y_target").get(libcamera.ipa.Pwl, libcamera.ipa.Pwl{});
        if (self.yTarget.empty()) {
            return error.InvalidArgument;
        }

        self.speed = params.get("speed").get(f64, 0.2);
        self.startupFrames = params.get("startup_frames").get(u16, 10);
        self.convergenceFrames = params.get("convergence_frames").get(u32, 6);
        self.fastReduceThreshold = params.get("fast_reduce_threshold").get(f64, 0.4);
        self.baseEv = params.get("base_ev").get(f64, 1.0);

        self.defaultExposureTime = params.get("default_exposure_time").get(f64, 1000) * std.time.microsecond;
        self.defaultAnalogueGain = params.get("default_analogue_gain").get(f64, 1.0);

        self.stableRegion = params.get("stable_region").get(f64, 0.02);

        self.desaturate = params.get("desaturate").get(bool, true);
    }
};

const AgcChannel = struct {
    meteringMode: ?*AgcMeteringMode,
    exposureMode: ?*AgcExposureMode,
    constraintMode: ?*std.ArrayList(AgcConstraint),
    frameCount: u64,
    lockCount: i32,
    lastDeviceStatus: DeviceStatus,
    lastTargetExposure: Duration,
    ev: f64,
    flickerPeriod: Duration,
    maxExposureTime: Duration,
    fixedExposureTime: Duration,
    fixedAnalogueGain: f64,
    meteringModeName: []const u8,
    exposureModeName: []const u8,
    constraintModeName: []const u8,
    config: AgcConfig,
    mode: CameraMode,
    awb: AwbStatus,
    status: AgcStatus,
    current: ExposureValues,
    target: ExposureValues,
    filtered: ExposureValues,

    pub fn init() AgcChannel {
        return AgcChannel{
            .meteringMode = null,
            .exposureMode = null,
            .constraintMode = null,
            .frameCount = 0,
            .lockCount = 0,
            .lastDeviceStatus = DeviceStatus.init(),
            .lastTargetExposure = 0,
            .ev = 1.0,
            .flickerPeriod = 0,
            .maxExposureTime = 0,
            .fixedExposureTime = 0,
            .fixedAnalogueGain = 0.0,
            .meteringModeName = "",
            .exposureModeName = "",
            .constraintModeName = "",
            .config = AgcConfig.init(),
            .mode = CameraMode.init(),
            .awb = AwbStatus.init(),
            .status = AgcStatus.init(),
            .current = ExposureValues.init(),
            .target = ExposureValues.init(),
            .filtered = ExposureValues.init(),
        };
    }

    pub fn read(self: *AgcChannel, params: libcamera.YamlObject, hardwareConfig: RPiController.Controller.HardwareConfig) !void {
        try self.config.read(params);

        const size = hardwareConfig.agcZoneWeights;
        for (self.config.meteringModes) |modes| {
            if (modes.value.weights.len != size.width * size.height) {
                RPiAgc.error("AgcMeteringMode: Incorrect number of weights");
                return error.InvalidArgument;
            }
        }

        self.meteringModeName = self.config.defaultMeteringMode;
        self.meteringMode = self.config.meteringModes.get(self.meteringModeName);
        self.exposureModeName = self.config.defaultExposureMode;
        self.exposureMode = self.config.exposureModes.get(self.exposureModeName);
        self.constraintModeName = self.config.defaultConstraintMode;
        self.constraintMode = self.config.constraintModes.get(self.constraintModeName);
        self.status.exposureTime = self.config.defaultExposureTime;
        self.status.analogueGain = self.config.defaultAnalogueGain;
    }

    pub fn disableAuto(self: *AgcChannel) void {
        self.fixedExposureTime = self.status.exposureTime;
        self.fixedAnalogueGain = self.status.analogueGain;
    }

    pub fn enableAuto(self: *AgcChannel) void {
        self.fixedExposureTime = 0;
        self.fixedAnalogueGain = 0;
    }

    pub fn getConvergenceFrames(self: *AgcChannel) u32 {
        if (self.fixedExposureTime != 0 and self.fixedAnalogueGain != 0) {
            return 0;
        } else {
            return self.config.convergenceFrames;
        }
    }

    pub fn getWeights(self: *AgcChannel) []f64 {
        const it = self.config.meteringModes.get(self.meteringModeName);
        if (it == null) {
            return self.meteringMode.weights.items;
        }
        return it.?.weights.items;
    }

    pub fn setEv(self: *AgcChannel, ev: f64) void {
        self.ev = ev;
    }

    pub fn setFlickerPeriod(self: *AgcChannel, flickerPeriod: Duration) void {
        self.flickerPeriod = flickerPeriod;
    }

    pub fn setMaxExposureTime(self: *AgcChannel, maxExposureTime: Duration) void {
        self.maxExposureTime = maxExposureTime;
    }

    pub fn setFixedExposureTime(self: *AgcChannel, fixedExposureTime: Duration) void {
        self.fixedExposureTime = fixedExposureTime;
        self.status.exposureTime = self.limitExposureTime(fixedExposureTime);
    }

    pub fn setFixedAnalogueGain(self: *AgcChannel, fixedAnalogueGain: f64) void {
        self.fixedAnalogueGain = fixedAnalogueGain;
        self.status.analogueGain = self.limitGain(fixedAnalogueGain);
    }

    pub fn setMeteringMode(self: *AgcChannel, meteringModeName: []const u8) void {
        self.meteringModeName = meteringModeName;
    }

    pub fn setExposureMode(self: *AgcChannel, exposureModeName: []const u8) void {
        self.exposureModeName = exposureModeName;
    }

    pub fn setConstraintMode(self: *AgcChannel, constraintModeName: []const u8) void {
        self.constraintModeName = constraintModeName;
    }

    pub fn switchMode(self: *AgcChannel, cameraMode: CameraMode, metadata: *Metadata) void {
        assert(cameraMode.sensitivity != 0);

        self.housekeepConfig();

        const lastSensitivity = self.mode.sensitivity;
        self.mode = cameraMode;

        const fixedExposureTime = self.limitExposureTime(self.fixedExposureTime);
        if (fixedExposureTime != 0 and self.fixedAnalogueGain != 0) {
            self.fetchAwbStatus(metadata);
            const minColourGain = std.math.min(std.math.min(self.awb.gainR, self.awb.gainG), std.math.min(self.awb.gainB, 1.0));
            assert(minColourGain != 0.0);

            self.target.totalExposureNoDG = self.fixedExposureTime * self.fixedAnalogueGain;
            self.target.totalExposure = self.target.totalExposureNoDG / minColourGain;

            self.filtered = self.target;

            self.filtered.exposureTime = fixedExposureTime;
            self.filtered.analogueGain = self.fixedAnalogueGain;
        } else if (self.status.totalExposureValue != 0) {
            const ratio = lastSensitivity / cameraMode.sensitivity;
            self.target.totalExposureNoDG *= ratio;
            self.target.totalExposure *= ratio;
            self.filtered.totalExposureNoDG *= ratio;
            self.filtered.totalExposure *= ratio;

            self.divideUpExposure();
        } else {
            self.filtered.exposureTime = fixedExposureTime != 0 ? fixedExposureTime : self.config.defaultExposureTime;
            self.filtered.analogueGain = self.fixedAnalogueGain != 0 ? self.fixedAnalogueGain : self.config.defaultAnalogueGain;
        }

        self.writeAndFinish(metadata, false);
    }

    pub fn prepare(self: *AgcChannel, imageMetadata: *Metadata) void {
        var totalExposureValue = self.status.totalExposureValue;
        var delayedStatus = AgcStatus.init();
        var prepareStatus = RPiController.AgcPrepareStatus.init();

        self.fetchAwbStatus(imageMetadata);

        if (imageMetadata.get("agc.delayed_status", &delayedStatus) == 0) {
            totalExposureValue = delayedStatus.totalExposureValue;
        }

        prepareStatus.digitalGain = 1.0;
        prepareStatus.locked = false;

        if (self.status.totalExposureValue != 0) {
            var deviceStatus = DeviceStatus.init();
            if (imageMetadata.get("device.status", &deviceStatus) == 0) {
                const actualExposure = deviceStatus.exposureTime * deviceStatus.analogueGain;
                if (actualExposure != 0) {
                    const digitalGain = totalExposureValue / actualExposure;
                    RPiAgc.debug("Want total exposure {d}", .{totalExposureValue});
                    prepareStatus.digitalGain = std.math.max(1.0, std.math.min(digitalGain, 4.0));
                    RPiAgc.debug("Actual exposure {d}", .{actualExposure});
                    RPiAgc.debug("Use digitalGain {d}", .{prepareStatus.digitalGain});
                    RPiAgc.debug("Effective exposure {d}", .{actualExposure * prepareStatus.digitalGain});
                    prepareStatus.locked = self.updateLockStatus(deviceStatus);
                }
            } else {
                RPiAgc.warning("AgcChannel: no device metadata");
            }
            imageMetadata.set("agc.prepare_status", prepareStatus);
        }
    }

    pub fn process(self: *AgcChannel, stats: *StatisticsPtr, deviceStatus: DeviceStatus, imageMetadata: *Metadata, channelTotalExposures: []Duration) void {
        self.frameCount += 1;
        self.housekeepConfig();
        self.fetchCurrentExposure(deviceStatus);
        var gain: f64 = 0;
        var targetY: f64 = 0;
        self.computeGain(stats, imageMetadata, &gain, &targetY);
        self.computeTargetExposure(gain);
        self.filterExposure();
        const channelBound = self.applyChannelConstraints(channelTotalExposures);
        const desaturate = self.applyDigitalGain(gain, targetY, channelBound);
        self.divideUpExposure();
        self.writeAndFinish(imageMetadata, desaturate);
    }

    fn updateLockStatus(self: *AgcChannel, deviceStatus: DeviceStatus) bool {
        const errorFactor = 0.10;
        const maxLockCount = 5;
        const resetMargin = 1.5;

        const exposureError = self.lastDeviceStatus.exposureTime * errorFactor + 200 * std.time.microsecond;
        const gainError = self.lastDeviceStatus.analogueGain * errorFactor;
        const targetError = self.lastTargetExposure * errorFactor;

        if (deviceStatus.exposureTime > self.lastDeviceStatus.exposureTime - exposureError and deviceStatus.exposureTime < self.lastDeviceStatus.exposureTime + exposureError and deviceStatus.analogueGain > self.lastDeviceStatus.analogueGain - gainError and deviceStatus.analogueGain < self.lastDeviceStatus.analogueGain + gainError and self.status.targetExposureValue > self.lastTargetExposure - targetError and self.status.targetExposureValue < self.lastTargetExposure + targetError) {
            self.lockCount = std.math.min(self.lockCount + 1, maxLockCount);
        } else if (deviceStatus.exposureTime < self.lastDeviceStatus.exposureTime - resetMargin * exposureError or deviceStatus.exposureTime > self.lastDeviceStatus.exposureTime + resetMargin * exposureError or deviceStatus.analogueGain < self.lastDeviceStatus.analogueGain - resetMargin * gainError or deviceStatus.analogueGain > self.lastDeviceStatus.analogueGain + resetMargin * gainError or self.status.targetExposureValue < self.lastTargetExposure - resetMargin * targetError or self.status.targetExposureValue > self.lastTargetExposure + resetMargin * targetError) {
            self.lockCount = 0;
        }

        self.lastDeviceStatus = deviceStatus;
        self.lastTargetExposure = self.status.targetExposureValue;

        RPiAgc.debug("Lock count updated to {d}", .{self.lockCount});
        return self.lockCount == maxLockCount;
    }

    fn housekeepConfig(self: *AgcChannel) void {
        self.status.ev = self.ev;
        self.status.fixedExposureTime = self.limitExposureTime(self.fixedExposureTime);
        self.status.fixedAnalogueGain = self.fixedAnalogueGain;
        self.status.flickerPeriod = self.flickerPeriod;
        RPiAgc.debug("ev {d} fixedExposureTime {d} fixedAnalogueGain {d}", .{self.status.ev, self.status.fixedExposureTime, self.status.fixedAnalogueGain});

        if (self.meteringModeName != self.status.meteringMode) {
            const it = self.config.meteringModes.get(self.meteringModeName);
            if (it == null) {
                RPiAgc.warning("No metering mode {s}", .{self.meteringModeName});
                self.meteringModeName = self.status.meteringMode;
            } else {
                self.meteringMode = it;
                self.status.meteringMode = self.meteringModeName;
            }
        }
        if (self.exposureModeName != self.status.exposureMode) {
            const it = self.config.exposureModes.get(self.exposureModeName);
            if (it == null) {
                RPiAgc.warning("No exposure profile {s}", .{self.exposureModeName});
                self.exposureModeName = self.status.exposureMode;
            } else {
                self.exposureMode = it;
                self.status.exposureMode = self.exposureModeName;
            }
        }
        if (self.constraintModeName != self.status.constraintMode) {
            const it = self.config.constraintModes.get(self.constraintModeName);
            if (it == null) {
                RPiAgc.warning("No constraint list {s}", .{self.constraintModeName});
                self.constraintModeName = self.status.constraintMode;
            } else {
                self.constraintMode = it;
                self.status.constraintMode = self.constraintModeName;
            }
        }
        RPiAgc.debug("exposureMode {s} constraintMode {s} meteringMode {s}", .{self.exposureModeName, self.constraintModeName, self.meteringModeName});
    }

    fn fetchCurrentExposure(self: *AgcChannel, deviceStatus: DeviceStatus) void {
        self.current.exposureTime = deviceStatus.exposureTime;
        self.current.analogueGain = deviceStatus.analogueGain;
        self.current.totalExposure = 0;
        self.current.totalExposureNoDG = self.current.exposureTime * self.current.analogueGain;
    }

    fn fetchAwbStatus(self: *AgcChannel, imageMetadata: *Metadata) void {
        if (imageMetadata.get("awb.status", &self.awb) != 0) {
            RPiAgc.debug("No AWB status found");
        }
    }

    fn computeGain(self: *AgcChannel, statistics: *StatisticsPtr, imageMetadata: *Metadata, gain: *f64, targetY: *f64) void {
        var lux = LuxStatus.init();
        lux.lux = 400;
        if (imageMetadata.get("lux.status", &lux) != 0) {
            RPiAgc.warning("No lux level found");
        }
        const h = statistics.yHist;
        const evGain = self.status.ev * self.config.baseEv;

        *targetY = self.config.yTarget.eval(self.config.yTarget.domain().clamp(lux.lux));
        *targetY = std.math.min(EvGainYTargetLimit, *targetY * evGain);

        *gain = 1.0;
        for (0..8) |i| {
            const initialY = computeInitialY(statistics, self.awb, self.meteringMode.weights.items, *gain);
            const extraGain = std.math.min(10.0, *targetY / (initialY + 0.001));
            *gain *= extraGain;
            RPiAgc.debug("Initial Y {d} target {d} gives gain {d}", .{initialY, *targetY, *gain});
            if (extraGain < 1.01) {
                break;
            }
        }

        for (self.constraintMode.items) |c| {
            var newTargetY: f64 = 0;
            const newGain = constraintComputeGain(c, h, lux.lux, evGain, &newTargetY);
            RPiAgc.debug("Constraint has target_Y {d} giving gain {d}", .{newTargetY, newGain});
            if (c.bound == AgcConstraint.Bound.LOWER and newGain > *gain) {
                RPiAgc.debug("Lower bound constraint adopted");
                *gain = newGain;
                *targetY = newTargetY;
            } else if (c.bound == AgcConstraint.Bound.UPPER and newGain < *gain) {
                RPiAgc.debug("Upper bound constraint adopted");
                *gain = newGain;
                *targetY = newTargetY;
            }
        }
        RPiAgc.debug("Final gain {d} (target_Y {d} ev {d} base_ev {d})", .{*gain, *targetY, self.status.ev, self.config.baseEv});
    }

    fn computeTargetExposure(self: *AgcChannel, gain: f64) void {
        if (self.status.fixedExposureTime != 0 and self.status.fixedAnalogueGain != 0) {
            const minColourGain = std.math.min(std.math.min(self.awb.gainR, self.awb.gainG), std.math.min(self.awb.gainB, 1.0));
            assert(minColourGain != 0.0);
            self.target.totalExposure = self.status.fixedExposureTime * self.status.fixedAnalogueGain / minColourGain;
        } else {
            self.target.totalExposure = self.current.totalExposureNoDG * gain;
            var maxExposureTime = self.status.fixedExposureTime != 0 ? self.status.fixedExposureTime : self.exposureMode.exposureTime.items[self.exposureMode.exposureTime.len - 1];
            maxExposureTime = self.limitExposureTime(maxExposureTime);
            const maxTotalExposure = maxExposureTime * (self.status.fixedAnalogueGain != 0.0 ? self.status.fixedAnalogueGain : self.exposureMode.gain.items[self.exposureMode.gain.len - 1]);
            self.target.totalExposure = std.math.min(self.target.totalExposure, maxTotalExposure);
        }
        RPiAgc.debug("Target totalExposure {d}", .{self.target.totalExposure});
    }

    fn applyChannelConstraints(self: *AgcChannel, channelTotalExposures: []Duration) bool {
        var channelBound = false;
        RPiAgc.debug("Total exposure before channel constraints {d}", .{self.filtered.totalExposure});

        for (self.config.channelConstraints.items) |constraint| {
            RPiAgc.debug("Check constraint: channel {d} bound {s} factor {d}", .{constraint.channel, if (constraint.bound == AgcChannelConstraint.Bound.UPPER) "UPPER" else "LOWER", constraint.factor});
            if (constraint.channel >= channelTotalExposures.len or channelTotalExposures[constraint.channel] == 0) {
                RPiAgc.debug("no such channel or no exposure available- skipped");
                continue;
            }

            const limitExposure = channelTotalExposures[constraint.channel] * constraint.factor;
            RPiAgc.debug("Limit exposure {d}", .{limitExposure});
            if ((constraint.bound == AgcChannelConstraint.Bound.UPPER and self.filtered.totalExposure > limitExposure) or (constraint.bound == AgcChannelConstraint.Bound.LOWER and self.filtered.totalExposure < limitExposure)) {
                self.filtered.totalExposure = limitExposure;
                RPiAgc.debug("Constraint applies");
                channelBound = true;
            } else {
                RPiAgc.debug("Constraint does not apply");
            }
        }

        RPiAgc.debug("Total exposure after channel constraints {d}", .{self.filtered.totalExposure});

        return channelBound;
    }

    fn applyDigitalGain(self: *AgcChannel, gain: f64, targetY: f64, channelBound: bool) bool {
        const minColourGain = std.math.min(std.math.min(self.awb.gainR, self.awb.gainG), std.math.min(self.awb.gainB, 1.0));
        assert(minColourGain != 0.0);
        var dg = 1.0 / minColourGain;
        RPiAgc.debug("after AWB, target dg {d} gain {d} target_Y {d}", .{dg, gain, targetY});
        var desaturate = false;
        if (self.config.desaturate) {
            desaturate = !channelBound and targetY > self.config.fastReduceThreshold and gain < std.math.sqrt(targetY);
        }
        if (desaturate) {
            dg /= self.config.fastReduceThreshold;
        }
        RPiAgc.debug("Digital gain {d} desaturate? {b}", .{dg, desaturate});
        self.filtered.totalExposureNoDG = self.filtered.totalExposure / dg;
        RPiAgc.debug("Target totalExposureNoDG {d}", .{self.filtered.totalExposureNoDG});
        return desaturate;
    }

    fn filterExposure(self: *AgcChannel) void {
        var speed = self.config.speed;
        var stableRegion = self.config.stableRegion;

        if ((self.status.fixedExposureTime != 0 and self.status.fixedAnalogueGain != 0) or self.frameCount <= self.config.startupFrames) {
            speed = 1.0;
            stableRegion = 0.0;
        }
        if (self.filtered.totalExposure == 0) {
            self.filtered.totalExposure = self.target.totalExposure;
        } else if (self.filtered.totalExposure * (1.0 - stableRegion) < self.target.totalExposure and self.filtered.totalExposure * (1.0 + stableRegion) > self.target.totalExposure) {
        } else {
            if (self.filtered.totalExposure < 1.2 * self.target.totalExposure and self.filtered.totalExposure > 0.8 * self.target.totalExposure) {
                speed = std.math.sqrt(speed);
            }
            self.filtered.totalExposure = speed * self.target.totalExposure + self.filtered.totalExposure * (1.0 - speed);
        }
        RPiAgc.debug("After filtering, totalExposure {d} no dg {d}", .{self.filtered.totalExposure, self.filtered.totalExposureNoDG});
    }

    fn divideUpExposure(self: *AgcChannel) void {
        var exposureValue = self.filtered.totalExposureNoDG;
        var exposureTime = self.status.fixedExposureTime != 0 ? self.status.fixedExposureTime : self.exposureMode.exposureTime.items[0];
        exposureTime = self.limitExposureTime(exposureTime);
        var analogueGain = self.status.fixedAnalogueGain != 0.0 ? self.status.fixedAnalogueGain : self.exposureMode.gain.items[0];
        analogueGain = self.limitGain(analogueGain);
        if (exposureTime * analogueGain < exposureValue) {
            for (1..self.exposureMode.gain.len) |stage| {
                if (self.status.fixedExposureTime == 0) {
                    const stageExposureTime = self.limitExposureTime(self.exposureMode.exposureTime.items[stage]);
                    if (stageExposureTime * analogueGain >= exposureValue) {
                        exposureTime = exposureValue / analogueGain;
                        break;
                    }
                    exposureTime = stageExposureTime;
                }
                if (self.status.fixedAnalogueGain == 0.0) {
                    if (self.exposureMode.gain.items[stage] * exposureTime >= exposureValue) {
                        analogueGain = exposureValue / exposureTime;
                        break;
                    }
                    analogueGain = self.exposureMode.gain.items[stage];
                    analogueGain = self.limitGain(analogueGain);
                }
            }
        }
        RPiAgc.debug("Divided up exposure time and gain are {d} and {d}", .{exposureTime, analogueGain});
        if (self.status.fixedExposureTime == 0 and self.status.fixedAnalogueGain == 0 and self.status.flickerPeriod != 0) {
            const flickerPeriods = exposureTime / self.status.flickerPeriod;
            if (flickerPeriods != 0) {
                const newExposureTime = flickerPeriods * self.status.flickerPeriod;
                analogueGain *= exposureTime / newExposureTime;
                analogueGain = std.math.min(analogueGain, self.exposureMode.gain.items[self.exposureMode.gain.len - 1]);
                analogueGain = self.limitGain(analogueGain);
                exposureTime = newExposureTime;
            }
            RPiAgc.debug("After flicker avoidance, exposure time {d} gain {d}", .{exposureTime, analogueGain});
        }
        self.filtered.exposureTime = exposureTime;
        self.filtered.analogueGain = analogueGain;
    }

    fn writeAndFinish(self: *AgcChannel, imageMetadata: *Metadata, desaturate: bool) void {
        self.status.totalExposureValue = self.filtered.totalExposure;
        self.status.targetExposureValue = desaturate ? 0 : self.target.totalExposure;
        self.status.exposureTime = self.filtered.exposureTime;
        self.status.analogueGain = self.filtered.analogueGain;
        imageMetadata.set("agc.status", self.status);
        RPiAgc.debug("Output written, total exposure requested is {d}", .{self.filtered.totalExposure});
        RPiAgc.debug("Camera exposure update: exposure time {d} analogue gain {d}", .{self.filtered.exposureTime, self.filtered.analogueGain});
    }

    fn limitExposureTime(self: *AgcChannel, exposureTime: Duration) Duration {
        if (exposureTime == 0) {
            return exposureTime;
        }

        return std.math.clamp(exposureTime, self.mode.minExposureTime, self.maxExposureTime);
    }

    fn limitGain(self: *AgcChannel, gain: f64) f64 {
        if (gain == 0.0) {
            return gain;
        }

        return std.math.max(gain, self.mode.minAnalogueGain);
    }
};

fn computeInitialY(stats: *StatisticsPtr, awb: AwbStatus, weights: []f64, gain: f64) f64 {
    const maxVal = 1 << RPiController.Statistics.NormalisationFactorPow2;

    if (stats.agcRegions.numRegions() == 0 and stats.yHist.bins() != 0) {
        const hist = stats.yHist;
        const minBin = std.math.min(1.0, 1.0 / gain) * hist.bins();
        const binMean = hist.interBinMean(0.0, minBin);
        const numUnsaturated = hist.cumulativeFreq(minBin);
        var ySum = binMean * gain * numUnsaturated;
        ySum += (hist.total() - numUnsaturated) * hist.bins();
        return ySum / hist.total() / hist.bins();
    }

    assert(weights.len == stats.agcRegions.numRegions());

    var sum = RPiController.ipa.RGB(f64){ .r = 0.0, .g = 0.0, .b = 0.0 };
    var pixelSum: f64 = 0;
    for (0..stats.agcRegions.numRegions()) |i| {
        const region = stats.agcRegions.get(i);
        sum.r += std.math.min(region.val.rSum * gain, (maxVal - 1) * region.counted);
        sum.g += std.math.min(region.val.gSum * gain, (maxVal - 1) * region.counted);
        sum.b += std.math.min(region.val.bSum * gain, (maxVal - 1) * region.counted);
        pixelSum += region.counted;
    }
    if (pixelSum == 0.0) {
        RPiAgc.warning("computeInitialY: pixelSum is zero");
        return 0;
    }

    if (stats.agcStatsPos == RPiController.Statistics.AgcStatsPos.PreWb) {
        sum *= RPiController.ipa.RGB(f64){ .r = awb.gainR, .g = awb.gainR, .b = awb.gainB };
    }

    const ySum = RPiController.ipa.rec601LuminanceFromRGB(sum);

    return ySum / pixelSum / (1 << 16);
}

fn constraintComputeGain(c: AgcConstraint, h: Histogram, lux: f64, evGain: f64, targetY: *f64) f64 {
    *targetY = c.yTarget.eval(c.yTarget.domain().clamp(lux));
    *targetY = std.math.min(EvGainYTargetLimit, *targetY * evGain);
    const iqm = h.interQuantileMean(c.qLo, c.qHi);
    return (*targetY * h.bins()) / iqm;
}

const ExposureValues = struct {
    exposureTime: Duration,
    analogueGain: f64,
    totalExposure: Duration,
    totalExposureNoDG: Duration,

    pub fn init() ExposureValues {
        return ExposureValues{
            .exposureTime = 0,
            .analogueGain = 0,
            .totalExposure = 0,
            .totalExposureNoDG = 0,
        };
    }
};
