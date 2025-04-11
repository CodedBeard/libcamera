const std = @import("std");

pub const Metadata = struct {
    data: std.StringHashMap(std.anytype),

    pub fn init() Metadata {
        return Metadata{
            .data = std.StringHashMap(std.anytype).init(std.heap.page_allocator),
        };
    }

    pub fn set(self: *Metadata, tag: []const u8, value: anytype) void {
        self.data.put(tag, value) catch {};
    }

    pub fn get(self: *const Metadata, tag: []const u8, value: *anytype) i32 {
        const it = self.data.get(tag);
        if (it == null) return -1;
        value.* = it.*;
        return 0;
    }

    pub fn clear(self: *Metadata) void {
        self.data.clear();
    }

    pub fn assign(self: *Metadata, other: Metadata) void {
        self.data = other.data;
    }

    pub fn merge(self: *Metadata, other: *Metadata) void {
        for (it in other.data) |entry| {
            self.data.put(entry.key, entry.value) catch {};
        }
    }

    pub fn mergeCopy(self: *Metadata, other: *const Metadata) void {
        for (it in other.data) |entry| {
            if (!self.data.contains(entry.key)) {
                self.data.put(entry.key, entry.value) catch {};
            }
        }
    }

    pub fn erase(self: *Metadata, tag: []const u8) void {
        self.data.remove(tag);
    }

    pub fn getLocked(self: *Metadata, tag: []const u8) ?*anytype {
        return self.data.get(tag);
    }

    pub fn setLocked(self: *Metadata, tag: []const u8, value: anytype) void {
        self.data.put(tag, value) catch {};
    }

    pub fn eraseLocked(self: *Metadata, tag: []const u8) void {
        self.data.remove(tag);
    }
};
