const std = @import("std");
const log = @import("log");
const yaml = @import("yaml");
const algorithm = @import("algorithm");

const IPAModuleAlgo = log.Category("IPAModuleAlgo");

pub const Module = struct {
    pub const Context = struct {};
    pub const FrameContext = struct {};
    pub const Config = struct {};
    pub const Params = struct {};
    pub const Stats = struct {};

    algorithms: std.ArrayList(*algorithm.Algorithm),

    pub fn init() Module {
        return Module{
            .algorithms = std.ArrayList(*algorithm.Algorithm).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *Module) void {
        self.algorithms.deinit();
    }

    pub fn algorithms(self: *Module) std.ArrayList(*algorithm.Algorithm) {
        return self.algorithms;
    }

    pub fn createAlgorithms(self: *Module, context: *Context, algorithms: yaml.YamlObject) !void {
        const list = algorithms.asList();
        for (list.items()) |algo, i| {
            if (!algo.isDictionary()) {
                log.error(IPAModuleAlgo, "Invalid YAML syntax for algorithm {d}", .{i});
                self.algorithms.clear();
                return error.InvalidAlgorithm;
            }

            self.createAlgorithm(context, algo) catch |err| {
                self.algorithms.clear();
                return err;
            };
        }
    }

    pub fn registerAlgorithm(factory: *algorithm.AlgorithmFactoryBase) void {
        Module.factories().append(factory);
    }

    fn createAlgorithm(self: *Module, context: *Context, data: yaml.YamlObject) !void {
        const name = data.asDict().items()[0].key;
        const algoData = data.asDict().items()[0].value;
        const algo = try Module.createAlgorithm(name);
        if (algo == null) {
            log.error(IPAModuleAlgo, "Algorithm '{s}' not found", .{name});
            return error.AlgorithmNotFound;
        }

        try algo.init(context, algoData);
        log.debug(IPAModuleAlgo, "Instantiated algorithm '{s}'", .{name});
        self.algorithms.append(algo);
    }

    fn createAlgorithm(name: []const u8) !*algorithm.Algorithm {
        for (Module.factories().items()) |factory| {
            if (std.mem.eql(u8, name, factory.name)) {
                return try factory.create();
            }
        }

        return null;
    }

    fn factories() *std.ArrayList(*algorithm.AlgorithmFactoryBase) {
        return &std.ArrayList(*algorithm.AlgorithmFactoryBase).init(std.heap.page_allocator);
    }
};
