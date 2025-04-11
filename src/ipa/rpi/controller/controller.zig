const std = @import("std");
const YamlObject = @import("yaml_parser").YamlObject;
const File = @import("libcamera.base.file").File;
const Log = @import("libcamera.base.log").Log;
const Algorithm = @import("algorithm").Algorithm;
const Metadata = @import("metadata").Metadata;
const StatisticsPtr = @import("statistics").StatisticsPtr;

const RPiController = @import("RPiController");

const HardwareConfigMap = std.HashMap(
    []const u8,
    RPiController.HardwareConfig,
    std.hash_map.StringHashFn,
    std.hash_map.StringEqlFn,
);

pub const Controller = struct {
    switchModeCalled: bool,
    target: []const u8,
    algorithms: std.ArrayList(Algorithm),
    globalMetadata: Metadata,

    pub fn init() Controller {
        return Controller{
            .switchModeCalled = false,
            .target = "bcm2835",
            .algorithms = std.ArrayList(Algorithm).init(std.heap.page_allocator),
            .globalMetadata = Metadata.init(),
        };
    }

    pub fn read(self: *Controller, filename: []const u8) i32 {
        var file = File.init(filename);
        if (!file.open(File.OpenModeFlag.ReadOnly)) {
            Log.warning("Failed to open tuning file '{s}'", .{filename});
            return -EINVAL;
        }

        var root = YamlObject.parse(file);
        if (root == null) {
            return -EINVAL;
        }

        const version = root.get("version").getOptional(f64, 1.0);
        self.target = root.get("target").getOptional([]const u8, "bcm2835");

        if (version < 2.0) {
            Log.warning("This format of the tuning file will be deprecated soon! Please use the convert_tuning.py utility to update to version 2.0.");

            for (rootItem in root.asDict()) |key, value| {
                const ret = self.createAlgorithm(key, value);
                if (ret != 0) {
                    return ret;
                }
            }
        } else if (version < 3.0) {
            if (!root.contains("algorithms")) {
                Log.error("Tuning file {s} does not have an \"algorithms\" list!", .{filename});
                return -EINVAL;
            }

            for (rootAlgo in root.get("algorithms").asList()) |rootAlgoItem| {
                for (rootAlgoItemEntry in rootAlgoItem.asDict()) |key, value| {
                    const ret = self.createAlgorithm(key, value);
                    if (ret != 0) {
                        return ret;
                    }
                }
            }
        } else {
            Log.error("Unrecognised version {f} for the tuning file {s}", .{version, filename});
            return -EINVAL;
        }

        return 0;
    }

    fn createAlgorithm(self: *Controller, name: []const u8, params: YamlObject) i32 {
        const it = RPiController.getAlgorithms().get(name);
        if (it == null) {
            Log.warning("No algorithm found for \"{s}\"", .{name});
            return 0;
        }

        var algo = it.createFunc(self);
        const ret = algo.read(params);
        if (ret != 0) {
            return ret;
        }

        self.algorithms.append(algo) catch {
            return -ENOMEM;
        };
        return 0;
    }

    pub fn initialise(self: *Controller) void {
        for (algo in self.algorithms.items) |*algo| {
            algo.initialise();
        }
    }

    pub fn switchMode(self: *Controller, cameraMode: CameraMode, metadata: *Metadata) void {
        for (algo in self.algorithms.items) |*algo| {
            algo.switchMode(cameraMode, metadata);
        }
        self.switchModeCalled = true;
    }

    pub fn prepare(self: *Controller, imageMetadata: *Metadata) void {
        assert(self.switchModeCalled);
        for (algo in self.algorithms.items) |*algo| {
            algo.prepare(imageMetadata);
        }
    }

    pub fn process(self: *Controller, stats: StatisticsPtr, imageMetadata: *Metadata) void {
        assert(self.switchModeCalled);
        for (algo in self.algorithms.items) |*algo| {
            algo.process(stats, imageMetadata);
        }
    }

    pub fn getGlobalMetadata(self: *Controller) *Metadata {
        return &self.globalMetadata;
    }

    pub fn getAlgorithm(self: *const Controller, name: []const u8) ?*Algorithm {
        const nameLen = name.len;
        for (algo in self.algorithms.items) |*algo| {
            const algoName = algo.name();
            const algoNameLen = std.mem.len(algoName);
            if (algoNameLen >= nameLen and
                std.mem.eql(u8, name, algoName[algoNameLen - nameLen..]) and
                (nameLen == algoNameLen or algoName[algoNameLen - nameLen - 1] == '.')) {
                return algo;
            }
        }
        return null;
    }

    pub fn getTarget(self: *const Controller) []const u8 {
        return self.target;
    }

    pub fn getHardwareConfig(self: *const Controller) *const RPiController.HardwareConfig {
        const cfg = HardwareConfigMap.get(self.getTarget());
        assert(cfg != null);
        return cfg;
    }
};
