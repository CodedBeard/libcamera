const std = @import("std");
const libcamera = @import("libcamera");
const utils = @import("libcamera.utils");
const controls = @import("libcamera.controls");
const bayer = @import("libcamera.bayer_format");
const fc_queue = @import("libipa.fc_queue");

pub const IPASessionConfiguration = struct {
    agc: struct {
        minShutterSpeed: utils.Duration,
        maxShutterSpeed: utils.Duration,
        defaultExposure: u32,
        minAnalogueGain: f64,
        maxAnalogueGain: f64,
    },
    sensor: struct {
        bayerOrder: bayer.Order,
        lineDuration: utils.Duration,
        blackLevel: u32,
    },
};

pub const IPAActiveState = struct {
    agc: struct {
        automatic: struct {
            exposure: u32,
            sensorGain: f64,
            ispGain: f64,
        },
        manual: struct {
            exposure: u32,
            sensorGain: f64,
            ispGain: f64,
        },
        autoEnabled: bool,
        constraintMode: u32,
        exposureMode: u32,
        temperatureK: u32,
    },
    awb: struct {
        rGain: f64,
        bGain: f64,
    },
};

pub const IPAFrameContext = struct {
    agc: struct {
        exposure: u32,
        sensorGain: f64,
        ispGain: f64,
    },
    awb: struct {
        rGain: f64,
        bGain: f64,
    },
};

pub const IPAContext = struct {
    configuration: IPASessionConfiguration,
    activeState: IPAActiveState,
    frameContexts: fc_queue.FCQueue(IPAFrameContext),
    ctrlMap: std.HashMap(*const controls.ControlId, controls.ControlInfo),
};

pub fn initIPAContext(frameContextSize: usize) IPAContext {
    return IPAContext{
        .configuration = IPASessionConfiguration{},
        .activeState = IPAActiveState{},
        .frameContexts = fc_queue.FCQueue(IPAFrameContext).init(frameContextSize),
        .ctrlMap = std.HashMap(*const controls.ControlId, controls.ControlInfo).init(std.heap.page_allocator),
    };
}
