//! The mutable DOM: `DocumentMut` and the `NodeMut` handles into it.
//!
//! Only what `jsonz.dom` re-exports is public; `storage.zig` and the glue below
//! are module internals.
const std = @import("std");
const common = @import("../common.zig");
const storage_mod = @import("storage.zig");
const node_mut = @import("NodeMut.zig");

/// An owned editable document.
pub const DocumentMut = @import("DocumentMut.zig");
/// A borrowed handle to one node of a `DocumentMut`.
pub const NodeMut = node_mut;
/// Errors returned by structural edits.
pub const MutateError = node_mut.MutateError;
/// Parses JSON straight into a mutable document.
pub const parse = DocumentMut.parse;

/// Copies a compact read-only storage into a new mutable document; the glue
/// behind `Document.toMut`, which is the entry point users need.
pub fn fromStorage(
    allocator: std.mem.Allocator,
    source: *const common.Storage,
    root_index: u32,
) std.mem.Allocator.Error!DocumentMut {
    return .{ .storage = try storage_mod.fromStorage(allocator, source, root_index) };
}

test {
    _ = @import("DocumentMut.zig");
    _ = node_mut;
}
