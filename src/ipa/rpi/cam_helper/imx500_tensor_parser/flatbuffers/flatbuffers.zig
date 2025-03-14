const std = @import("std");
const c = @cImport({
    @cInclude("base.h");
});

pub const FlatBufferBuilder = struct {
    buf: std.ArrayList(u8),
    num_field_loc: u32,
    max_voffset: u16,
    nested: bool,
    finished: bool,
    minalign: usize,
    force_defaults: bool,
    dedup_vtables: bool,
    string_pool: ?*StringOffsetMap,

    pub fn init(allocator: *std.mem.Allocator) FlatBufferBuilder {
        return FlatBufferBuilder{
            .buf = std.ArrayList(u8).init(allocator),
            .num_field_loc = 0,
            .max_voffset = 0,
            .nested = false,
            .finished = false,
            .minalign = 1,
            .force_defaults = false,
            .dedup_vtables = true,
            .string_pool = null,
        };
    }

    pub fn deinit(self: *FlatBufferBuilder) void {
        if (self.string_pool) |pool| {
            pool.deinit();
        }
        self.buf.deinit();
    }

    pub fn reset(self: *FlatBufferBuilder) void {
        self.clear();
        self.buf.resize(0) catch unreachable;
    }

    pub fn clear(self: *FlatBufferBuilder) void {
        self.clear_offsets();
        self.buf.resize(0) catch unreachable;
        self.nested = false;
        self.finished = false;
        self.minalign = 1;
        if (self.string_pool) |pool| {
            pool.clear();
        }
    }

    pub fn getSize(self: *const FlatBufferBuilder) u32 {
        return self.buf.items.len;
    }

    pub fn getBufferPointer(self: *const FlatBufferBuilder) *const u8 {
        self.finished();
        return self.buf.items.ptr;
    }

    pub fn getCurrentBufferPointer(self: *const FlatBufferBuilder) *const u8 {
        return self.buf.items.ptr;
    }

    pub fn releaseBufferPointer(self: *FlatBufferBuilder) *u8 {
        self.finished();
        return self.buf.release();
    }

    pub fn release(self: *FlatBufferBuilder) *u8 {
        self.finished();
        return self.buf.release();
    }

    pub fn releaseRaw(self: *FlatBufferBuilder, size: *usize, offset: *usize) *u8 {
        self.finished();
        return self.buf.releaseRaw(size, offset);
    }

    pub fn getBufferMinAlignment(self: *const FlatBufferBuilder) usize {
        self.finished();
        return self.minalign;
    }

    pub fn forceDefaults(self: *FlatBufferBuilder, fd: bool) void {
        self.force_defaults = fd;
    }

    pub fn dedupVtables(self: *FlatBufferBuilder, dedup: bool) void {
        self.dedup_vtables = dedup;
    }

    pub fn pad(self: *FlatBufferBuilder, num_bytes: usize) void {
        self.buf.resize(self.buf.items.len + num_bytes) catch unreachable;
    }

    pub fn trackMinAlign(self: *FlatBufferBuilder, elem_size: usize) void {
        if (elem_size > self.minalign) {
            self.minalign = elem_size;
        }
    }

    pub fn align(self: *FlatBufferBuilder, elem_size: usize) void {
        self.trackMinAlign(elem_size);
        self.buf.resize(self.buf.items.len + paddingBytes(self.buf.items.len, elem_size)) catch unreachable;
    }

    pub fn pushFlatBuffer(self: *FlatBufferBuilder, bytes: []const u8) void {
        self.pushBytes(bytes);
        self.finished = true;
    }

    pub fn pushBytes(self: *FlatBufferBuilder, bytes: []const u8) void {
        self.buf.appendSlice(bytes) catch unreachable;
    }

    pub fn popBytes(self: *FlatBufferBuilder, amount: usize) void {
        self.buf.resize(self.buf.items.len - amount) catch unreachable;
    }

    pub fn pushElement(self: *FlatBufferBuilder, element: var) u32 {
        self.align(@sizeOf(element));
        self.buf.append(&element, 1) catch unreachable;
        return self.getSize();
    }

    pub fn trackField(self: *FlatBufferBuilder, field: u16, off: u32) void {
        const fl = FieldLoc{ .off = off, .id = field };
        self.buf.append(&fl, 1) catch unreachable;
        self.num_field_loc += 1;
        if (field > self.max_voffset) {
            self.max_voffset = field;
        }
    }

    pub fn addElement(self: *FlatBufferBuilder, field: u16, e: var, def: var) void {
        if (e == def and !self.force_defaults) return;
        const off = self.pushElement(e);
        self.trackField(field, off);
    }

    pub fn addOffset(self: *FlatBufferBuilder, field: u16, off: u32) void {
        if (off == 0) return;
        self.addElement(field, self.referTo(off), 0);
    }

    pub fn addStruct(self: *FlatBufferBuilder, field: u16, structptr: ?*const var) void {
        if (structptr == null) return;
        self.align(@alignOf(@TypeOf(structptr.*)));
        self.buf.append(structptr, 1) catch unreachable;
        self.trackField(field, self.getSize());
    }

    pub fn addStructOffset(self: *FlatBufferBuilder, field: u16, off: u32) void {
        self.trackField(field, off);
    }

    pub fn referTo(self: *FlatBufferBuilder, off: u32) u32 {
        self.align(@sizeOf(u32));
        return self.getSize() - off + @sizeOf(u32);
    }

    pub fn notNested(self: *FlatBufferBuilder) void {
        assert(!self.nested);
        assert(self.num_field_loc == 0);
    }

    pub fn startTable(self: *FlatBufferBuilder) u32 {
        self.notNested();
        self.nested = true;
        return self.getSize();
    }

    pub fn endTable(self: *FlatBufferBuilder, start: u32) u32 {
        assert(self.nested);
        const vtableoffsetloc = self.pushElement(0);
        self.buf.resize(self.buf.items.len + self.max_voffset) catch unreachable;
        const table_object_size = vtableoffsetloc - start;
        assert(table_object_size < 0x10000);
        self.buf.items.ptr[sizeof(u16)] = @intCast(u16, table_object_size);
        self.buf.items.ptr[0] = self.max_voffset;
        for (var it = self.buf.items.ptr + self.buf.items.len - self.num_field_loc * @sizeOf(FieldLoc); it < self.buf.items.ptr + self.buf.items.len; it += @sizeOf(FieldLoc)) {
            const field_location = @ptrCast(*FieldLoc, it);
            const pos = @intCast(u16, vtableoffsetloc - field_location.off);
            assert(self.buf.items.ptr[field_location.id] == 0);
            self.buf.items.ptr[field_location.id] = pos;
        }
        self.clearOffsets();
        const vt1 = @ptrCast(*u16, self.buf.items.ptr);
        const vt1_size = vt1.*;
        var vt_use = self.getSize();
        if (self.dedup_vtables) {
            for (var it = self.buf.items.ptr; it < self.buf.items.ptr + self.buf.items.len; it += @sizeOf(u32)) {
                const vt_offset_ptr = @ptrCast(*u32, it);
                const vt2 = @ptrCast(*u16, self.buf.items.ptr + vt_offset_ptr.*);
                const vt2_size = vt2.*;
                if (vt1_size != vt2_size or memcmp(vt2, vt1, vt1_size) != 0) continue;
                vt_use = vt_offset_ptr.*;
                self.buf.resize(self.buf.items.len - (self.getSize() - vtableoffsetloc)) catch unreachable;
                break;
            }
        }
        if (vt_use == self.getSize()) {
            self.buf.append(&vt_use, 1) catch unreachable;
        }
        self.buf.items.ptr[vtableoffsetloc] = @intCast(i32, vt_use) - @intCast(i32, vtableoffsetloc);
        self.nested = false;
        return vtableoffsetloc;
    }

    pub fn required(self: *FlatBufferBuilder, table: u32, field: u16) void {
        const table_ptr = @ptrCast(*Table, self.buf.items.ptr + table);
        const ok = table_ptr.getOptionalFieldOffset(field) != 0;
        assert(ok);
    }

    pub fn startStruct(self: *FlatBufferBuilder, alignment: usize) u32 {
        self.align(alignment);
        return self.getSize();
    }

    pub fn endStruct(self: *FlatBufferBuilder) u32 {
        return self.getSize();
    }

    pub fn clearOffsets(self: *FlatBufferBuilder) void {
        self.buf.resize(self.buf.items.len - self.num_field_loc * @sizeOf(FieldLoc)) catch unreachable;
        self.num_field_loc = 0;
        self.max_voffset = 0;
    }

    pub fn preAlign(self: *FlatBufferBuilder, len: usize, alignment: usize) void {
        self.trackMinAlign(alignment);
        self.buf.resize(self.buf.items.len + paddingBytes(self.buf.items.len + len, alignment)) catch unreachable;
    }

    pub fn createString(self: *FlatBufferBuilder, str: []const u8) u32 {
        self.notNested();
        self.preAlign(@sizeOf(u32) + str.len + 1, 1);
        self.buf.resize(self.buf.items.len + 1) catch unreachable;
        self.pushBytes(str);
        self.pushElement(@intCast(u32, str.len));
        return self.getSize();
    }

    pub fn createSharedString(self: *FlatBufferBuilder, str: []const u8) u32 {
        if (self.string_pool == null) {
            self.string_pool = try self.buf.allocator.create(StringOffsetMap);
            self.string_pool.* = StringOffsetMap.init(self.buf);
        }
        const size_before_string = self.buf.items.len;
        const off = self.createString(str);
        if (self.string_pool.*.contains(off)) {
            self.buf.resize(size_before_string) catch unreachable;
            return self.string_pool.*.get(off).?;
        }
        self.string_pool.*.put(off, off);
        return off;
    }

    pub fn endVector(self: *FlatBufferBuilder, len: usize) u32 {
        assert(self.nested);
        self.nested = false;
        return self.pushElement(@intCast(u32, len));
    }

    pub fn startVector(self: *FlatBufferBuilder, len: usize, elemsize: usize) void {
        self.notNested();
        self.nested = true;
        self.preAlign(@sizeOf(u32) + len * elemsize, elemsize);
    }

    pub fn forceVectorAlignment(self: *FlatBufferBuilder, len: usize, elemsize: usize, alignment: usize) void {
        self.preAlign(@sizeOf(u32) + len * elemsize, alignment);
    }

    pub fn forceStringAlignment(self: *FlatBufferBuilder, len: usize, alignment: usize) void {
        self.preAlign(@sizeOf(u32) + len + 1, alignment);
    }

    pub fn createVector(self: *FlatBufferBuilder, v: []const var) u32 {
        self.startVector(v.len, @sizeOf(@TypeOf(v[0])));
        self.pushBytes(@ptrCast(*const u8, v), v.len * @sizeOf(@TypeOf(v[0])));
        return self.endVector(v.len);
    }

    pub fn createVectorOfStructs(self: *FlatBufferBuilder, v: []const var) u32 {
        self.startVector(v.len, @sizeOf(@TypeOf(v[0])));
        self.pushBytes(@ptrCast(*const u8, v), v.len * @sizeOf(@TypeOf(v[0])));
        return self.endVector(v.len);
    }

    pub fn createVectorOfSortedStructs(self: *FlatBufferBuilder, v: []var) u32 {
        std.sort.sort(v, StructKeyComparator{});
        return self.createVectorOfStructs(v);
    }

    pub fn createVectorOfSortedTables(self: *FlatBufferBuilder, v: []u32) u32 {
        std.sort.sort(v, TableKeyComparator{ .buf = self.buf });
        return self.createVector(v);
    }

    pub fn createUninitializedVector(self: *FlatBufferBuilder, len: usize, elemsize: usize, buf: *?*u8) u32 {
        self.notNested();
        self.startVector(len, elemsize);
        self.buf.resize(self.buf.items.len + len * elemsize) catch unreachable;
        const vec_start = self.getSize();
        const vec_end = self.endVector(len);
        buf.* = self.buf.items.ptr + vec_start;
        return vec_end;
    }

    pub fn createStruct(self: *FlatBufferBuilder, structobj: var) u32 {
        self.notNested();
        self.align(@alignOf(@TypeOf(structobj)));
        self.buf.append(&structobj, 1) catch unreachable;
        return self.getSize();
    }

    pub fn finish(self: *FlatBufferBuilder, root: u32, file_identifier: ?[]const u8) void {
        self.finishBuffer(root, file_identifier, false);
    }

    pub fn finishSizePrefixed(self: *FlatBufferBuilder, root: u32, file_identifier: ?[]const u8) void {
        self.finishBuffer(root, file_identifier, true);
    }

    pub fn swapBufAllocator(self: *FlatBufferBuilder, other: *FlatBufferBuilder) void {
        self.buf.swapAllocator(other.buf);
    }

    fn finished(self: *const FlatBufferBuilder) void {
        assert(self.finished);
    }

    fn finishBuffer(self: *FlatBufferBuilder, root: u32, file_identifier: ?[]const u8, size_prefix: bool) void {
        self.notNested();
        self.buf.clearScratch();
        self.preAlign(@sizeOf(u32) + if (file_identifier) |id| id.len else 0, self.minalign);
        if (file_identifier) |id| {
            assert(id.len == 4);
            self.pushBytes(id);
        }
        self.pushElement(self.referTo(root));
        if (size_prefix) {
            self.pushElement(self.getSize());
        }
        self.finished = true;
    }
};

fn paddingBytes(buf_size: usize, scalar_size: usize) usize {
    return ((~buf_size) + 1) & (scalar_size - 1);
}

const FieldLoc = struct {
    off: u32,
    id: u16,
};

const Table = struct {
    data: [*]u8,

    fn getVTable(self: *const Table) *const u8 {
        return self.data - @intCast(i32, self.data[0]);
    }

    fn getOptionalFieldOffset(self: *const Table, field: u16) u16 {
        const vtable = self.getVTable();
        const vtsize = @intCast(u16, vtable[0]);
        return if (field < vtsize) @intCast(u16, vtable[field]) else 0;
    }

    fn getField(self: *const Table, field: u16, defaultval: var) var {
        const field_offset = self.getOptionalFieldOffset(field);
        return if (field_offset != 0) @intCast(@TypeOf(defaultval), self.data[field_offset]) else defaultval;
    }

    fn getPointer(self: *const Table, field: u16) *const u8 {
        const field_offset = self.getOptionalFieldOffset(field);
        const p = self.data + field_offset;
        return if (field_offset != 0) p + @intCast(u32, p[0]) else null;
    }

    fn getStruct(self: *const Table, field: u16) *const var {
        const field_offset = self.getOptionalFieldOffset(field);
        const p = self.data + field_offset;
        return if (field_offset != 0) @ptrCast(*const var, p) else null;
    }

    fn setField(self: *Table, field: u16, val: var, def: var) bool {
        const field_offset = self.getOptionalFieldOffset(field);
        if (field_offset == 0) return val == def;
        self.data[field_offset] = @intCast(u8, val);
        return true;
    }

    fn setPointer(self: *Table, field: u16, val: *const u8) bool {
        const field_offset = self.getOptionalFieldOffset(field);
        if (field_offset == 0) return false;
        self.data[field_offset] = @intCast(u8, val - (self.data + field_offset));
        return true;
    }

    fn getAddressOf(self: *Table, field: u16) *u8 {
        const field_offset = self.getOptionalFieldOffset(field);
        return if (field_offset != 0) self.data + field_offset else null;
    }

    fn checkField(self: *const Table, field: u16) bool {
        return self.getOptionalFieldOffset(field) != 0;
    }

    fn verifyTableStart(self: *const Table, verifier: *Verifier) bool {
        return verifier.verifyTableStart(self.data);
    }

    fn verifyField(self: *const Table, verifier: *Verifier, field: u16) bool {
        const field_offset = self.getOptionalFieldOffset(field);
        return field_offset == 0 or verifier.verify(self.data, field_offset);
    }

    fn verifyFieldRequired(self: *const Table, verifier: *Verifier, field: u16) bool {
        const field_offset = self.getOptionalFieldOffset(field);
        return verifier.check(field_offset != 0) and verifier.verify(self.data, field_offset);
    }

    fn verifyOffset(self: *const Table, verifier: *Verifier, field: u16) bool {
        const field_offset = self.getOptionalFieldOffset(field);
        return field_offset == 0 or verifier.verifyOffset(self.data, field_offset);
    }

    fn verifyOffsetRequired(self: *const Table, verifier: *Verifier, field: u16) bool {
        const field_offset = self.getOptionalFieldOffset(field);
        return verifier.check(field_offset != 0) and verifier.verifyOffset(self.data, field_offset);
    }
};

const Verifier = struct {
    buf: [*]const u8,
    size: usize,
    depth: u32,
    max_depth: u32,
    num_tables: u32,
    max_tables: u32,
    upper_bound: usize,
    check_alignment: bool,

    pub fn init(buf: [*]const u8, buf_len: usize, max_depth: u32, max_tables: u32, check_alignment: bool) Verifier {
        return Verifier{
            .buf = buf,
            .size = buf_len,
            .depth = 0,
            .max_depth = max_depth,
            .num_tables = 0,
            .max_tables = max_tables,
            .upper_bound = 0,
            .check_alignment = check_alignment,
        };
    }

    pub fn check(self: *const Verifier, ok: bool) bool {
        return ok;
    }

    pub fn verify(self: *const Verifier, elem: usize, elem_len: usize) bool {
        return self.check(elem_len < self.size and elem <= self.size - elem_len);
    }

    pub fn verifyAlignment(self: *const Verifier, elem: usize) bool {
        return (elem & (@sizeOf(@TypeOf(elem)) - 1)) == 0 or !self.check_alignment;
    }

    pub fn verifyType(self: *const Verifier, elem: usize) bool {
        return self.verifyAlignment(elem) and self.verify(elem, @sizeOf(@TypeOf(elem)));
    }

    pub fn verifyPointer(self: *const Verifier, base: [*]const u8, elem_off: u16, elem_len: usize) bool {
        return self.verify(@intCast(usize, base - self.buf) + elem_off, elem_len);
    }

    pub fn verifyPointerType(self: *const Verifier, base: [*]const u8, elem_off: u16) bool {
        return self.verify(@intCast(usize, base - self.buf) + elem_off, @sizeOf(@TypeOf(elem_off)));
    }

    pub fn verifyTable(self: *const Verifier, table: *const Table) bool {
        return table == null or table.verify(self);
    }

    pub fn verifyVector(self: *const Verifier, vec: *const Vector) bool {
        return vec == null or self.verifyVectorOrString(@ptrCast([*]const u8, vec), @sizeOf(@TypeOf(vec.items[0])));
    }

    pub fn verifyVectorOrString(self: *const Verifier, vec: [*]const u8, elem_size: usize, end: ?*usize) bool {
        const veco = @intCast(usize, vec - self.buf);
        if (!self.verifyType(veco)) return false;
        const size = @intCast(usize, vec[0]);
        const max_elems = FLATBUFFERS_MAX_BUFFER_SIZE / elem_size;
        if (!self.check(size < max_elems)) return false;
        const byte_size = @sizeOf(@TypeOf(size)) + elem_size * size;
        if (end) |e| e.* = veco + byte_size;
        return self.verify(veco, byte_size);
    }

    pub fn verifyVectorOfStrings(self: *const Verifier, vec: *const Vector) bool {
        if (vec) |v| {
            for (var i: u32 = 0; i < v.len; i += 1) {
                if (!self.verifyString(v[i])) return false;
            }
        }
        return true;
    }

    pub fn verifyVectorOfTables(self: *const Verifier, vec: *const Vector) bool {
        if (vec) |v| {
            for (var i: u32 = 0; i < v.len; i += 1) {
                if (!v[i].verify(self)) return false;
            }
        }
        return true;
    }

    pub fn verifyTableStart(self: *const Verifier, table: [*]const u8) bool {
        const tableo = @intCast(usize, table - self.buf);
        if (!self.verifyType(tableo)) return false;
        const vtableo = tableo - @intCast(usize, table[0]);
        return self.verifyComplexity() and self.verifyType(vtableo) and self.verifyAlignment(@intCast(usize, self.buf[vtableo])) and self.verify(vtableo, @intCast(usize, self.buf[vtableo]));
    }

    pub fn verifyBufferFromStart(self: *const Verifier, identifier: ?[*]const u8, start: usize) bool {
        if (identifier and (self.size < 2 * @sizeOf(u32) or !bufferHasIdentifier(self.buf + start, identifier))) return false;
        const o = self.verifyOffset(start);
        return o != 0 and @ptrCast(*const Table, self.buf + start + o).verify(self);
    }

    pub fn verifyBuffer(self: *const Verifier) bool {
        return self.verifyBufferType(null);
    }

    pub fn verifyBufferType(self: *const Verifier, identifier: ?[*]const u8) bool {
        return self.verifyBufferFromStart(identifier, 0);
    }

    pub fn verifySizePrefixedBuffer(self: *const Verifier, identifier: ?[*]const u8) bool {
        return self.verifyType(0) and @intCast(usize, self.buf[0]) == self.size - @sizeOf(u32) and self.verifyBufferFromStart(identifier, @sizeOf(u32));
    }

    pub fn verifyOffset(self: *const Verifier, start: usize) u32 {
        if (!self.verifyType(start)) return 0;
        const o = @intCast(u32, self.buf[start]);
        if (!self.check(o != 0)) return 0;
        if (!self.check(@intCast(i32, o) >= 0)) return 0;
        if (!self.verify(start + o, 1)) return 0;
        return o;
    }

    pub fn verifyOffsetPointer(self: *const Verifier, base: [*]const u8, start: u16) u32 {
        return self.verifyOffset(@intCast(usize, base - self.buf) + start);
    }

    pub fn verifyComplexity(self: *Verifier) bool {
        self.depth += 1;
        self.num_tables += 1;
        return self.check(self.depth <= self.max_depth and self.num_tables <= self.max_tables);
    }

    pub fn endTable(self: *Verifier) bool {
        self.depth -= 1;
        return true;
    }

    pub fn getComputedSize(self: *const Verifier) usize {
        return self.upper_bound;
    }
};

fn bufferHasIdentifier(buf: [*]const u8, identifier: [*]const u8) bool {
    return std.mem.eql(u8, buf[0..4], identifier[0..4]);
}

fn getBufferStartFromRootPointer(root: *const void) *const u8 {
    const table = @ptrCast(*const Table, root);
    const vtable = table.getVTable();
    var start = if (vtable < @ptrCast([*]const u8, root)) vtable else @ptrCast([*]const u8, root);
    start = @ptrCast([*]const u8, @intCast(usize, start) & ~(std.mem.sizeOf(u32) - 1));
    for (var possible_roots = FLATBUFFERS_MAX_ALIGNMENT / std.mem.sizeOf(u32) + 1; possible_roots != 0; possible_roots -= 1) {
        start -= std.mem.sizeOf(u32);
        if (@intCast(u32, start[0]) + start == @ptrCast([*]const u8, root)) return start;
    }
    assert(false);
    return null;
}

fn getPrefixedSize(buf: [*]const u8) u32 {
    return @intCast(u32, buf[0]);
}

const NativeTable = struct {};

const StringOffsetMap = std.AutoHashMap(u32, u32, std.hash_map.defaultHasher);

const StructKeyComparator = struct {
    pub fn compare(a: var, b: var) bool {
        return a.keyCompareLessThan(b);
    }
};

const TableKeyComparator = struct {
    buf: std.ArrayList(u8),

    pub fn compare(a: u32, b: u32) bool {
        const table_a = @ptrCast(*Table, self.buf.items.ptr + a);
        const table_b = @ptrCast(*Table, self.buf.items.ptr + b);
        return table_a.keyCompareLessThan(table_b);
    }
};
