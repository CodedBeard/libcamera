const Algorithm = @import("algorithm.zig").Algorithm;

pub const BlackLevelAlgorithm = struct {
    algorithm: Algorithm,

    pub fn init(controller: *Controller) BlackLevelAlgorithm {
        return BlackLevelAlgorithm{ .algorithm = Algorithm.init(controller) };
    }

    pub fn initialValues(self: *BlackLevelAlgorithm, blackLevelR: *u16, blackLevelG: *u16, blackLevelB: *u16) void {
        // Implementation needed
    }
};
