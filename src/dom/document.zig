const std = @import("std");
const builtin = @import("builtin");
const pool_mod = @import("pool.zig");
const reader = @import("reader.zig");
const value = @import("value.zig");

const Value = value.Value;
const Array = value.Array;
const Object = value.Object;
const WriteOptions = value.WriteOptions;

/// Options that control DOM parsing.
pub const ParseOptions = reader.Options;
pub const ParseError = reader.Error;

/// An owned DOM document. Call `deinit` once when finished.
///
/// Values, arrays, objects, and string slices obtained from this document borrow
/// its storage and become invalid after `deinit`.
pub const Document = struct {
    /// Caller-provided storage when `parseInto` was used; otherwise the input
    /// buffer and the value pool are owned by `pool.allocator`.
    pool: pool_mod.Pool,
    storage: value.Storage,
    root_index: u32,

    /// Releases the DOM storage and invalidates this document and all of its views.
    pub fn deinit(self: *Document) void {
        if (self.pool.allocator) |allocator| {
            allocator.free(@constCast(self.storage.input));
        }
        self.pool.deinit();
        self.* = undefined;
    }

    /// Returns a view of the document's root value.
    pub fn root(self: *const Document) Value {
        return .{ .storage = &self.storage, .index = self.root_index };
    }

    /// Returns the kind of the root value.
    pub fn kind(self: *const Document) value.Kind {
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

/// Parses JSON into an owned DOM document using a default allocator.
///
/// Use `parseWith` to control the allocator, or `parseInto` to parse without
/// any allocator at all. Call `Document.deinit` to release the result.
/// The allocator `parse` uses on its own.
///
/// When the program links libc this is `std.heap.c_allocator`: parsing allocates
/// and frees a whole document each time, and malloc reuses those blocks while
/// Zig's page-based allocator returns them to the OS and faults them back in on
/// the next parse. Without libc it falls back to `std.heap.smp_allocator`.
pub const default_allocator: std.mem.Allocator = if (builtin.link_libc)
    std.heap.c_allocator
else
    std.heap.smp_allocator;

pub fn parse(input: []const u8, options: ParseOptions) ParseError!Document {
    return parseWith(default_allocator, input, options);
}

/// Parses JSON into an owned DOM document allocated with `allocator`.
///
/// The document owns a mutable copy of `input` because string escapes are
/// decoded in place.
pub fn parseWith(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
) ParseError!Document {
    // The reader needs four zero bytes past the text as scratch space, the same
    // padding yyjson adds, so its hot loops can skip bounds checks.
    const owned = allocator.alloc(u8, input.len + 4) catch return error.OutOfMemory;
    errdefer allocator.free(owned);
    @memcpy(owned[0..input.len], input);
    @memset(owned[input.len..], 0);

    var pool = pool_mod.Pool.init(allocator, input.len, hasWhitespace(input)) catch
        return error.OutOfMemory;
    errdefer pool.deinit();

    const root_index = try reader.read(&pool, owned, input.len, options);
    return .{
        .pool = pool,
        .storage = .{ .values = pool.items(), .input = owned },
        .root_index = root_index,
    };
}

/// Parses JSON into caller-provided storage.
///
/// `storage` must be at least `parseBufferSize(input.len, options)` bytes and
/// must outlive the returned document. `Document.deinit` still invalidates the
/// document, but does not free caller-owned storage.
pub fn parseInto(
    storage: []u8,
    input: []const u8,
    options: ParseOptions,
) ParseError!Document {
    if (storage.len < input.len + 4) return error.OutOfMemory;

    // The input copy (plus four zero padding bytes) comes first, then the value
    // pool, so a decode in place never disturbs the values.
    const input_copy = storage[0 .. input.len + 4];
    @memcpy(input_copy[0..input.len], input);
    @memset(input_copy[input.len..], 0);
    var pool = pool_mod.Pool.initFixed(storage[input.len + 4 ..]);

    const root_index = try reader.read(&pool, input_copy, input.len, options);
    return .{
        .pool = pool,
        .storage = .{ .values = pool.items(), .input = input_copy },
        .root_index = root_index,
    };
}

/// Returns the minimum storage size required by `parseInto` for this input
/// length and options.
///
/// Every value occupies at least one input byte, so the value pool never needs
/// more than `16 * input_len` bytes, plus the input copy and alignment padding.
pub fn parseBufferSize(input_len: usize, options: ParseOptions) usize {
    _ = options;
    const values = std.math.mul(usize, input_len, pool_mod.value_size) catch
        return std.math.maxInt(usize);
    // Four bytes of reader padding, plus alignment and slack.
    const total = std.math.add(usize, input_len, 4) catch
        return std.math.maxInt(usize);
    const with_values = std.math.add(usize, total, values) catch
        return std.math.maxInt(usize);
    return std.math.add(usize, with_values, 64) catch std.math.maxInt(usize);
}

fn hasWhitespace(input: []const u8) bool {
    return std.mem.indexOfAny(u8, input, " \t\n\r") != null;
}

test "value access" {
    var document = try parseWith(
        std.testing.allocator,
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
    var document = try parseWith(std.testing.allocator, "{\"a\":1,\"b\":2}", .{});
    defer document.deinit();

    var iterator = document.object().iterator();
    var count: usize = 0;
    while (iterator.next()) |entry| {
        try std.testing.expect(entry.value.isUint());
        try std.testing.expect(entry.key.len == 1);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    var elements = document.object().get("a").?.kind();
    try std.testing.expectEqual(value.Kind.uint, elements);
    elements = document.root().kind();
    try std.testing.expectEqual(value.Kind.object, elements);
}

test "caller storage" {
    const input = "{\"name\":\"jsonz\",\"values\":[1,2]}";
    const storage = try std.testing.allocator.alloc(u8, parseBufferSize(input.len, .{}));
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
    var document = try parseWith(std.testing.allocator, "{\"name\":\"jsonz\",\"values\":[1,2]}", .{});
    defer document.deinit();

    const output = try document.toSlice(std.testing.allocator, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("{\"name\":\"jsonz\",\"values\":[1,2]}", output);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try document.field("name").toWriter(&writer.writer, .{});
    try std.testing.expectEqualStrings("\"jsonz\"", writer.written());
}

test "escaped strings round trip" {
    var document = try parseWith(std.testing.allocator, "{\"text\":\"line\\n\\u4e16\\u754c\",\"face\":\"\\ud83d\\ude00\"}", .{});
    defer document.deinit();

    try std.testing.expectEqualStrings("line\n\u{4e16}\u{754c}", document.field("text").string());
    try std.testing.expectEqualStrings("\u{1f600}", document.field("face").string());

    const output = try document.toSlice(std.testing.allocator, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "{\"text\":\"line\\n\u{4e16}\u{754c}\",\"face\":\"\u{1f600}\"}",
        output,
    );
}

test "parse options" {
    try std.testing.expectError(
        error.InvalidJson,
        parseWith(std.testing.allocator, "{/* note */ \"value\": 1,}", .{}),
    );

    var document = try parseWith(std.testing.allocator, "{/* note */ \"value\": 1,}", .{
        .allow_comments = true,
        .allow_trailing_commas = true,
    });
    defer document.deinit();
    try std.testing.expectEqual(@as(u64, 1), document.field("value").uint());
}

test "escaped keys are matched by content" {
    var document = try parseWith(std.testing.allocator, "{\"\\u0061\\u0062\":1,\"a\":2}", .{});
    defer document.deinit();
    try std.testing.expectEqual(@as(u64, 1), document.field("ab").uint());
    try std.testing.expectEqual(@as(u64, 2), document.field("a").uint());
}

test "deeply nested documents" {
    const depth = 20_000;
    const input = try std.testing.allocator.alloc(u8, depth * 2);
    defer std.testing.allocator.free(input);
    @memset(input[0..depth], '[');
    @memset(input[depth..], ']');

    var document = try parseWith(std.testing.allocator, input, .{});
    defer document.deinit();

    // Neither the reader nor the writer may recurse.
    const output = try document.toSlice(std.testing.allocator, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(input, output);
}

test "invalid input" {
    try std.testing.expectError(error.InvalidJson, parse("{", .{}));
    try std.testing.expectError(error.InvalidJson, parse("[1]x", .{}));
    try std.testing.expectError(error.InvalidJson, parse("[1 2]", .{}));
}
