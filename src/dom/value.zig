const std = @import("std");
const pool_mod = @import("pool.zig");
const writer_mod = @import("writer.zig");

/// The JSON kind represented by a DOM value.
pub const Kind = enum {
    null,
    bool,
    uint,
    int,
    float,
    string,
    array,
    object,
};

/// Options that control DOM serialization.
pub const WriteOptions = writer_mod.WriteOptions;

/// Errors returned when a DOM value cannot be read as the requested type.
pub const ValueError = error{
    UnexpectedType,
    OutOfRange,
    MissingField,
    OutOfBounds,
};

/// Numeric types accepted by `Value.as`.
pub const NumberType = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    isize,
    u8,
    u16,
    u32,
    u64,
    u128,
    usize,
    f16,
    f32,
    f64,

    pub fn Type(comptime self: NumberType) type {
        return switch (self) {
            .i8 => i8,
            .i16 => i16,
            .i32 => i32,
            .i64 => i64,
            .i128 => i128,
            .isize => isize,
            .u8 => u8,
            .u16 => u16,
            .u32 => u32,
            .u64 => u64,
            .u128 => u128,
            .usize => usize,
            .f16 => f16,
            .f32 => f32,
            .f64 => f64,
        };
    }
};

/// The parsed storage behind every `Value`.
///
/// `input` is the (owned or caller-provided) JSON buffer whose escape
/// sequences were decoded in place; `values` is the value pool. Both slices are
/// borrowed from the owning `Document` and are only valid while it lives.
pub const Storage = struct {
    values: []const pool_mod.Value,
    input: []const u8,
};

/// A borrowed view of one DOM value; it does not own memory.
pub const Value = struct {
    storage: *const Storage,
    index: u32,

    fn raw(self: Value) *const pool_mod.Value {
        return &self.storage.values[self.index];
    }

    /// Returns this value's JSON kind.
    pub fn kind(self: Value) Kind {
        const value = self.raw();
        return switch (pool_mod.valueType(value.*)) {
            .null => .null,
            .bool => .bool,
            .number => switch (pool_mod.valueSubtype(value.*)) {
                .real => .float,
                .one => .int,
                .none => .uint,
            },
            .string => .string,
            .array => .array,
            .object => .object,
            else => unreachable,
        };
    }

    /// Returns whether this value is JSON `null`.
    pub fn isNull(self: Value) bool {
        return pool_mod.valueType(self.raw().*) == .null;
    }

    /// Returns whether this value is a boolean.
    pub fn isBool(self: Value) bool {
        return pool_mod.valueType(self.raw().*) == .bool;
    }

    /// Returns whether this value is a signed integer.
    pub fn isInt(self: Value) bool {
        return self.kind() == .int;
    }

    /// Returns whether this value is an unsigned integer.
    pub fn isUint(self: Value) bool {
        return self.kind() == .uint;
    }

    /// Returns whether this value is a floating-point number.
    pub fn isFloat(self: Value) bool {
        return self.kind() == .float;
    }

    /// Returns whether this value is a string.
    pub fn isString(self: Value) bool {
        return pool_mod.valueType(self.raw().*) == .string;
    }

    /// Returns whether this value is an array.
    pub fn isArray(self: Value) bool {
        return pool_mod.valueType(self.raw().*) == .array;
    }

    /// Returns whether this value is an object.
    pub fn isObject(self: Value) bool {
        return pool_mod.valueType(self.raw().*) == .object;
    }

    /// Returns the boolean value.
    pub fn toBool(self: Value) ValueError!bool {
        if (!self.isBool()) return error.UnexpectedType;
        return pool_mod.valueSubtype(self.raw().*) == pool_mod.true_value;
    }

    /// Converts this JSON number to the requested numeric type.
    pub fn toNumber(self: Value, comptime target: NumberType) ValueError!target.Type() {
        return switch (target) {
            .i8, .i16, .i32, .i64, .i128, .isize => switch (self.kind()) {
                .int => std.math.cast(target.Type(), self.raw().payload.int) orelse error.OutOfRange,
                .uint => std.math.cast(target.Type(), self.raw().payload.uint) orelse error.OutOfRange,
                else => error.UnexpectedType,
            },
            .u8, .u16, .u32, .u64, .u128, .usize => switch (self.kind()) {
                .uint => std.math.cast(target.Type(), self.raw().payload.uint) orelse error.OutOfRange,
                .int => std.math.cast(target.Type(), self.raw().payload.int) orelse error.OutOfRange,
                else => error.UnexpectedType,
            },
            .f16, .f32, .f64 => switch (self.kind()) {
                .float => @floatCast(self.raw().payload.float),
                .int => @floatFromInt(self.raw().payload.int),
                .uint => @floatFromInt(self.raw().payload.uint),
                else => error.UnexpectedType,
            },
        };
    }

    /// Converts this value to the requested numeric type, or returns `null`
    /// when it is not numeric or does not fit.
    pub fn asNumber(self: Value, comptime target: NumberType) ?target.Type() {
        return self.toNumber(target) catch null;
    }

    /// Returns the boolean value when this value is a boolean, otherwise null.
    pub fn asBool(self: Value) ?bool {
        return self.toBool() catch null;
    }

    /// Returns the borrowed string when this value is a string, otherwise null.
    pub fn asString(self: Value) ?[]const u8 {
        return self.toString() catch null;
    }

    /// Returns the array view when this value is an array, otherwise null.
    pub fn asArray(self: Value) ?Array {
        return self.toArray() catch null;
    }

    /// Returns the object view when this value is an object, otherwise null.
    pub fn asObject(self: Value) ?Object {
        return self.toObject() catch null;
    }

    /// Returns a string slice borrowed from the document.
    pub fn toString(self: Value) ValueError![]const u8 {
        if (!self.isString()) return error.UnexpectedType;
        return stringAt(self.storage, self.raw());
    }

    /// Returns an array view borrowed from the document.
    pub fn toArray(self: Value) ValueError!Array {
        if (!self.isArray()) return error.UnexpectedType;
        return .{ .storage = self.storage, .index = self.index };
    }

    /// Returns an object view borrowed from the document.
    pub fn toObject(self: Value) ValueError!Object {
        if (!self.isObject()) return error.UnexpectedType;
        return .{ .storage = self.storage, .index = self.index };
    }

    /// Looks up an object field, returning `null` when this value is not an
    /// object or the field is absent.
    pub fn get(self: Value, key: []const u8) ?Value {
        const object = self.toObject() catch return null;
        return object.get(key);
    }

    /// Returns an object field, or an error when this value is not an object or
    /// the field does not exist.
    pub fn field(self: Value, key: []const u8) ValueError!Value {
        return (try self.toObject()).field(key);
    }

    /// Traverses a comptime-known sequence of object fields without allocating.
    pub fn fieldPath(self: Value, comptime fields: anytype) FieldPath {
        var current: ?Value = self;
        var failure_info: ?FieldPath.Failure = null;

        inline for (fields, 0..) |field_name, index| {
            const key: []const u8 = field_name;
            if (current) |value| {
                if (value.asObject()) |object| {
                    current = object.get(key) orelse blk: {
                        failure_info = .{
                            .index = index,
                            .field = key,
                            .reason = .missing_field,
                            .found = null,
                        };
                        break :blk null;
                    };
                } else {
                    current = null;
                    failure_info = .{
                        .index = index,
                        .field = key,
                        .reason = .expected_object,
                        .found = value.kind(),
                    };
                }
            }
        }

        return .{ .value = current, .failure_info = failure_info };
    }

    /// Serializes this value to a newly allocated JSON byte slice owned by `allocator`.
    pub fn toSlice(
        self: Value,
        allocator: std.mem.Allocator,
        options: WriteOptions,
    ) ![]u8 {
        return writer_mod.toSlice(allocator, self, options);
    }

    /// Serializes this value to `writer` without allocating an output slice.
    pub fn toWriter(
        self: Value,
        writer: *std.Io.Writer,
        options: WriteOptions,
    ) !void {
        return writer_mod.toWriter(writer, self, options);
    }
};

/// The result of a `Value.fieldPath` traversal.
pub const FieldPath = struct {
    value: ?Value,
    failure_info: ?Failure,

    /// Information about the first failed field lookup.
    pub const Failure = struct {
        index: usize,
        field: []const u8,
        reason: Reason,
        found: ?Kind,
    };

    pub const Reason = enum {
        missing_field,
        expected_object,
    };

    /// Returns information about the first failed field lookup, if any.
    pub fn failure(self: FieldPath) ?Failure {
        return self.failure_info;
    }

    fn resolve(self: FieldPath) ValueError!Value {
        if (self.value) |value| return value;
        return switch ((self.failure_info orelse return error.UnexpectedType).reason) {
            .missing_field => error.MissingField,
            .expected_object => error.UnexpectedType,
        };
    }

    pub fn toBool(self: FieldPath) ValueError!bool {
        return (try self.resolve()).toBool();
    }

    pub fn toNumber(self: FieldPath, comptime target: NumberType) ValueError!target.Type() {
        return (try self.resolve()).toNumber(target);
    }

    pub fn toString(self: FieldPath) ValueError![]const u8 {
        return (try self.resolve()).toString();
    }

    pub fn toArray(self: FieldPath) ValueError!Array {
        return (try self.resolve()).toArray();
    }

    pub fn toObject(self: FieldPath) ValueError!Object {
        return (try self.resolve()).toObject();
    }

    pub fn asBool(self: FieldPath) ?bool {
        return if (self.value) |value| value.asBool() else null;
    }

    pub fn asNumber(self: FieldPath, comptime target: NumberType) ?target.Type() {
        return if (self.value) |value| value.asNumber(target) else null;
    }

    pub fn asString(self: FieldPath) ?[]const u8 {
        return if (self.value) |value| value.asString() else null;
    }

    pub fn asArray(self: FieldPath) ?Array {
        return if (self.value) |value| value.asArray() else null;
    }

    pub fn asObject(self: FieldPath) ?Object {
        return if (self.value) |value| value.asObject() else null;
    }
};

test "safe numeric access" {
    const raw_values = [_]pool_mod.Value{
        .{ .tag = pool_mod.makeTag(.number, .none, 0), .payload = .{ .uint = 42 } },
        .{ .tag = pool_mod.makeTag(.number, .one, 0), .payload = .{ .int = -7 } },
        .{ .tag = pool_mod.makeTag(.number, .real, 0), .payload = .{ .float = 1.5 } },
        .{ .tag = pool_mod.makeTag(.number, .none, 0), .payload = .{ .uint = std.math.maxInt(u64) } },
        .{ .tag = pool_mod.makeTag(.bool, .one, 0), .payload = .{ .uint = 0 } },
    };
    const storage = Storage{ .values = &raw_values, .input = &.{} };
    const value = Value{ .storage = &storage, .index = 0 };
    const signed = Value{ .storage = &storage, .index = 1 };
    const floating = Value{ .storage = &storage, .index = 2 };
    const large = Value{ .storage = &storage, .index = 3 };
    const boolean = Value{ .storage = &storage, .index = 4 };

    try std.testing.expectEqual(@as(?i8, 42), value.asNumber(.i8));
    try std.testing.expectEqual(@as(?u8, 42), value.asNumber(.u8));
    try std.testing.expectEqual(@as(?f32, 42.0), value.asNumber(.f32));
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

/// A borrowed view of a JSON array.
pub const Array = struct {
    storage: *const Storage,
    index: u32,

    /// Returns the number of elements.
    pub fn len(self: Array) usize {
        return pool_mod.valueLen(self.storage.values[self.index]);
    }

    /// Returns the element at `index`, or `null` when the index is out of bounds.
    pub fn get(self: Array, index: usize) ?Value {
        if (index >= self.len()) return null;
        // Children are stored depth-first, so an earlier child that is itself a
        // container occupies its whole subtree, not one slot.
        var cursor = self.index + 1;
        var remaining = index;
        while (remaining != 0) : (remaining -= 1) {
            cursor += subtreeLength(self.storage, cursor);
        }
        return .{ .storage = self.storage, .index = cursor };
    }

    /// Returns the element at `index`, or `error.OutOfBounds` when it is out of bounds.
    pub fn at(self: Array, index: usize) ValueError!Value {
        return self.get(index) orelse error.OutOfBounds;
    }

    /// Returns an iterator over the array's values.
    pub fn iterator(self: Array) ArrayIterator {
        return .{ .array = self, .remaining = self.len(), .cursor = self.index + 1 };
    }
};

/// Iterator returned by `Array.iterator`.
pub const ArrayIterator = struct {
    array: Array,
    remaining: usize,
    /// Pool slot of the next element.
    cursor: u32,

    /// Returns the next value, or `null` after the final element.
    pub fn next(self: *ArrayIterator) ?Value {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const index = self.cursor;
        self.cursor += subtreeLength(self.array.storage, index);
        return .{ .storage = self.array.storage, .index = index };
    }
};

/// One key/value pair yielded by `ObjectIterator`.
/// Both fields borrow from the source document.
pub const ObjectEntry = struct {
    key: []const u8,
    value: Value,
};

/// A borrowed view of a JSON object.
pub const Object = struct {
    storage: *const Storage,
    index: u32,

    /// Returns the number of fields.
    pub fn len(self: Object) usize {
        return pool_mod.valueLen(self.storage.values[self.index]);
    }

    /// Pool slot of the `index`-th key; the value follows it.
    fn keyIndex(self: Object, index: usize) u32 {
        var cursor = self.index + 1;
        var remaining = index;
        while (remaining != 0) : (remaining -= 1) {
            // A key is one slot, and its value is one slot plus its subtree.
            cursor += 1 + subtreeLength(self.storage, cursor + 1);
        }
        return cursor;
    }

    /// Looks up `key`, returning `null` when it is absent. Keys are compared by
    /// content, not by the escaped text they were read from.
    pub fn get(self: Object, key: []const u8) ?Value {
        const count = self.len();
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const cursor = self.keyIndex(index);
            const entry_key = &self.storage.values[cursor];
            if (pool_mod.valueLen(entry_key.*) == key.len and
                std.mem.eql(u8, stringAt(self.storage, entry_key), key))
            {
                return .{ .storage = self.storage, .index = cursor + 1 };
            }
        }
        return null;
    }

    /// Returns `key`'s value, or `error.MissingField` when it does not exist.
    pub fn field(self: Object, key: []const u8) ValueError!Value {
        return self.get(key) orelse error.MissingField;
    }

    /// Returns an iterator over the object's fields in document order.
    pub fn iterator(self: Object) ObjectIterator {
        return .{ .object = self, .remaining = self.len(), .cursor = self.index + 1 };
    }
};

/// Iterator returned by `Object.iterator`.
pub const ObjectIterator = struct {
    object: Object,
    remaining: usize,
    /// Pool slot of the next key.
    cursor: u32,

    /// Returns the next field, or `null` after the final field.
    pub fn next(self: *ObjectIterator) ?ObjectEntry {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const storage = self.object.storage;
        const key = self.cursor;
        const value_index = key + 1;
        self.cursor = value_index + subtreeLength(storage, value_index);
        return .{
            .key = stringAt(storage, &storage.values[key]),
            .value = .{ .storage = storage, .index = value_index },
        };
    }
};

/// The number of pool slots the value at `index` occupies: one for a scalar,
/// and the whole subtree for a container.
inline fn subtreeLength(storage: *const Storage, index: u32) u32 {
    const value = &storage.values[index];
    return switch (pool_mod.valueType(value.*)) {
        .array, .object => @intCast(value.payload.offset / pool_mod.value_size),
        else => 1,
    };
}

fn stringAt(storage: *const Storage, value: *const pool_mod.Value) []const u8 {
    const offset: usize = @intCast(value.payload.offset);
    return storage.input[offset..][0..pool_mod.valueLen(value.*)];
}

/// Serializes a DOM value to a newly allocated JSON byte slice owned by `allocator`.
pub fn toSlice(
    allocator: std.mem.Allocator,
    value: Value,
    options: WriteOptions,
) ![]u8 {
    return writer_mod.toSlice(allocator, value, options);
}

/// Serializes a DOM value to `writer` without allocating an output slice.
pub fn toWriter(
    writer: *std.Io.Writer,
    value: Value,
    options: WriteOptions,
) !void {
    return writer_mod.toWriter(writer, value, options);
}
