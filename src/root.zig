/// Typed JSON parsing and serialization for Zig values.
pub const typed = @import("typed/root.zig");
/// A zero-copy-friendly JSON DOM backed by yyjson.
pub const dom = @import("dom/root.zig");

test {
    _ = typed;
    _ = dom;
}
