const std = @import("std");
const libcamera = @import("libcamera");

const IPAHwSettings = struct {
    numAeCells: u32,
    numHistogramBins: u32,
    numHistogramWeights: u32,
    numGammaOutSamples: u32,
    compand: bool,
};

const IPASessionConfiguration = struct {
    agc: struct {
        measureWindow: libcamera.rkisp1_cif_isp_window,
    },
    awb: struct {
        measureWindow: libcamera.rkisp1_cif_isp_window,
        enabled: bool,
    },
    lsc: struct {
        enabled: bool,
    },
    sensor: struct {
        minExposureTime: libcamera.utils.Duration,
        maxExposureTime: libcamera.utils.Duration,
        minAnalogueGain: f64,
        maxAnalogueGain: f64,
        defVBlank: i32,
        lineDuration: libcamera.utils.Duration,
        size: libcamera.Size,
    },
    raw: bool,
    paramFormat: u32,
};

const IPAActiveState = struct {
    agc: struct {
        manual: struct {
            exposure: u32,
            gain: f64,
        },
        automatic: struct {
            exposure: u32,
            gain: f64,
        },
        autoEnabled: bool,
        constraintMode: libcamera.controls.AeConstraintModeEnum,
        exposureMode: libcamera.controls.AeExposureModeEnum,
        meteringMode: libcamera.controls.AeMeteringModeEnum,
        maxFrameDuration: libcamera.utils.Duration,
    },
    awb: struct {
        gains: struct {
            manual: libcamera.RGB(f64),
            automatic: libcamera.RGB(f64),
        },
        temperatureK: u32,
        autoEnabled: bool,
    },
    ccm: struct {
        ccm: libcamera.Matrix(f32, 3, 3),
    },
    cproc: struct {
        brightness: i8,
        contrast: u8,
        saturation: u8,
    },
    dpf: struct {
        denoise: bool,
    },
    filter: struct {
        denoise: u8,
        sharpness: u8,
    },
    goc: struct {
        gamma: f64,
    },
};

const IPAFrameContext = struct {
    agc: struct {
        exposure: u32,
        gain: f64,
        autoEnabled: bool,
        constraintMode: libcamera.controls.AeConstraintModeEnum,
        exposureMode: libcamera.controls.AeExposureModeEnum,
        meteringMode: libcamera.controls.AeMeteringModeEnum,
        maxFrameDuration: libcamera.utils.Duration,
        updateMetering: bool,
    },
    awb: struct {
        gains: libcamera.RGB(f64),
        autoEnabled: bool,
        temperatureK: u32,
    },
    cproc: struct {
        brightness: i8,
        contrast: u8,
        saturation: u8,
        update: bool,
    },
    dpf: struct {
        denoise: bool,
        update: bool,
    },
    filter: struct {
        denoise: u8,
        sharpness: u8,
        update: bool,
    },
    goc: struct {
        gamma: f64,
        update: bool,
    },
    sensor: struct {
        exposure: u32,
        gain: f64,
    },
    ccm: struct {
        ccm: libcamera.Matrix(f32, 3, 3),
    },
    lux: struct {
        lux: f64,
    },
};

const IPAContext = struct {
    hw: ?*const IPAHwSettings,
    sensorInfo: libcamera.IPACameraSensorInfo,
    configuration: IPASessionConfiguration,
    activeState: IPAActiveState,
    frameContexts: libcamera.FCQueue(IPAFrameContext),
    ctrlMap: libcamera.ControlInfoMap.Map,
    debugMetadata: libcamera.DebugMetadata,
    camHelper: ?*libcamera.CameraSensorHelper,

    pub fn init(self: *IPAContext, frameContextSize: u32) void {
        self.hw = null;
        self.frameContexts = libcamera.FCQueue(IPAFrameContext).init(frameContextSize);
    }
};
