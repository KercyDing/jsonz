const std = @import("std");
const bridge = @import("yyjson_c");

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
    pretty: bool = false,
};

pub const Value = struct {
    handle: *const bridge.yyjson_val,

    pub fn kind(self: Value) Kind {
        return @enumFromInt(bridge.jsonz_yyjson_kind(self.handle));
    }

    pub fn isNull(self: Value) bool {
        return self.kind() == .null;
    }

    pub fn isBool(self: Value) bool {
        return self.kind() == .bool;
    }

    pub fn isInt(self: Value) bool {
        return self.kind() == .int;
    }

    pub fn isUint(self: Value) bool {
        return self.kind() == .uint;
    }

    pub fn isFloat(self: Value) bool {
        return self.kind() == .float;
    }

    pub fn isString(self: Value) bool {
        return self.kind() == .string;
    }

    pub fn isArray(self: Value) bool {
        return self.kind() == .array;
    }

    pub fn isObject(self: Value) bool {
        return self.kind() == .object;
    }

    pub fn @"bool"(self: Value) bool {
        std.debug.assert(self.isBool());
        return bridge.jsonz_yyjson_bool(self.handle);
    }

    pub fn int(self: Value) i64 {
        std.debug.assert(self.isInt());
        return bridge.jsonz_yyjson_sint(self.handle);
    }

    pub fn uint(self: Value) u64 {
        std.debug.assert(self.isUint());
        return bridge.jsonz_yyjson_uint(self.handle);
    }

    pub fn float(self: Value) f64 {
        std.debug.assert(self.isFloat());
        return bridge.jsonz_yyjson_real(self.handle);
    }

    pub fn string(self: Value) []const u8 {
        std.debug.assert(self.isString());
        return bridge.jsonz_yyjson_str(self.handle)[0..bridge.jsonz_yyjson_len(self.handle)];
    }

    pub fn array(self: Value) Array {
        std.debug.assert(self.isArray());
        return .{ .handle = self.handle };
    }

    pub fn object(self: Value) Object {
        std.debug.assert(self.isObject());
        return .{ .handle = self.handle };
    }

    pub fn get(self: Value, key: []const u8) ?Value {
        return self.object().get(key);
    }

    pub fn field(self: Value, key: []const u8) Value {
        return self.object().field(key);
    }

    pub fn toSlice(
        self: Value,
        allocator: std.mem.Allocator,
        options: WriteOptions,
    ) ![]u8 {
        return writeToSlice(allocator, self, options);
    }

    pub fn toWriter(
        self: Value,
        writer: *std.Io.Writer,
        options: WriteOptions,
    ) !void {
        return writeToWriter(writer, self, options);
    }
};

pub const Array = struct {
    handle: *const bridge.yyjson_val,

    pub fn len(self: Array) usize {
        return bridge.jsonz_yyjson_size(self.handle);
    }

    pub fn get(self: Array, index: usize) ?Value {
        if (index >= self.len()) return null;
        const value = bridge.jsonz_yyjson_index(self.handle, index) orelse return null;
        return .{ .handle = value };
    }

    pub fn at(self: Array, index: usize) Value {
        const value = self.get(index);
        std.debug.assert(value != null);
        return value.?;
    }

    pub fn iterator(self: Array) ArrayIterator {
        return .{ .array = self };
    }
};

pub const ArrayIterator = struct {
    array: Array,
    index: usize = 0,

    pub fn next(self: *ArrayIterator) ?Value {
        const value = self.array.get(self.index) orelse return null;
        self.index += 1;
        return value;
    }
};

pub const ObjectEntry = struct {
    key: []const u8,
    value: Value,
};

pub const Object = struct {
    handle: *const bridge.yyjson_val,

    pub fn len(self: Object) usize {
        return bridge.jsonz_yyjson_size(self.handle);
    }

    pub fn get(self: Object, key: []const u8) ?Value {
        const value = bridge.jsonz_yyjson_object_get(
            self.handle,
            key.ptr,
            key.len,
        ) orelse return null;
        return .{ .handle = value };
    }

    pub fn field(self: Object, key: []const u8) Value {
        const value = self.get(key);
        std.debug.assert(value != null);
        return value.?;
    }

    pub fn iterator(self: Object) ObjectIterator {
        return .{ .object = self };
    }
};

pub const ObjectIterator = struct {
    object: Object,
    index: usize = 0,

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

pub fn toSlice(
    allocator: std.mem.Allocator,
    value: Value,
    options: WriteOptions,
) ![]u8 {
    return writeToSlice(allocator, value, options);
}

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
