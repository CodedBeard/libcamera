const std = @import("std");
const log = @import("log");
const utils = @import("utils");
const controls = @import("controls");
const properties = @import("properties");
const colours = @import("colours");
const fixedpoint = @import("fixedpoint");

const MaliC55Agc = log.defineCategory("MaliC55Agc");

const kNumHistogramBins = 256;
const kMinDigitalGain = 1.0;
const kMaxDigitalGain = 31.99609375;

const AgcStatistics = struct {
    rHist: Histogram,
    gHist: Histogram,
    bHist: Histogram,
    yHist: Histogram,
    rIndex_: u32,
    grIndex_: u32,
    gbIndex_: u32,
    bIndex_: u32,

    pub fn init() AgcStatistics {
        return AgcStatistics{
            .rHist = Histogram.init(),
            .gHist = Histogram.init(),
            .bHist = Histogram.init(),
            .yHist = Histogram.init(),
            .rIndex_ = 0,
            .grIndex_ = 0,
            .gbIndex_ = 0,
            .bIndex_ = 0,
        };
    }

    pub fn decodeBinValue(binVal: u16) u32 {
        const exponent = (binVal & 0xf000) >> 12;
        const mantissa = binVal & 0xfff;

        if (exponent == 0) {
            return mantissa * 2;
        } else {
            return (mantissa + 4096) * std.math.pow(2, exponent);
        }
    }

    pub fn setBayerOrderIndices(self: *AgcStatistics, bayerOrder: BayerFormat.Order) !void {
        switch (bayerOrder) {
            BayerFormat.Order.RGGB => {
                self.rIndex_ = 0;
                self.grIndex_ = 1;
                self.gbIndex_ = 2;
                self.bIndex_ = 3;
            },
            BayerFormat.Order.GRBG => {
                self.grIndex_ = 0;
                self.rIndex_ = 1;
                self.bIndex_ = 2;
                self.gbIndex_ = 3;
            },
            BayerFormat.Order.GBRG => {
                self.gbIndex_ = 0;
                self.bIndex_ = 1;
                self.rIndex_ = 2;
                self.grIndex_ = 3;
            },
            BayerFormat.Order.BGGR => {
                self.bIndex_ = 0;
                self.gbIndex_ = 1;
                self.grIndex_ = 2;
                self.rIndex_ = 3;
            },
            else => {
                log.error(MaliC55Agc, "Invalid bayer format {}", .{bayerOrder});
                return error.InvalidBayerFormat;
            },
        }
    }

    pub fn parseStatistics(self: *AgcStatistics, stats: *const mali_c55_stats_buffer) void {
        var r: [256]u32 = undefined;
        var g: [256]u32 = undefined;
        var b: [256]u32 = undefined;
        var y: [256]u32 = undefined;

        for (i: u32 = 0; i < 256; i += 1) {
            r[i] = self.decodeBinValue(stats.ae_1024bin_hist.bins[i + (256 * self.rIndex_)]);
            g[i] = (self.decodeBinValue(stats.ae_1024bin_hist.bins[i + (256 * self.grIndex_)]) +
                    self.decodeBinValue(stats.ae_1024bin_hist.bins[i + (256 * self.gbIndex_)])) / 2;
            b[i] = self.decodeBinValue(stats.ae_1024bin_hist.bins[i + (256 * self.bIndex_)]);

            y[i] = colours.rec601LuminanceFromRGB(.{r[i], g[i], b[i]});
        }

        self.rHist = Histogram.initFromSlice(&r);
        self.gHist = Histogram.initFromSlice(&g);
        self.bHist = Histogram.initFromSlice(&b);
        self.yHist = Histogram.initFromSlice(&y);
    }
};

const Agc = struct {
    statistics: AgcStatistics,

    pub fn init() Agc {
        return Agc{
            .statistics = AgcStatistics.init(),
        };
    }

    pub fn init(self: *Agc, context: *IPAContext, tuningData: *const YamlObject) !void {
        try self.parseTuningData(tuningData);

        context.ctrlMap[&controls.AeEnable] = ControlInfo{.min = false, .max = true};
        context.ctrlMap[&controls.DigitalGain] = ControlInfo{
            .min = kMinDigitalGain,
            .max = kMaxDigitalGain,
            .def = kMinDigitalGain,
        };
        context.ctrlMap.merge(self.controls());
    }

    pub fn configure(self: *Agc, context: *IPAContext, configInfo: *const IPACameraSensorInfo) !void {
        try self.statistics.setBayerOrderIndices(context.configuration.sensor.bayerOrder);

        context.activeState.agc.autoEnabled = true;
        context.activeState.agc.automatic.sensorGain = context.configuration.agc.minAnalogueGain;
        context.activeState.agc.automatic.exposure = context.configuration.agc.defaultExposure;
        context.activeState.agc.automatic.ispGain = kMinDigitalGain;
        context.activeState.agc.manual.sensorGain = context.configuration.agc.minAnalogueGain;
        context.activeState.agc.manual.exposure = context.configuration.agc.defaultExposure;
        context.activeState.agc.manual.ispGain = kMinDigitalGain;
        context.activeState.agc.constraintMode = self.constraintModes().begin().?.first;
        context.activeState.agc.exposureMode = self.exposureModeHelpers().begin().?.first;

        self.setLimits(context.configuration.agc.minShutterSpeed,
                       context.configuration.agc.maxShutterSpeed,
                       context.configuration.agc.minAnalogueGain,
                       context.configuration.agc.maxAnalogueGain);

        self.resetFrameCount();
    }

    pub fn queueRequest(self: *Agc, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, controls: *const ControlList) void {
        var agc = &context.activeState.agc;

        const constraintMode = controls.get(controls.AeConstraintMode);
        agc.constraintMode = constraintMode orelse agc.constraintMode;

        const exposureMode = controls.get(controls.AeExposureMode);
        agc.exposureMode = exposureMode orelse agc.exposureMode;

        const agcEnable = controls.get(controls.AeEnable);
        if (agcEnable) |enable| {
            if (enable != agc.autoEnabled) {
                agc.autoEnabled = enable;
                log.info(MaliC55Agc, "{} AGC", .{if (agc.autoEnabled) "Enabling" else "Disabling"});
            }
        }

        if (agc.autoEnabled) return;

        const exposure = controls.get(controls.ExposureTime);
        if (exposure) |exp| {
            agc.manual.exposure = exp * 1.0 / context.configuration.sensor.lineDuration;
            log.debug(MaliC55Agc, "Exposure set to {} on request sequence {}", .{agc.manual.exposure, frame});
        }

        const analogueGain = controls.get(controls.AnalogueGain);
        if (analogueGain) |gain| {
            agc.manual.sensorGain = gain;
            log.debug(MaliC55Agc, "Analogue gain set to {} on request sequence {}", .{agc.manual.sensorGain, frame});
        }

        const digitalGain = controls.get(controls.DigitalGain);
        if (digitalGain) |gain| {
            agc.manual.ispGain = gain;
            log.debug(MaliC55Agc, "Digital gain set to {} on request sequence {}", .{agc.manual.ispGain, frame});
        }
    }

    pub fn fillGainParamBlock(self: *Agc, context: *IPAContext, frameContext: *IPAFrameContext, block: *mali_c55_params_block) usize {
        const activeState = &context.activeState;
        const gain = if (activeState.agc.autoEnabled) activeState.agc.automatic.ispGain else activeState.agc.manual.ispGain;

        block.header.type = MALI_C55_PARAM_BLOCK_DIGITAL_GAIN;
        block.header.flags = MALI_C55_PARAM_BLOCK_FL_NONE;
        block.header.size = @sizeOf(mali_c55_params_digital_gain);

        block.digital_gain.gain = fixedpoint.floatingToFixedPoint(5, 8, gain);
        frameContext.agc.ispGain = gain;

        return block.header.size;
    }

    pub fn fillParamsBuffer(self: *Agc, block: *mali_c55_params_block, type: mali_c55_param_block_type) usize {
        block.header.type = type;
        block.header.flags = MALI_C55_PARAM_BLOCK_FL_NONE;
        block.header.size = @sizeOf(mali_c55_params_aexp_hist);

        block.aexp_hist.skip_x = 1;
        block.aexp_hist.offset_x = 0;
        block.aexp_hist.skip_y = 0;
        block.aexp_hist.offset_y = 0;
        block.aexp_hist.scale_bottom = 0;
        block.aexp_hist.scale_top = 0;
        block.aexp_hist.plane_mode = 1;
        block.aexp_hist.tap_point = MALI_C55_AEXP_HIST_TAP_FS;

        return block.header.size;
    }

    pub fn fillWeightsArrayBuffer(self: *Agc, block: *mali_c55_params_block, type: mali_c55_param_block_type) usize {
        block.header.type = type;
        block.header.flags = MALI_C55_PARAM_BLOCK_FL_NONE;
        block.header.size = @sizeOf(mali_c55_params_aexp_weights);

        block.aexp_weights.nodes_used_horiz = 15;
        block.aexp_weights.nodes_used_vert = 15;

        var weights = block.aexp_weights.zone_weights[0..MALI_C55_MAX_ZONES];
        std.mem.set(u8, &weights, 1);

        return block.header.size;
    }

    pub fn prepare(self: *Agc, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *mali_c55_params_buffer) void {
        var block = &params.data[params.total_size];
        params.total_size += self.fillGainParamBlock(context, frameContext, block);

        if (frame > 0) return;

        block = &params.data[params.total_size];
        params.total_size += self.fillParamsBuffer(block, MALI_C55_PARAM_BLOCK_AEXP_HIST);

        block = &params.data[params.total_size];
        params.total_size += self.fillWeightsArrayBuffer(block, MALI_C55_PARAM_BLOCK_AEXP_HIST_WEIGHTS);

        block = &params.data[params.total_size];
        params.total_size += self.fillParamsBuffer(block, MALI_C55_PARAM_BLOCK_AEXP_IHIST);

        block = &params.data[params.total_size];
        params.total_size += self.fillWeightsArrayBuffer(block, MALI_C55_PARAM_BLOCK_AEXP_IHIST_WEIGHTS);
    }

    pub fn estimateLuminance(self: *const Agc, gain: f64) f64 {
        const rAvg = self.statistics.rHist.interQuantileMean(0, 1) * gain;
        const gAvg = self.statistics.gHist.interQuantileMean(0, 1) * gain;
        const bAvg = self.statistics.bHist.interQuantileMean(0, 1) * gain;
        const yAvg = colours.rec601LuminanceFromRGB(.{rAvg, gAvg, bAvg});

        return yAvg / kNumHistogramBins;
    }

    pub fn process(self: *Agc, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *const mali_c55_stats_buffer, metadata: *ControlList) void {
        const configuration = &context.configuration;
        const activeState = &context.activeState;

        if (stats == null) {
            log.error(MaliC55Agc, "No statistics buffer passed to Agc");
            return;
        }

        self.statistics.parseStatistics(stats);
        context.activeState.agc.temperatureK = self.estimateCCT(.{self.statistics.rHist.interQuantileMean(0, 1), self.statistics.gHist.interQuantileMean(0, 1), self.statistics.bHist.interQuantileMean(0, 1)});

        const exposure = frameContext.agc.exposure;
        const analogueGain = frameContext.agc.sensorGain;
        const digitalGain = frameContext.agc.ispGain;
        const totalGain = analogueGain * digitalGain;
        const currentShutter = exposure * configuration.sensor.lineDuration;
        const effectiveExposureValue = currentShutter * totalGain;

        const (shutterTime, aGain, dGain) = self.calculateNewEv(activeState.agc.constraintMode, activeState.agc.exposureMode, self.statistics.yHist, effectiveExposureValue);

        dGain = std.math.clamp(dGain, kMinDigitalGain, kMaxDigitalGain);

        log.debug(MaliC55Agc, "Divided up shutter, analogue gain and digital gain are {}, {}, and {}", .{shutterTime, aGain, dGain});

        activeState.agc.automatic.exposure = shutterTime / configuration.sensor.lineDuration;
        activeState.agc.automatic.sensorGain = aGain;
        activeState.agc.automatic.ispGain = dGain;

        metadata.set(controls.ExposureTime, currentShutter);
        metadata.set(controls.AnalogueGain, frameContext.agc.sensorGain);
        metadata.set(controls.DigitalGain, frameContext.agc.ispGain);
        metadata.set(controls.ColourTemperature, context.activeState.agc.temperatureK);
    }
};

pub fn registerIPAAlgorithm() void {
    registerIPAAlgorithmImpl(Agc, "Agc");
}
