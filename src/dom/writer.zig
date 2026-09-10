const std = @import("std");
const float = @import("float");
const pool_mod = @import("pool.zig");
const value_mod = @import("value.zig");

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

/// Serializes `value` to a newly allocated JSON byte slice owned by `allocator`.
pub fn toSlice(
    allocator: std.mem.Allocator,
    value: value_mod.Value,
    options: WriteOptions,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try write(&out.writer, value, options, allocator);
    return out.toOwnedSlice();
}

/// Serializes `value` to `writer` without allocating an output slice.
pub fn toWriter(
    writer: *std.Io.Writer,
    value: value_mod.Value,
    options: WriteOptions,
) !void {
    return write(writer, value, options, std.heap.smp_allocator);
}

/// Writes `value`, iteratively so document depth cannot overflow the stack.
///
/// The traversal mirrors yyjson's writer: container frames are pushed on an
/// explicit stack, and separators are emitted before each value instead of
/// being overwritten afterwards.
fn write(
    writer: *std.Io.Writer,
    value: value_mod.Value,
    options: WriteOptions,
    allocator: std.mem.Allocator,
) !void {
    const values = value.storage.values;
    const input = value.storage.input;
    const root = values[value.index];
    const root_type = pool_mod.valueType(root);
    if ((root_type != .array and root_type != .object) or pool_mod.valueLen(root) == 0) {
        return writeSingle(writer, input, root);
    }

    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);

    var object = root_type == .object;
    var remaining: usize = if (object) pool_mod.valueLen(root) * 2 else pool_mod.valueLen(root);
    var first = true;
    var level: usize = 1;
    var index = value.index + 1;

    try writer.writeByte(if (object) '{' else '[');
    if (options.pretty) try writer.writeByte('\n');

    while (true) {
        const item = values[index];
        const item_type = pool_mod.valueType(item);
        const is_key = object and remaining % 2 == 0;

        if (!first) {
            if (is_key) {
                // The previous slot was an object value.
                try writer.writeByte(',');
                if (options.pretty) try writer.writeByte('\n');
            } else if (object) {
                // This slot is an object value, directly after its key.
                try writer.writeAll(if (options.pretty) ": " else ":");
            } else {
                try writer.writeByte(',');
                if (options.pretty) try writer.writeByte('\n');
            }
        }
        // Object values stay on their key's line; keys and array elements do not.
        if (options.pretty and !(object and !is_key)) try writeIndent(writer, level);
        first = false;

        switch (item_type) {
            .string => try writeString(writer, input, item),
            .number => try writeNumber(writer, item),
            .bool => try writer.writeAll(
                if (pool_mod.valueSubtype(item) == pool_mod.true_value) "true" else "false",
            ),
            .null => try writer.writeAll("null"),
            .array, .object => {
                const child_object = item_type == .object;
                const child_len = pool_mod.valueLen(item);
                if (child_len == 0) {
                    try writer.writeAll(if (child_object) "{}" else "[]");
                } else {
                    try stack.append(allocator, .{ .remaining = remaining, .object = object });
                    object = child_object;
                    remaining = if (object) child_len * 2 else child_len;
                    first = true;
                    try writer.writeByte(if (object) '{' else '[');
                    if (options.pretty) {
                        try writer.writeByte('\n');
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
                try writer.writeByte('\n');
                level -= 1;
                try writeIndent(writer, level);
            }
            try writer.writeByte(if (object) '}' else ']');
            const frame = stack.pop() orelse return;
            object = frame.object;
            remaining = frame.remaining - 1;
            first = false;
            if (remaining != 0) break;
        }
    }
}

/// Writes a value that is not a non-empty container.
fn writeSingle(writer: *std.Io.Writer, input: []const u8, item: pool_mod.Value) !void {
    switch (pool_mod.valueType(item)) {
        .string => try writeString(writer, input, item),
        .number => try writeNumber(writer, item),
        .bool => try writer.writeAll(
            if (pool_mod.valueSubtype(item) == pool_mod.true_value) "true" else "false",
        ),
        .null => try writer.writeAll("null"),
        .array => try writer.writeAll("[]"),
        .object => try writer.writeAll("{}"),
        else => unreachable,
    }
}

/// Writes one UTF-8 string, escaping only what JSON requires.
///
/// yyjson's default writer escapes `"`, `\`, and the C0 control characters,
/// using uppercase hex for `\u00XX`; every other byte, including DEL and any
/// valid multi-byte sequence, is copied through.
fn writeString(writer: *std.Io.Writer, input: []const u8, item: pool_mod.Value) !void {
    const offset: usize = @intCast(item.uni.offset);
    const bytes = input[offset..][0..pool_mod.valueLen(item)];

    try writer.writeByte('"');
    if (pool_mod.valueSubtype(item) == pool_mod.no_escape) {
        try writer.writeAll(bytes);
        return writer.writeByte('"');
    }

    const digits = "0123456789ABCDEF";
    var start: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte >= 0x20 and byte != '"' and byte != '\\') continue;
        try writer.writeAll(bytes[start..index]);
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeAll(&.{
                '\\',              'u',                 '0', '0',
                digits[byte >> 4], digits[byte & 0x0f],
            }),
        }
        start = index + 1;
    }
    try writer.writeAll(bytes[start..]);
    return writer.writeByte('"');
}

fn writeNumber(writer: *std.Io.Writer, item: pool_mod.Value) !void {
    var buffer: [24]u8 = undefined;
    const text = switch (pool_mod.valueSubtype(item)) {
        .real => return writeReal(writer, item.uni.float),
        .one => std.fmt.bufPrint(&buffer, "{d}", .{item.uni.int}) catch unreachable,
        .none => std.fmt.bufPrint(&buffer, "{d}", .{item.uni.uint}) catch unreachable,
    };
    try writer.writeAll(text);
}

/// Writes an `f64` in the shortest form that reads back identically.
///
/// The digits and the choice between fixed and scientific notation follow
/// yyjson: fixed for decimal exponents in `[-6, 20]`, scientific outside it,
/// and a real is never written without a `.` or an exponent.
fn writeReal(writer: *std.Io.Writer, number: f64) !void {
    var buffer: [float.maxNumberLength(f64) + 8]u8 = undefined;
    const decimal = float.formatNumber(&buffer, number) catch {
        return writeRealScientific(writer, number);
    };
    const exponent = decimalExponent(decimal);
    if (exponent < -6 or exponent > 20) return writeRealScientific(writer, number);
    try writer.writeAll(decimal);
    if (std.mem.indexOfScalar(u8, decimal, '.') == null) try writer.writeAll(".0");
}

/// The rare scientific path, also used when the fused formatter declines.
fn writeRealScientific(writer: *std.Io.Writer, number: f64) !void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{e}", .{number}) catch return error.InvalidValue;
    try writer.writeAll(text);
}

/// Returns the decimal exponent of the shortest form `text`, e.g. `2` for
/// `"123.45"`, `-3` for `"0.001"`, and `0` for `"0"`.
fn decimalExponent(text: []const u8) i32 {
    const point = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    var first = text.len;
    for (text, 0..) |byte, index| {
        if (byte != '-' and byte != '.' and byte != '0') {
            first = index;
            break;
        }
    }
    if (first == text.len) return 0;
    if (first < point) return @intCast(point - first - 1);
    return @as(i32, @intCast(point)) - @as(i32, @intCast(first));
}

fn writeIndent(writer: *std.Io.Writer, level: usize) !void {
    const spaces = "                ";
    var remaining = level * 4;
    while (remaining >= spaces.len) : (remaining -= spaces.len) try writer.writeAll(spaces);
    if (remaining > 0) try writer.writeAll(spaces[0..remaining]);
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
}

test "string escaping" {
    try expectWrite("\"a\\nb\"", "\"a\\nb\"", false);
    try expectWrite("\"\\u0001\\u001F\"", "\"\\u0001\\u001f\"", false);
    // A slash escape is decoded but never re-escaped.
    try expectWrite("\"/\"", "\"\\/\"", false);
    try expectWrite("\"\\\"\\\\\"", "\"\\\"\\\\\"", false);
}

fn expectWrite(expected: []const u8, input: []const u8, pretty: bool) !void {
    var document = try @import("document.zig").parseWith(std.testing.allocator, input, .{});
    defer document.deinit();
    const output = try document.toSlice(std.testing.allocator, .{ .pretty = pretty });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}
