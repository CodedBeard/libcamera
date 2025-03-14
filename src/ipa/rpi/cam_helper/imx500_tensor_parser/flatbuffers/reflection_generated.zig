const std = @import("std");

pub const BaseType = enum {
    None,
    UType,
    Bool,
    Byte,
    UByte,
    Short,
    UShort,
    Int,
    UInt,
    Long,
    ULong,
    Float,
    Double,
    String,
    Vector,
    Obj,
    Union,

    pub fn values() []const BaseType {
        return &[_]BaseType{
            .None,
            .UType,
            .Bool,
            .Byte,
            .UByte,
            .Short,
            .UShort,
            .Int,
            .UInt,
            .Long,
            .ULong,
            .Float,
            .Double,
            .String,
            .Vector,
            .Obj,
            .Union,
        };
    }

    pub fn names() []const []const u8 {
        return &[_][]const u8{
            "None",
            "UType",
            "Bool",
            "Byte",
            "UByte",
            "Short",
            "UShort",
            "Int",
            "UInt",
            "Long",
            "ULong",
            "Float",
            "Double",
            "String",
            "Vector",
            "Obj",
            "Union",
        };
    }

    pub fn name(e: BaseType) []const u8 {
        return BaseType.names()[@enumToInt(e)];
    }
};

pub const Type = struct {
    base_type: BaseType,
    element: BaseType,
    index: i32,

    pub fn new(base_type: BaseType, element: BaseType, index: i32) Type {
        return Type{
            .base_type = base_type,
            .element = element,
            .index = index,
        };
    }
};

pub const KeyValue = struct {
    key: []const u8,
    value: ?[]const u8,

    pub fn new(key: []const u8, value: ?[]const u8) KeyValue {
        return KeyValue{
            .key = key,
            .value = value,
        };
    }
};

pub const EnumVal = struct {
    name: []const u8,
    value: i64,
    object: ?*const Object,
    union_type: ?*const Type,
    documentation: ?[]const []const u8,

    pub fn new(name: []const u8, value: i64, object: ?*const Object, union_type: ?*const Type, documentation: ?[]const []const u8) EnumVal {
        return EnumVal{
            .name = name,
            .value = value,
            .object = object,
            .union_type = union_type,
            .documentation = documentation,
        };
    }
};

pub const Enum = struct {
    name: []const u8,
    values: []const EnumVal,
    is_union: bool,
    underlying_type: *const Type,
    attributes: ?[]const KeyValue,
    documentation: ?[]const []const u8,

    pub fn new(name: []const u8, values: []const EnumVal, is_union: bool, underlying_type: *const Type, attributes: ?[]const KeyValue, documentation: ?[]const []const u8) Enum {
        return Enum{
            .name = name,
            .values = values,
            .is_union = is_union,
            .underlying_type = underlying_type,
            .attributes = attributes,
            .documentation = documentation,
        };
    }
};

pub const Field = struct {
    name: []const u8,
    type_: *const Type,
    id: u16,
    offset: u16,
    default_integer: i64,
    default_real: f64,
    deprecated: bool,
    required: bool,
    key: bool,
    attributes: ?[]const KeyValue,
    documentation: ?[]const []const u8,

    pub fn new(name: []const u8, type_: *const Type, id: u16, offset: u16, default_integer: i64, default_real: f64, deprecated: bool, required: bool, key: bool, attributes: ?[]const KeyValue, documentation: ?[]const []const u8) Field {
        return Field{
            .name = name,
            .type_ = type_,
            .id = id,
            .offset = offset,
            .default_integer = default_integer,
            .default_real = default_real,
            .deprecated = deprecated,
            .required = required,
            .key = key,
            .attributes = attributes,
            .documentation = documentation,
        };
    }
};

pub const Object = struct {
    name: []const u8,
    fields: []const Field,
    is_struct: bool,
    minalign: i32,
    bytesize: i32,
    attributes: ?[]const KeyValue,
    documentation: ?[]const []const u8,

    pub fn new(name: []const u8, fields: []const Field, is_struct: bool, minalign: i32, bytesize: i32, attributes: ?[]const KeyValue, documentation: ?[]const []const u8) Object {
        return Object{
            .name = name,
            .fields = fields,
            .is_struct = is_struct,
            .minalign = minalign,
            .bytesize = bytesize,
            .attributes = attributes,
            .documentation = documentation,
        };
    }
};

pub const RPCCall = struct {
    name: []const u8,
    request: *const Object,
    response: *const Object,
    attributes: ?[]const KeyValue,
    documentation: ?[]const []const u8,

    pub fn new(name: []const u8, request: *const Object, response: *const Object, attributes: ?[]const KeyValue, documentation: ?[]const []const u8) RPCCall {
        return RPCCall{
            .name = name,
            .request = request,
            .response = response,
            .attributes = attributes,
            .documentation = documentation,
        };
    }
};

pub const Service = struct {
    name: []const u8,
    calls: []const RPCCall,
    attributes: ?[]const KeyValue,
    documentation: ?[]const []const u8,

    pub fn new(name: []const u8, calls: []const RPCCall, attributes: ?[]const KeyValue, documentation: ?[]const []const u8) Service {
        return Service{
            .name = name,
            .calls = calls,
            .attributes = attributes,
            .documentation = documentation,
        };
    }
};

pub const Schema = struct {
    objects: []const Object,
    enums: []const Enum,
    file_ident: ?[]const u8,
    file_ext: ?[]const u8,
    root_table: ?*const Object,
    services: ?[]const Service,

    pub fn new(objects: []const Object, enums: []const Enum, file_ident: ?[]const u8, file_ext: ?[]const u8, root_table: ?*const Object, services: ?[]const Service) Schema {
        return Schema{
            .objects = objects,
            .enums = enums,
            .file_ident = file_ident,
            .file_ext = file_ext,
            .root_table = root_table,
            .services = services,
        };
    }
};
