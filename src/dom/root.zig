const common = @import("common.zig");
const pool = @import("pool.zig");
const reader = @import("reader.zig");
const rfc = @import("rfc.zig");
const encode = @import("encode.zig");
const document = @import("Document/root.zig");
const document_mut = @import("DocumentMut/root.zig");

/// An owned parsed DOM document.
pub const Document = document.Document;
/// An owned mutable document.
pub const DocumentMut = document_mut.DocumentMut;
/// A borrowed view of any node in an owned document.
pub const Node = document.Node;
/// A borrowed handle to one node of a `DocumentMut`.
pub const NodeMut = document_mut.NodeMut;
/// The kind of a DOM value.
pub const Kind = document.Kind;
/// Numeric target types accepted by `Node.toNumber` and `Node.asNumber`.
pub const NumberType = document.NumberType;
/// Errors returned when a node cannot be accessed or converted.
pub const AccessError = document.AccessError;
/// Errors from resolving an RFC 6901 JSON Pointer.
pub const PointerError = document.PointerError;
/// Errors returned by structural edits to a `DocumentMut`.
pub const MutateError = document_mut.MutateError;

/// Options that control DOM parsing.
pub const ParseOptions = document.ParseOptions;
/// Errors returned by DOM parsing.
pub const ParseError = document.ParseError;
/// Options that control DOM serialization.
pub const WriteOptions = document.WriteOptions;

/// Whether `token` is a well-formed RFC 6901 reference token.
pub const validToken = rfc.validToken;
/// Decodes one RFC 6901 reference token into `buffer`, which must hold at least
/// `token.len` bytes.
pub const decodeToken = rfc.decodeToken;
/// Parses an RFC 6901 array index token, or null when it is not one.
pub const parseArrayIndex = rfc.parseArrayIndex;

/// Parses JSON into an owned DOM document.
pub const parse = document.parse;
/// Parses JSON into caller-provided storage.
pub const parseInto = document.parseInto;
/// Returns the required storage size for `parseInto`.
pub const parseBufferSize = document.parseBufferSize;

/// Parses JSON straight into a mutable document.
pub const parseMut = document_mut.parse;

/// Serializes a DOM node to a newly allocated JSON byte slice owned by `allocator`.
pub const toSlice = document.toSlice;
/// Serializes a DOM node directly to an IO writer.
pub const toWriter = document.toWriter;

test {
    _ = common;
    _ = document;
    _ = document_mut;
    _ = pool;
    _ = reader;
    _ = rfc;
    _ = encode;
}
