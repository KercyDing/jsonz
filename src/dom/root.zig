const document = @import("document.zig");
const value = @import("value.zig");

pub const Document = document.Document;
pub const Value = value.Value;
pub const Kind = value.Kind;
pub const Object = value.Object;
pub const ObjectEntry = value.ObjectEntry;
pub const ObjectIterator = value.ObjectIterator;
pub const Array = value.Array;
pub const ArrayIterator = value.ArrayIterator;

pub const ParseOptions = document.ParseOptions;
pub const ParseError = document.ParseError;
pub const WriteOptions = value.WriteOptions;

pub const parse = document.parse;
pub const parseInto = document.parseInto;
pub const parseBufferSize = document.parseBufferSize;

pub const toSlice = value.toSlice;
pub const toWriter = value.toWriter;

test {
    _ = document;
    _ = value;
}
