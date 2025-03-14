const std = @import("std");
const log = @import("log");

const Algorithm = @import("algorithm.zig").Algorithm;
const IPAContext = @import("ipa_context.zig").IPAContext;
const IPAConfigInfo = @import("ipa_context.zig").IPAConfigInfo;
const IPAFrameContext = @import("ipa_context.zig").IPAFrameContext;
const SwIspStats = @import("swisp_stats.zig").SwIspStats;
const ControlList = @import("control_list.zig").ControlList;

const IPASoftBL = log.Category("IPASoftBL");

pub const BlackLevel = struct {
    algorithm: Algorithm,
    exposure: i32,
    gain: f64,
    definedLevel: ?u8,

    pub fn init(self: *BlackLevel, context: *IPAContext, tuningData: anytype) !void {
        const blackLevel = tuningData.getOptional(i16, "blackLevel");
        if (blackLevel) |level| {
            self.definedLevel = @intCast(u8, level) >> 8;
        }
    }

    pub fn configure(self: *BlackLevel, context: *IPAContext, configInfo: *IPAConfigInfo) !void {
        if (self.definedLevel) |level| {
            context.configuration.black.level = level;
        }
        context.activeState.blc.level = context.configuration.black.level orelse 255;
    }

    pub fn process(self: *BlackLevel, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *SwIspStats, metadata: *ControlList) !void {
        if (context.configuration.black.level) return;

        if (frameContext.sensor.exposure == self.exposure and frameContext.sensor.gain == self.gain) {
            return;
        }

        const histogram = stats.yHistogram;
        const ignoredPercentage = 0.02;
        const total = std.math.sum(histogram);
        const pixelThreshold = @intCast(u32, ignoredPercentage * total);
        const histogramRatio = 256 / SwIspStats.kYHistogramSize;
        const currentBlackIdx = context.activeState.blc.level / histogramRatio;

        for (var i: u32 = 0, seen: u32 = 0; i < currentBlackIdx and i < SwIspStats.kYHistogramSize; i += 1) {
            seen += histogram[i];
            if (seen >= pixelThreshold) {
                context.activeState.blc.level = i * histogramRatio;
                self.exposure = frameContext.sensor.exposure;
                self.gain = frameContext.sensor.gain;
                IPASoftBL.debug("Auto-set black level: {}/{} ({}% below, {}% at or below)", .{ i, SwIspStats.kYHistogramSize, 100 * (seen - histogram[i]) / total, 100 * seen / total });
                break;
            }
        }
    }
};

pub fn createAlgorithm() *Algorithm {
    return BlackLevel.init();
}
