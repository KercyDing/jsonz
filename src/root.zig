const kind_mod = @import("kind.zig");
const serialize_mod = @import("serialize.zig");
const deserialize_mod = @import("deserialize.zig");
const cursor_mod = @import("cursor.zig");
const dom_mod = @import("dom.zig");

// Typed serialization
pub const SerializeOptions = serialize_mod.Options;

pub const toSlice = serialize_mod.toSlice;
pub const toWriter = serialize_mod.toWriter;

// Typed deserialization
pub const Parsed = deserialize_mod.Parsed;
pub const DeserializeOptions = deserialize_mod.Options;
pub const DeserializeError = deserialize_mod.Error;

pub const fromSlice = deserialize_mod.fromSlice;
pub const fromSliceBorrowed = deserialize_mod.fromSliceBorrowed;
pub const fromSliceInto = deserialize_mod.fromSliceInto;
pub const fromSliceOwned = deserialize_mod.parse;

// DOM / arbitrary JSON
pub const Document = dom_mod.Document;
pub const Value = dom_mod.Value;
pub const Kind = dom_mod.Kind;
pub const ParseOptions = dom_mod.ParseOptions;
pub const ParseError = dom_mod.ParseError;
pub const ValueWriteOptions = dom_mod.WriteOptions;

pub const toSliceValue = dom_mod.toSliceValue;
pub const parse = dom_mod.parse;

test {
    _ = kind_mod;
    _ = serialize_mod;
    _ = deserialize_mod;
    _ = cursor_mod;
    _ = dom_mod;
}
