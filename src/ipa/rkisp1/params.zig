const std = @import("std");
const log = @import("log");
const utils = @import("utils");

const BlockType = enum {
    Bls,
    Dpcc,
    Sdg,
    AwbGain,
    Flt,
    Bdm,
    Ctk,
    Goc,
    Dpf,
    DpfStrength,
    Cproc,
    Ie,
    Lsc,
    Awb,
    Hst,
    Aec,
    Afc,
    CompandBls,
    CompandExpand,
    CompandCompress,
};

const BlockTypeInfo = struct {
    type: u32,
    size: usize,
    offset: usize,
    enableBit: u32,
};

const kBlockTypeInfo = std.AutoHashMap(BlockType, BlockTypeInfo).init(std.heap.page_allocator);

fn initBlockTypeInfo() void {
    kBlockTypeInfo.put(BlockType.Bls, BlockTypeInfo{ .type = 0, .size = @sizeOf(rkisp1_cif_isp_bls_config), .offset = @offsetof(rkisp1_params_cfg, others.bls_config), .enableBit = 0 });
    kBlockTypeInfo.put(BlockType.Dpcc, BlockTypeInfo{ .type = 1, .size = @sizeOf(rkisp1_cif_isp_dpcc_config), .offset = @offsetof(rkisp1_params_cfg, others.dpcc_config), .enableBit = 1 });
    kBlockTypeInfo.put(BlockType.Sdg, BlockTypeInfo{ .type = 2, .size = @sizeOf(rkisp1_cif_isp_sdg_config), .offset = @offsetof(rkisp1_params_cfg, others.sdg_config), .enableBit = 2 });
    kBlockTypeInfo.put(BlockType.AwbGain, BlockTypeInfo{ .type = 3, .size = @sizeOf(rkisp1_cif_isp_awb_gain_config), .offset = @offsetof(rkisp1_params_cfg, others.awb_gain_config), .enableBit = 3 });
    kBlockTypeInfo.put(BlockType.Flt, BlockTypeInfo{ .type = 4, .size = @sizeOf(rkisp1_cif_isp_flt_config), .offset = @offsetof(rkisp1_params_cfg, others.flt_config), .enableBit = 4 });
    kBlockTypeInfo.put(BlockType.Bdm, BlockTypeInfo{ .type = 5, .size = @sizeOf(rkisp1_cif_isp_bdm_config), .offset = @offsetof(rkisp1_params_cfg, others.bdm_config), .enableBit = 5 });
    kBlockTypeInfo.put(BlockType.Ctk, BlockTypeInfo{ .type = 6, .size = @sizeOf(rkisp1_cif_isp_ctk_config), .offset = @offsetof(rkisp1_params_cfg, others.ctk_config), .enableBit = 6 });
    kBlockTypeInfo.put(BlockType.Goc, BlockTypeInfo{ .type = 7, .size = @sizeOf(rkisp1_cif_isp_goc_config), .offset = @offsetof(rkisp1_params_cfg, others.goc_config), .enableBit = 7 });
    kBlockTypeInfo.put(BlockType.Dpf, BlockTypeInfo{ .type = 8, .size = @sizeOf(rkisp1_cif_isp_dpf_config), .offset = @offsetof(rkisp1_params_cfg, others.dpf_config), .enableBit = 8 });
    kBlockTypeInfo.put(BlockType.DpfStrength, BlockTypeInfo{ .type = 9, .size = @sizeOf(rkisp1_cif_isp_dpf_strength_config), .offset = @offsetof(rkisp1_params_cfg, others.dpf_strength_config), .enableBit = 9 });
    kBlockTypeInfo.put(BlockType.Cproc, BlockTypeInfo{ .type = 10, .size = @sizeOf(rkisp1_cif_isp_cproc_config), .offset = @offsetof(rkisp1_params_cfg, others.cproc_config), .enableBit = 10 });
    kBlockTypeInfo.put(BlockType.Ie, BlockTypeInfo{ .type = 11, .size = @sizeOf(rkisp1_cif_isp_ie_config), .offset = @offsetof(rkisp1_params_cfg, others.ie_config), .enableBit = 11 });
    kBlockTypeInfo.put(BlockType.Lsc, BlockTypeInfo{ .type = 12, .size = @sizeOf(rkisp1_cif_isp_lsc_config), .offset = @offsetof(rkisp1_params_cfg, others.lsc_config), .enableBit = 12 });
    kBlockTypeInfo.put(BlockType.Awb, BlockTypeInfo{ .type = 13, .size = @sizeOf(rkisp1_cif_isp_awb_meas_config), .offset = @offsetof(rkisp1_params_cfg, meas.awb_meas_config), .enableBit = 13 });
    kBlockTypeInfo.put(BlockType.Hst, BlockTypeInfo{ .type = 14, .size = @sizeOf(rkisp1_cif_isp_hst_config), .offset = @offsetof(rkisp1_params_cfg, meas.hst_config), .enableBit = 14 });
    kBlockTypeInfo.put(BlockType.Aec, BlockTypeInfo{ .type = 15, .size = @sizeOf(rkisp1_cif_isp_aec_config), .offset = @offsetof(rkisp1_params_cfg, meas.aec_config), .enableBit = 15 });
    kBlockTypeInfo.put(BlockType.Afc, BlockTypeInfo{ .type = 16, .size = @sizeOf(rkisp1_cif_isp_afc_config), .offset = @offsetof(rkisp1_params_cfg, meas.afc_config), .enableBit = 16 });
    kBlockTypeInfo.put(BlockType.CompandBls, BlockTypeInfo{ .type = 17, .size = @sizeOf(rkisp1_cif_isp_compand_bls_config), .offset = 0, .enableBit = 0 });
    kBlockTypeInfo.put(BlockType.CompandExpand, BlockTypeInfo{ .type = 18, .size = @sizeOf(rkisp1_cif_isp_compand_curve_config), .offset = 0, .enableBit = 0 });
    kBlockTypeInfo.put(BlockType.CompandCompress, BlockTypeInfo{ .type = 19, .size = @sizeOf(rkisp1_cif_isp_compand_curve_config), .offset = 0, .enableBit = 0 });
}

const RkISP1ParamsBlockBase = struct {
    params: *RkISP1Params,
    type: BlockType,
    header: []u8,
    data: []u8,

    pub fn init(params: *RkISP1Params, type: BlockType, data: []u8) RkISP1ParamsBlockBase {
        var header: []u8 = &[_]u8{};
        var data_: []u8 = data;

        if (params.format == V4L2_META_FMT_RK_ISP1_EXT_PARAMS) {
            header = data[0..@sizeOf(rkisp1_ext_params_block_header)];
            data_ = data[@sizeOf(rkisp1_ext_params_block_header)..];
        }

        return RkISP1ParamsBlockBase{
            .params = params,
            .type = type,
            .header = header,
            .data = data_,
        };
    }

    pub fn setEnabled(self: *RkISP1ParamsBlockBase, enabled: bool) void {
        if (self.params.format == V4L2_META_FMT_RK_ISP1_PARAMS) {
            return self.params.setBlockEnabled(self.type, enabled);
        }

        var header = @ptrCast(*rkisp1_ext_params_block_header, self.header.ptr);
        header.flags &= ~(RKISP1_EXT_PARAMS_FL_BLOCK_ENABLE | RKISP1_EXT_PARAMS_FL_BLOCK_DISABLE);
        header.flags |= if (enabled) RKISP1_EXT_PARAMS_FL_BLOCK_ENABLE else RKISP1_EXT_PARAMS_FL_BLOCK_DISABLE;
    }
};

const RkISP1ParamsBlock = struct {
    base: RkISP1ParamsBlockBase,

    pub fn init(params: *RkISP1Params, type: BlockType, data: []u8) RkISP1ParamsBlock {
        return RkISP1ParamsBlock{
            .base = RkISP1ParamsBlockBase.init(params, type, data),
        };
    }

    pub fn operator_arrow(self: *RkISP1ParamsBlock) *anytype {
        return @ptrCast(*anytype, self.base.data.ptr);
    }

    pub fn operator_star(self: *RkISP1ParamsBlock) anytype {
        return @ptrCast(*anytype, self.base.data.ptr).*;
    }
};

const RkISP1Params = struct {
    format: u32,
    data: []u8,
    used: usize,
    blocks: std.AutoHashMap(BlockType, []u8),

    pub fn init(format: u32, data: []u8) RkISP1Params {
        var used: usize = 0;

        if (format == V4L2_META_FMT_RK_ISP1_EXT_PARAMS) {
            var cfg = @ptrCast(*rkisp1_ext_params_cfg, data.ptr);
            cfg.version = RKISP1_EXT_PARAM_BUFFER_V1;
            cfg.data_size = 0;
            used += @offsetof(rkisp1_ext_params_cfg, data);
        } else {
            std.mem.set(data, 0);
            used = @sizeOf(rkisp1_params_cfg);
        }

        return RkISP1Params{
            .format = format,
            .data = data,
            .used = used,
            .blocks = std.AutoHashMap(BlockType, []u8).init(std.heap.page_allocator),
        };
    }

    pub fn setBlockEnabled(self: *RkISP1Params, type: BlockType, enabled: bool) void {
        const info = kBlockTypeInfo.get(type).?;
        var cfg = @ptrCast(*rkisp1_params_cfg, self.data.ptr);

        if (enabled) {
            cfg.module_ens |= info.enableBit;
        } else {
            cfg.module_ens &= ~info.enableBit;
        }
    }

    pub fn block(self: *RkISP1Params, type: BlockType) []u8 {
        const info = kBlockTypeInfo.get(type).?;

        if (self.format == V4L2_META_FMT_RK_ISP1_PARAMS) {
            if (info.offset == 0) {
                log.error("RkISP1Params", "Block type {d} unavailable in fixed parameters format", .{ @enumToInt(type) });
                return &[_]u8{};
            }

            var cfg = @ptrCast(*rkisp1_params_cfg, self.data.ptr);
            cfg.module_cfg_update |= info.enableBit;
            cfg.module_en_update |= info.enableBit;

            return self.data[info.offset..info.offset + info.size];
        }

        var cacheIt = self.blocks.get(type);
        if (cacheIt != null) {
            return cacheIt.*;
        }

        var size = @sizeOf(rkisp1_ext_params_block_header) + ((info.size + 7) & ~7);
        if (size > self.data.len - self.used) {
            log.error("RkISP1Params", "Out of memory to allocate block type {d}", .{ @enumToInt(type) });
            return &[_]u8{};
        }

        var block = self.data[self.used..self.used + size];
        self.used += size;

        var cfg = @ptrCast(*rkisp1_ext_params_cfg, self.data.ptr);
        cfg.data_size += size;

        std.mem.set(block, 0);

        var header = @ptrCast(*rkisp1_ext_params_block_header, block.ptr);
        header.type = info.type;
        header.size = block.len;

        self.blocks.put(type, block);

        return block;
    }
};

pub fn main() void {
    initBlockTypeInfo();
    const params = RkISP1Params.init(0, &[_]u8{});
    const block = RkISP1ParamsBlock.init(&params, BlockType.Bls, &[_]u8{});
    // Example usage of the RkISP1Params and RkISP1ParamsBlock structs
}
