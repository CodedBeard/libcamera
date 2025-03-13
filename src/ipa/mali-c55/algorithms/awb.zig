const std = @import("std");
const log = @import("log");
const utils = @import("utils");
const controls = @import("libcamera.control_ids");
const fixedpoint = @import("libipa.fixedpoint");

const MaliC55Awb = log.Category("MaliC55Awb");

const kNumStartupFrames: u32 = 4;

pub const Awb = struct {
    rGain: f64,
    bGain: f64,

    pub fn init() Awb {
        return Awb{
            .rGain = 1.0,
            .bGain = 1.0,
        };
    }

    pub fn configure(self: *Awb, context: *IPAContext, configInfo: *IPACameraSensorInfo) !void {
        context.activeState.awb.rGain = 1.0;
        context.activeState.awb.bGain = 1.0;
    }

    fn fillGainsParamBlock(self: *Awb, block: *mali_c55_params_block, context: *IPAContext, frameContext: *IPAFrameContext) usize {
        block.header.type = MALI_C55_PARAM_BLOCK_AWB_GAINS;
        block.header.flags = MALI_C55_PARAM_BLOCK_FL_NONE;
        block.header.size = @sizeOf(mali_c55_params_awb_gains);

        const rGain = context.activeState.awb.rGain;
        const bGain = context.activeState.awb.bGain;

        block.awb_gains.gain00 = fixedpoint.floatingToFixedPoint(4, 8, rGain);
        block.awb_gains.gain01 = fixedpoint.floatingToFixedPoint(4, 8, 1.0);
        block.awb_gains.gain10 = fixedpoint.floatingToFixedPoint(4, 8, 1.0);
        block.awb_gains.gain11 = fixedpoint.floatingToFixedPoint(4, 8, bGain);

        frameContext.awb.rGain = rGain;
        frameContext.awb.bGain = bGain;

        return @sizeOf(mali_c55_params_awb_gains);
    }

    fn fillConfigParamBlock(self: *Awb, block: *mali_c55_params_block) usize {
        block.header.type = MALI_C55_PARAM_BLOCK_AWB_CONFIG;
        block.header.flags = MALI_C55_PARAM_BLOCK_FL_NONE;
        block.header.size = @sizeOf(mali_c55_params_awb_config);

        block.awb_config.tap_point = MALI_C55_AWB_STATS_TAP_PF;
        block.awb_config.stats_mode = MALI_C55_AWB_MODE_RGBG;
        block.awb_config.white_level = 1023;
        block.awb_config.black_level = 0;
        block.awb_config.cr_max = 511;
        block.awb_config.cr_min = 64;
        block.awb_config.cb_max = 511;
        block.awb_config.cb_min = 64;
        block.awb_config.nodes_used_horiz = 15;
        block.awb_config.nodes_used_vert = 15;
        block.awb_config.cr_high = 511;
        block.awb_config.cr_low = 64;
        block.awb_config.cb_high = 511;
        block.awb_config.cb_low = 64;

        return @sizeOf(mali_c55_params_awb_config);
    }

    pub fn prepare(self: *Awb, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *mali_c55_params_buffer) void {
        var block: mali_c55_params_block = undefined;
        block.data = &params.data[params.total_size];

        params.total_size += self.fillGainsParamBlock(&block, context, frameContext);

        if (frame > 0) return;

        block.data = &params.data[params.total_size];
        params.total_size += self.fillConfigParamBlock(&block);
    }

    pub fn process(self: *Awb, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *mali_c55_stats_buffer, metadata: *ControlList) void {
        const awb_ratios = &stats.awb_ratios;

        var counted_zones: u32 = 0;
        var rgSum: f64 = 0;
        var bgSum: f64 = 0;

        for (i: u32 = 0; i < 225; i += 1) {
            if (awb_ratios[i].num_pixels == 0) continue;

            rgSum += fixedpoint.fixedToFloatingPoint(4, 8, awb_ratios[i].avg_rg_gr);
            bgSum += fixedpoint.fixedToFloatingPoint(4, 8, awb_ratios[i].avg_bg_br);
            counted_zones += 1;
        }

        var rgAvg: f64 = if (counted_zones == 0) 1.0 else rgSum / counted_zones;
        var bgAvg: f64 = if (counted_zones == 0) 1.0 else bgSum / counted_zones;

        const rRatio = rgAvg / frameContext.awb.rGain;
        const bRatio = bgAvg / frameContext.awb.bGain;

        var rGain = 1 / rRatio;
        var bGain = 1 / bRatio;

        const speed = if (frame < kNumStartupFrames) 1.0 else 0.2;
        rGain = speed * rGain + context.activeState.awb.rGain * (1.0 - speed);
        bGain = speed * bGain + context.activeState.awb.bGain * (1.0 - speed);

        context.activeState.awb.rGain = rGain;
        context.activeState.awb.bGain = bGain;

        metadata.set(controls.ColourGains, [2]f32{ @floatCast(f32, frameContext.awb.rGain), @floatCast(f32, frameContext.awb.bGain) });

        log.debug(MaliC55Awb, "For frame number {d}: Average R/G Ratio: {f}, Average B/G Ratio: {f}\nrGain applied to this frame: {f}, bGain applied to this frame: {f}\nrGain to apply: {f}, bGain to apply: {f}", .{ frame, rgAvg, bgAvg, frameContext.awb.rGain, frameContext.awb.bGain, context.activeState.awb.rGain, context.activeState.awb.bGain });
    }
};

pub fn registerAlgorithm() void {
    const algo = Awb.init();
    registerIPAAlgorithm("Awb", &algo);
}
