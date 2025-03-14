const std = @import("std");
const flatbuffers = @import("flatbuffers");

const Registry = struct {
    schemas: std.StringHashMap(Schema),
    lasterror: []const u8,
    opts: flatbuffers.IDLOptions,
    include_paths: std.ArrayList([]const u8),

    pub fn init(allocator: *std.mem.Allocator) Registry {
        return Registry{
            .schemas = std.StringHashMap(Schema).init(allocator),
            .lasterror = "",
            .opts = flatbuffers.IDLOptions{},
            .include_paths = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn register(self: *Registry, file_identifier: []const u8, schema_path: []const u8) void {
        var schema = Schema{ .path = schema_path };
        self.schemas.put(file_identifier, schema) catch unreachable;
    }

    pub fn flatBufferToText(self: *Registry, flatbuf: []const u8, dest: *std.ArrayList(u8)) bool {
        if (flatbuf.len < @sizeOf(flatbuffers.uoffset_t) + flatbuffers.FlatBufferBuilder.kFileIdentifierLength) {
            self.lasterror = "buffer truncated";
            return false;
        }
        var ident = flatbuf[@sizeOf(flatbuffers.uoffset_t)..][0..flatbuffers.FlatBufferBuilder.kFileIdentifierLength];
        var parser = flatbuffers.Parser{};
        if (!self.loadSchema(ident, &parser)) return false;
        if (!flatbuffers.generateText(parser, flatbuf, dest)) {
            self.lasterror = "unable to generate text for FlatBuffer binary";
            return false;
        }
        return true;
    }

    pub fn textToFlatBuffer(self: *Registry, text: []const u8, file_identifier: []const u8) flatbuffers.DetachedBuffer {
        var parser = flatbuffers.Parser{};
        if (!self.loadSchema(file_identifier, &parser)) return flatbuffers.DetachedBuffer{};
        if (!parser.parse(text)) {
            self.lasterror = parser.error;
            return flatbuffers.DetachedBuffer{};
        }
        return parser.builder.release();
    }

    pub fn setOptions(self: *Registry, opts: flatbuffers.IDLOptions) void {
        self.opts = opts;
    }

    pub fn addIncludeDirectory(self: *Registry, path: []const u8) void {
        self.include_paths.append(path) catch unreachable;
    }

    pub fn getLastError(self: *Registry) []const u8 {
        return self.lasterror;
    }

    fn loadSchema(self: *Registry, ident: []const u8, parser: *flatbuffers.Parser) bool {
        var it = self.schemas.get(ident);
        if (it == null) {
            self.lasterror = "identifier for this buffer not in the registry";
            return false;
        }
        var schema = it.*;
        var schematext = try std.fs.readFileAlloc(std.heap.page_allocator, schema.path, std.math.maxInt(usize));
        defer std.heap.page_allocator.free(schematext);
        parser.opts = self.opts;
        if (!parser.parse(schematext, self.include_paths.items, schema.path)) {
            self.lasterror = parser.error;
            return false;
        }
        return true;
    }

    const Schema = struct {
        path: []const u8,
    };
};
