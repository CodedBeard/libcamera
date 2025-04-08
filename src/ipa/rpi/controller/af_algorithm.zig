const std = @import("std");

pub const AfAlgorithm = struct {
    controller: *Controller,

    pub const AfRange = enum {
        Normal,
        Macro,
        Full,
        Max,
    };

    pub const AfSpeed = enum {
        Normal,
        Fast,
        Max,
    };

    pub const AfMode = enum {
        Manual,
        Auto,
        Continuous,
    };

    pub const AfPause = enum {
        Immediate,
        Deferred,
        Resume,
    };

    pub fn init(controller: *Controller) AfAlgorithm {
        return AfAlgorithm{ .controller = controller };
    }

    pub fn setRange(self: *AfAlgorithm, range: AfRange) void {}
    pub fn setSpeed(self: *AfAlgorithm, speed: AfSpeed) void {}
    pub fn setMetering(self: *AfAlgorithm, use_windows: bool) void {}
    pub fn setWindows(self: *AfAlgorithm, wins: []const libcamera.Rectangle) void {}
    pub fn setMode(self: *AfAlgorithm, mode: AfMode) void {}
    pub fn getMode(self: *AfAlgorithm) AfMode { return AfMode.Manual; }
    pub fn setLensPosition(self: *AfAlgorithm, dioptres: f64, hwpos: *i32) bool { return false; }
    pub fn getLensPosition(self: *AfAlgorithm) ?f64 { return null; }
    pub fn triggerScan(self: *AfAlgorithm) void {}
    pub fn cancelScan(self: *AfAlgorithm) void {}
    pub fn pause(self: *AfAlgorithm, pause: AfPause) void {}
};

pub const AfState = enum {
    Idle,
    Scanning,
    Focused,
    Failed,
};

pub const AfPauseState = enum {
    Running,
    Pausing,
    Paused,
};

pub const AfStatus = struct {
    state: AfState,
    pauseState: AfPauseState,
    lensSetting: ?i32,
};
