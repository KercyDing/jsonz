const std = @import("std");
const bridge = @import("yyjson_c");

pub const Kind = enum {
    null,
    bool,
    uint,
    sint,
    float,
    string,
    array,
    object,
};

pub const ParseOptions = struct {
    allow_comments: bool = false,
    allow_trailing_commas: bool = false,
};

pub const WriteOptions = struct {
    pretty: bool = false,
};

pub const ParseError = error{ InvalidJson, OutOfMemory };

pub const Document = struct {
    handle: *bridge.yyjson_doc,

    pub fn root(self: *const Document) Value {
        return .{ .handle = bridge.jsonz_yyjson_root(self.handle) orelse unreachable };
    }

    pub fn deinit(self: *Document) void {
        bridge.jsonz_yyjson_free(self.handle);
        self.* = undefined;
    }
};

pub const Value = struct {
    handle: *const bridge.yyjson_val,

    pub fn kind(self: Value) Kind {
        return @enumFromInt(bridge.jsonz_yyjson_kind(self.handle));
    }

    pub fn isNull(self: Value) bool {
        return self.kind() == .null;
    }

    pub fn boolean(self: Value) ?bool {
        return if (self.kind() == .bool) bridge.jsonz_yyjson_bool(self.handle) else null;
    }

    pub fn uint(self: Value) ?u64 {
        return if (self.kind() == .uint) bridge.jsonz_yyjson_uint(self.handle) else null;
    }

    pub fn sint(self: Value) ?i64 {
        return if (self.kind() == .sint) bridge.jsonz_yyjson_sint(self.handle) else null;
    }

    pub fn float(self: Value) ?f64 {
        return if (self.kind() == .float) bridge.jsonz_yyjson_real(self.handle) else null;
    }

    pub fn string(self: Value) ?[]const u8 {
        return if (self.kind() == .string) bridge.jsonz_yyjson_str(self.handle)[0..bridge.jsonz_yyjson_len(self.handle)] else null;
    }

    pub fn array(self: Value) ?Array {
        return if (self.kind() == .array) .{ .handle = self.handle } else null;
    }

    pub fn object(self: Value) ?Object {
        return if (self.kind() == .object) .{ .handle = self.handle } else null;
    }
};

pub const Array = struct {
    handle: *const bridge.yyjson_val,

    pub fn len(self: Array) usize {
        return bridge.jsonz_yyjson_size(self.handle);
    }

    pub fn get(self: Array, i: usize) ?Value {
        return if (bridge.jsonz_yyjson_index(self.handle, i)) |v| .{ .handle = v } else null;
    }

    pub fn iterator(self: Array) ArrayIterator {
        return .{ .array = self };
    }
};

pub const ArrayIterator = struct {
    array: Array,
    index: usize = 0,

    pub fn next(self: *ArrayIterator) ?Value {
        const v = self.array.get(self.index) orelse return null;
        self.index += 1;
        return v;
    }
};

pub const ObjectEntry = struct { key: []const u8, value: Value };

pub const Object = struct {
    handle: *const bridge.yyjson_val,

    pub fn len(self: Object) usize {
        return bridge.jsonz_yyjson_size(self.handle);
    }

    pub fn get(self: Object, key: []const u8) ?Value {
        var i: usize = 0;
        while (i < self.len()) : (i += 1) {
            const k = bridge.jsonz_yyjson_object_key(self.handle, i);
            const n = bridge.jsonz_yyjson_object_key_len(self.handle, i);
            if (std.mem.eql(u8, k[0..n], key)) return .{ .handle = bridge.jsonz_yyjson_object_value(self.handle, i) orelse return null };
        }
        return null;
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
        const k = bridge.jsonz_yyjson_object_key(self.object.handle, self.index);
        const n = bridge.jsonz_yyjson_object_key_len(self.object.handle, self.index);
        const v = bridge.jsonz_yyjson_object_value(self.object.handle, self.index) orelse return null;
        self.index += 1;
        return .{ .key = k[0..n], .value = .{ .handle = v } };
    }
};

pub fn parse(input: []const u8, options: ParseOptions) ParseError!Document {
    var code: c_int = 0;
    const d = bridge.jsonz_yyjson_read(@constCast(input.ptr), input.len, options.allow_comments, options.allow_trailing_commas, &code) orelse return if (code == 2) error.OutOfMemory else error.InvalidJson;
    return .{ .handle = d };
}

pub fn toSliceValue(allocator: std.mem.Allocator, value: Value, options: WriteOptions) ![]u8 {
    var n: usize = 0;
    const raw = bridge.jsonz_yyjson_write(value.handle, options.pretty, &n) orelse return error.InvalidValue;
    defer std.c.free(raw);
    return allocator.dupe(u8, raw[0..n]);
}

test "parses nested values" {
    var document = try parse(
        "{\"enabled\":true,\"count\":42,\"items\":[null,\"jsonz\",-7,1.5]}",
        .{},
    );
    defer document.deinit();

    const root = document.root();
    const object = root.object().?;
    try std.testing.expectEqual(Kind.object, root.kind());
    try std.testing.expect(object.get("enabled").?.boolean().?);
    try std.testing.expectEqual(@as(u64, 42), object.get("count").?.uint().?);

    const items = object.get("items").?.array().?;
    try std.testing.expect(items.get(0).?.isNull());
    try std.testing.expectEqualStrings("jsonz", items.get(1).?.string().?);
    try std.testing.expectEqual(@as(i64, -7), items.get(2).?.sint().?);
    try std.testing.expectEqual(@as(f64, 1.5), items.get(3).?.float().?);
}

test "iterates containers" {
    var document = try parse("{\"a\":1,\"b\":2}", .{});
    defer document.deinit();

    var iterator = document.root().object().?.iterator();
    var count: usize = 0;
    while (iterator.next()) |entry| {
        try std.testing.expect(entry.value.kind() == .uint);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "writes parsed value" {
    var document = try parse("{\"name\":\"jsonz\",\"values\":[1,2]}", .{});
    defer document.deinit();

    const output = try toSliceValue(std.testing.allocator, document.root(), .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("{\"name\":\"jsonz\",\"values\":[1,2]}", output);
}

test "rejects invalid input" {
    try std.testing.expectError(error.InvalidJson, parse("{", .{}));
}
