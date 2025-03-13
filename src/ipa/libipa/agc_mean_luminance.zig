const std = @import("std");
const log = @import("log");
const yaml = @import("yaml");
const exposure_mode_helper = @import("exposure_mode_helper");
const histogram = @import("histogram");

const AgcMeanLuminance = struct {
    pub const AgcConstraint = struct {
        pub const Bound = enum {
            Lower,
            Upper,
        };
        bound: Bound,
        qLo: f64,
        qHi: f64,
        yTarget: f64,
    };

    frameCount: u64,
    filteredExposure: std.time.Duration,
    relativeLuminanceTarget: f64,
    constraintModes: std.StringHashMap([]AgcConstraint),
    exposureModeHelpers: std.StringHashMap(*exposure_mode_helper.ExposureModeHelper),
    controls: std.StringHashMap(yaml.ControlInfo),

    pub fn init() AgcMeanLuminance {
        return AgcMeanLuminance{
            .frameCount = 0,
            .filteredExposure = std.time.Duration{},
            .relativeLuminanceTarget = 0,
            .constraintModes = std.StringHashMap([]AgcConstraint).init(std.heap.page_allocator),
            .exposureModeHelpers = std.StringHashMap(*exposure_mode_helper.ExposureModeHelper).init(std.heap.page_allocator),
            .controls = std.StringHashMap(yaml.ControlInfo).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *AgcMeanLuminance) void {
        self.constraintModes.deinit();
        self.exposureModeHelpers.deinit();
        self.controls.deinit();
    }

    pub fn parseTuningData(self: *AgcMeanLuminance, tuningData: yaml.YamlObject) !void {
        self.parseRelativeLuminanceTarget(tuningData) catch |err| return err;
        self.parseConstraintModes(tuningData) catch |err| return err;
        self.parseExposureModes(tuningData) catch |err| return err;
    }

    fn parseRelativeLuminanceTarget(self: *AgcMeanLuminance, tuningData: yaml.YamlObject) !void {
        self.relativeLuminanceTarget = tuningData.get("relativeLuminanceTarget").getOptional(f64).catch(0.16);
    }

    fn parseConstraint(self: *AgcMeanLuminance, modeDict: yaml.YamlObject, id: i32) !void {
        for (modeDict.items()) |item| {
            const boundName = item.key;
            const content = item.value;

            if (boundName != "upper" and boundName != "lower") {
                log.warn("Ignoring unknown constraint bound '{s}'", .{boundName});
                continue;
            }

            const idx = if (boundName == "upper") 1 else 0;
            const bound = if (idx == 1) AgcConstraint.Bound.Upper else AgcConstraint.Bound.Lower;
            const qLo = content.get("qLo").getOptional(f64).catch(0.98);
            const qHi = content.get("qHi").getOptional(f64).catch(1.0);
            const yTarget = content.get("yTarget").getList(f64).catch([]f64{0.5})[0];

            const constraint = AgcConstraint{
                .bound = bound,
                .qLo = qLo,
                .qHi = qHi,
                .yTarget = yTarget,
            };

            if (!self.constraintModes.contains(id)) {
                self.constraintModes.put(id, []AgcConstraint{});
            }

            if (idx == 1) {
                self.constraintModes.get(id).append(constraint);
            } else {
                self.constraintModes.get(id).insert(0, constraint);
            }
        }
    }

    fn parseConstraintModes(self: *AgcMeanLuminance, tuningData: yaml.YamlObject) !void {
        const availableConstraintModes = []yaml.ControlValue{};

        const yamlConstraintModes = tuningData.get("AeConstraintMode");
        if (yamlConstraintModes.isDictionary()) {
            for (yamlConstraintModes.items()) |item| {
                const modeName = item.key;
                const modeDict = item.value;

                if (!yaml.AeConstraintModeNameValueMap.contains(modeName)) {
                    log.warn("Skipping unknown constraint mode '{s}'", .{modeName});
                    continue;
                }

                if (!modeDict.isDictionary()) {
                    log.err("Invalid constraint mode '{s}'", .{modeName});
                    return error.InvalidConstraintMode;
                }

                self.parseConstraint(modeDict, yaml.AeConstraintModeNameValueMap.get(modeName)) catch |err| return err;
                availableConstraintModes.append(yaml.AeConstraintModeNameValueMap.get(modeName));
            }
        }

        if (self.constraintModes.size() == 0) {
            const constraint = AgcConstraint{
                .bound = AgcConstraint.Bound.Lower,
                .qLo = 0.98,
                .qHi = 1.0,
                .yTarget = 0.5,
            };

            self.constraintModes.put(yaml.AeConstraintModeNameValueMap.get("ConstraintNormal"), []AgcConstraint{constraint});
            availableConstraintModes.append(yaml.AeConstraintModeNameValueMap.get("ConstraintNormal"));
        }

        self.controls.put("AeConstraintMode", yaml.ControlInfo.init(availableConstraintModes));
    }

    fn parseExposureModes(self: *AgcMeanLuminance, tuningData: yaml.YamlObject) !void {
        const availableExposureModes = []yaml.ControlValue{};

        const yamlExposureModes = tuningData.get("AeExposureMode");
        if (yamlExposureModes.isDictionary()) {
            for (yamlExposureModes.items()) |item| {
                const modeName = item.key;
                const modeValues = item.value;

                if (!yaml.AeExposureModeNameValueMap.contains(modeName)) {
                    log.warn("Skipping unknown exposure mode '{s}'", .{modeName});
                    continue;
                }

                if (!modeValues.isDictionary()) {
                    log.err("Invalid exposure mode '{s}'", .{modeName});
                    return error.InvalidExposureMode;
                }

                const exposureTimes = modeValues.get("exposureTime").getList(u32).catch([]u32{});
                const gains = modeValues.get("gain").getList(f64).catch([]f64{});

                if (exposureTimes.len != gains.len) {
                    log.err("Exposure time and gain array sizes unequal");
                    return error.InvalidExposureMode;
                }

                if (exposureTimes.len == 0) {
                    log.err("Exposure time and gain arrays are empty");
                    return error.InvalidExposureMode;
                }

                const stages = []exposure_mode_helper.Stage{};
                for (exposureTimes) |exposureTime, i| {
                    stages.append(exposure_mode_helper.Stage{
                        .exposureTime = std.time.Duration{ .seconds = exposureTime },
                        .gain = gains[i],
                    });
                }

                const helper = exposure_mode_helper.ExposureModeHelper.init(stages);
                self.exposureModeHelpers.put(yaml.AeExposureModeNameValueMap.get(modeName), helper);
                availableExposureModes.append(yaml.AeExposureModeNameValueMap.get(modeName));
            }
        }

        if (availableExposureModes.len == 0) {
            const exposureModeId = yaml.AeExposureModeNameValueMap.get("ExposureNormal");
            const stages = []exposure_mode_helper.Stage{};
            const helper = exposure_mode_helper.ExposureModeHelper.init(stages);
            self.exposureModeHelpers.put(exposureModeId, helper);
            availableExposureModes.append(exposureModeId);
        }

        self.controls.put("AeExposureMode", yaml.ControlInfo.init(availableExposureModes));
    }

    pub fn setLimits(self: *AgcMeanLuminance, minExposureTime: std.time.Duration, maxExposureTime: std.time.Duration, minGain: f64, maxGain: f64) void {
        for (self.exposureModeHelpers.items()) |item| {
            const helper = item.value;
            helper.setLimits(minExposureTime, maxExposureTime, minGain, maxGain);
        }
    }

    pub fn constraintModes(self: *AgcMeanLuminance) std.StringHashMap([]AgcConstraint) {
        return self.constraintModes;
    }

    pub fn exposureModeHelpers(self: *AgcMeanLuminance) std.StringHashMap(*exposure_mode_helper.ExposureModeHelper) {
        return self.exposureModeHelpers;
    }

    pub fn controls(self: *AgcMeanLuminance) std.StringHashMap(yaml.ControlInfo) {
        return self.controls;
    }

    pub fn resetFrameCount(self: *AgcMeanLuminance) void {
        self.frameCount = 0;
    }

    fn estimateLuminance(self: *AgcMeanLuminance, gain: f64) f64 {
        // This function should be overridden by derived classes
        return 0.0;
    }

    fn estimateInitialGain(self: *AgcMeanLuminance) f64 {
        const yTarget = self.relativeLuminanceTarget;
        var yGain = 1.0;

        for (var i = 0; i < 8; i += 1) {
            const yValue = self.estimateLuminance(yGain);
            const extra_gain = std.math.min(10.0, yTarget / (yValue + 0.001));

            yGain *= extra_gain;
            log.debug("Y value: {f}, Y target: {f}, gives gain {f}", .{yValue, yTarget, yGain});

            if (std.math.abs(extra_gain - 1.0) < 0.01) {
                break;
            }
        }

        return yGain;
    }

    fn constraintClampGain(self: *AgcMeanLuminance, constraintModeIndex: u32, hist: histogram.Histogram, gain: f64) f64 {
        const constraints = self.constraintModes.get(constraintModeIndex);
        for (constraints) |constraint| {
            const newGain = constraint.yTarget * hist.bins() / hist.interQuantileMean(constraint.qLo, constraint.qHi);

            if (constraint.bound == AgcConstraint.Bound.Lower and newGain > gain) {
                gain = newGain;
            }

            if (constraint.bound == AgcConstraint.Bound.Upper and newGain < gain) {
                gain = newGain;
            }
        }

        return gain;
    }

    fn filterExposure(self: *AgcMeanLuminance, exposureValue: std.time.Duration) std.time.Duration {
        var speed = 0.2;

        if (self.frameCount < 10) {
            speed = 1.0;
        }

        if (self.filteredExposure < exposureValue * 1.2 and self.filteredExposure > exposureValue * 0.8) {
            speed = std.math.sqrt(speed);
        }

        self.filteredExposure = exposureValue * speed + self.filteredExposure * (1.0 - speed);

        return self.filteredExposure;
    }

    pub fn calculateNewEv(self: *AgcMeanLuminance, constraintModeIndex: u32, exposureModeIndex: u32, yHist: histogram.Histogram, effectiveExposureValue: std.time.Duration) !std.time.Duration {
        const exposureModeHelper = self.exposureModeHelpers.get(exposureModeIndex);

        var gain = self.estimateInitialGain();
        gain = self.constraintClampGain(constraintModeIndex, yHist, gain);

        var newExposureValue = effectiveExposureValue * gain;
        newExposureValue = self.filterExposure(newExposureValue);

        self.frameCount += 1;
        return exposureModeHelper.splitExposure(newExposureValue);
    }
};
