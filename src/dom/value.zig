const std = @import("std");
const bridge = @import("yyjson_c");

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

pub const WriteOptions = struct {
    /// Format objects and arrays with indentation and line breaks.
    pretty: bool = false,
};

/// A lightweight view of a value owned by a `Document`.
///
/// It does not own memory and is invalid after its source document is deinitialized.
pub const Value = struct {
    handle: *const bridge.yyjson_val,

    /// Returns this value's JSON kind.
    pub fn kind(self: Value) Kind {
        return @enumFromInt(bridge.jsonz_yyjson_kind(self.handle));
    }

    /// Returns whether this value is JSON `null`.
    pub fn isNull(self: Value) bool {
        return self.kind() == .null;
    }

    /// Returns whether this value is a boolean.
    pub fn isBool(self: Value) bool {
        return self.kind() == .bool;
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
        return self.kind() == .string;
    }

    /// Returns whether this value is an array.
    pub fn isArray(self: Value) bool {
        return self.kind() == .array;
    }

    /// Returns whether this value is an object.
    pub fn isObject(self: Value) bool {
        return self.kind() == .object;
    }

    /// Returns the boolean value. Asserts that `isBool()` is true.
    pub fn @"bool"(self: Value) bool {
        std.debug.assert(self.isBool());
        return bridge.jsonz_yyjson_bool(self.handle);
    }

    /// Returns the signed integer value. Asserts that `isInt()` is true.
    pub fn int(self: Value) i64 {
        std.debug.assert(self.isInt());
        return bridge.jsonz_yyjson_sint(self.handle);
    }

    /// Returns the unsigned integer value. Asserts that `isUint()` is true.
    pub fn uint(self: Value) u64 {
        std.debug.assert(self.isUint());
        return bridge.jsonz_yyjson_uint(self.handle);
    }

    /// Returns the floating-point value. Asserts that `isFloat()` is true.
    pub fn float(self: Value) f64 {
        std.debug.assert(self.isFloat());
        return bridge.jsonz_yyjson_real(self.handle);
    }

    /// Returns a string slice borrowed from the source document. Asserts that `isString()` is true.
    pub fn string(self: Value) []const u8 {
        std.debug.assert(self.isString());
        return bridge.jsonz_yyjson_str(self.handle)[0..bridge.jsonz_yyjson_len(self.handle)];
    }

    /// Returns an array view borrowed from the source document. Asserts that `isArray()` is true.
    pub fn array(self: Value) Array {
        std.debug.assert(self.isArray());
        return .{ .handle = self.handle };
    }

    /// Returns an object view borrowed from the source document. Asserts that `isObject()` is true.
    pub fn object(self: Value) Object {
        std.debug.assert(self.isObject());
        return .{ .handle = self.handle };
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
        return writeToSlice(allocator, self, options);
    }

    /// Serializes this value to `writer` without allocating an output slice.
    pub fn toWriter(
        self: Value,
        writer: *std.Io.Writer,
        options: WriteOptions,
    ) !void {
        return writeToWriter(writer, self, options);
    }
};

/// A borrowed view of a JSON array.
pub const Array = struct {
    handle: *const bridge.yyjson_val,

    /// Returns the number of elements.
    pub fn len(self: Array) usize {
        return bridge.jsonz_yyjson_size(self.handle);
    }

    /// Returns the element at `index`, or `null` when the index is out of bounds.
    pub fn get(self: Array, index: usize) ?Value {
        if (index >= self.len()) return null;
        const value = bridge.jsonz_yyjson_index(self.handle, index) orelse return null;
        return .{ .handle = value };
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
    handle: *const bridge.yyjson_val,

    /// Returns the number of fields.
    pub fn len(self: Object) usize {
        return bridge.jsonz_yyjson_size(self.handle);
    }

    /// Looks up `key`, returning `null` when it is absent.
    pub fn get(self: Object, key: []const u8) ?Value {
        const value = bridge.jsonz_yyjson_object_get(
            self.handle,
            key.ptr,
            key.len,
        ) orelse return null;
        return .{ .handle = value };
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

        const key = bridge.jsonz_yyjson_object_key(
            self.object.handle,
            self.index,
        );
        const key_len = bridge.jsonz_yyjson_object_key_len(
            self.object.handle,
            self.index,
        );
        const value = bridge.jsonz_yyjson_object_value(
            self.object.handle,
            self.index,
        ) orelse return null;
        self.index += 1;

        return .{
            .key = key[0..key_len],
            .value = .{ .handle = value },
        };
    }
};

/// Serializes a DOM value to a newly allocated JSON byte slice owned by `allocator`.
pub fn toSlice(
    allocator: std.mem.Allocator,
    value: Value,
    options: WriteOptions,
) ![]u8 {
    return writeToSlice(allocator, value, options);
}

/// Serializes a DOM value to `writer` without allocating an output slice.
pub fn toWriter(
    writer: *std.Io.Writer,
    value: Value,
    options: WriteOptions,
) !void {
    return writeToWriter(writer, value, options);
}

fn writeToSlice(
    allocator: std.mem.Allocator,
    value: Value,
    options: WriteOptions,
) ![]u8 {
    var len: usize = 0;
    const raw = bridge.jsonz_yyjson_write(
        value.handle,
        options.pretty,
        &len,
    ) orelse return error.InvalidValue;
    defer std.c.free(raw);
    return allocator.dupe(u8, raw[0..len]);
}

fn writeToWriter(
    writer: *std.Io.Writer,
    value: Value,
    options: WriteOptions,
) !void {
    const output = try writeToSlice(std.heap.c_allocator, value, options);
    defer std.heap.c_allocator.free(output);
    try writer.writeAll(output);
}
