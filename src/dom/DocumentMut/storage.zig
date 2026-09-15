//! The linked node pool behind a `DocumentMut`: the layout, the builders that
//! fill it, and the primitives the `NodeMut` edits are made of.
//!
//! Nothing here is part of the public surface: `DocumentMut` and `NodeMut` are,
//! and they reach into this file.
pub const std = @import("std");
pub const pool_mod = @import("../pool.zig");
pub const common = @import("../common.zig");
pub const reader = @import("../reader.zig");

/// This file: sibling declarations are reached through `Self` when a nested
/// struct has a member of the same name.
const Self = @This();

/// Sentinel for "no node" links.
pub const none = std.math.maxInt(u32);

/// One node of a mutable document. A container's children form a doubly linked
/// list: `payload` holds the first child in its low 32 bits and the last child
/// in its high 32 bits.
pub const NodeData = struct {
    tag: pool_mod.Tag,
    payload: pool_mod.Payload,
    parent: u32 = none,
    prev: u32 = none,
    next: u32 = none,
};

/// Node storage owned by a `DocumentMut`.
pub const StorageMut = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(NodeData) = .empty,
    /// Decoded strings plus strings added by edits; append-only.
    input: std.ArrayList(u8) = .empty,
    root: u32 = 0,
};

pub inline fn nodeType(node: NodeData) pool_mod.Type {
    return node.tag.type;
}

pub inline fn nodeSubtype(node: NodeData) pool_mod.Subtype {
    return node.tag.subtype;
}

pub inline fn nodeLen(node: NodeData) usize {
    return node.tag.len;
}

/// The first child of a container, or `none`.
pub inline fn head(node: NodeData) u32 {
    return @truncate(node.payload.uint);
}

/// The last child of a container, or `none`.
pub inline fn tail(node: NodeData) u32 {
    return @intCast(node.payload.uint >> 32);
}

/// Stores a container's first and last child.
pub inline fn setChildren(node: *NodeData, first: u32, last: u32) void {
    node.payload.uint = @as(u64, first) | (@as(u64, last) << 32);
}

pub fn stringAtMut(storage: *const StorageMut, node: *const NodeData) []const u8 {
    const offset: usize = @intCast(node.payload.offset);
    return storage.input.items[offset..][0..nodeLen(node.*)];
}

pub fn stringAtCompact(source: *const common.Storage, node: *const pool_mod.NodeData) []const u8 {
    const offset: usize = @intCast(node.payload.offset);
    return source.input[offset..][0..node.tag.len];
}

/// One open container while `toCompact` walks the tree.
pub const CompactFrame = struct {
    /// The next source child to copy.
    source: u32,
    /// The slots this container still has to copy.
    remaining: usize,
    /// The container's compact index, patched when it closes.
    index: u32,
};

/// The number of slots a container's children occupy; null for a scalar.
pub inline fn childSlots(node: NodeData) ?usize {
    return switch (node.tag.type) {
        .object => node.tag.len * 2,
        .array => node.tag.len,
        else => null,
    };
}

/// Copies one node, dropping the mutable tag bits. A container starts with the
/// skip distance of an empty one, which `toCompact` corrects when it closes.
pub inline fn compactNode(node: NodeData) pool_mod.NodeData {
    const tag = pool_mod.makeTag(node.tag.type, node.tag.subtype, node.tag.len);
    return switch (node.tag.type) {
        .array, .object => .{ .tag = tag, .payload = .{ .offset = pool_mod.node_size } },
        else => .{ .tag = tag, .payload = node.payload },
    };
}

/// The mutable builder: links every parsed node into the tree as it is created.
pub const Builder = struct {
    storage: *StorageMut,
    /// The reader's padded input, whose string bytes are copied out.
    input: []const u8,

    pub inline fn append(
        self: *Builder,
        parent: ?u32,
        tag: pool_mod.Tag,
        payload: pool_mod.Payload,
    ) reader.Error!u32 {
        var node: NodeData = .{ .tag = tag, .payload = payload };
        switch (Self.nodeType(node)) {
            .string => {
                const start: usize = @intCast(node.payload.offset);
                const bytes = self.input[start..][0..Self.nodeLen(node)];
                node.payload = .{ .offset = try storeString(self.storage, bytes) };
            },
            .array, .object => setChildren(&node, none, none),
            else => {},
        }
        const index = try appendNode(self.storage, node);
        if (parent) |parent_index| {
            // While a container is being parsed its length holds the number of
            // finished slots, which is also the new child's slot index: object
            // members alternate key and value, so odd slots are values. They
            // carry a tag bit so that `remove` can drop the whole member.
            const parent_node = &self.storage.nodes.items[parent_index];
            if (parent_node.tag.type == .object and parent_node.tag.len % 2 == 1) {
                self.storage.nodes.items[index].tag.reserved |= member_value_bit;
            }
            parent_node.tag.len += 1;
            linkChild(self.storage, parent_index, index);
        }
        return index;
    }

    /// Nothing to do: `append` already counted the child in its parent.
    pub inline fn attach(self: *Builder, _: u32, _: u32, _: usize) void {
        _ = self;
    }

    /// The container's parent, or the container itself when it is the root.
    pub inline fn parentOf(self: *Builder, container: u32) u32 {
        const parent = self.storage.nodes.items[container].parent;
        return if (parent == none) container else parent;
    }

    pub inline fn nodeType(self: *Builder, node: u32) pool_mod.Type {
        return self.storage.nodes.items[node].tag.type;
    }

    pub inline fn nodeLen(self: *Builder, node: u32) usize {
        return self.storage.nodes.items[node].tag.len;
    }

    /// Records a finished container's length, keeping its child links.
    pub inline fn finish(self: *Builder, container: u32, length: usize) void {
        self.storage.nodes.items[container].tag.len = @intCast(length);
    }
};

/// Appends `child` to the child list of the node at `parent_index`.
pub fn linkChild(storage: *StorageMut, parent_index: u32, child: u32) void {
    const parent = &storage.nodes.items[parent_index];
    const last = tail(parent.*);

    const node = &storage.nodes.items[child];
    node.parent = parent_index;
    node.prev = last;
    node.next = none;

    if (last == none) {
        setChildren(parent, child, child);
    } else {
        storage.nodes.items[last].next = child;
        setChildren(parent, head(parent.*), child);
    }
}

/// Detaches `child` from the child list of the node at `parent_index`.
pub fn unlink(storage: *StorageMut, parent_index: u32, child: u32) void {
    const parent = &storage.nodes.items[parent_index];
    const node = storage.nodes.items[child];
    const prev = node.prev;
    const next = node.next;
    setChildren(
        parent,
        if (prev == none) next else head(parent.*),
        if (next == none) prev else tail(parent.*),
    );
    if (prev != none) storage.nodes.items[prev].next = next;
    if (next != none) storage.nodes.items[next].prev = prev;
    storage.nodes.items[child].parent = none;
    storage.nodes.items[child].prev = none;
    storage.nodes.items[child].next = none;
}

/// Inserts `child` into the child list of `before`'s parent, directly before it.
pub fn insertBefore(storage: *StorageMut, before: u32, child: u32) void {
    const node = storage.nodes.items[before];
    const prev = node.prev;
    const parent_index = node.parent;
    const inserted = &storage.nodes.items[child];
    inserted.parent = parent_index;
    inserted.prev = prev;
    inserted.next = before;
    storage.nodes.items[before].prev = child;
    if (prev == none) {
        const parent = &storage.nodes.items[parent_index];
        setChildren(parent, child, tail(parent.*));
    } else {
        storage.nodes.items[prev].next = child;
    }
}

/// Reserved tag bit marking the value of an object member pair.
pub const member_value_bit: u3 = 1;

pub inline fn isMemberValue(node: NodeData) bool {
    return node.tag.reserved & member_value_bit != 0;
}

pub inline fn setMemberValue(node: *NodeData, value: bool) void {
    if (value) {
        node.tag.reserved |= member_value_bit;
    } else {
        node.tag.reserved &= ~member_value_bit;
    }
}

/// Replaces a node's value while keeping its links and member bit.
pub inline fn setValue(node: *NodeData, tag: pool_mod.Tag, payload: pool_mod.Payload) void {
    const reserved = node.tag.reserved;
    node.tag = tag;
    node.payload = payload;
    node.tag.reserved = reserved;
}

pub fn needsEscape(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte < 0x20 or byte == '"' or byte == '\\') return true;
    }
    return false;
}

pub inline fn stringTag(value: []const u8) pool_mod.Tag {
    return pool_mod.makeTag(.string, if (needsEscape(value)) .none else pool_mod.no_escape, value.len);
}

pub fn pointsInto(buffer: []const u8, slice: []const u8) bool {
    if (slice.len == 0) return false;
    const start = @intFromPtr(slice.ptr);
    const base = @intFromPtr(buffer.ptr);
    return start >= base and start + slice.len <= base + buffer.len;
}

/// Appends `bytes` to the string pool and returns their offset.
///
/// `bytes` may point into the pool itself, so the source is re-read after the
/// capacity is reserved: reserving can move the buffer.
pub fn storeString(storage: *StorageMut, bytes: []const u8) !usize {
    const allocator = storage.allocator;
    const aliased: ?usize = if (pointsInto(storage.input.items, bytes))
        @intFromPtr(bytes.ptr) - @intFromPtr(storage.input.items.ptr)
    else
        null;
    try storage.input.ensureUnusedCapacity(allocator, bytes.len);
    const source = if (aliased) |offset| storage.input.items[offset..][0..bytes.len] else bytes;
    const offset = storage.input.items.len;
    storage.input.appendSliceAssumeCapacity(source);
    return offset;
}

/// Appends a node and returns its index.
pub inline fn appendNode(storage: *StorageMut, node: NodeData) !u32 {
    const index: u32 = @intCast(storage.nodes.items.len);
    try storage.nodes.append(storage.allocator, node);
    return index;
}

/// Creates a detached string node and returns its index.
pub fn storeStringNode(storage: *StorageMut, value: []const u8) !u32 {
    const tag = stringTag(value);
    const offset = try storeString(storage, value);
    return appendNode(storage, .{ .tag = tag, .payload = .{ .offset = offset } });
}

pub const Scalar = struct { tag: pool_mod.Tag, payload: pool_mod.Payload };

/// Packs a Zig integer or float into a number node's tag and payload.
pub inline fn numberScalar(value: anytype) common.AccessError!Scalar {
    switch (@typeInfo(@TypeOf(value))) {
        .float, .comptime_float => {
            const number: f64 = @floatCast(value);
            // JSON has no NaN or infinity, so neither does a document.
            if (!std.math.isFinite(number)) return error.OutOfRange;
            return .{
                .tag = pool_mod.makeTag(.number, .real, 0),
                .payload = .{ .float = number },
            };
        },
        .comptime_int => {
            if (value < 0) return .{
                .tag = pool_mod.makeTag(.number, pool_mod.sint, 0),
                .payload = .{ .int = std.math.cast(i64, value) orelse return error.OutOfRange },
            };
            return .{
                .tag = pool_mod.makeTag(.number, pool_mod.uint, 0),
                .payload = .{ .uint = std.math.cast(u64, value) orelse return error.OutOfRange },
            };
        },
        .int => |info| {
            if (info.signedness == .signed) return .{
                .tag = pool_mod.makeTag(.number, pool_mod.sint, 0),
                .payload = .{ .int = std.math.cast(i64, value) orelse return error.OutOfRange },
            };
            return .{
                .tag = pool_mod.makeTag(.number, pool_mod.uint, 0),
                .payload = .{ .uint = std.math.cast(u64, value) orelse return error.OutOfRange },
            };
        },
        else => @compileError("expected an integer or a float"),
    }
}

pub fn copyNode(storage: *StorageMut, source: NodeData, source_input: []const u8) !u32 {
    var node = source;
    switch (nodeType(source)) {
        .string => {
            const offset: usize = @intCast(source.payload.offset);
            node.payload = .{ .offset = try storeString(storage, source_input[offset..][0..nodeLen(source)]) };
        },
        .array, .object => setChildren(&node, none, none),
        else => {},
    }
    node.parent = none;
    node.prev = none;
    node.next = none;
    return appendNode(storage, node);
}

/// Deep-copies the subtree at `source` and returns the index of the detached copy.
///
/// Iterative on purpose: documents can nest arbitrarily deep.
pub fn copySubtree(
    storage: *StorageMut,
    source: *const StorageMut,
    source_index: u32,
) !u32 {
    const allocator = storage.allocator;
    const source_root = source.nodes.items[source_index];
    const root_index = try copyNode(storage, source_root, source.input.items);
    const root_type = nodeType(source_root);
    if (root_type != .array and root_type != .object) return root_index;
    const total: usize = if (root_type == .object) nodeLen(source_root) * 2 else nodeLen(source_root);
    if (total == 0) return root_index;

    const Frame = struct { new_index: u32, cursor: u32, remaining: usize };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{
        .new_index = root_index,
        .cursor = head(source_root),
        .remaining = total,
    });

    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        if (frame.remaining == 0) {
            _ = stack.pop();
            continue;
        }
        const child_index = frame.cursor;
        const source_node = source.nodes.items[child_index];
        frame.cursor = source_node.next;
        frame.remaining -= 1;
        const parent_index = frame.new_index;

        const new_child = try copyNode(storage, source_node, source.input.items);
        linkChild(storage, parent_index, new_child);

        if (nodeType(source_node) == .array or nodeType(source_node) == .object) {
            const count = nodeLen(source_node);
            const child_total: usize = if (nodeType(source_node) == .object) count * 2 else count;
            if (child_total != 0) try stack.append(allocator, .{
                .new_index = new_child,
                .cursor = head(source_node),
                .remaining = child_total,
            });
        }
    }
    return root_index;
}

/// Copies a compact read-only tree into a new mutable document.
///
/// The compact pool is depth-first, so one linear scan in index order is a
/// pre-order walk; an explicit frame stack links each node to its parent. It is
/// iterative on purpose: documents can nest arbitrarily deep.
pub fn fromStorage(
    allocator: std.mem.Allocator,
    source: *const common.Storage,
    root_index: u32,
) std.mem.Allocator.Error!StorageMut {
    const compact = source.nodes;
    var storage: StorageMut = .{ .allocator = allocator };
    errdefer storage.nodes.deinit(allocator);
    errdefer storage.input.deinit(allocator);
    try storage.nodes.ensureTotalCapacity(allocator, compact.len);

    const Frame = struct { index: u32, remaining: usize };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    try stack.ensureTotalCapacity(allocator, 32);

    for (compact, 0..) |*compact_node, i| {
        const index: u32 = @intCast(storage.nodes.items.len);
        var node: NodeData = .{ .tag = compact_node.tag, .payload = compact_node.payload };
        switch (compact_node.tag.type) {
            .string => {
                const bytes = stringAtCompact(source, compact_node);
                const offset = storage.input.items.len;
                try storage.input.appendSlice(allocator, bytes);
                node.payload = .{ .offset = offset };
            },
            .array, .object => setChildren(&node, none, none),
            else => {},
        }
        try storage.nodes.append(allocator, node);

        if (i == root_index) {
            storage.root = index;
        } else {
            const top = &stack.items[stack.items.len - 1];
            const parent_index = top.index;
            // Odd slots of an object are member values; even slots are keys.
            if (storage.nodes.items[parent_index].tag.type == .object and top.remaining % 2 == 1) {
                storage.nodes.items[index].tag.reserved |= member_value_bit;
            }
            linkChild(&storage, parent_index, index);
            top.remaining -= 1;
        }

        const children: usize = switch (compact_node.tag.type) {
            .object => compact_node.tag.len * 2,
            .array => compact_node.tag.len,
            else => 0,
        };
        if (children != 0) try stack.append(allocator, .{ .index = index, .remaining = children });

        while (stack.items.len != 0 and stack.items[stack.items.len - 1].remaining == 0) {
            _ = stack.pop();
        }
    }

    return storage;
}

/// A compact copy of a mutable tree: a depth-first node pool plus the string
/// pool its offsets refer to. Both are owned by the allocator that made them.
pub const Compact = struct {
    /// The compact nodes, ready for a `Document`.
    pool: pool_mod.Pool,
    /// The decoded strings the nodes point into.
    input: []u8,
    /// The index of the copied root inside `pool`.
    root_index: u32,

    /// Releases the node pool and the string pool.
    pub fn deinit(self: *Compact, allocator: std.mem.Allocator) void {
        allocator.free(self.pool.buffer);
        allocator.free(self.input);
    }
};

/// Copies the tree at `root` into a compact depth-first pool.
///
/// The mutable string pool already has the layout a compact document wants, so
/// it is copied once and the nodes keep their offsets. The copy is iterative,
/// so a deep tree cannot overflow the stack.
pub fn toCompact(
    storage: *const StorageMut,
    root: u32,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!Compact {
    const source = storage.nodes.items;
    const root_node = source[root];

    const input = try allocator.dupe(u8, storage.input.items);
    errdefer allocator.free(input);

    var nodes: std.ArrayList(pool_mod.NodeData) = .empty;
    errdefer nodes.deinit(allocator);
    try nodes.ensureTotalCapacity(allocator, source.len);
    try nodes.append(allocator, compactNode(root_node));

    var stack: std.ArrayList(CompactFrame) = .empty;
    defer stack.deinit(allocator);
    if (childSlots(root_node)) |slots| {
        try stack.ensureTotalCapacity(allocator, 32);
        try stack.append(allocator, .{ .source = head(root_node), .remaining = slots, .index = 0 });
    }

    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        if (frame.remaining == 0) {
            // The subtree is complete, so the container can record how far the
            // next sibling is.
            const closed = frame.index;
            _ = stack.pop();
            nodes.items[closed].payload.offset = pool_mod.byteOffset(closed, @intCast(nodes.items.len));
            continue;
        }
        const child = frame.source;
        frame.source = source[child].next;
        frame.remaining -= 1;

        const index: u32 = @intCast(nodes.items.len);
        try nodes.append(allocator, compactNode(source[child]));
        if (childSlots(source[child])) |slots| {
            try stack.append(allocator, .{
                .source = head(source[child]),
                .remaining = slots,
                .index = index,
            });
        }
    }

    return .{
        .pool = .{ .allocator = allocator, .buffer = nodes.allocatedSlice(), .len = nodes.items.len },
        .input = input,
        .root_index = root,
    };
}

/// Parses the JSON in `buffer[0..end]` into linked nodes in `storage` and
/// returns the root index.
///
/// It shares `../reader.zig`'s scanner and state machine with the compact
/// parser, but links every node as it is created, so no compact tree is built
/// in between. `buffer` must have four readable zero bytes at
/// `buffer[end..end + 4]`; its decoded strings are copied into `storage.input`,
/// so the caller may free it afterwards.
pub fn parseInto(
    storage: *StorageMut,
    buffer: []u8,
    end: usize,
    options: reader.Options,
) reader.Error!u32 {
    var parser: reader.Reader(Builder) = .{
        .input = buffer[0 .. end + 4],
        .end = end,
        .options = options,
        .sink = .{ .storage = storage, .input = buffer },
    };
    return parser.run();
}

/// Creates a detached `null` node.
pub fn createNull(storage: *StorageMut) !u32 {
    return appendNode(storage, .{
        .tag = pool_mod.makeTag(.null, .none, 0),
        .payload = .{ .uint = 0 },
    });
}

/// Creates a detached boolean node.
pub fn createBool(storage: *StorageMut, value: bool) !u32 {
    return appendNode(storage, .{
        .tag = pool_mod.makeTag(.bool, if (value) pool_mod.true_flag else pool_mod.false_flag, 0),
        .payload = .{ .uint = 0 },
    });
}

/// Creates a detached number node.
pub fn createNumber(storage: *StorageMut, value: anytype) !u32 {
    const scalar = try numberScalar(value);
    return appendNode(storage, .{ .tag = scalar.tag, .payload = scalar.payload });
}

/// Creates a detached string node.
pub fn createString(storage: *StorageMut, value: []const u8) !u32 {
    return storeStringNode(storage, value);
}

/// Creates a detached empty array node.
pub fn createArray(storage: *StorageMut) !u32 {
    var node: NodeData = .{ .tag = pool_mod.makeTag(.array, .none, 0), .payload = .{ .uint = 0 } };
    setChildren(&node, none, none);
    return appendNode(storage, node);
}

/// Creates a detached empty object node.
pub fn createObject(storage: *StorageMut) !u32 {
    var node: NodeData = .{ .tag = pool_mod.makeTag(.object, .none, 0), .payload = .{ .uint = 0 } };
    setChildren(&node, none, none);
    return appendNode(storage, node);
}
