//! The mutable DOM: `DocumentMut` and the `NodeMut` handles into it.
const node_mut = @import("NodeMut.zig");

/// An owned editable document.
pub const DocumentMut = @import("DocumentMut.zig");
/// A borrowed handle to one node of a `DocumentMut`.
pub const NodeMut = node_mut;
/// Errors returned by structural edits.
pub const MutateError = node_mut.MutateError;
/// Parses JSON straight into a mutable document.
pub const parse = DocumentMut.parse;

test {
    _ = @import("DocumentMut.zig");
    _ = node_mut;
}
