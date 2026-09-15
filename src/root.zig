/// Typed JSON parsing and serialization for Zig values.
pub const typed = @import("typed/root.zig");
/// A DOM for arbitrary JSON documents.
pub const dom = @import("dom/root.zig");
/// Format diagnosis for JSON that a parser rejected.
pub const diagnostic = @import("diagnostic/root.zig");
/// RFC 6902 JSON Patch.
pub const patch = dom.patch;

test {
    _ = typed;
    _ = dom;
    _ = diagnostic;
    _ = patch;
}
