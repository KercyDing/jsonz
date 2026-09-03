const std = @import("std");
const kind = @import("kind.zig");

pub const Options = struct {
    pretty: bool = false,
    indent: u8 = 2,
};

pub const Serializer = struct {
    writer: *std.Io.Writer,
    options: Options,
    depth: usize = 0,

    pub fn init(writer: *std.Io.Writer, options: Options) Serializer {
        return .{ .writer = writer, .options = options };
    }

    pub fn serialize(self: *Serializer, value: anytype) std.Io.Writer.Error!void {
        return serializeValue(@TypeOf(value), value, self);
    }

    pub fn serializeBool(self: *Serializer, value: bool) std.Io.Writer.Error!void {
        try self.writer.writeAll(if (value) "true" else "false");
    }

    pub fn serializeInt(self: *Serializer, value: anytype) std.Io.Writer.Error!void {
        try self.writer.print("{d}", .{value});
    }

    pub fn serializeFloat(self: *Serializer, value: anytype) std.Io.Writer.Error!void {
        if (std.math.isFinite(value)) {
            try self.writer.print("{d}", .{value});
        } else {
            try self.serializeNull();
        }
    }

    pub fn serializeString(self: *Serializer, value: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(value, .{}, self.writer);
    }

    pub fn serializeNull(self: *Serializer) std.Io.Writer.Error!void {
        try self.writer.writeAll("null");
    }

    fn newline(self: *Serializer) std.Io.Writer.Error!void {
        if (!self.options.pretty) return;
        try self.writer.writeByte('\n');
        for (0..self.depth * self.options.indent) |_| try self.writer.writeByte(' ');
    }
};

pub fn toSlice(allocator: std.mem.Allocator, value: anytype, options: Options) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var serializer = Serializer.init(&output.writer, options);
    try serializer.serialize(value);
    return output.toOwnedSlice();
}

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
    const info = @typeInfo(T).@"struct";
    try serializer.writer.writeByte('[');
    serializer.depth += 1;

    inline for (info.field_names, info.field_types, 0..) |name, Field, index| {
        if (index != 0) try serializer.writer.writeByte(',');
        try serializer.newline();
        try serializeValue(Field, @field(value, name), serializer);
    }

    serializer.depth -= 1;
    if (info.field_names.len != 0) try serializer.newline();
    try serializer.writer.writeByte(']');
}

fn serializeStruct(comptime T: type, value: T, serializer: *Serializer) std.Io.Writer.Error!void {
    const info = @typeInfo(T).@"struct";
    try serializer.writer.writeByte('{');
    serializer.depth += 1;

    inline for (info.field_names, info.field_types, 0..) |name, Field, index| {
        try writeFieldPrefix(name, index == 0, serializer);
        try serializeValue(Field, @field(value, name), serializer);
    }

    serializer.depth -= 1;
    if (info.field_names.len != 0) try serializer.newline();
    try serializer.writer.writeByte('}');
}

fn serializeUnion(comptime T: type, value: T, serializer: *Serializer) std.Io.Writer.Error!void {
    const info = @typeInfo(T).@"union";
    const tag = std.meta.activeTag(value);

    inline for (info.field_names, info.field_types) |name, Field| {
        if (tag == @field(info.tag_type.?, name)) {
            if (Field == void) return serializer.serializeString(name);

            try serializer.writer.writeByte('{');
            serializer.depth += 1;
            try writeFieldPrefix(name, true, serializer);
            try serializeValue(Field, @field(value, name), serializer);
            serializer.depth -= 1;
            try serializer.newline();
            return serializer.writer.writeByte('}');
        }
    }
    unreachable;
}

inline fn writeFieldPrefix(comptime name: []const u8, comptime first: bool, serializer: *Serializer) std.Io.Writer.Error!void {
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
