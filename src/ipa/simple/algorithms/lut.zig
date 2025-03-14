const std = @import("std");
const log = @import("log");

const IPAContext = @import("simple/ipa_context.zig").IPAContext;
const IPAConfigInfo = @import("simple/ipa_context.zig").IPAConfigInfo;
const IPAFrameContext = @import("simple/ipa_context.zig").IPAFrameContext;
const DebayerParams = @import("libcamera/internal/software_isp/debayer_params.zig").DebayerParams;
const ControlList = @import("libcamera/controls.zig").ControlList;
const ControlInfo = @import("libcamera/controls.zig").ControlInfo;
const controls = @import("libcamera/controls.zig").controls;

const Algorithm = @import("algorithm.zig").Algorithm;

const IPASoftLut = log.defineCategory("IPASoftLut");

const kGammaLookupSize = 1024;

pub const Lut = struct {
    pub fn init(context: *IPAContext, tuningData: ?*const anyopaque) i32 {
        context.ctrlMap[&controls.Contrast] = ControlInfo{ .min = 0.0, .max = 2.0, .def = 1.0 };
        return 0;
    }

    pub fn configure(context: *IPAContext, configInfo: ?*const IPAConfigInfo) i32 {
        context.configuration.gamma = 0.5;
        context.activeState.knobs.contrast = null;
        updateGammaTable(context);
        return 0;
    }

    pub fn queueRequest(context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, controls: ControlList) void {
        const contrast = controls.get(controls.Contrast);
        if (contrast) |c| {
            context.activeState.knobs.contrast = c;
            IPASoftLut.debug("Setting contrast to {}", .{c});
        }
    }

    fn updateGammaTable(context: *IPAContext) void {
        const gammaTable = &context.activeState.gamma.gammaTable;
        const blackLevel = context.activeState.blc.level;
        const blackIndex = blackLevel * gammaTable.len / 256;
        const contrast = context.activeState.knobs.contrast orelse 1.0;

        std.mem.set(gammaTable[0..blackIndex], 0);
        const divisor = gammaTable.len - blackIndex - 1.0;
        for (i, _) in gammaTable[blackIndex..] {
            var normalized = (i - blackIndex) / divisor;
            const contrastExp = std.math.tan(std.math.clamp(contrast * std.math.pi / 4, 0.0, std.math.pi / 2 - 0.00001));
            if (normalized < 0.5) {
                normalized = 0.5 * std.math.pow(normalized / 0.5, contrastExp);
            } else {
                normalized = 1.0 - 0.5 * std.math.pow((1.0 - normalized) / 0.5, contrastExp);
            }
            gammaTable[i] = @intCast(u8, std.math.pow(normalized, context.configuration.gamma) * 255);
        }

        context.activeState.gamma.blackLevel = blackLevel;
        context.activeState.gamma.contrast = contrast;
    }

    pub fn prepare(context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *DebayerParams) void {
        if (context.activeState.gamma.blackLevel != context.activeState.blc.level or context.activeState.gamma.contrast != context.activeState.knobs.contrast) {
            updateGammaTable(context);
        }

        const gains = &context.activeState.gains;
        const gammaTable = &context.activeState.gamma.gammaTable;
        const gammaTableSize = gammaTable.len;

        for (i, _) in params.red {
            const div = @intCast(f64, DebayerParams.kRGBLookupSize) / gammaTableSize;
            var idx: usize = @intCast(usize, std.math.min(i * gains.red / div, gammaTableSize - 1));
            params.red[i] = gammaTable[idx];
            idx = @intCast(usize, std.math.min(i * gains.green / div, gammaTableSize - 1));
            params.green[i] = gammaTable[idx];
            idx = @intCast(usize, std.math.min(i * gains.blue / div, gammaTableSize - 1));
            params.blue[i] = gammaTable[idx];
        }
    }
};

pub fn registerIPAAlgorithm() void {
    Algorithm.register("Lut", Lut);
}

registerIPAAlgorithm();
