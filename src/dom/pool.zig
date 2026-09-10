const std = @import("std");

/// Every immutable DOM value uses this exact two-word layout.
/// `tag` packs type, subtype, and container length; `uni` is the scalar value,
/// string offset, or a relative value-pool offset.
pub const Value = extern struct {
    tag: u64,
    uni: u64,
};

pub const Type = enum(u3) {
    none = 0,
    raw = 1,
    null = 2,
    bool = 3,
    number = 4,
    string = 5,
    array = 6,
    object = 7,
};

pub const Subtype = enum(u2) {
    none = 0,
    one = 1,
    real = 2,
};

pub const false_value: Subtype = .none;
pub const true_value: Subtype = .one;
pub const uint: Subtype = .none;
pub const sint: Subtype = .one;
pub const no_escape: Subtype = .one;

pub const type_mask: u64 = 0x07;
pub const subtype_mask: u64 = 0x18;
pub const tag_bits = 8;
pub const value_size = @sizeOf(Value);

pub fn makeTag(value_type: Type, subtype: Subtype, len: usize) u64 {
    return (@as(u64, @intCast(len)) << tag_bits) |
        @as(u64, @intFromEnum(value_type)) |
        (@as(u64, @intFromEnum(subtype)) << 3);
}

pub fn valueType(value: Value) Type {
    return @enumFromInt(value.tag & type_mask);
}

pub fn valueSubtype(value: Value) Subtype {
    return @enumFromInt((value.tag & subtype_mask) >> 3);
}

pub fn valueLen(value: Value) usize {
    return @intCast(value.tag >> tag_bits);
}

/// Container links use byte offsets rather than pointers, so the
/// reader can grow the contiguous value array with realloc.
pub fn byteOffset(from: u32, to: u32) u64 {
    return (@as(u64, to) - @as(u64, from)) * value_size;
}

pub fn indexAtOffset(from: u32, offset: u64) u32 {
    std.debug.assert(offset % value_size == 0);
    return from + @as(u32, @intCast(offset / value_size));
}

/// Reader value storage with input-size capacity estimates and 1.5x
/// growth factor. Values are addressed by index, so a realloc never invalidates
/// a stored container offset.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(Value) = .empty,

    pub fn init(allocator: std.mem.Allocator, input_len: usize, pretty: bool) !Pool {
        var pool: Pool = .{ .allocator = allocator };
        const ratio: usize = if (pretty) 16 else 6;
        const estimate = input_len / ratio + 4;
        try pool.values.ensureTotalCapacityPrecise(allocator, estimate);
        return pool;
    }

    pub fn deinit(self: *Pool) void {
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Pool, value: Value) !u32 {
        try self.ensureUnusedCapacity(1);
        const index = self.values.items.len;
        self.values.appendAssumeCapacity(value);
        return std.math.cast(u32, index) orelse error.OutOfMemory;
    }

    pub fn at(self: *const Pool, index: u32) *const Value {
        return &self.values.items[index];
    }

    pub fn atMut(self: *Pool, index: u32) *Value {
        return &self.values.items[index];
    }

    fn ensureUnusedCapacity(self: *Pool, additional: usize) !void {
        const required = std.math.add(usize, self.values.items.len, additional) catch return error.OutOfMemory;
        if (required <= self.values.capacity) return;

        const grown = self.values.capacity + self.values.capacity / 2;
        try self.values.ensureTotalCapacityPrecise(self.allocator, @max(required, grown));
    }
};

test "value layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Value));
}

test "tag fields" {
    const value = Value{ .tag = makeTag(.number, .real, 42), .uni = 0 };
    try std.testing.expectEqual(Type.number, valueType(value));
    try std.testing.expectEqual(Subtype.real, valueSubtype(value));
    try std.testing.expectEqual(@as(usize, 42), valueLen(value));
}

test "container offsets" {
    const parent: u32 = 3;
    const child: u32 = 7;
    const offset = byteOffset(parent, child);
    try std.testing.expectEqual(@as(u64, 64), offset);
    try std.testing.expectEqual(child, indexAtOffset(parent, offset));
}

test "pool growth" {
    var pool = try Pool.init(std.testing.allocator, 0, false);
    defer pool.deinit();
    _ = try pool.append(.{ .tag = makeTag(.null, .none, 0), .uni = 0 });
    try std.testing.expectEqual(@as(usize, 1), pool.values.items.len);
}
