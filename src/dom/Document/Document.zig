/// An owned DOM document. Call `deinit` once when finished.
///
/// `Node`s and string slices obtained from this document borrow its storage
/// and become invalid after `deinit`.
const Document = @This();

const std = @import("std");
const pool_mod = @import("../pool.zig");
const reader = @import("../reader.zig");
const common = @import("../common.zig");
const Node = @import("Node.zig");
const document_mut = @import("../DocumentMut/root.zig");

const WriteOptions = common.WriteOptions;

/// Options that control DOM parsing.
pub const ParseOptions = reader.Options;
pub const ParseError = reader.Error;

/// Caller-provided storage when `parseInto` was used; otherwise the input
/// buffer and the node pool are owned by `pool.allocator`.
pool: pool_mod.Pool,
storage: common.Storage,
root_index: u32,

/// Releases the DOM storage and invalidates this document and all of its views.
pub fn deinit(self: *Document) void {
    if (self.pool.allocator) |allocator| {
        allocator.free(@constCast(self.storage.input));
    }
    self.pool.deinit();
    self.* = undefined;
}

/// Returns a view of the document's root node.
pub fn root(self: *const Document) Node {
    return .{ .storage = &self.storage, .index = self.root_index };
}

/// Copies this document into a new mutable document. The original stays
/// valid; the mutable tree owns its own nodes and strings.
pub fn toMut(self: *const Document, allocator: std.mem.Allocator) std.mem.Allocator.Error!document_mut.DocumentMut {
    return document_mut.fromStorage(allocator, &self.storage, self.root_index);
}

/// Returns the kind of the root node.
pub fn kind(self: *const Document) common.Kind {
    return self.root().kind();
}

/// Returns whether the root node is JSON `null`.
pub fn isNull(self: *const Document) bool {
    return self.root().isNull();
}

/// Returns whether the root node is a boolean.
pub fn isBool(self: *const Document) bool {
    return self.root().isBool();
}

/// Returns whether the root node can be converted to the requested numeric type.
pub fn isNumber(self: *const Document, comptime target: common.NumberType) bool {
    return self.root().isNumber(target);
}

/// Returns whether the root node is a string.
pub fn isString(self: *const Document) bool {
    return self.root().isString();
}

/// Returns whether the root node is an array.
pub fn isArray(self: *const Document) bool {
    return self.root().isArray();
}

/// Returns whether the root node is an object.
pub fn isObject(self: *const Document) bool {
    return self.root().isObject();
}

/// Returns the number of fields or elements in the root container.
pub fn len(self: *const Document) common.AccessError!usize {
    return self.root().len();
}

/// Returns the root boolean.
pub fn toBool(self: *const Document) common.AccessError!bool {
    return self.root().toBool();
}

/// Converts the root JSON number to the requested numeric type.
pub fn toNumber(self: *const Document, comptime target: common.NumberType) common.AccessError!target.Type() {
    return self.root().toNumber(target);
}

/// Converts the root JSON number to the requested numeric type, or null.
pub fn asNumber(self: *const Document, comptime target: common.NumberType) ?target.Type() {
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

/// Returns a string slice borrowed from the document.
pub fn toString(self: *const Document) common.AccessError![]const u8 {
    return self.root().toString();
}

/// Looks up a root-object field, returning `null` when the root is not an
/// object or the field is absent.
pub fn get(self: *const Document, key: []const u8) ?Node {
    return self.root().get(key);
}

/// Returns a root-object field, or an error when it cannot be accessed.
pub fn field(self: *const Document, key: []const u8) common.AccessError!Node {
    return self.root().field(key);
}

/// Returns an array element, or `null` when the root is not an array or the index is out of bounds.
pub fn getAt(self: *const Document, index: usize) ?Node {
    return self.root().getAt(index);
}

/// Returns an array element, or an error when the root is not an array or the index is out of bounds.
pub fn at(self: *const Document, index: usize) common.AccessError!Node {
    return self.root().at(index);
}

/// Returns an iterator over root object fields.
pub fn objectIterator(self: *const Document) common.AccessError!Node.ObjectIterator {
    return self.root().objectIterator();
}

/// Returns an iterator over root array elements.
pub fn arrayIterator(self: *const Document) common.AccessError!Node.ArrayIterator {
    return self.root().arrayIterator();
}

/// Resolves a comptime-known RFC 6901 JSON Pointer from the root.
pub fn ptrGet(self: *const Document, comptime ptr: []const u8) common.PointerError!Node {
    return self.root().ptrGet(ptr);
}

/// Resolves a comptime-known pointer format from the root.
pub fn ptrGetFmt(
    self: *const Document,
    comptime fmt: []const u8,
    args: anytype,
) common.PointerError!Node {
    return self.root().ptrGetFmt(fmt, args);
}

/// Resolves a complete RFC 6901 JSON Pointer from the root, known only at
/// runtime.
pub fn ptrGetDyn(self: *const Document, ptr: []const u8) common.PointerError!Node {
    return self.root().ptrGetDyn(ptr);
}

/// Serializes the root node to a newly allocated JSON byte slice owned by `allocator`.
pub fn toSlice(
    self: *const Document,
    allocator: std.mem.Allocator,
    options: WriteOptions,
) ![]u8 {
    return self.root().toSlice(allocator, options);
}

/// Serializes the root node to `writer` without allocating an output slice.
pub fn toWriter(
    self: *const Document,
    writer: *std.Io.Writer,
    options: WriteOptions,
) !void {
    return self.root().toWriter(writer, options);
}

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
        .storage = .{ .nodes = pool.items(), .input = owned },
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

    // The input copy (plus four zero padding bytes) comes first, then the node
    // pool, so a decode in place never disturbs the values.
    const input_copy = storage[0 .. input.len + 4];
    @memcpy(input_copy[0..input.len], input);
    @memset(input_copy[input.len..], 0);
    var pool = pool_mod.Pool.initFixed(storage[input.len + 4 ..]);

    const root_index = try reader.read(&pool, input_copy, input.len, options);
    return .{
        .pool = pool,
        .storage = .{ .nodes = pool.items(), .input = input_copy },
        .root_index = root_index,
    };
}

/// Returns the minimum storage size required by `parseInto` for this input
/// length and options.
///
/// Every node occupies at least one input byte, so the node pool never needs
/// more than `16 * input_len` bytes, plus the input copy and alignment padding.
pub fn parseBufferSize(input_len: usize, options: ParseOptions) usize {
    _ = options;
    const values = std.math.mul(usize, input_len, pool_mod.node_size) catch
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
/// documents with a little indentation "pretty" and badly under-size the node
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
