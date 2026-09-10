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
        return self.raw().uni.int;
    }

    /// Returns the unsigned integer value. Asserts that `isUint()` is true.
    pub fn uint(self: Value) u64 {
        std.debug.assert(self.isUint());
        return self.raw().uni.uint;
    }

    /// Returns the floating-point value. Asserts that `isFloat()` is true.
    pub fn float(self: Value) f64 {
        std.debug.assert(self.isFloat());
        return self.raw().uni.float;
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
        // A container's children start at the next pool slot.
        return .{
            .storage = self.storage,
            .index = self.index + 1 + @as(u32, @intCast(index)),
        };
    }

    /// Returns the element at `index`. Asserts that `index` is in bounds.
    pub fn at(self: Array, index: usize) Value {
        const value = self.get(index);
        std.debug.assert(value != null);
        return value.?;
    }

    /// Returns an iterator over the array's values.
    pub fn iterator(self: Array) ArrayIterator {
        return .{ .array = self };
    }
};

/// Iterator returned by `Array.iterator`.
pub const ArrayIterator = struct {
    array: Array,
    index: usize = 0,

    /// Returns the next value, or `null` after the final element.
    pub fn next(self: *ArrayIterator) ?Value {
        const value = self.array.get(self.index) orelse return null;
        self.index += 1;
        return value;
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

    fn keyAt(self: Object, index: usize) *const pool_mod.Value {
        return &self.storage.values[self.index + 1 + @as(u32, @intCast(index)) * 2];
    }

    fn valueAt(self: Object, index: usize) *const pool_mod.Value {
        return &self.storage.values[self.valueIndex(index)];
    }

    fn valueIndex(self: Object, index: usize) u32 {
        return self.index + 2 + @as(u32, @intCast(index)) * 2;
    }

    /// Looks up `key`, returning `null` when it is absent. Keys are compared by
    /// content, not by the escaped text they were read from.
    pub fn get(self: Object, key: []const u8) ?Value {
        const count = self.len();
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const entry_key = self.keyAt(index);
            if (pool_mod.valueLen(entry_key.*) == key.len and
                std.mem.eql(u8, stringAt(self.storage, entry_key), key))
            {
                return .{ .storage = self.storage, .index = self.valueIndex(index) };
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
        return .{ .object = self };
    }
};

/// Iterator returned by `Object.iterator`.
pub const ObjectIterator = struct {
    object: Object,
    index: usize = 0,

    /// Returns the next field, or `null` after the final field.
    pub fn next(self: *ObjectIterator) ?ObjectEntry {
        if (self.index >= self.object.len()) return null;
        const storage = self.object.storage;
        const key = self.object.keyAt(self.index);
        const value_index = self.object.valueIndex(self.index);
        self.index += 1;
        return .{
            .key = stringAt(storage, key),
            .value = .{ .storage = storage, .index = value_index },
        };
    }
};

fn stringAt(storage: *const Storage, value: *const pool_mod.Value) []const u8 {
    const offset: usize = @intCast(value.uni.offset);
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
