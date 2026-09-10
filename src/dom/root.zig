const document = @import("document.zig");
const value = @import("value.zig");
const pool = @import("pool.zig");
const reader = @import("reader.zig");

/// An owned parsed DOM document.
pub const Document = document.Document;
/// A borrowed DOM value view.
pub const Value = value.Value;
/// The kind of a DOM value.
pub const Kind = value.Kind;
/// A borrowed DOM object view.
pub const Object = value.Object;
/// A borrowed key/value pair from a DOM object.
pub const ObjectEntry = value.ObjectEntry;
/// Iterator over DOM object fields.
pub const ObjectIterator = value.ObjectIterator;
/// A borrowed DOM array view.
pub const Array = value.Array;
/// Iterator over DOM array values.
pub const ArrayIterator = value.ArrayIterator;

/// Options that control DOM parsing.
pub const ParseOptions = document.ParseOptions;
/// Errors returned by DOM parsing.
pub const ParseError = document.ParseError;
/// Options that control DOM serialization.
pub const WriteOptions = value.WriteOptions;

/// Parses JSON into an owned DOM document.
pub const parse = document.parse;
/// Parses JSON into caller-provided storage.
pub const parseInto = document.parseInto;
/// Returns the required storage size for `parseInto`.
pub const parseBufferSize = document.parseBufferSize;

/// Serializes a DOM value to an allocated JSON slice.
pub const toSlice = value.toSlice;
/// Serializes a DOM value directly to an IO writer.
pub const toWriter = value.toWriter;

test {
    _ = document;
    _ = value;
    _ = pool;
    _ = reader;
}
