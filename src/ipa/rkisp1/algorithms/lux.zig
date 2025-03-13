const std = @import("std");
const log = @import("log");
const controls = @import("controls");
const core_ipa_interface = @import("core_ipa_interface");
const yaml_parser = @import("yaml_parser");
const histogram = @import("histogram");

const Lux = struct {
    lux: f64 = 65535.0,

    pub fn init(self: *Lux, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        return self.lux.parseTuningData(tuningData);
    }

    pub fn process(self: *Lux, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *rkisp1_stat_buffer, metadata: *ControlList) void {
        const exposureTime = context.configuration.sensor.lineDuration * frameContext.sensor.exposure;
        const gain = frameContext.sensor.gain;

        const params = &stats.params;
        const yHist = Histogram{ .data = params.hist.hist_bins[0..context.hw.numHistogramBins], .transform = |x| x >> 4 };

        const lux = self.lux.estimateLux(exposureTime, gain, 1.0, yHist);
        frameContext.lux.lux = lux;
        metadata.set(controls.Lux, lux);
    }
};

pub fn main() void {
    const lux = Lux{};
    // Example usage of the Lux struct
}
