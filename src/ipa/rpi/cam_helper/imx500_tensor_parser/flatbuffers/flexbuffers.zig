const std = @import("std");

const BitWidth = enum {
    BIT_WIDTH_8 = 0,
    BIT_WIDTH_16 = 1,
    BIT_WIDTH_32 = 2,
    BIT_WIDTH_64 = 3,
};

const Type = enum {
    FBT_NULL = 0,
    FBT_INT = 1,
    FBT_UINT = 2,
    FBT_FLOAT = 3,
    FBT_KEY = 4,
    FBT_STRING = 5,
    FBT_INDIRECT_INT = 6,
    FBT_INDIRECT_UINT = 7,
    FBT_INDIRECT_FLOAT = 8,
    FBT_MAP = 9,
    FBT_VECTOR = 10,
    FBT_VECTOR_INT = 11,
    FBT_VECTOR_UINT = 12,
    FBT_VECTOR_FLOAT = 13,
    FBT_VECTOR_KEY = 14,
    FBT_VECTOR_STRING = 15,
    FBT_VECTOR_INT2 = 16,
    FBT_VECTOR_UINT2 = 17,
    FBT_VECTOR_FLOAT2 = 18,
    FBT_VECTOR_INT3 = 19,
    FBT_VECTOR_UINT3 = 20,
    FBT_VECTOR_FLOAT3 = 21,
    FBT_VECTOR_INT4 = 22,
    FBT_VECTOR_UINT4 = 23,
    FBT_VECTOR_FLOAT4 = 24,
    FBT_BLOB = 25,
    FBT_BOOL = 26,
    FBT_VECTOR_BOOL = 36,
};

fn IsInline(t: Type) bool {
    return t <= .FBT_FLOAT or t == .FBT_BOOL;
}

fn IsTypedVectorElementType(t: Type) bool {
    return (t >= .FBT_INT and t <= .FBT_STRING) or t == .FBT_BOOL;
}

fn IsTypedVector(t: Type) bool {
    return (t >= .FBT_VECTOR_INT and t <= .FBT_VECTOR_STRING) or t == .FBT_VECTOR_BOOL;
}

fn IsFixedTypedVector(t: Type) bool {
    return t >= .FBT_VECTOR_INT2 and t <= .FBT_VECTOR_FLOAT4;
}

fn ToTypedVector(t: Type, fixed_len: usize) Type {
    assert(IsTypedVectorElementType(t));
    switch (fixed_len) {
        0 => return @intToEnum(Type, @enumToInt(t) - @enumToInt(.FBT_INT) + @enumToInt(.FBT_VECTOR_INT)),
        2 => return @intToEnum(Type, @enumToInt(t) - @enumToInt(.FBT_INT) + @enumToInt(.FBT_VECTOR_INT2)),
        3 => return @intToEnum(Type, @enumToInt(t) - @enumToInt(.FBT_INT) + @enumToInt(.FBT_VECTOR_INT3)),
        4 => return @intToEnum(Type, @enumToInt(t) - @enumToInt(.FBT_INT) + @enumToInt(.FBT_VECTOR_INT4)),
        else => unreachable,
    }
}

fn ToTypedVectorElementType(t: Type) Type {
    assert(IsTypedVector(t));
    return @intToEnum(Type, @enumToInt(t) - @enumToInt(.FBT_VECTOR_INT) + @enumToInt(.FBT_INT));
}

fn ToFixedTypedVectorElementType(t: Type, len: *u8) Type {
    assert(IsFixedTypedVector(t));
    const fixed_type = @enumToInt(t) - @enumToInt(.FBT_VECTOR_INT2);
    *len = @intCast(u8, fixed_type / 3 + 2);
    return @intToEnum(Type, fixed_type % 3 + @enumToInt(.FBT_INT));
}

fn ReadSizedScalar(comptime R: type, comptime T1: type, comptime T2: type, comptime T4: type, comptime T8: type, data: []const u8, byte_width: u8) R {
    return switch (byte_width) {
        1 => @intCast(R, @bitCast(T1, data[0])),
        2 => @intCast(R, @bitCast(T2, data[0..2])),
        4 => @intCast(R, @bitCast(T4, data[0..4])),
        8 => @intCast(R, @bitCast(T8, data[0..8])),
        else => unreachable,
    };
}

fn ReadInt64(data: []const u8, byte_width: u8) i64 {
    return ReadSizedScalar(i64, i8, i16, i32, i64, data, byte_width);
}

fn ReadUInt64(data: []const u8, byte_width: u8) u64 {
    return ReadSizedScalar(u64, u8, u16, u32, u64, data, byte_width);
}

fn ReadDouble(data: []const u8, byte_width: u8) f64 {
    return ReadSizedScalar(f64, i8, i16, f32, f64, data, byte_width);
}

fn Indirect(offset: []const u8, byte_width: u8) []const u8 {
    return offset - ReadUInt64(offset, byte_width);
}

fn WidthU(u: u64) BitWidth {
    if (u & ~((1 << 8) - 1) == 0) return .BIT_WIDTH_8;
    if (u & ~((1 << 16) - 1) == 0) return .BIT_WIDTH_16;
    if (u & ~((1 << 32) - 1) == 0) return .BIT_WIDTH_32;
    return .BIT_WIDTH_64;
}

fn WidthI(i: i64) BitWidth {
    const u = @intCast(u64, i) << 1;
    return WidthU(if (i >= 0) u else ~u);
}

fn WidthF(f: f64) BitWidth {
    return if (@floatCast(f32, f) == f) .BIT_WIDTH_32 else .BIT_WIDTH_64;
}

const Object = struct {
    data: []const u8,
    byte_width: u8,

    pub fn new(data: []const u8, byte_width: u8) Object {
        return Object{ .data = data, .byte_width = byte_width };
    }
};

const Sized = struct {
    base: Object,

    pub fn new(data: []const u8, byte_width: u8) Sized {
        return Sized{ .base = Object.new(data, byte_width) };
    }

    pub fn size(self: *const Sized) usize {
        return @intCast(usize, ReadUInt64(self.base.data - self.base.byte_width, self.base.byte_width));
    }
};

const String = struct {
    base: Sized,

    pub fn new(data: []const u8, byte_width: u8) String {
        return String{ .base = Sized.new(data, byte_width) };
    }

    pub fn length(self: *const String) usize {
        return self.base.size();
    }

    pub fn c_str(self: *const String) []const u8 {
        return self.base.data;
    }

    pub fn str(self: *const String) []const u8 {
        return self.c_str()[0..self.length()];
    }

    pub fn EmptyString() String {
        const empty_string = [_]u8{ 0, 0 };
        return String.new(empty_string[1..], 1);
    }

    pub fn IsTheEmptyString(self: *const String) bool {
        return self.base.data == String.EmptyString().base.data;
    }
};

const Blob = struct {
    base: Sized,

    pub fn new(data: []const u8, byte_width: u8) Blob {
        return Blob{ .base = Sized.new(data, byte_width) };
    }

    pub fn EmptyBlob() Blob {
        const empty_blob = [_]u8{ 0 };
        return Blob.new(empty_blob[1..], 1);
    }

    pub fn IsTheEmptyBlob(self: *const Blob) bool {
        return self.base.data == Blob.EmptyBlob().base.data;
    }

    pub fn data(self: *const Blob) []const u8 {
        return self.base.data;
    }
};

const Vector = struct {
    base: Sized,

    pub fn new(data: []const u8, byte_width: u8) Vector {
        return Vector{ .base = Sized.new(data, byte_width) };
    }

    pub fn operator_index(self: *const Vector, i: usize) Reference {
        const len = self.base.size();
        if (i >= len) return Reference.new(null, 1, NullPackedType());
        const packed_type = (self.base.data + len * self.base.byte_width)[i];
        const elem = self.base.data + i * self.base.byte_width;
        return Reference.new(elem, self.base.byte_width, packed_type);
    }

    pub fn EmptyVector() Vector {
        const empty_vector = [_]u8{ 0 };
        return Vector.new(empty_vector[1..], 1);
    }

    pub fn IsTheEmptyVector(self: *const Vector) bool {
        return self.base.data == Vector.EmptyVector().base.data;
    }
};

const TypedVector = struct {
    base: Sized,
    type: Type,

    pub fn new(data: []const u8, byte_width: u8, element_type: Type) TypedVector {
        return TypedVector{ .base = Sized.new(data, byte_width), .type = element_type };
    }

    pub fn operator_index(self: *const TypedVector, i: usize) Reference {
        const len = self.base.size();
        if (i >= len) return Reference.new(null, 1, NullPackedType());
        const elem = self.base.data + i * self.base.byte_width;
        return Reference.new(elem, self.base.byte_width, 1, self.type);
    }

    pub fn EmptyTypedVector() TypedVector {
        const empty_typed_vector = [_]u8{ 0 };
        return TypedVector.new(empty_typed_vector[1..], 1, .FBT_INT);
    }

    pub fn IsTheEmptyVector(self: *const TypedVector) bool {
        return self.base.data == TypedVector.EmptyTypedVector().base.data;
    }

    pub fn ElementType(self: *const TypedVector) Type {
        return self.type;
    }
};

const FixedTypedVector = struct {
    base: Object,
    type: Type,
    len: u8,

    pub fn new(data: []const u8, byte_width: u8, element_type: Type, len: u8) FixedTypedVector {
        return FixedTypedVector{ .base = Object.new(data, byte_width), .type = element_type, .len = len };
    }

    pub fn operator_index(self: *const FixedTypedVector, i: usize) Reference {
        if (i >= self.len) return Reference.new(null, 1, NullPackedType());
        const elem = self.base.data + i * self.base.byte_width;
        return Reference.new(elem, self.base.byte_width, 1, self.type);
    }

    pub fn EmptyFixedTypedVector() FixedTypedVector {
        const fixed_empty_vector = [_]u8{ 0 };
        return FixedTypedVector.new(fixed_empty_vector[1..], 1, .FBT_INT, 0);
    }

    pub fn IsTheEmptyFixedTypedVector(self: *const FixedTypedVector) bool {
        return self.base.data == FixedTypedVector.EmptyFixedTypedVector().base.data;
    }

    pub fn ElementType(self: *const FixedTypedVector) Type {
        return self.type;
    }

    pub fn size(self: *const FixedTypedVector) u8 {
        return self.len;
    }
};

const Map = struct {
    base: Vector,

    pub fn new(data: []const u8, byte_width: u8) Map {
        return Map{ .base = Vector.new(data, byte_width) };
    }

    pub fn operator_index(self: *const Map, key: []const u8) Reference {
        const keys = self.Keys();
        const comp = switch (keys.base.byte_width) {
            1 => KeyCompare(u8),
            2 => KeyCompare(u16),
            4 => KeyCompare(u32),
            8 => KeyCompare(u64),
            else => unreachable,
        };
        const res = std.bsearch(key, keys.base.data, keys.base.size(), keys.base.byte_width, comp);
        if (res == null) return Reference.new(null, 1, NullPackedType());
        const i = (res - keys.base.data) / keys.base.byte_width;
        return self.base.operator_index(i);
    }

    pub fn operator_index(self: *const Map, key: []const u8) Reference {
        return self.operator_index(key);
    }

    pub fn Values(self: *const Map) Vector {
        return Vector.new(self.base.data, self.base.byte_width);
    }

    pub fn Keys(self: *const Map) TypedVector {
        const num_prefixed_fields = 3;
        const keys_offset = self.base.data - self.base.byte_width * num_prefixed_fields;
        return TypedVector.new(Indirect(keys_offset, self.base.byte_width), @intCast(u8, ReadUInt64(keys_offset + self.base.byte_width, self.base.byte_width)), .FBT_KEY);
    }

    pub fn EmptyMap() Map {
        const empty_map = [_]u8{ 0, 0, 1, 0 };
        return Map.new(empty_map[4..], 1);
    }

    pub fn IsTheEmptyMap(self: *const Map) bool {
        return self.base.data == Map.EmptyMap().base.data;
    }
};

fn AppendToString(comptime T: type, s: *std.String, v: T, keys_quoted: bool) void {
    s.append("[ ");
    for (i, item) in v {
        if (i != 0) s.append(", ");
        item.ToString(true, keys_quoted, s);
    }
    s.append(" ]");
}

const Reference = struct {
    data: []const u8,
    parent_width: u8,
    byte_width: u8,
    type: Type,

    pub fn new(data: []const u8, parent_width: u8, byte_width: u8, type: Type) Reference {
        return Reference{ .data = data, .parent_width = parent_width, .byte_width = byte_width, .type = type };
    }

    pub fn new(data: []const u8, parent_width: u8, packed_type: u8) Reference {
        const byte_width = 1 << @intCast(BitWidth, packed_type & 3);
        const type = @intCast(Type, packed_type >> 2);
        return Reference{ .data = data, .parent_width = parent_width, .byte_width = byte_width, .type = type };
    }

    pub fn GetType(self: *const Reference) Type {
        return self.type;
    }

    pub fn IsNull(self: *const Reference) bool {
        return self.type == .FBT_NULL;
    }

    pub fn IsBool(self: *const Reference) bool {
        return self.type == .FBT_BOOL;
    }

    pub fn IsInt(self: *const Reference) bool {
        return self.type == .FBT_INT or self.type == .FBT_INDIRECT_INT;
    }

    pub fn IsUInt(self: *const Reference) bool {
        return self.type == .FBT_UINT or self.type == .FBT_INDIRECT_UINT;
    }

    pub fn IsIntOrUint(self: *const Reference) bool {
        return self.IsInt() or self.IsUInt();
    }

    pub fn IsFloat(self: *const Reference) bool {
        return self.type == .FBT_FLOAT or self.type == .FBT_INDIRECT_FLOAT;
    }

    pub fn IsNumeric(self: *const Reference) bool {
        return self.IsIntOrUint() or self.IsFloat();
    }

    pub fn IsString(self: *const Reference) bool {
        return self.type == .FBT_STRING;
    }

    pub fn IsKey(self: *const Reference) bool {
        return self.type == .FBT_KEY;
    }

    pub fn IsVector(self: *const Reference) bool {
        return self.type == .FBT_VECTOR or self.type == .FBT_MAP;
    }

    pub fn IsTypedVector(self: *const Reference) bool {
        return IsTypedVector(self.type);
    }

    pub fn IsFixedTypedVector(self: *const Reference) bool {
        return IsFixedTypedVector(self.type);
    }

    pub fn IsAnyVector(self: *const Reference) bool {
        return self.IsTypedVector() or self.IsFixedTypedVector() or self.IsVector();
    }

    pub fn IsMap(self: *const Reference) bool {
        return self.type == .FBT_MAP;
    }

    pub fn IsBlob(self: *const Reference) bool {
        return self.type == .FBT_BLOB or self.type == .FBT_STRING;
    }

    pub fn AsBool(self: *const Reference) bool {
        return if (self.type == .FBT_BOOL) ReadUInt64(self.data, self.parent_width) else self.AsUInt64() != 0;
    }

    pub fn AsInt64(self: *const Reference) i64 {
        return switch (self.type) {
            .FBT_INT => ReadInt64(self.data, self.parent_width),
            .FBT_INDIRECT_INT => ReadInt64(Indirect(self.data, self.byte_width), self.byte_width),
            .FBT_UINT => ReadUInt64(self.data, self.parent_width),
            .FBT_INDIRECT_UINT => ReadUInt64(Indirect(self.data, self.byte_width), self.byte_width),
            .FBT_FLOAT => @intCast(i64, ReadDouble(self.data, self.parent_width)),
            .FBT_INDIRECT_FLOAT => @intCast(i64, ReadDouble(Indirect(self.data, self.byte_width), self.byte_width)),
            .FBT_NULL => 0,
            .FBT_STRING => std.fmt.parseInt(i64, self.AsString().c_str(), 10),
            .FBT_VECTOR => @intCast(i64, self.AsVector().base.size()),
            .FBT_BOOL => ReadInt64(self.data, self.parent_width),
            else => 0,
        };
    }

    pub fn AsInt32(self: *const Reference) i32 {
        return @intCast(i32, self.AsInt64());
    }

    pub fn AsInt16(self: *const Reference) i16 {
        return @intCast(i16, self.AsInt64());
    }

    pub fn AsInt8(self: *const Reference) i8 {
        return @intCast(i8, self.AsInt64());
    }

    pub fn AsUInt64(self: *const Reference) u64 {
        return switch (self.type) {
            .FBT_UINT => ReadUInt64(self.data, self.parent_width),
            .FBT_INDIRECT_UINT => ReadUInt64(Indirect(self.data, self.byte_width), self.byte_width),
            .FBT_INT => ReadInt64(self.data, self.parent_width),
            .FBT_INDIRECT_INT => ReadInt64(Indirect(self.data, self.byte_width), self.byte_width),
            .FBT_FLOAT => @intCast(u64, ReadDouble(self.data, self.parent_width)),
            .FBT_INDIRECT_FLOAT => @intCast(u64, ReadDouble(Indirect(self.data, self.byte_width), self.byte_width)),
            .FBT_NULL => 0,
            .FBT_STRING => std.fmt.parseInt(u64, self.AsString().c_str(), 10),
            .FBT_VECTOR => @intCast(u64, self.AsVector().base.size()),
            .FBT_BOOL => ReadUInt64(self.data, self.parent_width),
            else => 0,
        };
    }

    pub fn AsUInt32(self: *const Reference) u32 {
        return @intCast(u32, self.AsUInt64());
    }

    pub fn AsUInt16(self: *const Reference) u16 {
        return @intCast(u16, self.AsUInt64());
    }

    pub fn AsUInt8(self: *const Reference) u8 {
        return @intCast(u8, self.AsUInt64());
    }

    pub fn AsDouble(self: *const Reference) f64 {
        return switch (self.type) {
            .FBT_FLOAT => ReadDouble(self.data, self.parent_width),
            .FBT_INDIRECT_FLOAT => ReadDouble(Indirect(self.data, self.byte_width), self.byte_width),
            .FBT_INT => @floatCast(f64, ReadInt64(self.data, self.parent_width)),
            .FBT_UINT => @floatCast(f64, ReadUInt64(self.data, self.parent_width)),
            .FBT_INDIRECT_INT => @floatCast(f64, ReadInt64(Indirect(self.data, self.byte_width), self.byte_width)),
            .FBT_INDIRECT_UINT => @floatCast(f64, ReadUInt64(Indirect(self.data, self.byte_width), self.byte_width)),
            .FBT_NULL => 0.0,
            .FBT_STRING => std.fmt.parseFloat(f64, self.AsString().c_str()),
            .FBT_VECTOR => @floatCast(f64, self.AsVector().base.size()),
            .FBT_BOOL => @floatCast(f64, ReadUInt64(self.data, self.parent_width)),
            else => 0.0,
        };
    }

    pub fn AsFloat(self: *const Reference) f32 {
        return @floatCast(f32, self.AsDouble());
    }

    pub fn AsKey(self: *const Reference) []const u8 {
        return if (self.type == .FBT_KEY) Indirect(self.data, self.parent_width) else "";
    }

    pub fn AsString(self: *const Reference) String {
        return if (self.type == .FBT_STRING) String.new(Indirect(self.data, self.byte_width), self.byte_width) else String.EmptyString();
    }

    pub fn ToString(self: *const Reference) []const u8 {
        var s = std.String.init();
        self.ToString(false, false, &s);
        return s.toSlice();
    }

    pub fn ToString(self: *const Reference, strings_quoted: bool, keys_quoted: bool, s: *std.String) void {
        switch (self.type) {
            .FBT_STRING => {
                const str = String.new(Indirect(self.data, self.byte_width), self.byte_width);
                if (strings_quoted) {
                    std.fmt.escapeString(str.c_str(), str.length(), s, true, false);
                } else {
                    s.append(str.c_str()[0..str.length()]);
                }
            },
            .FBT_KEY => {
                const str = self.AsKey();
                if (keys_quoted) {
                    std.fmt.escapeString(str, std.mem.len(str), s, true, false);
                } else {
                    s.append(str);
                }
            },
            .FBT_INT => s.append(std.fmt.formatInt(self.AsInt64())),
            .FBT_UINT => s.append(std.fmt.formatInt(self.AsUInt64())),
            .FBT_FLOAT => s.append(std.fmt.formatFloat(self.AsDouble())),
            .FBT_NULL => s.append("null"),
            .FBT_BOOL => s.append(if (self.AsBool()) "true" else "false"),
            .FBT_MAP => {
                s.append("{ ");
                const m = self.AsMap();
                const keys = m.Keys();
                const vals = m.Values();
                for (i, key) in keys {
                    key.ToString(true, keys_quoted, s);
                    s.append(": ");
                    vals[i].ToString(true, keys_quoted, s);
                    if (i < keys.size() - 1) s.append(", ");
                }
                s.append(" }");
            },
            .FBT_VECTOR => AppendToString(Vector, s, self.AsVector(), keys_quoted),
            .FBT_TYPED_VECTOR => AppendToString(TypedVector, s, self.AsTypedVector(), keys_quoted),
            .FBT_FIXED_TYPED_VECTOR => AppendToString(FixedTypedVector, s, self.AsFixedTypedVector(), keys_quoted),
            .FBT_BLOB => {
                const blob = self.AsBlob();
                std.fmt.escapeString(blob.data(), blob.size(), s, true, false);
            },
            else => s.append("(?)"),
        }
    }

    pub fn AsBlob(self: *const Reference) Blob {
        return if (self.type == .FBT_BLOB or self.type == .FBT_STRING) Blob.new(Indirect(self.data, self.byte_width), self.byte_width) else Blob.EmptyBlob();
    }

    pub fn AsVector(self: *const Reference) Vector {
        return if (self.type == .FBT_VECTOR or self.type == .FBT_MAP) Vector.new(Indirect(self.data, self.byte_width), self.byte_width) else Vector.EmptyVector();
    }

    pub fn AsTypedVector(self: *const Reference) TypedVector {
        return if (IsTypedVector(self.type)) TypedVector.new(Indirect(self.data, self.byte_width), self.byte_width, ToTypedVectorElementType(self.type)) else TypedVector.EmptyTypedVector();
    }

    pub fn AsFixedTypedVector(self: *const Reference) FixedTypedVector {
        return if (IsFixedTypedVector(self.type)) {
            var len: u8 = 0;
            const vtype = ToFixedTypedVectorElementType(self.type, &len);
            FixedTypedVector.new(Indirect(self.data, self.byte_width), self.byte_width, vtype, len);
        } else {
            FixedTypedVector.EmptyFixedTypedVector();
        }
    }

    pub fn AsMap(self: *const Reference) Map {
        return if (self.type == .FBT_MAP) Map.new(Indirect(self.data, self.byte_width), self.byte_width) else Map.EmptyMap();
    }

    pub fn MutateInt(self: *Reference, i: i64) bool {
        return switch (self.type) {
            .FBT_INT => self.Mutate(self.data, i, self.parent_width, WidthI(i)),
            .FBT_INDIRECT_INT => self.Mutate(Indirect(self.data, self.byte_width), i, self.byte_width, WidthI(i)),
            .FBT_UINT => self.Mutate(self.data, @intCast(u64, i), self.parent_width, WidthU(@intCast(u64, i))),
            .FBT_INDIRECT_UINT => self.Mutate(Indirect(self.data, self.byte_width), @intCast(u64, i), self.byte_width, WidthU(@intCast(u64, i))),
            else => false,
        };
    }

    pub fn MutateBool(self: *Reference, b: bool) bool {
        return self.type == .FBT_BOOL and self.Mutate(self.data, b, self.parent_width, .BIT_WIDTH_8);
    }

    pub fn MutateUInt(self: *Reference, u: u64) bool {
        return switch (self.type) {
            .FBT_UINT => self.Mutate(self.data, u, self.parent_width, WidthU(u)),
            .FBT_INDIRECT_UINT => self.Mutate(Indirect(self.data, self.byte_width), u, self.byte_width, WidthU(u)),
            .FBT_INT => self.Mutate(self.data, @intCast(i64, u), self.parent_width, WidthI(@intCast(i64, u))),
            .FBT_INDIRECT_INT => self.Mutate(Indirect(self.data, self.byte_width), @intCast(i64, u), self.byte_width, WidthI(@intCast(i64, u))),
            else => false,
        };
    }

    pub fn MutateFloat(self: *Reference, f: f32) bool {
        return switch (self.type) {
            .FBT_FLOAT => self.MutateF(self.data, f, self.parent_width, .BIT_WIDTH_32),
            .FBT_INDIRECT_FLOAT => self.MutateF(Indirect(self.data, self.byte_width), f, self.byte_width, .BIT_WIDTH_32),
            else => false,
        };
    }

    pub fn MutateFloat(self: *Reference, d: f64) bool {
        return switch (self.type) {
            .FBT_FLOAT => self.MutateF(self.data, d, self.parent_width, WidthF(d)),
            .FBT_INDIRECT_FLOAT => self.MutateF(Indirect(self.data, self.byte_width), d, self.byte_width, WidthF(d)),
            else => false,
        };
    }

    pub fn MutateString(self: *Reference, str: []const u8, len: usize) bool {
        const s = self.AsString();
        if (s.IsTheEmptyString()) return false;
        if (s.length() != len) return false;
        std.mem.copy(u8, s.c_str(), str, len);
        return true;
    }

    pub fn MutateString(self: *Reference, str: []const u8) bool {
        return self.MutateString(str, std.mem.len(str));
    }

    pub fn MutateString(self: *Reference, str: []const u8) bool {
        return self.MutateString(str, std.mem.len(str));
    }

    fn Indirect(self: *const Reference) []const u8 {
        return flexbuffers.Indirect(self.data, self.parent_width);
    }

    fn Mutate(comptime T: type, dest: []const u8, t: T, byte_width: usize, value_width: BitWidth) bool {
        const fits = (1 << @enumToInt(value_width)) <= byte_width;
        if (fits) {
            const t_endian = std.builtin.endianSwap(t);
            std.mem.copy(u8, dest, @bytesOf(t_endian), byte_width);
        }
        return fits;
    }

    fn MutateF(comptime T: type, dest: []const u8, t: T, byte_width: usize, value_width: BitWidth) bool {
        return switch (byte_width) {
            8 => self.Mutate(dest, @floatCast(f64, t), byte_width, value_width),
            4 => self.Mutate(dest, @floatCast(f32, t), byte_width, value_width),
            else => unreachable,
        };
    }
};

fn KeyCompare(comptime T: type, key: []const u8, elem: []const u8) i32 {
    const str_elem = Indirect(elem, @sizeOf(T));
    const skey = key;
    return std.mem.cmp(skey, str_elem);
}

fn NullPackedType() u8 {
    return PackedType(.BIT_WIDTH_8, .FBT_NULL);
}

fn PackedType(bit_width: BitWidth, type: Type) u8 {
    return @intCast(u8, @enumToInt(bit_width) | (@enumToInt(type) << 2));
}

fn GetRoot(buffer: []const u8, size: usize) Reference {
    const end = buffer[size..];
    const byte_width = end[-1];
    const packed_type = end[-2];
    const root_data = end[-1 - byte_width..-1];
    return Reference.new(root_data, byte_width, packed_type);
}

fn GetRoot(buffer: []const u8) Reference {
    return GetRoot(buffer, buffer.len);
}
