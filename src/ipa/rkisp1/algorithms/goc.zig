const std = @import("std");
const log = @import("log");
const controls = @import("controls");
const core_ipa_interface = @import("core_ipa_interface");
const yaml_parser = @import("yaml_parser");

const GammaOutCorrection = struct {
    defaultGamma: f32,

    pub fn init(self: *GammaOutCorrection, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        if (context.hw.numGammaOutSamples != RKISP1_CIF_ISP_GAMMA_OUT_MAX_SAMPLES_V10) {
            log.error("RkISP1Gamma", "Gamma is not implemented for RkISP1 V12");
            return -EINVAL;
        }

        self.defaultGamma = tuningData.get("gamma").getOptional(f32) orelse 2.2;
        context.ctrlMap.put(&controls.Gamma, ControlInfo{ .min = 0.1, .max = 10.0, .def = self.defaultGamma });

        return 0;
    }

    pub fn configure(self: *GammaOutCorrection, context: *IPAContext, configInfo: *IPACameraSensorInfo) i32 {
        context.activeState.goc.gamma = self.defaultGamma;
        return 0;
    }

    pub fn queueRequest(self: *GammaOutCorrection, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, controls: *ControlList) void {
        if (frame == 0) {
            frameContext.goc.update = true;
        }

        const gamma = controls.get(controls.Gamma);
        if (gamma != null) {
            context.activeState.goc.gamma = *gamma;
            frameContext.goc.update = true;
            log.debug("RkISP1Gamma", "Set gamma to {d}", .{ *gamma });
        }

        frameContext.goc.gamma = context.activeState.goc.gamma;
    }

    pub fn prepare(self: *GammaOutCorrection, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        assert(context.hw.numGammaOutSamples == RKISP1_CIF_ISP_GAMMA_OUT_MAX_SAMPLES_V10);

        if (!frameContext.goc.update) {
            return;
        }

        const segments = [_]u32{ 64, 64, 64, 64, 128, 128, 128, 128, 256, 256, 256, 512, 512, 512, 512, 512, 0 };

        const config = params.block(BlockType.Goc);
        config.setEnabled(true);

        var x: u32 = 0;
        for (segments) |size, i| {
            config.gamma_y[i] = @intCast(u16, std.math.pow(x / 4096.0, 1.0 / frameContext.goc.gamma) * 1023.0);
            x += size;
        }

        config.mode = RKISP1_CIF_ISP_GOC_MODE_LOGARITHMIC;
    }

    pub fn process(self: *GammaOutCorrection, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *rkisp1_stat_buffer, metadata: *ControlList) void {
        metadata.set(controls.Gamma, frameContext.goc.gamma);
    }
};

pub fn main() void {
    const gammaOutCorrection = GammaOutCorrection{};
    // Example usage of the GammaOutCorrection struct
}
