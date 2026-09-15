/// A mutable JSON node, plus the storage and traversal behind it.
///
/// Nodes are linked - each one knows its parent and its previous and next
/// sibling - so structural edits are pointer updates instead of shifting a
/// contiguous pool. A `NodeMut` is a borrowed handle into one `StorageMut`.
const NodeMut = @This();

const std = @import("std");
const storage_mod = @import("storage.zig");
const pool_mod = @import("../pool.zig");
const common = @import("../common.zig");
const encode = @import("../encode.zig");
const rfc = @import("../rfc.zig");
const reader = @import("../reader.zig");

/// A borrowed handle to one node of a `DocumentMut`; it does not own memory.
storage: *StorageMut,
index: u32,

// The storage layer, under this file's short names; `storage.zig` owns it.
const none = storage_mod.none;
const NodeData = storage_mod.NodeData;
const StorageMut = storage_mod.StorageMut;
const nodeType = storage_mod.nodeType;
const nodeSubtype = storage_mod.nodeSubtype;
const nodeLen = storage_mod.nodeLen;
const head = storage_mod.head;
const tail = storage_mod.tail;
const setChildren = storage_mod.setChildren;
const stringAtMut = storage_mod.stringAtMut;
const isMemberValue = storage_mod.isMemberValue;
const setMemberValue = storage_mod.setMemberValue;
const setValue = storage_mod.setValue;
const storeString = storage_mod.storeString;
const stringTag = storage_mod.stringTag;
const storeStringNode = storage_mod.storeStringNode;
const numberScalar = storage_mod.numberScalar;
const linkChild = storage_mod.linkChild;
const unlink = storage_mod.unlink;
const insertBefore = storage_mod.insertBefore;
const copySubtree = storage_mod.copySubtree;
const createNull = storage_mod.createNull;
const createBool = storage_mod.createBool;
const createNumber = storage_mod.createNumber;

/// The kind of a DOM value.
const Kind = common.Kind;

/// Numeric types accepted by `NodeMut.toNumber` and `NodeMut.asNumber`.
const NumberType = common.NumberType;

/// Errors returned when a node cannot be accessed or converted.
const AccessError = common.AccessError;

/// Errors from resolving an RFC 6901 JSON Pointer.
pub const PointerError = common.PointerError;

/// Options that control DOM serialization.
const WriteOptions = common.WriteOptions;

/// Errors returned by structural edits.
pub const MutateError = std.mem.Allocator.Error || common.AccessError || error{
    /// The node is already linked into a tree.
    AlreadyAttached,
    /// The node belongs to another document's storage.
    DifferentStorage,
    /// Attaching the node there would make it its own descendant.
    WouldCycle,
};

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
    const copy_index = try copySubtree(self.storage, source.storage, source.index);
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

/// Appends an object member whose value is `null`.
pub fn addNull(self: NodeMut, key: []const u8) !void {
    if (!self.isObject()) return error.UnexpectedType;
    return self.addMember(key, try createNull(self.storage));
}

/// Appends an object member whose value is a boolean.
pub fn addBool(self: NodeMut, key: []const u8, value: bool) !void {
    if (!self.isObject()) return error.UnexpectedType;
    return self.addMember(key, try createBool(self.storage, value));
}

/// Appends an object member whose value is a number.
pub fn addNumber(self: NodeMut, key: []const u8, value: anytype) !void {
    if (!self.isObject()) return error.UnexpectedType;
    return self.addMember(key, try createNumber(self.storage, value));
}

/// Appends an object member whose value is a string.
pub fn addString(self: NodeMut, key: []const u8, value: []const u8) !void {
    if (!self.isObject()) return error.UnexpectedType;
    return self.addMember(key, try storeStringNode(self.storage, value));
}

/// Appends an array element. `value` must be a detached node of this document.
pub fn append(self: NodeMut, value: NodeMut) MutateError!void {
    if (!self.isArray()) return error.UnexpectedType;
    try checkAttachable(self, value);
    self.appendChild(value.index);
}

/// Appends a `null` array element.
pub fn appendNull(self: NodeMut) !void {
    if (!self.isArray()) return error.UnexpectedType;
    self.appendChild(try createNull(self.storage));
}

/// Appends a boolean array element.
pub fn appendBool(self: NodeMut, value: bool) !void {
    if (!self.isArray()) return error.UnexpectedType;
    self.appendChild(try createBool(self.storage, value));
}

/// Appends a number array element.
pub fn appendNumber(self: NodeMut, value: anytype) !void {
    if (!self.isArray()) return error.UnexpectedType;
    self.appendChild(try createNumber(self.storage, value));
}

/// Appends a string array element.
pub fn appendString(self: NodeMut, value: []const u8) !void {
    if (!self.isArray()) return error.UnexpectedType;
    self.appendChild(try storeStringNode(self.storage, value));
}

/// Links a key and a freshly created value into this object.
fn addMember(self: NodeMut, key: []const u8, value_index: u32) !void {
    const key_index = try storeStringNode(self.storage, key);
    linkChild(self.storage, self.index, key_index);
    linkChild(self.storage, self.index, value_index);
    setMemberValue(&self.storage.nodes.items[value_index], true);
    self.raw().tag.len += 1;
}

/// Links a freshly created value into this array.
fn appendChild(self: NodeMut, value_index: u32) void {
    linkChild(self.storage, self.index, value_index);
    setMemberValue(&self.storage.nodes.items[value_index], false);
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
