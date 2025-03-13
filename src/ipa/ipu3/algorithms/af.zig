const std = @import("std");

const Af = struct {
    focus: u32,
    bestFocus: u32,
    currentVariance: f64,
    previousVariance: f64,
    coarseCompleted: bool,
    fineCompleted: bool,
    ignoreCounter: u32,
    maxStep: u32,

    pub fn init() Af {
        return Af{
            .focus = 0,
            .bestFocus = 0,
            .currentVariance = 0.0,
            .previousVariance = 0.0,
            .coarseCompleted = false,
            .fineCompleted = false,
            .ignoreCounter = 10,
            .maxStep = 1023,
        };
    }

    pub fn configure(self: *Af, context: *IPAContext, configInfo: *IPAConfigInfo) !void {
        var grid = &context.configuration.af.afGrid;
        grid.width = 16;
        grid.height = 16;
        grid.block_width_log2 = 4;
        grid.block_height_log2 = 3;

        grid.width = std.math.clamp(grid.width, 16, 32);
        grid.height = std.math.clamp(grid.height, 16, 24);
        grid.block_width_log2 = std.math.clamp(grid.block_width_log2, 4, 6);
        grid.block_height_log2 = std.math.clamp(grid.block_height_log2, 3, 6);
        grid.height_per_slice = 2;

        const bds = Rectangle{ .size = configInfo.bdsOutputSize };
        const gridSize = Size{ .width = grid.width << grid.block_width_log2, .height = grid.height << grid.block_height_log2 };
        const roi = gridSize.centeredTo(bds.center());
        const start = roi.topLeft();

        grid.x_start = utils.alignDown(start.x, 2);
        grid.y_start = utils.alignDown(start.y, 2);
        grid.y_start |= IPU3_UAPI_GRID_Y_START_EN;

        self.maxStep = 1023;
        self.afIgnoreFrameReset();
        context.activeState.af.focus = 0;
        context.activeState.af.maxVariance = 0;
        context.activeState.af.stable = false;
    }

    pub fn prepare(self: *Af, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *ipu3_uapi_params) void {
        const grid = &context.configuration.af.afGrid;
        params.acc_param.af.grid_cfg = grid;
        params.acc_param.af.filter_config = ipu3_uapi_af_filter_config{
            .y1_coeff_0 = [4]u8{ 0, 1, 3, 7 },
            .y1_coeff_1 = [4]u8{ 11, 13, 1, 2 },
            .y1_coeff_2 = [4]u8{ 8, 19, 34, 242 },
            .y1_sign_vec = 0x7fdffbfe,
            .y2_coeff_0 = [4]u8{ 0, 1, 6, 6 },
            .y2_coeff_1 = [4]u8{ 13, 25, 3, 0 },
            .y2_coeff_2 = [4]u8{ 25, 3, 177, 254 },
            .y2_sign_vec = 0x4e53ca72,
            .y_calc = [4]u8{ 8, 8, 8, 8 },
            .nf = [5]u8{ 0, 9, 0, 9, 0 },
        };
        params.use.acc_af = 1;
    }

    fn afCoarseScan(self: *Af, context: *IPAContext) void {
        if (self.coarseCompleted) return;
        if (self.afNeedIgnoreFrame()) return;
        if (self.afScan(context, 30)) {
            self.coarseCompleted = true;
            context.activeState.af.maxVariance = 0;
            self.focus = context.activeState.af.focus - (context.activeState.af.focus * 0.05);
            context.activeState.af.focus = self.focus;
            self.previousVariance = 0;
            self.maxStep = std.math.clamp(self.focus + (self.focus * 0.05), 0, 1023);
        }
    }

    fn afFineScan(self: *Af, context: *IPAContext) void {
        if (!self.coarseCompleted) return;
        if (self.afNeedIgnoreFrame()) return;
        if (self.afScan(context, 1)) {
            context.activeState.af.stable = true;
            self.fineCompleted = true;
        }
    }

    fn afReset(self: *Af, context: *IPAContext) void {
        if (self.afNeedIgnoreFrame()) return;
        context.activeState.af.maxVariance = 0;
        context.activeState.af.focus = 0;
        self.focus = 0;
        context.activeState.af.stable = false;
        self.ignoreCounter = 10;
        self.previousVariance = 0.0;
        self.coarseCompleted = false;
        self.fineCompleted = false;
        self.maxStep = 1023;
    }

    fn afScan(self: *Af, context: *IPAContext, min_step: i32) bool {
        if (self.focus > self.maxStep) {
            context.activeState.af.focus = self.bestFocus;
            return true;
        } else {
            if ((self.currentVariance - context.activeState.af.maxVariance) >= -(context.activeState.af.maxVariance * 0.1)) {
                self.bestFocus = self.focus;
                self.focus += min_step;
                context.activeState.af.focus = self.focus;
                context.activeState.af.maxVariance = self.currentVariance;
            } else {
                context.activeState.af.focus = self.bestFocus;
                return true;
            }
        }
        self.previousVariance = self.currentVariance;
        std.debug.print("Previous step is {}, Current step is {}", .{ self.bestFocus, self.focus });
        return false;
    }

    fn afNeedIgnoreFrame(self: *Af) bool {
        if (self.ignoreCounter == 0) return false;
        self.ignoreCounter -= 1;
        return true;
    }

    fn afIgnoreFrameReset(self: *Af) void {
        self.ignoreCounter = 10;
    }

    fn afEstimateVariance(self: *Af, y_items: []const y_table_item_t, isY1: bool) f64 {
        var total: u32 = 0;
        var mean: f64 = 0;
        var var_sum: f64 = 0;

        for (y in y_items) {
            total += if (isY1) y.y1_avg else y.y2_avg;
        }

        mean = total / y_items.len;

        for (y in y_items) {
            const avg = if (isY1) y.y1_avg else y.y2_avg;
            var_sum += std.math.pow(avg - mean, 2);
        }

        return var_sum / y_items.len;
    }

    fn afIsOutOfFocus(self: *Af, context: *IPAContext) bool {
        const diff_var = std.math.abs(self.currentVariance - context.activeState.af.maxVariance);
        const var_ratio = diff_var / context.activeState.af.maxVariance;

        std.debug.print("Variance change rate: {}, Current VCM step: {}", .{ var_ratio, context.activeState.af.focus });

        return var_ratio > 0.5;
    }

    pub fn process(self: *Af, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, stats: *const ipu3_uapi_stats_3a, metadata: *ControlList) void {
        const afRawBufferLen = context.configuration.af.afGrid.width * context.configuration.af.afGrid.height;
        assert(afRawBufferLen < IPU3_UAPI_AF_Y_TABLE_MAX_SIZE);

        const y_items = stats.af_raw_buffer.y_table[0..afRawBufferLen];
        self.currentVariance = self.afEstimateVariance(y_items, !self.coarseCompleted);

        if (!context.activeState.af.stable) {
            self.afCoarseScan(context);
            self.afFineScan(context);
        } else {
            if (self.afIsOutOfFocus(context)) {
                self.afReset(context);
            } else {
                self.afIgnoreFrameReset();
            }
        }
    }
};

pub fn register() void {
    Algorithm.register("Af", Af.init);
}
