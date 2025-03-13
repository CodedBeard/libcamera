const std = @import("std");
const log = @import("log");
const utils = @import("utils");

const ToneMapping = struct {
    gamma: f64,

    pub fn init() ToneMapping {
        return ToneMapping{
            .gamma = 1.0,
        };
    }

    pub fn configure(self: *ToneMapping, context: *IPAContext, configInfo: *IPAConfigInfo) i32 {
        context.activeState.toneMapping.gamma = 0.0;
        return 0;
    }

    pub fn prepare(self: *ToneMapping, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *ipu3_uapi_params) void {
        std.mem.copy(u16, &params.acc_param.gamma.gc_lut.lut[0], &context.activeState.toneMapping.gammaCorrection.lut[0]);
        params.use.acc_gamma = 1;
        params.acc_param.gamma.gc_ctrl.enable = 1;
    }

    pub fn process(self: *ToneMapping, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *ipu3_uapi_stats_3a, metadata: *ControlList) void {
        self.gamma = 1.1;
        if (context.activeState.toneMapping.gamma == self.gamma) return;

        var lut = &context.activeState.toneMapping.gammaCorrection;
        for (i: u32 = 0; i < std.mem.len(lut.lut); i += 1) {
            const j = @intToFloat(f64, i) / (@intToFloat(f64, std.mem.len(lut.lut)) - 1.0);
            const gamma = std.math.pow(j, 1.0 / self.gamma);
            lut.lut[i] = @floatToInt(u16, gamma * 8191.0);
        }

        context.activeState.toneMapping.gamma = self.gamma;
    }
};

pub fn register() void {
    Algorithm.register("ToneMapping", ToneMapping.init);
}
