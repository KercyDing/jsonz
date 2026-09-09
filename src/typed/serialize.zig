const std = @import("std");
const kind = @import("kind.zig");

pub const Options = struct {
    /// Format arrays and objects with indentation and line breaks.
    pretty: bool = false,
    /// Number of spaces per indentation level when `pretty` is enabled.
    indent: u8 = 2,
};

/// Low-level typed serializer used by custom `jsonzSerialize` hooks.
/// Most applications should call `toSlice` or `toWriter`.
pub const Serializer = struct {
    writer: *std.Io.Writer,
    options: Options,
    depth: usize = 0,

    /// Creates a serializer that writes JSON to `writer`.
    pub fn init(writer: *std.Io.Writer, options: Options) Serializer {
        return .{ .writer = writer, .options = options };
    }

    /// Serializes any supported Zig value.
    pub fn serialize(self: *Serializer, value: anytype) std.Io.Writer.Error!void {
        return serializeValue(@TypeOf(value), value, self);
    }

    /// Serializes a boolean literal.
    pub fn serializeBool(self: *Serializer, value: bool) std.Io.Writer.Error!void {
        try self.writer.writeAll(if (value) "true" else "false");
    }

    /// Serializes an integer value.
    pub fn serializeInt(self: *Serializer, value: anytype) std.Io.Writer.Error!void {
        try self.writer.print("{d}", .{value});
    }

    /// Serializes a finite floating-point value, or JSON `null` for NaN and infinities.
    pub fn serializeFloat(self: *Serializer, value: anytype) std.Io.Writer.Error!void {
        if (std.math.isFinite(value)) {
            try self.writer.print("{d}", .{value});
        } else {
            try self.serializeNull();
        }
    }

    /// Serializes a UTF-8 byte slice as a JSON string with required escapes.
    pub fn serializeString(self: *Serializer, value: []const u8) std.Io.Writer.Error!void {
        try writeJsonString(self.writer, value);
    }

    /// Serializes JSON `null`.
    pub fn serializeNull(self: *Serializer) std.Io.Writer.Error!void {
        try self.writer.writeAll("null");
    }

    fn newline(self: *Serializer) std.Io.Writer.Error!void {
        if (!self.options.pretty) return;
        try self.writer.writeByte('\n');
        for (0..self.depth * self.options.indent) |_| try self.writer.writeByte(' ');
    }
};

/// Serializes a Zig value to a newly allocated JSON byte slice owned by `allocator`.
pub fn toSlice(allocator: std.mem.Allocator, value: anytype, options: Options) ![]u8 {
    const capacity = @min(estimateSerializedSize(@TypeOf(value), value), 64 * 1024 * 1024);
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, capacity);
    errdefer output.deinit();

    var serializer = Serializer.init(&output.writer, options);
    try serializer.serialize(value);
    return output.toOwnedSlice();
}

/// Estimates compact JSON output size without scanning string contents.
///
/// String escapes can make the actual output larger, in which case the writer
/// grows normally. The estimate is only a capacity hint for `toSlice`.
fn estimateSerializedSize(comptime T: type, value: T) usize {
    if (comptime kind.hasCustomSerialize(T)) return 0;

    return switch (comptime kind.typeKind(T)) {
        .bool => 5,
        .int => maxIntDigits(T),
        .float => maxFloatDigits(T),
        .string => value.len +| 2,
        .void => 4,
        .optional => if (value) |payload|
            estimateSerializedSize(kind.Child(T), payload)
        else
            4,
        .array, .slice => estimateSequenceSize(T, value),
        .tuple => estimateTupleSize(T, value),
        .@"struct" => estimateStructSize(T, value),
        .@"enum" => @tagName(value).len + 2,
        .@"union" => estimateUnionSize(T, value),
    };
}

fn maxIntDigits(comptime T: type) usize {
    const type_info = @typeInfo(T);
    if (type_info == .comptime_int) return 40;

    const info = type_info.int;
    const bits: usize = info.bits;
    const digits = (bits * 30103 + 99_999) / 100_000;
    return digits + @intFromBool(info.signedness == .signed);
}

fn maxFloatDigits(comptime T: type) usize {
    const type_info = @typeInfo(T);
    if (type_info == .comptime_float) return 48;

    return switch (type_info.float.bits) {
        16 => 16,
        32 => 24,
        64 => 32,
        128 => 48,
        else => 64,
    };
}

fn estimateSequenceSize(comptime T: type, value: T) usize {
    var size: usize = 2;
    for (value, 0..) |element, index| {
        size +|= @intFromBool(index != 0);
        size +|= estimateSerializedSize(kind.Child(T), element);
    }
    return size;
}

fn estimateTupleSize(comptime T: type, value: T) usize {
    var size: usize = 2;
    inline for (comptime kind.structFields(T), 0..) |field, index| {
        size +|= @intFromBool(index != 0);
        size +|= estimateSerializedSize(field.type, @field(value, field.name));
    }
    return size;
}

fn estimateStructSize(comptime T: type, value: T) usize {
    var size: usize = 2;
    inline for (comptime kind.structFields(T), 0..) |field, index| {
        size +|= fieldPrefix(field.name, index == 0).len;
        size +|= estimateSerializedSize(field.type, @field(value, field.name));
    }
    return size;
}

fn estimateUnionSize(comptime T: type, value: T) usize {
    const info = @typeInfo(T).@"union";
    const tag = std.meta.activeTag(value);
    inline for (comptime kind.unionFields(T)) |field| {
        if (tag == @field(info.tag_type.?, field.name)) {
            if (field.type == void) return field.name.len + 2;
            return 2 +| fieldPrefix(field.name, true).len +| estimateSerializedSize(field.type, @field(value, field.name));
        }
    }
    unreachable;
}

/// Write a JSON string directly, scanning ordinary text in 8-byte blocks.
/// This keeps the common no-escape path to one bulk writer call.
fn writeJsonString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');

    var start: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        while (index + 8 <= value.len) {
            const bytes: @Vector(8, u8) = value[index..][0..8].*;
            const special =
                (bytes == @as(@Vector(8, u8), @splat('"'))) |
                (bytes == @as(@Vector(8, u8), @splat('\\'))) |
                (bytes < @as(@Vector(8, u8), @splat(0x20)));
            if (@reduce(.Or, special)) break;
            index += 8;
        }
        if (index == value.len) break;

        const byte = value[index];
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            0x00...0x07, 0x0b, 0x0e...0x1f => null,
            else => continue,
        };

        if (index > start) try writer.writeAll(value[start..index]);
        if (escape) |text| {
            try writer.writeAll(text);
        } else {
            const hex = "0123456789abcdef";
            try writer.writeAll("\\u00");
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
        start = index + 1;
    }

    if (start < value.len) try writer.writeAll(value[start..]);
    try writer.writeByte('"');
}

/// Serializes a Zig value directly to `writer`.
pub fn toWriter(writer: *std.Io.Writer, value: anytype, options: Options) !void {
    var serializer = Serializer.init(writer, options);
    try serializer.serialize(value);
}

fn serializeValue(comptime T: type, value: T, serializer: *Serializer) std.Io.Writer.Error!void {
    if (comptime kind.hasCustomSerialize(T)) return value.jsonzSerialize(serializer);

    switch (comptime kind.typeKind(T)) {
        .bool => try serializer.serializeBool(value),
        .int => try serializer.serializeInt(value),
        .float => try serializer.serializeFloat(value),
        .string => try serializer.serializeString(value),
        .void => try serializer.serializeNull(),
        .optional => if (value) |payload|
            try serializeValue(kind.Child(T), payload, serializer)
        else
            try serializer.serializeNull(),
        .array, .slice => try serializeSequence(T, value, serializer),
        .tuple => try serializeTuple(T, value, serializer),
        .@"struct" => try serializeStruct(T, value, serializer),
        .@"enum" => try serializer.serializeString(@tagName(value)),
        .@"union" => try serializeUnion(T, value, serializer),
    }
}

fn serializeSequence(comptime T: type, value: T, serializer: *Serializer) std.Io.Writer.Error!void {
    try serializer.writer.writeByte('[');
    serializer.depth += 1;

    for (value, 0..) |element, index| {
        if (index != 0) try serializer.writer.writeByte(',');
        try serializer.newline();
        try serializeValue(kind.Child(T), element, serializer);
    }

    serializer.depth -= 1;
    if (value.len != 0) try serializer.newline();
    try serializer.writer.writeByte(']');
}

fn serializeTuple(comptime T: type, value: T, serializer: *Serializer) std.Io.Writer.Error!void {
    const fields = comptime kind.structFields(T);
    try serializer.writer.writeByte('[');
    serializer.depth += 1;

    inline for (fields, 0..) |field, index| {
        if (index != 0) try serializer.writer.writeByte(',');
        try serializer.newline();
        try serializeValue(field.type, @field(value, field.name), serializer);
    }

    serializer.depth -= 1;
    if (fields.len != 0) try serializer.newline();
    try serializer.writer.writeByte(']');
}

fn serializeStruct(comptime T: type, value: T, serializer: *Serializer) std.Io.Writer.Error!void {
    const fields = comptime kind.structFields(T);
    try serializer.writer.writeByte('{');
    serializer.depth += 1;

    inline for (fields, 0..) |field, index| {
        try writeFieldPrefix(field.name, index == 0, serializer);
        try serializeValue(field.type, @field(value, field.name), serializer);
    }

    serializer.depth -= 1;
    if (fields.len != 0) try serializer.newline();
    try serializer.writer.writeByte('}');
}

fn serializeUnion(comptime T: type, value: T, serializer: *Serializer) std.Io.Writer.Error!void {
    const info = @typeInfo(T).@"union";
    const tag = std.meta.activeTag(value);

    inline for (comptime kind.unionFields(T)) |field| {
        if (tag == @field(info.tag_type.?, field.name)) {
            if (field.type == void) return serializer.serializeString(field.name);

            try serializer.writer.writeByte('{');
            serializer.depth += 1;
            try writeFieldPrefix(field.name, true, serializer);
            try serializeValue(field.type, @field(value, field.name), serializer);
            serializer.depth -= 1;
            try serializer.newline();
            return serializer.writer.writeByte('}');
        }
    }
    unreachable;
}

inline fn writeFieldPrefix(comptime name: []const u8, comptime first: bool, serializer: *Serializer) std.Io.Writer.Error!void {
    if (!serializer.options.pretty and comptime !fieldNameNeedsEscaping(name)) {
        return serializer.writer.writeAll(comptime fieldPrefix(name, first));
    }

    if (!first) try serializer.writer.writeByte(',');
    try serializer.newline();

    if (comptime fieldNameNeedsEscaping(name)) {
        try serializer.serializeString(name);
    } else {
        try serializer.writer.writeByte('"');
        try serializer.writer.writeAll(name);
        try serializer.writer.writeByte('"');
    }

    try serializer.writer.writeByte(':');
    if (serializer.options.pretty) try serializer.writer.writeByte(' ');
}

inline fn fieldPrefix(comptime name: []const u8, comptime first: bool) []const u8 {
    return if (first) "\"" ++ name ++ "\":" else ",\"" ++ name ++ "\":";
}

fn fieldNameNeedsEscaping(comptime name: []const u8) bool {
    for (name) |byte| {
        if (byte == '"' or byte == '\\' or byte < 0x20) return true;
    }
    return false;
}

const testing = std.testing;

test "nested values" {
    const input = .{
        .id = @as(u32, 7),
        .name = @as([]const u8, "jsonz"),
        .flags = [_]bool{ true, false },
    };
    const output = try toSlice(testing.allocator, input, .{});
    defer testing.allocator.free(output);

    try testing.expectEqualStrings(
        "{\"id\":7,\"name\":\"jsonz\",\"flags\":[true,false]}",
        output,
    );
}

test "string escaping" {
    const value: []const u8 = "a\n\"b";
    const output = try toSlice(testing.allocator, value, .{});
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("\"a\\n\\\"b\"", output);
}

test "external union" {
    const Value = union(enum) { none, number: i32 };
    const output = try toSlice(testing.allocator, Value{ .number = 42 }, .{});
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("{\"number\":42}", output);
}

test "field name escaping" {
    const Value = struct { @"quoted\"field": u8 };
    const output = try toSlice(testing.allocator, Value{ .@"quoted\"field" = 1 }, .{});
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("{\"quoted\\\"field\":1}", output);
}

test "pretty struct fields" {
    const output = try toSlice(testing.allocator, .{ .value = @as(u8, 1) }, .{ .pretty = true });
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("{\n  \"value\": 1\n}", output);
}
