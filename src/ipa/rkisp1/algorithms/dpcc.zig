const std = @import("std");
const log = @import("log");
const yaml_parser = @import("yaml_parser");

const DefectPixelClusterCorrection = struct {
    config: rkisp1_cif_isp_dpcc_config = {},

    pub fn init(self: *DefectPixelClusterCorrection, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        self.config.mode = RKISP1_CIF_ISP_DPCC_MODE_STAGE1_ENABLE;
        self.config.output_mode = RKISP1_CIF_ISP_DPCC_OUTPUT_MODE_STAGE1_INCL_G_CENTER | RKISP1_CIF_ISP_DPCC_OUTPUT_MODE_STAGE1_INCL_RB_CENTER;

        self.config.set_use = if (tuningData.get("fixed-set").getOptional(bool)) |value| value else false ? RKISP1_CIF_ISP_DPCC_SET_USE_STAGE1_USE_FIX_SET else 0;

        const setsObject = tuningData.get("sets");
        if (!setsObject.isList()) {
            log.error("RkISP1Dpcc", "'sets' parameter not found in tuning file");
            return -EINVAL;
        }

        if (setsObject.size() > RKISP1_CIF_ISP_DPCC_METHODS_MAX) {
            log.error("RkISP1Dpcc", "'sets' size in tuning file ({}) exceeds the maximum hardware capacity (3)", .{ setsObject.size() });
            return -EINVAL;
        }

        for (setsObject.toList().iterator()) |set, i| {
            var method = &self.config.methods[i];
            var value: u16 = 0;

            self.config.set_use |= 1 << i;

            const pgObject = set.get("pg-factor");
            if (pgObject.has("green")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_PG_GREEN_ENABLE;
                value = pgObject.get("green").get(u16);
                method.pg_fac |= RKISP1_CIF_ISP_DPCC_PG_FAC_G(value);
            }

            if (pgObject.has("red-blue")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_PG_RED_BLUE_ENABLE;
                value = pgObject.get("red-blue").get(u16);
                method.pg_fac |= RKISP1_CIF_ISP_DPCC_PG_FAC_RB(value);
            }

            const roObject = set.get("ro-limits");
            if (roObject.has("green")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_RO_GREEN_ENABLE;
                value = roObject.get("green").get(u16);
                self.config.ro_limits |= RKISP1_CIF_ISP_DPCC_RO_LIMITS_n_G(i, value);
            }

            if (roObject.has("red-blue")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_RO_RED_BLUE_ENABLE;
                value = roObject.get("red-blue").get(u16);
                self.config.ro_limits |= RKISP1_CIF_ISP_DPCC_RO_LIMITS_n_RB(i, value);
            }

            const rgObject = set.get("rg-factor");
            method.rg_fac = 0;
            if (rgObject.has("green")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_RG_GREEN_ENABLE;
                value = rgObject.get("green").get(u16);
                method.rg_fac |= RKISP1_CIF_ISP_DPCC_RG_FAC_G(value);
            }

            if (rgObject.has("red-blue")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_RG_RED_BLUE_ENABLE;
                value = rgObject.get("red-blue").get(u16);
                method.rg_fac |= RKISP1_CIF_ISP_DPCC_RG_FAC_RB(value);
            }

            const rndOffsetsObject = set.get("rnd-offsets");
            if (rndOffsetsObject.has("green")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_RND_GREEN_ENABLE;
                value = rndOffsetsObject.get("green").get(u16);
                self.config.rnd_offs |= RKISP1_CIF_ISP_DPCC_RND_OFFS_n_G(i, value);
            }

            if (rndOffsetsObject.has("red-blue")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_RND_RED_BLUE_ENABLE;
                value = rndOffsetsObject.get("red-blue").get(u16);
                self.config.rnd_offs |= RKISP1_CIF_ISP_DPCC_RND_OFFS_n_RB(i, value);
            }

            const rndThresholdObject = set.get("rnd-threshold");
            method.rnd_thresh = 0;
            if (rndThresholdObject.has("green")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_RND_GREEN_ENABLE;
                value = rndThresholdObject.get("green").get(u16);
                method.rnd_thresh |= RKISP1_CIF_ISP_DPCC_RND_THRESH_G(value);
            }

            if (rndThresholdObject.has("red-blue")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_RND_RED_BLUE_ENABLE;
                value = rndThresholdObject.get("red-blue").get(u16);
                method.rnd_thresh |= RKISP1_CIF_ISP_DPCC_RND_THRESH_RB(value);
            }

            const lcThresholdObject = set.get("line-threshold");
            method.line_thresh = 0;
            if (lcThresholdObject.has("green")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_LC_GREEN_ENABLE;
                value = lcThresholdObject.get("green").get(u16);
                method.line_thresh |= RKISP1_CIF_ISP_DPCC_LINE_THRESH_G(value);
            }

            if (lcThresholdObject.has("red-blue")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_LC_RED_BLUE_ENABLE;
                value = lcThresholdObject.get("red-blue").get(u16);
                method.line_thresh |= RKISP1_CIF_ISP_DPCC_LINE_THRESH_RB(value);
            }

            const lcTMadFactorObject = set.get("line-mad-factor");
            method.line_mad_fac = 0;
            if (lcTMadFactorObject.has("green")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_LC_GREEN_ENABLE;
                value = lcTMadFactorObject.get("green").get(u16);
                method.line_mad_fac |= RKISP1_CIF_ISP_DPCC_LINE_MAD_FAC_G(value);
            }

            if (lcTMadFactorObject.has("red-blue")) {
                method.method |= RKISP1_CIF_ISP_DPCC_METHODS_SET_LC_RED_BLUE_ENABLE;
                value = lcTMadFactorObject.get("red-blue").get(u16);
                method.line_mad_fac |= RKISP1_CIF_ISP_DPCC_LINE_MAD_FAC_RB(value);
            }
        }

        return 0;
    }

    pub fn prepare(self: *DefectPixelClusterCorrection, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        if (frame > 0) return;

        const config = params.block(BlockType.Dpcc);
        config.setEnabled(true);
        config.* = self.config;
    }
};

pub fn main() void {
    const dpcc = DefectPixelClusterCorrection{};
    // Example usage of the DefectPixelClusterCorrection struct
}
