/// An editable JSON document. Call `deinit` once when finished.
///
/// Nodes are linked - each one knows its parent and its previous and next
/// sibling - so structural edits are pointer updates instead of shifting a
/// contiguous pool. `NodeMut` is a borrowed handle to one node, and
/// `StorageMut` owns the nodes and strings.
const DocumentMut = @This();

const std = @import("std");
const common = @import("../common.zig");
const NodeMut = @import("NodeMut.zig");

/// Node and string storage owned by this document.
storage: NodeMut.StorageMut,

/// Creates a document whose root is `null`, ready to be filled by editing.
pub fn init(allocator: std.mem.Allocator) !DocumentMut {
    var storage: NodeMut.StorageMut = .{ .allocator = allocator };
    errdefer storage.nodes.deinit(allocator);
    storage.root = try NodeMut.createNull(&storage);
    return .{ .storage = storage };
}

/// Deep-copies a compact read-only tree into a new mutable document.
pub fn fromStorage(
    allocator: std.mem.Allocator,
    source: *const common.Storage,
    root_index: u32,
) !DocumentMut {
    return .{ .storage = try NodeMut.fromStorage(allocator, source, root_index) };
}

/// Deep-copies `source` into a new document; the copy shares nothing with it.
pub fn clone(allocator: std.mem.Allocator, source: *DocumentMut) !DocumentMut {
    var copy = try init(allocator);
    errdefer copy.deinit();
    try copy.root().copyFrom(source.root());
    return copy;
}

/// Releases all node and string storage.
pub fn deinit(self: *DocumentMut) void {
    self.storage.nodes.deinit(self.storage.allocator);
    self.storage.input.deinit(self.storage.allocator);
    self.* = undefined;
}

/// Returns a handle to the document's root node.
pub fn root(self: *DocumentMut) NodeMut {
    return .{ .storage = &self.storage, .index = self.storage.root };
}

/// Serializes the document's root node to a newly allocated JSON byte slice.
pub fn toSlice(self: *DocumentMut, allocator: std.mem.Allocator, options: common.WriteOptions) ![]u8 {
    return self.root().toSlice(allocator, options);
}

/// Serializes the document's root node to `writer`.
pub fn toWriter(self: *DocumentMut, writer: *std.Io.Writer, options: common.WriteOptions) !void {
    return self.root().toWriter(writer, options);
}

/// Resolves a comptime-known RFC 6901 JSON Pointer against the root node.
pub fn ptrGet(self: *DocumentMut, comptime ptr: []const u8) common.PointerError!NodeMut {
    return self.root().ptrGet(ptr);
}

/// Resolves a comptime-known JSON Pointer format against the root node.
pub fn ptrGetFmt(self: *DocumentMut, comptime fmt: []const u8, args: anytype) common.PointerError!NodeMut {
    return self.root().ptrGetFmt(fmt, args);
}

/// Resolves a runtime RFC 6901 JSON Pointer against the root node.
pub fn ptrGetDyn(self: *DocumentMut, ptr: []const u8) common.PointerError!NodeMut {
    return self.root().ptrGetDyn(ptr);
}

/// Creates a detached `null` node; attach it with `addField`, `append`, or
/// `insertAt`.
pub fn newNull(self: *DocumentMut) !NodeMut {
    return self.wrap(try NodeMut.createNull(&self.storage));
}

/// Creates a detached boolean node.
pub fn newBool(self: *DocumentMut, value: bool) !NodeMut {
    return self.wrap(try NodeMut.createBool(&self.storage, value));
}

/// Creates a detached number node.
pub fn newNumber(self: *DocumentMut, value: anytype) !NodeMut {
    return self.wrap(try NodeMut.createNumber(&self.storage, value));
}

/// Creates a detached string node.
pub fn newString(self: *DocumentMut, value: []const u8) !NodeMut {
    return self.wrap(try NodeMut.createString(&self.storage, value));
}

/// Creates a detached empty array node.
pub fn newArray(self: *DocumentMut) !NodeMut {
    return self.wrap(try NodeMut.createArray(&self.storage));
}

/// Creates a detached empty object node.
pub fn newObject(self: *DocumentMut) !NodeMut {
    return self.wrap(try NodeMut.createObject(&self.storage));
}

fn wrap(self: *DocumentMut, index: u32) NodeMut {
    return .{ .storage = &self.storage, .index = index };
}
