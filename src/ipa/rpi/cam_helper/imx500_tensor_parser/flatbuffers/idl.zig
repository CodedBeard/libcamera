const std = @import("std");

const FLATBUFFERS_MAX_PARSING_DEPTH = 64;

const BaseType = enum {
    NONE,
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
    VECTOR,
    STRUCT,
    UNION,
};

const Type = struct {
    base_type: BaseType,
    element: BaseType,
    struct_def: ?*StructDef,
    enum_def: ?*EnumDef,

    pub fn init(base_type: BaseType, struct_def: ?*StructDef, enum_def: ?*EnumDef) Type {
        return Type{
            .base_type = base_type,
            .element = BaseType.NONE,
            .struct_def = struct_def,
            .enum_def = enum_def,
        };
    }

    pub fn VectorType(self: Type) Type {
        return Type.init(self.element, self.struct_def, self.enum_def);
    }
};

const Value = struct {
    type_: Type,
    constant: []const u8,
    offset: u32,

    pub fn init() Value {
        return Value{
            .type_ = Type.init(BaseType.NONE, null, null),
            .constant = "0",
            .offset = ~u32(0),
        };
    }
};

const SymbolTable = struct {
    dict: std.StringHashMap(*void),
    vec: std.ArrayList(*void),

    pub fn init(allocator: *std.mem.Allocator) SymbolTable {
        return SymbolTable{
            .dict = std.StringHashMap(*void).init(allocator),
            .vec = std.ArrayList(*void).init(allocator),
        };
    }

    pub fn add(self: *SymbolTable, name: []const u8, e: *void) bool {
        self.vec.append(e) catch return false;
        return self.dict.put(name, e) == null;
    }

    pub fn lookup(self: *SymbolTable, name: []const u8) ?*void {
        return self.dict.get(name);
    }
};

const Namespace = struct {
    components: std.ArrayList([]const u8),
    from_table: usize,

    pub fn init(allocator: *std.mem.Allocator) Namespace {
        return Namespace{
            .components = std.ArrayList([]const u8).init(allocator),
            .from_table = 0,
        };
    }

    pub fn GetFullyQualifiedName(self: *Namespace, name: []const u8, max_components: usize) []const u8 {
        var result = std.ArrayList([]const u8).init(self.components.allocator);
        defer result.deinit();

        var count = std.math.min(self.components.items.len, max_components);
        for (self.components.items[0..count]) |component| {
            result.append(component) catch return "";
            result.append(".") catch return "";
        }
        result.append(name) catch return "";

        return result.toOwnedSlice();
    }
};

const Definition = struct {
    name: []const u8,
    file: []const u8,
    doc_comment: std.ArrayList([]const u8),
    attributes: SymbolTable,
    generated: bool,
    defined_namespace: ?*Namespace,
    serialized_location: u32,
    index: i32,
    refcount: i32,

    pub fn init(allocator: *std.mem.Allocator) Definition {
        return Definition{
            .name = "",
            .file = "",
            .doc_comment = std.ArrayList([]const u8).init(allocator),
            .attributes = SymbolTable.init(allocator),
            .generated = false,
            .defined_namespace = null,
            .serialized_location = 0,
            .index = -1,
            .refcount = 1,
        };
    }
};

const FieldDef = struct {
    base: Definition,
    value: Value,
    deprecated: bool,
    required: bool,
    key: bool,
    shared: bool,
    native_inline: bool,
    flexbuffer: bool,
    nested_flatbuffer: ?*StructDef,
    padding: usize,

    pub fn init(allocator: *std.mem.Allocator) FieldDef {
        return FieldDef{
            .base = Definition.init(allocator),
            .value = Value.init(),
            .deprecated = false,
            .required = false,
            .key = false,
            .shared = false,
            .native_inline = false,
            .flexbuffer = false,
            .nested_flatbuffer = null,
            .padding = 0,
        };
    }
};

const StructDef = struct {
    base: Definition,
    fields: SymbolTable,
    fixed: bool,
    predecl: bool,
    sortbysize: bool,
    has_key: bool,
    minalign: usize,
    bytesize: usize,

    pub fn init(allocator: *std.mem.Allocator) StructDef {
        return StructDef{
            .base = Definition.init(allocator),
            .fields = SymbolTable.init(allocator),
            .fixed = false,
            .predecl = true,
            .sortbysize = true,
            .has_key = false,
            .minalign = 1,
            .bytesize = 0,
        };
    }

    pub fn PadLastField(self: *StructDef, min_align: usize) void {
        var padding = std.math.alignForward(self.bytesize, min_align) - self.bytesize;
        self.bytesize += padding;
        if (self.fields.vec.items.len > 0) {
            var last_field = @field(self.fields.vec.items[self.fields.vec.items.len - 1], "padding");
            last_field.* = padding;
        }
    }
};

const EnumVal = struct {
    name: []const u8,
    doc_comment: std.ArrayList([]const u8),
    value: i64,
    union_type: Type,

    pub fn init(allocator: *std.mem.Allocator, name: []const u8, value: i64) EnumVal {
        return EnumVal{
            .name = name,
            .doc_comment = std.ArrayList([]const u8).init(allocator),
            .value = value,
            .union_type = Type.init(BaseType.NONE, null, null),
        };
    }
};

const EnumDef = struct {
    base: Definition,
    vals: SymbolTable,
    is_union: bool,
    uses_multiple_type_instances: bool,
    underlying_type: Type,

    pub fn init(allocator: *std.mem.Allocator) EnumDef {
        return EnumDef{
            .base = Definition.init(allocator),
            .vals = SymbolTable.init(allocator),
            .is_union = false,
            .uses_multiple_type_instances = false,
            .underlying_type = Type.init(BaseType.NONE, null, null),
        };
    }

    pub fn ReverseLookup(self: *EnumDef, enum_idx: i64, skip_union_default: bool) ?*EnumVal {
        var start = if (self.is_union and skip_union_default) 1 else 0;
        for (self.vals.vec.items[start..]) |val| {
            if (@field(val, "value") == enum_idx) {
                return val;
            }
        }
        return null;
    }
};

const RPCCall = struct {
    base: Definition,
    request: ?*StructDef,
    response: ?*StructDef,

    pub fn init(allocator: *std.mem.Allocator) RPCCall {
        return RPCCall{
            .base = Definition.init(allocator),
            .request = null,
            .response = null,
        };
    }
};

const ServiceDef = struct {
    base: Definition,
    calls: SymbolTable,

    pub fn init(allocator: *std.mem.Allocator) ServiceDef {
        return ServiceDef{
            .base = Definition.init(allocator),
            .calls = SymbolTable.init(allocator),
        };
    }
};

const IDLOptions = struct {
    strict_json: bool,
    skip_js_exports: bool,
    use_goog_js_export_format: bool,
    use_ES6_js_export_format: bool,
    output_default_scalars_in_json: bool,
    indent_step: i32,
    output_enum_identifiers: bool,
    prefixed_enums: bool,
    scoped_enums: bool,
    include_dependence_headers: bool,
    mutable_buffer: bool,
    one_file: bool,
    proto_mode: bool,
    proto_oneof_union: bool,
    generate_all: bool,
    skip_unexpected_fields_in_json: bool,
    generate_name_strings: bool,
    generate_object_based_api: bool,
    gen_compare: bool,
    cpp_object_api_pointer_type: []const u8,
    cpp_object_api_string_type: []const u8,
    cpp_object_api_string_flexible_constructor: bool,
    gen_nullable: bool,
    gen_generated: bool,
    object_prefix: []const u8,
    object_suffix: []const u8,
    union_value_namespacing: bool,
    allow_non_utf8: bool,
    natural_utf8: bool,
    include_prefix: []const u8,
    keep_include_path: bool,
    binary_schema_comments: bool,
    binary_schema_builtins: bool,
    skip_flatbuffers_import: bool,
    go_import: []const u8,
    go_namespace: []const u8,
    reexport_ts_modules: bool,
    js_ts_short_names: bool,
    protobuf_ascii_alike: bool,
    size_prefixed: bool,
    root_type: []const u8,
    force_defaults: bool,
    lang: Language,
    mini_reflect: MiniReflect,
    lang_to_generate: u64,
    set_empty_to_null: bool,

    pub fn init() IDLOptions {
        return IDLOptions{
            .strict_json = false,
            .skip_js_exports = false,
            .use_goog_js_export_format = false,
            .use_ES6_js_export_format = false,
            .output_default_scalars_in_json = false,
            .indent_step = 2,
            .output_enum_identifiers = true,
            .prefixed_enums = true,
            .scoped_enums = false,
            .include_dependence_headers = true,
            .mutable_buffer = false,
            .one_file = false,
            .proto_mode = false,
            .proto_oneof_union = false,
            .generate_all = false,
            .skip_unexpected_fields_in_json = false,
            .generate_name_strings = false,
            .generate_object_based_api = false,
            .gen_compare = false,
            .cpp_object_api_pointer_type = "std::unique_ptr",
            .cpp_object_api_string_flexible_constructor = false,
            .gen_nullable = false,
            .gen_generated = false,
            .object_suffix = "T",
            .union_value_namespacing = true,
            .allow_non_utf8 = false,
            .natural_utf8 = false,
            .keep_include_path = false,
            .binary_schema_comments = false,
            .binary_schema_builtins = false,
            .skip_flatbuffers_import = false,
            .reexport_ts_modules = true,
            .js_ts_short_names = false,
            .protobuf_ascii_alike = false,
            .size_prefixed = false,
            .force_defaults = false,
            .lang = Language.Java,
            .mini_reflect = MiniReflect.None,
            .lang_to_generate = 0,
            .set_empty_to_null = true,
        };
    }

    pub const Language = enum {
        Java = 1 << 0,
        CSharp = 1 << 1,
        Go = 1 << 2,
        Cpp = 1 << 3,
        Js = 1 << 4,
        Python = 1 << 5,
        Php = 1 << 6,
        Json = 1 << 7,
        Binary = 1 << 8,
        Ts = 1 << 9,
        JsonSchema = 1 << 10,
        Dart = 1 << 11,
        Lua = 1 << 12,
        Lobster = 1 << 13,
        Rust = 1 << 14,
        MAX,
    };

    pub const MiniReflect = enum {
        None,
        Types,
        TypesAndNames,
    };
};

const ParserState = struct {
    cursor: ?*const u8,
    line_start: ?*const u8,
    line: i32,
    token: i32,
    attr_is_trivial_ascii_string: bool,
    attribute: []const u8,
    doc_comment: std.ArrayList([]const u8),

    pub fn init(allocator: *std.mem.Allocator) ParserState {
        return ParserState{
            .cursor = null,
            .line_start = null,
            .line = 0,
            .token = -1,
            .attr_is_trivial_ascii_string = true,
            .attribute = "",
            .doc_comment = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn ResetState(self: *ParserState, source: []const u8) void {
        self.cursor = source.ptr;
        self.line = 0;
        self.MarkNewLine();
    }

    pub fn MarkNewLine(self: *ParserState) void {
        self.line_start = self.cursor;
        self.line += 1;
    }

    pub fn CursorPosition(self: *ParserState) i64 {
        return @intCast(i64, self.cursor - self.line_start);
    }
};

const CheckedError = struct {
    is_error: bool,
    has_been_checked: bool,

    pub fn init(error: bool) CheckedError {
        return CheckedError{
            .is_error = error,
            .has_been_checked = false,
        };
    }

    pub fn check(self: *CheckedError) bool {
        self.has_been_checked = true;
        return self.is_error;
    }
};

const Parser = struct {
    state: ParserState,
    current_namespace: ?*Namespace,
    empty_namespace: ?*Namespace,
    root_struct_def: ?*StructDef,
    opts: IDLOptions,
    uses_flexbuffers: bool,
    source: ?*const u8,
    anonymous_counter: i32,
    recurse_protection_counter: i32,
    types: SymbolTable,
    structs: SymbolTable,
    enums: SymbolTable,
    services: SymbolTable,
    namespaces: std.ArrayList(*Namespace),
    file_identifier: []const u8,
    file_extension: []const u8,
    included_files: std.StringHashMap([]const u8),
    files_included_per_file: std.StringHashMap(std.ArrayList([]const u8)),
    native_included_files: std.ArrayList([]const u8),
    known_attributes: std.StringHashMap(bool),
    error: []const u8,

    pub fn init(allocator: *std.mem.Allocator, options: IDLOptions) Parser {
        var empty_namespace = Namespace.init(allocator);
        var namespaces = std.ArrayList(*Namespace).init(allocator);
        namespaces.append(&empty_namespace) catch unreachable;

        return Parser{
            .state = ParserState.init(allocator),
            .current_namespace = &empty_namespace,
            .empty_namespace = &empty_namespace,
            .root_struct_def = null,
            .opts = options,
            .uses_flexbuffers = false,
            .source = null,
            .anonymous_counter = 0,
            .recurse_protection_counter = 0,
            .types = SymbolTable.init(allocator),
            .structs = SymbolTable.init(allocator),
            .enums = SymbolTable.init(allocator),
            .services = SymbolTable.init(allocator),
            .namespaces = namespaces,
            .file_identifier = "",
            .file_extension = "",
            .included_files = std.StringHashMap([]const u8).init(allocator),
            .files_included_per_file = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .native_included_files = std.ArrayList([]const u8).init(allocator),
            .known_attributes = std.StringHashMap(bool).init(allocator),
            .error = "",
        };
    }

    pub fn Parse(self: *Parser, source: []const u8, include_paths: ?[][]const u8, source_filename: ?[]const u8) bool {
        // Implementation of Parse function
        return true;
    }

    pub fn SetRootType(self: *Parser, name: []const u8) bool {
        // Implementation of SetRootType function
        return true;
    }

    pub fn MarkGenerated(self: *Parser) void {
        // Implementation of MarkGenerated function
    }

    pub fn GetIncludedFilesRecursive(self: *Parser, file_name: []const u8) std.StringHashMap(bool) {
        // Implementation of GetIncludedFilesRecursive function
        return std.StringHashMap(bool).init(self.state.doc_comment.allocator);
    }

    pub fn Serialize(self: *Parser) void {
        // Implementation of Serialize function
    }

    pub fn Deserialize(self: *Parser, buf: []const u8) bool {
        // Implementation of Deserialize function
        return true;
    }

    pub fn DeserializeSchema(self: *Parser, schema: *const u8) bool {
        // Implementation of DeserializeSchema function
        return true;
    }

    pub fn DeserializeType(self: *Parser, type_: *const u8) ?*Type {
        // Implementation of DeserializeType function
        return null;
    }

    pub fn ConformTo(self: *Parser, base: *Parser) []const u8 {
        // Implementation of ConformTo function
        return "";
    }

    pub fn ParseFlexBuffer(self: *Parser, source: []const u8, source_filename: []const u8, builder: *const u8) bool {
        // Implementation of ParseFlexBuffer function
        return true;
    }

    pub fn LookupStruct(self: *Parser, id: []const u8) ?*StructDef {
        // Implementation of LookupStruct function
        return null;
    }

    pub fn UnqualifiedName(self: *Parser, fullQualifiedName: []const u8) []const u8 {
        // Implementation of UnqualifiedName function
        return "";
    }

    pub fn Error(self: *Parser, msg: []const u8) CheckedError {
        // Implementation of Error function
        return CheckedError.init(true);
    }
};

pub fn MakeCamel(in: []const u8, first: bool) []const u8 {
    // Implementation of MakeCamel function
    return "";
}

pub fn GenerateTextFromTable(parser: *Parser, table: *const u8, tablename: []const u8, text: *std.ArrayList(u8)) bool {
    // Implementation of GenerateTextFromTable function
    return true;
}

pub fn GenerateText(parser: *Parser, flatbuffer: *const u8, text: *std.ArrayList(u8)) bool {
    // Implementation of GenerateText function
    return true;
}

pub fn GenerateTextFile(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateTextFile function
    return true;
}

pub fn GenerateBinary(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateBinary function
    return true;
}

pub fn GenerateCPP(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateCPP function
    return true;
}

pub fn GenerateDart(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateDart function
    return true;
}

pub fn GenerateJSTS(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateJSTS function
    return true;
}

pub fn GenerateGo(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateGo function
    return true;
}

pub fn GeneratePhp(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GeneratePhp function
    return true;
}

pub fn GeneratePython(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GeneratePython function
    return true;
}

pub fn GenerateLobster(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateLobster function
    return true;
}

pub fn GenerateLua(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateLua function
    return true;
}

pub fn GenerateRust(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateRust function
    return true;
}

pub fn GenerateJsonSchema(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateJsonSchema function
    return true;
}

pub fn GenerateGeneral(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateGeneral function
    return true;
}

pub fn GenerateFBS(parser: *Parser, file_name: []const u8) []const u8 {
    // Implementation of GenerateFBS function
    return "";
}

pub fn GenerateFBSFile(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateFBSFile function
    return true;
}

pub fn JSTSMakeRule(parser: *Parser, path: []const u8, file_name: []const u8) []const u8 {
    // Implementation of JSTSMakeRule function
    return "";
}

pub fn CPPMakeRule(parser: *Parser, path: []const u8, file_name: []const u8) []const u8 {
    // Implementation of CPPMakeRule function
    return "";
}

pub fn DartMakeRule(parser: *Parser, path: []const u8, file_name: []const u8) []const u8 {
    // Implementation of DartMakeRule function
    return "";
}

pub fn RustMakeRule(parser: *Parser, path: []const u8, file_name: []const u8) []const u8 {
    // Implementation of RustMakeRule function
    return "";
}

pub fn GeneralMakeRule(parser: *Parser, path: []const u8, file_name: []const u8) []const u8 {
    // Implementation of GeneralMakeRule function
    return "";
}

pub fn TextMakeRule(parser: *Parser, path: []const u8, file_names: []const u8) []const u8 {
    // Implementation of TextMakeRule function
    return "";
}

pub fn BinaryMakeRule(parser: *Parser, path: []const u8, file_name: []const u8) []const u8 {
    // Implementation of BinaryMakeRule function
    return "";
}

pub fn GenerateCppGRPC(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateCppGRPC function
    return true;
}

pub fn GenerateGoGRPC(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateGoGRPC function
    return true;
}

pub fn GenerateJavaGRPC(parser: *Parser, path: []const u8, file_name: []const u8) bool {
    // Implementation of GenerateJavaGRPC function
    return true;
}
