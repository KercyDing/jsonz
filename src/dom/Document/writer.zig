const std = @import("std");
const pool_mod = @import("../pool.zig");
const node_mod = @import("Node.zig");
const encode = @import("../encode.zig");
const common = @import("../common.zig");

const Buffer = encode.Buffer;

const WriteOptions = common.WriteOptions;

/// A container still being written, with the sibling count left in its parent.
const Frame = struct {
    remaining: usize,
    object: bool,
};

/// Serializes `node` to a newly allocated JSON byte slice owned by `allocator`.
pub fn toSlice(
    allocator: std.mem.Allocator,
    node: node_mod,
    options: WriteOptions,
) ![]u8 {
    var buffer: Buffer = .{ .allocator = allocator };
    errdefer buffer.list.deinit(allocator);
    // The source length is a good output hint, so the buffer rarely grows.
    const estimate = if (options.pretty)
        node.storage.input.len * 2 + 64
    else
        node.storage.input.len + 64;
    try buffer.list.ensureTotalCapacity(allocator, estimate);
    try write(&buffer, node, options, allocator);
    return buffer.list.toOwnedSlice(allocator);
}

/// Serializes `node` to `writer`.
pub fn toWriter(
    writer: *std.Io.Writer,
    node: node_mod,
    options: WriteOptions,
) !void {
    // The document is buffered and flushed once, which keeps this on the same
    // fast path as `toSlice`.
    const output = try toSlice(std.heap.smp_allocator, node, options);
    defer std.heap.smp_allocator.free(output);
    try writer.writeAll(output);
}

/// Writes `node`, iteratively so document depth cannot overflow the stack.
///
/// The traversal pushes container frames on an explicit stack and emits
/// separators before each node instead of overwriting them afterwards.
fn write(
    buffer: *Buffer,
    node: node_mod,
    options: WriteOptions,
    allocator: std.mem.Allocator,
) !void {
    const nodes = node.storage.nodes;
    const input = node.storage.input;
    const root = nodes[node.index];
    const root_type = pool_mod.nodeType(root);
    if ((root_type != .array and root_type != .object) or pool_mod.nodeLen(root) == 0) {
        return writeSingle(buffer, input, root);
    }

    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);

    var object = root_type == .object;
    var remaining: usize = if (object) pool_mod.nodeLen(root) * 2 else pool_mod.nodeLen(root);
    var first = true;
    var level: usize = 1;
    var index = node.index + 1;

    try buffer.reserve(2);
    buffer.put(if (object) '{' else '[');
    if (options.pretty) buffer.put('\n');

    while (true) {
        const item = nodes[index];
        const item_type = pool_mod.nodeType(item);
        const is_key = object and remaining % 2 == 0;

        if (!first) {
            try buffer.reserve(2);
            if (is_key) {
                // The previous slot held an object member value.
                buffer.put(',');
                if (options.pretty) buffer.put('\n');
            } else if (object) {
                // This slot is an object member value, directly after its key.
                buffer.put(':');
                if (options.pretty) buffer.put(' ');
            } else {
                buffer.put(',');
                if (options.pretty) buffer.put('\n');
            }
        }
        // Object member values stay on their key's line; keys and array elements do not.
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
                buffer.putAll(if (pool_mod.nodeSubtype(item) == pool_mod.true_flag) "true" else "false");
            },
            .null => {
                try buffer.reserve(4);
                buffer.putAll("null");
            },
            .array, .object => {
                const child_object = item_type == .object;
                const child_len = pool_mod.nodeLen(item);
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

/// Writes a node that is not a non-empty container.
fn writeSingle(buffer: *Buffer, input: []const u8, node: pool_mod.NodeData) !void {
    switch (pool_mod.nodeType(node)) {
        .string => try writeString(buffer, input, node),
        .number => try writeNumber(buffer, node),
        .bool => {
            try buffer.reserve(5);
            buffer.putAll(if (pool_mod.nodeSubtype(node) == pool_mod.true_flag) "true" else "false");
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
inline fn writeString(buffer: *Buffer, input: []const u8, node: pool_mod.NodeData) !void {
    const offset: usize = @intCast(node.payload.offset);
    const bytes = input[offset..][0..pool_mod.nodeLen(node)];
    try encode.writeStringBytes(buffer, bytes, pool_mod.nodeSubtype(node) != pool_mod.no_escape);
}

inline fn writeNumber(buffer: *Buffer, node: pool_mod.NodeData) !void {
    switch (pool_mod.nodeSubtype(node)) {
        .real => try encode.writeReal(buffer, node.payload.float),
        .one => try encode.writeSigned(buffer, node.payload.int),
        .none => try encode.writeUnsigned(buffer, node.payload.uint),
    }
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
    var document = try @import("Document.zig").parse(std.testing.allocator, input, .{});
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
