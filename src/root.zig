/// Typed JSON parsing and serialization for Zig values.
pub const typed = @import("typed/root.zig");
/// A JSON DOM for arbitrary documents, written in Zig.
pub const dom = @import("dom/root.zig");

test {
    _ = typed;
    _ = dom;
}
