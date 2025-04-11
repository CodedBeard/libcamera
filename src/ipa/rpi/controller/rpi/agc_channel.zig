const std = @import("std");
const libcamera = @import("libcamera");
const ipa = @import("libipa");
const RPiController = @import("../controller");

const AgcMeteringMode = struct {
    weights: std.ArrayList(f64),

    pub fn read(self: *AgcMeteringMode, params: YamlObject) !void {
        const yamlWeights = params.get("weights");
        for (p in yamlWeights.asList()) |value| {
            self.weights.append(value.get(f64)) catch return error.Invalid;
        }
    }
};

const AgcExposureMode = struct {
    exposureTime: std.ArrayList(libcamera.utils.Duration),
    gain: std.ArrayList(f64),

    pub fn read(self: *AgcExposureMode, params: YamlObject) !void {
        const shutter = params.get("shutter").getList(f64) orelse return error.Invalid;
        for (v in shutter) |value| {
            self.exposureTime.append(value * 1e-6) catch return error.Invalid;
        }

        const gainList = params.get("gain").getList(f64) orelse return error.Invalid;
        self.gain = gainList;

        if (self.exposureTime.len < 2 or self.gain.len < 2) {
            return error.Invalid;
        }

        if (self.exposureTime.len != self.gain.len) {
            return error.Invalid;
        }
    }
};

const AgcConstraint = struct {
    Bound: enum { LOWER, UPPER },
    bound: Bound,
    qLo: f64,
    qHi: f64,
    yTarget: ipa.Pwl,

    pub fn read(self: *AgcConstraint, params: YamlObject) !void {
        const boundString = params.get("bound").get([]const u8) orelse return error.Invalid;
        const upperBound = std.mem.eql(u8, boundString, "UPPER");
        const lowerBound = std.mem.eql(u8, boundString, "LOWER");
        if (!upperBound and !lowerBound) {
            return error.Invalid;
        }
        self.bound = upperBound ? .UPPER : .LOWER;

        self.qLo = params.get("q_lo").get(f64) orelse return error.Invalid;
        self.qHi = params.get("q_hi").get(f64) orelse return error.Invalid;
        self.yTarget = params.get("y_target").get(ipa.Pwl) orelse return error.Invalid;
    }
};

const AgcChannelConstraint = struct {
    Bound: enum { LOWER, UPPER },
    bound: Bound,
    channel: u32,
    factor: f64,

    pub fn read(self: *AgcChannelConstraint, params: YamlObject) !void {
        self.channel = params.get("channel").get(u32) orelse return error.Invalid;

        const boundString = params.get("bound").get([]const u8) orelse return error.Invalid;
        const upperBound = std.mem.eql(u8, boundString, "UPPER");
        const lowerBound = std.mem.eql(u8, boundString, "LOWER");
        if (!upperBound and !lowerBound) {
            return error.Invalid;
        }
        self.bound = upperBound ? .UPPER : .LOWER;

        self.factor = params.get("factor").get(f64) orelse return error.Invalid;
    }
};

const AgcConfig = struct {
    meteringModes: std.HashMap([]const u8, AgcMeteringMode, std.hash_map.StringHashFn, std.hash_map.StringEqlFn),
    exposureModes: std.HashMap([]const u8, AgcExposureMode, std.hash_map.StringHashFn, std.hash_map.StringEqlFn),
    constraintModes: std.HashMap([]const u8, std.ArrayList(AgcConstraint), std.hash_map.StringHashFn, std.hash_map.StringEqlFn),
    channelConstraints: std.ArrayList(AgcChannelConstraint),
    yTarget: ipa.Pwl,
    speed: f64,
    startupFrames: u16,
    convergenceFrames: u32,
    fastReduceThreshold: f64,
    baseEv: f64,
    defaultExposureTime: libcamera.utils.Duration,
    defaultAnalogueGain: f64,
    stableRegion: f64,
    desaturate: bool,
    defaultMeteringMode: []const u8,
    defaultExposureMode: []const u8,
    defaultConstraintMode: []const u8,

    pub fn read(self: *AgcConfig, params: YamlObject) !void {
        self.meteringModes = std.HashMap([]const u8, AgcMeteringMode, std.hash_map.StringHashFn, std.hash_map.StringEqlFn).init(std.heap.page_allocator);
        self.exposureModes = std.HashMap([]const u8, AgcExposureMode, std.hash_map.StringHashFn, std.hash_map.StringEqlFn).init(std.heap.page_allocator);
        self.constraintModes = std.HashMap([]const u8, std.ArrayList(AgcConstraint), std.hash_map.StringHashFn, std.hash_map.StringEqlFn).init(std.heap.page_allocator);
        self.channelConstraints = std.ArrayList(AgcChannelConstraint).init(std.heap.page_allocator);

        const meteringModes = params.get("metering_modes");
        for (entry in meteringModes.asDict()) |key, value| {
            var meteringMode = AgcMeteringMode{};
            meteringMode.read(value) catch return error.Invalid;
            self.meteringModes.put(key, meteringMode) catch return error.OutOfMemory;
        }
        self.defaultMeteringMode = meteringModes.asDict().first().key;

        const exposureModes = params.get("exposure_modes");
        for (entry in exposureModes.asDict()) |key, value| {
            var exposureMode = AgcExposureMode{};
            exposureMode.read(value) catch return error.Invalid;
            self.exposureModes.put(key, exposureMode) catch return error.OutOfMemory;
        }
        self.defaultExposureMode = exposureModes.asDict().first().key;

        const constraintModes = params.get("constraint_modes");
        for (entry in constraintModes.asDict()) |key, value| {
            var constraints = std.ArrayList(AgcConstraint).init(std.heap.page_allocator);
            for (constraint in value.asList()) |constraintValue| {
                var agcConstraint = AgcConstraint{};
                agcConstraint.read(constraintValue) catch return error.Invalid;
                constraints.append(agcConstraint) catch return error.OutOfMemory;
            }
            self.constraintModes.put(key, constraints) catch return error.OutOfMemory;
        }
        self.defaultConstraintMode = constraintModes.asDict().first().key;

        if (params.contains("channel_constraints")) {
            const channelConstraints = params.get("channel_constraints");
            for (constraint in channelConstraints.asList()) |constraintValue| {
                var agcChannelConstraint = AgcChannelConstraint{};
                agcChannelConstraint.read(constraintValue) catch return error.Invalid;
                self.channelConstraints.append(agcChannelConstraint) catch return error.OutOfMemory;
            }
        }

        self.yTarget = params.get("y_target").get(ipa.Pwl) orelse return error.Invalid;
        self.speed = params.get("speed").get(f64) orelse 0.2;
        self.startupFrames = params.get("startup_frames").get(u16) orelse 10;
        self.convergenceFrames = params.get("convergence_frames").get(u32) orelse 6;
        self.fastReduceThreshold = params.get("fast_reduce_threshold").get(f64) orelse 0.4;
        self.baseEv = params.get("base_ev").get(f64) orelse 1.0;
        self.defaultExposureTime = params.get("default_exposure_time").get(f64) orelse 1000 * 1e-6;
        self.defaultAnalogueGain = params.get("default_analogue_gain").get(f64) orelse 1.0;
        self.stableRegion = params.get("stable_region").get(f64) orelse 0.02;
        self.desaturate = params.get("desaturate").get(bool) orelse true;
    }
};

const AgcChannel = struct {
    meteringMode: *AgcMeteringMode,
    exposureMode: *AgcExposureMode,
    constraintMode: *std.ArrayList(AgcConstraint),
    mode: RPiController.CameraMode,
    frameCount: u64,
    awb: RPiController.AwbStatus,
    current: ExposureValues,
    target: ExposureValues,
    filtered: ExposureValues,
    status: RPiController.AgcStatus,
    lockCount: i32,
    lastDeviceStatus: RPiController.DeviceStatus,
    lastTargetExposure: libcamera.utils.Duration,
    meteringModeName: []const u8,
    exposureModeName: []const u8,
    constraintModeName: []const u8,
    ev: f64,
    flickerPeriod: libcamera.utils.Duration,
    maxExposureTime: libcamera.utils.Duration,
    fixedExposureTime: libcamera.utils.Duration,
    fixedAnalogueGain: f64,
    config: AgcConfig,

    pub fn init() AgcChannel {
        return AgcChannel{
            .meteringMode = null,
            .exposureMode = null,
            .constraintMode = null,
            .mode = RPiController.CameraMode{},
            .frameCount = 0,
            .awb = RPiController.AwbStatus{},
            .current = ExposureValues{},
            .target = ExposureValues{},
            .filtered = ExposureValues{},
            .status = RPiController.AgcStatus{},
            .lockCount = 0,
            .lastDeviceStatus = RPiController.DeviceStatus{},
            .lastTargetExposure = 0,
            .meteringModeName = "",
            .exposureModeName = "",
            .constraintModeName = "",
            .ev = 1.0,
            .flickerPeriod = 0,
            .maxExposureTime = 0,
            .fixedExposureTime = 0,
            .fixedAnalogueGain = 0.0,
            .config = AgcConfig{},
        };
    }

    pub fn read(self: *AgcChannel, params: YamlObject, hardwareConfig: RPiController.HardwareConfig) !void {
        self.config.read(params) catch return error.Invalid;

        const size = hardwareConfig.agcZoneWeights;
        for (modes in self.config.meteringModes.items) |entry| {
            if (entry.value.weights.len != size.width * size.height) {
                return error.Invalid;
            }
        }

        self.meteringModeName = self.config.defaultMeteringMode;
        self.meteringMode = self.config.meteringModes.get(self.meteringModeName) orelse return error.Invalid;
        self.exposureModeName = self.config.defaultExposureMode;
        self.exposureMode = self.config.exposureModes.get(self.exposureModeName) orelse return error.Invalid;
        self.constraintModeName = self.config.defaultConstraintMode;
        self.constraintMode = self.config.constraintModes.get(self.constraintModeName) orelse return error.Invalid;

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

    pub fn getConvergenceFrames(self: *const AgcChannel) u32 {
        if (self.fixedExposureTime != 0 and self.fixedAnalogueGain != 0) {
            return 0;
        } else {
            return self.config.convergenceFrames;
        }
    }

    pub fn getWeights(self: *const AgcChannel) []const f64 {
        const it = self.config.meteringModes.get(self.meteringModeName);
        if (it == null) {
            return self.meteringMode.weights.items;
        }
        return it.weights.items;
    }

    pub fn setEv(self: *AgcChannel, ev: f64) void {
        self.ev = ev;
    }

    pub fn setFlickerPeriod(self: *AgcChannel, flickerPeriod: libcamera.utils.Duration) void {
        self.flickerPeriod = flickerPeriod;
    }

    pub fn setMaxExposureTime(self: *AgcChannel, maxExposureTime: libcamera.utils.Duration) void {
        self.maxExposureTime = maxExposureTime;
    }

    pub fn setFixedExposureTime(self: *AgcChannel, fixedExposureTime: libcamera.utils.Duration) void {
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

    pub fn switchMode(self: *AgcChannel, cameraMode: RPiController.CameraMode, metadata: *Metadata) void {
        self.housekeepConfig();

        const lastSensitivity = self.mode.sensitivity;
        self.mode = cameraMode;

        const fixedExposureTime = self.limitExposureTime(self.fixedExposureTime);
        if (fixedExposureTime != 0 and self.fixedAnalogueGain != 0) {
            self.fetchAwbStatus(metadata);
            const minColourGain = std.math.min(self.awb.gainR, self.awb.gainG, self.awb.gainB, 1.0);
            self.target.totalExposureNoDG = fixedExposureTime * self.fixedAnalogueGain;
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
        var delayedStatus = RPiController.AgcStatus{};
        var prepareStatus = RPiController.AgcPrepareStatus{};

        self.fetchAwbStatus(imageMetadata);

        if (imageMetadata.get("agc.delayed_status", &delayedStatus) == 0) {
            totalExposureValue = delayedStatus.totalExposureValue;
        }

        prepareStatus.digitalGain = 1.0;
        prepareStatus.locked = false;

        if (self.status.totalExposureValue != 0) {
            var deviceStatus = RPiController.DeviceStatus{};
            if (imageMetadata.get("device.status", &deviceStatus) == 0) {
                const actualExposure = deviceStatus.exposureTime * deviceStatus.analogueGain;
                if (actualExposure != 0) {
                    const digitalGain = totalExposureValue / actualExposure;
                    prepareStatus.digitalGain = std.math.max(1.0, std.math.min(digitalGain, 4.0));
                    prepareStatus.locked = self.updateLockStatus(deviceStatus);
                }
            }
            imageMetadata.set("agc.prepare_status", prepareStatus);
        }
    }

    pub fn process(self: *AgcChannel, stats: StatisticsPtr, deviceStatus: RPiController.DeviceStatus, imageMetadata: *Metadata, channelTotalExposures: []const libcamera.utils.Duration) void {
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

    fn updateLockStatus(self: *AgcChannel, deviceStatus: RPiController.DeviceStatus) bool {
        const errorFactor = 0.10;
        const maxLockCount = 5;
        const resetMargin = 1.5;

        const exposureError = self.lastDeviceStatus.exposureTime * errorFactor + 200e-6;
        const gainError = self.lastDeviceStatus.analogueGain * errorFactor;
        const targetError = self.lastTargetExposure * errorFactor;

        if (deviceStatus.exposureTime > self.lastDeviceStatus.exposureTime - exposureError and
            deviceStatus.exposureTime < self.lastDeviceStatus.exposureTime + exposureError and
            deviceStatus.analogueGain > self.lastDeviceStatus.analogueGain - gainError and
            deviceStatus.analogueGain < self.lastDeviceStatus.analogueGain + gainError and
            self.status.targetExposureValue > self.lastTargetExposure - targetError and
            self.status.targetExposureValue < self.lastTargetExposure + targetError) {
            self.lockCount = std.math.min(self.lockCount + 1, maxLockCount);
        } else if (deviceStatus.exposureTime < self.lastDeviceStatus.exposureTime - resetMargin * exposureError or
                   deviceStatus.exposureTime > self.lastDeviceStatus.exposureTime + resetMargin * exposureError or
                   deviceStatus.analogueGain < self.lastDeviceStatus.analogueGain - resetMargin * gainError or
                   deviceStatus.analogueGain > self.lastDeviceStatus.analogueGain + resetMargin * gainError or
                   self.status.targetExposureValue < self.lastTargetExposure - resetMargin * targetError or
                   self.status.targetExposureValue > self.lastTargetExposure + resetMargin * targetError) {
            self.lockCount = 0;
        }

        self.lastDeviceStatus = deviceStatus;
        self.lastTargetExposure = self.status.targetExposureValue;

        return self.lockCount == maxLockCount;
    }

    fn housekeepConfig(self: *AgcChannel) void {
        self.status.ev = self.ev;
        self.status.fixedExposureTime = self.limitExposureTime(self.fixedExposureTime);
        self.status.fixedAnalogueGain = self.fixedAnalogueGain;
        self.status.flickerPeriod = self.flickerPeriod;

        if (std.mem.eql(u8, self.meteringModeName, self.status.meteringMode)) {
            const it = self.config.meteringModes.get(self.meteringModeName);
            if (it == null) {
                self.meteringModeName = self.status.meteringMode;
            } else {
                self.meteringMode = it;
                self.status.meteringMode = self.meteringModeName;
            }
        }
        if (std.mem.eql(u8, self.exposureModeName, self.status.exposureMode)) {
            const it = self.config.exposureModes.get(self.exposureModeName);
            if (it == null) {
                self.exposureModeName = self.status.exposureMode;
            } else {
                self.exposureMode = it;
                self.status.exposureMode = self.exposureModeName;
            }
        }
        if (std.mem.eql(u8, self.constraintModeName, self.status.constraintMode)) {
            const it = self.config.constraintModes.get(self.constraintModeName);
            if (it == null) {
                self.constraintModeName = self.status.constraintMode;
            } else {
                self.constraintMode = it;
                self.status.constraintMode = self.constraintModeName;
            }
        }
    }

    fn fetchCurrentExposure(self: *AgcChannel, deviceStatus: RPiController.DeviceStatus) void {
        self.current.exposureTime = deviceStatus.exposureTime;
        self.current.analogueGain = deviceStatus.analogueGain;
        self.current.totalExposureNoDG = self.current.exposureTime * self.current.analogueGain;
    }

    fn fetchAwbStatus(self: *AgcChannel, imageMetadata: *Metadata) void {
        if (imageMetadata.get("awb.status", &self.awb) != 0) {
            // No AWB status found
        }
    }

    fn computeGain(self: *AgcChannel, statistics: StatisticsPtr, imageMetadata: *Metadata, gain: *f64, targetY: *f64) void {
        var lux = RPiController.LuxStatus{ .lux = 400 };
        if (imageMetadata.get("lux.status", &lux) != 0) {
            // No lux level found
        }
        const h = statistics.yHist;
        const evGain = self.status.ev * self.config.baseEv;

        targetY.* = self.config.yTarget.eval(self.config.yTarget.domain().clamp(lux.lux));
        targetY.* = std.math.min(EvGainYTargetLimit, targetY.* * evGain);

        gain.* = 1.0;
        for (i in 0..8) {
            const initialY = computeInitialY(statistics, self.awb, self.meteringMode.weights.items, gain.*);
            const extraGain = std.math.min(10.0, targetY.* / (initialY + 0.001));
            gain.* *= extraGain;
            if (extraGain < 1.01) {
                break;
            }
        }

        for (c in self.constraintMode.items) |constraint| {
            var newTargetY: f64 = 0;
            const newGain = constraintComputeGain(constraint, h, lux.lux, evGain, &newTargetY);
            if (constraint.bound == AgcConstraint.Bound.LOWER and newGain > gain.*) {
                gain.* = newGain;
                targetY.* = newTargetY;
            } else if (constraint.bound == AgcConstraint.Bound.UPPER and newGain < gain.*) {
                gain.* = newGain;
                targetY.* = newTargetY;
            }
        }
    }

    fn computeTargetExposure(self: *AgcChannel, gain: f64) void {
        if (self.status.fixedExposureTime != 0 and self.status.fixedAnalogueGain != 0) {
            const minColourGain = std.math.min(self.awb.gainR, self.awb.gainG, self.awb.gainB, 1.0);
            self.target.totalExposure = self.status.fixedExposureTime * self.status.fixedAnalogueGain / minColourGain;
        } else {
            self.target.totalExposure = self.current.totalExposureNoDG * gain;
            const maxExposureTime = self.status.fixedExposureTime != 0 ? self.status.fixedExposureTime : self.exposureMode.exposureTime.back();
            const maxTotalExposure = maxExposureTime * (self.status.fixedAnalogueGain != 0 ? self.status.fixedAnalogueGain : self.exposureMode.gain.back());
            self.target.totalExposure = std.math.min(self.target.totalExposure, maxTotalExposure);
        }
    }

    fn applyChannelConstraints(self: *AgcChannel, channelTotalExposures: []const libcamera.utils.Duration) bool {
        var channelBound = false;

        for (constraint in self.config.channelConstraints.items) |channelConstraint| {
            if (channelConstraint.channel >= channelTotalExposures.len or channelTotalExposures[channelConstraint.channel] == 0) {
                continue;
            }

            const limitExposure = channelTotalExposures[channelConstraint.channel] * channelConstraint.factor;
            if ((channelConstraint.bound == AgcChannelConstraint.Bound.UPPER and self.filtered.totalExposure > limitExposure) or
                (channelConstraint.bound == AgcChannelConstraint.Bound.LOWER and self.filtered.totalExposure < limitExposure)) {
                self.filtered.totalExposure = limitExposure;
                channelBound = true;
            }
        }

        return channelBound;
    }

    fn applyDigitalGain(self: *AgcChannel, gain: f64, targetY: f64, channelBound: bool) bool {
        const minColourGain = std.math.min(self.awb.gainR, self.awb.gainG, self.awb.gainB, 1.0);
        var dg = 1.0 / minColourGain;

        var desaturate = false;
        if (self.config.desaturate) {
            desaturate = !channelBound and targetY > self.config.fastReduceThreshold and gain < std.math.sqrt(targetY);
        }
        if (desaturate) {
            dg /= self.config.fastReduceThreshold;
        }
        self.filtered.totalExposureNoDG = self.filtered.totalExposure / dg;
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
        } else if (self.filtered.totalExposure * (1.0 - stableRegion) < self.target.totalExposure and
                   self.filtered.totalExposure * (1.0 + stableRegion) > self.target.totalExposure) {
        } else {
            if (self.filtered.totalExposure < 1.2 * self.target.totalExposure and
                self.filtered.totalExposure > 0.8 * self.target.totalExposure) {
                speed = std.math.sqrt(speed);
            }
            self.filtered.totalExposure = speed * self.target.totalExposure + self.filtered.totalExposure * (1.0 - speed);
        }
    }

    fn divideUpExposure(self: *AgcChannel) void {
        var exposureValue = self.filtered.totalExposureNoDG;
        var exposureTime = self.status.fixedExposureTime != 0 ? self.status.fixedExposureTime : self.exposureMode.exposureTime[0];
        exposureTime = self.limitExposureTime(exposureTime);
        var analogueGain = self.status.fixedAnalogueGain != 0 ? self.status.fixedAnalogueGain : self.exposureMode.gain[0];
        analogueGain = self.limitGain(analogueGain);

        if (exposureTime * analogueGain < exposureValue) {
            for (stage in 1..self.exposureMode.gain.len) {
                if (self.status.fixedExposureTime == 0) {
                    const stageExposureTime = self.limitExposureTime(self.exposureMode.exposureTime[stage]);
                    if (stageExposureTime * analogueGain >= exposureValue) {
                        exposureTime = exposureValue / analogueGain;
                        break;
                    }
                    exposureTime = stageExposureTime;
                }
                if (self.status.fixedAnalogueGain == 0) {
                    if (self.exposureMode.gain[stage] * exposureTime >= exposureValue) {
                        analogueGain = exposureValue / exposureTime;
                        break;
                    }
                    analogueGain = self.exposureMode.gain[stage];
                    analogueGain = self.limitGain(analogueGain);
                }
            }
        }

        if (self.status.fixedExposureTime == 0 and self.status.fixedAnalogueGain == 0 and self.status.flickerPeriod != 0) {
            const flickerPeriods = exposureTime / self.status.flickerPeriod;
            if (flickerPeriods != 0) {
                const newExposureTime = flickerPeriods * self.status.flickerPeriod;
                analogueGain *= exposureTime / newExposureTime;
                analogueGain = std.math.min(analogueGain, self.exposureMode.gain.back());
                analogueGain = self.limitGain(analogueGain);
                exposureTime = newExposureTime;
            }
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
    }

    fn limitExposureTime(self: *AgcChannel, exposureTime: libcamera.utils.Duration) libcamera.utils.Duration {
        if (exposureTime == 0) {
            return exposureTime;
        }
        return std.math.clamp(exposureTime, self.mode.minExposureTime, self.maxExposureTime);
    }

    fn limitGain(self: *AgcChannel, gain: f64) f64 {
        if (gain == 0) {
            return gain;
        }
        return std.math.max(gain, self.mode.minAnalogueGain);
    }
};

const ExposureValues = struct {
    exposureTime: libcamera.utils.Duration,
    analogueGain: f64,
    totalExposure: libcamera.utils.Duration,
    totalExposureNoDG: libcamera.utils.Duration,

    pub fn init() ExposureValues {
        return ExposureValues{
            .exposureTime = 0,
            .analogueGain = 0,
            .totalExposure = 0,
            .totalExposureNoDG = 0,
        };
    }
};

fn computeInitialY(stats: StatisticsPtr, awb: RPiController.AwbStatus, weights: []const f64, gain: f64) f64 {
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

    var sum = ipa.RGB{ .r = 0.0, .g = 0.0, .b = 0.0 };
    var pixelSum = 0.0;
    for (i in 0..stats.agcRegions.numRegions()) {
        const region = stats.agcRegions.get(i);
        sum.r += std.math.min(region.val.rSum * gain, (maxVal - 1) * region.counted);
        sum.g += std.math.min(region.val.gSum * gain, (maxVal - 1) * region.counted);
        sum.b += std.math.min(region.val.bSum * gain, (maxVal - 1) * region.counted);
        pixelSum += region.counted;
    }
    if (pixelSum == 0.0) {
        return 0;
    }

    if (stats.agcStatsPos == RPiController.Statistics.AgcStatsPos.PreWb) {
        sum.r *= awb.gainR;
        sum.g *= awb.gainG;
        sum.b *= awb.gainB;
    }

    const ySum = ipa.rec601LuminanceFromRGB(sum);
    return ySum / pixelSum / (1 << 16);
}

fn constraintComputeGain(c: AgcConstraint, h: RPiController.Histogram, lux: f64, evGain: f64, targetY: *f64) f64 {
    targetY.* = c.yTarget.eval(c.yTarget.domain().clamp(lux));
    targetY.* = std.math.min(EvGainYTargetLimit, targetY.* * evGain);
    const iqm = h.interQuantileMean(c.qLo, c.qHi);
    return (targetY.* * h.bins()) / iqm;
}
