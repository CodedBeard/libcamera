const std = @import("std");

const ElementaryType = enum {
    UTYPE,
    BOOL,
    CHAR,
    UCHAR,
    SHORT,
    USHORT,
    INT,
    UINT,
    LONG,
    ULONG,
    FLOAT,
    DOUBLE,
    STRING,
    SEQUENCE,
};

const TypeTable = struct {
    st: SequenceType,
    num_elems: usize,
    values: []const i64,
    names: []const []const u8,
    type_codes: []const TypeCode,
    type_refs: []const fn() TypeTable,
};

const SequenceType = enum {
    TABLE,
    UNION,
    STRUCT,
    ENUM,
};

const TypeCode = struct {
    base_type: ElementaryType,
    is_vector: bool,
    sequence_ref: i32,
};

const String = struct {
    c_str: []const u8,
    size: usize,
};

const IterationVisitor = struct {
    pub fn startSequence(self: *IterationVisitor) void {}
    pub fn endSequence(self: *IterationVisitor) void {}
    pub fn field(self: *IterationVisitor, field_idx: usize, set_idx: usize, type: ElementaryType, is_vector: bool, type_table: ?*TypeTable, name: ?[]const u8, val: ?*const u8) void {}
    pub fn uType(self: *IterationVisitor, value: u8, name: ?[]const u8) void {}
    pub fn bool(self: *IterationVisitor, value: bool) void {}
    pub fn char(self: *IterationVisitor, value: i8, name: ?[]const u8) void {}
    pub fn uChar(self: *IterationVisitor, value: u8, name: ?[]const u8) void {}
    pub fn short(self: *IterationVisitor, value: i16, name: ?[]const u8) void {}
    pub fn uShort(self: *IterationVisitor, value: u16, name: ?[]const u8) void {}
    pub fn int(self: *IterationVisitor, value: i32, name: ?[]const u8) void {}
    pub fn uInt(self: *IterationVisitor, value: u32, name: ?[]const u8) void {}
    pub fn long(self: *IterationVisitor, value: i64) void {}
    pub fn uLong(self: *IterationVisitor, value: u64) void {}
    pub fn float(self: *IterationVisitor, value: f32) void {}
    pub fn double(self: *IterationVisitor, value: f64) void {}
    pub fn string(self: *IterationVisitor, value: *const String) void {}
    pub fn unknown(self: *IterationVisitor, value: *const u8) void {}
    pub fn startVector(self: *IterationVisitor) void {}
    pub fn endVector(self: *IterationVisitor) void {}
    pub fn element(self: *IterationVisitor, index: usize, type: ElementaryType, type_table: ?*TypeTable, val: *const u8) void {}
};

fn inlineSize(type: ElementaryType, type_table: ?*TypeTable) usize {
    switch (type) {
        ElementaryType.UTYPE, ElementaryType.BOOL, ElementaryType.CHAR, ElementaryType.UCHAR => return 1,
        ElementaryType.SHORT, ElementaryType.USHORT => return 2,
        ElementaryType.INT, ElementaryType.UINT, ElementaryType.FLOAT, ElementaryType.STRING => return 4,
        ElementaryType.LONG, ElementaryType.ULONG, ElementaryType.DOUBLE => return 8,
        ElementaryType.SEQUENCE => {
            switch (type_table.?) |tt| {
                SequenceType.TABLE, SequenceType.UNION => return 4,
                SequenceType.STRUCT => return @intCast(usize, tt.values[tt.num_elems]),
                else => return 1,
            }
        },
        else => return 1,
    }
}

fn lookupEnum(enum_val: i64, values: []const i64) i64 {
    for (values) |value, i| {
        if (enum_val == value) return @intCast(i64, i);
    }
    return enum_val;
}

fn enumName(T: type, tval: T, type_table: ?*TypeTable) ?[]const u8 {
    if (type_table == null or type_table.names == null) return null;
    const i = lookupEnum(@intCast(i64, tval), type_table.values);
    if (i >= 0 and i < @intCast(i64, type_table.num_elems)) {
        return type_table.names[@intCast(usize, i)];
    }
    return null;
}

fn iterateObject(obj: *const u8, type_table: *const TypeTable, visitor: *IterationVisitor) void {
    visitor.startSequence();
    var prev_val: ?*const u8 = null;
    var set_idx: usize = 0;
    for (type_table.num_elems) |i| {
        const type_code = type_table.type_codes[i];
        const type = type_code.base_type;
        const is_vector = type_code.is_vector;
        const ref_idx = type_code.sequence_ref;
        const ref = if (ref_idx >= 0) type_table.type_refs[ref_idx]() else null;
        const name = if (type_table.names != null) type_table.names[i] else null;
        const val = if (type_table.st == SequenceType.TABLE) {
            @intToPtr(*const u8, @ptrToInt(obj) + @intCast(usize, i) * @sizeOf(u8))
        } else {
            obj + type_table.values[i]
        };
        visitor.field(i, set_idx, type, is_vector, ref, name, val);
        if (val != null) {
            set_idx += 1;
            if (is_vector) {
                val += @intCast(usize, @intFromPtr(*const u8, val));
                const vec = @intToPtr(*const Vector(u8), val);
                visitor.startVector();
                var elem_ptr = vec.data();
                for (vec.size()) |j| {
                    visitor.element(j, type, ref, elem_ptr);
                    iterateValue(type, elem_ptr, ref, prev_val, @intCast(soffset_t, j), visitor);
                    elem_ptr += inlineSize(type, ref);
                }
                visitor.endVector();
            } else {
                iterateValue(type, val, ref, prev_val, -1, visitor);
            }
        }
        prev_val = val;
    }
    visitor.endSequence();
}

fn iterateValue(type: ElementaryType, val: *const u8, type_table: ?*TypeTable, prev_val: ?*const u8, vector_index: soffset_t, visitor: *IterationVisitor) void {
    switch (type) {
        ElementaryType.UTYPE => {
            const tval = @intFromPtr(u8, val);
            visitor.uType(tval, enumName(u8, tval, type_table));
        },
        ElementaryType.BOOL => {
            visitor.bool(@intFromPtr(u8, val) != 0);
        },
        ElementaryType.CHAR => {
            const tval = @intFromPtr(i8, val);
            visitor.char(tval, enumName(i8, tval, type_table));
        },
        ElementaryType.UCHAR => {
            const tval = @intFromPtr(u8, val);
            visitor.uChar(tval, enumName(u8, tval, type_table));
        },
        ElementaryType.SHORT => {
            const tval = @intFromPtr(i16, val);
            visitor.short(tval, enumName(i16, tval, type_table));
        },
        ElementaryType.USHORT => {
            const tval = @intFromPtr(u16, val);
            visitor.uShort(tval, enumName(u16, tval, type_table));
        },
        ElementaryType.INT => {
            const tval = @intFromPtr(i32, val);
            visitor.int(tval, enumName(i32, tval, type_table));
        },
        ElementaryType.UINT => {
            const tval = @intFromPtr(u32, val);
            visitor.uInt(tval, enumName(u32, tval, type_table));
        },
        ElementaryType.LONG => {
            visitor.long(@intFromPtr(i64, val));
        },
        ElementaryType.ULONG => {
            visitor.uLong(@intFromPtr(u64, val));
        },
        ElementaryType.FLOAT => {
            visitor.float(@intFromPtr(f32, val));
        },
        ElementaryType.DOUBLE => {
            visitor.double(@intFromPtr(f64, val));
        },
        ElementaryType.STRING => {
            val += @intCast(usize, @intFromPtr(uoffset_t, val));
            visitor.string(@intToPtr(*const String, val));
        },
        ElementaryType.SEQUENCE => {
            switch (type_table.?) |tt| {
                SequenceType.TABLE => {
                    val += @intCast(usize, @intFromPtr(uoffset_t, val));
                    iterateObject(val, tt, visitor);
                },
                SequenceType.STRUCT => {
                    iterateObject(val, tt, visitor);
                },
                SequenceType.UNION => {
                    val += @intCast(usize, @intFromPtr(uoffset_t, val));
                    const union_type = if (vector_index >= 0) {
                        const type_vec = @intToPtr(*const Vector(u8), prev_val);
                        type_vec.get(@intCast(uoffset_t, vector_index))
                    } else {
                        @intFromPtr(u8, prev_val)
                    };
                    const type_code_idx = lookupEnum(@intCast(i64, union_type), tt.values);
                    if (type_code_idx >= 0 and type_code_idx < @intCast(i32, tt.num_elems)) {
                        const type_code = tt.type_codes[@intCast(usize, type_code_idx)];
                        switch (type_code.base_type) {
                            ElementaryType.SEQUENCE => {
                                const ref = tt.type_refs[type_code.sequence_ref]();
                                iterateObject(val, ref, visitor);
                            },
                            ElementaryType.STRING => {
                                visitor.string(@intToPtr(*const String, val));
                            },
                            else => {
                                visitor.unknown(val);
                            },
                        }
                    } else {
                        visitor.unknown(val);
                    }
                },
                else => {
                    visitor.unknown(val);
                },
            }
        },
        else => {
            visitor.unknown(val);
        },
    }
}

fn iterateFlatBuffer(buffer: *const u8, type_table: *const TypeTable, callback: *IterationVisitor) void {
    iterateObject(@intToPtr(*const u8, @intFromPtr(*const u8, buffer)), type_table, callback);
}

const ToStringVisitor = struct {
    s: []u8,
    d: []const u8,
    q: bool,
    in: []const u8,
    indent_level: usize,
    vector_delimited: bool,

    pub fn init(delimiter: []const u8, quotes: bool, indent: []const u8, vdelimited: bool) ToStringVisitor {
        return ToStringVisitor{
            .s = undefined,
            .d = delimiter,
            .q = quotes,
            .in = indent,
            .indent_level = 0,
            .vector_delimited = vdelimited,
        };
    }

    pub fn initSimple(delimiter: []const u8) ToStringVisitor {
        return ToStringVisitor{
            .s = undefined,
            .d = delimiter,
            .q = false,
            .in = "",
            .indent_level = 0,
            .vector_delimited = true,
        };
    }

    fn appendIndent(self: *ToStringVisitor) void {
        for (self.indent_level) |i| {
            self.s.append(self.in);
        }
    }

    pub fn startSequence(self: *ToStringVisitor) void {
        self.s.append("{");
        self.s.append(self.d);
        self.indent_level += 1;
    }

    pub fn endSequence(self: *ToStringVisitor) void {
        self.s.append(self.d);
        self.indent_level -= 1;
        self.appendIndent();
        self.s.append("}");
    }

    pub fn field(self: *ToStringVisitor, field_idx: usize, set_idx: usize, type: ElementaryType, is_vector: bool, type_table: ?*TypeTable, name: ?[]const u8, val: ?*const u8) void {
        if (val == null) return;
        if (set_idx != 0) {
            self.s.append(",");
            self.s.append(self.d);
        }
        self.appendIndent();
        if (name != null) {
            if (self.q) self.s.append("\"");
            self.s.append(name);
            if (self.q) self.s.append("\"");
            self.s.append(": ");
        }
    }

    pub fn named(T: type, value: T, name: ?[]const u8) void {
        if (name != null) {
            if (self.q) self.s.append("\"");
            self.s.append(name);
            if (self.q) self.s.append("\"");
        } else {
            self.s.append(std.fmt.format("{d}", .{value}));
        }
    }

    pub fn uType(self: *ToStringVisitor, value: u8, name: ?[]const u8) void {
        self.named(u8, value, name);
    }

    pub fn bool(self: *ToStringVisitor, value: bool) void {
        self.s.append(if (value) "true" else "false");
    }

    pub fn char(self: *ToStringVisitor, value: i8, name: ?[]const u8) void {
        self.named(i8, value, name);
    }

    pub fn uChar(self: *ToStringVisitor, value: u8, name: ?[]const u8) void {
        self.named(u8, value, name);
    }

    pub fn short(self: *ToStringVisitor, value: i16, name: ?[]const u8) void {
        self.named(i16, value, name);
    }

    pub fn uShort(self: *ToStringVisitor, value: u16, name: ?[]const u8) void {
        self.named(u16, value, name);
    }

    pub fn int(self: *ToStringVisitor, value: i32, name: ?[]const u8) void {
        self.named(i32, value, name);
    }

    pub fn uInt(self: *ToStringVisitor, value: u32, name: ?[]const u8) void {
        self.named(u32, value, name);
    }

    pub fn long(self: *ToStringVisitor, value: i64) void {
        self.s.append(std.fmt.format("{d}", .{value}));
    }

    pub fn uLong(self: *ToStringVisitor, value: u64) void {
        self.s.append(std.fmt.format("{d}", .{value}));
    }

    pub fn float(self: *ToStringVisitor, value: f32) void {
        self.s.append(std.fmt.format("{f}", .{value}));
    }

    pub fn double(self: *ToStringVisitor, value: f64) void {
        self.s.append(std.fmt.format("{f}", .{value}));
    }

    pub fn string(self: *ToStringVisitor, value: *const String) void {
        self.s.append(std.fmt.format("{s}", .{value.c_str}));
    }

    pub fn unknown(self: *ToStringVisitor, value: *const u8) void {
        self.s.append("(?)");
    }

    pub fn startVector(self: *ToStringVisitor) void {
        self.s.append("[");
        if (self.vector_delimited) {
            self.s.append(self.d);
            self.indent_level += 1;
            self.appendIndent();
        } else {
            self.s.append(" ");
        }
    }

    pub fn endVector(self: *ToStringVisitor) void {
        if (self.vector_delimited) {
            self.s.append(self.d);
            self.indent_level -= 1;
            self.appendIndent();
        } else {
            self.s.append(" ");
        }
        self.s.append("]");
    }

    pub fn element(self: *ToStringVisitor, index: usize, type: ElementaryType, type_table: ?*TypeTable, val: *const u8) void {
        if (index != 0) {
            self.s.append(",");
            if (self.vector_delimited) {
                self.s.append(self.d);
                self.appendIndent();
            } else {
                self.s.append(" ");
            }
        }
    }
};

fn flatBufferToString(buffer: *const u8, type_table: *const TypeTable, multi_line: bool, vector_delimited: bool) []u8 {
    var tostring_visitor = ToStringVisitor.init(if (multi_line) "\n" else " ", false, "", vector_delimited);
    iterateFlatBuffer(buffer, type_table, &tostring_visitor);
    return tostring_visitor.s;
}
