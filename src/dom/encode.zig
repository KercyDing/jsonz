//! Scalar JSON encoding shared by the compact and mutable writers.
const std = @import("std");
const float = @import("float");

/// A growable output buffer with an unchecked `reserve` + write split.
///
/// Each node reserves the most bytes it can produce and then writes without
/// further checks, so the hot path is plain stores.
pub const Buffer = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    pub inline fn reserve(self: *Buffer, additional: usize) !void {
        const required = self.list.items.len + additional;
        if (required <= self.list.capacity) return;
        try self.list.ensureTotalCapacity(self.allocator, required);
    }

    /// Appends one byte; callers reserve capacity before writing.
    pub inline fn put(self: *Buffer, byte: u8) void {
        self.list.appendAssumeCapacity(byte);
    }

    pub inline fn putAll(self: *Buffer, bytes: []const u8) void {
        const dest = self.list.unusedCapacitySlice();
        copyBytes(dest.ptr, bytes.ptr, bytes.len);
        self.list.items.len += bytes.len;
    }

    pub inline fn putSpaces(self: *Buffer, count: usize) void {
        @memset(self.list.unusedCapacitySlice()[0..count], ' ');
        self.list.items.len += count;
    }
};

/// All two-digit decimal pairs, so integers divide by 100 instead of 10.
const digit_pairs: [200]u8 = blk: {
    var table: [200]u8 = undefined;
    for (0..100) |i| {
        table[i * 2] = '0' + @as(u8, @intCast(i / 10));
        table[i * 2 + 1] = '0' + @as(u8, @intCast(i % 10));
    }
    break :blk table;
};

/// Bytes checked at once while scanning a string for characters to escape.
const escape_chunk = 32;
const EscapeVector = @Vector(escape_chunk, u8);

/// Bit `i` is set when byte `i` of the chunk needs an escape: a quote, a
/// backslash, or a control byte. DEL and non-ASCII bytes are copied through,
/// so unlike the reader's equivalent this ignores the high bit.
inline fn escapeMask(bytes: EscapeVector) u32 {
    const quote = bytes == @as(EscapeVector, @splat('"'));
    const backslash = bytes == @as(EscapeVector, @splat('\\'));
    const control = bytes < @as(EscapeVector, @splat(0x20));
    return @bitCast(quote | backslash | control);
}

/// Copies `len` bytes from `src` to `dest`.
///
/// The writer mostly copies short runs — escape sequences, integer digits, and
/// the plain gaps between escapes — so anything under 32 bytes is copied with
/// overlapping fixed-size moves instead of a call into `@memcpy`.
inline fn copyBytes(dest: [*]u8, src: [*]const u8, len: usize) void {
    @setRuntimeSafety(false);
    if (len >= 32) {
        @memcpy(dest[0..len], src[0..len]);
        return;
    }
    if (len >= 16) {
        copySized(16, dest, src);
        copySized(16, dest + len - 16, src + len - 16);
        return;
    }
    if (len >= 8) {
        copySized(8, dest, src);
        copySized(8, dest + len - 8, src + len - 8);
        return;
    }
    if (len >= 4) {
        copySized(4, dest, src);
        copySized(4, dest + len - 4, src + len - 4);
        return;
    }
    if (len == 0) return;
    if (len >= 2) {
        copySized(2, dest, src);
        copySized(2, dest + len - 2, src + len - 2);
        return;
    }
    dest[0] = src[0];
}

/// Copies exactly `size` bytes, which must be a power of two.
///
/// Both sides are declared with an alignment of one: a writer buffer and the
/// runs inside it are not guaranteed to be aligned.
inline fn copySized(comptime size: usize, dest: [*]u8, src: [*]const u8) void {
    const Bytes = [size]u8;
    @as(*align(1) Bytes, @ptrCast(dest)).* = @as(*align(1) const Bytes, @ptrCast(src)).*;
}

/// Writes `bytes` between quotes, escaping only what JSON requires when
/// `escape` is true.
pub fn writeStringBytes(buffer: *Buffer, bytes: []const u8, escape: bool) !void {
    // Worst case is six bytes per input byte, plus the quotes.
    try buffer.reserve(bytes.len * 6 + 2);
    buffer.put('"');
    if (!escape) {
        buffer.putAll(bytes);
    } else {
        // Out of line: most strings need no escaping, and growing this
        // function costs the common path more than the call costs the rare one.
        writeEscaped(buffer, bytes);
    }
    buffer.put('"');
}

/// Writes `bytes` between quotes, escaping what JSON requires.
///
/// A string that came in with an escape sequence is re-scanned 32 bytes at a
/// time, falling back to a byte loop for the last partial chunk.
fn writeEscaped(buffer: *Buffer, bytes: []const u8) void {
    // Bytes already copied through: everything before `index` that did not need
    // escaping is still pending, so the copy happens once per escape instead of
    // once per chunk.
    var start: usize = 0;
    var index: usize = 0;
    while (index + escape_chunk <= bytes.len) {
        const mask = escapeMask(bytes[index..][0..escape_chunk].*);
        if (mask == 0) {
            index += escape_chunk;
            continue;
        }
        index += @ctz(mask);
        buffer.putAll(bytes[start..index]);
        writeEscape(buffer, bytes[index]);
        index += 1;
        start = index;
    }
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte >= 0x20 and byte != '"' and byte != '\\') continue;
        buffer.putAll(bytes[start..index]);
        writeEscape(buffer, byte);
        start = index + 1;
    }
    buffer.putAll(bytes[start..]);
}

/// Writes the escape sequence for one byte that JSON cannot carry literally.
inline fn writeEscape(buffer: *Buffer, byte: u8) void {
    const digits = "0123456789ABCDEF";
    switch (byte) {
        '"' => buffer.putAll("\\\""),
        '\\' => buffer.putAll("\\\\"),
        0x08 => buffer.putAll("\\b"),
        0x0c => buffer.putAll("\\f"),
        '\n' => buffer.putAll("\\n"),
        '\r' => buffer.putAll("\\r"),
        '\t' => buffer.putAll("\\t"),
        else => buffer.putAll(&.{
            '\\',              'u',                 '0', '0',
            digits[byte >> 4], digits[byte & 0x0f],
        }),
    }
}

pub fn writeUnsigned(buffer: *Buffer, value: u64) !void {
    try buffer.reserve(20);
    var digits: [20]u8 = undefined;
    var index: usize = digits.len;
    var remaining = value;
    while (remaining >= 100) {
        const pair = (remaining % 100) * 2;
        remaining /= 100;
        index -= 2;
        digits[index] = digit_pairs[pair];
        digits[index + 1] = digit_pairs[pair + 1];
    }
    if (remaining >= 10) {
        const pair = remaining * 2;
        index -= 2;
        digits[index] = digit_pairs[pair];
        digits[index + 1] = digit_pairs[pair + 1];
    } else {
        index -= 1;
        digits[index] = '0' + @as(u8, @intCast(remaining));
    }
    buffer.putAll(digits[index..]);
}

pub fn writeSigned(buffer: *Buffer, value: i64) !void {
    try buffer.reserve(21);
    if (value < 0) {
        buffer.put('-');
        // Negating `minInt` overflows, so widen to `u64` first.
        try writeUnsigned(buffer, ~@as(u64, @bitCast(value)) + 1);
    } else {
        try writeUnsigned(buffer, @intCast(value));
    }
}

/// Writes an `f64` in the shortest form that reads back identically.
///
/// The digits come from the shortest round-tripping decimal; the notation is
/// fixed for decimal exponents in `[-6, 20]` and scientific outside it, and a
/// real is never written without a `.` or an exponent.
pub fn writeReal(buffer: *Buffer, number: f64) !void {
    var scratch: [float.maxNumberLength(f64) + 8]u8 = undefined;
    const shortest = float.formatNumberExponent(&scratch, number) catch {
        return writeRealScientific(buffer, number);
    };
    if (shortest.exponent < -6 or shortest.exponent > 20) {
        return writeRealScientific(buffer, number);
    }
    try buffer.reserve(shortest.text.len + 2);
    buffer.putAll(shortest.text);
    // A real must keep a `.` or an exponent so it reads back as a real.
    if (!shortest.has_point) buffer.putAll(".0");
}

/// The rare scientific path, also used when the fused formatter declines.
fn writeRealScientific(buffer: *Buffer, number: f64) !void {
    var scratch: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&scratch, "{e}", .{number}) catch return error.InvalidValue;
    try buffer.reserve(text.len);
    buffer.putAll(text);
}
