const libcamera = @import("libcamera");
const Pwl = libcamera.ipa.Pwl;

pub const ContrastStatus = struct {
    gammaCurve: Pwl,
    brightness: f64,
    contrast: f64,
};
