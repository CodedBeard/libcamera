const std = @import("std");

const FLATBUFFERS_CPP98_STL = std.builtin.os.tag == .android;

const FLATBUFFERS_TEMPLATES_ALIASES = @hasDecl(std.builtin, "cpp_alias_templates") or (@hasDecl(std.builtin, "cpp_std") and std.builtin.cpp_std >= 201103);

namespace flatbuffers {

pub fn string_back(value: []const u8) u8 {
    return value[value.len - 1];
}

pub fn vector_data(comptime T: type, vector: []T) ?*T {
    return if (vector.len == 0) null else &vector[0];
}

pub fn vector_emplace_back(comptime T: type, vector: *std.ArrayList(T), data: T) void {
    if (FLATBUFFERS_CPP98_STL) {
        vector.append(data) catch unreachable;
    } else {
        vector.append(std.mem.forward(T, data)) catch unreachable;
    }
}

pub const numeric_limits = struct {
    pub fn lowest(comptime T: type) T {
        return switch (T) {
            f32 => -std.math.max(f32),
            f64 => -std.math.max(f64),
            u64 => 0,
            i64 => @intCast(i64, 1 << (@sizeOf(i64) * 8 - 1)),
            else => std.math.min(T),
        };
    }
};

pub const is_scalar = struct {
    pub fn check(comptime T: type) bool {
        return @typeInfo(T) == .Int or @typeInfo(T) == .Float or @typeInfo(T) == .Bool;
    }
};

pub const is_same = struct {
    pub fn check(comptime T: type, comptime U: type) bool {
        return @TypeOf(T) == @TypeOf(U);
    }
};

pub const is_floating_point = struct {
    pub fn check(comptime T: type) bool {
        return @typeInfo(T) == .Float;
    }
};

pub const is_unsigned = struct {
    pub fn check(comptime T: type) bool {
        return @typeInfo(T) == .Int and @typeInfo(T).Int.signedness == .Unsigned;
    }
};

pub const make_unsigned = struct {
    pub fn type(comptime T: type) type {
        return switch (T) {
            i8 => u8,
            i16 => u16,
            i32 => u32,
            i64 => u64,
            else => T,
        };
    }
};

pub const unique_ptr = struct {
    const T = type;
    var ptr: ?*T = null;

    pub fn init(p: ?*T) unique_ptr {
        return unique_ptr{ .ptr = p };
    }

    pub fn deinit(self: *unique_ptr) void {
        if (self.ptr) |p| {
            std.heap.page_allocator.free(p);
        }
    }

    pub fn release(self: *unique_ptr) ?*T {
        const p = self.ptr;
        self.ptr = null;
        return p;
    }

    pub fn reset(self: *unique_ptr, p: ?*T) void {
        if (self.ptr) |old_p| {
            std.heap.page_allocator.free(old_p);
        }
        self.ptr = p;
    }

    pub fn get(self: *unique_ptr) ?*T {
        return self.ptr;
    }

    pub fn operator_bool(self: *unique_ptr) bool {
        return self.ptr != null;
    }
};

} // namespace flatbuffers
