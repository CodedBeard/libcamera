const libcamera = @import("libcamera");
const Algorithm = @import("../ccm_algorithm").CcmAlgorithm;
const AwbStatus = @import("../awb_status").AwbStatus;
const CcmStatus = @import("../ccm_status").CcmStatus;
const LuxStatus = @import("../lux_status").LuxStatus;
const Metadata = @import("../metadata").Metadata;
const Pwl = @import("libcamera.ipa.pwl").Pwl;

const NAME = "rpi.ccm";

const Matrix3x3 = libcamera.Matrix(f64, 3, 3);

pub const CtCcm = struct {
    ct: f64,
    ccm: Matrix3x3,
};

pub const CcmConfig = struct {
    ccms: std.ArrayList(CtCcm),
    saturation: Pwl,
};

pub const Ccm = struct {
    algorithm: Algorithm,
    saturation: f64,
    config: CcmConfig,

    pub fn init(controller: *Controller) Ccm {
        return Ccm{
            .algorithm = Algorithm.init(controller),
            .saturation = 1.0,
            .config = CcmConfig{
                .ccms = std.ArrayList(CtCcm).init(std.heap.page_allocator),
                .saturation = Pwl.init(),
            },
        };
    }

    pub fn name(self: *Ccm) []const u8 {
        return NAME;
    }

    pub fn read(self: *Ccm, params: YamlObject) i32 {
        if (params.contains("saturation")) {
            self.config.saturation = params.get("saturation").getOptional(Pwl, Pwl.init());
            if (self.config.saturation.empty()) {
                return -EINVAL;
            }
        }

        for (p in params.get("ccms").asList()) |p| {
            const value = p.get("ct").getOptional(f64, 0.0);
            if (value == 0.0) {
                return -EINVAL;
            }

            var ctCcm = CtCcm{
                .ct = value,
                .ccm = Matrix3x3.init(),
            };

            const ccm = p.get("ccm").getOptional(Matrix3x3, Matrix3x3.init());
            if (ccm == Matrix3x3.init()) {
                return -EINVAL;
            }

            ctCcm.ccm = ccm;

            if (!self.config.ccms.empty() and ctCcm.ct <= self.config.ccms.back().ct) {
                log.error("CCM not in increasing colour temperature order");
                return -EINVAL;
            }

            self.config.ccms.append(ctCcm) catch {
                return -ENOMEM;
            };
        }

        if (self.config.ccms.empty()) {
            log.error("No CCMs specified");
            return -EINVAL;
        }

        return 0;
    }

    pub fn setSaturation(self: *Ccm, saturation: f64) void {
        self.saturation = saturation;
    }

    pub fn initialise(self: *Ccm) void {}

    fn getLocked(comptime T: type, metadata: *Metadata, tag: []const u8, value: *T) bool {
        const ptr = metadata.getLocked(T, tag);
        if (ptr == null) {
            return false;
        }
        value.* = ptr.*;
        return true;
    }

    fn calculateCcm(ccms: []const CtCcm, ct: f64) Matrix3x3 {
        if (ct <= ccms[0].ct) {
            return ccms[0].ccm;
        } else if (ct >= ccms[ccms.len - 1].ct) {
            return ccms[ccms.len - 1].ccm;
        } else {
            var i: usize = 0;
            while (ct > ccms[i].ct) : (i += 1) {}
            const lambda = (ct - ccms[i - 1].ct) / (ccms[i].ct - ccms[i - 1].ct);
            return lambda * ccms[i].ccm + (1.0 - lambda) * ccms[i - 1].ccm;
        }
    }

    fn applySaturation(ccm: Matrix3x3, saturation: f64) Matrix3x3 {
        const RGB2Y = Matrix3x3{
            .data = [_][3]f64{
                { 0.299, 0.587, 0.114 },
                { -0.169, -0.331, 0.500 },
                { 0.500, -0.419, -0.081 },
            },
        };

        const Y2RGB = Matrix3x3{
            .data = [_][3]f64{
                { 1.000, 0.000, 1.402 },
                { 1.000, -0.345, -0.714 },
                { 1.000, 1.771, 0.000 },
            },
        };

        const S = Matrix3x3{
            .data = [_][3]f64{
                { 1, 0, 0 },
                { 0, saturation, 0 },
                { 0, 0, saturation },
            },
        };

        return Y2RGB * S * RGB2Y * ccm;
    }

    pub fn prepare(self: *Ccm, imageMetadata: *Metadata) void {
        var awbOk = false;
        var luxOk = false;
        var awb = AwbStatus{
            .temperatureK = 4000,
        };
        var lux = LuxStatus{
            .lux = 400,
        };

        {
            const lock = std.mutex.Lock(imageMetadata);
            awbOk = getLocked(AwbStatus, imageMetadata, "awb.status", &awb);
            luxOk = getLocked(LuxStatus, imageMetadata, "lux.status", &lux);
        }

        if (!awbOk) {
            log.warning("no colour temperature found");
        }
        if (!luxOk) {
            log.warning("no lux value found");
        }

        var ccm = calculateCcm(self.config.ccms.items, awb.temperatureK);
        var saturation = self.saturation;
        var ccmStatus = CcmStatus{
            .saturation = saturation,
        };

        if (!self.config.saturation.empty()) {
            saturation *= self.config.saturation.eval(self.config.saturation.domain().clamp(lux.lux));
        }

        ccm = applySaturation(ccm, saturation);

        for (j in 0..3) {
            for (i in 0..3) {
                ccmStatus.matrix[j * 3 + i] = std.math.max(-8.0, std.math.min(7.9999, ccm[j][i]));
            }
        }

        log.debug("colour temperature {d}K", .{ awb.temperatureK });
        log.debug("CCM: {f} {f} {f}     {f} {f} {f}     {f} {f} {f}",
            .{
                ccmStatus.matrix[0], ccmStatus.matrix[1], ccmStatus.matrix[2],
                ccmStatus.matrix[3], ccmStatus.matrix[4], ccmStatus.matrix[5],
                ccmStatus.matrix[6], ccmStatus.matrix[7], ccmStatus.matrix[8],
            });

        imageMetadata.set("ccm.status", ccmStatus);
    }
};
