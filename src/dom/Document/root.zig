//! The compact, read-only DOM: `Document` and the `Node` views into it.
const writer = @import("writer.zig");

/// An owned parsed DOM document.
pub const Document = @import("Document.zig");
/// A borrowed view of any node in an owned document.
pub const Node = @import("Node.zig");
/// Options that control DOM parsing.
pub const ParseOptions = Document.ParseOptions;
/// Errors returned by DOM parsing.
pub const ParseError = Document.ParseError;

/// Parses JSON into an owned DOM document.
pub const parse = Document.parse;
/// Parses JSON into caller-provided storage.
pub const parseInto = Document.parseInto;
/// Returns the required storage size for `parseInto`.
pub const parseBufferSize = Document.parseBufferSize;

test {
    _ = Document;
    _ = Node;
    _ = writer;
}
