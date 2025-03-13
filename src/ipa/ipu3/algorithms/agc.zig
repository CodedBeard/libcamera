const std = @import("std");
const log = @import("log");
const utils = @import("utils");
const colours = @import("colours");
const histogram = @import("histogram");

const kMinAnalogueGain = 1.0;
const kMaxExposureTime = std.time.millisecond * 60;
const knumHistogramBins = 256;

pub const Agc = struct {
    minExposureTime: std.time.Duration,
    maxExposureTime: std.time.Duration,
    minAnalogueGain: f64,
    maxAnalogueGain: f64,
    stride: u32,
    bdsGrid: ipu3_uapi_grid_config,
    rGain: f64,
    gGain: f64,
    bGain: f64,
    rgbTriples: std.ArrayList(std.tuple.Tuple(u8, u8, u8)),

    pub fn init(context: *IPAContext, tuningData: YamlObject) !void {
        try parseTuningData(tuningData);
        context.ctrlMap.merge(controls());
    }

    pub fn configure(context: *IPAContext, configInfo: IPAConfigInfo) !void {
        const configuration = context.configuration;
        const activeState = context.activeState;

        self.stride = configuration.grid.stride;
        self.bdsGrid = configuration.grid.bdsGrid;

        self.minExposureTime = configuration.agc.minExposureTime;
        self.maxExposureTime = std.math.min(configuration.agc.maxExposureTime, kMaxExposureTime);

        self.minAnalogueGain = std.math.max(configuration.agc.minAnalogueGain, kMinAnalogueGain);
        self.maxAnalogueGain = configuration.agc.maxAnalogueGain;

        activeState.agc.gain = self.minAnalogueGain;
        activeState.agc.exposure = 10 * std.time.millisecond / configuration.sensor.lineDuration;

        context.activeState.agc.constraintMode = constraintModes().begin().?.first;
        context.activeState.agc.exposureMode = exposureModeHelpers().begin().?.first;

        setLimits(self.minExposureTime, self.maxExposureTime, self.minAnalogueGain, self.maxAnalogueGain);
        resetFrameCount();
    }

    fn parseStatistics(stats: *const ipu3_uapi_stats_3a, grid: ipu3_uapi_grid_config) Histogram {
        var hist: [knumHistogramBins]u32 = undefined;

        self.rgbTriples.clear();

        for (cellY: u32 = 0; cellY < grid.height; cellY += 1) {
            for (cellX: u32 = 0; cellX < grid.width; cellX += 1) {
                const cellPosition = cellY * self.stride + cellX;
                const cell = @ptrCast(*const ipu3_uapi_awb_set_item, &stats.awb_raw_buffer.meta_data[cellPosition]);

                self.rgbTriples.append(std.tuple.Tuple(u8, u8, u8){cell.R_avg, (cell.Gr_avg + cell.Gb_avg) / 2, cell.B_avg});

                hist[(cell.Gr_avg + cell.Gb_avg) / 2] += 1;
            }
        }

        return Histogram{ .data = hist[0..] };
    }

    fn estimateLuminance(gain: f64) f64 {
        var sum: RGB(f64) = RGB(f64){ .r = 0.0, .g = 0.0, .b = 0.0 };

        for (i: usize = 0; i < self.rgbTriples.len; i += 1) {
            sum.r += std.math.min(@intToFloat(f64, self.rgbTriples[i].a) * gain, 255.0);
            sum.g += std.math.min(@intToFloat(f64, self.rgbTriples[i].b) * gain, 255.0);
            sum.b += std.math.min(@intToFloat(f64, self.rgbTriples[i].c) * gain, 255.0);
        }

        const gains = RGB(f64){ .r = self.rGain, .g = self.gGain, .b = self.bGain };
        const ySum = rec601LuminanceFromRGB(sum * gains);
        return ySum / (self.bdsGrid.height * self.bdsGrid.width) / 255.0;
    }

    pub fn process(context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *const ipu3_uapi_stats_3a, metadata: *ControlList) void {
        const hist = self.parseStatistics(stats, context.configuration.grid.bdsGrid);
        self.rGain = context.activeState.awb.gains.red;
        self.gGain = context.activeState.awb.gains.blue;
        self.bGain = context.activeState.awb.gains.green;

        const exposureTime = context.configuration.sensor.lineDuration * frameContext.sensor.exposure;
        const analogueGain = frameContext.sensor.gain;
        const effectiveExposureValue = exposureTime * analogueGain;

        const newExposureTime = undefined;
        const aGain = undefined;
        const dGain = undefined;
        std.math.tuple(newExposureTime, aGain, dGain) = self.calculateNewEv(context.activeState.agc.constraintMode, context.activeState.agc.exposureMode, hist, effectiveExposureValue);

        log.debug("Divided up exposure time, analogue gain and digital gain are {}, {}, and {}", .{ newExposureTime, aGain, dGain });

        const activeState = context.activeState;
        activeState.agc.exposure = newExposureTime / context.configuration.sensor.lineDuration;
        activeState.agc.gain = aGain;

        metadata.set(controls.AnalogueGain, frameContext.sensor.gain);
        metadata.set(controls.ExposureTime, exposureTime.getMicro());

        const vTotal = context.configuration.sensor.size.height + context.configuration.sensor.defVBlank;
        const frameDuration = context.configuration.sensor.lineDuration * vTotal;
        metadata.set(controls.FrameDuration, frameDuration.getMicro());
    }
};

pub fn REGISTER_IPA_ALGORITHM(Agc, "Agc");
