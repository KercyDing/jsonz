const std = @import("std");

/// The JSON node type, stored in the low three bits of a tag.
pub const Type = enum(u3) {
    /// Only the default tag of an unset node uses this.
    none = 0,
    null = 1,
    bool = 2,
    number = 3,
    string = 4,
    array = 5,
    object = 6,
};

/// The node subtype, stored in the next two bits of a tag.
pub const Subtype = enum(u2) {
    none = 0,
    one = 1,
    real = 2,
};

/// Boolean `false`.
pub const false_flag: Subtype = .none;
/// Boolean `true`.
pub const true_flag: Subtype = .one;
/// Unsigned integer.
pub const uint: Subtype = .none;
/// Signed integer.
pub const sint: Subtype = .one;
/// String that contains no escape sequence.
pub const no_escape: Subtype = .one;

/// The first word of every node: type, subtype, and length.
///
/// The layout is 3 bits of type, 2 bits of subtype, 3 reserved bits, then a
/// 56-bit length.
pub const Tag = packed struct(u64) {
    type: Type,
    subtype: Subtype = .none,
    reserved: u3 = 0,
    /// Number of bytes for strings, number of elements for arrays, and number
    /// of key/value pairs for objects.
    len: u56 = 0,
};

/// The second word of every node: the scalar itself, a string offset, or a
/// container offset.
pub const Payload = extern union {
    uint: u64,
    int: i64,
    float: f64,
    /// For a string, the byte offset of its text in the input buffer.
    ///
    /// For a container, the distance in bytes to the node after its subtree
    /// (a relative offset so the pool can be reallocated), or, while the
    /// container is still open, the distance to its parent.
    offset: u64,
};

/// One 16-byte DOM node: a tag and a payload.
pub const NodeData = extern struct {
    tag: Tag = .{ .type = .none },
    payload: Payload = .{ .uint = 0 },
};

/// The size of one node.
pub const node_size = @sizeOf(NodeData);

/// Packs a type, subtype, and length into a tag.
pub fn makeTag(node_type: Type, subtype: Subtype, len: usize) Tag {
    return .{
        .type = node_type,
        .subtype = subtype,
        .len = @intCast(len),
    };
}

pub fn nodeType(node: NodeData) Type {
    return node.tag.type;
}

pub fn nodeSubtype(node: NodeData) Subtype {
    return node.tag.subtype;
}

pub fn nodeLen(node: NodeData) usize {
    return node.tag.len;
}

/// The byte distance between two node indices.
pub fn byteOffset(from: u32, to: u32) u64 {
    return (@as(u64, to) - @as(u64, from)) * node_size;
}

/// The pool index `offset` bytes away from `from`.
pub fn indexAtOffset(from: u32, offset: u64) u32 {
    std.debug.assert(offset % node_size == 0);
    return from + @as(u32, @intCast(offset / node_size));
}

/// NodeData storage for one document.
///
/// Nodes live in one contiguous, depth-first array: a container's children
/// start at the next index, and `payload.offset` skips to the node after a
/// container's subtree. A pool is either owned by an allocator and can grow, or
/// backed by caller storage and fails with `error.OutOfMemory` when it is full.
pub const Pool = struct {
    /// Null for caller-provided storage, which `deinit` must not free.
    allocator: ?std.mem.Allocator = null,
    /// The allocated capacity; `len` says how much of it is used.
    buffer: []NodeData = &.{},
    len: usize = 0,

    /// Creates a growing pool sized for `input_len` bytes of JSON.
    ///
    /// `pretty` widens the estimate because whitespace bytes carry no nodes.
    pub fn init(allocator: std.mem.Allocator, input_len: usize, pretty: bool) !Pool {
        const ratio: usize = if (pretty) 16 else 6;
        const estimate = input_len / ratio + 4;
        return .{
            .allocator = allocator,
            .buffer = try allocator.alloc(NodeData, estimate),
        };
    }

    /// Uses `storage` as fixed-capacity node storage without owning it.
    ///
    /// The region is aligned up to `NodeData` alignment; the returned pool cannot
    /// grow.
    pub fn initFixed(storage: []u8) Pool {
        const address = @intFromPtr(storage.ptr);
        const aligned = std.mem.alignForward(usize, address, @alignOf(NodeData));
        if (aligned - address >= storage.len) return .{};
        const nodes: [*]NodeData = @ptrFromInt(aligned);
        const count = (storage.len - (aligned - address)) / node_size;
        return .{ .buffer = nodes[0..count] };
    }

    pub fn deinit(self: *Pool) void {
        if (self.allocator) |allocator| allocator.free(self.buffer);
        self.* = undefined;
    }

    /// The nodes appended so far.
    pub fn items(self: *const Pool) []const NodeData {
        return self.buffer[0..self.len];
    }

    pub fn append(self: *Pool, node: NodeData) !u32 {
        if (self.len == self.buffer.len) try self.grow();
        const index = std.math.cast(u32, self.len) orelse error.OutOfMemory;
        self.buffer[self.len] = node;
        self.len += 1;
        return index;
    }

    pub fn at(self: *const Pool, index: u32) *const NodeData {
        return &self.buffer[index];
    }

    pub fn atMut(self: *Pool, index: u32) *NodeData {
        return &self.buffer[index];
    }

    fn grow(self: *Pool) !void {
        const allocator = self.allocator orelse return error.OutOfMemory;
        const grown = self.buffer.len + self.buffer.len / 2;
        self.buffer = try allocator.realloc(self.buffer, @max(grown, 4));
    }
};

test "node layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(NodeData));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(NodeData));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(NodeData, "tag"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(NodeData, "payload"));
}

test "tag fields" {
    const node = NodeData{ .tag = makeTag(.number, .real, 42), .payload = .{ .float = 1.5 } };
    try std.testing.expectEqual(Type.number, nodeType(node));
    try std.testing.expectEqual(Subtype.real, nodeSubtype(node));
    try std.testing.expectEqual(@as(usize, 42), nodeLen(node));
    try std.testing.expectEqual(@as(f64, 1.5), node.payload.float);
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
        _ = try pool.append(.{ .tag = makeTag(.null, .none, 0), .payload = .{ .uint = i } });
    }
    try std.testing.expectEqual(@as(usize, 64), pool.items().len);
}

test "fixed pool" {
    var storage: [4]NodeData align(@alignOf(NodeData)) = undefined;
    var pool = Pool.initFixed(std.mem.asBytes(&storage));
    try std.testing.expectEqual(@as(usize, 4), pool.buffer.len);
    for (0..4) |_| {
        _ = try pool.append(.{ .tag = makeTag(.null, .none, 0), .payload = .{ .uint = 0 } });
    }
    try std.testing.expectError(error.OutOfMemory, pool.append(.{ .tag = makeTag(.null, .none, 0) }));
}
