const std = @import("std");
const log = @import("log");
const utils = @import("utils");
const controls = @import("controls");
const core_ipa_interface = @import("core_ipa_interface");
const yaml_parser = @import("yaml_parser");
const fixedpoint = @import("fixedpoint");
const interpolator = @import("interpolator");

const Ccm = struct {
    ccm: interpolator.Interpolator(Matrix(f32, 3, 3)),
    offsets: interpolator.Interpolator(Matrix(i16, 3, 1)),
    ct: u32,

    pub fn init(self: *Ccm, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        var ret: i32 = self.ccm.readYaml(tuningData.get("ccms"), "ct", "ccm");
        if (ret != 0) {
            log.warning("RkISP1Ccm", "Failed to parse 'ccm' parameter from tuning file; falling back to unit matrix");
            self.ccm.setData([0]Matrix(f32, 3, 3).identity());
        }

        ret = self.offsets.readYaml(tuningData.get("ccms"), "ct", "offsets");
        if (ret != 0) {
            log.warning("RkISP1Ccm", "Failed to parse 'offsets' parameter from tuning file; falling back to zero offsets");
            self.offsets.setData([0]Matrix(i16, 3, 1){0, 0, 0});
        }

        return 0;
    }

    pub fn prepare(self: *Ccm, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        const ct = context.activeState.awb.temperatureK;

        if (frame > 0 and ct == self.ct) {
            frameContext.ccm.ccm = context.activeState.ccm.ccm;
            return;
        }

        self.ct = ct;
        const ccm = self.ccm.getInterpolated(ct);
        const offsets = self.offsets.getInterpolated(ct);

        context.activeState.ccm.ccm = ccm;
        frameContext.ccm.ccm = ccm;

        const config = params.block(BlockType.Ctk);
        config.setEnabled(true);
        self.setParameters(config, ccm, offsets);
    }

    pub fn process(self: *Ccm, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *rkisp1_stat_buffer, metadata: *ControlList) void {
        var m: [9]f32 = undefined;
        for (var i: usize = 0; i < 3; i += 1) {
            for (var j: usize = 0; j < 3; j += 1) {
                m[i * 3 + j] = frameContext.ccm.ccm[i][j];
            }
        }
        metadata.set(controls.ColourCorrectionMatrix, m);
    }

    fn setParameters(self: *Ccm, config: *rkisp1_cif_isp_ctk_config, matrix: Matrix(f32, 3, 3), offsets: Matrix(i16, 3, 1)) void {
        for (var i: usize = 0; i < 3; i += 1) {
            for (var j: usize = 0; j < 3; j += 1) {
                config.coeff[i][j] = fixedpoint.floatingToFixedPoint(4, 7, u16, f64, matrix[i][j]);
            }
        }

        for (var i: usize = 0; i < 3; i += 1) {
            config.ct_offset[i] = offsets[i][0] & 0xfff;
        }

        log.debug("RkISP1Ccm", "Setting matrix {any}", .{matrix});
        log.debug("RkISP1Ccm", "Setting offsets {any}", .{offsets});
    }
};

pub fn main() void {
    const ccm = Ccm{};
    // Example usage of the Ccm struct
}
