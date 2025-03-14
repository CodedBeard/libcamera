const std = @import("std");
const log = @import("log");

const Algorithm = @import("algorithm.zig");
const IPAContext = @import("ipa_context.zig");
const IPAFrameContext = @import("ipa_context.zig").IPAFrameContext;
const SwIspStats = @import("swisp_stats.zig");
const ControlList = @import("control_list.zig");

const kExposureBinsCount = 5;
const kExposureOptimal = kExposureBinsCount / 2.0;
const kExposureSatisfactory = 0.2;

pub const Agc = struct {
    pub fn init() Agc {
        return Agc{};
    }

    pub fn process(self: *Agc, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *const SwIspStats, metadata: *ControlList) void {
        const histogram = &stats.yHistogram;
        const blackLevelHistIdx = context.activeState.blc.level / (256 / SwIspStats.kYHistogramSize);
        const histogramSize = SwIspStats.kYHistogramSize - blackLevelHistIdx;
        const yHistValsPerBin = histogramSize / kExposureBinsCount;
        const yHistValsPerBinMod = histogramSize / (histogramSize % kExposureBinsCount + 1);
        var exposureBins: [kExposureBinsCount]u32 = undefined;
        var denom: u32 = 0;
        var num: u32 = 0;

        for (var i: u32 = 0; i < histogramSize; i += 1) {
            const idx = (i - (i / yHistValsPerBinMod)) / yHistValsPerBin;
            exposureBins[idx] += histogram[blackLevelHistIdx + i];
        }

        for (var i: u32 = 0; i < kExposureBinsCount; i += 1) {
            log.debug("{}: {}", .{i, exposureBins[i]});
            denom += exposureBins[i];
            num += exposureBins[i] * (i + 1);
        }

        const exposureMSV = if (denom == 0) 0 else @intToFloat(f32, num) / @intToFloat(f32, denom);
        self.updateExposure(context, frameContext, exposureMSV);
    }

    fn updateExposure(self: *Agc, context: *IPAContext, frameContext: *IPAFrameContext, exposureMSV: f32) void {
        const kExpDenominator = 10;
        const kExpNumeratorUp = kExpDenominator + 1;
        const kExpNumeratorDown = kExpDenominator - 1;

        var next: f32 = 0;
        var exposure = &frameContext.sensor.exposure;
        var again = &frameContext.sensor.gain;

        if (exposureMSV < kExposureOptimal - kExposureSatisfactory) {
            next = @intToFloat(f32, exposure.*) * kExpNumeratorUp / kExpDenominator;
            if (next - @intToFloat(f32, exposure.*) < 1) {
                exposure.* += 1;
            } else {
                exposure.* = @floatToInt(i32, next);
            }
            if (exposure.* >= context.configuration.agc.exposureMax) {
                next = again.* * kExpNumeratorUp / kExpDenominator;
                if (next - again.* < context.configuration.agc.againMinStep) {
                    again.* += context.configuration.agc.againMinStep;
                } else {
                    again.* = next;
                }
            }
        }

        if (exposureMSV > kExposureOptimal + kExposureSatisfactory) {
            if (exposure.* == context.configuration.agc.exposureMax && again.* > context.configuration.agc.againMin) {
                next = again.* * kExpNumeratorDown / kExpDenominator;
                if (again.* - next < context.configuration.agc.againMinStep) {
                    again.* -= context.configuration.agc.againMinStep;
                } else {
                    again.* = next;
                }
            } else {
                next = @intToFloat(f32, exposure.*) * kExpNumeratorDown / kExpDenominator;
                if (@intToFloat(f32, exposure.*) - next < 1) {
                    exposure.* -= 1;
                } else {
                    exposure.* = @floatToInt(i32, next);
                }
            }
        }

        exposure.* = std.math.clamp(exposure.*, context.configuration.agc.exposureMin, context.configuration.agc.exposureMax);
        again.* = std.math.clamp(again.*, context.configuration.agc.againMin, context.configuration.agc.againMax);

        log.debug("exposureMSV {} exp {} again {}", .{exposureMSV, exposure.*, again.*});
    }
};

pub fn registerAlgorithm() void {
    Algorithm.register("Agc", Agc.init);
}
