const std = @import("std");
const log = @import("log");
const controls = @import("controls");
const core_ipa_interface = @import("core_ipa_interface");
const colours = @import("colours");

const Awb = struct {
    rgbMode: bool = false,
    colourGainCurve: ?Interpolator = null,

    pub fn init(self: *Awb, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        var cmap = &context.ctrlMap;
        cmap.put(&controls.ColourTemperature, ControlInfo{ .min = 2500, .max = 10000, .def = 5000 });

        var gainCurve = Interpolator(Vector(f64, 2));
        var ret = gainCurve.readYaml(tuningData.get("colourGains"), "ct", "gains");
        if (ret < 0) {
            log.warning("RkISP1Awb", "Failed to parse 'colourGains' parameter from tuning file; manual colour temperature will not work properly");
        } else {
            self.colourGainCurve = gainCurve;
        }

        return 0;
    }

    pub fn configure(self: *Awb, context: *IPAContext, configInfo: *IPACameraSensorInfo) i32 {
        context.activeState.awb.gains.manual = RGB(f64){ 1.0, 1.0, 1.0 };
        context.activeState.awb.gains.automatic = RGB(f64){ 1.0, 1.0, 1.0 };
        context.activeState.awb.autoEnabled = true;
        context.activeState.awb.temperatureK = 5000;

        context.configuration.awb.measureWindow.h_offs = configInfo.outputSize.width / 8;
        context.configuration.awb.measureWindow.v_offs = configInfo.outputSize.height / 8;
        context.configuration.awb.measureWindow.h_size = 3 * configInfo.outputSize.width / 4;
        context.configuration.awb.measureWindow.v_size = 3 * configInfo.outputSize.height / 4;

        context.configuration.awb.enabled = true;

        return 0;
    }

    pub fn queueRequest(self: *Awb, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, controls: *ControlList) void {
        var awb = &context.activeState.awb;

        const awbEnable = controls.get(controls.AwbEnable);
        if (awbEnable != null and *awbEnable != awb.autoEnabled) {
            awb.autoEnabled = *awbEnable;
            log.debug("RkISP1Awb", "{s} AWB", .{ if (awb.autoEnabled) "Enabling" else "Disabling" });
        }

        frameContext.awb.autoEnabled = awb.autoEnabled;

        if (awb.autoEnabled) return;

        const colourGains = controls.get(controls.ColourGains);
        const colourTemperature = controls.get(controls.ColourTemperature);
        var update = false;
        if (colourGains != null) {
            awb.gains.manual.r = (*colourGains)[0];
            awb.gains.manual.b = (*colourGains)[1];
            update = true;
        } else if (colourTemperature != null and self.colourGainCurve != null) {
            const gains = self.colourGainCurve.getInterpolated(*colourTemperature);
            awb.gains.manual.r = gains[0];
            awb.gains.manual.b = gains[1];
            awb.temperatureK = *colourTemperature;
            update = true;
        }

        if (update) {
            log.debug("RkISP1Awb", "Set colour gains to {any}", .{ awb.gains.manual });
        }

        frameContext.awb.gains = awb.gains.manual;
        frameContext.awb.temperatureK = awb.temperatureK;
    }

    pub fn prepare(self: *Awb, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        if (frameContext.awb.autoEnabled) {
            frameContext.awb.gains = context.activeState.awb.gains.automatic;
            frameContext.awb.temperatureK = context.activeState.awb.temperatureK;
        }

        const gainConfig = params.block(BlockType.AwbGain);
        gainConfig.setEnabled(true);

        gainConfig.gain_green_b = std.math.clamp(@intCast(i32, 256 * frameContext.awb.gains.g), 0, 0x3ff);
        gainConfig.gain_blue = std.math.clamp(@intCast(i32, 256 * frameContext.awb.gains.b), 0, 0x3ff);
        gainConfig.gain_red = std.math.clamp(@intCast(i32, 256 * frameContext.awb.gains.r), 0, 0x3ff);
        gainConfig.gain_green_r = std.math.clamp(@intCast(i32, 256 * frameContext.awb.gains.g), 0, 0x3ff);

        if (frame > 0) return;

        const awbConfig = params.block(BlockType.Awb);
        awbConfig.setEnabled(true);

        awbConfig.awb_wnd = context.configuration.awb.measureWindow;
        awbConfig.frames = 0;

        if (self.rgbMode) {
            awbConfig.awb_mode = RKISP1_CIF_ISP_AWB_MODE_RGB;
            awbConfig.awb_ref_cr = 250;
            awbConfig.min_y = 250;
            awbConfig.awb_ref_cb = 250;
            awbConfig.max_y = 0;
            awbConfig.min_c = 0;
            awbConfig.max_csum = 0;
        } else {
            awbConfig.awb_mode = RKISP1_CIF_ISP_AWB_MODE_YCBCR;
            awbConfig.awb_ref_cb = 128;
            awbConfig.awb_ref_cr = 128;
            awbConfig.min_y = 16;
            awbConfig.max_y = 250;
            awbConfig.min_c = 16;
            awbConfig.max_csum = 250;
        }
    }

    pub fn process(self: *Awb, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *rkisp1_stat_buffer, metadata: *ControlList) void {
        const params = &stats.params;
        const awb = &params.awb;
        var activeState = &context.activeState;
        var rgbMeans = RGB(f64);

        metadata.set(controls.AwbEnable, frameContext.awb.autoEnabled);
        metadata.set(controls.ColourGains, [f32]{ @intCast(f32, frameContext.awb.gains.r), @intCast(f32, frameContext.awb.gains.b) });
        metadata.set(controls.ColourTemperature, frameContext.awb.temperatureK);

        if (stats == null or !(stats.meas_type & RKISP1_CIF_ISP_STAT_AWB)) {
            log.error("RkISP1Awb", "AWB data is missing in statistics");
            return;
        }

        if (self.rgbMode) {
            rgbMeans = RGB(f64){
                @intCast(f64, awb.awb_mean[0].mean_y_or_g),
                @intCast(f64, awb.awb_mean[0].mean_cr_or_r),
                @intCast(f64, awb.awb_mean[0].mean_cb_or_b)
            };
        } else {
            const yuvMeans = Vector(f64, 3){
                @intCast(f64, awb.awb_mean[0].mean_y_or_g),
                @intCast(f64, awb.awb_mean[0].mean_cb_or_b),
                @intCast(f64, awb.awb_mean[0].mean_cr_or_r)
            };

            const yuv2rgbMatrix = Matrix(f64, 3, 3){
                1.1636, -0.0623,  1.6008,
                1.1636, -0.4045, -0.7949,
                1.1636,  1.9912, -0.0250
            };
            const yuv2rgbOffset = Vector(f64, 3){ 16, 128, 128 };

            rgbMeans = yuv2rgbMatrix * (yuvMeans - yuv2rgbOffset);
            rgbMeans = rgbMeans.max(0.0);
        }

        rgbMeans /= frameContext.awb.gains;

        if (rgbMeans.r < 2.0 and rgbMeans.g < 2.0 and rgbMeans.b < 2.0) return;

        activeState.awb.temperatureK = self.estimateCCT(rgbMeans);

        var gains = RGB(f64){
            rgbMeans.g / std.math.max(rgbMeans.r, 1.0),
            1.0,
            rgbMeans.g / std.math.max(rgbMeans.b, 1.0)
        };

        gains = gains.max(1.0 / 256).min(1023.0 / 256);

        const speed = 0.2;
        gains = gains * speed + activeState.awb.gains.automatic * (1 - speed);

        activeState.awb.gains.automatic = gains;

        log.debug("RkISP1Awb", "Means {any}, gains {any}, temp {d}K", .{ rgbMeans, activeState.awb.gains.automatic, activeState.awb.temperatureK });
    }
};

pub fn main() void {
    const awb = Awb{};
    // Example usage of the Awb struct
}
