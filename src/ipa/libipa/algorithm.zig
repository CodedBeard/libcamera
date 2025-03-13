const std = @import("std");

pub const Algorithm = struct {
    pub const Module = struct {};

    pub fn init(
        context: *Module.Context,
        tuningData: *const YamlObject,
    ) callconv(.Inline) !void {
        // Default implementation does nothing
    }

    pub fn configure(
        context: *Module.Context,
        configInfo: *const Module.Config,
    ) callconv(.Inline) !void {
        // Default implementation does nothing
    }

    pub fn queueRequest(
        context: *Module.Context,
        frame: u32,
        frameContext: *Module.FrameContext,
        controls: *const ControlList,
    ) callconv(.Inline) void {
        // Default implementation does nothing
    }

    pub fn prepare(
        context: *Module.Context,
        frame: u32,
        frameContext: *Module.FrameContext,
        params: *Module.Params,
    ) callconv(.Inline) void {
        // Default implementation does nothing
    }

    pub fn process(
        context: *Module.Context,
        frame: u32,
        frameContext: *Module.FrameContext,
        stats: *const Module.Stats,
        metadata: *ControlList,
    ) callconv(.Inline) void {
        // Default implementation does nothing
    }
};

pub const AlgorithmFactoryBase = struct {
    name: []const u8,

    pub fn create(self: *const AlgorithmFactoryBase) callconv(.Inline) !*Algorithm {
        return error.Unimplemented;
    }
};

pub const AlgorithmFactory = struct {
    base: AlgorithmFactoryBase,

    pub fn create(self: *const AlgorithmFactory) callconv(.Inline) !*Algorithm {
        return AlgorithmFactoryBase.create(&self.base);
    }
};

pub fn registerAlgorithm(factory: *AlgorithmFactoryBase) void {
    // Register the algorithm factory
}

pub fn createAlgorithm(name: []const u8) !*Algorithm {
    return error.Unimplemented;
}

pub fn REGISTER_IPA_ALGORITHM(algorithm: type, name: []const u8) void {
    const factory = AlgorithmFactory{
        .base = AlgorithmFactoryBase{
            .name = name,
        },
    };
    registerAlgorithm(&factory.base);
}
