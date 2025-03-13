const std = @import("std");
const log = @import("log");
const controls = @import("controls");

const ColorProcessing = struct {
    pub fn init(self: *ColorProcessing, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        var cmap = &context.ctrlMap;

        cmap.put(&controls.Brightness, ControlInfo{ .min = -1.0, .max = 0.993, .def = 0.0 });
        cmap.put(&controls.Contrast, ControlInfo{ .min = 0.0, .max = 1.993, .def = 1.0 });
        cmap.put(&controls.Saturation, ControlInfo{ .min = 0.0, .max = 1.993, .def = 1.0 });

        return 0;
    }

    pub fn configure(self: *ColorProcessing, context: *IPAContext, configInfo: *IPACameraSensorInfo) i32 {
        var cproc = &context.activeState.cproc;

        cproc.brightness = self.convertBrightness(0.0);
        cproc.contrast = self.convertContrastOrSaturation(1.0);
        cproc.saturation = self.convertContrastOrSaturation(1.0);

        return 0;
    }

    pub fn queueRequest(self: *ColorProcessing, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, controls: *ControlList) void {
        var cproc = &context.activeState.cproc;
        var update = false;

        if (frame == 0) {
            update = true;
        }

        const brightness = controls.get(controls.Brightness);
        if (brightness != null) {
            const value = self.convertBrightness(*brightness);
            if (cproc.brightness != value) {
                cproc.brightness = value;
                update = true;
            }

            log.debug("RkISP1CProc", "Set brightness to {d}", .{ value });
        }

        const contrast = controls.get(controls.Contrast);
        if (contrast != null) {
            const value = self.convertContrastOrSaturation(*contrast);
            if (cproc.contrast != value) {
                cproc.contrast = value;
                update = true;
            }

            log.debug("RkISP1CProc", "Set contrast to {d}", .{ value });
        }

        const saturation = controls.get(controls.Saturation);
        if (saturation != null) {
            const value = self.convertContrastOrSaturation(*saturation);
            if (cproc.saturation != value) {
                cproc.saturation = value;
                update = true;
            }

            log.debug("RkISP1CProc", "Set saturation to {d}", .{ value });
        }

        frameContext.cproc.brightness = cproc.brightness;
        frameContext.cproc.contrast = cproc.contrast;
        frameContext.cproc.saturation = cproc.saturation;
        frameContext.cproc.update = update;
    }

    pub fn prepare(self: *ColorProcessing, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        if (!frameContext.cproc.update) {
            return;
        }

        const config = params.block(BlockType.Cproc);
        config.setEnabled(true);
        config.brightness = frameContext.cproc.brightness;
        config.contrast = frameContext.cproc.contrast;
        config.sat = frameContext.cproc.saturation;
    }

    fn convertBrightness(self: *ColorProcessing, v: f32) i32 {
        return std.math.clamp(@intCast(i32, std.math.round(v * 128.0)), -128, 127);
    }

    fn convertContrastOrSaturation(self: *ColorProcessing, v: f32) i32 {
        return std.math.clamp(@intCast(i32, std.math.round(v * 128.0)), 0, 255);
    }
};

pub fn main() void {
    const colorProcessing = ColorProcessing{};
    // Example usage of the ColorProcessing struct
}
