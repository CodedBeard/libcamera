const std = @import("std");
const log = @import("log");
const yaml = @import("yaml");
const histogram = @import("histogram");

const Lux = struct {
    binSize: u32,
    referenceExposureTime: std.time.Duration,
    referenceAnalogueGain: f64,
    referenceDigitalGain: f64,
    referenceY: f64,
    referenceLux: f64,

    pub fn init(binSize: u32) Lux {
        return Lux{
            .binSize = binSize,
            .referenceExposureTime = std.time.Duration{},
            .referenceAnalogueGain = 0.0,
            .referenceDigitalGain = 0.0,
            .referenceY = 0.0,
            .referenceLux = 0.0,
        };
    }

    pub fn parseTuningData(self: *Lux, tuningData: yaml.YamlObject) !void {
        self.referenceExposureTime = std.time.Duration{ .seconds = tuningData.get("referenceExposureTime").get(f64) catch |err| return err };
        self.referenceAnalogueGain = tuningData.get("referenceAnalogueGain").get(f64) catch |err| return err;
        self.referenceDigitalGain = tuningData.get("referenceDigitalGain").get(f64) catch |err| return err;
        self.referenceY = tuningData.get("referenceY").get(f64) catch |err| return err;
        self.referenceLux = tuningData.get("referenceLux").get(f64) catch |err| return err;
    }

    pub fn estimateLux(self: *Lux, exposureTime: std.time.Duration, aGain: f64, dGain: f64, yHist: histogram.Histogram) f64 {
        const currentY = yHist.interQuantileMean(0, 1);
        const exposureTimeRatio = self.referenceExposureTime / exposureTime;
        const aGainRatio = self.referenceAnalogueGain / aGain;
        const dGainRatio = self.referenceDigitalGain / dGain;
        const yRatio = currentY * (self.binSize / yHist.bins()) / self.referenceY;

        const estimatedLux = exposureTimeRatio * aGainRatio * dGainRatio * yRatio * self.referenceLux;

        log.debug("Estimated lux {f}", .{estimatedLux});
        return estimatedLux;
    }
};
