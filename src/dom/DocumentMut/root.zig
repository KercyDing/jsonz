//! The mutable DOM: `DocumentMut` and the `NodeMut` handles into it.
const common = @import("../common.zig");
const node_mut = @import("NodeMut.zig");

/// An owned editable document.
pub const DocumentMut = @import("DocumentMut.zig");
/// A borrowed handle to one node of a `DocumentMut`.
pub const NodeMut = node_mut;
/// Errors returned by structural edits.
pub const MutateError = node_mut.MutateError;
/// The kind of a DOM value.
pub const Kind = common.Kind;
/// Numeric target types accepted by `NodeMut.toNumber` and `NodeMut.asNumber`.
pub const NumberType = common.NumberType;
/// Errors returned when a node cannot be accessed or converted.
pub const AccessError = common.AccessError;
/// Errors from resolving an RFC 6901 JSON Pointer.
pub const PointerError = common.PointerError;
/// Options that control DOM serialization.
pub const WriteOptions = common.WriteOptions;
/// RFC 6902 JSON Patch.
pub const patch = @import("patch.zig");
/// Parses JSON straight into a mutable document.
pub const parse = DocumentMut.parse;

test {
    _ = @import("DocumentMut.zig");
    _ = node_mut;
}
