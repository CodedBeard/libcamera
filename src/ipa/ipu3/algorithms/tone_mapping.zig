const std = @import("std");
const c = @cImport({
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/core_ipa_interface.h");
    @cInclude("libcamera/base/utils.h");
    @cInclude("libcamera/base/log.h");
    @cInclude("libcamera/geometry.h");
    @cInclude("libcamera/controls.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
    @cInclude("libcamera/ipa/ipu3_ipa_interface.h");
});

const ToneMapping = struct {
    gamma: f64,

    pub fn init() ToneMapping {
        return ToneMapping{
            .gamma = 1.0,
        };
    }

    pub fn configure(self: *ToneMapping, context: *c.IPAContext, configInfo: *c.IPAConfigInfo) c_int {
        context.activeState.toneMapping.gamma = 0.0;
        return 0;
    }

    pub fn prepare(self: *ToneMapping, context: *c.IPAContext, frame: u32, frameContext: *c.IPAFrameContext, params: *c.ipu3_uapi_params) void {
        std.mem.copy(u16, &params.acc_param.gamma.gc_lut.lut[0], &context.activeState.toneMapping.gammaCorrection.lut[0]);
        params.use.acc_gamma = 1;
        params.acc_param.gamma.gc_ctrl.enable = 1;
    }

    pub fn process(self: *ToneMapping, context: *c.IPAContext, frame: u32, frameContext: *c.IPAFrameContext, stats: *c.ipu3_uapi_stats_3a, metadata: *c.ControlList) void {
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

test "ToneMapping" {
    var toneMapping = ToneMapping.init();
    var context: c.IPAContext = undefined;
    var configInfo: c.IPAConfigInfo = undefined;
    var frameContext: c.IPAFrameContext = undefined;
    var params: c.ipu3_uapi_params = undefined;
    var stats: c.ipu3_uapi_stats_3a = undefined;
    var metadata: c.ControlList = undefined;

    try toneMapping.configure(&context, &configInfo);
    toneMapping.prepare(&context, 0, &frameContext, &params);
    toneMapping.process(&context, 0, &frameContext, &stats, &metadata);
}
