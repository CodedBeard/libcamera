const std = @import("std");
const log = @import("log");
const Algorithm = @import("algorithm.zig");

const kExposureBinsCount = 5;
const kExposureOptimal = kExposureBinsCount / 2.0;
const kExposureSatisfactory = 0.2;

pub const Awb = struct {
    pub fn new() Awb {
        return Awb{};
    }

    pub fn configure(self: *Awb, context: *IPAContext, configInfo: *const IPAConfigInfo) i32 {
        context.activeState.gains.red = 1.0;
        context.activeState.gains.green = 1.0;
        context.activeState.gains.blue = 1.0;
        return 0;
    }

    pub fn process(self: *Awb, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *const SwIspStats, metadata: *ControlList) void {
        const histogram = &stats.yHistogram;
        const blackLevel = context.activeState.blc.level;

        const nPixels = std.math.sum(histogram);
        const offset = blackLevel * nPixels;
        const sumR = stats.sumR - offset / 4;
        const sumG = stats.sumG - offset / 2;
        const sumB = stats.sumB - offset / 4;

        const gains = &context.activeState.gains;
        gains.red = if (sumR <= sumG / 4) 4.0 else @intToFloat(f64, sumG) / @intToFloat(f64, sumR);
        gains.blue = if (sumB <= sumG / 4) 4.0 else @intToFloat(f64, sumG) / @intToFloat(f64, sumB);

        log.debug("gain R/B {}/{}", .{gains.red, gains.blue});
    }
};

pub fn registerAlgorithm() void {
    Algorithm.register("Awb", Awb.new);
}
