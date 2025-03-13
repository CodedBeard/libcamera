const std = @import("std");
const log = @import("log");
const yaml = @import("yaml");

const Interpolator = struct {
    data: std.StringHashMap([]const u8),
    lastInterpolatedValue: ?[]const u8,
    lastInterpolatedKey: ?u32,
    quantization: u32,

    pub fn init() Interpolator {
        return Interpolator{
            .data = std.StringHashMap([]const u8).init(std.heap.page_allocator),
            .lastInterpolatedValue = null,
            .lastInterpolatedKey = null,
            .quantization = 0,
        };
    }

    pub fn deinit(self: *Interpolator) void {
        self.data.deinit();
    }

    pub fn readYaml(self: *Interpolator, yaml: yaml.YamlObject, key_name: []const u8, value_name: []const u8) !void {
        self.data.clear();
        self.lastInterpolatedKey = null;

        if (!yaml.isList()) {
            log.err("yaml object must be a list");
            return error.InvalidYaml;
        }

        for (yaml.asList()) |value| {
            const ct = value.get(key_name).getOptional(u32).catch(0);
            const data = value.get(value_name).getOptional([]const u8).catch(null);
            if (data == null) {
                return error.InvalidYaml;
            }

            self.data.put(ct, data);
        }

        if (self.data.size() < 1) {
            log.err("Need at least one element");
            return error.InvalidYaml;
        }
    }

    pub fn setQuantization(self: *Interpolator, q: u32) void {
        self.quantization = q;
    }

    pub fn setData(self: *Interpolator, data: std.StringHashMap([]const u8)) void {
        self.data = data;
        self.lastInterpolatedKey = null;
    }

    pub fn getInterpolated(self: *Interpolator, key: u32, quantizedKey: ?*u32) []const u8 {
        assert(self.data.size() > 0);

        if (self.quantization > 0) {
            key = @intCast(u32, std.math.round(@intToFloat(f64, key) / @intToFloat(f64, self.quantization))) * self.quantization;
        }

        if (quantizedKey) {
            quantizedKey.* = key;
        }

        if (self.lastInterpolatedKey) |lastKey| {
            if (lastKey == key) {
                return self.lastInterpolatedValue.?;
            }
        }

        var it = self.data.lowerBound(key);

        if (it == self.data.begin()) {
            return it.value;
        }

        if (it == self.data.end()) {
            return self.data.prev(it).value;
        }

        if (it.key == key) {
            return it.value;
        }

        const it2 = self.data.prev(it);
        const lambda = @intToFloat(f64, key - it2.key) / @intToFloat(f64, it.key - it2.key);
        self.interpolate(it2.value, it.value, &self.lastInterpolatedValue, lambda);
        self.lastInterpolatedKey = key;

        return self.lastInterpolatedValue;
    }

    fn interpolate(self: *Interpolator, a: []const u8, b: []const u8, dest: *?[]const u8, lambda: f64) void {
        dest.* = a[0..] ++ b[0..];
    }
};
