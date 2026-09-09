const std = @import("std");
const bridge = @import("yyjson_c");
const value = @import("value.zig");

const Value = value.Value;
const Kind = value.Kind;
const Array = value.Array;
const Object = value.Object;
const WriteOptions = value.WriteOptions;

pub const ParseOptions = struct {
    allow_comments: bool = false,
    allow_trailing_commas: bool = false,
};

pub const ParseError = error{ InvalidJson, OutOfMemory };

pub const Document = struct {
    handle: *bridge.yyjson_doc,

    pub fn deinit(self: *Document) void {
        bridge.jsonz_yyjson_free(self.handle);
        self.* = undefined;
    }

    pub fn root(self: *const Document) Value {
        return .{ .handle = bridge.jsonz_yyjson_root(self.handle) orelse unreachable };
    }

    pub fn kind(self: *const Document) Kind {
        return self.root().kind();
    }

    pub fn isNull(self: *const Document) bool {
        return self.root().isNull();
    }

    pub fn isBool(self: *const Document) bool {
        return self.root().isBool();
    }

    pub fn isInt(self: *const Document) bool {
        return self.root().isInt();
    }

    pub fn isUint(self: *const Document) bool {
        return self.root().isUint();
    }

    pub fn isFloat(self: *const Document) bool {
        return self.root().isFloat();
    }

    pub fn isString(self: *const Document) bool {
        return self.root().isString();
    }

    pub fn isArray(self: *const Document) bool {
        return self.root().isArray();
    }

    pub fn isObject(self: *const Document) bool {
        return self.root().isObject();
    }

    pub fn @"bool"(self: *const Document) bool {
        return self.root().bool();
    }

    pub fn int(self: *const Document) i64 {
        return self.root().int();
    }

    pub fn uint(self: *const Document) u64 {
        return self.root().uint();
    }

    pub fn float(self: *const Document) f64 {
        return self.root().float();
    }

    pub fn string(self: *const Document) []const u8 {
        return self.root().string();
    }

    pub fn array(self: *const Document) Array {
        return self.root().array();
    }

    pub fn object(self: *const Document) Object {
        return self.root().object();
    }

    pub fn get(self: *const Document, key: []const u8) ?Value {
        return self.root().get(key);
    }

    pub fn field(self: *const Document, key: []const u8) Value {
        return self.root().field(key);
    }

    pub fn toSlice(
        self: *const Document,
        allocator: std.mem.Allocator,
        options: WriteOptions,
    ) ![]u8 {
        return self.root().toSlice(allocator, options);
    }

    pub fn toWriter(
        self: *const Document,
        writer: *std.Io.Writer,
        options: WriteOptions,
    ) !void {
        return self.root().toWriter(writer, options);
    }
};

pub fn parse(input: []const u8, options: ParseOptions) ParseError!Document {
    var error_code: c_int = 0;
    const document = bridge.jsonz_yyjson_read(
        @constCast(input.ptr),
        input.len,
        options.allow_comments,
        options.allow_trailing_commas,
        &error_code,
    ) orelse return parseError(error_code);
    return .{ .handle = document };
}

pub fn parseInto(
    storage: []u8,
    input: []const u8,
    options: ParseOptions,
) ParseError!Document {
    var error_code: c_int = 0;
    const document = bridge.jsonz_yyjson_read_into(
        @constCast(input.ptr),
        input.len,
        options.allow_comments,
        options.allow_trailing_commas,
        storage.ptr,
        storage.len,
        &error_code,
    ) orelse return parseError(error_code);
    return .{ .handle = document };
}

pub fn parseBufferSize(input_len: usize, options: ParseOptions) usize {
    return bridge.jsonz_yyjson_read_buffer_size(
        input_len,
        options.allow_comments,
        options.allow_trailing_commas,
    );
}

fn parseError(error_code: c_int) ParseError {
    return if (error_code == 2) error.OutOfMemory else error.InvalidJson;
}

test "value access" {
    var document = try parse(
        "{\"enabled\":true,\"count\":42,\"items\":[null,\"jsonz\",-7,1.5]}",
        .{},
    );
    defer document.deinit();

    try std.testing.expect(document.isObject());
    try std.testing.expect(document.field("enabled").bool());
    try std.testing.expectEqual(@as(u64, 42), document.field("count").uint());
    try std.testing.expect(document.get("missing") == null);

    const items = document.field("items").array();
    try std.testing.expect(items.at(0).isNull());
    try std.testing.expectEqualStrings("jsonz", items.at(1).string());
    try std.testing.expectEqual(@as(i64, -7), items.at(2).int());
    try std.testing.expectEqual(@as(f64, 1.5), items.at(3).float());
    try std.testing.expect(items.get(4) == null);
}

test "container iteration" {
    var document = try parse("{\"a\":1,\"b\":2}", .{});
    defer document.deinit();

    var iterator = document.object().iterator();
    var count: usize = 0;
    while (iterator.next()) |entry| {
        try std.testing.expect(entry.value.isUint());
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "caller storage" {
    const input = "{\"name\":\"jsonz\",\"values\":[1,2]}";
    const size = parseBufferSize(input.len, .{});
    const storage = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(storage);

    var document = try parseInto(storage, input, .{});
    defer document.deinit();

    try std.testing.expectEqualStrings("jsonz", document.field("name").string());

    var insufficient: [1]u8 = undefined;
    try std.testing.expectError(
        error.OutOfMemory,
        parseInto(&insufficient, input, .{}),
    );
}

test "document serialization" {
    var document = try parse("{\"name\":\"jsonz\",\"values\":[1,2]}", .{});
    defer document.deinit();

    const output = try document.toSlice(std.testing.allocator, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("{\"name\":\"jsonz\",\"values\":[1,2]}", output);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try document.field("name").toWriter(&writer.writer, .{});
    try std.testing.expectEqualStrings("\"jsonz\"", writer.written());
}

test "invalid input" {
    try std.testing.expectError(error.InvalidJson, parse("{", .{}));
}
