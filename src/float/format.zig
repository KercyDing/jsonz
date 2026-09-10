//! Shortest round-trip decimal formatting, used for JSON output.
//!
//! Produces the same text as `std.fmt`'s `{d}` with the Schubfach algorithm,
//! writing the digits eight at a time and placing the decimal point in one pass.
//! Only `f32` and `f64` are handled: anything else reports
//! `error.UnsupportedType`, and NaN or infinity `error.UnsupportedValue`,
//! because JSON has no spelling for them.
//!
//! The power-of-ten table is generated at comptime and checked against the
//! Eisel-Lemire table the parser uses.

const std = @import("std");
const eisel_lemire = @import("vendor/convert_eisel_lemire.zig");

pub const Error = error{
    /// `buf` cannot hold the longest form of this value.
    BufferTooSmall,
    /// The value is NaN or infinite.
    UnsupportedValue,
    /// `T` has no fused formatter.
    UnsupportedType,
};

/// The longest text `write` can produce for `T`, or zero if `T` is unsupported.
///
/// The bounds match `std.fmt.float.bufferSize(.decimal, T)`.
pub fn maxLength(comptime T: type) usize {
    return switch (T) {
        f32 => 55,
        f64 => 347,
        else => 0,
    };
}

/// The shortest decimal form of a float, with the decimal exponent of its most
/// significant digit (`0` for zero).
pub const Shortest = struct {
    /// Formatted text, exactly what `write` returns.
    text: []const u8,
    /// The value is `d.dddd × 10^exponent`.
    exponent: i32,
    /// Whether `text` already contains a decimal point, so a caller that must
    /// keep the value a real knows whether to append `.0`.
    has_point: bool,
};

/// Writes the shortest decimal form of `value` into `buf` and returns it.
///
/// The result matches `std.fmt`'s `{d}` exactly: never an exponent, never a
/// trailing `.0`, and negative zero keeps its sign.
pub fn write(buf: []u8, value: anytype) Error![]const u8 {
    return (try writeShortest(buf, value)).text;
}

/// Like `write`, but also reports the decimal exponent, which callers need to
/// choose between fixed and scientific notation.
pub fn writeShortest(buf: []u8, value: anytype) Error!Shortest {
    return switch (@TypeOf(value)) {
        f64 => writeF64(buf, value),
        f32 => writeF32(buf, value),
        else => error.UnsupportedType,
    };
}

fn writeF64(buf: []u8, value: f64) Error!Shortest {
    const bits: u64 = @bitCast(value);
    const negative = bits >> 63 != 0;
    const magnitude = bits & 0x7FFF_FFFF_FFFF_FFFF;

    const exponent_bits: u32 = @intCast((magnitude >> 52) & 0x7FF);
    const significand_bits = magnitude & 0x000F_FFFF_FFFF_FFFF;

    if (exponent_bits == 0x7FF) return error.UnsupportedValue;
    if (magnitude == 0) return writeZero(buf, negative);

    const decimal = if (exponent_bits == 0)
        // Subnormal: no implicit leading bit, and the exponent is pinned.
        f64ToDecimal(significand_bits, 0, significand_bits, -1074)
    else
        f64ToDecimal(
            significand_bits,
            exponent_bits,
            significand_bits | (@as(u64, 1) << 52),
            @as(i32, @intCast(exponent_bits)) - 1075,
        );

    return emit(buf, negative, decimal);
}

fn writeF32(buf: []u8, value: f32) Error!Shortest {
    const bits: u32 = @bitCast(value);
    const negative = bits >> 31 != 0;
    const magnitude = bits & 0x7FFF_FFFF;

    const exponent_bits: u32 = (magnitude >> 23) & 0xFF;
    const significand_bits = magnitude & 0x007F_FFFF;

    if (exponent_bits == 0xFF) return error.UnsupportedValue;
    if (magnitude == 0) return writeZero(buf, negative);

    const decimal = if (exponent_bits == 0)
        f32ToDecimal(significand_bits, 0, significand_bits, -149)
    else
        f32ToDecimal(
            significand_bits,
            exponent_bits,
            significand_bits | (@as(u32, 1) << 23),
            @as(i32, @intCast(exponent_bits)) - 150,
        );

    return emit(buf, negative, decimal);
}

fn writeZero(buf: []u8, negative: bool) Error!Shortest {
    const required: usize = if (negative) 2 else 1;
    if (buf.len < required) return error.BufferTooSmall;
    if (negative) {
        buf[0] = '-';
        buf[1] = '0';
        return .{ .text = buf[0..2], .exponent = 0, .has_point = false };
    }
    buf[0] = '0';
    return .{ .text = buf[0..1], .exponent = 0, .has_point = false };
}

/// Significant digits and their decimal exponent: the value is
/// `significand × 10^exponent`.
const Decimal = struct {
    significand: u64,
    exponent: i32,
};

/// Schubfach: the shortest decimal that round-trips to the same `f64`.
///
/// `significand_bits` and `exponent_bits` are the raw bit fields;
/// `binary_significand × 2^binary_exponent` is the same value written as a
/// binary float.
fn f64ToDecimal(
    significand_bits: u64,
    exponent_bits: u32,
    binary_significand: u64,
    binary_exponent: i32,
) Decimal {
    // Fast path: a nonzero fraction field means the value is not an exact power
    // of two, so its neighbours are evenly spaced and the candidate window has
    // a closed form. Exact powers of two fall through to Schubfach because the
    // spacing below them is halved.
    fast: {
        if (significand_bits == 0) break :fast;

        // k = floor(log10(2^binary_exponent)), h = the remaining power of two.
        const k = (binary_exponent *% 315653) >> 20;
        const h = binary_exponent + ((-k *% 217707) >> 16);
        const power = pow10(-k);

        const scaled = binary_significand << @intCast(h + 1);
        const low_product = @as(u128, scaled) * power.lo;
        const high_product = @as(u128, scaled) * power.hi + @as(u64, @truncate(low_product >> 64));
        const upper: u64 = @truncate(high_product >> 64);
        const lower: u64 = @truncate(high_product);

        // The middle digit, and the candidates one unit away from it.
        const modulus = upper % 10;
        const truncated = upper - modulus;
        const center = (modulus << 60) | (lower >> 4);
        const half_ulp = power.hi >> @intCast(4 - h);

        const upper_inside = lower >= (1 << 63);
        if (lower == (1 << 63)) break :fast;
        const lower_inside = half_ulp >= center;
        if (half_ulp == center) break :fast;
        const limit = @as(u64, 10) << 60;
        const reach = center +% half_ulp;
        const carry_inside = reach >= limit;
        if (limit -% reach <= 1) break :fast;

        const trim = lower_inside or carry_inside;
        const add_ten = if (carry_inside) @as(u64, 10) else 0;
        const add_one = modulus + @intFromBool(upper_inside);
        return .{
            .significand = truncated + (if (trim) add_ten else add_one),
            .exponent = k,
        };
    }

    // Schubfach, from "The Schubfach way to render doubles" (Giulietti, 2022).
    const irregular = significand_bits == 0 and exponent_bits > 1;
    const is_even = binary_significand & 1 == 0;
    const below = 4 * binary_significand - 2 + @intFromBool(irregular);
    const center = 4 * binary_significand;
    const above = 4 * binary_significand + 2;

    // k = floor(log10(2^binary_exponent)) with an allowance for the halved
    // spacing below; h = the remaining power of two.
    const k = (binary_exponent *% 315653 - (if (irregular) @as(i32, 131237) else 0)) >> 20;
    const h = binary_exponent + ((-k *% 217707) >> 16) + 1;
    const power = pow10(-k);
    const half_ulp = power.lo +% 1;

    const lower_bound = roundToOdd64(power.hi, half_ulp, below << @intCast(h));
    const middle = roundToOdd64(power.hi, half_ulp, center << @intCast(h));
    const upper_bound = roundToOdd64(power.hi, half_ulp, above << @intCast(h));
    const lower = lower_bound + @intFromBool(!is_even);
    const upper = upper_bound - @intFromBool(!is_even);

    // Step 5: pick the shortest of the three candidates.
    const candidate = middle / 4;
    if (candidate >= 10) {
        const trimmed = candidate / 10;
        const lower_inside = lower <= 40 * trimmed;
        const upper_inside = upper >= 40 * trimmed + 40;
        if (lower_inside != upper_inside) {
            return .{
                .significand = trimmed * 10 + (if (upper_inside) @as(u64, 10) else 0),
                .exponent = k,
            };
        }
    }
    const lower_inside = lower <= 4 * candidate;
    const upper_inside = upper >= 4 * candidate + 4;
    const middle_digit = 4 * candidate + 2;
    const round_up = middle > middle_digit or (middle == middle_digit and (candidate & 1) != 0);
    return .{
        .significand = candidate + (if (lower_inside != upper_inside) @intFromBool(upper_inside) else @intFromBool(round_up)),
        .exponent = k,
    };
}

/// `f32` counterpart of `f64ToDecimal`.
fn f32ToDecimal(
    significand_bits: u32,
    exponent_bits: u32,
    binary_significand: u32,
    binary_exponent: i32,
) Decimal {
    fast: {
        if (significand_bits == 0) break :fast;

        const k = (binary_exponent *% 315653) >> 20;
        const h = binary_exponent + ((-k *% 217707) >> 16);
        const power = pow10(-k);

        const scaled = binary_significand << @intCast(h + 1);
        const product = @as(u128, scaled) * power.hi;
        const upper: u32 = @truncate(product >> 64);
        const lower: u32 = @truncate(product >> 32);

        const modulus = upper % 10;
        const truncated = upper - modulus;
        const center = (modulus << 28) | (lower >> 4);
        const half_ulp: u32 = @truncate(power.hi >> @intCast(36 - h));

        const upper_inside = lower >= (1 << 31);
        if (lower == (1 << 31)) break :fast;
        const lower_inside = half_ulp >= center;
        if (half_ulp == center) break :fast;
        const limit = @as(u32, 10) << 28;
        const reach = center +% half_ulp;
        const carry_inside = reach >= limit;
        if (limit -% reach <= 1) break :fast;

        const trim = lower_inside or carry_inside;
        const add_ten = if (carry_inside) @as(u32, 10) else 0;
        const add_one = modulus + @intFromBool(upper_inside);
        return .{
            .significand = truncated + (if (trim) add_ten else add_one),
            .exponent = k,
        };
    }

    const irregular = significand_bits == 0 and exponent_bits > 1;
    const is_even = binary_significand & 1 == 0;
    const below = 4 * binary_significand - 2 + @intFromBool(irregular);
    const center = 4 * binary_significand;
    const above = 4 * binary_significand + 2;

    const k = (binary_exponent *% 315653 - (if (irregular) @as(i32, 131237) else 0)) >> 20;
    const h = binary_exponent + ((-k *% 217707) >> 16) + 1;
    const power = pow10(-k);
    const half_ulp: u64 = power.hi + 1;

    const lower_bound = roundToOdd32(half_ulp, below << @intCast(h));
    const middle = roundToOdd32(half_ulp, center << @intCast(h));
    const upper_bound = roundToOdd32(half_ulp, above << @intCast(h));
    const lower = lower_bound + @intFromBool(!is_even);
    const upper = upper_bound - @intFromBool(!is_even);

    const candidate = middle / 4;
    if (candidate >= 10) {
        const trimmed = candidate / 10;
        const lower_inside = lower <= 40 * trimmed;
        const upper_inside = upper >= 40 * trimmed + 40;
        if (lower_inside != upper_inside) {
            return .{
                .significand = trimmed * 10 + (if (upper_inside) @as(u32, 10) else 0),
                .exponent = k,
            };
        }
    }
    const lower_inside = lower <= 4 * candidate;
    const upper_inside = upper >= 4 * candidate + 4;
    const middle_digit = 4 * candidate + 2;
    const round_up = middle > middle_digit or (middle == middle_digit and (candidate & 1) != 0);
    return .{
        .significand = candidate + (if (lower_inside != upper_inside) @intFromBool(upper_inside) else @intFromBool(round_up)),
        .exponent = k,
    };
}

/// The high 64 bits of `scaled × (high, low)`, rounded up to odd.
inline fn roundToOdd64(high: u64, low: u64, scaled: u64) u64 {
    const product = @as(u128, scaled) * high + (@as(u128, scaled) * low >> 64);
    const result_high: u64 = @truncate(product >> 64);
    const result_low: u64 = @truncate(product);
    return result_high | @intFromBool(result_low > 1);
}

/// The high 32 bits of `scaled × significand`, rounded up to odd.
inline fn roundToOdd32(significand: u64, scaled: u32) u32 {
    const product = @as(u128, scaled) * significand;
    const high: u32 = @truncate(product >> 64);
    const low: u32 = @truncate(product >> 32);
    return high | @intFromBool(low > 1);
}

/// Renders `decimal` in the layout `std.fmt`'s decimal mode uses: plain
/// digits, a decimal point placed by position, and no exponent.
fn emit(buf: []u8, negative: bool, decimal: Decimal) Error!Shortest {
    // The digit selection is shortest but may leave trailing zeros: `1.0`
    // arrives as `10000000000000000e-16`. Dropping them never changes the value
    // and keeps the output as short as `{d}`'s.
    var significand = decimal.significand;
    var exponent = decimal.exponent;
    while (significand % 10 == 0) {
        significand /= 10;
        exponent += 1;
    }

    const length = digitCount(significand);
    const point = exponent + @as(i32, @intCast(length));
    const sign: usize = @intFromBool(negative);
    const required: usize = sign + if (point <= 0)
        2 + @as(usize, @intCast(-point)) + length
    else if (point >= @as(i32, @intCast(length)))
        @as(usize, @intCast(point))
    else
        length + 1;
    if (buf.len < required) return error.BufferTooSmall;

    if (negative) buf[0] = '-';

    if (point <= 0) {
        // 0.0001234
        const zeros: usize = @intCast(-point);
        buf[sign] = '0';
        buf[sign + 1] = '.';
        @memset(buf[sign + 2 ..][0..zeros], '0');
        writeDigits(buf[sign + 2 + zeros ..], significand, length);
        return .{
            .text = buf[0 .. sign + 2 + zeros + length],
            .exponent = point - 1,
            .has_point = true,
        };
    }

    if (point >= @as(i32, @intCast(length))) {
        // 123400000
        const zeros: usize = @as(usize, @intCast(point)) - length;
        writeDigits(buf[sign..], significand, length);
        @memset(buf[sign + length ..][0..zeros], '0');
        return .{
            .text = buf[0 .. sign + length + zeros],
            .exponent = point - 1,
            .has_point = false,
        };
    }

    // 123.456. Writing the digits one byte late leaves every digit after the
    // point already in its final place, so only the digits before it have to
    // move, and only by one byte. `moveBack` reads each word before storing it,
    // which keeps the overlap harmless.
    const head: usize = @intCast(point);
    writeDigits(buf[sign + 1 ..], significand, length);
    moveBack(buf[sign..], buf[sign + 1 ..], head);
    buf[sign + head] = '.';
    return .{
        .text = buf[0 .. sign + length + 1],
        .exponent = point - 1,
        .has_point = true,
    };
}

/// Copies `count` bytes from `source` to `destination`, where `destination`
/// starts `count` bytes earlier.
fn moveBack(destination: []u8, source: []const u8, count: usize) void {
    var copied: usize = 0;
    while (copied + 8 <= count) : (copied += 8) {
        const word: u64 = @bitCast(source[copied..][0..8].*);
        destination[copied..][0..8].* = @bitCast(word);
    }
    while (copied < count) : (copied += 1) destination[copied] = source[copied];
}

/// Writes the `length` digits of `value` into `buf[0..length]`, most
/// significant digit first.
fn writeDigits(buf: []u8, value: u64, length: usize) void {
    // A significand has at most 17 digits, so one 64-bit split leaves a high
    // part that fits in 32 bits and the rest can use cheaper 32-bit arithmetic.
    var rest = value;
    var index = length;
    if (index > 8) {
        index -= 8;
        writeEight(buf[index..][0..8], @intCast(rest % 100_000_000));
        rest /= 100_000_000;
    }

    var small: u32 = @intCast(rest);
    if (index >= 8) {
        index -= 8;
        writeEight(buf[index..][0..8], small % 100_000_000);
        small /= 100_000_000;
    }
    while (index >= 2) {
        index -= 2;
        writeTwo(buf[index..][0..2], @intCast(small % 100));
        small /= 100;
    }
    if (index == 1) buf[0] = '0' + @as(u8, @intCast(small));
}

/// Number of decimal digits in `value`, which must not be zero.
inline fn digitCount(value: u64) usize {
    const bits: u32 = 64 - @as(u32, @clz(value));
    const guess: usize = (bits * 1233) >> 12;
    return guess + @intFromBool(value >= powers_of_ten[guess]);
}

const powers_of_ten = [_]u64{
    1,
    10,
    100,
    1000,
    10000,
    100000,
    1000000,
    10000000,
    100000000,
    1000000000,
    10000000000,
    100000000000,
    1000000000000,
    10000000000000,
    100000000000000,
    1000000000000000,
    10000000000000000,
    100000000000000000,
    1000000000000000000,
    10000000000000000000,
};

/// Writes exactly eight digits of `value`, which must be at least `10000000`.
inline fn writeEight(buf: *[8]u8, value: u32) void {
    const high: u32 = @intCast((@as(u64, value) * 109951163) >> 40); // value / 10000
    const low = value - high * 10000;
    const high_pairs = (high * 5243) >> 19; // high / 100
    const low_pairs = (low * 5243) >> 19; // low / 100
    writeTwo(buf[0..2], high_pairs);
    writeTwo(buf[2..4], high - high_pairs * 100);
    writeTwo(buf[4..6], low_pairs);
    writeTwo(buf[6..8], low - low_pairs * 100);
}

inline fn writeTwo(buf: *[2]u8, value: u32) void {
    buf.* = digit_pairs[value];
}

const digit_pairs = blk: {
    var table: [100][2]u8 = undefined;
    for (&table, 0..) |*entry, value| {
        entry.* = .{ '0' + @as(u8, value / 10), '0' + @as(u8, value % 10) };
    }
    break :blk table;
};

const Power = struct { hi: u64, lo: u64 };

/// The 128 most significant bits of `10^k`, normalised so bit 127 is set.
///
/// `10^k` and `5^k` normalise to the same bits, which is why `convert`
/// below can check the low end of this table against the parser's
/// Eisel-Lemire table.
fn pow10(exponent: i32) Power {
    std.debug.assert(exponent >= min_power and exponent <= max_power);
    return pow10_table[@intCast(exponent - min_power)];
}

const min_power = -343;
const max_power = 324;

/// Generated at comptime rather than stored as a literal: the same values are
/// already in the parser's Eisel-Lemire table, and the assert below proves the
/// generator agrees with it.
const pow10_table = blk: {
    @setEvalBranchQuota(10_000_000);
    var table: [max_power - min_power + 1]Power = undefined;
    for (&table, 0..) |*entry, index| {
        const exponent = min_power + @as(i32, @intCast(index));
        entry.* = pow10Entry(exponent);
        if (exponent >= eisel_lemire_min_power and exponent <= eisel_lemire_max_power) {
            // The vendored table names its halves for the algorithm that
            // consumes them: `lo` holds the most significant 64 bits (see
            // `U128.mul` and `computeProductApprox`). It also rounds its
            // significands to nearest, while Schubfach needs them truncated, so
            // the two agree to within one unit in the last place. Proving they
            // do is what catches a generator that lands on the wrong exponent.
            const reference =
                eisel_lemire.eisel_lemire_table_powers_of_five_128[exponent - eisel_lemire_min_power];
            const rounded = (@as(u128, reference.lo) << 64) | reference.hi;
            const truncated = (@as(u128, entry.hi) << 64) | entry.lo;
            std.debug.assert(rounded - truncated <= 1);
        }
    }
    break :blk table;
};

const eisel_lemire_min_power = -342;
const eisel_lemire_max_power = 308;

fn pow10Entry(comptime exponent: i32) Power {
    const magnitude: comptime_int = if (exponent < 0) -exponent else exponent;
    const power_of_five: comptime_int = powInt(5, magnitude);

    // Normalise so that bit 127 is set, truncating towards zero.
    const signature: comptime_int = if (exponent >= 0) signature: {
        const top = bitLength(power_of_five) - 1;
        break :signature if (top >= 127)
            power_of_five >> (top - 127)
        else
            power_of_five << (127 - top);
    } else signature: {
        break :signature (@as(comptime_int, 1) << (127 + bitLength(power_of_five))) / power_of_five;
    };

    return .{
        .hi = @intCast(signature >> 64),
        .lo = @intCast(signature & 0xFFFF_FFFF_FFFF_FFFF),
    };
}

fn powInt(comptime base: comptime_int, comptime exponent: comptime_int) comptime_int {
    var result: comptime_int = 1;
    for (0..exponent) |_| result *= base;
    return result;
}

fn bitLength(comptime value: comptime_int) comptime_int {
    var rest = value;
    var length: comptime_int = 0;
    while (rest != 0) : (rest >>= 1) length += 1;
    return length;
}

test "matches std.fmt {d}" {
    const values = [_]f64{
        0.0,                -0.0,                    1.0,                     -1.0,                0.5,                    0.1,
        0.3,                1.5,                     2.0,                     10.0,                100.0,                  123.0,
        1e21,               1e22,                    1e-7,                    1e-6,                1.7976931348623157e308, 5e-324,
        2.5e-324,           4.9406564584124654e-324, 2.2250738585072014e-308, 0.1,                 0.2,                    0.30000000000000004,
        3.141592653589793,  2.718281828459045,       65.613616999999977,      -65.613616999999977, 43.420273000000009,     -123456.789,
        9007199254740992.0, 9007199254740993.0,      1e-300,                  1e300,
    };
    for (values) |value| try expectMatch(f64, value, @as(u64, @bitCast(value)));

    const f32_values = [_]f32{
        0.0,   -0.0,          1.0,        -1.0,       0.1,        0.5, 3.4028235e38,
        1e-45, 1.1754944e-38, 16777216.0, 16777217.0, -65.613617,
    };
    for (f32_values) |value| try expectMatch(f32, value, @as(u32, @bitCast(value)));
}

test "every f32 exponent" {
    // The roundings that decide the digits all change at exponent boundaries.
    var exponent: u32 = 0;
    while (exponent <= 0xFE) : (exponent += 1) {
        for ([_]u32{ 0, 1, 2, 3, 0x40_0000, 0x55_5555, 0x7F_FFFE, 0x7F_FFFF }) |significand| {
            const bits = (exponent << 23) | significand;
            try expectMatch(f32, @bitCast(bits), bits);
        }
    }
}

test "sampled bit patterns" {
    var prng = std.Random.DefaultPrng.init(0x5eed_f10a);
    const random = prng.random();
    const iterations: usize = if (std.debug.runtime_safety) 20_000 else 500_000;

    for (0..iterations) |_| {
        const bits = random.int(u32);
        const value: f32 = @bitCast(bits);
        if (std.math.isFinite(value)) try expectMatch(f32, value, bits);
    }
    for (0..iterations) |_| {
        const bits = random.int(u64);
        const value: f64 = @bitCast(bits);
        if (std.math.isFinite(value)) try expectMatch(f64, value, bits);
    }
}

/// Formats `value` both ways and asserts the text is identical.
fn expectMatch(comptime T: type, value: T, bits: anytype) !void {
    var expected_buffer: [400]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{d}", .{value});

    var actual_buffer: [maxLength(T)]u8 = undefined;
    const actual = write(&actual_buffer, value) catch |err| {
        std.debug.print("{s} write({d}) failed: {}\n", .{ @typeName(T), value, err });
        return error.TestUnexpectedResult;
    };

    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print("0x{x:0>16} ({d}): expected '{s}', got '{s}'\n", .{ bits, value, expected, actual });
        return error.TestUnexpectedResult;
    }
    const reparsed = std.fmt.parseFloat(T, actual) catch {
        std.debug.print("'{s}' does not parse back\n", .{actual});
        return error.TestUnexpectedResult;
    };
    if (value != 0 and reparsed != value) {
        std.debug.print("{d} does not round trip through '{s}'\n", .{ value, actual });
        return error.TestUnexpectedResult;
    }
}
