/// An editable JSON document. Call `deinit` once when finished.
///
/// Nodes are linked - each one knows its parent and its previous and next
/// sibling - so structural edits are pointer updates instead of shifting a
/// contiguous pool. `NodeMut` is a borrowed handle to one node, and
/// `StorageMut` owns the nodes and strings.
const DocumentMut = @This();

const std = @import("std");
const common = @import("../common.zig");
const reader = @import("../reader.zig");
const NodeMut = @import("NodeMut.zig");
const storage_mod = @import("storage.zig");
const Document = @import("../Document/root.zig").Document;
pub const patch = @import("patch.zig");

/// Node and string storage owned by this document.
storage: storage_mod.StorageMut,

/// What a new document's root is, chosen with `init`.
///
/// Only the two containers: a value on its own has no building semantics, and
/// a document that should hold something else starts from one of these and
/// calls `replaceNull` / `replaceNumber` / ... on the root.
pub const RootKind = enum { object, array };

/// Creates an empty document whose root is an object or an array.
pub fn init(allocator: std.mem.Allocator, kind: RootKind) !DocumentMut {
    var document = try initEmpty(allocator);
    errdefer document.deinit();
    const container = switch (kind) {
        .object => try document.newObject(),
        .array => try document.newArray(),
    };
    try document.root().replace(container);
    return document;
}

/// Creates a document whose root is `null`, for `clone` and `init`, which
/// replace the whole root right away. A caller that wants a non-container root
/// starts from `init` and replaces the root node.
fn initEmpty(allocator: std.mem.Allocator) !DocumentMut {
    var storage: storage_mod.StorageMut = .{ .allocator = allocator };
    errdefer storage.nodes.deinit(allocator);
    storage.root = try storage_mod.createNull(&storage);
    return .{ .storage = storage };
}

/// Parses `input` into a new mutable document.
///
/// It shares `../reader.zig` with `Document.parse` and builds linked nodes
/// directly, so no compact tree is built in between.
pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: reader.Options,
) reader.Error!DocumentMut {
    // Escape sequences are decoded in place, so the reader needs its own copy.
    const buffer = try allocator.alloc(u8, input.len + 4);
    defer allocator.free(buffer);
    @memcpy(buffer[0..input.len], input);
    @memset(buffer[input.len..], 0);

    var storage: storage_mod.StorageMut = .{ .allocator = allocator };
    errdefer storage.nodes.deinit(allocator);
    errdefer storage.input.deinit(allocator);
    storage.root = try storage_mod.parseInto(&storage, buffer, input.len, options);
    return .{ .storage = storage };
}

/// Deep-copies `source` into a new document; the copy shares nothing with it.
pub fn clone(allocator: std.mem.Allocator, source: *DocumentMut) !DocumentMut {
    var copy = try initEmpty(allocator);
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

/// Copies this document into a compact read-only `Document`.
///
/// The copy is deep and independent, so it stays valid after this document is
/// freed. Freezing an edited document is how it is shared for reading: `Node`
/// borrows `*const Storage`, so a `*const Document` has no mutating API at all,
/// while a `DocumentMut` cannot even be read through a constant pointer.
pub fn toDocument(self: *DocumentMut, allocator: std.mem.Allocator) std.mem.Allocator.Error!Document {
    const compact = try storage_mod.toCompact(&self.storage, self.storage.root, allocator);
    var document: Document = .{
        .pool = compact.pool,
        .storage = .{ .nodes = &.{}, .input = compact.input },
        .root_index = compact.root_index,
    };
    document.storage.nodes = document.pool.items();
    return document;
}

/// Applies an RFC 6902 JSON Patch to this document, atomically.
///
/// It is `DocumentMut.patch.apply` with this document as the target; a failed
/// operation leaves the document unchanged.
pub fn applyPatch(self: *DocumentMut, text: []const u8, options: patch.Options) patch.Error!void {
    return patch.apply(self, text, options);
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
    return self.wrap(try storage_mod.createNull(&self.storage));
}

/// Creates a detached boolean node.
pub fn newBool(self: *DocumentMut, value: bool) !NodeMut {
    return self.wrap(try storage_mod.createBool(&self.storage, value));
}

/// Creates a detached number node.
pub fn newNumber(self: *DocumentMut, value: anytype) !NodeMut {
    return self.wrap(try storage_mod.createNumber(&self.storage, value));
}

/// Creates a detached string node.
pub fn newString(self: *DocumentMut, value: []const u8) !NodeMut {
    return self.wrap(try storage_mod.createString(&self.storage, value));
}

/// Creates a detached empty array node.
pub fn newArray(self: *DocumentMut) !NodeMut {
    return self.wrap(try storage_mod.createArray(&self.storage));
}

/// Creates a detached empty object node.
pub fn newObject(self: *DocumentMut) !NodeMut {
    return self.wrap(try storage_mod.createObject(&self.storage));
}

fn wrap(self: *DocumentMut, index: u32) NodeMut {
    return .{ .storage = &self.storage, .index = index };
}
