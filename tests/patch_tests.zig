//! RFC 6902 JSON Patch tests.
const std = @import("std");
const jsonz = @import("jsonz");

const dom = jsonz.dom;
const patch = dom.patch;
const testing = std.testing;

test "patch: add" {
    // A new object member, and an existing one replaced.
    try expectPatched("{\"a\":1,\"b\":2}", "{\"a\":1}", "[{\"op\":\"add\",\"path\":\"/b\",\"value\":2}]");
    try expectPatched("{\"a\":2}", "{\"a\":1}", "[{\"op\":\"add\",\"path\":\"/a\",\"value\":2}]");

    // Array elements are inserted, and `-` appends.
    try expectPatched("[0,1,2]", "[1,2]", "[{\"op\":\"add\",\"path\":\"/0\",\"value\":0}]");
    try expectPatched("[1,9,2]", "[1,2]", "[{\"op\":\"add\",\"path\":\"/1\",\"value\":9}]");
    try expectPatched("[1,2,3]", "[1,2]", "[{\"op\":\"add\",\"path\":\"/-\",\"value\":3}]");
    try expectPatched("[1,2,3]", "[1,2]", "[{\"op\":\"add\",\"path\":\"/2\",\"value\":3}]");

    // An empty path replaces the whole document, whatever it held.
    try expectPatched("{\"a\":1}", "null", "[{\"op\":\"add\",\"path\":\"\",\"value\":{\"a\":1}}]");
    try expectPatched("[1]", "{\"a\":1}", "[{\"op\":\"add\",\"path\":\"\",\"value\":[1]}]");

    // Values are deep-copied, subtrees included.
    try expectPatched("{\"a\":{\"b\":[1,2]}}", "{\"a\":{}}", "[{\"op\":\"add\",\"path\":\"/a/b\",\"value\":[1,2]}]");

    // `~1` names a member containing `/` and `~0` one containing `~`.
    try expectPatched(
        "{\"a/b\":1,\"m~n\":2}",
        "{}",
        "[{\"op\":\"add\",\"path\":\"/a~1b\",\"value\":1},{\"op\":\"add\",\"path\":\"/m~0n\",\"value\":2}]",
    );

    // Failures.
    try expectPatchFailure(error.OutOfBounds, "[1]", "[{\"op\":\"add\",\"path\":\"/2\",\"value\":9}]");
    try expectPatchFailure(error.InvalidArrayIndex, "[1]", "[{\"op\":\"add\",\"path\":\"/01\",\"value\":9}]");
    try expectPatchFailure(error.InvalidTarget, "{\"a\":1}", "[{\"op\":\"add\",\"path\":\"/a/b\",\"value\":1}]");
    try expectPatchFailure(error.MissingField, "{}", "[{\"op\":\"add\",\"path\":\"/a/b\",\"value\":1}]");
    try expectPatchFailure(error.InvalidPointer, "{}", "[{\"op\":\"add\",\"path\":\"a\",\"value\":1}]");
}

test "patch: remove" {
    try expectPatched("{\"b\":2}", "{\"a\":1,\"b\":2}", "[{\"op\":\"remove\",\"path\":\"/a\"}]");
    try expectPatched("[1,3]", "[1,2,3]", "[{\"op\":\"remove\",\"path\":\"/1\"}]");
    try expectPatched("{}", "{\"a/b\":1}", "[{\"op\":\"remove\",\"path\":\"/a~1b\"}]");
    try expectPatched("[1]", "[1,2]", "[{\"op\":\"remove\",\"path\":\"/1\"}]");

    try expectPatchFailure(error.MissingField, "{\"a\":1}", "[{\"op\":\"remove\",\"path\":\"/b\"}]");
    try expectPatchFailure(error.OutOfBounds, "[1]", "[{\"op\":\"remove\",\"path\":\"/1\"}]");
    try expectPatchFailure(error.InvalidArrayIndex, "[1]", "[{\"op\":\"remove\",\"path\":\"/-\"}]");
    try expectPatchFailure(error.InvalidTarget, "{\"a\":1}", "[{\"op\":\"remove\",\"path\":\"\"}]");
    try expectPatchFailure(error.InvalidTarget, "{\"a\":1}", "[{\"op\":\"remove\",\"path\":\"/a/b\"}]");
}

test "patch: replace" {
    try expectPatched("{\"a\":2}", "{\"a\":1}", "[{\"op\":\"replace\",\"path\":\"/a\",\"value\":2}]");
    try expectPatched("[1,9,3]", "[1,2,3]", "[{\"op\":\"replace\",\"path\":\"/1\",\"value\":9}]");
    try expectPatched("{\"a\":[1,2]}", "{\"a\":{}}", "[{\"op\":\"replace\",\"path\":\"/a\",\"value\":[1,2]}]");
    try expectPatched("null", "{\"a\":1}", "[{\"op\":\"replace\",\"path\":\"\",\"value\":null}]");

    try expectPatchFailure(error.MissingField, "{\"a\":1}", "[{\"op\":\"replace\",\"path\":\"/b\",\"value\":1}]");
    try expectPatchFailure(error.OutOfBounds, "[1]", "[{\"op\":\"replace\",\"path\":\"/1\",\"value\":1}]");
    try expectPatchFailure(error.InvalidArrayIndex, "[1]", "[{\"op\":\"replace\",\"path\":\"/-\",\"value\":1}]");
    try expectPatchFailure(error.InvalidTarget, "{\"a\":1}", "[{\"op\":\"replace\",\"path\":\"/a/b\",\"value\":1}]");
}

test "patch: move" {
    try expectPatched("{\"b\":2,\"c\":1}", "{\"a\":1,\"b\":2}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/c\"}]");
    // Removing first shifts the array, so the value lands at the given index.
    try expectPatched("[2,3,1]", "[1,2,3]", "[{\"op\":\"move\",\"from\":\"/0\",\"path\":\"/2\"}]");
    try expectPatched("[-1,1,2]", "[1,2,-1]", "[{\"op\":\"move\",\"from\":\"/2\",\"path\":\"/0\"}]");
    // A subtree moves as a whole.
    try expectPatched(
        "{\"a\":{},\"b\":{\"y\":1}}",
        "{\"a\":{\"x\":1},\"b\":{}}",
        "[{\"op\":\"move\",\"from\":\"/a/x\",\"path\":\"/b/y\"}]",
    );
    // Moving onto the same location is allowed, and so is moving to the root.
    try expectPatched("{\"a\":1}", "{\"a\":1}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/a\"}]");
    try expectPatched("[1]", "{\"a\":[1]}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"\"}]");

    try expectPatchFailure(error.InvalidMove, "{\"a\":{\"b\":1}}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/a/b\"}]");
    try expectPatchFailure(error.InvalidMove, "{\"a\":1}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/a/c\"}]");
    // A different member that merely starts with the same text is not a child.
    try expectPatched("{\"a\":1,\"ab\":1}", "{\"a\":1,\"ab\":0}", "[{\"op\":\"replace\",\"path\":\"/ab\",\"value\":1}]");
    try expectPatchFailure(error.InvalidTarget, "{\"a\":1}", "[{\"op\":\"move\",\"from\":\"\",\"path\":\"/b\"}]");
    try expectPatchFailure(error.MissingField, "{}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/b\"}]");
    try expectPatchFailure(error.InvalidPatch, "{}", "[{\"op\":\"move\",\"path\":\"/b\"}]");
}

test "patch: copy" {
    try expectPatched("{\"a\":1,\"b\":1}", "{\"a\":1}", "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/b\"}]");
    try expectPatched("[1,2,1]", "[1,2]", "[{\"op\":\"copy\",\"from\":\"/0\",\"path\":\"/-\"}]");

    // The copy is independent: editing it leaves the source alone.
    try expectPatched(
        "{\"a\":[1],\"b\":[9,1]}",
        "{\"a\":[1]}",
        "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/b\"},{\"op\":\"add\",\"path\":\"/b/0\",\"value\":9}]",
    );
    // Copying into the source's own child is allowed, unlike `move`.
    try expectPatched(
        "{\"a\":{\"b\":{\"b\":1}}}",
        "{\"a\":{\"b\":1}}",
        "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/a/b\"}]",
    );

    try expectPatchFailure(error.MissingField, "{}", "[{\"op\":\"copy\",\"from\":\"/x\",\"path\":\"/y\"}]");
    try expectPatchFailure(error.InvalidPatch, "{}", "[{\"op\":\"copy\",\"path\":\"/y\"}]");
}

test "patch: test" {
    try expectPatched("{\"a\":1}", "{\"a\":1}", "[{\"op\":\"test\",\"path\":\"/a\",\"value\":1}]");
    try expectPatched("{\"a/b\":1}", "{\"a/b\":1}", "[{\"op\":\"test\",\"path\":\"/a~1b\",\"value\":1}]");

    // Numbers compare by value, whatever their representation.
    try expectPatched("1", "1", "[{\"op\":\"test\",\"path\":\"\",\"value\":1.0}]");
    try expectPatched("1.0", "1.0", "[{\"op\":\"test\",\"path\":\"\",\"value\":1}]");
    try expectPatched("-0.0", "-0.0", "[{\"op\":\"test\",\"path\":\"\",\"value\":0}]");
    // Big integers stay exact.
    try expectPatched(
        "9007199254740993",
        "9007199254740993",
        "[{\"op\":\"test\",\"path\":\"\",\"value\":9007199254740993}]",
    );

    // Object members are unordered, arrays are ordered.
    try expectPatched(
        "{\"a\":1,\"b\":2}",
        "{\"a\":1,\"b\":2}",
        "[{\"op\":\"test\",\"path\":\"\",\"value\":{\"b\":2,\"a\":1}}]",
    );

    try expectPatchFailure(error.TestFailed, "[1,2]", "[{\"op\":\"test\",\"path\":\"\",\"value\":[2,1]}]");
    try expectPatchFailure(error.TestFailed, "{\"a\":1}", "[{\"op\":\"test\",\"path\":\"/a\",\"value\":2}]");
    try expectPatchFailure(error.TestFailed, "1", "[{\"op\":\"test\",\"path\":\"\",\"value\":true}]");
    try expectPatchFailure(error.TestFailed, "1", "[{\"op\":\"test\",\"path\":\"\",\"value\":1.5}]");
    try expectPatchFailure(error.TestFailed, "{\"a\":1}", "[{\"op\":\"test\",\"path\":\"\",\"value\":{\"a\":1,\"b\":2}}]");
    try expectPatchFailure(error.TestFailed, "9007199254740993", "[{\"op\":\"test\",\"path\":\"\",\"value\":9007199254740992}]");
    try expectPatchFailure(error.MissingField, "{}", "[{\"op\":\"test\",\"path\":\"/a\",\"value\":1}]");
}

test "patch: test on deep values" {
    const depth = 20_000;
    const nested = try testing.allocator.alloc(u8, depth * 2);
    defer testing.allocator.free(nested);
    @memset(nested[0..depth], '[');
    @memset(nested[depth..], ']');

    const text = try std.fmt.allocPrint(
        testing.allocator,
        "[{{\"op\":\"test\",\"path\":\"\",\"value\":{s}}}]",
        .{nested},
    );
    defer testing.allocator.free(text);

    var mutable = try mutableFrom(nested);
    defer mutable.deinit();
    try mutable.applyPatch(text, .{});
}

test "patch: malformed patches" {
    // Not a JSON array, or an element that is not an operation object.
    try expectPatchFailure(error.InvalidPatch, "{}", "{\"op\":\"remove\",\"path\":\"/a\"}");
    try expectPatchFailure(error.InvalidPatch, "{}", "[1]");
    try expectPatchFailure(error.InvalidPatch, "{}", "[\"add\"]");

    // A missing or unusable `op` member.
    try expectPatchFailure(error.InvalidPatch, "{}", "[{\"path\":\"/a\"}]");
    try expectPatchFailure(error.InvalidPatch, "{}", "[{\"op\":1,\"path\":\"/a\"}]");
    try expectPatchFailure(error.InvalidPatch, "{}", "[{\"op\":\"rewind\",\"path\":\"/a\"}]");

    // A missing or unusable `path`, and a missing `value`.
    try expectPatchFailure(error.InvalidPatch, "{}", "[{\"op\":\"remove\"}]");
    try expectPatchFailure(error.InvalidPatch, "{}", "[{\"op\":\"remove\",\"path\":1}]");
    try expectPatchFailure(error.InvalidPatch, "{}", "[{\"op\":\"add\",\"path\":\"/a\"}]");

    // Invalid JSON is reported as a parse error.
    try expectPatchFailure(error.InvalidJson, "{}", "[");
}

test "patch: operations apply in order and atomically" {
    try expectPatched(
        "{\"a\":2,\"b\":3}",
        "{\"a\":1}",
        "[{\"op\":\"add\",\"path\":\"/b\",\"value\":2},{\"op\":\"replace\",\"path\":\"/a\",\"value\":2},{\"op\":\"replace\",\"path\":\"/b\",\"value\":3}]",
    );

    // The first operation runs, the second fails: nothing is kept.
    try expectPatchFailure(
        error.MissingField,
        "{\"a\":1}",
        "[{\"op\":\"add\",\"path\":\"/b\",\"value\":2},{\"op\":\"remove\",\"path\":\"/missing\"}]",
    );
}

test "patch: the free function matches the method" {
    var document = try dom.parse(testing.allocator, "{\"a\":1}", .{});
    defer document.deinit();
    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();

    try patch.apply(&mutable, "[{\"op\":\"add\",\"path\":\"/b\",\"value\":2}]", .{});
    try expectSerialized(&mutable, "{\"a\":1,\"b\":2}");
}

test "patch: applyOps edits in place" {
    var document = try dom.parse(testing.allocator, "{\"a\":1}", .{});
    defer document.deinit();
    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();

    var ops = try dom.parse(testing.allocator, "[{\"op\":\"add\",\"path\":\"/b\",\"value\":2}]", .{});
    defer ops.deinit();
    var ops_mut = try ops.toMut(testing.allocator);
    defer ops_mut.deinit();

    try patch.applyOps(&mutable, ops_mut.root());
    try expectSerialized(&mutable, "{\"a\":1,\"b\":2}");
}

fn mutableFrom(input: []const u8) !dom.DocumentMut {
    var document = try dom.parse(testing.allocator, input, .{});
    defer document.deinit();
    return document.toMut(testing.allocator);
}

fn expectSerialized(document: *dom.DocumentMut, expected: []const u8) !void {
    const output = try document.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(expected, output);
}

fn expectPatched(expected: []const u8, input: []const u8, text: []const u8) !void {
    var mutable = try mutableFrom(input);
    defer mutable.deinit();
    try mutable.applyPatch(text, .{});
    try expectSerialized(&mutable, expected);
}

/// A failed patch must leave the document exactly as it was.
fn expectPatchFailure(expected: anyerror, input: []const u8, text: []const u8) !void {
    var mutable = try mutableFrom(input);
    defer mutable.deinit();

    const before = try mutable.toSlice(testing.allocator, .{});
    defer testing.allocator.free(before);

    try testing.expectError(expected, mutable.applyPatch(text, .{}));

    const after = try mutable.toSlice(testing.allocator, .{});
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}
