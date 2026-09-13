const std = @import("std");
const float = @import("float");
const pool_mod = @import("pool.zig");
const value_mod = @import("view.zig");

/// Options that control DOM serialization.
pub const WriteOptions = struct {
    /// Format objects and arrays with four-space indentation and line breaks.
    pretty: bool = false,
};

/// A container still being written, with the sibling count left in its parent.
const Frame = struct {
    remaining: usize,
    object: bool,
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

/// A growable output buffer with an unchecked `reserve` + write split.
///
/// Each value reserves the most bytes it can produce and then writes without
/// further checks, so the hot path is plain stores.
const Buffer = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    inline fn reserve(self: *Buffer, additional: usize) !void {
        const required = self.list.items.len + additional;
        if (required <= self.list.capacity) return;
        try self.list.ensureTotalCapacity(self.allocator, required);
    }

    /// Appends one byte; callers reserve capacity before writing.
    inline fn put(self: *Buffer, byte: u8) void {
        self.list.appendAssumeCapacity(byte);
    }

    inline fn putAll(self: *Buffer, bytes: []const u8) void {
        const dest = self.list.unusedCapacitySlice();
        copyBytes(dest.ptr, bytes.ptr, bytes.len);
        self.list.items.len += bytes.len;
    }

    inline fn putSpaces(self: *Buffer, count: usize) void {
        @memset(self.list.unusedCapacitySlice()[0..count], ' ');
        self.list.items.len += count;
    }
};

/// Serializes `value` to a newly allocated JSON byte slice owned by `allocator`.
pub fn toSlice(
    allocator: std.mem.Allocator,
    value: value_mod.DocView,
    options: WriteOptions,
) ![]u8 {
    var buffer: Buffer = .{ .allocator = allocator };
    errdefer buffer.list.deinit(allocator);
    // The source length is a good output hint, so the buffer rarely grows.
    const estimate = if (options.pretty)
        value.storage.input.len * 2 + 64
    else
        value.storage.input.len + 64;
    try buffer.list.ensureTotalCapacity(allocator, estimate);
    try write(&buffer, value, options, allocator);
    return buffer.list.toOwnedSlice(allocator);
}

/// Serializes `value` to `writer`.
pub fn toWriter(
    writer: *std.Io.Writer,
    value: value_mod.DocView,
    options: WriteOptions,
) !void {
    // The document is buffered and flushed once, which keeps this on the same
    // fast path as `toSlice`.
    const output = try toSlice(std.heap.smp_allocator, value, options);
    defer std.heap.smp_allocator.free(output);
    try writer.writeAll(output);
}

/// Writes `value`, iteratively so document depth cannot overflow the stack.
///
/// The traversal pushes container frames on an explicit stack and emits
/// separators before each value instead of overwriting them afterwards.
fn write(
    buffer: *Buffer,
    value: value_mod.DocView,
    options: WriteOptions,
    allocator: std.mem.Allocator,
) !void {
    const values = value.storage.values;
    const input = value.storage.input;
    const root = values[value.index];
    const root_type = pool_mod.valueType(root);
    if ((root_type != .array and root_type != .object) or pool_mod.valueLen(root) == 0) {
        return writeSingle(buffer, input, root);
    }

    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);

    var object = root_type == .object;
    var remaining: usize = if (object) pool_mod.valueLen(root) * 2 else pool_mod.valueLen(root);
    var first = true;
    var level: usize = 1;
    var index = value.index + 1;

    try buffer.reserve(2);
    buffer.put(if (object) '{' else '[');
    if (options.pretty) buffer.put('\n');

    while (true) {
        const item = values[index];
        const item_type = pool_mod.valueType(item);
        const is_key = object and remaining % 2 == 0;

        if (!first) {
            try buffer.reserve(2);
            if (is_key) {
                // The previous slot was an object value.
                buffer.put(',');
                if (options.pretty) buffer.put('\n');
            } else if (object) {
                // This slot is an object value, directly after its key.
                buffer.put(':');
                if (options.pretty) buffer.put(' ');
            } else {
                buffer.put(',');
                if (options.pretty) buffer.put('\n');
            }
        }
        // Object values stay on their key's line; keys and array elements do not.
        if (options.pretty and !(object and !is_key)) {
            try buffer.reserve(level * 4);
            buffer.putSpaces(level * 4);
        }
        first = false;

        switch (item_type) {
            .string => try writeString(buffer, input, item),
            .number => try writeNumber(buffer, item),
            .bool => {
                try buffer.reserve(5);
                buffer.putAll(if (pool_mod.valueSubtype(item) == pool_mod.true_value) "true" else "false");
            },
            .null => {
                try buffer.reserve(4);
                buffer.putAll("null");
            },
            .array, .object => {
                const child_object = item_type == .object;
                const child_len = pool_mod.valueLen(item);
                if (child_len == 0) {
                    try buffer.reserve(2);
                    buffer.putAll(if (child_object) "{}" else "[]");
                } else {
                    try stack.append(allocator, .{ .remaining = remaining, .object = object });
                    object = child_object;
                    remaining = if (object) child_len * 2 else child_len;
                    first = true;
                    try buffer.reserve(2);
                    buffer.put(if (object) '{' else '[');
                    if (options.pretty) {
                        buffer.put('\n');
                        level += 1;
                    }
                    index += 1;
                    continue;
                }
            },
            else => unreachable,
        }

        index += 1;
        remaining -= 1;
        if (remaining != 0) continue;

        // Close this container and every parent that just ended with it.
        while (true) {
            if (options.pretty) {
                try buffer.reserve(level * 4 + 2);
                buffer.put('\n');
                level -= 1;
                buffer.putSpaces(level * 4);
            } else {
                try buffer.reserve(1);
            }
            buffer.put(if (object) '}' else ']');
            const frame = stack.pop() orelse return;
            object = frame.object;
            remaining = frame.remaining - 1;
            first = false;
            if (remaining != 0) break;
        }
    }
}

/// Writes a value that is not a non-empty container.
fn writeSingle(buffer: *Buffer, input: []const u8, item: pool_mod.Value) !void {
    switch (pool_mod.valueType(item)) {
        .string => try writeString(buffer, input, item),
        .number => try writeNumber(buffer, item),
        .bool => {
            try buffer.reserve(5);
            buffer.putAll(if (pool_mod.valueSubtype(item) == pool_mod.true_value) "true" else "false");
        },
        .null => {
            try buffer.reserve(4);
            buffer.putAll("null");
        },
        .array => {
            try buffer.reserve(2);
            buffer.putAll("[]");
        },
        .object => {
            try buffer.reserve(2);
            buffer.putAll("{}");
        },
        else => unreachable,
    }
}

/// Writes one UTF-8 string, escaping only what JSON requires.
///
/// Escapes `"`, `\`, and the C0 control characters, using uppercase hex for
/// `\u00XX`; every other byte, including DEL and any valid multi-byte sequence,
/// is copied through.
inline fn writeString(buffer: *Buffer, input: []const u8, item: pool_mod.Value) !void {
    const offset: usize = @intCast(item.payload.offset);
    const bytes = input[offset..][0..pool_mod.valueLen(item)];

    // Worst case is six bytes per input byte, plus the quotes.
    try buffer.reserve(bytes.len * 6 + 2);
    buffer.put('"');
    if (pool_mod.valueSubtype(item) == pool_mod.no_escape) {
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

inline fn writeNumber(buffer: *Buffer, item: pool_mod.Value) !void {
    switch (pool_mod.valueSubtype(item)) {
        .real => try writeReal(buffer, item.payload.float),
        .one => {
            try buffer.reserve(21);
            writeSigned(buffer, item.payload.int);
        },
        .none => {
            try buffer.reserve(20);
            writeUnsigned(buffer, item.payload.uint);
        },
    }
}

inline fn writeUnsigned(buffer: *Buffer, value: u64) void {
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

inline fn writeSigned(buffer: *Buffer, value: i64) void {
    if (value < 0) {
        buffer.put('-');
        // Negating `minInt` overflows, so widen to `u64` first.
        writeUnsigned(buffer, ~@as(u64, @bitCast(value)) + 1);
    } else {
        writeUnsigned(buffer, @intCast(value));
    }
}

/// Writes an `f64` in the shortest form that reads back identically.
///
/// The digits come from the shortest round-tripping decimal; the notation is
/// fixed for decimal exponents in `[-6, 20]` and scientific outside it, and a
/// real is never written without a `.` or an exponent.
fn writeReal(buffer: *Buffer, number: f64) !void {
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

test "minified output" {
    try expectWrite("{\"a\":1,\"b\":[true,null,\"x\"]}", "{\"a\": 1, \"b\": [true, null, \"x\"]}", false);
    try expectWrite("[]", "[]", false);
    try expectWrite("{}", "{}", false);
    try expectWrite("0", "0", false);
}

test "pretty output" {
    try expectWrite(
        \\{
        \\    "a": [
        \\        1,
        \\        2
        \\    ],
        \\    "b": {
        \\        "c": null
        \\    },
        \\    "d": "x"
        \\}
    , "{\"a\":[1,2],\"b\":{\"c\":null},\"d\":\"x\"}", true);
    try expectWrite(
        \\{
        \\    "a": [],
        \\    "b": {}
        \\}
    , "{\"a\":[],\"b\":{}}", true);
}

test "float formatting" {
    try expectWrite("1.0", "1.0", false);
    try expectWrite("1000.0", "1e3", false);
    try expectWrite("0.001", "1e-3", false);
    try expectWrite("0.000001", "1e-6", false);
    try expectWrite("1e-7", "1e-7", false);
    try expectWrite("1e21", "1e21", false);
    try expectWrite("100000000000000000000.0", "1e20", false);
    try expectWrite("-0.0", "-0.0", false);
    try expectWrite("1", "1", false);
    try expectWrite("-9223372036854775808", "-9223372036854775808", false);
    try expectWrite("18446744073709551615", "18446744073709551615", false);
}

test "string escaping" {
    try expectWrite("\"a\\nb\"", "\"a\\nb\"", false);
    try expectWrite("\"\\u0001\\u001F\"", "\"\\u0001\\u001f\"", false);
    // A slash escape is decoded but never re-escaped.
    try expectWrite("\"/\"", "\"\\/\"", false);
    try expectWrite("\"\\\"\\\\\"", "\"\\\"\\\\\"", false);
}

fn expectWrite(expected: []const u8, input: []const u8, pretty: bool) !void {
    var document = try @import("document.zig").parse(std.testing.allocator, input, .{});
    defer document.deinit();
    const output = try document.toSlice(std.testing.allocator, .{ .pretty = pretty });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "escapes across vector chunks" {
    // Canonical escapes sitting at offsets that straddle the 32-byte scan
    // chunk must round-trip byte for byte.
    const pieces = [_][]const u8{
        "\\n", "\\u0001", "\\\"", "\\\\", "\\t", "\\r", "\\b", "\\f",
    };
    for ([_]usize{ 0, 15, 30, 31, 32, 33, 62, 63, 64, 65, 96 }) |offset| {
        var buffer: [512]u8 = undefined;
        var length: usize = 0;
        buffer[length] = '"';
        length += 1;
        for (0..offset) |_| {
            buffer[length] = 'a';
            length += 1;
        }
        for (pieces) |piece| {
            @memcpy(buffer[length..][0..piece.len], piece);
            length += piece.len;
        }
        // A plain run longer than one chunk between escapes.
        for (0..70) |_| {
            buffer[length] = 'b';
            length += 1;
        }
        @memcpy(buffer[length..][0..2], "\\n");
        length += 2;
        buffer[length] = '"';
        length += 1;
        const input = buffer[0..length];
        try expectWrite(input, input, false);
    }
}
