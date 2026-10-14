/// Typed JSON parsing and serialization for Zig values.
pub const typed = @import("typed/root.zig");
/// A DOM for arbitrary JSON documents.
pub const dom = @import("dom/root.zig");
/// Format diagnosis for JSON that a parser rejected.
pub const diagnostic = @import("diagnostic/root.zig");

test {
    const std = @import("std");

    std.testing.refAllDecls(typed);
    std.testing.refAllDecls(dom);
    std.testing.refAllDecls(diagnostic);
}
