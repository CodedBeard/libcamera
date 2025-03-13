const std = @import("std");
const log = @import("log");
const yaml = @import("yaml");
const libcamera = @import("libcamera");
const Algorithm = @import("algorithm.zig");

const MaliC55Blc = log.Category("MaliC55Blc");

const kMaxOffset: u32 = 0xfffff;

pub const BlackLevelCorrection = struct {
    algorithm: Algorithm,
    tuningParameters: bool,
    offset00: u32,
    offset01: u32,
    offset10: u32,
    offset11: u32,

    pub fn init(self: *BlackLevelCorrection, context: *libcamera.IPAContext, tuningData: yaml.Object) !void {
        self.offset00 = tuningData.get("offset00", 0);
        self.offset01 = tuningData.get("offset01", 0);
        self.offset10 = tuningData.get("offset10", 0);
        self.offset11 = tuningData.get("offset11", 0);

        if (self.offset00 > kMaxOffset or self.offset01 > kMaxOffset or self.offset10 > kMaxOffset or self.offset11 > kMaxOffset) {
            return error.InvalidBlackLevelOffsets;
        }

        self.tuningParameters = true;

        log.debug(MaliC55Blc, "Black levels: 00 {}, 01 {}, 10 {}, 11 {}", .{ self.offset00, self.offset01, self.offset10, self.offset11 });
    }

    pub fn configure(self: *BlackLevelCorrection, context: *libcamera.IPAContext, configInfo: libcamera.IPACameraSensorInfo) !void {
        if (context.configuration.sensor.blackLevel != 0 and (self.offset00 + self.offset01 + self.offset10 + self.offset11) == 0) {
            self.offset00 = context.configuration.sensor.blackLevel;
            self.offset01 = context.configuration.sensor.blackLevel;
            self.offset10 = context.configuration.sensor.blackLevel;
            self.offset11 = context.configuration.sensor.blackLevel;
        }
    }

    pub fn prepare(self: *BlackLevelCorrection, context: *libcamera.IPAContext, frame: u32, frameContext: *libcamera.IPAFrameContext, params: *libcamera.mali_c55_params_buffer) void {
        var block: libcamera.mali_c55_params_block = undefined;
        block.data = &params.data[params.total_size];

        if (frame > 0) return;
        if (!self.tuningParameters) return;

        block.header.type = libcamera.MALI_C55_PARAM_BLOCK_SENSOR_OFFS;
        block.header.flags = libcamera.MALI_C55_PARAM_BLOCK_FL_NONE;
        block.header.size = @sizeOf(libcamera.mali_c55_params_sensor_off_preshading);

        block.sensor_offs.chan00 = self.offset00;
        block.sensor_offs.chan01 = self.offset01;
        block.sensor_offs.chan10 = self.offset10;
        block.sensor_offs.chan11 = self.offset11;

        params.total_size += block.header.size;
    }

    pub fn process(self: *BlackLevelCorrection, context: *libcamera.IPAContext, frame: u32, frameContext: *libcamera.IPAFrameContext, stats: *libcamera.mali_c55_stats_buffer, metadata: *libcamera.ControlList) void {
        metadata.set(libcamera.controls.SensorBlackLevels, .{
            @intCast(i32, self.offset00 >> 4),
            @intCast(i32, self.offset01 >> 4),
            @intCast(i32, self.offset10 >> 4),
            @intCast(i32, self.offset11 >> 4),
        });
    }
};

pub fn registerAlgorithm() void {
    libcamera.registerIPAAlgorithm("BlackLevelCorrection", BlackLevelCorrection);
}
