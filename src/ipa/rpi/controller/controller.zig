const std = @import("std");
const yaml = @import("yaml");
const Metadata = @import("metadata");
const CameraMode = @import("camera_mode");
const StatisticsPtr = @import("statistics").StatisticsPtr;

pub const Controller = struct {
    pub const HardwareConfig = struct {
        agcRegions: std.math.Vector(2, u32),
        agcZoneWeights: std.math.Vector(2, u32),
        awbRegions: std.math.Vector(2, u32),
        cacRegions: std.math.Vector(2, u32),
        focusRegions: std.math.Vector(2, u32),
        numHistogramBins: u32,
        numGammaPoints: u32,
        pipelineWidth: u32,
        statsInline: bool,
        minPixelProcessingTime: f64,
        dataBufferStrided: bool,
    };

    switchModeCalled: bool,
    target: []const u8,
    algorithms: std.ArrayList(*Algorithm),
    globalMetadata: Metadata,

    pub fn init(self: *Controller) void {
        self.switchModeCalled = false;
    }

    pub fn deinit(self: *Controller) void {}

    pub fn read(self: *Controller, filename: []const u8) !void {
        const file = try std.fs.File.openRead(filename);
        defer file.close();

        const root = try yaml.parse(file);
        const version = root.get("version").get(f64, 1.0);
        self.target = root.get("target").get([]const u8, "bcm2835");

        if (version < 2.0) {
            std.log.warn("This format of the tuning file will be deprecated soon! Please use the convert_tuning.py utility to update to version 2.0.");

            for (root.each |key, value| {
                try self.createAlgorithm(key, value);
            });
        } else if (version < 3.0) {
            if (!root.contains("algorithms")) {
                return error.InvalidArgument;
            }

            for (root.get("algorithms").each |rootAlgo| {
                for (rootAlgo.each |key, value| {
                    try self.createAlgorithm(key, value);
                });
            });
        } else {
            return error.InvalidArgument;
        }
    }

    fn createAlgorithm(self: *Controller, name: []const u8, params: yaml.Node) !void {
        const algo = try Algorithm.create(self, name);
        try algo.read(params);
        self.algorithms.append(algo);
    }

    pub fn initialise(self: *Controller) void {
        for (self.algorithms.each |algo| {
            algo.initialise();
        });
    }

    pub fn switchMode(self: *Controller, cameraMode: CameraMode, metadata: *Metadata) void {
        for (self.algorithms.each |algo| {
            algo.switchMode(cameraMode, metadata);
        });
        self.switchModeCalled = true;
    }

    pub fn prepare(self: *Controller, imageMetadata: *Metadata) void {
        assert(self.switchModeCalled);
        for (self.algorithms.each |algo| {
            algo.prepare(imageMetadata);
        });
    }

    pub fn process(self: *Controller, stats: StatisticsPtr, imageMetadata: *Metadata) void {
        assert(self.switchModeCalled);
        for (self.algorithms.each |algo| {
            algo.process(stats, imageMetadata);
        });
    }

    pub fn getGlobalMetadata(self: *Controller) *Metadata {
        return &self.globalMetadata;
    }

    pub fn getAlgorithm(self: *Controller, name: []const u8) *Algorithm {
        const nameLen = name.len;
        for (self.algorithms.each |algo| {
            const algoName = algo.name();
            const algoNameLen = algoName.len;
            if (algoNameLen >= nameLen and std.mem.eql(u8, name, algoName[algoNameLen - nameLen..]) and (nameLen == algoNameLen or algoName[algoNameLen - nameLen - 1] == '.')) {
                return algo;
            }
        });
        return null;
    }

    pub fn getTarget(self: *Controller) []const u8 {
        return self.target;
    }

    pub fn getHardwareConfig(self: *Controller) *Controller.HardwareConfig {
        const cfg = HardwareConfigMap.get(self.getTarget());
        assert(cfg != null);
        return cfg.*;
    }
};
