const std = @import("std");

pub const Algorithm = struct {
    controller: *Controller,

    pub fn init(controller: *Controller) Algorithm {
        return Algorithm{ .controller = controller };
    }

    pub fn name(self: *Algorithm) []const u8 {
        return "Algorithm";
    }

    pub fn read(self: *Algorithm, params: YamlObject) i32 {
        return 0;
    }

    pub fn initialise(self: *Algorithm) void {
    }

    pub fn switchMode(self: *Algorithm, cameraMode: CameraMode, metadata: *Metadata) void {
    }

    pub fn prepare(self: *Algorithm, imageMetadata: *Metadata) void {
    }

    pub fn process(self: *Algorithm, stats: *Statistics, imageMetadata: *Metadata) void {
    }

    pub fn getGlobalMetadata(self: *Algorithm) *Metadata {
        return self.controller.getGlobalMetadata();
    }

    pub fn getTarget(self: *Algorithm) []const u8 {
        return self.controller.getTarget();
    }

    pub fn getHardwareConfig(self: *Algorithm) *Controller.HardwareConfig {
        return self.controller.getHardwareConfig();
    }
};

pub const RegisterAlgorithm = struct {
    name: []const u8,
    createFunc: fn(*Controller) Algorithm,

    pub fn init(name: []const u8, createFunc: fn(*Controller) Algorithm) RegisterAlgorithm {
        return RegisterAlgorithm{ .name = name, .createFunc = createFunc };
    }
};

pub fn getAlgorithms() map([]const u8, fn(*Controller) Algorithm) {
    return algorithms;
}

var algorithms = map([]const u8, fn(*Controller) Algorithm){};

pub fn registerAlgorithm(name: []const u8, createFunc: fn(*Controller) Algorithm) void {
    algorithms[name] = createFunc;
}
