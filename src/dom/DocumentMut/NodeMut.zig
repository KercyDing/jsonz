/// A mutable JSON node, plus the storage and traversal behind it.
///
/// Nodes are linked - each one knows its parent and its previous and next
/// sibling - so structural edits are pointer updates instead of shifting a
/// contiguous pool. A `NodeMut` is a borrowed handle into one `StorageMut`.
const NodeMut = @This();

const std = @import("std");
const pool_mod = @import("../pool.zig");
const common = @import("../common.zig");
const encode = @import("../encode.zig");
const rfc = @import("../rfc.zig");
const reader = @import("../reader.zig");

/// The kind of a DOM value.
pub const Kind = common.Kind;
/// Numeric types accepted by `NodeMut.toNumber` and `NodeMut.asNumber`.
pub const NumberType = common.NumberType;
/// Errors returned when a node cannot be accessed or converted.
pub const AccessError = common.AccessError;
/// Errors from resolving an RFC 6901 JSON Pointer.
pub const PointerError = common.PointerError;
/// Options that control DOM serialization.
pub const WriteOptions = common.WriteOptions;

/// Errors returned by structural edits.
pub const MutateError = std.mem.Allocator.Error || common.AccessError || error{
    /// The node is already linked into a tree.
    AlreadyAttached,
    /// The node belongs to another document's storage.
    DifferentStorage,
    /// Attaching the node there would make it its own descendant.
    WouldCycle,
};

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

/// A borrowed handle to one node of a `DocumentMut`; it does not own memory.
storage: *StorageMut,
index: u32,

/// One key/value pair yielded by `ObjectIterator`.
pub const ObjectEntry = struct {
    key: []const u8,
    value: NodeMut,
};

/// Iterator over an object's fields in document order.
pub const ObjectIterator = struct {
    storage: *StorageMut,
    remaining: usize,
    /// Pool slot of the next key.
    cursor: u32,

    /// Returns the next field, or `null` after the final field.
    pub fn next(self: *ObjectIterator) ?ObjectEntry {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const nodes = self.storage.nodes.items;
        const key_index = self.cursor;
        const value_index = nodes[key_index].next;
        self.cursor = nodes[value_index].next;
        return .{
            .key = stringAtMut(self.storage, &nodes[key_index]),
            .value = .{ .storage = self.storage, .index = value_index },
        };
    }
};

/// Iterator over an array's elements in document order.
pub const ArrayIterator = struct {
    storage: *StorageMut,
    remaining: usize,
    /// Pool slot of the next element.
    cursor: u32,

    /// Returns the next element, or `null` after the final element.
    pub fn next(self: *ArrayIterator) ?NodeMut {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const index = self.cursor;
        self.cursor = self.storage.nodes.items[index].next;
        return .{ .storage = self.storage, .index = index };
    }
};

fn raw(self: NodeMut) *NodeData {
    return &self.storage.nodes.items[self.index];
}

/// Returns this node's JSON kind.
pub fn kind(self: NodeMut) Kind {
    return switch (nodeType(self.raw().*)) {
        .null => .null,
        .bool => .bool,
        .number => .number,
        .string => .string,
        .array => .array,
        .object => .object,
        else => unreachable,
    };
}

/// Returns whether this node is JSON `null`.
pub fn isNull(self: NodeMut) bool {
    return nodeType(self.raw().*) == .null;
}

/// Returns whether this node is a boolean.
pub fn isBool(self: NodeMut) bool {
    return nodeType(self.raw().*) == .bool;
}

/// Returns whether this node can be converted to the requested numeric type.
pub fn isNumber(self: NodeMut, comptime target: NumberType) bool {
    _ = self.toNumber(target) catch return false;
    return true;
}

/// Returns whether this node is a string.
pub fn isString(self: NodeMut) bool {
    return nodeType(self.raw().*) == .string;
}

/// Returns whether this node is an array.
pub fn isArray(self: NodeMut) bool {
    return nodeType(self.raw().*) == .array;
}

/// Returns whether this node is an object.
pub fn isObject(self: NodeMut) bool {
    return nodeType(self.raw().*) == .object;
}

/// Returns the boolean payload.
pub fn toBool(self: NodeMut) AccessError!bool {
    if (!self.isBool()) return error.UnexpectedType;
    return nodeSubtype(self.raw().*) == pool_mod.true_flag;
}

/// Converts this JSON number to the requested numeric type.
pub fn toNumber(self: NodeMut, comptime target: NumberType) AccessError!target.Type() {
    if (nodeType(self.raw().*) != .number) return error.UnexpectedType;
    return switch (target) {
        .i8, .i16, .i32, .i64, .i128, .isize => switch (nodeSubtype(self.raw().*)) {
            .one => std.math.cast(target.Type(), self.raw().payload.int) orelse error.OutOfRange,
            .none => std.math.cast(target.Type(), self.raw().payload.uint) orelse error.OutOfRange,
            else => error.UnexpectedType,
        },
        .u8, .u16, .u32, .u64, .u128, .usize => switch (nodeSubtype(self.raw().*)) {
            .none => std.math.cast(target.Type(), self.raw().payload.uint) orelse error.OutOfRange,
            .one => std.math.cast(target.Type(), self.raw().payload.int) orelse error.OutOfRange,
            else => error.UnexpectedType,
        },
        .f16, .f32, .f64 => switch (nodeSubtype(self.raw().*)) {
            .real => @floatCast(self.raw().payload.float),
            .one => @floatFromInt(self.raw().payload.int),
            .none => @floatFromInt(self.raw().payload.uint),
        },
    };
}

/// Returns a string slice borrowed from the document.
pub fn toString(self: NodeMut) AccessError![]const u8 {
    if (!self.isString()) return error.UnexpectedType;
    return stringAtMut(self.storage, self.raw());
}

/// Converts this node to the requested numeric type, or returns `null`
/// when it is not numeric or does not fit.
pub fn asNumber(self: NodeMut, comptime target: NumberType) ?target.Type() {
    return self.toNumber(target) catch null;
}

/// Returns the boolean payload when this node is a boolean, otherwise null.
pub fn asBool(self: NodeMut) ?bool {
    return self.toBool() catch null;
}

/// Returns the borrowed string when this node is a string, otherwise null.
pub fn asString(self: NodeMut) ?[]const u8 {
    return self.toString() catch null;
}

/// Returns the number of fields or elements in this container.
pub fn len(self: NodeMut) AccessError!usize {
    if (!self.isArray() and !self.isObject()) return error.UnexpectedType;
    return nodeLen(self.raw().*);
}

/// Looks up an object field, returning `null` when this node is not an
/// object or the field is absent.
pub fn get(self: NodeMut, key: []const u8) ?NodeMut {
    if (!self.isObject()) return null;
    return getObjectUnchecked(self, key);
}

/// Returns an object field, or an error when this node is not an object or
/// the field does not exist.
pub fn field(self: NodeMut, key: []const u8) AccessError!NodeMut {
    if (!self.isObject()) return error.UnexpectedType;
    return getObjectUnchecked(self, key) orelse error.MissingField;
}

/// Returns an array element, or `null` when this node is not an array or
/// the index is out of bounds.
pub fn getAt(self: NodeMut, index: usize) ?NodeMut {
    if (!self.isArray()) return null;
    return getArrayUnchecked(self, index);
}

/// Returns an array element, or an error when this node is not an array or
/// the index is out of bounds.
pub fn at(self: NodeMut, index: usize) AccessError!NodeMut {
    if (!self.isArray()) return error.UnexpectedType;
    return getArrayUnchecked(self, index) orelse error.OutOfBounds;
}

/// Resolves a comptime-known RFC 6901 JSON Pointer against this node.
pub fn ptrGet(self: NodeMut, comptime ptr: []const u8) PointerError!NodeMut {
    return rfc.resolveStatic(self, ptr);
}

/// Resolves a comptime-known RFC 6901 JSON Pointer format against this node.
pub fn ptrGetFmt(self: NodeMut, comptime fmt: []const u8, args: anytype) PointerError!NodeMut {
    return rfc.resolveFmt(self, fmt, args);
}

/// Resolves a runtime RFC 6901 JSON Pointer against this node.
pub fn ptrGetDyn(self: NodeMut, ptr: []const u8) PointerError!NodeMut {
    return rfc.resolve(self, ptr);
}

/// Returns an iterator over this object's fields.
pub fn objectIterator(self: NodeMut) AccessError!ObjectIterator {
    if (!self.isObject()) return error.UnexpectedType;
    return .{
        .storage = self.storage,
        .remaining = nodeLen(self.raw().*),
        .cursor = head(self.raw().*),
    };
}

/// Returns an iterator over this array's elements.
pub fn arrayIterator(self: NodeMut) AccessError!ArrayIterator {
    if (!self.isArray()) return error.UnexpectedType;
    return .{
        .storage = self.storage,
        .remaining = nodeLen(self.raw().*),
        .cursor = head(self.raw().*),
    };
}

/// Serializes this node to a newly allocated JSON byte slice owned by
/// `allocator`.
pub fn toSlice(self: NodeMut, allocator: std.mem.Allocator, options: WriteOptions) ![]u8 {
    var buffer: encode.Buffer = .{ .allocator = allocator };
    errdefer buffer.list.deinit(allocator);
    // The source length is a good output hint, so the buffer rarely grows.
    const estimate = if (options.pretty)
        self.storage.input.items.len * 2 + 64
    else
        self.storage.input.items.len + 64;
    try buffer.list.ensureTotalCapacity(allocator, estimate);
    try writeMut(&buffer, self, options, allocator);
    return buffer.list.toOwnedSlice(allocator);
}

/// Serializes this node to `writer`.
pub fn toWriter(self: NodeMut, writer: *std.Io.Writer, options: WriteOptions) !void {
    // The document is buffered and flushed once, which keeps this on the
    // same fast path as `toSlice`.
    const output = try self.toSlice(std.heap.smp_allocator, options);
    defer std.heap.smp_allocator.free(output);
    try writer.writeAll(output);
}

/// Replaces this node's value with `null`, keeping its position.
pub fn replaceNull(self: NodeMut) void {
    setValue(self.raw(), pool_mod.makeTag(.null, .none, 0), .{ .uint = 0 });
}

/// Replaces this node's value with a boolean, keeping its position.
pub fn replaceBool(self: NodeMut, value: bool) void {
    setValue(
        self.raw(),
        pool_mod.makeTag(.bool, if (value) pool_mod.true_flag else pool_mod.false_flag, 0),
        .{ .uint = 0 },
    );
}

/// Replaces this node's value with a number, keeping its position.
///
/// Numbers are stored as `i64`, `u64`, or `f64`, so an integer that does not
/// fit reports `error.OutOfRange`; so does a float that JSON cannot carry, like
/// a NaN or an infinity.
pub fn replaceNumber(self: NodeMut, value: anytype) AccessError!void {
    const scalar = try numberScalar(value);
    setValue(self.raw(), scalar.tag, scalar.payload);
}

/// Replaces this node's value with a copy of `value`, keeping its position.
pub fn replaceString(self: NodeMut, value: []const u8) !void {
    const tag = stringTag(value);
    const offset = try storeString(self.storage, value);
    setValue(self.raw(), tag, .{ .offset = offset });
}

/// Removes this node from its parent. An object member is removed together
/// with its key; the document root cannot be removed.
pub fn remove(self: NodeMut) void {
    if (self.index == self.storage.root) return;
    const node = self.raw().*;
    if (node.parent == none) return;
    const parent_index = node.parent;
    if (self.storage.nodes.items[parent_index].tag.type == .object) {
        const pair = if (isMemberValue(node)) node.prev else node.next;
        unlink(self.storage, parent_index, self.index);
        if (pair != none) unlink(self.storage, parent_index, pair);
    } else {
        unlink(self.storage, parent_index, self.index);
    }
    self.storage.nodes.items[parent_index].tag.len -= 1;
}

/// Splices a detached node into this node's position and leaves this node
/// detached. The replacement must belong to the same document.
pub fn replace(self: NodeMut, value: NodeMut) MutateError!void {
    try checkAttachable(self, value);
    if (self.index == self.storage.root) {
        self.storage.root = value.index;
        return;
    }
    const node = self.raw().*;
    const parent_index = node.parent;
    const replacement = &self.storage.nodes.items[value.index];
    replacement.parent = parent_index;
    replacement.prev = node.prev;
    replacement.next = node.next;
    setMemberValue(replacement, isMemberValue(node));
    if (node.prev == none) {
        const parent = &self.storage.nodes.items[parent_index];
        setChildren(parent, value.index, tail(parent.*));
    } else {
        self.storage.nodes.items[node.prev].next = value.index;
    }
    if (node.next == none) {
        const parent = &self.storage.nodes.items[parent_index];
        setChildren(parent, head(parent.*), value.index);
    } else {
        self.storage.nodes.items[node.next].prev = value.index;
    }
    const detached = self.raw();
    detached.parent = none;
    detached.prev = none;
    detached.next = none;
}

/// Copies `source` into this node, keeping this node's position. `source`
/// may belong to another document.
pub fn copyFrom(self: NodeMut, source: NodeMut) !void {
    const copy_index = try copySubtree(self.storage, source);
    const copied = self.storage.nodes.items[copy_index];
    const member = isMemberValue(self.raw().*);
    const node = self.raw();
    node.tag = copied.tag;
    node.payload = copied.payload;
    setMemberValue(node, member);
    if (nodeType(copied) == .array or nodeType(copied) == .object) {
        var cursor = head(copied);
        while (cursor != none) : (cursor = self.storage.nodes.items[cursor].next) {
            self.storage.nodes.items[cursor].parent = self.index;
        }
        setChildren(node, head(copied), tail(copied));
    }
}

/// Appends an object member. `value` must be a detached node of this document.
pub fn addField(self: NodeMut, key: []const u8, value: NodeMut) MutateError!void {
    if (!self.isObject()) return error.UnexpectedType;
    try checkAttachable(self, value);
    const key_index = try storeStringNode(self.storage, key);
    linkChild(self.storage, self.index, key_index);
    linkChild(self.storage, self.index, value.index);
    setMemberValue(&self.storage.nodes.items[value.index], true);
    self.raw().tag.len += 1;
}

/// Appends an object member whose value is a string.
pub fn addString(self: NodeMut, key: []const u8, value: []const u8) !void {
    if (!self.isObject()) return error.UnexpectedType;
    const key_index = try storeStringNode(self.storage, key);
    const value_index = try storeStringNode(self.storage, value);
    linkChild(self.storage, self.index, key_index);
    linkChild(self.storage, self.index, value_index);
    setMemberValue(&self.storage.nodes.items[value_index], true);
    self.raw().tag.len += 1;
}

/// Appends an array element. `value` must be a detached node of this document.
pub fn append(self: NodeMut, value: NodeMut) MutateError!void {
    if (!self.isArray()) return error.UnexpectedType;
    try checkAttachable(self, value);
    linkChild(self.storage, self.index, value.index);
    setMemberValue(&self.storage.nodes.items[value.index], false);
    self.raw().tag.len += 1;
}

/// Appends a string array element.
pub fn appendString(self: NodeMut, value: []const u8) !void {
    if (!self.isArray()) return error.UnexpectedType;
    const index = try storeStringNode(self.storage, value);
    linkChild(self.storage, self.index, index);
    self.raw().tag.len += 1;
}

/// Inserts an array element at `index`; `index == len` appends.
pub fn insertAt(self: NodeMut, index: usize, value: NodeMut) MutateError!void {
    if (!self.isArray()) return error.UnexpectedType;
    if (index > nodeLen(self.raw().*)) return error.OutOfBounds;
    try checkAttachable(self, value);
    const sibling = self.atSlot(index);
    if (sibling) |target| {
        insertBefore(self.storage, target.index, value.index);
    } else {
        linkChild(self.storage, self.index, value.index);
    }
    setMemberValue(&self.storage.nodes.items[value.index], false);
    self.raw().tag.len += 1;
}

/// Walks to the child at `slot`, or returns null past the end.
fn atSlot(self: NodeMut, slot: usize) ?NodeMut {
    var cursor = head(self.raw().*);
    var remaining = slot;
    while (remaining != 0) : (remaining -= 1) {
        if (cursor == none) return null;
        cursor = self.storage.nodes.items[cursor].next;
    }
    if (cursor == none) return null;
    return .{ .storage = self.storage, .index = cursor };
}

inline fn nodeType(node: NodeData) pool_mod.Type {
    return node.tag.type;
}

inline fn nodeSubtype(node: NodeData) pool_mod.Subtype {
    return node.tag.subtype;
}

inline fn nodeLen(node: NodeData) usize {
    return node.tag.len;
}

/// The first child of a container, or `none`.
inline fn head(node: NodeData) u32 {
    return @truncate(node.payload.uint);
}

/// The last child of a container, or `none`.
inline fn tail(node: NodeData) u32 {
    return @intCast(node.payload.uint >> 32);
}

/// Stores a container's first and last child.
inline fn setChildren(node: *NodeData, first: u32, last: u32) void {
    node.payload.uint = @as(u64, first) | (@as(u64, last) << 32);
}

fn getObjectUnchecked(self: NodeMut, key: []const u8) ?NodeMut {
    const nodes = self.storage.nodes.items;
    const count = nodeLen(self.raw().*);
    var key_index = head(self.raw().*);
    for (0..count) |_| {
        const value_index = nodes[key_index].next;
        const entry_key = &nodes[key_index];
        if (nodeLen(entry_key.*) == key.len and
            std.mem.eql(u8, stringAtMut(self.storage, entry_key), key))
        {
            return .{ .storage = self.storage, .index = value_index };
        }
        key_index = nodes[value_index].next;
    }
    return null;
}

fn getArrayUnchecked(self: NodeMut, index: usize) ?NodeMut {
    if (index >= nodeLen(self.raw().*)) return null;
    var cursor = head(self.raw().*);
    var remaining = index;
    while (remaining != 0) : (remaining -= 1) {
        cursor = self.storage.nodes.items[cursor].next;
    }
    return .{ .storage = self.storage, .index = cursor };
}

fn stringAtMut(storage: *const StorageMut, node: *const NodeData) []const u8 {
    const offset: usize = @intCast(node.payload.offset);
    return storage.input.items[offset..][0..nodeLen(node.*)];
}

fn stringAtCompact(source: *const common.Storage, node: *const pool_mod.NodeData) []const u8 {
    const offset: usize = @intCast(node.payload.offset);
    return source.input[offset..][0..node.tag.len];
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

/// The mutable builder: links every parsed node into the tree as it is created.
const Builder = struct {
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
        switch (NodeMut.nodeType(node)) {
            .string => {
                const start: usize = @intCast(node.payload.offset);
                const bytes = self.input[start..][0..NodeMut.nodeLen(node)];
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
fn linkChild(storage: *StorageMut, parent_index: u32, child: u32) void {
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
fn unlink(storage: *StorageMut, parent_index: u32, child: u32) void {
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
fn insertBefore(storage: *StorageMut, before: u32, child: u32) void {
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
const member_value_bit: u3 = 1;

inline fn isMemberValue(node: NodeData) bool {
    return node.tag.reserved & member_value_bit != 0;
}

inline fn setMemberValue(node: *NodeData, value: bool) void {
    if (value) {
        node.tag.reserved |= member_value_bit;
    } else {
        node.tag.reserved &= ~member_value_bit;
    }
}

/// Replaces a node's value while keeping its links and member bit.
inline fn setValue(node: *NodeData, tag: pool_mod.Tag, payload: pool_mod.Payload) void {
    const reserved = node.tag.reserved;
    node.tag = tag;
    node.payload = payload;
    node.tag.reserved = reserved;
}

fn needsEscape(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte < 0x20 or byte == '"' or byte == '\\') return true;
    }
    return false;
}

inline fn stringTag(value: []const u8) pool_mod.Tag {
    return pool_mod.makeTag(.string, if (needsEscape(value)) .none else pool_mod.no_escape, value.len);
}

fn pointsInto(buffer: []const u8, slice: []const u8) bool {
    if (slice.len == 0) return false;
    const start = @intFromPtr(slice.ptr);
    const base = @intFromPtr(buffer.ptr);
    return start >= base and start + slice.len <= base + buffer.len;
}

/// Appends `bytes` to the string pool and returns their offset.
///
/// `bytes` may point into the pool itself, so the source is re-read after the
/// capacity is reserved: reserving can move the buffer.
fn storeString(storage: *StorageMut, bytes: []const u8) !usize {
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
inline fn appendNode(storage: *StorageMut, node: NodeData) !u32 {
    const index: u32 = @intCast(storage.nodes.items.len);
    try storage.nodes.append(storage.allocator, node);
    return index;
}

/// Creates a detached string node and returns its index.
fn storeStringNode(storage: *StorageMut, value: []const u8) !u32 {
    const tag = stringTag(value);
    const offset = try storeString(storage, value);
    return appendNode(storage, .{ .tag = tag, .payload = .{ .offset = offset } });
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

const Scalar = struct { tag: pool_mod.Tag, payload: pool_mod.Payload };

/// Packs a Zig integer or float into a number node's tag and payload.
inline fn numberScalar(value: anytype) common.AccessError!Scalar {
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

fn checkAttachable(parent: NodeMut, value: NodeMut) MutateError!void {
    if (value.storage != parent.storage) return error.DifferentStorage;
    if (value.index == parent.index or isAttached(value)) return error.AlreadyAttached;
    // A detached node can still hold `parent` in its own subtree, and attaching
    // it there would make the tree a cycle. The walk is short in practice: it
    // stops at the root.
    const nodes = parent.storage.nodes.items;
    var cursor = parent.index;
    while (cursor != none) : (cursor = nodes[cursor].parent) {
        if (cursor == value.index) return error.WouldCycle;
    }
}

/// A node is attached when it is linked into a tree or is the document root.
fn isAttached(node: NodeMut) bool {
    if (node.index == node.storage.root) return true;
    const data = node.storage.nodes.items[node.index];
    return data.parent != none or data.prev != none or data.next != none;
}

fn copyNode(storage: *StorageMut, source: NodeData, source_input: []const u8) !u32 {
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
fn copySubtree(storage: *StorageMut, source: NodeMut) !u32 {
    const allocator = storage.allocator;
    const source_root = source.storage.nodes.items[source.index];
    const root_index = try copyNode(storage, source_root, source.storage.input.items);
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
        const source_index = frame.cursor;
        const source_node = source.storage.nodes.items[source_index];
        frame.cursor = source_node.next;
        frame.remaining -= 1;
        const parent_index = frame.new_index;

        const new_child = try copyNode(storage, source_node, source.storage.input.items);
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

/// A container still being written, with its emit position and total slots.
const MutFrame = struct {
    index: u32,
    object: bool,
    slot: usize,
    count: usize,
};

/// Writes `node`, iteratively so document depth cannot overflow the stack.
fn writeMut(
    buffer: *encode.Buffer,
    node: NodeMut,
    options: WriteOptions,
    allocator: std.mem.Allocator,
) !void {
    const storage = node.storage;
    const nodes = storage.nodes.items;
    const start = nodes[node.index];
    const root_type = nodeType(start);
    if ((root_type != .array and root_type != .object) or nodeLen(start) == 0) {
        return writeMutSingle(buffer, storage, start);
    }

    var stack: std.ArrayList(MutFrame) = .empty;
    defer stack.deinit(allocator);

    var current: MutFrame = .{
        .index = node.index,
        .object = root_type == .object,
        .slot = 0,
        .count = if (root_type == .object) nodeLen(start) * 2 else nodeLen(start),
    };
    var child = head(start);
    var level: usize = 1;

    try buffer.reserve(2);
    buffer.put(if (current.object) '{' else '[');
    if (options.pretty) buffer.put('\n');

    while (true) {
        if (current.slot == current.count) {
            // Close this container and step back to its parent's next sibling.
            if (options.pretty) {
                try buffer.reserve(level * 4 + 2);
                buffer.put('\n');
                level -= 1;
                buffer.putSpaces(level * 4);
            } else {
                try buffer.reserve(1);
            }
            buffer.put(if (current.object) '}' else ']');
            const closed = current.index;
            current = stack.pop() orelse return;
            current.slot += 1;
            child = nodes[closed].next;
            continue;
        }

        const item_index = child;
        const item = nodes[item_index];
        const item_type = nodeType(item);
        const is_key = current.object and current.slot % 2 == 0;

        if (current.slot != 0) {
            try buffer.reserve(2);
            if (is_key) {
                // The previous slot held an object member value.
                buffer.put(',');
                if (options.pretty) buffer.put('\n');
            } else if (current.object) {
                // This slot is an object member value, directly after its key.
                buffer.put(':');
                if (options.pretty) buffer.put(' ');
            } else {
                buffer.put(',');
                if (options.pretty) buffer.put('\n');
            }
        }
        // Object member values stay on their key's line; keys and array elements do not.
        if (options.pretty and !(current.object and !is_key)) {
            try buffer.reserve(level * 4);
            buffer.putSpaces(level * 4);
        }

        switch (item_type) {
            .string => try writeMutString(buffer, storage, item),
            .number => try writeMutNumber(buffer, item),
            .bool => {
                try buffer.reserve(5);
                buffer.putAll(if (nodeSubtype(item) == pool_mod.true_flag) "true" else "false");
            },
            .null => {
                try buffer.reserve(4);
                buffer.putAll("null");
            },
            .array, .object => {
                const child_object = item_type == .object;
                const child_len = nodeLen(item);
                if (child_len == 0) {
                    try buffer.reserve(2);
                    buffer.putAll(if (child_object) "{}" else "[]");
                } else {
                    try stack.append(allocator, current);
                    current = .{
                        .index = item_index,
                        .object = child_object,
                        .slot = 0,
                        .count = if (child_object) child_len * 2 else child_len,
                    };
                    try buffer.reserve(2);
                    buffer.put(if (child_object) '{' else '[');
                    if (options.pretty) {
                        buffer.put('\n');
                        level += 1;
                    }
                    child = head(item);
                    continue;
                }
            },
            else => unreachable,
        }

        current.slot += 1;
        child = nodes[item_index].next;
    }
}

/// Writes a node that is not a non-empty container.
fn writeMutSingle(buffer: *encode.Buffer, storage: *const StorageMut, node: NodeData) !void {
    switch (nodeType(node)) {
        .string => try writeMutString(buffer, storage, node),
        .number => try writeMutNumber(buffer, node),
        .bool => {
            try buffer.reserve(5);
            buffer.putAll(if (nodeSubtype(node) == pool_mod.true_flag) "true" else "false");
        },
        .null => {
            try buffer.reserve(4);
            buffer.putAll("null");
        },
        .array => {
            try buffer.reserve(2);
            buffer.putAll("[]");
        },
        .object => {
            try buffer.reserve(2);
            buffer.putAll("{}");
        },
        else => unreachable,
    }
}

inline fn writeMutString(buffer: *encode.Buffer, storage: *const StorageMut, node: NodeData) !void {
    try encode.writeStringBytes(
        buffer,
        stringAtMut(storage, &node),
        nodeSubtype(node) != pool_mod.no_escape,
    );
}

inline fn writeMutNumber(buffer: *encode.Buffer, node: NodeData) !void {
    switch (nodeSubtype(node)) {
        .real => try encode.writeReal(buffer, node.payload.float),
        .one => try encode.writeSigned(buffer, node.payload.int),
        .none => try encode.writeUnsigned(buffer, node.payload.uint),
    }
}
