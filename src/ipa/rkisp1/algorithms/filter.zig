const std = @import("std");
const log = @import("log");
const controls = @import("controls");

const Filter = struct {
    pub fn queueRequest(self: *Filter, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, controls: *ControlList) void {
        var filter = &context.activeState.filter;
        var update = false;

        const sharpness = controls.get(controls.Sharpness);
        if (sharpness != null) {
            const value = std.math.round(std.math.clamp(*sharpness, 0.0, 10.0));
            if (filter.sharpness != value) {
                filter.sharpness = value;
                update = true;
            }
            log.debug("RkISP1Filter", "Set sharpness to {d}", .{ *sharpness });
        }

        const denoise = controls.get(controls.draft.NoiseReductionMode);
        if (denoise != null) {
            log.debug("RkISP1Filter", "Set denoise to {d}", .{ *denoise });
            switch (*denoise) {
                controls.draft.NoiseReductionModeOff => {
                    if (filter.denoise != 0) {
                        filter.denoise = 0;
                        update = true;
                    }
                },
                controls.draft.NoiseReductionModeMinimal => {
                    if (filter.denoise != 1) {
                        filter.denoise = 1;
                        update = true;
                    }
                },
                controls.draft.NoiseReductionModeHighQuality,
                controls.draft.NoiseReductionModeFast => {
                    if (filter.denoise != 3) {
                        filter.denoise = 3;
                        update = true;
                    }
                },
                else => {
                    log.error("RkISP1Filter", "Unsupported denoise value {d}", .{ *denoise });
                }
            }
        }

        frameContext.filter.denoise = filter.denoise;
        frameContext.filter.sharpness = filter.sharpness;
        frameContext.filter.update = update;
    }

    pub fn prepare(self: *Filter, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        if (!frameContext.filter.update) return;

        const filt_fac_sh0 = [_]u16{ 0x04, 0x07, 0x0a, 0x0c, 0x10, 0x14, 0x1a, 0x1e, 0x24, 0x2a, 0x30 };
        const filt_fac_sh1 = [_]u16{ 0x04, 0x08, 0x0c, 0x10, 0x16, 0x1b, 0x20, 0x26, 0x2c, 0x30, 0x3f };
        const filt_fac_mid = [_]u16{ 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x10, 0x13, 0x17, 0x1d, 0x22, 0x28 };
        const filt_fac_bl0 = [_]u16{ 0x02, 0x02, 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x10, 0x15, 0x1a, 0x24 };
        const filt_fac_bl1 = [_]u16{ 0x00, 0x00, 0x00, 0x02, 0x04, 0x04, 0x06, 0x08, 0x0d, 0x14, 0x20 };
        const filt_thresh_sh0 = [_]u16{ 0, 18, 26, 36, 41, 75, 90, 120, 170, 250, 1023 };
        const filt_thresh_sh1 = [_]u16{ 0, 33, 44, 51, 67, 100, 120, 150, 200, 300, 1023 };
        const filt_thresh_bl0 = [_]u16{ 0, 8, 13, 23, 26, 50, 60, 80, 140, 180, 1023 };
        const filt_thresh_bl1 = [_]u16{ 0, 2, 5, 10, 15, 20, 26, 51, 100, 150, 1023 };
        const stage1_select = [_]u16{ 6, 6, 4, 4, 3, 3, 2, 2, 2, 1, 0 };
        const filt_chr_v_mode = [_]u16{ 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3 };
        const filt_chr_h_mode = [_]u16{ 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3 };

        const denoise = frameContext.filter.denoise;
        const sharpness = frameContext.filter.sharpness;

        const config = params.block(BlockType.Flt);
        config.setEnabled(true);

        config.fac_sh0 = filt_fac_sh0[sharpness];
        config.fac_sh1 = filt_fac_sh1[sharpness];
        config.fac_mid = filt_fac_mid[sharpness];
        config.fac_bl0 = filt_fac_bl0[sharpness];
        config.fac_bl1 = filt_fac_bl1[sharpness];

        config.lum_weight = 0x00022040;
        config.mode = 0x000004f2;
        config.thresh_sh0 = filt_thresh_sh0[denoise];
        config.thresh_sh1 = filt_thresh_sh1[denoise];
        config.thresh_bl0 = filt_thresh_bl0[denoise];
        config.thresh_bl1 = filt_thresh_bl1[denoise];
        config.grn_stage1 = stage1_select[denoise];
        config.chr_v_mode = filt_chr_v_mode[denoise];
        config.chr_h_mode = filt_chr_h_mode[denoise];

        if (denoise == 9) {
            if (sharpness > 3) config.grn_stage1 = 2;
        } else if (denoise == 10) {
            if (sharpness > 5) config.grn_stage1 = 2;
            else if (sharpness > 3) config.grn_stage1 = 1;
        }

        if (denoise > 7) {
            if (sharpness > 7) {
                config.fac_bl0 /= 2;
                config.fac_bl1 /= 4;
            } else if (sharpness > 4) {
                config.fac_bl0 = config.fac_bl0 * 3 / 4;
                config.fac_bl1 /= 2;
            }
        }
    }
};

pub fn main() void {
    const filter = Filter{};
    // Example usage of the Filter struct
}
