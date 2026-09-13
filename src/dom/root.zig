const document = @import("document.zig");
const view = @import("view.zig");
const pool = @import("pool.zig");
const reader = @import("reader.zig");
const writer = @import("writer.zig");
const rfc = @import("rfc.zig");

/// An owned parsed DOM document.
pub const Document = document.Document;
/// A borrowed view of any node in an owned document.
pub const DocView = view.DocView;
/// The kind of a DOM value.
pub const Kind = view.Kind;
/// Errors returned when a node cannot be accessed or converted.
pub const AccessError = view.AccessError;
/// Errors from resolving an RFC 6901 JSON Pointer.
pub const PointerError = view.PointerError;
/// Numeric target types accepted by `DocView.toNumber` and `DocView.asNumber`.
pub const NumberType = view.NumberType;

/// Options that control DOM parsing.
pub const ParseOptions = document.ParseOptions;
/// Errors returned by DOM parsing.
pub const ParseError = document.ParseError;
/// Options that control DOM serialization.
pub const WriteOptions = view.WriteOptions;

/// Parses JSON into an owned DOM document.
pub const parse = document.parse;
/// Parses JSON into caller-provided storage.
pub const parseInto = document.parseInto;
/// Returns the required storage size for `parseInto`.
pub const parseBufferSize = document.parseBufferSize;

/// Serializes a DOM value to an allocated JSON slice.
pub const toSlice = view.toSlice;
/// Serializes a DOM value directly to an IO writer.
pub const toWriter = view.toWriter;

test {
    _ = document;
    _ = view;
    _ = pool;
    _ = reader;
    _ = writer;
    _ = rfc;
}
