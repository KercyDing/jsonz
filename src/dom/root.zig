const common = @import("common.zig");
const pool = @import("pool.zig");
const reader = @import("reader.zig");
const rfc = @import("rfc.zig");
const encode = @import("encode.zig");
const document = @import("Document/root.zig");

/// An owned parsed DOM document.
pub const Document = document.Document;
/// A borrowed view of any node in an owned document.
pub const Node = document.Node;
/// The kind of a DOM value.
pub const Kind = document.Kind;
/// Numeric target types accepted by `Node.toNumber` and `Node.asNumber`.
pub const NumberType = document.NumberType;
/// Errors returned when a node cannot be accessed or converted.
pub const AccessError = document.AccessError;
/// Errors from resolving an RFC 6901 JSON Pointer.
pub const PointerError = document.PointerError;

/// Options that control DOM parsing.
pub const ParseOptions = document.ParseOptions;
/// Errors returned by DOM parsing.
pub const ParseError = document.ParseError;
/// Options that control DOM serialization.
pub const WriteOptions = document.WriteOptions;

/// Parses JSON into an owned DOM document.
pub const parse = document.parse;
/// Parses JSON into caller-provided storage.
pub const parseInto = document.parseInto;
/// Returns the required storage size for `parseInto`.
pub const parseBufferSize = document.parseBufferSize;

/// Serializes a DOM node to a newly allocated JSON byte slice owned by `allocator`.
pub const toSlice = document.toSlice;
/// Serializes a DOM node directly to an IO writer.
pub const toWriter = document.toWriter;

test {
    _ = common;
    _ = document;
    _ = pool;
    _ = reader;
    _ = rfc;
    _ = encode;
}
