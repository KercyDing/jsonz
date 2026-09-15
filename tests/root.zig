//! Aggregates the integration tests. `zig build test` compiles this root and
//! the imports below pull in each test file. The fuzz targets live in
//! `fuzzy_tests.zig`, which `zig build fuzzy` runs on its own.

test {
    _ = @import("dom_tests.zig");
    _ = @import("patch_tests.zig");
    _ = @import("typed_tests.zig");
}
