const Algorithm = @import("algorithm.zig").Algorithm;

pub const AwbAlgorithm = struct {
    algorithm: Algorithm,

    pub fn init(controller: *Controller) AwbAlgorithm {
        return AwbAlgorithm{ .algorithm = Algorithm.init(controller) };
    }

    pub fn getConvergenceFrames(self: *AwbAlgorithm) u32 {
        return 0;
    }

    pub fn initialValues(self: *AwbAlgorithm, gainR: *f64, gainB: *f64) void {
    }

    pub fn setMode(self: *AwbAlgorithm, modeName: []const u8) void {
    }

    pub fn setManualGains(self: *AwbAlgorithm, manualR: f64, manualB: f64) void {
    }

    pub fn setColourTemperature(self: *AwbAlgorithm, temperatureK: f64) void {
    }

    pub fn enableAuto(self: *AwbAlgorithm) void {
    }

    pub fn disableAuto(self: *AwbAlgorithm) void {
    }
};
