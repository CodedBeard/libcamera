const std = @import("std");

const FLATBUFFERS_LITTLEENDIAN = @intCast(bool, std.builtin.endian == .Little);

const FLATBUFFERS_VERSION_MAJOR = 1;
const FLATBUFFERS_VERSION_MINOR = 11;
const FLATBUFFERS_VERSION_REVISION = 0;

const FLATBUFFERS_MAX_BUFFER_SIZE = (1 << (@sizeOf(soffset_t) * 8 - 1)) - 1;
const FLATBUFFERS_MAX_ALIGNMENT = 16;

const uoffset_t = u32;
const soffset_t = i32;
const voffset_t = u16;
const largest_scalar_t = u64;

fn EndianSwap(T: type, t: T) T {
    if (@sizeOf(T) == 1) {
        return t;
    } else if (@sizeOf(T) == 2) {
        return @intCast(T, std.mem.swapBytes(@intCast(u16, t)));
    } else if (@sizeOf(T) == 4) {
        return @intCast(T, std.mem.swapBytes(@intCast(u32, t)));
    } else if (@sizeOf(T) == 8) {
        return @intCast(T, std.mem.swapBytes(@intCast(u64, t)));
    } else {
        std.debug.assert(false);
    }
}

fn EndianScalar(T: type, t: T) T {
    if (FLATBUFFERS_LITTLEENDIAN) {
        return t;
    } else {
        return EndianSwap(T, t);
    }
}

fn ReadScalar(T: type, p: *const u8) T {
    return EndianScalar(T, @ptrCast(*const T, p).*);
}

fn WriteScalar(T: type, p: *u8, t: T) void {
    @ptrCast(*T, p).* = EndianScalar(T, t);
}

fn PaddingBytes(buf_size: usize, scalar_size: usize) usize {
    return ((~buf_size) + 1) & (scalar_size - 1);
}
