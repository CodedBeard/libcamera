const std = @import("std");
const log = @import("log");

const IPU3Awb = log.Category("IPU3Awb");

const kMinGreenLevelInZone: u32 = 16;
const kMaxCellSaturationRatio: f64 = 0.8;
const kMinCellsPerZoneRatio: u32 = 255 * 90 / 100;

const imguCssBnrDefaults = struct {
    wb_gains: [4]u16 = [4]u16{16, 16, 16, 16},
    wb_gains_thr: [4]u16 = [4]u16{255, 255, 255, 255},
    thr_coeffs: [6]u16 = [6]u16{1700, 0, 31, 31, 0, 16},
    thr_ctrl_shd: [4]u16 = [4]u16{26, 26, 26, 26},
    opt_center: [2]i32 = [2]i32{-648, 0, -366, 0},
    lut: [32]u16 = [32]u16{
        17, 23, 28, 32, 36, 39, 42, 45,
        48, 51, 53, 55, 58, 60, 62, 64,
        66, 68, 70, 72, 73, 75, 77, 78,
        80, 82, 83, 85, 86, 88, 89, 90
    },
    bp_ctrl: [9]u16 = [9]u16{20, 0, 1, 40, 0, 6, 0, 6, 0},
    dn_detect_ctrl: [11]u16 = [11]u16{9, 3, 4, 0, 8, 0, 1, 1, 1, 1, 0},
    column_size: u16 = 1296,
    opt_center_sqr: [2]i32 = [2]i32{419904, 133956},
};

const imguCssCcmDefault = struct {
    ccm: [12]u16 = [12]u16{8191, 0, 0, 0, 0, 8191, 0, 0, 0, 0, 8191, 0},
};

const Accumulator = struct {
    counted: u32,
    sum: struct {
        red: u64,
        green: u64,
        blue: u64,
    },
};

const AwbStatus = struct {
    temperatureK: f64,
    redGain: f64,
    greenGain: f64,
    blueGain: f64,
};

const Awb = struct {
    zones: std.ArrayList(RGB(f64)),
    awbStats: [kAwbStatsSizeX * kAwbStatsSizeY]Accumulator,
    asyncResults: AwbStatus,
    stride: u32,
    cellsPerZoneX: u32,
    cellsPerZoneY: u32,
    cellsPerZoneThreshold: u32,

    pub fn new() Awb {
        return Awb{
            .zones = std.ArrayList(RGB(f64)).init(std.heap.page_allocator),
            .asyncResults = AwbStatus{
                .blueGain = 1.0,
                .greenGain = 1.0,
                .redGain = 1.0,
                .temperatureK = 4500,
            },
        };
    }

    pub fn configure(self: *Awb, context: *IPAContext, configInfo: *const IPAConfigInfo) i32 {
        const grid = &context.configuration.grid.bdsGrid;
        self.stride = context.configuration.grid.stride;

        self.cellsPerZoneX = std.math.round(grid.width / @intToFloat(f64, kAwbStatsSizeX));
        self.cellsPerZoneY = std.math.round(grid.height / @intToFloat(f64, kAwbStatsSizeY));

        self.cellsPerZoneThreshold = self.cellsPerZoneX * self.cellsPerZoneY * kMaxCellSaturationRatio;
        IPU3Awb.debug("Threshold for AWB is set to {}", .{self.cellsPerZoneThreshold});

        return 0;
    }

    pub fn prepare(self: *Awb, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *ipu3_uapi_params) void {
        params.acc_param.awb.config.rgbs_thr_r = self.threshold(1.0);
        params.acc_param.awb.config.rgbs_thr_gr = self.threshold(0.9);
        params.acc_param.awb.config.rgbs_thr_gb = self.threshold(0.9);
        params.acc_param.awb.config.rgbs_thr_b = self.threshold(1.0);

        params.acc_param.awb.config.rgbs_thr_b |= IPU3_UAPI_AWB_RGBS_THR_B_INCL_SAT | IPU3_UAPI_AWB_RGBS_THR_B_EN;

        const grid = &context.configuration.grid.bdsGrid;

        params.acc_param.awb.config.grid = context.configuration.grid.bdsGrid;

        const bdsOutputSize = &context.configuration.grid.bdsOutputSize;
        params.acc_param.bnr = imguCssBnrDefaults;
        params.acc_param.bnr.column_size = bdsOutputSize.width;
        params.acc_param.bnr.opt_center.x_reset = grid.x_start - (bdsOutputSize.width / 2);
        params.acc_param.bnr.opt_center.y_reset = grid.y_start - (bdsOutputSize.height / 2);
        params.acc_param.bnr.opt_center_sqr.x_sqr_reset = params.acc_param.bnr.opt_center.x_reset * params.acc_param.bnr.opt_center.x_reset;
        params.acc_param.bnr.opt_center_sqr.y_sqr_reset = params.acc_param.bnr.opt_center.y_reset * params.acc_param.bnr.opt_center.y_reset;

        params.acc_param.bnr.wb_gains.gr = self.gainValue(context.activeState.awb.gains.green);
        params.acc_param.bnr.wb_gains.r = self.gainValue(context.activeState.awb.gains.red);
        params.acc_param.bnr.wb_gains.b = self.gainValue(context.activeState.awb.gains.blue);
        params.acc_param.bnr.wb_gains.gb = self.gainValue(context.activeState.awb.gains.green);

        IPU3Awb.debug("Color temperature estimated: {}", .{self.asyncResults.temperatureK});

        params.acc_param.ccm = imguCssCcmDefault;

        params.use.acc_awb = 1;
        params.use.acc_bnr = 1;
        params.use.acc_ccm = 1;
    }

    fn threshold(self: *Awb, value: f64) u16 {
        return @intCast(u16, value * 8191);
    }

    fn gainValue(self: *Awb, gain: f64) u16 {
        return @intCast(u16, std.math.clamp((gain - 1.0) * 8192, 0.0, 65535.0));
    }

    fn generateZones(self: *Awb) void {
        self.zones.clear();

        for (i: u32 = 0; i < kAwbStatsSizeX * kAwbStatsSizeY; i += 1) {
            const counted = self.awbStats[i].counted;
            if (counted >= self.cellsPerZoneThreshold) {
                var zone = RGB(f64){
                    .r = @intToFloat(f64, self.awbStats[i].sum.red),
                    .g = @intToFloat(f64, self.awbStats[i].sum.green),
                    .b = @intToFloat(f64, self.awbStats[i].sum.blue),
                };

                zone /= counted;

                if (zone.g >= kMinGreenLevelInZone) {
                    self.zones.append(zone) catch {};
                }
            }
        }
    }

    fn generateAwbStats(self: *Awb, stats: *const ipu3_uapi_stats_3a) void {
        for (cellY: u32 = 0; cellY < kAwbStatsSizeY * self.cellsPerZoneY; cellY += 1) {
            for (cellX: u32 = 0; cellX < kAwbStatsSizeX * self.cellsPerZoneX; cellX += 1) {
                const cellPosition = cellY * self.stride + cellX;
                const zoneX = cellX / self.cellsPerZoneX;
                const zoneY = cellY / self.cellsPerZoneY;

                const awbZonePosition = zoneY * kAwbStatsSizeX + zoneX;

                const currentCell = &stats.awb_raw_buffer.meta_data[cellPosition];

                if (currentCell.sat_ratio <= kMinCellsPerZoneRatio) {
                    self.awbStats[awbZonePosition].counted += 1;
                    const greenValue = currentCell.Gr_avg + currentCell.Gb_avg;
                    self.awbStats[awbZonePosition].sum.green += greenValue / 2;
                    self.awbStats[awbZonePosition].sum.red += currentCell.R_avg;
                    self.awbStats[awbZonePosition].sum.blue += currentCell.B_avg;
                }
            }
        }
    }

    fn clearAwbStats(self: *Awb) void {
        for (i: u32 = 0; i < kAwbStatsSizeX * kAwbStatsSizeY; i += 1) {
            self.awbStats[i].sum.blue = 0;
            self.awbStats[i].sum.red = 0;
            self.awbStats[i].sum.green = 0;
            self.awbStats[i].counted = 0;
        }
    }

    fn awbGreyWorld(self: *Awb) void {
        IPU3Awb.debug("Grey world AWB");

        var redDerivative = self.zones;
        var blueDerivative = self.zones;

        std.sort.sort(redDerivative.items, (a: *const RGB(f64), b: *const RGB(f64)) bool {
            return a.g * b.r < b.g * a.r;
        });

        std.sort.sort(blueDerivative.items, (a: *const RGB(f64), b: *const RGB(f64)) bool {
            return a.g * b.b < b.g * a.b;
        });

        const discard = redDerivative.items.len / 4;

        var sumRed = RGB(f64){};
        var sumBlue = RGB(f64){};

        for (ri: usize = discard, bi: usize = discard; ri < redDerivative.items.len - discard; ri += 1, bi += 1) {
            sumRed += redDerivative.items[ri];
            sumBlue += blueDerivative.items[bi];
        }

        var redGain = sumRed.g / (sumRed.r + 1);
        var blueGain = sumBlue.g / (sumBlue.b + 1);

        self.asyncResults.temperatureK = estimateCCT(RGB(f64){ .r = sumRed.r, .g = sumRed.g, .b = sumBlue.b });

        redGain = std.math.clamp(redGain, 0.0, 65535.0 / 8192);
        blueGain = std.math.clamp(blueGain, 0.0, 65535.0 / 8192);

        self.asyncResults.redGain = redGain;
        self.asyncResults.greenGain = 1.0;
        self.asyncResults.blueGain = blueGain;
    }

    fn calculateWBGains(self: *Awb, stats: *const ipu3_uapi_stats_3a) void {
        assert(stats.stats_3a_status.awb_en);

        self.clearAwbStats();
        self.generateAwbStats(stats);
        self.generateZones();

        IPU3Awb.debug("Valid zones: {}", .{self.zones.items.len});

        if (self.zones.items.len > 10) {
            self.awbGreyWorld();
            IPU3Awb.debug("Gain found for red: {} and for blue: {}", .{self.asyncResults.redGain, self.asyncResults.blueGain});
        }
    }

    pub fn process(self: *Awb, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *const ipu3_uapi_stats_3a, metadata: *ControlList) void {
        self.calculateWBGains(stats);

        context.activeState.awb.gains.blue = self.asyncResults.blueGain;
        context.activeState.awb.gains.green = self.asyncResults.greenGain;
        context.activeState.awb.gains.red = self.asyncResults.redGain;
        context.activeState.awb.temperatureK = self.asyncResults.temperatureK;

        metadata.set(controls.AwbEnable, true);
        metadata.set(controls.ColourGains, [2]f32{ @intToFloat(f32, context.activeState.awb.gains.red), @intToFloat(f32, context.activeState.awb.gains.blue) });
        metadata.set(controls.ColourTemperature, context.activeState.awb.temperatureK);
    }
};

pub fn main() void {
    const awb = Awb.new();
    // Add your test cases here
}
