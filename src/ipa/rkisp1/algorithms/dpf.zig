const std = @import("std");
const log = @import("log");
const controls = @import("controls");
const yaml_parser = @import("yaml_parser");

const Dpf = struct {
    config: rkisp1_cif_isp_dpf_config = {},
    strengthConfig: rkisp1_cif_isp_dpf_strength_config = {},

    pub fn init(self: *Dpf, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        var values: []u8 = undefined;

        const dFObject = tuningData.get("DomainFilter");

        values = dFObject.get("g").getList(u8).? orelse std.ArrayList(u8).init();
        if (values.len != RKISP1_CIF_ISP_DPF_MAX_SPATIAL_COEFFS) {
            log.error("RkISP1Dpf", "Invalid 'DomainFilter:g': expected {d} elements, got {d}", .{ RKISP1_CIF_ISP_DPF_MAX_SPATIAL_COEFFS, values.len });
            return -EINVAL;
        }

        std.mem.copy(u8, self.config.g_flt.spatial_coeff[0..values.len], values);

        self.config.g_flt.gr_enable = true;
        self.config.g_flt.gb_enable = true;

        values = dFObject.get("rb").getList(u8).? orelse std.ArrayList(u8).init();
        if (values.len != RKISP1_CIF_ISP_DPF_MAX_SPATIAL_COEFFS and values.len != RKISP1_CIF_ISP_DPF_MAX_SPATIAL_COEFFS - 1) {
            log.error("RkISP1Dpf", "Invalid 'DomainFilter:rb': expected {d} or {d} elements, got {d}", .{ RKISP1_CIF_ISP_DPF_MAX_SPATIAL_COEFFS - 1, RKISP1_CIF_ISP_DPF_MAX_SPATIAL_COEFFS, values.len });
            return -EINVAL;
        }

        self.config.rb_flt.fltsize = if (values.len == RKISP1_CIF_ISP_DPF_MAX_SPATIAL_COEFFS) RKISP1_CIF_ISP_DPF_RB_FILTERSIZE_13x9 else RKISP1_CIF_ISP_DPF_RB_FILTERSIZE_9x9;

        std.mem.copy(u8, self.config.rb_flt.spatial_coeff[0..values.len], values);

        self.config.rb_flt.r_enable = true;
        self.config.rb_flt.b_enable = true;

        const rFObject = tuningData.get("NoiseLevelFunction");

        var nllValues: []u16 = undefined;
        nllValues = rFObject.get("coeff").getList(u16).? orelse std.ArrayList(u16).init();
        if (nllValues.len != RKISP1_CIF_ISP_DPF_MAX_NLF_COEFFS) {
            log.error("RkISP1Dpf", "Invalid 'RangeFilter:coeff': expected {d} elements, got {d}", .{ RKISP1_CIF_ISP_DPF_MAX_NLF_COEFFS, nllValues.len });
            return -EINVAL;
        }

        std.mem.copy(u16, self.config.nll.coeff[0..nllValues.len], nllValues);

        const scaleMode = rFObject.get("scale-mode").getString("");
        if (std.mem.eql(u8, scaleMode, "linear")) {
            self.config.nll.scale_mode = RKISP1_CIF_ISP_NLL_SCALE_LINEAR;
        } else if (std.mem.eql(u8, scaleMode, "logarithmic")) {
            self.config.nll.scale_mode = RKISP1_CIF_ISP_NLL_SCALE_LOGARITHMIC;
        } else {
            log.error("RkISP1Dpf", "Invalid 'RangeFilter:scale-mode': expected 'linear' or 'logarithmic' value, got {s}", .{ scaleMode });
            return -EINVAL;
        }

        const fSObject = tuningData.get("FilterStrength");

        self.strengthConfig.r = fSObject.get("r").get(u16) orelse 64;
        self.strengthConfig.g = fSObject.get("g").get(u16) orelse 64;
        self.strengthConfig.b = fSObject.get("b").get(u16) orelse 64;

        return 0;
    }

    pub fn queueRequest(self: *Dpf, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, controls: *ControlList) void {
        var dpf = &context.activeState.dpf;
        var update = false;

        const denoise = controls.get(controls.draft.NoiseReductionMode);
        if (denoise != null) {
            log.debug("RkISP1Dpf", "Set denoise to {d}", .{ *denoise });

            switch (denoise) {
                controls.draft.NoiseReductionModeOff => {
                    if (dpf.denoise) {
                        dpf.denoise = false;
                        update = true;
                    }
                },
                controls.draft.NoiseReductionModeMinimal,
                controls.draft.NoiseReductionModeHighQuality,
                controls.draft.NoiseReductionModeFast => {
                    if (!dpf.denoise) {
                        dpf.denoise = true;
                        update = true;
                    }
                },
                else => {
                    log.error("RkISP1Dpf", "Unsupported denoise value {d}", .{ *denoise });
                }
            }
        }

        frameContext.dpf.denoise = dpf.denoise;
        frameContext.dpf.update = update;
    }

    pub fn prepare(self: *Dpf, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        if (!frameContext.dpf.update and frame > 0) return;

        const config = params.block(BlockType.Dpf);
        config.setEnabled(frameContext.dpf.denoise);

        if (frameContext.dpf.denoise) {
            config.* = self.config;

            const awb = context.configuration.awb;
            const lsc = context.configuration.lsc;

            var mode = &config.gain.mode;

            if (awb.enabled and lsc.enabled) {
                mode = RKISP1_CIF_ISP_DPF_GAIN_USAGE_AWB_LSC_GAINS;
            } else if (awb.enabled) {
                mode = RKISP1_CIF_ISP_DPF_GAIN_USAGE_AWB_GAINS;
            } else if (lsc.enabled) {
                mode = RKISP1_CIF_ISP_DPF_GAIN_USAGE_LSC_GAINS;
            } else {
                mode = RKISP1_CIF_ISP_DPF_GAIN_USAGE_DISABLED;
            }
        }

        if (frame == 0) {
            const strengthConfig = params.block(BlockType.DpfStrength);
            strengthConfig.setEnabled(true);
            strengthConfig.* = self.strengthConfig;
        }
    }
};

pub fn main() void {
    const dpf = Dpf{};
    // Example usage of the Dpf struct
}
