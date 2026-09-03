const kind_mod = @import("kind.zig");
const serialize_mod = @import("serialize.zig");
const deserialize_mod = @import("deserialize.zig");
const cursor_mod = @import("cursor.zig");

// Types
pub const SerializeOptions = serialize_mod.Options;
pub const Parsed = deserialize_mod.Parsed;
pub const DeserializeOptions = deserialize_mod.Options;
pub const DeserializeError = deserialize_mod.Error;

// Functions
pub const toSlice = serialize_mod.toSlice;
pub const toWriter = serialize_mod.toWriter;
pub const fromSlice = deserialize_mod.fromSlice;
pub const fromSliceWith = deserialize_mod.fromSliceWith;
pub const fromSliceBorrowed = deserialize_mod.fromSliceBorrowed;
pub const parse = deserialize_mod.parse;

test {
    _ = kind_mod;
    _ = serialize_mod;
    _ = deserialize_mod;
    _ = cursor_mod;
}
