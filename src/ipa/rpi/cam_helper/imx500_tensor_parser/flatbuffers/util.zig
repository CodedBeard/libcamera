const std = @import("std");
const base = @import("flatbuffers/base.zig");

const FLATBUFFERS_PREFER_PRINTF = false;

fn check_ascii_range(x: u8, a: u8, b: u8) bool {
    return x >= a and x <= b;
}

fn is_alpha(c: u8) bool {
    return check_ascii_range(c & 0xDF, 'a' & 0xDF, 'z' & 0xDF);
}

fn is_alpha_char(c: u8, alpha: u8) bool {
    return (c & 0xDF) == (alpha & 0xDF);
}

fn is_digit(c: u8) bool {
    return check_ascii_range(c, '0', '9');
}

fn is_xdigit(c: u8) bool {
    return is_digit(c) or check_ascii_range(c & 0xDF, 'a' & 0xDF, 'f' & 0xDF);
}

fn is_alnum(c: u8) bool {
    return is_alpha(c) or is_digit(c);
}

fn int_to_digit_count(T: type, t: T) usize {
    var digit_count: usize = 0;
    if (t < 0) digit_count += 1;
    if (t > -1 and t < 1) digit_count += 1;
    var eps = std.math.epsilon(T);
    while (t <= (-1 + eps) or (1 - eps) <= t) {
        t /= 10;
        digit_count += 1;
    }
    return digit_count;
}

fn num_to_string_width(T: type, t: T, precision: i32) usize {
    var string_width = int_to_digit_count(T, t);
    if (precision != 0) string_width += (precision + 1);
    return string_width;
}

fn num_to_string_impl_wrapper(T: type, t: T, fmt: []const u8, precision: i32) []const u8 {
    var string_width = num_to_string_width(T, t, precision);
    var s = std.heap.page_allocator.alloc(u8, string_width) catch unreachable;
    std.fmt.bufPrintZ(s, fmt, .{precision, t}) catch unreachable;
    return s;
}

fn num_to_string(T: type, t: T) []const u8 {
    if (!FLATBUFFERS_PREFER_PRINTF) {
        return std.fmt.bufPrintZ(std.heap.page_allocator, "{}", .{t}) catch unreachable;
    } else {
        return num_to_string_impl_wrapper(T, t, "%.*lld", 0);
    }
}

fn float_to_string(T: type, t: T, precision: i32) []const u8 {
    if (!FLATBUFFERS_PREFER_PRINTF) {
        return std.fmt.bufPrintZ(std.heap.page_allocator, "{:.{}f}", .{t, precision}) catch unreachable;
    } else {
        return num_to_string_impl_wrapper(T, t, "%0.*f", precision);
    }
}

fn int_to_string_hex(i: i32, xdigits: i32) []const u8 {
    return std.fmt.bufPrintZ(std.heap.page_allocator, "{:0{}X}", .{i, xdigits}) catch unreachable;
}

fn strtoval_impl(T: type, val: *T, str: []const u8, base: i32) void {
    if (T == i64) {
        val.* = std.fmt.parseInt(i64, str, base) catch unreachable;
    } else if (T == u64) {
        val.* = std.fmt.parseInt(u64, str, base) catch unreachable;
    } else if (T == f64) {
        val.* = std.fmt.parseFloat(f64, str) catch unreachable;
    } else if (T == f32) {
        val.* = std.fmt.parseFloat(f32, str) catch unreachable;
    }
}

fn string_to_integer_impl(T: type, val: *T, str: []const u8, base: i32, check_errno: bool) bool {
    if (base <= 0) {
        var s = str;
        while (s.len > 0 and !is_digit(s[0])) s = s[1..];
        if (s.len > 1 and s[0] == '0' and is_alpha_char(s[1], 'X')) {
            return string_to_integer_impl(T, val, str, 16, check_errno);
        }
        return string_to_integer_impl(T, val, str, 10, check_errno);
    } else {
        if (check_errno) std.os.setErrno(0);
        var endptr: ?[]const u8 = null;
        strtoval_impl(T, val, str, base);
        if (endptr != null and endptr.* != 0) {
            val.* = 0;
            return false;
        }
        if (check_errno and std.os.getErrno() != 0) return false;
        return true;
    }
}

fn string_to_float_impl(T: type, val: *T, str: []const u8) bool {
    var end: ?[]const u8 = null;
    strtoval_impl(T, val, str, 10);
    return end != null and end.* == 0;
}

fn string_to_number(T: type, s: []const u8, val: *T) bool {
    if (T == i64) {
        return string_to_integer_impl(T, val, s, 0, false);
    } else if (T == u64) {
        if (!string_to_integer_impl(T, val, s, 0, false)) return false;
        if (val.* != 0) {
            var str = s;
            while (str.len > 0 and !is_digit(str[0])) str = str[1..];
            if (str.len > 0 and str[0] == '-') {
                val.* = std.math.maxInt(u64);
                return false;
            }
        }
        return true;
    } else if (T == f32 or T == f64) {
        return string_to_float_impl(T, val, s);
    }
    return false;
}

fn string_to_int(s: []const u8, base: i32) i64 {
    var val: i64 = 0;
    return if (string_to_integer_impl(i64, &val, s, base, true)) val else 0;
}

fn string_to_uint(s: []const u8, base: i32) u64 {
    var val: u64 = 0;
    return if (string_to_integer_impl(u64, &val, s, base, true)) val else 0;
}

fn escape_string(s: []const u8, allow_non_utf8: bool, natural_utf8: bool) []const u8 {
    var text = std.heap.page_allocator.alloc(u8, s.len * 2) catch unreachable;
    text[0] = '"';
    var idx = 1;
    for (i, c) in s {
        switch (c) {
            '\n' => {
                text[idx] = '\\';
                text[idx + 1] = 'n';
                idx += 2;
            },
            '\t' => {
                text[idx] = '\\';
                text[idx + 1] = 't';
                idx += 2;
            },
            '\r' => {
                text[idx] = '\\';
                text[idx + 1] = 'r';
                idx += 2;
            },
            '\b' => {
                text[idx] = '\\';
                text[idx + 1] = 'b';
                idx += 2;
            },
            '\f' => {
                text[idx] = '\\';
                text[idx + 1] = 'f';
                idx += 2;
            },
            '"' => {
                text[idx] = '\\';
                text[idx + 1] = '"';
                idx += 2;
            },
            '\\' => {
                text[idx] = '\\';
                text[idx + 1] = '\\';
                idx += 2;
            },
            else => {
                if (c >= ' ' and c <= '~') {
                    text[idx] = c;
                    idx += 1;
                } else {
                    var utf8 = s[i..];
                    var ucc = std.unicode.utf8Decode(utf8) catch -1;
                    if (ucc < 0) {
                        if (allow_non_utf8) {
                            text[idx] = '\\';
                            text[idx + 1] = 'x';
                            text[idx + 2] = int_to_string_hex(c, 2)[0];
                            text[idx + 3] = int_to_string_hex(c, 2)[1];
                            idx += 4;
                        } else {
                            return null;
                        }
                    } else {
                        if (natural_utf8) {
                            for (j, b) in utf8[0..ucc.len] {
                                text[idx + j] = b;
                            }
                            idx += ucc.len;
                        } else if (ucc <= 0xFFFF) {
                            text[idx] = '\\';
                            text[idx + 1] = 'u';
                            var hex = int_to_string_hex(ucc, 4);
                            for (j, b) in hex {
                                text[idx + 2 + j] = b;
                            }
                            idx += 6;
                        } else if (ucc <= 0x10FFFF) {
                            var base = ucc - 0x10000;
                            var high_surrogate = (base >> 10) + 0xD800;
                            var low_surrogate = (base & 0x03FF) + 0xDC00;
                            text[idx] = '\\';
                            text[idx + 1] = 'u';
                            var high_hex = int_to_string_hex(high_surrogate, 4);
                            for (j, b) in high_hex {
                                text[idx + 2 + j] = b;
                            }
                            text[idx + 6] = '\\';
                            text[idx + 7] = 'u';
                            var low_hex = int_to_string_hex(low_surrogate, 4);
                            for (j, b) in low_hex {
                                text[idx + 8 + j] = b;
                            }
                            idx += 12;
                        }
                    }
                }
            }
        }
    }
    text[idx] = '"';
    return text[0..idx + 1];
}

fn remove_string_quotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) {
        return s[1..s.len - 1];
    }
    return s;
}

fn set_global_test_locale(locale_name: []const u8) []const u8 {
    return std.os.setLocale(std.os.LC_ALL, locale_name) catch unreachable;
}

fn read_environment_variable(var_name: []const u8) []const u8 {
    return std.os.getenv(var_name) catch null;
}
