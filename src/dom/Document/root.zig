//! The compact, read-only DOM: `Document` and the `Node` views into it.
const std = @import("std");
const writer = @import("writer.zig");

/// An owned parsed DOM document.
pub const Document = @import("Document.zig");
/// A borrowed view of any node in an owned document.
pub const Node = @import("Node.zig");
/// The kind of a DOM value.
pub const Kind = Node.Kind;
/// Numeric target types accepted by `Node.toNumber` and `Node.asNumber`.
pub const NumberType = Node.NumberType;
/// Errors returned when a node cannot be accessed or converted.
pub const AccessError = Node.AccessError;
/// Errors from resolving an RFC 6901 JSON Pointer.
pub const PointerError = Node.PointerError;
/// Options that control DOM parsing.
pub const ParseOptions = Document.ParseOptions;
/// Errors returned by DOM parsing.
pub const ParseError = Document.ParseError;
/// Options that control DOM serialization.
pub const WriteOptions = Node.WriteOptions;

/// Parses JSON into an owned DOM document.
pub const parse = Document.parse;
/// Parses JSON into caller-provided storage.
pub const parseInto = Document.parseInto;
/// Returns the required storage size for `parseInto`.
pub const parseBufferSize = Document.parseBufferSize;

/// Serializes a DOM node to a newly allocated JSON byte slice owned by `allocator`.
pub fn toSlice(allocator: std.mem.Allocator, node: Node, options: WriteOptions) ![]u8 {
    return node.toSlice(allocator, options);
}

/// Serializes a DOM node directly to an IO writer.
pub fn toWriter(output: *std.Io.Writer, node: Node, options: WriteOptions) !void {
    return node.toWriter(output, options);
}

test {
    _ = Document;
    _ = Node;
    _ = writer;
}
