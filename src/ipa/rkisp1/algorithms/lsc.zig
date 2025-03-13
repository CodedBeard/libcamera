const std = @import("std");
const log = @import("log");
const utils = @import("utils");
const controls = @import("controls");
const core_ipa_interface = @import("core_ipa_interface");
const yaml_parser = @import("yaml_parser");
const interpolator = @import("interpolator");
const lsc_polynomial = @import("lsc_polynomial");

const LensShadingCorrection = struct {
    lastAppliedCt: u32 = 0,
    lastAppliedQuantizedCt: u32 = 0,
    sets: interpolator.Interpolator(Components),
    xSize: []f64,
    ySize: []f64,
    xGrad: [RKISP1_CIF_ISP_LSC_SECTORS_TBL_SIZE]u16,
    yGrad: [RKISP1_CIF_ISP_LSC_SECTORS_TBL_SIZE]u16,
    xSizes: [RKISP1_CIF_ISP_LSC_SECTORS_TBL_SIZE]u16,
    ySizes: [RKISP1_CIF_ISP_LSC_SECTORS_TBL_SIZE]u16,

    pub fn init(self: *LensShadingCorrection, context: *IPAContext, tuningData: *yaml_parser.YamlObject) i32 {
        self.xSize = parseSizes(tuningData, "x-size");
        self.ySize = parseSizes(tuningData, "y-size");

        if (self.xSize.len == 0 or self.ySize.len == 0) {
            return -EINVAL;
        }

        const yamlSets = tuningData.get("sets");
        if (!yamlSets.isList()) {
            log.error("RkISP1Lsc", "'sets' parameter not found in tuning file");
            return -EINVAL;
        }

        var lscData = std.AutoHashMap(u32, Components).init(std.heap.page_allocator);
        var res: i32 = 0;
        const type = tuningData.get("type").getOptional([]const u8) orelse "table";
        if (std.mem.eql(u8, type, "table")) {
            log.debug("RkISP1Lsc", "Loading tabular LSC data.");
            var loader = LscTableLoader{};
            res = loader.parseLscData(yamlSets, &lscData);
        } else if (std.mem.eql(u8, type, "polynomial")) {
            log.debug("RkISP1Lsc", "Loading polynomial LSC data.");
            var loader = LscPolynomialLoader{
                .sensorSize = context.sensorInfo.activeAreaSize,
                .cropRectangle = context.sensorInfo.analogCrop,
                .xSizes = self.xSize,
                .ySizes = self.ySize,
            };
            res = loader.parseLscData(yamlSets, &lscData);
        } else {
            log.error("RkISP1Lsc", "Unsupported LSC data type '{s}'", .{ type });
            res = -EINVAL;
        }

        if (res != 0) {
            return res;
        }

        self.sets.setData(lscData);

        return 0;
    }

    pub fn configure(self: *LensShadingCorrection, context: *IPAContext, configInfo: *IPACameraSensorInfo) i32 {
        const size = context.configuration.sensor.size;
        var totalSize = Size{};

        for (var i: usize = 0; i < RKISP1_CIF_ISP_LSC_SECTORS_TBL_SIZE; i += 1) {
            self.xSizes[i] = @intCast(u16, self.xSize[i] * size.width);
            self.ySizes[i] = @intCast(u16, self.ySize[i] * size.height);

            if (i == RKISP1_CIF_ISP_LSC_SECTORS_TBL_SIZE - 1) {
                self.xSizes[i] = @intCast(u16, size.width / 2 - totalSize.width);
                self.ySizes[i] = @intCast(u16, size.height / 2 - totalSize.height);
            }

            totalSize.width += self.xSizes[i];
            totalSize.height += self.ySizes[i];

            self.xGrad[i] = @intCast(u16, std.math.round(32768.0 / self.xSizes[i]));
            self.yGrad[i] = @intCast(u16, std.math.round(32768.0 / self.ySizes[i]));
        }

        context.configuration.lsc.enabled = true;
        return 0;
    }

    pub fn prepare(self: *LensShadingCorrection, context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *RkISP1Params) void {
        const ct = context.activeState.awb.temperatureK;
        if (std.math.abs(@intCast(i32, ct) - @intCast(i32, self.lastAppliedCt)) < kColourTemperatureChangeThreshhold) {
            return;
        }
        var quantizedCt: u32 = 0;
        const set = self.sets.getInterpolated(ct, &quantizedCt);
        if (self.lastAppliedQuantizedCt == quantizedCt) {
            return;
        }

        const config = params.block(BlockType.Lsc);
        config.setEnabled(true);
        self.setParameters(config);
        self.copyTable(config, set);

        self.lastAppliedCt = ct;
        self.lastAppliedQuantizedCt = quantizedCt;

        log.debug("RkISP1Lsc", "ct is {d}, quantized to {d}", .{ ct, quantizedCt });
    }

    fn setParameters(self: *LensShadingCorrection, config: *rkisp1_cif_isp_lsc_config) void {
        std.mem.copy(u16, config.x_grad_tbl[0..], self.xGrad[0..]);
        std.mem.copy(u16, config.y_grad_tbl[0..], self.yGrad[0..]);
        std.mem.copy(u16, config.x_size_tbl[0..], self.xSizes[0..]);
        std.mem.copy(u16, config.y_size_tbl[0..], self.ySizes[0..]);
    }

    fn copyTable(self: *LensShadingCorrection, config: *rkisp1_cif_isp_lsc_config, set: *Components) void {
        std.mem.copy(u16, config.r_data_tbl[0..], set.r[0..]);
        std.mem.copy(u16, config.gr_data_tbl[0..], set.gr[0..]);
        std.mem.copy(u16, config.gb_data_tbl[0..], set.gb[0..]);
        std.mem.copy(u16, config.b_data_tbl[0..], set.b[0..]);
    }

    fn parseSizes(tuningData: *yaml_parser.YamlObject, prop: []const u8) []f64 {
        const sizes = tuningData.get(prop).getList(f64) orelse []f64{};
        if (sizes.len != RKISP1_CIF_ISP_LSC_SECTORS_TBL_SIZE) {
            log.error("RkISP1Lsc", "Invalid '{s}' values: expected {d} elements, got {d}", .{ prop, RKISP1_CIF_ISP_LSC_SECTORS_TBL_SIZE, sizes.len });
            return []f64{};
        }

        const sum = std.math.sum(sizes);
        if (sum < 0.495 or sum > 0.505) {
            log.error("RkISP1Lsc", "Invalid '{s}' values: sum of the elements should be 0.5, got {d}", .{ prop, sum });
            return []f64{};
        }

        return sizes;
    }

    const kColourTemperatureChangeThreshhold: i32 = 10;

    const Components = struct {
        ct: u32,
        r: []u16,
        gr: []u16,
        gb: []u16,
        b: []u16,
    };

    const LscTableLoader = struct {
        pub fn parseLscData(self: *LscTableLoader, yamlSets: *yaml_parser.YamlObject, lscData: *std.AutoHashMap(u32, Components)) i32 {
            const sets = yamlSets.asList();

            for (sets.iterator()) |yamlSet| {
                const ct = yamlSet.get("ct").get(u32) orelse 0;

                if (lscData.get(ct) != null) {
                    log.error("RkISP1Lsc", "Multiple sets found for color temperature {d}", .{ ct });
                    return -EINVAL;
                }

                var set = Components{
                    .ct = ct,
                    .r = self.parseTable(yamlSet, "r"),
                    .gr = self.parseTable(yamlSet, "gr"),
                    .gb = self.parseTable(yamlSet, "gb"),
                    .b = self.parseTable(yamlSet, "b"),
                };

                if (set.r.len == 0 or set.gr.len == 0 or set.gb.len == 0 or set.b.len == 0) {
                    log.error("RkISP1Lsc", "Set for color temperature {d} is missing tables", .{ ct });
                    return -EINVAL;
                }

                lscData.put(ct, set);
            }

            if (lscData.len == 0) {
                log.error("RkISP1Lsc", "Failed to load any sets");
                return -EINVAL;
            }

            return 0;
        }

        fn parseTable(self: *LscTableLoader, tuningData: *yaml_parser.YamlObject, prop: []const u8) []u16 {
            const kLscNumSamples = RKISP1_CIF_ISP_LSC_SAMPLES_MAX * RKISP1_CIF_ISP_LSC_SAMPLES_MAX;

            const table = tuningData.get(prop).getList(u16) orelse []u16{};
            if (table.len != kLscNumSamples) {
                log.error("RkISP1Lsc", "Invalid '{s}' values: expected {d} elements, got {d}", .{ prop, kLscNumSamples, table.len });
                return []u16{};
            }

            return table;
        }
    };

    const LscPolynomialLoader = struct {
        sensorSize: Size,
        cropRectangle: Rectangle,
        xSizes: []f64,
        ySizes: []f64,

        pub fn parseLscData(self: *LscPolynomialLoader, yamlSets: *yaml_parser.YamlObject, lscData: *std.AutoHashMap(u32, Components)) i32 {
            const sets = yamlSets.asList();

            for (sets.iterator()) |yamlSet| {
                const ct = yamlSet.get("ct").get(u32) orelse 0;

                if (lscData.get(ct) != null) {
                    log.error("RkISP1Lsc", "Multiple sets found for color temperature {d}", .{ ct });
                    return -EINVAL;
                }

                var set = Components{
                    .ct = ct,
                    .r = self.samplePolynomial(yamlSet.get("r").get(LscPolynomial)),
                    .gr = self.samplePolynomial(yamlSet.get("gr").get(LscPolynomial)),
                    .gb = self.samplePolynomial(yamlSet.get("gb").get(LscPolynomial)),
                    .b = self.samplePolynomial(yamlSet.get("b").get(LscPolynomial)),
                };

                if (set.r.len == 0 or set.gr.len == 0 or set.gb.len == 0 or set.b.len == 0) {
                    log.error("RkISP1Lsc", "Failed to parse polynomial for color temperature {d}", .{ ct });
                    return -EINVAL;
                }

                lscData.put(ct, set);
            }

            if (lscData.len == 0) {
                log.error("RkISP1Lsc", "Failed to load any sets");
                return -EINVAL;
            }

            return 0;
        }

        fn samplePolynomial(self: *LscPolynomialLoader, poly: LscPolynomial) []u16 {
            const k = RKISP1_CIF_ISP_LSC_SAMPLES_MAX;

            const m = poly.getM();
            const x0 = self.cropRectangle.x / m;
            const y0 = self.cropRectangle.y / m;
            const w = self.cropRectangle.width / m;
            const h = self.cropRectangle.height / m;
            var res = std.ArrayList(u16).init(std.heap.page_allocator);

            assert(self.xSizes.len * 2 + 1 == k);
            assert(self.ySizes.len * 2 + 1 == k);

            res.ensureTotalCapacity(k * k);

            const xPos = self.sizesListToPositions(self.xSizes);
            const yPos = self.sizesListToPositions(self.ySizes);

            for (var y: usize = 0; y < k; y += 1) {
                for (var x: usize = 0; x < k; x += 1) {
                    const xp = x0 + xPos[x] * w;
                    const yp = y0 + yPos[y] * h;
                    var v = @intCast(i32, poly.sampleAtNormalizedPixelPos(xp, yp) * 1024.0);
                    v = std.math.clamp(v, 1024, 4095);
                    res.append(@intCast(u16, v));
                }
            }
            return res.toOwnedSlice();
        }

        fn sizesListToPositions(self: *LscPolynomialLoader, sizes: []f64) []f64 {
            const half = sizes.len;
            var res = std.ArrayList(f64).init(std.heap.page_allocator);
            res.ensureTotalCapacity(half * 2 + 1);
            var x = 0.0;

            res.append(0.5);
            for (var i: usize = 1; i <= half; i += 1) {
                x += sizes[half - i];
                res.items[half - i] = 0.5 - x;
                res.items[half + i] = 0.5 + x;
            }

            return res.toOwnedSlice();
        }
    };
};

pub fn main() void {
    const lsc = LensShadingCorrection{};
    // Example usage of the LensShadingCorrection struct
}
