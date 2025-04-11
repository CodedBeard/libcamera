const std = @import("std");

pub const DenoiseStatus = struct {
    noiseConstant: f64,
    noiseSlope: f64,
    strength: f64,
    mode: u32,
};

pub const SdnStatus = struct {
    noiseConstant: f64,
    noiseSlope: f64,
    noiseConstant2: f64,
    noiseSlope2: f64,
    strength: f64,
};

pub const CdnStatus = struct {
    strength: f64,
    threshold: f64,
};

pub const TdnStatus = struct {
    noiseConstant: f64,
    noiseSlope: f64,
    threshold: f64,
};
