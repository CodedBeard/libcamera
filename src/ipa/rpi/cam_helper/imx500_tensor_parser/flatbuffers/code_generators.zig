const std = @import("std");

const CodeWriter = struct {
    value_map: std.StringHashMap([]const u8),
    stream: std.io.fixed_buffer_stream.Writer,

    pub fn init() CodeWriter {
        return CodeWriter{
            .value_map = std.StringHashMap([]const u8).init(std.heap.page_allocator),
            .stream = std.io.fixed_buffer_stream.Writer.init(std.heap.page_allocator),
        };
    }

    pub fn clear(self: *CodeWriter) void {
        self.stream.clear();
    }

    pub fn setValue(self: *CodeWriter, key: []const u8, value: []const u8) void {
        self.value_map.put(key, value) catch unreachable;
    }

    pub fn append(self: *CodeWriter, text: []const u8) void {
        var start = 0;
        while (true) {
            var open = std.mem.indexOf(u8, text[start..], '{');
            if (open == null) break;
            var close = std.mem.indexOf(u8, text[open + 1..], '}');
            if (close == null) break;

            self.stream.writeAll(text[start..open]) catch unreachable;
            var key = text[open + 1..close];
            var value = self.value_map.get(key);
            if (value != null) {
                self.stream.writeAll(value) catch unreachable;
            } else {
                self.stream.writeAll(text[open..close + 1]) catch unreachable;
            }
            start = close + 1;
        }
        self.stream.writeAll(text[start..]) catch unreachable;
        self.stream.writeAll("\n") catch unreachable;
    }

    pub fn toString(self: *CodeWriter) []const u8 {
        return self.stream.toSlice();
    }
};

const BaseGenerator = struct {
    parser: *const anyopaque,
    path: []const u8,
    file_name: []const u8,
    qualifying_start: []const u8,
    qualifying_separator: []const u8,

    pub fn init(parser: *const anyopaque, path: []const u8, file_name: []const u8, qualifying_start: []const u8, qualifying_separator: []const u8) BaseGenerator {
        return BaseGenerator{
            .parser = parser,
            .path = path,
            .file_name = file_name,
            .qualifying_start = qualifying_start,
            .qualifying_separator = qualifying_separator,
        };
    }

    pub fn namespaceDir(self: *BaseGenerator, ns: *const anyopaque) []const u8 {
        return NamespaceDir(self.parser.*, self.path, ns);
    }

    pub fn flatBuffersGeneratedWarning() []const u8 {
        return "This file was generated by the FlatBuffers compiler.";
    }

    pub fn fullNamespace(separator: []const u8, ns: *const anyopaque) []const u8 {
        var result = std.heap.page_allocator.alloc(u8, 0) catch unreachable;
        for (var i = 0; i < ns.size; i += 1) {
            if (i != 0) {
                result = std.mem.concat(u8, result, separator) catch unreachable;
            }
            result = std.mem.concat(u8, result, ns[i]) catch unreachable;
        }
        return result;
    }

    pub fn lastNamespacePart(ns: *const anyopaque) []const u8 {
        return ns[ns.size - 1];
    }

    pub fn wrapInNameSpace(self: *BaseGenerator, ns: *const anyopaque, name: []const u8) []const u8 {
        if (ns == self.currentNameSpace()) {
            return name;
        }
        return std.mem.concat(u8, self.fullNamespace(self.qualifying_separator, ns), name) catch unreachable;
    }

    pub fn wrapInNameSpaceDef(self: *BaseGenerator, def: *const anyopaque) []const u8 {
        return self.wrapInNameSpace(def.namespace, def.name);
    }

    pub fn getNameSpace(self: *BaseGenerator, def: *const anyopaque) []const u8 {
        return self.fullNamespace(self.qualifying_separator, def.namespace);
    }

    pub fn currentNameSpace(self: *BaseGenerator) *const anyopaque {
        return null;
    }
};

const CommentConfig = struct {
    first_line: []const u8,
    content_line_prefix: []const u8,
    last_line: []const u8,
};

pub fn genComment(dc: []const []const u8, code_ptr: *[]u8, config: *const CommentConfig, prefix: []const u8) void {
    if (dc.len == 0) return;
    var code = *code_ptr;
    code = std.mem.concat(u8, code, config.first_line) catch unreachable;
    for (var i = 0; i < dc.len; i += 1) {
        code = std.mem.concat(u8, code, config.content_line_prefix) catch unreachable;
        code = std.mem.concat(u8, code, dc[i]) catch unreachable;
    }
    code = std.mem.concat(u8, code, config.last_line) catch unreachable;
    *code_ptr = code;
}

const FloatConstantGenerator = struct {
    pub fn genFloatConstant(self: *const FloatConstantGenerator, field: *const anyopaque) []const u8 {
        if (field.value.type.base_type == 8) {
            return self.value(field.value.constant, field.value.constant);
        } else if (field.value.type.base_type == 9) {
            return self.value(field.value.constant, field.value.constant);
        }
        return "";
    }

    fn value(self: *const FloatConstantGenerator, v: []const u8, src: []const u8) []const u8 {
        return "";
    }

    fn inf(self: *const FloatConstantGenerator, v: []const u8) []const u8 {
        return "";
    }

    fn nan(self: *const FloatConstantGenerator, v: []const u8) []const u8 {
        return "";
    }
};

const SimpleFloatConstantGenerator = struct {
    base: FloatConstantGenerator,
    nan_number: []const u8,
    pos_inf_number: []const u8,
    neg_inf_number: []const u8,

    pub fn init(nan_number: []const u8, pos_inf_number: []const u8, neg_inf_number: []const u8) SimpleFloatConstantGenerator {
        return SimpleFloatConstantGenerator{
            .base = FloatConstantGenerator{},
            .nan_number = nan_number,
            .pos_inf_number = pos_inf_number,
            .neg_inf_number = neg_inf_number,
        };
    }

    fn value(self: *const SimpleFloatConstantGenerator, v: []const u8, src: []const u8) []const u8 {
        return src;
    }

    fn inf(self: *const SimpleFloatConstantGenerator, v: []const u8) []const u8 {
        if (v[0] == '-') {
            return self.neg_inf_number;
        }
        return self.pos_inf_number;
    }

    fn nan(self: *const SimpleFloatConstantGenerator, v: []const u8) []const u8 {
        return self.nan_number;
    }
};

const TypedFloatConstantGenerator = struct {
    base: FloatConstantGenerator,
    double_prefix: []const u8,
    single_prefix: []const u8,
    nan_number: []const u8,
    pos_inf_number: []const u8,
    neg_inf_number: []const u8,

    pub fn init(double_prefix: []const u8, single_prefix: []const u8, nan_number: []const u8, pos_inf_number: []const u8, neg_inf_number: []const u8) TypedFloatConstantGenerator {
        return TypedFloatConstantGenerator{
            .base = FloatConstantGenerator{},
            .double_prefix = double_prefix,
            .single_prefix = single_prefix,
            .nan_number = nan_number,
            .pos_inf_number = pos_inf_number,
            .neg_inf_number = neg_inf_number,
        };
    }

    fn value(self: *const TypedFloatConstantGenerator, v: []const u8, src: []const u8) []const u8 {
        return std.mem.concat(u8, self.double_prefix, src) catch unreachable;
    }

    fn inf(self: *const TypedFloatConstantGenerator, v: []const u8) []const u8 {
        return self.makeInf(v[0] == '-', self.double_prefix);
    }

    fn nan(self: *const TypedFloatConstantGenerator, v: []const u8) []const u8 {
        return self.makeNaN(self.double_prefix);
    }

    fn makeNaN(self: *const TypedFloatConstantGenerator, prefix: []const u8) []const u8 {
        return std.mem.concat(u8, prefix, self.nan_number) catch unreachable;
    }

    fn makeInf(self: *const TypedFloatConstantGenerator, neg: bool, prefix: []const u8) []const u8 {
        if (neg) {
            return std.mem.concat(u8, prefix, self.neg_inf_number) catch unreachable;
        }
        return std.mem.concat(u8, prefix, self.pos_inf_number) catch unreachable;
    }
};
