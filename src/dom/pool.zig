const std = @import("std");

/// The JSON value type, matching yyjson's 3-bit `YYJSON_TYPE_*` tag.
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

/// The value subtype, matching yyjson's 2-bit `YYJSON_SUBTYPE_*` tag.
pub const Subtype = enum(u2) {
    none = 0,
    one = 1,
    real = 2,
};

/// Boolean `false`, `YYJSON_SUBTYPE_FALSE`.
pub const false_value: Subtype = .none;
/// Boolean `true`, `YYJSON_SUBTYPE_TRUE`.
pub const true_value: Subtype = .one;
/// Unsigned integer, `YYJSON_SUBTYPE_UINT`.
pub const uint: Subtype = .none;
/// Signed integer, `YYJSON_SUBTYPE_SINT`.
pub const sint: Subtype = .one;
/// String that contains no escape sequence, `YYJSON_SUBTYPE_NOESC`.
pub const no_escape: Subtype = .one;

/// The first word of every value: type, subtype, and length.
///
/// The bit layout is yyjson's `tag`: 3 bits of type, 2 bits of subtype, 3
/// reserved bits, then a 56-bit length.
pub const Tag = packed struct(u64) {
    type: Type,
    subtype: Subtype = .none,
    reserved: u3 = 0,
    /// Number of bytes for strings, number of elements for arrays, and number
    /// of key/value pairs for objects.
    len: u56 = 0,
};

/// The second word of every value: the scalar itself, a string offset, or a
/// container offset.
pub const Payload = extern union {
    uint: u64,
    int: i64,
    float: f64,
    /// For a string, the byte offset of its text in the input buffer.
    ///
    /// For a container, the distance in bytes to the value after its subtree
    /// (a relative offset so the pool can be reallocated), or, while the
    /// container is still open, the distance to its parent.
    offset: u64,
};

/// One 16-byte DOM value; the Zig spelling of `yyjson_val`.
pub const Value = extern struct {
    tag: Tag = .{ .type = .none },
    uni: Payload = .{ .uint = 0 },
};

/// `sizeof(yyjson_val)`.
pub const value_size = @sizeOf(Value);

/// Packs a type, subtype, and length into a tag.
pub fn makeTag(value_type: Type, subtype: Subtype, len: usize) Tag {
    return .{
        .type = value_type,
        .subtype = subtype,
        .len = @intCast(len),
    };
}

pub fn valueType(value: Value) Type {
    return value.tag.type;
}

pub fn valueSubtype(value: Value) Subtype {
    return value.tag.subtype;
}

pub fn valueLen(value: Value) usize {
    return value.tag.len;
}

/// The byte distance between two value indices.
pub fn byteOffset(from: u32, to: u32) u64 {
    return (@as(u64, to) - @as(u64, from)) * value_size;
}

/// The pool index `offset` bytes away from `from`.
pub fn indexAtOffset(from: u32, offset: u64) u32 {
    std.debug.assert(offset % value_size == 0);
    return from + @as(u32, @intCast(offset / value_size));
}

/// Value storage for one document.
///
/// Values live in one contiguous, depth-first array exactly like yyjson's read
/// pool: a container's children start at the next index, and `uni.offset`
/// skips to the value after a container's subtree. A pool is either owned by an
/// allocator and can grow, or backed by caller storage and fails with
/// `error.OutOfMemory` when it is full.
pub const Pool = struct {
    /// Null for caller-provided storage, which `deinit` must not free.
    allocator: ?std.mem.Allocator = null,
    /// The allocated capacity; `len` says how much of it is used.
    buffer: []Value = &.{},
    len: usize = 0,

    /// Creates a growing pool sized for `input_len` bytes of JSON.
    ///
    /// `pretty` widens the estimate because whitespace bytes carry no values.
    pub fn init(allocator: std.mem.Allocator, input_len: usize, pretty: bool) !Pool {
        const ratio: usize = if (pretty) 16 else 6;
        const estimate = input_len / ratio + 4;
        return .{
            .allocator = allocator,
            .buffer = try allocator.alloc(Value, estimate),
        };
    }

    /// Uses `storage` as fixed-capacity value storage without owning it.
    ///
    /// The region is aligned up to `Value` alignment; the returned pool cannot
    /// grow.
    pub fn initFixed(storage: []u8) Pool {
        const address = @intFromPtr(storage.ptr);
        const aligned = std.mem.alignForward(usize, address, @alignOf(Value));
        if (aligned - address >= storage.len) return .{};
        const values: [*]Value = @ptrFromInt(aligned);
        const count = (storage.len - (aligned - address)) / value_size;
        return .{ .buffer = values[0..count] };
    }

    pub fn deinit(self: *Pool) void {
        if (self.allocator) |allocator| allocator.free(self.buffer);
        self.* = undefined;
    }

    /// The values appended so far.
    pub fn items(self: *const Pool) []const Value {
        return self.buffer[0..self.len];
    }

    pub fn append(self: *Pool, value: Value) !u32 {
        if (self.len == self.buffer.len) try self.grow();
        const index = std.math.cast(u32, self.len) orelse error.OutOfMemory;
        self.buffer[self.len] = value;
        self.len += 1;
        return index;
    }

    pub fn at(self: *const Pool, index: u32) *const Value {
        return &self.buffer[index];
    }

    pub fn atMut(self: *Pool, index: u32) *Value {
        return &self.buffer[index];
    }

    fn grow(self: *Pool) !void {
        const allocator = self.allocator orelse return error.OutOfMemory;
        const grown = self.buffer.len + self.buffer.len / 2;
        self.buffer = try allocator.realloc(self.buffer, @max(grown, 4));
    }
};

test "value layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Value));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Value, "tag"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Value, "uni"));
}

test "tag fields" {
    const value = Value{ .tag = makeTag(.number, .real, 42), .uni = .{ .float = 1.5 } };
    try std.testing.expectEqual(Type.number, valueType(value));
    try std.testing.expectEqual(Subtype.real, valueSubtype(value));
    try std.testing.expectEqual(@as(usize, 42), valueLen(value));
    try std.testing.expectEqual(@as(f64, 1.5), value.uni.float);
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
    for (0..64) |i| {
        _ = try pool.append(.{ .tag = makeTag(.null, .none, 0), .uni = .{ .uint = i } });
    }
    try std.testing.expectEqual(@as(usize, 64), pool.items().len);
}

test "fixed pool" {
    var storage: [4]Value align(@alignOf(Value)) = undefined;
    var pool = Pool.initFixed(std.mem.asBytes(&storage));
    try std.testing.expectEqual(@as(usize, 4), pool.buffer.len);
    for (0..4) |_| {
        _ = try pool.append(.{ .tag = makeTag(.null, .none, 0), .uni = .{ .uint = 0 } });
    }
    try std.testing.expectError(error.OutOfMemory, pool.append(.{ .tag = makeTag(.null, .none, 0) }));
}
