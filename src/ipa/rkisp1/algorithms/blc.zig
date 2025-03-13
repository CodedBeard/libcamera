const std = @import("std");
const log = @import("log");
const controls = @import("controls");
const yaml_parser = @import("yaml_parser");

const BlackLevelCorrection = struct {
    supportsRaw: bool = true,
    supported: bool = false,
    blackLevelRed: i16,
    blackLevelGreenR: i16,
    blackLevelGreenB: i16,
    blackLevelBlue: i16,

    pub fn init(self: *BlackLevelCorrection, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        var levelRed = tuningData.get("R").getOptional(i16);
        var levelGreenR = tuningData.get("Gr").getOptional(i16);
        var levelGreenB = tuningData.get("Gb").getOptional(i16);
        var levelBlue = tuningData.get("B").getOptional(i16);
        var tuningHasLevels = levelRed != null and levelGreenR != null and levelGreenB != null and levelBlue != null;

        var blackLevel = context.camHelper.blackLevel();
        if (blackLevel == null) {
            log.warning("RkISP1Blc", "No black levels provided by camera sensor helper, please fix");
            self.blackLevelRed = levelRed orelse 4096;
            self.blackLevelGreenR = levelGreenR orelse 4096;
            self.blackLevelGreenB = levelGreenB orelse 4096;
            self.blackLevelBlue = levelBlue orelse 4096;
        } else if (tuningHasLevels) {
            log.warning("RkISP1Blc", "Deprecated: black levels overwritten by tuning file");
            self.blackLevelRed = levelRed.?;
            self.blackLevelGreenR = levelGreenR.?;
            self.blackLevelGreenB = levelGreenB.?;
            self.blackLevelBlue = levelBlue.?;
        } else {
            self.blackLevelRed = blackLevel.?;
            self.blackLevelGreenR = blackLevel.?;
            self.blackLevelGreenB = blackLevel.?;
            self.blackLevelBlue = blackLevel.?;
        }

        log.debug("RkISP1Blc", "Black levels: red {d}, green (red) {d}, green (blue) {d}, blue {d}", .{ self.blackLevelRed, self.blackLevelGreenR, self.blackLevelGreenB, self.blackLevelBlue });

        return 0;
    }

    pub fn configure(self: *BlackLevelCorrection, context: *IPAContext, configInfo: *IPACameraSensorInfo) i32 {
        self.supported = context.configuration.paramFormat == V4L2_META_FMT_RK_ISP1_EXT_PARAMS or !context.hw.compand;

        if (!self.supported) {
            log.warning("RkISP1Blc", "BLC in companding block requires extensible parameters");
        }

        return 0;
    }

    pub fn prepare(self: *BlackLevelCorrection, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        if (context.configuration.raw) return;
        if (frame > 0) return;
        if (!self.supported) return;

        if (context.hw.compand) {
            const config = params.block(BlockType.CompandBls);
            config.setEnabled(true);
            config.r = self.blackLevelRed << 4;
            config.gr = self.blackLevelGreenR << 4;
            config.gb = self.blackLevelGreenB << 4;
            config.b = self.blackLevelBlue << 4;
        } else {
            const config = params.block(BlockType.Bls);
            config.setEnabled(true);
            config.enable_auto = 0;
            config.fixed_val.r = self.blackLevelRed >> 4;
            config.fixed_val.gr = self.blackLevelGreenR >> 4;
            config.fixed_val.gb = self.blackLevelGreenB >> 4;
            config.fixed_val.b = self.blackLevelBlue >> 4;
        }
    }

    pub fn process(self: *BlackLevelCorrection, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *rkisp1_stat_buffer, metadata: *ControlList) void {
        metadata.set(controls.SensorBlackLevels, [i32]{ @intCast(i32, self.blackLevelRed), @intCast(i32, self.blackLevelGreenR), @intCast(i32, self.blackLevelGreenB), @intCast(i32, self.blackLevelBlue) });
    }
};

pub fn main() void {
    const blc = BlackLevelCorrection{};
    // Example usage of the BlackLevelCorrection struct
}
