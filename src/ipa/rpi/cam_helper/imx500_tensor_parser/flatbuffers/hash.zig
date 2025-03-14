const std = @import("std");

const FnvTraits = struct {
    const kFnvPrime: u32 = 0x01000193;
    const kOffsetBasis: u32 = 0x811C9DC5;
};

fn hashFnv1(input: []const u8) u32 {
    var hash: u32 = FnvTraits.kOffsetBasis;
    for (input) |c| {
        hash = hash * FnvTraits.kFnvPrime;
        hash = hash ^ @intCast(u32, c);
    }
    return hash;
}

fn hashFnv1a(input: []const u8) u32 {
    var hash: u32 = FnvTraits.kOffsetBasis;
    for (input) |c| {
        hash = hash ^ @intCast(u32, c);
        hash = hash * FnvTraits.kFnvPrime;
    }
    return hash;
}

fn hashFnv1_16(input: []const u8) u16 {
    const hash: u32 = hashFnv1(input);
    return @intCast(u16, (hash >> 16) ^ (hash & 0xffff));
}

fn hashFnv1a_16(input: []const u8) u16 {
    const hash: u32 = hashFnv1a(input);
    return @intCast(u16, (hash >> 16) ^ (hash & 0xffff));
}

const NamedHashFunction = struct {
    name: []const u8,
    function: fn([]const u8) u32,
};

const kHashFunctions32 = [_]NamedHashFunction{
    NamedHashFunction{ .name = "fnv1_32", .function = hashFnv1 },
    NamedHashFunction{ .name = "fnv1a_32", .function = hashFnv1a },
};

fn findHashFunction32(name: []const u8) ?fn([]const u8) u32 {
    for (kHashFunctions32) |hashFunction| {
        if (std.mem.eql(u8, name, hashFunction.name)) {
            return hashFunction.function;
        }
    }
    return null;
}
