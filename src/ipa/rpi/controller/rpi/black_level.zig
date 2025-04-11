const libcamera = @import("libcamera");
const Metadata = @import("../metadata.zig").Metadata;
const BlackLevelStatus = @import("../black_level_status.zig").BlackLevelStatus;
const Algorithm = @import("../algorithm.zig").Algorithm;

const NAME = "rpi.black_level";

pub const BlackLevel = struct {
    algorithm: Algorithm,
    blackLevelR: f64,
    blackLevelG: f64,
    blackLevelB: f64,

    pub fn init(controller: *Controller) BlackLevel {
        return BlackLevel{
            .algorithm = Algorithm.init(controller),
            .blackLevelR = 0.0,
            .blackLevelG = 0.0,
            .blackLevelB = 0.0,
        };
    }

    pub fn name(self: *BlackLevel) []const u8 {
        return NAME;
    }

    pub fn read(self: *BlackLevel, params: YamlObject) i32 {
        const blackLevel = params.get("black_level").getOptional(u16, 4096);
        self.blackLevelR = params.get("black_level_r").getOptional(u16, blackLevel);
        self.blackLevelG = params.get("black_level_g").getOptional(u16, blackLevel);
        self.blackLevelB = params.get("black_level_b").getOptional(u16, blackLevel);
        log.debug("Read black levels red {f} green {f} blue {f}", .{ self.blackLevelR, self.blackLevelG, self.blackLevelB });
        return 0;
    }

    pub fn initialValues(self: *BlackLevel, blackLevelR: *u16, blackLevelG: *u16, blackLevelB: *u16) void {
        blackLevelR.* = @intCast(u16, self.blackLevelR);
        blackLevelG.* = @intCast(u16, self.blackLevelG);
        blackLevelB.* = @intCast(u16, self.blackLevelB);
    }

    pub fn prepare(self: *BlackLevel, imageMetadata: *Metadata) void {
        var status = BlackLevelStatus{
            .blackLevelR = @intCast(u16, self.blackLevelR),
            .blackLevelG = @intCast(u16, self.blackLevelG),
            .blackLevelB = @intCast(u16, self.blackLevelB),
        };
        imageMetadata.set("black_level.status", status);
    }
};

pub fn create(controller: *Controller) *BlackLevel {
    return BlackLevel.init(controller);
}

pub const RegisterAlgorithm = struct {
    name: []const u8,
    createFunc: fn(*Controller) *BlackLevel,

    pub fn init(name: []const u8, createFunc: fn(*Controller) *BlackLevel) RegisterAlgorithm {
        return RegisterAlgorithm{ .name = name, .createFunc = createFunc };
    }
};

pub const reg = RegisterAlgorithm.init(NAME, create);
