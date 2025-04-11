const std = @import("std");
const libcamera = @import("libcamera");
const Algorithm = @import("algorithm").Algorithm;
const Metadata = @import("metadata").Metadata;
const CacStatus = @import("cac_status").CacStatus;

const NAME = "rpi.cac";

pub const Cac = struct {
    algorithm: Algorithm,
    config: CacConfig,
    cacStatus: CacStatus,

    pub fn init(controller: *Controller) Cac {
        return Cac{
            .algorithm = Algorithm.init(controller),
            .config = CacConfig.init(),
            .cacStatus = CacStatus.init(),
        };
    }

    pub fn name(self: *Cac) []const u8 {
        return NAME;
    }

    pub fn read(self: *Cac, params: YamlObject) i32 {
        self.config.enabled = params.contains("lut_rx") and params.contains("lut_ry") and
                              params.contains("lut_bx") and params.contains("lut_by");
        if (!self.config.enabled) {
            return 0;
        }

        const size = self.algorithm.getHardwareConfig().cacRegions;

        if (!arrayToSet(params.get("lut_rx"), &self.config.lutRx, size)) {
            std.log.err("Bad CAC lut_rx table", .{});
            return -EINVAL;
        }

        if (!arrayToSet(params.get("lut_ry"), &self.config.lutRy, size)) {
            std.log.err("Bad CAC lut_ry table", .{});
            return -EINVAL;
        }

        if (!arrayToSet(params.get("lut_bx"), &self.config.lutBx, size)) {
            std.log.err("Bad CAC lut_bx table", .{});
            return -EINVAL;
        }

        if (!arrayToSet(params.get("lut_by"), &self.config.lutBy, size)) {
            std.log.err("Bad CAC lut_by table", .{});
            return -EINVAL;
        }

        const strength = params.get("strength").getOptional(f64, 1);
        self.cacStatus.lutRx = self.config.lutRx;
        self.cacStatus.lutRy = self.config.lutRy;
        self.cacStatus.lutBx = self.config.lutBx;
        self.cacStatus.lutBy = self.config.lutBy;
        setStrength(&self.config.lutRx, &self.cacStatus.lutRx, strength);
        setStrength(&self.config.lutBx, &self.cacStatus.lutBx, strength);
        setStrength(&self.config.lutRy, &self.cacStatus.lutRy, strength);
        setStrength(&self.config.lutBy, &self.cacStatus.lutBy, strength);

        return 0;
    }

    pub fn prepare(self: *Cac, imageMetadata: *Metadata) void {
        if (self.config.enabled) {
            imageMetadata.set("cac.status", self.cacStatus);
        }
    }
};

fn arrayToSet(params: YamlObject, inputArray: *std.ArrayList(f64), size: Size) bool {
    var num = 0;
    const max_num = (size.width + 1) * (size.height + 1);
    inputArray.resize(max_num) catch {
        return false;
    };

    for (p in params.asList()) |value| {
        if (num == max_num) {
            return false;
        }
        inputArray.items[num] = value.get(f64, 0);
        num += 1;
    }

    return num == max_num;
}

fn setStrength(inputArray: *std.ArrayList(f64), outputArray: *std.ArrayList(f64), strengthFactor: f64) void {
    var num = 0;
    for (p in inputArray.items) |value| {
        outputArray.items[num] = value * strengthFactor;
        num += 1;
    }
}

pub const CacConfig = struct {
    enabled: bool,
    lutRx: std.ArrayList(f64),
    lutRy: std.ArrayList(f64),
    lutBx: std.ArrayList(f64),
    lutBy: std.ArrayList(f64),

    pub fn init() CacConfig {
        return CacConfig{
            .enabled = false,
            .lutRx = std.ArrayList(f64).init(std.heap.page_allocator),
            .lutRy = std.ArrayList(f64).init(std.heap.page_allocator),
            .lutBx = std.ArrayList(f64).init(std.heap.page_allocator),
            .lutBy = std.ArrayList(f64).init(std.heap.page_allocator),
        };
    }
};
