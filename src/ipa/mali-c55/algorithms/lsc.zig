const std = @import("std");
const log = @import("log");
const yaml = @import("yaml");

const MaliC55Lsc = struct {};

pub fn init(context: *IPAContext, tuningData: yaml.Node) !void {
    if (!tuningData.has("meshScale")) {
        log.error("meshScale missing from tuningData");
        return error.InvalidArgument;
    }

    self.meshScale = tuningData.get("meshScale").as(u32);

    const yamlSets = tuningData.get("sets");
    if (!yamlSets.isList()) {
        log.error("LSC tables missing or invalid");
        return error.InvalidArgument;
    }

    var tableSize: usize = 0;
    const sets = yamlSets.asList();
    for (sets) |yamlSet| {
        const ct = yamlSet.get("ct").as(u32);

        if (ct == 0) {
            log.error("Invalid colour temperature");
            return error.InvalidArgument;
        }

        if (std.mem.indexOf(self.colourTemperatures, ct) != null) {
            log.error("Multiple sets found for colour temperature");
            return error.InvalidArgument;
        }

        const rTable = yamlSet.get("r").asList(u8) orelse std.ArrayList(u8).init(std.heap.page_allocator);
        const gTable = yamlSet.get("g").asList(u8) orelse std.ArrayList(u8).init(std.heap.page_allocator);
        const bTable = yamlSet.get("b").asList(u8) orelse std.ArrayList(u8).init(std.heap.page_allocator);

        if (tableSize == 0) {
            if (rTable.len != 256 && rTable.len != 1024) {
                log.error("Invalid table size for colour temperature {}", ct);
                return error.InvalidArgument;
            }
            tableSize = rTable.len;
        }

        if (rTable.len != tableSize || gTable.len != tableSize || bTable.len != tableSize) {
            log.error("Invalid or mismatched table size for colour temperature {}", ct);
            return error.InvalidArgument;
        }

        if (self.colourTemperatures.len >= 3) {
            log.error("A maximum of 3 colour temperatures are supported");
            return error.InvalidArgument;
        }

        for (rTable) |r, i| {
            self.mesh[kRedOffset + i] |= (r << (self.colourTemperatures.len * 8));
        }
        for (gTable) |g, i| {
            self.mesh[kGreenOffset + i] |= (g << (self.colourTemperatures.len * 8));
        }
        for (bTable) |b, i| {
            self.mesh[kBlueOffset + i] |= (b << (self.colourTemperatures.len * 8));
        }

        self.colourTemperatures.append(ct);
    }

    if (tableSize == 256) {
        self.meshSize = 15;
    } else {
        self.meshSize = 31;
    }
}

fn fillConfigParamsBlock(block: *mali_c55_params_block) usize {
    block.header.type = MALI_C55_PARAM_MESH_SHADING_CONFIG;
    block.header.flags = MALI_C55_PARAM_BLOCK_FL_NONE;
    block.header.size = @sizeOf(mali_c55_params_mesh_shading_config);

    block.shading_config.mesh_show = false;
    block.shading_config.mesh_scale = self.meshScale;
    block.shading_config.mesh_page_r = 0;
    block.shading_config.mesh_page_g = 1;
    block.shading_config.mesh_page_b = 2;
    block.shading_config.mesh_width = self.meshSize;
    block.shading_config.mesh_height = self.meshSize;

    std.mem.copy(u32, block.shading_config.mesh, self.mesh);

    return block.header.size;
}

fn fillSelectionParamsBlock(block: *mali_c55_params_block, bank: u8, alpha: u8) usize {
    block.header.type = MALI_C55_PARAM_MESH_SHADING_SELECTION;
    block.header.flags = MALI_C55_PARAM_BLOCK_FL_NONE;
    block.header.size = @sizeOf(mali_c55_params_mesh_shading_selection);

    block.shading_selection.mesh_alpha_bank_r = bank;
    block.shading_selection.mesh_alpha_bank_g = bank;
    block.shading_selection.mesh_alpha_bank_b = bank;
    block.shading_selection.mesh_alpha_r = alpha;
    block.shading_selection.mesh_alpha_g = alpha;
    block.shading_selection.mesh_alpha_b = alpha;
    block.shading_selection.mesh_strength = 0x1000;

    return block.header.size;
}

fn findBankAndAlpha(ct: u32) (u8, u8) {
    var i: usize = 0;

    ct = std.math.clamp(ct, self.colourTemperatures[0], self.colourTemperatures[self.colourTemperatures.len - 1]);

    while (i < self.colourTemperatures.len - 1) {
        if (ct >= self.colourTemperatures[i] && ct <= self.colourTemperatures[i + 1]) {
            break;
        }
        i += 1;
    }

    const alpha = (255 * (ct - self.colourTemperatures[i])) / (self.colourTemperatures[i + 1] - self.colourTemperatures[i]);

    return (i, alpha);
}

pub fn prepare(context: *IPAContext, frame: u32, frameContext: *IPAFrameContext, params: *mali_c55_params_buffer) void {
    const temperatureK = context.activeState.agc.temperatureK;
    var bank: u8 = 0;
    var alpha: u8 = 0;

    if (self.colourTemperatures.len == 1) {
        if (frame > 0) {
            return;
        }
        bank = 0;
        alpha = 0;
    } else {
        (bank, alpha) = findBankAndAlpha(temperatureK);
    }

    var block: mali_c55_params_block = undefined;
    block.data = &params.data[params.total_size];

    params.total_size += fillSelectionParamsBlock(&block, bank, alpha);

    if (frame > 0) {
        return;
    }

    block.data = &params.data[params.total_size];
    params.total_size += fillConfigParamsBlock(&block);
}

pub fn registerAlgorithm() void {
    // Register the Lsc algorithm
}
