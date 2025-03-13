const std = @import("std");
const log = @import("log");

pub const CameraSensorHelper = struct {
    blackLevel: ?i16 = null,
    gain: Gain = .none,

    pub fn init() CameraSensorHelper {
        return CameraSensorHelper{};
    }

    pub fn gainCode(self: CameraSensorHelper, gain: f64) u32 {
        return switch (self.gain) {
            .linear => |l| {
                assert(l.m0 == 0 or l.m1 == 0);
                return @intCast(u32, (l.c0 - l.c1 * gain) / (l.m1 * gain - l.m0));
            },
            .exp => |e| {
                assert(e.a != 0 and e.m != 0);
                return @intCast(u32, std.math.log2(gain / e.a) / e.m);
            },
            else => {
                assert(false);
                return 0;
            }
        };
    }

    pub fn gain(self: CameraSensorHelper, gainCode: u32) f64 {
        const gain = @intToFloat(f64, gainCode);

        return switch (self.gain) {
            .linear => |l| {
                assert(l.m0 == 0 or l.m1 == 0);
                return (l.m0 * gain + l.c0) / (l.m1 * gain + l.c1);
            },
            .exp => |e| {
                assert(e.a != 0 and e.m != 0);
                return e.a * std.math.exp2(e.m * gain);
            },
            else => {
                assert(false);
                return 0.0;
            }
        };
    }

    pub const Gain = union(enum) {
        none: void,
        linear: AnalogueGainLinear,
        exp: AnalogueGainExp,
    };

    pub const AnalogueGainLinear = struct {
        m0: i16,
        c0: i16,
        m1: i16,
        c1: i16,
    };

    pub const AnalogueGainExp = struct {
        a: f64,
        m: f64,
    };
};

pub const CameraSensorHelperFactoryBase = struct {
    name: []const u8,

    pub fn init(name: []const u8) CameraSensorHelperFactoryBase {
        const factory = CameraSensorHelperFactoryBase{
            .name = name,
        };
        factory.registerType();
        return factory;
    }

    pub fn create(name: []const u8) ?*CameraSensorHelper {
        const factories = CameraSensorHelperFactoryBase.factories();
        var i: usize = 0;
        while (i < factories.len) : (i += 1) {
            const factory = factories[i];
            if (std.mem.eql(u8, name, factory.name)) {
                return factory.createInstance();
            }
        }
        return null;
    }

    fn registerType(self: *CameraSensorHelperFactoryBase) void {
        const factories = CameraSensorHelperFactoryBase.factories();
        factories.append(self);
    }

    fn factories() []CameraSensorHelperFactoryBase {
        return &[_]CameraSensorHelperFactoryBase{};
    }

    fn createInstance(self: *CameraSensorHelperFactoryBase) ?*CameraSensorHelper {
        return null;
    }
};

pub const CameraSensorHelperFactory = struct {
    base: CameraSensorHelperFactoryBase,

    pub fn init(name: []const u8) CameraSensorHelperFactory {
        return CameraSensorHelperFactory{
            .base = CameraSensorHelperFactoryBase.init(name),
        };
    }

    fn createInstance(self: *CameraSensorHelperFactory) ?*CameraSensorHelper {
        return null;
    }
};

pub fn REGISTER_CAMERA_SENSOR_HELPER(name: []const u8, helper: type) void {
    _ = CameraSensorHelperFactory.init(name);
}

fn expGainDb(step: f64) f64 {
    const log2_10 = 3.321928094887362;
    return log2_10 * step / 20;
}

const CameraSensorHelperAr0144 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperAr0144 {
        return CameraSensorHelperAr0144{
            .helper = CameraSensorHelper{
                .blackLevel = 2688,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 100,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 1024,
                }),
            },
        };
    }

    pub fn gainCode(self: CameraSensorHelperAr0144, gain: f64) u32 {
        gain = std.math.clamp(gain, 1.0 / (1.0 - 13.0 / 32.0), 18.45);

        if (gain > 4.0) {
            gain /= 1.153125;
        }

        const coarse = @intCast(u32, std.math.log2(gain));
        const fine = @intCast(u32, (1 - (1 << coarse) / gain) * 32);

        if (coarse == 1 or coarse == 3) {
            fine &= ~1;
        } else if (coarse == 4) {
            fine &= ~3;
        }

        return (coarse << 4) | (fine & 0xf);
    }

    pub fn gain(self: CameraSensorHelperAr0144, gainCode: u32) f64 {
        const coarse = gainCode >> 4;
        const fine = gainCode & 0xf;
        var d1: u32 = 1;
        var d2: f64 = 32.0;
        var m: f64 = 1.0;

        switch (coarse) {
            0 => {},
            1 => {
                d1 = 2;
                d2 = 16.0;
            },
            2 => {
                d1 = 1;
                d2 = 32.0;
                m = 1.153125;
            },
            3 => {
                d1 = 2;
                d2 = 16.0;
                m = 1.153125;
            },
            4 => {
                d1 = 4;
                d2 = 8.0;
                m = 1.153125;
            },
            else => {},
        }

        m += std.math.epsilon(f64);
        return m * (1 << coarse) / (1.0 - (fine / d1) / d2);
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ar0144", CameraSensorHelperAr0144);

const CameraSensorHelperAr0521 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperAr0521 {
        return CameraSensorHelperAr0521{
            .helper = CameraSensorHelper{},
        };
    }

    pub fn gainCode(self: CameraSensorHelperAr0521, gain: f64) u32 {
        gain = std.math.clamp(gain, 1.0, 15.5);
        const coarse = @intCast(u32, std.math.log2(gain));
        const fine = @intCast(u32, (gain / (1 << coarse) - 1) * 16);
        return (coarse << 4) | (fine & 0xf);
    }

    pub fn gain(self: CameraSensorHelperAr0521, gainCode: u32) f64 {
        const coarse = gainCode >> 4;
        const fine = gainCode & 0xf;
        return (1 << coarse) * (1 + fine / 16);
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ar0521", CameraSensorHelperAr0521);

const CameraSensorHelperGc05a2 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperGc05a2 {
        return CameraSensorHelperGc05a2{
            .helper = CameraSensorHelper{
                .blackLevel = 4096,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 100,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 1024,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("gc05a2", CameraSensorHelperGc05a2);

const CameraSensorHelperGc08a3 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperGc08a3 {
        return CameraSensorHelperGc08a3{
            .helper = CameraSensorHelper{
                .blackLevel = 4096,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 100,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 1024,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("gc08a3", CameraSensorHelperGc08a3);

const CameraSensorHelperImx214 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperImx214 {
        return CameraSensorHelperImx214{
            .helper = CameraSensorHelper{
                .blackLevel = 4096,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 0,
                    .c0 = 512,
                    .m1 = -1,
                    .c1 = 512,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx214", CameraSensorHelperImx214);

const CameraSensorHelperImx219 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperImx219 {
        return CameraSensorHelperImx219{
            .helper = CameraSensorHelper{
                .blackLevel = 4096,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 0,
                    .c0 = 256,
                    .m1 = -1,
                    .c1 = 256,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx219", CameraSensorHelperImx219);

const CameraSensorHelperImx258 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperImx258 {
        return CameraSensorHelperImx258{
            .helper = CameraSensorHelper{
                .blackLevel = 4096,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 0,
                    .c0 = 512,
                    .m1 = -1,
                    .c1 = 512,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx258", CameraSensorHelperImx258);

const CameraSensorHelperImx283 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperImx283 {
        return CameraSensorHelperImx283{
            .helper = CameraSensorHelper{
                .blackLevel = 3200,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 0,
                    .c0 = 2048,
                    .m1 = -1,
                    .c1 = 2048,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx283", CameraSensorHelperImx283);

const CameraSensorHelperImx290 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperImx290 {
        return CameraSensorHelperImx290{
            .helper = CameraSensorHelper{
                .blackLevel = 3840,
                .gain = CameraSensorHelper.Gain.exp(CameraSensorHelper.AnalogueGainExp{
                    .a = 1.0,
                    .m = expGainDb(0.3),
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx290", CameraSensorHelperImx290);

const CameraSensorHelperImx296 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperImx296 {
        return CameraSensorHelperImx296{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.exp(CameraSensorHelper.AnalogueGainExp{
                    .a = 1.0,
                    .m = expGainDb(0.1),
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx296", CameraSensorHelperImx296);

const CameraSensorHelperImx327 = struct {
    helper: CameraSensorHelperImx290,

    pub fn init() CameraSensorHelperImx327 {
        return CameraSensorHelperImx327{
            .helper = CameraSensorHelperImx290.init(),
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx327", CameraSensorHelperImx327);

const CameraSensorHelperImx335 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperImx335 {
        return CameraSensorHelperImx335{
            .helper = CameraSensorHelper{
                .blackLevel = 3200,
                .gain = CameraSensorHelper.Gain.exp(CameraSensorHelper.AnalogueGainExp{
                    .a = 1.0,
                    .m = expGainDb(0.3),
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx335", CameraSensorHelperImx335);

const CameraSensorHelperImx415 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperImx415 {
        return CameraSensorHelperImx415{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.exp(CameraSensorHelper.AnalogueGainExp{
                    .a = 1.0,
                    .m = expGainDb(0.3),
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx415", CameraSensorHelperImx415);

const CameraSensorHelperImx462 = struct {
    helper: CameraSensorHelperImx290,

    pub fn init() CameraSensorHelperImx462 {
        return CameraSensorHelperImx462{
            .helper = CameraSensorHelperImx290.init(),
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx462", CameraSensorHelperImx462);

const CameraSensorHelperImx477 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperImx477 {
        return CameraSensorHelperImx477{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 0,
                    .c0 = 1024,
                    .m1 = -1,
                    .c1 = 1024,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("imx477", CameraSensorHelperImx477);

const CameraSensorHelperOv2685 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv2685 {
        return CameraSensorHelperOv2685{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 128,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov2685", CameraSensorHelperOv2685);

const CameraSensorHelperOv2740 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv2740 {
        return CameraSensorHelperOv2740{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 128,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov2740", CameraSensorHelperOv2740);

const CameraSensorHelperOv4689 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv4689 {
        return CameraSensorHelperOv4689{
            .helper = CameraSensorHelper{
                .blackLevel = 1024,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 128,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov4689", CameraSensorHelperOv4689);

const CameraSensorHelperOv5640 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv5640 {
        return CameraSensorHelperOv5640{
            .helper = CameraSensorHelper{
                .blackLevel = 1024,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 16,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov5640", CameraSensorHelperOv5640);

const CameraSensorHelperOv5647 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv5647 {
        return CameraSensorHelperOv5647{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 16,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov5647", CameraSensorHelperOv5647);

const CameraSensorHelperOv5670 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv5670 {
        return CameraSensorHelperOv5670{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 128,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov5670", CameraSensorHelperOv5670);

const CameraSensorHelperOv5675 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv5675 {
        return CameraSensorHelperOv5675{
            .helper = CameraSensorHelper{
                .blackLevel = 4096,
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 128,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov5675", CameraSensorHelperOv5675);

const CameraSensorHelperOv5693 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv5693 {
        return CameraSensorHelperOv5693{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 16,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov5693", CameraSensorHelperOv5693);

const CameraSensorHelperOv64a40 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv64a40 {
        return CameraSensorHelperOv64a40{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 128,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov64a40", CameraSensorHelperOv64a40);

const CameraSensorHelperOv8858 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv8858 {
        return CameraSensorHelperOv8858{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 128,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov8858", CameraSensorHelperOv8858);

const CameraSensorHelperOv8865 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv8865 {
        return CameraSensorHelperOv8865{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 128,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov8865", CameraSensorHelperOv8865);

const CameraSensorHelperOv13858 = struct {
    helper: CameraSensorHelper,

    pub fn init() CameraSensorHelperOv13858 {
        return CameraSensorHelperOv13858{
            .helper = CameraSensorHelper{
                .gain = CameraSensorHelper.Gain.linear(CameraSensorHelper.AnalogueGainLinear{
                    .m0 = 1,
                    .c0 = 0,
                    .m1 = 0,
                    .c1 = 128,
                }),
            },
        };
    }
};

REGISTER_CAMERA_SENSOR_HELPER("ov13858", CameraSensorHelperOv13858);
