//! Fused JSON number scanning and floating-point conversion.
//!
//! Scans a number once, accumulating its significant digits and decimal
//! exponent, then converts those directly. Delegating the conversion to
//! `std.fmt.parseFloat` would scan the digits a second time: it only accepts a
//! complete slice, and the `(mantissa, exponent)` form its converter consumes
//! is private.
//!
//! The conversion code under `vendor/` is vendored from the Zig standard
//! library.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("vendor/common.zig");
const FloatInfo = @import("vendor/FloatInfo.zig");
const convertEiselLemire = @import("vendor/convert_eisel_lemire.zig").convertEiselLemire;

/// Errors reported while scanning a JSON number.
///
/// This is a subset of `Cursor.Error`, so a failed scan can be returned from
/// cursor methods unchanged.
pub const Error = error{
    InvalidNumber,
    UnexpectedEof,
    UnexpectedToken,
};

/// Number of significant decimal digits a `u64` accumulator can hold.
const max_digits = 19;

/// A converted number and the offset just past its last byte.
pub fn Result(comptime T: type) type {
    return struct {
        value: T,
        end: usize,
    };
}

/// Scans the JSON number starting at `start` and converts it to `T`.
///
/// The scanner rejects everything JSON rejects that `std.fmt.parseFloat`
/// accepts (`1.`, `.5`, `+1`, `01`, `1e`, leading zeros, underscores, `inf`,
/// `nan`, hex floats). Trailing bytes that no JSON number can contain are left
/// for the caller, matching `Cursor.scanNumber`.
pub fn parse(comptime T: type, input: []const u8, start: usize) Error!Result(T) {
    if (start == input.len) return error.UnexpectedEof;

    var pos = start;
    var negative = false;
    switch (input[pos]) {
        '-' => {
            negative = true;
            pos += 1;
            if (pos == input.len) return error.InvalidNumber;
        },
        '0'...'9' => {},
        else => return error.UnexpectedToken,
    }

    var mantissa: u64 = 0;
    var significant: usize = 0;
    var dropped: usize = 0;

    // Integer part: JSON allows a lone `0` or a nonzero leading digit.
    const integer_first = input[pos];
    if (integer_first == '0') {
        pos += 1;
    } else if (integer_first >= '1' and integer_first <= '9') {
        mantissa = integer_first - '0';
        significant = 1;
        pos = scanDigits(input, pos + 1, &mantissa, &significant, &dropped);
    } else {
        return error.InvalidNumber;
    }

    // Fractional part.
    var fraction_digits: usize = 0;
    if (pos < input.len and input[pos] == '.') {
        pos += 1;
        const fraction_start = pos;
        if (pos == input.len) return error.InvalidNumber;
        if (!isDigit(input[pos])) return error.InvalidNumber;

        if (mantissa == 0) {
            // Leading zeros carry no significance but they do move the decimal
            // point, which `fraction_digits` accounts for.
            while (pos < input.len and input[pos] == '0') pos += 1;
            if (pos < input.len and isDigit(input[pos])) {
                mantissa = input[pos] - '0';
                significant = 1;
                pos += 1;
            }
        }
        if (pos < input.len and isDigit(input[pos])) {
            pos = scanDigits(input, pos, &mantissa, &significant, &dropped);
        }
        fraction_digits = pos - fraction_start;
    }

    // Exponent part.
    var exponent: i64 = 0;
    if (pos < input.len and (input[pos] == 'e' or input[pos] == 'E')) {
        pos += 1;
        var exponent_negative = false;
        if (pos < input.len and (input[pos] == '+' or input[pos] == '-')) {
            exponent_negative = input[pos] == '-';
            pos += 1;
        }
        if (pos == input.len or !isDigit(input[pos])) return error.InvalidNumber;
        while (pos < input.len and isDigit(input[pos])) : (pos += 1) {
            // Saturate well before overflowing: the conversion only cares
            // whether the exponent is far outside the representable range.
            if (exponent < 0x1000_0000) exponent = exponent * 10 + (input[pos] - '0');
        }
        if (exponent_negative) exponent = -exponent;
    }

    const end = pos;
    // Digits dropped past the accumulator shift the value up by one decimal
    // place each, while every fractional digit shifts it down by one.
    exponent += @as(i64, @intCast(dropped)) - @as(i64, @intCast(fraction_digits));

    if (comptime hasFastConverter(T)) {
        if (convert(T, negative, mantissa, exponent, dropped != 0)) |value| {
            if (comptime builtin.is_test) {
                assertMatches(T, value, input[start..end]);
            }
            return .{ .value = value, .end = end };
        }
    }

    // Unsupported types and near-halfway values go through the standard
    // library, so results stay bit-identical to it.
    const value = std.fmt.parseFloat(T, input[start..end]) catch return error.InvalidNumber;
    return .{ .value = value, .end = end };
}

/// Consumes a run of decimal digits.
///
/// Up to `max_digits` significant digits are accumulated into `mantissa`; the
/// rest only count towards `dropped`, which the caller turns into a decimal
/// exponent. Eight digits are consumed at a time while a whole chunk still fits
/// in the accumulator.
///
/// `mantissa` must be nonzero on entry so that no digit in the run can be an
/// insignificant leading zero.
inline fn scanDigits(
    input: []const u8,
    start: usize,
    mantissa: *u64,
    significant: *usize,
    dropped: *usize,
) usize {
    var pos = start;
    var accumulated = mantissa.*;
    var digits = significant.*;
    var skipped = dropped.*;

    while (digits <= max_digits - 8 and pos + 8 <= input.len) {
        const chunk = std.mem.readInt(u64, input[pos..][0..8], .little);
        if (!common.isEightDigits(chunk)) break;
        accumulated = accumulated *% 1_0000_0000 +% parse8Digits(chunk);
        digits += 8;
        pos += 8;
    }

    while (pos < input.len) {
        const digit = input[pos] -% '0';
        if (digit > 9) break;
        if (digits < max_digits) {
            accumulated = accumulated * 10 + digit;
            digits += 1;
        } else {
            skipped += 1;
        }
        pos += 1;
    }

    mantissa.* = accumulated;
    significant.* = digits;
    dropped.* = skipped;
    return pos;
}

/// Parses eight decimal digits packed in little-endian order.
///
/// Every byte must already be known to be `'0'..'9'`; see
/// `common.isEightDigits`. Three multiplications replace the usual eight by
/// splitting the packed bytes into two groups of four digits.
inline fn parse8Digits(chunk: u64) u64 {
    var value = chunk;
    const mask = 0x0000_00ff_0000_00ff;
    const mul1 = 0x000f_4240_0000_0064;
    const mul2 = 0x0000_2710_0000_0001;
    value -= 0x3030_3030_3030_3030;
    value = (value * 10) + (value >> 8); // cannot overflow, fits in 63 bits
    const low = (value & mask) *% mul1;
    const high = ((value >> 16) & mask) *% mul2;
    return @as(u64, @as(u32, @truncate((low +% high) >> 32)));
}

/// Converts scanned significant digits to `T`, or returns `null` when the fast
/// paths cannot prove the correctly rounded result.
fn convert(comptime T: type, negative: bool, mantissa: u64, exponent: i64, many_digits: bool) ?T {
    const info = FloatInfo.from(T);

    if (!many_digits) {
        // Clinger fast path: the mantissa and the power of ten are both
        // exactly representable, so the arithmetic is exactly rounded.
        if (mantissa <= info.max_mantissa_fast_path and
            exponent >= info.min_exponent_fast_path and
            exponent <= info.max_exponent_fast_path)
        {
            var value: T = @floatFromInt(mantissa);
            value = if (exponent < 0)
                value / pow10(T, @intCast(-exponent))
            else
                value * pow10(T, @intCast(exponent));
            return if (negative) -value else value;
        }

        // Disguised fast path: shift a small power of ten out of the exponent
        // and into the mantissa while the result stays exactly representable.
        if (exponent > info.max_exponent_fast_path and
            exponent <= info.max_exponent_fast_path_disguised)
        {
            const shift: usize = @intCast(exponent - info.max_exponent_fast_path);
            const scale = intPow10(shift);
            if (mantissa <= info.max_mantissa_fast_path / scale) {
                const scaled: T = @floatFromInt(mantissa * scale);
                const value = scaled * pow10(T, info.max_exponent_fast_path);
                return if (negative) -value else value;
            }
        }
    }

    if (convertEiselLemire(T, exponent, mantissa)) |biased| {
        if (!many_digits) return biased.toFloat(T, negative);
        // Truncated digits can only change the result by carrying into the last
        // kept digit, so the two possible roundings agreeing proves the result.
        if (convertEiselLemire(T, exponent, mantissa + 1)) |carried| {
            if (biased.eql(carried)) return biased.toFloat(T, negative);
        }
    }

    return null;
}

/// Reports whether `convert` can handle `T` without help.
fn hasFastConverter(comptime T: type) bool {
    return T == f16 or T == f32 or T == f64;
}

/// Re-derives `value` with the standard library and asserts the bits match.
///
/// This runs for every float a test binary parses, including the optimized
/// fuzz build, which makes the suite a continuous differential check of the
/// fused scanner.
fn assertMatches(comptime T: type, value: T, raw: []const u8) void {
    const reference = std.fmt.parseFloat(T, raw) catch unreachable;
    const actual_bits: [@sizeOf(T)]u8 = @bitCast(value);
    const reference_bits: [@sizeOf(T)]u8 = @bitCast(reference);
    std.debug.assert(std.mem.eql(u8, &actual_bits, &reference_bits));
}

/// Exact powers of ten, indexed by non-negative exponent.
fn pow10(comptime T: type, exponent: usize) T {
    return switch (T) {
        f16 => ([8]f16{
            1e0, 1e1, 1e2, 1e3, 1e4, 0, 0, 0,
        })[exponent & 7],

        f32 => ([16]f32{
            1e0, 1e1, 1e2,  1e3, 1e4, 1e5, 1e6, 1e7,
            1e8, 1e9, 1e10, 0,   0,   0,   0,   0,
        })[exponent & 15],

        f64 => ([32]f64{
            1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,
            1e8,  1e9,  1e10, 1e11, 1e12, 1e13, 1e14, 1e15,
            1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22, 0,
            0,    0,    0,    0,    0,    0,    0,    0,
        })[exponent & 31],

        else => unreachable,
    };
}

/// Exact powers of ten that fit in a `u64`, indexed by exponent.
fn intPow10(exponent: usize) u64 {
    return ([16]u64{
        1,             10,             100,             1000,
        10000,         100000,         1000000,         10000000,
        100000000,     1000000000,     10000000000,     100000000000,
        1000000000000, 10000000000000, 100000000000000, 1000000000000000,
    })[exponent];
}

inline fn isDigit(byte: u8) bool {
    return byte -% '0' <= 9;
}

test "float values match std" {
    const values = [_][]const u8{
        "0",                                        "-0",                                                      "0.0",                                                      "-0.0",
        "1",                                        "-1",                                                      "1.5",                                                      "-1.5",
        "1e0",                                      "1E0",                                                     "1e+1",                                                     "1e-1",
        "0e999999",                                 "-0e-999999",                                              "1e309",                                                    "1e-400",
        "1.7976931348623157e308",                   "-1.7976931348623157e308",                                 "2.2250738585072014e-308",                                  "4.9406564584124654e-324",
        "5e-324",                                   "2.5e-324",                                                "1.0000000000000002",                                       "0.1",
        "0.3",                                      "0.30000000000000004",                                     "9007199254740992",                                         "9007199254740993",
        "1234567890123456789012345678901234567890", "0.000000000000000000000000000000001",                     "1.0000000000000000000000000001",                           "3.14159265358979323846264338327950288",
        "1000000000000000000000",                   "65.613616999999977",                                      "-65.613616999999977",                                      "43.420273000000009",
        "0.000123",
        // Values sitting exactly halfway between two floats, or at the edge of
        // the subnormal range, are where Eisel-Lemire has to give up and the
        // slow path takes over.
                                        "2.2250738585072011e-308",                                 "2.2250738585072012e-308",                                  "2.4703282292062327e-324",
        "2.4703282292062328e-324",                  "1.00000000000000011102230246251565404236316680908203125", "0.500000000000000166533453693773481063544750213623046875", "0.1e1",
        "1e007",                                    "1e999999999",                                             "-0.0000000000000000000000000000000000000001e-300",         "100000000000000000000000000000000000000000000000000000000000000000000",
    };

    for (values) |value| {
        inline for ([_]type{ f16, f32, f64 }) |T| {
            const expected = try std.fmt.parseFloat(T, value);
            const actual = try parse(T, value, 0);
            try std.testing.expectEqual(@as(usize, value.len), actual.end);
            const expected_bits: [@sizeOf(T)]u8 = @bitCast(expected);
            const actual_bits: [@sizeOf(T)]u8 = @bitCast(actual.value);
            try std.testing.expectEqualSlices(u8, &expected_bits, &actual_bits);
        }
    }
}

test "invalid numbers" {
    const invalid = [_][]const u8{
        "",      "-",   "+1",  ".5",  "1.", "1e",  "1e+",
        "1e-",   "-.5", "inf", "nan", " 1", "--1", "e5",
        "1e++1", "-e1",
    };

    for (invalid) |input| {
        if (parse(f64, input, 0)) |_| {
            std.debug.print("expected a scan error for '{s}'\n", .{input});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "scan stops at trailing bytes" {
    // The scanner validates the number it starts on and leaves the next byte to
    // the caller, so malformed JSON like `01` is rejected by the container, not
    // here. This is the same contract as `Cursor.scanNumber`.
    const cases = [_]struct { input: []const u8, end: usize }{
        .{ .input = "1,2", .end = 1 },
        .{ .input = "01", .end = 1 },
        .{ .input = "1.5e3]", .end = 5 },
        .{ .input = "-0.5x", .end = 4 },
        .{ .input = "1_000", .end = 1 },
        .{ .input = "0x10", .end = 1 },
        .{ .input = "1.2.3", .end = 3 },
        .{ .input = "1e1.5", .end = 3 },
        .{ .input = "1 ", .end = 1 },
    };

    for (cases) |case| {
        const result = try parse(f64, case.input, 0);
        try std.testing.expectEqual(case.end, result.end);
    }
}

test "scan from an offset" {
    const input = "[1.25,-2.5]";
    const first = try parse(f64, input, 1);
    try std.testing.expectEqual(@as(f64, 1.25), first.value);
    try std.testing.expectEqual(@as(usize, 5), first.end);

    const second = try parse(f64, input, first.end + 1);
    try std.testing.expectEqual(@as(f64, -2.5), second.value);
    try std.testing.expectEqual(@as(usize, 10), second.end);

    try std.testing.expectError(error.UnexpectedEof, parse(f64, "1", 1));
    try std.testing.expectError(error.UnexpectedToken, parse(f64, "true", 0));
}

test "random floats match std" {
    var prng = std.Random.DefaultPrng.init(0x7a1c_5eed);
    const random = prng.random();
    const iterations = 20_000;

    var buffer: [96]u8 = undefined;
    for (0..iterations) |_| {
        const length = writeNumber(random, &buffer);
        inline for ([_]type{ f16, f32, f64 }) |T| {
            const expected = try std.fmt.parseFloat(T, buffer[0..length]);
            const actual = try parse(T, buffer[0..length], 0);
            try std.testing.expectEqual(@as(usize, length), actual.end);
            const expected_bits: [@sizeOf(T)]u8 = @bitCast(expected);
            const actual_bits: [@sizeOf(T)]u8 = @bitCast(actual.value);
            try std.testing.expectEqualSlices(u8, &expected_bits, &actual_bits);
        }
    }
}

/// Writes a random, always valid JSON number and returns its length.
///
/// The digit counts deliberately reach past the 19 significant digits a `u64`
/// holds, so truncated mantissas, dropped digits, and long runs of leading
/// zeros are all covered.
fn writeNumber(random: std.Random, out: []u8) usize {
    var length: usize = 0;

    if (random.boolean()) {
        out[length] = '-';
        length += 1;
    }

    // Either a lone zero or a nonzero leading digit followed by up to 29 more.
    const integer_digits = random.intRangeAtMost(u8, 1, 30);
    if (random.boolean()) {
        out[length] = '0';
        length += 1;
    } else {
        out[length] = '0' + random.intRangeAtMost(u8, 1, 9);
        length += 1;
        for (1..integer_digits) |_| {
            out[length] = '0' + random.intRangeAtMost(u8, 0, 9);
            length += 1;
        }
    }

    if (random.boolean()) {
        out[length] = '.';
        length += 1;
        const fraction_digits = random.intRangeAtMost(u8, 1, 30);
        for (0..fraction_digits) |_| {
            out[length] = '0' + random.intRangeAtMost(u8, 0, 9);
            length += 1;
        }
    }

    if (random.boolean()) {
        out[length] = if (random.boolean()) 'e' else 'E';
        length += 1;
        if (random.boolean()) {
            out[length] = if (random.boolean()) '+' else '-';
            length += 1;
        }
        // Short exponents stay representable; long ones saturate the scanner.
        const exponent_digits = random.intRangeAtMost(u8, 1, if (random.boolean()) 3 else 8);
        for (0..exponent_digits) |_| {
            out[length] = '0' + random.intRangeAtMost(u8, 0, 9);
            length += 1;
        }
    }

    return length;
}
