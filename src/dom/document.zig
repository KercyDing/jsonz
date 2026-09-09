const std = @import("std");
const bridge = @import("yyjson_c");
const value = @import("value.zig");

const Value = value.Value;
const Kind = value.Kind;
const Array = value.Array;
const Object = value.Object;
const WriteOptions = value.WriteOptions;

pub const ParseOptions = struct {
    /// Accept `//` and `/* ... */` comments, which are not part of standard JSON.
    allow_comments: bool = false,
    /// Accept a comma before a closing `]` or `}`, which is not part of standard JSON.
    allow_trailing_commas: bool = false,
};

pub const ParseError = error{ InvalidJson, OutOfMemory };

/// An owned DOM document. Call `deinit` once when finished.
///
/// Values, arrays, objects, and string slices obtained from this document borrow
/// its storage and become invalid after `deinit`.
pub const Document = struct {
    handle: *bridge.yyjson_doc,

    /// Releases the DOM storage and invalidates this document and all of its views.
    pub fn deinit(self: *Document) void {
        bridge.jsonz_yyjson_free(self.handle);
        self.* = undefined;
    }

    /// Returns a view of the document's root value.
    pub fn root(self: *const Document) Value {
        return .{ .handle = bridge.jsonz_yyjson_root(self.handle) orelse unreachable };
    }

    /// Returns the kind of the root value.
    pub fn kind(self: *const Document) Kind {
        return self.root().kind();
    }

    /// Returns whether the root value is JSON `null`.
    pub fn isNull(self: *const Document) bool {
        return self.root().isNull();
    }

    /// Returns whether the root value is a boolean.
    pub fn isBool(self: *const Document) bool {
        return self.root().isBool();
    }

    /// Returns whether the root value is a signed integer.
    pub fn isInt(self: *const Document) bool {
        return self.root().isInt();
    }

    /// Returns whether the root value is an unsigned integer.
    pub fn isUint(self: *const Document) bool {
        return self.root().isUint();
    }

    /// Returns whether the root value is a floating-point number.
    pub fn isFloat(self: *const Document) bool {
        return self.root().isFloat();
    }

    /// Returns whether the root value is a string.
    pub fn isString(self: *const Document) bool {
        return self.root().isString();
    }

    /// Returns whether the root value is an array.
    pub fn isArray(self: *const Document) bool {
        return self.root().isArray();
    }

    /// Returns whether the root value is an object.
    pub fn isObject(self: *const Document) bool {
        return self.root().isObject();
    }

    /// Returns the root boolean. Asserts that `isBool()` is true.
    pub fn @"bool"(self: *const Document) bool {
        return self.root().bool();
    }

    /// Returns the root signed integer. Asserts that `isInt()` is true.
    pub fn int(self: *const Document) i64 {
        return self.root().int();
    }

    /// Returns the root unsigned integer. Asserts that `isUint()` is true.
    pub fn uint(self: *const Document) u64 {
        return self.root().uint();
    }

    /// Returns the root floating-point value. Asserts that `isFloat()` is true.
    pub fn float(self: *const Document) f64 {
        return self.root().float();
    }

    /// Returns a string slice borrowed from the document. Asserts that `isString()` is true.
    pub fn string(self: *const Document) []const u8 {
        return self.root().string();
    }

    /// Returns an array view borrowed from the document. Asserts that `isArray()` is true.
    pub fn array(self: *const Document) Array {
        return self.root().array();
    }

    /// Returns an object view borrowed from the document. Asserts that `isObject()` is true.
    pub fn object(self: *const Document) Object {
        return self.root().object();
    }

    /// Looks up a root-object field, returning `null` when the field is absent.
    /// Asserts that the root is an object.
    pub fn get(self: *const Document, key: []const u8) ?Value {
        return self.root().get(key);
    }

    /// Returns a root-object field. Asserts that the root is an object and the field exists.
    pub fn field(self: *const Document, key: []const u8) Value {
        return self.root().field(key);
    }

    /// Serializes the root value to a newly allocated JSON byte slice owned by `allocator`.
    pub fn toSlice(
        self: *const Document,
        allocator: std.mem.Allocator,
        options: WriteOptions,
    ) ![]u8 {
        return self.root().toSlice(allocator, options);
    }

    /// Serializes the root value to `writer` without allocating an output slice.
    pub fn toWriter(
        self: *const Document,
        writer: *std.Io.Writer,
        options: WriteOptions,
    ) !void {
        return self.root().toWriter(writer, options);
    }
};

/// Parses JSON into an owned DOM document. Call `Document.deinit` to release it.
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

/// Parses JSON into caller-provided storage.
///
/// `storage` must be at least `parseBufferSize(input.len, options)` bytes and
/// must outlive the returned document. `Document.deinit` still invalidates it,
/// but does not free caller-owned storage.
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

/// Returns the minimum storage size required by `parseInto` for this input length and options.
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
