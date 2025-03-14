const std = @import("std");
const libcamera = @import("libcamera");

pub const IPASessionConfiguration = struct {
    gamma: f32,
    agc: struct {
        exposureMin: i32,
        exposureMax: i32,
        againMin: f64,
        againMax: f64,
        againMinStep: f64,
    },
    black: struct {
        level: ?u8 = null,
    },
};

pub const IPAActiveState = struct {
    blc: struct {
        level: u8,
    },
    gains: struct {
        red: f64,
        green: f64,
        blue: f64,
    },
    gamma: struct {
        gammaTable: [1024]f64,
        blackLevel: u8,
        contrast: f64,
    },
    knobs: struct {
        contrast: ?f64 = null,
    },
};

pub const IPAFrameContext = struct {
    sensor: struct {
        exposure: i32,
        gain: f64,
    },
};

pub const IPAContext = struct {
    configuration: IPASessionConfiguration,
    activeState: IPAActiveState,
    frameContexts: std.ArrayList(IPAFrameContext),
    ctrlMap: std.HashMap(*const libcamera.ControlId, libcamera.ControlInfo),
};

pub fn initIPAContext(frameContextSize: usize) IPAContext {
    return IPAContext{
        .configuration = IPASessionConfiguration{},
        .activeState = IPAActiveState{},
        .frameContexts = std.ArrayList(IPAFrameContext).init(std.heap.page_allocator),
        .ctrlMap = std.HashMap(*const libcamera.ControlId, libcamera.ControlInfo).init(std.heap.page_allocator),
    };
}
