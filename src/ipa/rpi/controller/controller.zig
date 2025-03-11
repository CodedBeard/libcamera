const std = @import("std");
const libcamera = @import("libcamera");
const YamlParser = @import("libcamera.YamlParser");
const Algorithm = @import("algorithm");
const Metadata = @import("metadata");

const RPiController = libcamera.LogCategory("RPiController");

const HardwareConfigMap = std.HashMap([]const u8, Controller.HardwareConfig).init(std.heap.page_allocator);

pub const Controller = struct {
    switchModeCalled: bool,
    algorithms: []Algorithm,
    globalMetadata: Metadata,
    target: []const u8,

    pub fn init() Controller {
        return Controller{
            .switchModeCalled = false,
            .algorithms = &[_]Algorithm{},
            .globalMetadata = Metadata.init(),
            .target = "bcm2835",
        };
    }

    pub fn deinit(self: *Controller) void {}

    pub fn read(self: *Controller, filename: []const u8) !void {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const root = try YamlParser.parse(file);
        const version = root.get("version").get(f64, 1.0);
        self.target = root.get("target").get([]const u8, "bcm2835");

        if (version < 2.0) {
            RPiController.warn("This format of the tuning file will be deprecated soon! Please use the convert_tuning.py utility to update to version 2.0.");

            for (root.asDict()) |entry| {
                try self.createAlgorithm(entry.key, entry.value);
            }
        } else if (version < 3.0) {
            if (!root.contains("algorithms")) {
                RPiController.error("Tuning file does not have an \"algorithms\" list!");
                return error.InvalidArgument;
            }

            for (root.get("algorithms").asList()) |rootAlgo| {
                for (rootAlgo.asDict()) |entry| {
                    try self.createAlgorithm(entry.key, entry.value);
                }
            }
        } else {
            RPiController.error("Unrecognised version for the tuning file");
            return error.InvalidArgument;
        }
    }

    fn createAlgorithm(self: *Controller, name: []const u8, params: YamlObject) !void {
        const it = Algorithm.getAlgorithms().get(name);
        if (it == null) {
            RPiController.warn("No algorithm found for \"{s}\"", .{name});
            return;
        }

        const algo = it.?(self);
        try algo.read(params);

        self.algorithms.append(algo);
    }

    pub fn initialise(self: *Controller) void {
        for (self.algorithms) |algo| {
            algo.initialise();
        }
    }

    pub fn switchMode(self: *Controller, cameraMode: CameraMode, metadata: *Metadata) void {
        for (self.algorithms) |algo| {
            algo.switchMode(cameraMode, metadata);
        }
        self.switchModeCalled = true;
    }

    pub fn prepare(self: *Controller, imageMetadata: *Metadata) void {
        assert(self.switchModeCalled);
        for (self.algorithms) |algo| {
            algo.prepare(imageMetadata);
        }
    }

    pub fn process(self: *Controller, stats: *Statistics, imageMetadata: *Metadata) void {
        assert(self.switchModeCalled);
        for (self.algorithms) |algo| {
            algo.process(stats, imageMetadata);
        }
    }

    pub fn getGlobalMetadata(self: *Controller) *Metadata {
        return &self.globalMetadata;
    }

    pub fn getAlgorithm(self: *Controller, name: []const u8) ?*Algorithm {
        const nameLen = name.len;
        for (self.algorithms) |algo| {
            const algoName = algo.name();
            const algoNameLen = algoName.len;
            if (algoNameLen >= nameLen and std.mem.eql(u8, name, algoName[algoNameLen - nameLen..]) and (nameLen == algoNameLen or algoName[algoNameLen - nameLen - 1] == '.')) {
                return algo;
            }
        }
        return null;
    }

    pub fn getTarget(self: *Controller) []const u8 {
        return self.target;
    }

    pub fn getHardwareConfig(self: *Controller) *Controller.HardwareConfig {
        const cfg = HardwareConfigMap.get(self.getTarget());
        assert(cfg != null);
        return cfg.?;
    }

    pub const HardwareConfig = struct {
        agcRegions: libcamera.Size,
        agcZoneWeights: libcamera.Size,
        awbRegions: libcamera.Size,
        cacRegions: libcamera.Size,
        focusRegions: libcamera.Size,
        numHistogramBins: u32,
        numGammaPoints: u32,
        pipelineWidth: u32,
        statsInline: bool,
        minPixelProcessingTime: std.time.Duration,
        dataBufferStrided: bool,
    };
};

pub fn initHardwareConfigMap() void {
    HardwareConfigMap.put("bcm2835", Controller.HardwareConfig{
        .agcRegions = libcamera.Size{ .width = 15, .height = 1 },
        .agcZoneWeights = libcamera.Size{ .width = 15, .height = 1 },
        .awbRegions = libcamera.Size{ .width = 16, .height = 12 },
        .cacRegions = libcamera.Size{ .width = 0, .height = 0 },
        .focusRegions = libcamera.Size{ .width = 4, .height = 3 },
        .numHistogramBins = 128,
        .numGammaPoints = 33,
        .pipelineWidth = 13,
        .statsInline = false,
        .minPixelProcessingTime = 0,
        .dataBufferStrided = true,
    });

    HardwareConfigMap.put("pisp", Controller.HardwareConfig{
        .agcRegions = libcamera.Size{ .width = 0, .height = 0 },
        .agcZoneWeights = libcamera.Size{ .width = 15, .height = 15 },
        .awbRegions = libcamera.Size{ .width = 32, .height = 32 },
        .cacRegions = libcamera.Size{ .width = 8, .height = 8 },
        .focusRegions = libcamera.Size{ .width = 8, .height = 8 },
        .numHistogramBins = 1024,
        .numGammaPoints = 64,
        .pipelineWidth = 16,
        .statsInline = true,
        .minPixelProcessingTime = 1.0 / 380 * std.time.microsecond,
        .dataBufferStrided = false,
    });
}
