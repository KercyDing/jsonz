/// Typed JSON parsing and serialization for Zig values.
pub const typed = @import("typed/root.zig");
/// A DOM for arbitrary JSON documents.
pub const dom = @import("dom/root.zig");

test {
    _ = typed;
    _ = dom;
}
