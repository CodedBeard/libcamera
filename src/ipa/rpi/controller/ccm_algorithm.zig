const Algorithm = @import("algorithm").Algorithm;

pub const CcmAlgorithm = struct {
    algorithm: Algorithm,

    pub fn init(controller: *Controller) CcmAlgorithm {
        return CcmAlgorithm{ .algorithm = Algorithm.init(controller) };
    }

    pub fn setSaturation(self: *CcmAlgorithm, saturation: f64) void {
        // Implement this function in derived structs
    }
};
