const std = @import("std");
const log = @import("log");
const yaml = @import("yaml");

pub const Vector = struct {
    pub const T = type;
    pub const Rows = comptime_int;

    data: [Rows]T,

    pub fn init(scalar: T) Vector {
        var vec: Vector = undefined;
        for (vec.data) |*elem| {
            elem.* = scalar;
        }
        return vec;
    }

    pub fn initFromArray(data: [Rows]T) Vector {
        var vec: Vector = undefined;
        vec.data = data;
        return vec;
    }

    pub fn index(self: Vector, i: usize) T {
        assert(i < Rows);
        return self.data[i];
    }

    pub fn indexMut(self: *Vector, i: usize) *T {
        assert(i < Rows);
        return &self.data[i];
    }

    pub fn neg(self: Vector) Vector {
        var ret: Vector = undefined;
        for (self.data) |elem, i| {
            ret.data[i] = -elem;
        }
        return ret;
    }

    pub fn add(self: Vector, other: Vector) Vector {
        return self.apply(other, std.math.add);
    }

    pub fn addScalar(self: Vector, scalar: T) Vector {
        return self.applyScalar(scalar, std.math.add);
    }

    pub fn sub(self: Vector, other: Vector) Vector {
        return self.apply(other, std.math.sub);
    }

    pub fn subScalar(self: Vector, scalar: T) Vector {
        return self.applyScalar(scalar, std.math.sub);
    }

    pub fn mul(self: Vector, other: Vector) Vector {
        return self.apply(other, std.math.mul);
    }

    pub fn mulScalar(self: Vector, scalar: T) Vector {
        return self.applyScalar(scalar, std.math.mul);
    }

    pub fn div(self: Vector, other: Vector) Vector {
        return self.apply(other, std.math.div);
    }

    pub fn divScalar(self: Vector, scalar: T) Vector {
        return self.applyScalar(scalar, std.math.div);
    }

    pub fn addAssign(self: *Vector, other: Vector) void {
        self.applyAssign(other, std.math.add);
    }

    pub fn addAssignScalar(self: *Vector, scalar: T) void {
        self.applyAssignScalar(scalar, std.math.add);
    }

    pub fn subAssign(self: *Vector, other: Vector) void {
        self.applyAssign(other, std.math.sub);
    }

    pub fn subAssignScalar(self: *Vector, scalar: T) void {
        self.applyAssignScalar(scalar, std.math.sub);
    }

    pub fn mulAssign(self: *Vector, other: Vector) void {
        self.applyAssign(other, std.math.mul);
    }

    pub fn mulAssignScalar(self: *Vector, scalar: T) void {
        self.applyAssignScalar(scalar, std.math.mul);
    }

    pub fn divAssign(self: *Vector, other: Vector) void {
        self.applyAssign(other, std.math.div);
    }

    pub fn divAssignScalar(self: *Vector, scalar: T) void {
        self.applyAssignScalar(scalar, std.math.div);
    }

    pub fn min(self: Vector, other: Vector) Vector {
        return self.apply(other, std.math.min);
    }

    pub fn minScalar(self: Vector, scalar: T) Vector {
        return self.applyScalar(scalar, std.math.min);
    }

    pub fn max(self: Vector, other: Vector) Vector {
        return self.apply(other, std.math.max);
    }

    pub fn maxScalar(self: Vector, scalar: T) Vector {
        return self.applyScalar(scalar, std.math.max);
    }

    pub fn dot(self: Vector, other: Vector) T {
        var ret: T = 0;
        for (self.data) |elem, i| {
            ret += elem * other.data[i];
        }
        return ret;
    }

    pub fn x(self: Vector) T {
        return self.data[0];
    }

    pub fn y(self: Vector) T {
        return self.data[1];
    }

    pub fn z(self: Vector) T {
        return self.data[2];
    }

    pub fn r(self: Vector) T {
        return self.data[0];
    }

    pub fn g(self: Vector) T {
        return self.data[1];
    }

    pub fn b(self: Vector) T {
        return self.data[2];
    }

    pub fn length2(self: Vector) f64 {
        var ret: f64 = 0;
        for (self.data) |elem| {
            ret += @intToFloat(f64, elem) * @intToFloat(f64, elem);
        }
        return ret;
    }

    pub fn length(self: Vector) f64 {
        return std.math.sqrt(self.length2());
    }

    pub fn sum(self: Vector) T {
        var ret: T = 0;
        for (self.data) |elem| {
            ret += elem;
        }
        return ret;
    }

    fn apply(self: Vector, other: Vector, op: fn(T, T) T) Vector {
        var result: Vector = undefined;
        for (self.data) |elem, i| {
            result.data[i] = op(elem, other.data[i]);
        }
        return result;
    }

    fn applyScalar(self: Vector, scalar: T, op: fn(T, T) T) Vector {
        var result: Vector = undefined;
        for (self.data) |elem, i| {
            result.data[i] = op(elem, scalar);
        }
        return result;
    }

    fn applyAssign(self: *Vector, other: Vector, op: fn(T, T) T) void {
        for (self.data) |*elem, i| {
            elem.* = op(elem.*, other.data[i]);
        }
    }

    fn applyAssignScalar(self: *Vector, scalar: T, op: fn(T, T) T) void {
        for (self.data) |*elem| {
            elem.* = op(elem.*, scalar);
        }
    }
};

pub fn vectorValidateYaml(obj: yaml.YamlObject, size: u32) bool {
    if (!obj.isList()) {
        return false;
    }

    if (obj.size() != size) {
        log.error("Wrong number of values in YAML vector: expected {d}, got {d}", .{size, obj.size()});
        return false;
    }

    return true;
}

pub fn vectorFromYaml(obj: yaml.YamlObject, size: u32) ?Vector {
    if (!vectorValidateYaml(obj, size)) {
        return null;
    }

    var vector: Vector = undefined;
    var i: u32 = 0;
    for (obj.asList()) |entry| {
        const value = entry.get(T);
        if (value == null) {
            return null;
        }
        vector.data[i] = value.*;
        i += 1;
    }

    return vector;
}
