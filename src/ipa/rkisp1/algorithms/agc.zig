const std = @import("std");
const log = @import("log");
const utils = @import("utils");
const controls = @import("controls");
const core_ipa_interface = @import("core_ipa_interface");
const yaml_parser = @import("yaml_parser");
const histogram = @import("histogram");

const Agc = struct {
    meteringModes: std.AutoHashMap(i32, []u8),

    pub fn init(self: *Agc, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        var ret: i32 = self.parseTuningData(tuningData);
        if (ret != 0) return ret;

        const yamlMeteringModes = tuningData.get("AeMeteringMode");
        ret = self.parseMeteringModes(context, yamlMeteringModes);
        if (ret != 0) return ret;

        context.ctrlMap.put(&controls.AeEnable, ControlInfo{ .min = false, .max = true });
        context.ctrlMap.merge(self.controls());

        return 0;
    }

    pub fn configure(self: *Agc, context: *IPAContext, configInfo: *IPACameraSensorInfo) i32 {
        context.activeState.agc.automatic.gain = context.configuration.sensor.minAnalogueGain;
        context.activeState.agc.automatic.exposure = 10 * 1000 * 1000 / context.configuration.sensor.lineDuration;
        context.activeState.agc.manual.gain = context.activeState.agc.automatic.gain;
        context.activeState.agc.manual.exposure = context.activeState.agc.automatic.exposure;
        context.activeState.agc.autoEnabled = !context.configuration.raw;

        context.activeState.agc.constraintMode = @intCast(controls.AeConstraintModeEnum, self.constraintModes().keys().next().?);
        context.activeState.agc.exposureMode = @intCast(controls.AeExposureModeEnum, self.exposureModeHelpers().keys().next().?);
        context.activeState.agc.meteringMode = @intCast(controls.AeMeteringModeEnum, self.meteringModes.keys().next().?);

        context.activeState.agc.maxFrameDuration = context.configuration.sensor.maxExposureTime;

        context.configuration.agc.measureWindow.h_offs = configInfo.outputSize.width / 8;
        context.configuration.agc.measureWindow.v_offs = configInfo.outputSize.height / 8;
        context.configuration.agc.measureWindow.h_size = 3 * configInfo.outputSize.width / 4;
        context.configuration.agc.measureWindow.v_size = 3 * configInfo.outputSize.height / 4;

        self.setLimits(context.configuration.sensor.minExposureTime, context.configuration.sensor.maxExposureTime, context.configuration.sensor.minAnalogueGain, context.configuration.sensor.maxAnalogueGain);

        self.resetFrameCount();

        return 0;
    }

    pub fn queueRequest(self: *Agc, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, controls: *ControlList) void {
        var agc = &context.activeState.agc;

        if (!context.configuration.raw) {
            const agcEnable = controls.get(controls.AeEnable);
            if (agcEnable != null and *agcEnable != agc.autoEnabled) {
                agc.autoEnabled = *agcEnable;
                log.debug("RkISP1Agc", "{s} AGC", .{ if (agc.autoEnabled) "Enabling" else "Disabling" });
            }
        }

        const exposure = controls.get(controls.ExposureTime);
        if (exposure != null and !agc.autoEnabled) {
            agc.manual.exposure = *exposure * 1.0 / context.configuration.sensor.lineDuration;
            log.debug("RkISP1Agc", "Set exposure to {d}", .{ agc.manual.exposure });
        }

        const gain = controls.get(controls.AnalogueGain);
        if (gain != null and !agc.autoEnabled) {
            agc.manual.gain = *gain;
            log.debug("RkISP1Agc", "Set gain to {d}", .{ agc.manual.gain });
        }

        frameContext.agc.autoEnabled = agc.autoEnabled;

        if (!frameContext.agc.autoEnabled) {
            frameContext.agc.exposure = agc.manual.exposure;
            frameContext.agc.gain = agc.manual.gain;
        }

        const meteringMode = controls.get(controls.AeMeteringMode);
        if (meteringMode != null) {
            frameContext.agc.updateMetering = agc.meteringMode != *meteringMode;
            agc.meteringMode = @intCast(controls.AeMeteringModeEnum, *meteringMode);
        }
        frameContext.agc.meteringMode = agc.meteringMode;

        const exposureMode = controls.get(controls.AeExposureMode);
        if (exposureMode != null) {
            agc.exposureMode = @intCast(controls.AeExposureModeEnum, *exposureMode);
        }
        frameContext.agc.exposureMode = agc.exposureMode;

        const constraintMode = controls.get(controls.AeConstraintMode);
        if (constraintMode != null) {
            agc.constraintMode = @intCast(controls.AeConstraintModeEnum, *constraintMode);
        }
        frameContext.agc.constraintMode = agc.constraintMode;

        const frameDurationLimits = controls.get(controls.FrameDurationLimits);
        if (frameDurationLimits != null) {
            const maxFrameDuration = std.chrono.milliseconds((*frameDurationLimits).back());
            agc.maxFrameDuration = maxFrameDuration;
        }
        frameContext.agc.maxFrameDuration = agc.maxFrameDuration;
    }

    pub fn prepare(self: *Agc, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        if (frameContext.agc.autoEnabled) {
            frameContext.agc.exposure = context.activeState.agc.automatic.exposure;
            frameContext.agc.gain = context.activeState.agc.automatic.gain;
        }

        if (frame > 0 and !frameContext.agc.updateMetering) return;

        const aecConfig = params.block(BlockType.Aec);
        aecConfig.setEnabled(true);

        aecConfig.meas_window = context.configuration.agc.measureWindow;
        aecConfig.autostop = RKISP1_CIF_ISP_EXP_CTRL_AUTOSTOP_0;
        aecConfig.mode = RKISP1_CIF_ISP_EXP_MEASURING_MODE_1;

        const hstConfig = params.block(BlockType.Hst);
        hstConfig.setEnabled(true);

        hstConfig.meas_window = context.configuration.agc.measureWindow;
        hstConfig.mode = RKISP1_CIF_ISP_HISTOGRAM_MODE_Y_HISTOGRAM;

        const weights = hstConfig.hist_weight[0..context.hw.numHistogramWeights];
        const modeWeights = self.meteringModes.get(frameContext.agc.meteringMode).?;
        std.mem.copy(u8, weights, modeWeights);

        const window = hstConfig.meas_window;
        const windowSize = Size{ .width = window.h_size, .height = window.v_size };
        hstConfig.histogram_predivider = self.computeHistogramPredivider(windowSize, @intCast(rkisp1_cif_isp_histogram_mode, hstConfig.mode));
    }

    pub fn process(self: *Agc, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *rkisp1_stat_buffer, metadata: *ControlList) void {
        if (stats == null) {
            self.fillMetadata(context, frameContext, metadata);
            return;
        }

        if (!(stats.meas_type & RKISP1_CIF_ISP_STAT_AUTOEXP)) {
            self.fillMetadata(context, frameContext, metadata);
            log.error("RkISP1Agc", "AUTOEXP data is missing in statistics");
            return;
        }

        const params = &stats.params;

        const hist = Histogram{ .data = params.hist.hist_bins[0..context.hw.numHistogramBins], .transform = |x| x >> 4 };
        self.expMeans = params.ae.exp_mean[0..context.hw.numAeCells];

        const maxExposureTime = std.math.clamp(frameContext.agc.maxFrameDuration, context.configuration.sensor.minExposureTime, context.configuration.sensor.maxExposureTime);
        self.setLimits(context.configuration.sensor.minExposureTime, maxExposureTime, context.configuration.sensor.minAnalogueGain, context.configuration.sensor.maxAnalogueGain);

        const exposureTime = context.configuration.sensor.lineDuration * frameContext.sensor.exposure;
        const analogueGain = frameContext.sensor.gain;
        const effectiveExposureValue = exposureTime * analogueGain;

        const newExposureTime = self.calculateNewEv(frameContext.agc.constraintMode, frameContext.agc.exposureMode, hist, effectiveExposureValue);

        log.debug("RkISP1Agc", "Divided up exposure time, analogue gain and digital gain are {d}, {d} and {d}", .{ newExposureTime, aGain, dGain });

        context.activeState.agc.automatic.exposure = newExposureTime / context.configuration.sensor.lineDuration;
        context.activeState.agc.automatic.gain = aGain;

        self.fillMetadata(context, frameContext, metadata);
        self.expMeans = null;
    }

    fn parseMeteringModes(self: *Agc, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        if (!tuningData.isDictionary()) {
            log.warning("RkISP1Agc", "'AeMeteringMode' parameter not found in tuning file");
        }

        for (const [key, value] : tuningData.asDict()) {
            if (controls.AeMeteringModeNameValueMap.get(key) == null) {
                log.warning("RkISP1Agc", "Skipping unknown metering mode '{s}'", .{ key });
                continue;
            }

            const weights = value.getList(u8).? orelse std.ArrayList(u8).init();
            if (weights.len != context.hw.numHistogramWeights) {
                log.warning("RkISP1Agc", "Failed to read metering mode '{s}'", .{ key });
                continue;
            }

            self.meteringModes.put(controls.AeMeteringModeNameValueMap.get(key).?, weights);
        }

        if (self.meteringModes.len == 0) {
            log.warning("RkISP1Agc", "No metering modes read from tuning file; defaulting to matrix");
            const meteringModeId = controls.AeMeteringModeNameValueMap.get("MeteringMatrix").?;
            const weights = std.ArrayList(u8).init();
            weights.ensureTotalCapacity(context.hw.numHistogramWeights);
            for (var i: usize = 0; i < context.hw.numHistogramWeights; i += 1) {
                weights.append(1);
            }
            self.meteringModes.put(meteringModeId, weights);
        }

        const meteringModes = std.ArrayList(ControlValue).init();
        const meteringModeKeys = utils.map_keys(self.meteringModes);
        for (const key : meteringModeKeys) {
            meteringModes.append(ControlValue{ .i32 = key });
        }
        context.ctrlMap.put(&controls.AeMeteringMode, ControlInfo{ .values = meteringModes });

        return 0;
    }

    fn computeHistogramPredivider(self: *Agc, size: Size, mode: rkisp1_cif_isp_histogram_mode) u8 {
        const count = if (mode == RKISP1_CIF_ISP_HISTOGRAM_MODE_RGB_COMBINED) 3 else 1;
        const factor = size.width * size.height * count / 65536.0;
        const root = std.math.sqrt(factor);
        const predivider = @intCast(u8, std.math.ceil(root));

        return std.math.clamp(predivider, 3, 127);
    }

    fn fillMetadata(self: *Agc, context: *IPAContext, frameContext: *IPAFrameContext, metadata: *ControlList) void {
        const exposureTime = context.configuration.sensor.lineDuration * frameContext.sensor.exposure;
        metadata.set(controls.AnalogueGain, frameContext.sensor.gain);
        metadata.set(controls.ExposureTime, exposureTime.getMicroseconds());
        metadata.set(controls.AeEnable, frameContext.agc.autoEnabled);

        const vTotal = context.configuration.sensor.size.height + context.configuration.sensor.defVBlank;
        const frameDuration = context.configuration.sensor.lineDuration * vTotal;
        metadata.set(controls.FrameDuration, frameDuration.getMicroseconds());

        metadata.set(controls.AeMeteringMode, frameContext.agc.meteringMode);
        metadata.set(controls.AeExposureMode, frameContext.agc.exposureMode);
        metadata.set(controls.AeConstraintMode, frameContext.agc.constraintMode);
    }

    fn estimateLuminance(self: *Agc, gain: f64) f64 {
        var ySum: f64 = 0.0;

        for (const expMean : self.expMeans) {
            ySum += std.math.min(expMean * gain, 255.0);
        }

        return ySum / self.expMeans.len / 255.0;
    }
};

pub fn main() void {
    const agc = Agc{};
    // Example usage of the Agc struct
}
