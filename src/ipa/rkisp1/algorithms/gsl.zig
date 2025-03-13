const std = @import("std");
const log = @import("log");
const yaml_parser = @import("yaml_parser");

const GammaSensorLinearization = struct {
    gammaDx: [2]u32,
    curveYr: []u16,
    curveYg: []u16,
    curveYb: []u16,

    pub fn init(self: *GammaSensorLinearization, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        const xIntervals = tuningData.get("x-intervals").getList(u16).? orelse std.ArrayList(u16).init();
        if (xIntervals.len != 16) {
            log.error("RkISP1Gsl", "Invalid 'x' coordinates: expected 16 elements, got {d}", .{ xIntervals.len });
            return -EINVAL;
        }

        self.gammaDx[0] = 0;
        self.gammaDx[1] = 0;
        for (var i: usize = 0; i < 16; i += 1) {
            self.gammaDx[i / 8] |= (xIntervals[i] & 0x07) << ((i % 8) * 4);
        }

        const yObject = tuningData.get("y");
        if (!yObject.isDictionary()) {
            log.error("RkISP1Gsl", "Issue while parsing 'y' in tuning file: entry must be a dictionary");
            return -EINVAL;
        }

        self.curveYr = yObject.get("red").getList(u16).? orelse std.ArrayList(u16).init();
        if (self.curveYr.len != 17) {
            log.error("RkISP1Gsl", "Invalid 'y:red' coordinates: expected 17 elements, got {d}", .{ self.curveYr.len });
            return -EINVAL;
        }

        self.curveYg = yObject.get("green").getList(u16).? orelse std.ArrayList(u16).init();
        if (self.curveYg.len != 17) {
            log.error("RkISP1Gsl", "Invalid 'y:green' coordinates: expected 17 elements, got {d}", .{ self.curveYg.len });
            return -EINVAL;
        }

        self.curveYb = yObject.get("blue").getList(u16).? orelse std.ArrayList(u16).init();
        if (self.curveYb.len != 17) {
            log.error("RkISP1Gsl", "Invalid 'y:blue' coordinates: expected 17 elements, got {d}", .{ self.curveYb.len });
            return -EINVAL;
        }

        return 0;
    }

    pub fn prepare(self: *GammaSensorLinearization, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        if (frame > 0) return;

        const config = params.block(BlockType.Sdg);
        config.setEnabled(true);

        config.xa_pnts.gamma_dx0 = self.gammaDx[0];
        config.xa_pnts.gamma_dx1 = self.gammaDx[1];

        std.mem.copy(u16, config.curve_r.gamma_y, self.curveYr);
        std.mem.copy(u16, config.curve_g.gamma_y, self.curveYg);
        std.mem.copy(u16, config.curve_b.gamma_y, self.curveYb);
    }
};

pub fn main() void {
    const gsl = GammaSensorLinearization{};
    // Example usage of the GammaSensorLinearization struct
}
