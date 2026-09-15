/// A borrowed view of one DOM node; it does not own memory.
const Node = @This();

const std = @import("std");
const pool_mod = @import("../pool.zig");
const writer_mod = @import("writer.zig");
const common = @import("../common.zig");
const rfc = @import("../rfc.zig");

/// The kind of a DOM value.
const Kind = common.Kind;
/// Options that control DOM serialization.
const WriteOptions = common.WriteOptions;
/// Errors returned when a node cannot be accessed or converted.
const AccessError = common.AccessError;
/// Errors from resolving an RFC 6901 JSON Pointer.
const PointerError = common.PointerError;
/// Numeric types accepted by `Node.toNumber` and `Node.asNumber`.
const NumberType = common.NumberType;
/// The parsed storage behind every `Node`.
pub const Storage = common.Storage;
storage: *const Storage,
index: u32,

/// One key/value pair yielded by `ObjectIterator`. Both fields borrow from
/// the source document.
pub const ObjectEntry = struct {
    key: []const u8,
    value: Node,
};

/// Iterator over an object's fields in document order.
pub const ObjectIterator = struct {
    storage: *const Storage,
    remaining: usize,
    /// Pool slot of the next key.
    cursor: u32,

    /// Returns the next field, or `null` after the final field.
    pub fn next(self: *ObjectIterator) ?ObjectEntry {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const key = self.cursor;
        const node_index = key + 1;
        self.cursor = node_index + subtreeLength(self.storage, node_index);
        return .{
            .key = stringAt(self.storage, &self.storage.nodes[key]),
            .value = .{ .storage = self.storage, .index = node_index },
        };
    }
};

/// Iterator over an array's elements in document order.
pub const ArrayIterator = struct {
    storage: *const Storage,
    remaining: usize,
    /// Pool slot of the next element.
    cursor: u32,

    /// Returns the next element, or `null` after the final element.
    pub fn next(self: *ArrayIterator) ?Node {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const index = self.cursor;
        self.cursor += subtreeLength(self.storage, index);
        return .{ .storage = self.storage, .index = index };
    }
};

fn raw(self: Node) *const pool_mod.NodeData {
    return &self.storage.nodes[self.index];
}

/// Returns this node's JSON kind.
pub fn kind(self: Node) Kind {
    const node = self.raw();
    return switch (pool_mod.nodeType(node.*)) {
        .null => .null,
        .bool => .bool,
        .number => .number,
        .string => .string,
        .array => .array,
        .object => .object,
        else => unreachable,
    };
}

/// Returns whether this node is JSON `null`.
pub fn isNull(self: Node) bool {
    return pool_mod.nodeType(self.raw().*) == .null;
}

/// Returns whether this node is a boolean.
pub fn isBool(self: Node) bool {
    return pool_mod.nodeType(self.raw().*) == .bool;
}

/// Returns whether this node can be converted to the requested numeric type.
pub fn isNumber(self: Node, comptime target: NumberType) bool {
    _ = self.toNumber(target) catch return false;
    return true;
}

/// Returns whether this node is a string.
pub fn isString(self: Node) bool {
    return pool_mod.nodeType(self.raw().*) == .string;
}

/// Returns whether this node is an array.
pub fn isArray(self: Node) bool {
    return pool_mod.nodeType(self.raw().*) == .array;
}

/// Returns whether this node is an object.
pub fn isObject(self: Node) bool {
    return pool_mod.nodeType(self.raw().*) == .object;
}

/// Returns the boolean payload.
pub fn toBool(self: Node) AccessError!bool {
    if (!self.isBool()) return error.UnexpectedType;
    return pool_mod.nodeSubtype(self.raw().*) == pool_mod.true_flag;
}

/// Converts this JSON number to the requested numeric type.
pub fn toNumber(self: Node, comptime target: NumberType) AccessError!target.Type() {
    if (pool_mod.nodeType(self.raw().*) != .number) return error.UnexpectedType;
    return switch (target) {
        .i8, .i16, .i32, .i64, .i128, .isize => switch (pool_mod.nodeSubtype(self.raw().*)) {
            .one => std.math.cast(target.Type(), self.raw().payload.int) orelse error.OutOfRange,
            .none => std.math.cast(target.Type(), self.raw().payload.uint) orelse error.OutOfRange,
            else => error.UnexpectedType,
        },
        .u8, .u16, .u32, .u64, .u128, .usize => switch (pool_mod.nodeSubtype(self.raw().*)) {
            .none => std.math.cast(target.Type(), self.raw().payload.uint) orelse error.OutOfRange,
            .one => std.math.cast(target.Type(), self.raw().payload.int) orelse error.OutOfRange,
            else => error.UnexpectedType,
        },
        .f16, .f32, .f64 => switch (pool_mod.nodeSubtype(self.raw().*)) {
            .real => @floatCast(self.raw().payload.float),
            .one => @floatFromInt(self.raw().payload.int),
            .none => @floatFromInt(self.raw().payload.uint),
        },
    };
}

/// Returns a string slice borrowed from the document.
pub fn toString(self: Node) AccessError![]const u8 {
    if (!self.isString()) return error.UnexpectedType;
    return stringAt(self.storage, self.raw());
}

/// Converts this node to the requested numeric type, or returns `null`
/// when it is not numeric or does not fit.
pub fn asNumber(self: Node, comptime target: NumberType) ?target.Type() {
    return self.toNumber(target) catch null;
}

/// Returns the boolean payload when this node is a boolean, otherwise null.
pub fn asBool(self: Node) ?bool {
    return self.toBool() catch null;
}

/// Returns the borrowed string when this node is a string, otherwise null.
pub fn asString(self: Node) ?[]const u8 {
    return self.toString() catch null;
}

/// Returns the number of fields or elements in this container.
pub fn len(self: Node) AccessError!usize {
    if (!self.isArray() and !self.isObject()) return error.UnexpectedType;
    return pool_mod.nodeLen(self.raw().*);
}

/// Looks up an object field, returning `null` when this node is not an
/// object or the field is absent.
pub fn get(self: Node, key: []const u8) ?Node {
    if (!self.isObject()) return null;
    return getObjectUnchecked(self, key);
}

/// Returns an object field, or an error when this node is not an object or
/// the field does not exist.
pub fn field(self: Node, key: []const u8) AccessError!Node {
    if (!self.isObject()) return error.UnexpectedType;
    return getObjectUnchecked(self, key) orelse error.MissingField;
}

/// Returns an array element, or `null` when this node is not an array or
/// the index is out of bounds.
pub fn getAt(self: Node, index: usize) ?Node {
    if (!self.isArray()) return null;
    return getArrayUnchecked(self, index);
}

/// Returns an array element, or an error when this node is not an array or
/// the index is out of bounds.
pub fn at(self: Node, index: usize) AccessError!Node {
    if (!self.isArray()) return error.UnexpectedType;
    return getArrayUnchecked(self, index) orelse error.OutOfBounds;
}

/// Returns an iterator over this object's fields.
pub fn objectIterator(self: Node) AccessError!ObjectIterator {
    if (!self.isObject()) return error.UnexpectedType;
    return .{
        .storage = self.storage,
        .remaining = pool_mod.nodeLen(self.raw().*),
        .cursor = self.index + 1,
    };
}

/// Returns an iterator over this array's elements.
pub fn arrayIterator(self: Node) AccessError!ArrayIterator {
    if (!self.isArray()) return error.UnexpectedType;
    return .{
        .storage = self.storage,
        .remaining = pool_mod.nodeLen(self.raw().*),
        .cursor = self.index + 1,
    };
}

/// Resolves a comptime-known RFC 6901 JSON Pointer.
pub fn ptrGet(self: Node, comptime ptr: []const u8) PointerError!Node {
    return rfc.resolveStatic(self, ptr);
}

/// Resolves a comptime-known pointer format expanded with `std.fmt`
/// semantics. Interpolation is textual and never escapes anything.
pub fn ptrGetFmt(self: Node, comptime fmt: []const u8, args: anytype) PointerError!Node {
    return rfc.resolveFmt(self, fmt, args);
}

/// Resolves a complete RFC 6901 JSON Pointer known only at runtime.
pub fn ptrGetDyn(self: Node, ptr: []const u8) PointerError!Node {
    return rfc.resolve(self, ptr);
}

/// Serializes this node to a newly allocated JSON byte slice owned by `allocator`.
pub fn toSlice(
    self: Node,
    allocator: std.mem.Allocator,
    options: WriteOptions,
) ![]u8 {
    return writer_mod.toSlice(allocator, self, options);
}

/// Serializes this node to `writer` without allocating an output slice.
pub fn toWriter(
    self: Node,
    writer: *std.Io.Writer,
    options: WriteOptions,
) !void {
    return writer_mod.toWriter(writer, self, options);
}

inline fn getObjectUnchecked(self: Node, key: []const u8) ?Node {
    const count = pool_mod.nodeLen(self.raw().*);
    var cursor = self.index + 1;
    for (0..count) |_| {
        const key_index = cursor;
        const node_index = key_index + 1;
        const entry_key = &self.storage.nodes[key_index];
        if (pool_mod.nodeLen(entry_key.*) == key.len and
            std.mem.eql(u8, stringAt(self.storage, entry_key), key))
        {
            return .{ .storage = self.storage, .index = node_index };
        }
        cursor = node_index + subtreeLength(self.storage, node_index);
    }
    return null;
}

inline fn getArrayUnchecked(self: Node, index: usize) ?Node {
    if (index >= pool_mod.nodeLen(self.raw().*)) return null;
    var cursor = self.index + 1;
    var remaining = index;
    while (remaining != 0) : (remaining -= 1) {
        cursor += subtreeLength(self.storage, cursor);
    }
    return .{ .storage = self.storage, .index = cursor };
}

/// The number of pool slots the node at `index` occupies: one for a scalar,
/// and the whole subtree for a container.
inline fn subtreeLength(storage: *const Storage, index: u32) u32 {
    const node = &storage.nodes[index];
    return switch (pool_mod.nodeType(node.*)) {
        .array, .object => @intCast(node.payload.offset / pool_mod.node_size),
        else => 1,
    };
}

fn stringAt(storage: *const Storage, node: *const pool_mod.NodeData) []const u8 {
    const offset: usize = @intCast(node.payload.offset);
    return storage.input[offset..][0..pool_mod.nodeLen(node.*)];
}

test "safe numeric access" {
    const raw_nodes = [_]pool_mod.NodeData{
        .{ .tag = pool_mod.makeTag(.number, .none, 0), .payload = .{ .uint = 42 } },
        .{ .tag = pool_mod.makeTag(.number, .one, 0), .payload = .{ .int = -7 } },
        .{ .tag = pool_mod.makeTag(.number, .real, 0), .payload = .{ .float = 1.5 } },
        .{ .tag = pool_mod.makeTag(.number, .none, 0), .payload = .{ .uint = std.math.maxInt(u64) } },
        .{ .tag = pool_mod.makeTag(.bool, .one, 0), .payload = .{ .uint = 0 } },
    };
    const storage = Storage{ .nodes = &raw_nodes, .input = &.{} };
    const node = Node{ .storage = &storage, .index = 0 };
    const signed = Node{ .storage = &storage, .index = 1 };
    const floating = Node{ .storage = &storage, .index = 2 };
    const large = Node{ .storage = &storage, .index = 3 };
    const boolean = Node{ .storage = &storage, .index = 4 };

    try std.testing.expectEqual(@as(?i8, 42), node.asNumber(.i8));
    try std.testing.expectEqual(@as(?u8, 42), node.asNumber(.u8));
    try std.testing.expectEqual(@as(?f32, 42.0), node.asNumber(.f32));
    try std.testing.expectEqual(@as(?i64, -7), signed.asNumber(.i64));
    try std.testing.expect(signed.asNumber(.u64) == null);
    try std.testing.expectEqual(@as(?f64, -7.0), signed.asNumber(.f64));
    try std.testing.expect(floating.asNumber(.i64) == null);
    try std.testing.expect(floating.asNumber(.u64) == null);
    try std.testing.expectEqual(@as(?f32, 1.5), floating.asNumber(.f32));
    try std.testing.expect(large.asNumber(.i64) == null);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), large.asNumber(.u64));
    try std.testing.expect(boolean.asNumber(.f32) == null);
    try std.testing.expectEqual(@as(?bool, true), boolean.asBool());
    try std.testing.expectEqual(@as(?[]const u8, null), boolean.asString());
}
