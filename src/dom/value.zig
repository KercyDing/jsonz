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

    /// Returns the boolean value. Asserts that `isBool()` is true.
    pub fn @"bool"(self: Value) bool {
        std.debug.assert(self.isBool());
        return pool_mod.valueSubtype(self.raw().*) == pool_mod.true_value;
    }

    /// Returns the signed integer value. Asserts that `isInt()` is true.
    pub fn int(self: Value) i64 {
        std.debug.assert(self.isInt());
        return self.raw().payload.int;
    }

    /// Returns the unsigned integer value. Asserts that `isUint()` is true.
    pub fn uint(self: Value) u64 {
        std.debug.assert(self.isUint());
        return self.raw().payload.uint;
    }

    /// Returns the floating-point value. Asserts that `isFloat()` is true.
    pub fn float(self: Value) f64 {
        std.debug.assert(self.isFloat());
        return self.raw().payload.float;
    }

    /// Returns this value as a signed integer when it is an integer that fits
    /// in `i64`; otherwise returns `null`.
    pub fn asInt(self: Value) ?i64 {
        return switch (self.kind()) {
            .int => self.int(),
            .uint => if (self.uint() <= std.math.maxInt(i64)) @intCast(self.uint()) else null,
            else => null,
        };
    }

    /// Returns this value as an unsigned integer when it is a non-negative
    /// integer that fits in `u64`; otherwise returns `null`.
    pub fn asUint(self: Value) ?u64 {
        return switch (self.kind()) {
            .uint => self.uint(),
            .int => if (self.int() >= 0) @intCast(self.int()) else null,
            else => null,
        };
    }

    /// Returns this value as an `f64`. Integer values are converted and may
    /// lose precision; non-numeric values return `null`.
    pub fn asFloat(self: Value) ?f64 {
        return switch (self.kind()) {
            .float => self.float(),
            .int => @floatFromInt(self.int()),
            .uint => @floatFromInt(self.uint()),
            else => null,
        };
    }

    /// Returns a string slice borrowed from the document. Asserts that `isString()` is true.
    pub fn string(self: Value) []const u8 {
        std.debug.assert(self.isString());
        return stringAt(self.storage, self.raw());
    }

    /// Returns an array view borrowed from the document. Asserts that `isArray()` is true.
    pub fn array(self: Value) Array {
        std.debug.assert(self.isArray());
        return .{ .storage = self.storage, .index = self.index };
    }

    /// Returns an object view borrowed from the document. Asserts that `isObject()` is true.
    pub fn object(self: Value) Object {
        std.debug.assert(self.isObject());
        return .{ .storage = self.storage, .index = self.index };
    }

    /// Looks up an object field, returning `null` when the field is absent.
    /// Asserts that this value is an object.
    pub fn get(self: Value, key: []const u8) ?Value {
        return self.object().get(key);
    }

    /// Returns an object field. Asserts that this value is an object and the field exists.
    pub fn field(self: Value, key: []const u8) Value {
        return self.object().field(key);
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

    try std.testing.expectEqual(@as(?i64, 42), value.asInt());
    try std.testing.expectEqual(@as(?u64, 42), value.asUint());
    try std.testing.expectEqual(@as(?f64, 42.0), value.asFloat());
    try std.testing.expectEqual(@as(?i64, -7), signed.asInt());
    try std.testing.expect(signed.asUint() == null);
    try std.testing.expectEqual(@as(?f64, -7.0), signed.asFloat());
    try std.testing.expect(floating.asInt() == null);
    try std.testing.expect(floating.asUint() == null);
    try std.testing.expectEqual(@as(?f64, 1.5), floating.asFloat());
    try std.testing.expect(large.asInt() == null);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), large.asUint());
    try std.testing.expect(boolean.asFloat() == null);
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

    /// Returns the element at `index`. Asserts that `index` is in bounds.
    pub fn at(self: Array, index: usize) Value {
        const value = self.get(index);
        std.debug.assert(value != null);
        return value.?;
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

    /// Returns `key`'s value. Asserts that the field exists.
    pub fn field(self: Object, key: []const u8) Value {
        const value = self.get(key);
        std.debug.assert(value != null);
        return value.?;
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
