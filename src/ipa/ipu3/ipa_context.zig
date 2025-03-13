const std = @import("std");
const linux = @cImport({
    @cInclude("linux/intel-ipu3.h");
});

const utils = @import("libcamera/base/utils.zig");
const controls = @import("libcamera/controls.zig");
const geometry = @import("libcamera/geometry.zig");
const fc_queue = @import("libipa/fc_queue.zig");

pub const IPASessionConfiguration = struct {
    grid: struct {
        bdsGrid: linux.ipu3_uapi_grid_config,
        bdsOutputSize: geometry.Size,
        stride: u32,
    },
    af: struct {
        afGrid: linux.ipu3_uapi_grid_config,
    },
    agc: struct {
        minExposureTime: utils.Duration,
        maxExposureTime: utils.Duration,
        minAnalogueGain: f64,
        maxAnalogueGain: f64,
    },
    sensor: struct {
        defVBlank: i32,
        lineDuration: utils.Duration,
        size: geometry.Size,
    },
};

pub const IPAActiveState = struct {
    af: struct {
        focus: u32,
        maxVariance: f64,
        stable: bool,
    },
    agc: struct {
        exposure: u32,
        gain: f64,
        constraintMode: u32,
        exposureMode: u32,
    },
    awb: struct {
        gains: struct {
            red: f64,
            green: f64,
            blue: f64,
        },
        temperatureK: f64,
    },
    toneMapping: struct {
        gamma: f64,
        gammaCorrection: linux.ipu3_uapi_gamma_corr_lut,
    },
};

pub const IPAFrameContext = struct {
    sensor: struct {
        exposure: u32,
        gain: f64,
    },
};

pub const IPAContext = struct {
    configuration: IPASessionConfiguration,
    activeState: IPAActiveState,
    frameContexts: fc_queue.FCQueue(IPAFrameContext),
    ctrlMap: std.AutoHashMap(*const controls.ControlId, controls.ControlInfo),
    
    pub fn init(frameContextSize: usize) IPAContext {
        return IPAContext{
            .configuration = undefined,
            .activeState = undefined,
            .frameContexts = fc_queue.FCQueue(IPAFrameContext).init(frameContextSize),
            .ctrlMap = std.AutoHashMap(*const controls.ControlId, controls.ControlInfo).init(std.heap.page_allocator),
        };
    }
};
