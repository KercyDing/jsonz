const deserialize = @import("deserialize.zig");
const serialize = @import("serialize.zig");
const cursor = @import("cursor.zig");
const float = @import("float");
const kind = @import("kind.zig");
const pool = @import("pool.zig");

/// Options that control typed JSON parsing.
pub const ParseOptions = deserialize.Options;
/// Errors returned by typed parsing.
pub const ParseError = deserialize.Error;
/// Options that control typed JSON serialization.
pub const SerializeOptions = serialize.Options;
/// An owning typed parse result. Call `deinit` when finished.
pub const Parsed = deserialize.Parsed;

/// Parses JSON into an owning typed result.
pub const parse = deserialize.parse;
/// Parses JSON while borrowing unescaped strings from the input.
pub const parseBorrowed = deserialize.parseBorrowed;
/// Parses JSON into caller-provided storage.
pub const parseInto = deserialize.parseInto;

/// Serializes a Zig value to an allocated JSON slice.
pub const toSlice = serialize.toSlice;
/// Serializes a Zig value directly to an IO writer.
pub const toWriter = serialize.toWriter;

test {
    _ = deserialize;
    _ = serialize;
    _ = cursor;
    _ = float;
    _ = kind;
    _ = pool;
}
