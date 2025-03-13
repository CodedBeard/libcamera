const std = @import("std");
const log = @import("log");
const yaml = @import("yaml");

const LscPolynomial = struct {
    cx: f64,
    cy: f64,
    cnx: f64,
    cny: f64,
    coefficients: [5]f64,
    imageSize: Size,

    pub fn init(cx: f64, cy: f64, k0: f64, k1: f64, k2: f64, k3: f64, k4: f64) LscPolynomial {
        return LscPolynomial{
            .cx = cx,
            .cy = cy,
            .cnx = 0,
            .cny = 0,
            .coefficients = [5]f64{k0, k1, k2, k3, k4},
            .imageSize = Size{},
        };
    }

    pub fn sampleAtNormalizedPixelPos(self: *const LscPolynomial, x: f64, y: f64) f64 {
        const dx = x - self.cnx;
        const dy = y - self.cny;
        const r = std.math.sqrt(dx * dx + dy * dy);
        var res = 1.0;
        for (var i = 0; i < self.coefficients.len; i += 1) {
            res += self.coefficients[i] * std.math.pow(r, (i + 1) * 2);
        }
        return res;
    }

    pub fn getM(self: *const LscPolynomial) f64 {
        const cpx = self.imageSize.width * self.cx;
        const cpy = self.imageSize.height * self.cy;
        const mx = std.math.max(cpx, std.math.abs(self.imageSize.width - cpx));
        const my = std.math.max(cpy, std.math.abs(self.imageSize.height - cpy));

        return std.math.sqrt(mx * mx + my * my);
    }

    pub fn setReferenceImageSize(self: *LscPolynomial, size: Size) void {
        assert(!size.isNull());
        self.imageSize = size;

        const m = self.getM();
        self.cnx = (size.width * self.cx) / m;
        self.cny = (size.height * self.cy) / m;
    }
};

pub fn getLscPolynomialFromYaml(obj: yaml.YamlObject) !LscPolynomial {
    const cx = obj.get("cx").getOptional(f64).?;
    const cy = obj.get("cy").getOptional(f64).?;
    const k0 = obj.get("k0").getOptional(f64).?;
    const k1 = obj.get("k1").getOptional(f64).?;
    const k2 = obj.get("k2").getOptional(f64).?;
    const k3 = obj.get("k3").getOptional(f64).?;
    const k4 = obj.get("k4").getOptional(f64).?;

    if (cx == null or cy == null or k0 == null or k1 == null or k2 == null or k3 == null or k4 == null) {
        log.error("Polynomial is missing a parameter");
        return error.MissingParameter;
    }

    return LscPolynomial.init(cx.?, cy.?, k0.?, k1.?, k2.?, k3.?, k4.?);
}
