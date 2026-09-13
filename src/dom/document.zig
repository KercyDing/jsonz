const std = @import("std");
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

    /// Returns the root boolean.
    pub fn toBool(self: *const Document) value.ValueError!bool {
        return self.root().toBool();
    }

    /// Converts the root JSON number to the requested numeric type.
    pub fn toNumber(self: *const Document, comptime target: value.NumberType) value.ValueError!target.Type() {
        return self.root().toNumber(target);
    }

    /// Converts the root JSON number to the requested numeric type, or null.
    pub fn asNumber(self: *const Document, comptime target: value.NumberType) ?target.Type() {
        return self.root().asNumber(target);
    }

    /// Returns the root boolean when it is a boolean, otherwise null.
    pub fn asBool(self: *const Document) ?bool {
        return self.root().asBool();
    }

    /// Returns the root string when it is a string, otherwise null.
    pub fn asString(self: *const Document) ?[]const u8 {
        return self.root().asString();
    }

    /// Returns the root array when it is an array, otherwise null.
    pub fn asArray(self: *const Document) ?Array {
        return self.root().asArray();
    }

    /// Returns the root object when it is an object, otherwise null.
    pub fn asObject(self: *const Document) ?Object {
        return self.root().asObject();
    }

    /// Returns a string slice borrowed from the document.
    pub fn toString(self: *const Document) value.ValueError![]const u8 {
        return self.root().toString();
    }

    /// Returns an array view borrowed from the document.
    pub fn toArray(self: *const Document) value.ValueError!Array {
        return self.root().toArray();
    }

    /// Returns an object view borrowed from the document.
    pub fn toObject(self: *const Document) value.ValueError!Object {
        return self.root().toObject();
    }

    /// Looks up a root-object field, returning `null` when the root is not an
    /// object or the field is absent.
    pub fn get(self: *const Document, key: []const u8) ?Value {
        return self.root().get(key);
    }

    /// Returns a root-object field, or an error when it cannot be accessed.
    pub fn field(self: *const Document, key: []const u8) value.ValueError!Value {
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

/// Parses JSON into an owned DOM document allocated with `allocator`.
///
/// The document owns a mutable copy of `input` because string escapes are
/// decoded in place.
pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
) ParseError!Document {
    // The reader needs four zero bytes past the text as scratch space, so its
    // hot loops can skip bounds checks.
    const owned = allocator.alloc(u8, input.len + 4) catch return error.OutOfMemory;
    errdefer allocator.free(owned);
    @memcpy(owned[0..input.len], input);
    @memset(owned[input.len..], 0);

    var pool = pool_mod.Pool.init(allocator, input.len, looksPretty(input)) catch
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

/// Whether the document is indented rather than compact: a container opener
/// followed by two whitespace bytes. Scanning the whole input would call dense
/// documents with a little indentation "pretty" and badly under-size the value
/// pool.
fn looksPretty(input: []const u8) bool {
    var index: usize = 0;
    while (index < input.len and isWhitespace(input[index])) index += 1;
    if (index + 2 >= input.len) return false;
    const first = input[index];
    if (first != '[' and first != '{') return false;
    return isWhitespace(input[index + 1]) and isWhitespace(input[index + 2]);
}

inline fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}
test "caller storage" {
    const input = "{\"name\":\"jsonz\",\"values\":[1,2]}";
    const storage = try std.testing.allocator.alloc(u8, parseBufferSize(input.len, .{}));
    defer std.testing.allocator.free(storage);

    var document = try parseInto(storage, input, .{});
    defer document.deinit();

    try std.testing.expectEqualStrings("jsonz", try (try document.field("name")).toString());

    var insufficient: [1]u8 = undefined;
    try std.testing.expectError(
        error.OutOfMemory,
        parseInto(&insufficient, input, .{}),
    );
}

test "parse options" {
    try std.testing.expectError(
        error.InvalidJson,
        parse(std.testing.allocator, "{/* note */ \"value\": 1,}", .{}),
    );

    var document = try parse(std.testing.allocator, "{/* note */ \"value\": 1,}", .{
        .allow_comments = true,
        .allow_trailing_commas = true,
    });
    defer document.deinit();
    try std.testing.expectEqual(@as(u64, 1), try (try document.field("value")).toNumber(.u64));
}

test "escaped keys are matched by content" {
    var document = try parse(std.testing.allocator, "{\"\\u0061\\u0062\":1,\"a\":2}", .{});
    defer document.deinit();
    try std.testing.expectEqual(@as(u64, 1), try (try document.field("ab")).toNumber(.u64));
    try std.testing.expectEqual(@as(u64, 2), try (try document.field("a")).toNumber(.u64));
}

test "invalid input" {
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "{", .{}));
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "[1]x", .{}));
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "[1 2]", .{}));
}
