const deserialize = @import("deserialize.zig");
const serialize = @import("serialize.zig");
const cursor = @import("cursor.zig");
const kind = @import("kind.zig");
const pool = @import("pool.zig");

pub const ParseOptions = deserialize.Options;
pub const ParseError = deserialize.Error;
pub const SerializeOptions = serialize.Options;
pub const Parsed = deserialize.Parsed;

pub const parse = deserialize.parse;
pub const parseBorrowed = deserialize.parseBorrowed;
pub const parseInto = deserialize.parseInto;

pub const toSlice = serialize.toSlice;
pub const toWriter = serialize.toWriter;

test {
    _ = deserialize;
    _ = serialize;
    _ = cursor;
    _ = kind;
    _ = pool;
}
