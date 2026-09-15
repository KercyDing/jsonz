//! Integration tests for `jsonz.dom`: reading a document and writing it back,
//! and its verdict against `jsonz.diagnostic` on a corpus of valid and
//! malformed input.

const std = @import("std");
const jsonz = @import("jsonz");

const dom = jsonz.dom;
const diag = jsonz.diagnostic;

const testing = std.testing;

test "value access" {
    var document = try dom.parse(
        testing.allocator,
        "{\"enabled\":true,\"count\":42,\"items\":[null,\"jsonz\",-7,1.5]}",
        .{},
    );
    defer document.deinit();

    try testing.expect(document.isObject());
    try testing.expect(try (try document.field("enabled")).toBool());
    try testing.expectEqual(@as(u64, 42), try (try document.field("count")).toNumber(.u64));
    try testing.expect(document.get("missing") == null);

    const items = try document.field("items");
    try testing.expect((try items.at(0)).isNull());
    try testing.expectEqualStrings("jsonz", try (try items.at(1)).toString());
    try testing.expectEqual(@as(i64, -7), try (try items.at(2)).toNumber(.i64));
    try testing.expectEqual(@as(f64, 1.5), try (try items.at(3)).toNumber(.f64));
    try testing.expect(items.getAt(4) == null);
}

test "container iteration" {
    var document = try dom.parse(testing.allocator, "{\"a\":1,\"b\":2}", .{});
    defer document.deinit();

    var iterator = try document.objectIterator();
    var count: usize = 0;
    while (iterator.next()) |entry| {
        try testing.expect(entry.value.isNumber(.u64));
        try testing.expect(entry.key.len == 1);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);

    var elements = document.get("a").?.kind();
    try testing.expectEqual(dom.Kind.number, elements);
    elements = document.root().kind();
    try testing.expectEqual(dom.Kind.object, elements);
}

test "access past a container child" {
    // A container occupies its whole subtree in the pool, so accessors and
    // iterators must step over it instead of by a fixed slot count. Every
    // container here is followed by a later sibling, which is what a fixed
    // stride gets wrong.
    var document = try dom.parse(
        testing.allocator,
        "{\"a\":[1,2],\"b\":{\"c\":[3,4]},\"d\":5,\"e\":[],\"f\":[[6],[7,8]]}",
        .{},
    );
    defer document.deinit();

    try testing.expectEqual(@as(u64, 5), try (try document.field("d")).toNumber(.u64));
    const b_values = try (try document.field("b")).field("c");
    try testing.expectEqual(@as(u64, 3), try (try b_values.at(0)).toNumber(.u64));
    try testing.expectEqual(@as(u64, 4), try (try b_values.at(1)).toNumber(.u64));
    const empty = try document.field("e");
    try testing.expectEqual(@as(usize, 0), try empty.len());
    const f_array = try document.field("f");
    const nested = try f_array.at(1);
    try testing.expectEqual(@as(u64, 7), try (try nested.at(0)).toNumber(.u64));
    try testing.expectEqual(@as(u64, 8), try (try nested.at(1)).toNumber(.u64));
    try testing.expect(document.get("missing") == null);

    // "c" belongs to "b", so the top level has five fields.
    const keys = [_][]const u8{ "a", "b", "d", "e", "f" };
    var fields = try document.objectIterator();
    var field_index: usize = 0;
    while (fields.next()) |entry| : (field_index += 1) {
        try testing.expectEqualStrings(keys[field_index], entry.key);
    }
    try testing.expectEqual(keys.len, field_index);

    var list = try dom.parse(testing.allocator, "[[1],[2,[3]],4,[],5]", .{});
    defer list.deinit();

    const array = list;
    try testing.expectEqual(@as(usize, 5), try array.len());
    const first_nested = try array.at(0);
    try testing.expectEqual(@as(u64, 1), try (try first_nested.at(0)).toNumber(.u64));
    const nested_array = try array.at(1);
    const deeply_nested = try nested_array.at(1);
    try testing.expectEqual(@as(u64, 3), try (try deeply_nested.at(0)).toNumber(.u64));
    try testing.expectEqual(@as(u64, 4), try (try array.at(2)).toNumber(.u64));
    try testing.expectEqual(@as(usize, 0), try (try array.at(3)).len());
    try testing.expectEqual(@as(u64, 5), try (try array.at(4)).toNumber(.u64));
    try testing.expect(array.getAt(5) == null);

    var elements = try array.arrayIterator();
    var element_index: usize = 0;
    while (elements.next()) |element| : (element_index += 1) {
        if (element_index == 2) try testing.expect(element.isNumber(.u64));
    }
    try testing.expectEqual(@as(usize, 5), element_index);
}

test "document serialization" {
    var document = try dom.parse(testing.allocator, "{\"name\":\"jsonz\",\"values\":[1,2]}", .{});
    defer document.deinit();

    const output = try document.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("{\"name\":\"jsonz\",\"values\":[1,2]}", output);

    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try (try document.field("name")).toWriter(&writer.writer, .{});
    try testing.expectEqualStrings("\"jsonz\"", writer.written());
}

test "escaped strings round trip" {
    var document = try dom.parse(testing.allocator, "{\"text\":\"line\\n\\u4e16\\u754c\",\"face\":\"\\ud83d\\ude00\"}", .{});
    defer document.deinit();

    try testing.expectEqualStrings("line\n\u{4e16}\u{754c}", try (try document.field("text")).toString());
    try testing.expectEqualStrings("\u{1f600}", try (try document.field("face")).toString());

    const output = try document.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "{\"text\":\"line\\n\u{4e16}\u{754c}\",\"face\":\"\u{1f600}\"}",
        output,
    );
}

test "deeply nested documents" {
    const depth = 20_000;
    const input = try testing.allocator.alloc(u8, depth * 2);
    defer testing.allocator.free(input);
    @memset(input[0..depth], '[');
    @memset(input[depth..], ']');

    var document = try dom.parse(testing.allocator, input, .{});
    defer document.deinit();

    // Neither the reader nor the writer may recurse.
    const output = try document.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);
}

test "rfc 6901 section 5" {
    var doc = try jsonz.dom.parse(
        testing.allocator,
        "{\"foo\":[\"bar\",\"baz\"],\"\":0,\"a/b\":1,\"c%d\":2,\"e^f\":3,\"g|h\":4,\"i\\\\j\":5,\"k\\\"l\":6,\" \":7,\"m~n\":8,\"~1\":9}",
        .{},
    );
    defer doc.deinit();

    try testing.expect((try doc.ptrGet("")).isObject());
    try testing.expectEqualStrings("bar", try (try doc.ptrGet("/foo/0")).toString());
    try testing.expectEqual(@as(u8, 0), try (try doc.ptrGet("/")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 1), try (try doc.ptrGet("/a~1b")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 2), try (try doc.ptrGet("/c%d")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 3), try (try doc.ptrGet("/e^f")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 4), try (try doc.ptrGet("/g|h")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 5), try (try doc.ptrGet("/i\\j")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 6), try (try doc.ptrGet("/k\"l")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 7), try (try doc.ptrGet("/ ")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 8), try (try doc.ptrGet("/m~0n")).toNumber(.u8));

    // `~01` is `~0` followed by `1`, so it selects the member named "~1".
    try testing.expectEqual(@as(u8, 9), try (try doc.ptrGet("/~01")).toNumber(.u8));
}

test "json pointer arrays and syntax" {
    var doc = try jsonz.dom.parse(testing.allocator, "{\"a\":[10,20],\"01\":\"leading\"}", .{});
    defer doc.deinit();

    try testing.expectEqual(@as(u8, 20), try (try doc.ptrGet("/a/1")).toNumber(.u8));
    // A leading zero is not an array index, but it is a valid object member.
    try testing.expectEqualStrings("leading", try (try doc.ptrGet("/01")).toString());
    try testing.expectError(error.InvalidArrayIndex, doc.ptrGet("/a/01"));
    try testing.expectError(error.InvalidArrayIndex, doc.ptrGet("/a/00"));
    try testing.expectError(error.InvalidArrayIndex, doc.ptrGet("/a/+1"));
    try testing.expectError(error.InvalidArrayIndex, doc.ptrGet("/a/-1"));
    try testing.expectError(error.InvalidArrayIndex, doc.ptrGet("/a/1.0"));
    try testing.expectError(error.InvalidArrayIndex, doc.ptrGet("/a/"));
    try testing.expectError(error.InvalidArrayIndex, doc.ptrGet("/a/99999999999999999999999999"));
    try testing.expectError(error.OutOfBounds, doc.ptrGet("/a/2"));
    try testing.expectError(error.OutOfBounds, doc.ptrGet("/a/-"));
    try testing.expectError(error.MissingField, doc.ptrGet("/nope"));
    try testing.expectError(error.UnexpectedType, doc.ptrGet("/a/0/deeper"));

    // Malformed pointer text is only accepted from the runtime entry point.
    try testing.expectError(error.InvalidPointer, doc.ptrGetDyn("a"));
    try testing.expectError(error.InvalidPointer, doc.ptrGetDyn("/~"));
    try testing.expectError(error.InvalidPointer, doc.ptrGetDyn("/~2"));
    try testing.expectError(error.InvalidPointer, doc.ptrGetDyn("/a\xff"));
}

test "json pointer unicode is exact" {
    var doc = try jsonz.dom.parse(
        testing.allocator,
        "{\"\\u00e9\":1,\"e\\u0301\":2,\"\\u0000\":3}",
        .{},
    );
    defer doc.deinit();

    // Precomposed and decomposed forms are different members, not normalized.
    try testing.expectEqual(@as(u8, 1), try (try doc.ptrGet("/\u{e9}")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 2), try (try doc.ptrGet("/e\u{301}")).toNumber(.u8));

    // NUL is a valid code point in a reference token.
    try testing.expectEqual(@as(u8, 3), try (try doc.ptrGet("/\x00")).toNumber(.u8));
}

test "json pointer duplicate member" {
    var doc = try jsonz.dom.parse(testing.allocator, "{\"foo\":1,\"foo\":2}", .{});
    defer doc.deinit();

    // Duplicate member names resolve to the first match.
    try testing.expectEqual(@as(u8, 1), try (try doc.ptrGet("/foo")).toNumber(.u8));
    try testing.expectError(error.MissingField, doc.ptrGet("/bar"));
}

test "json pointer format" {
    var doc = try jsonz.dom.parse(
        testing.allocator,
        "{\"statuses\":[{\"user\":{\"id\":11}}],\"objects\":{\"a\":{\"b\":5}}}",
        .{},
    );
    defer doc.deinit();

    const index: usize = 0;
    const id_view = try doc.ptrGetFmt("/statuses/{}/user/id", .{index});
    try testing.expectEqual(@as(u8, 11), try id_view.toNumber(.u8));

    try testing.expectError(error.OutOfBounds, doc.ptrGetFmt("/statuses/{}/user/id", .{@as(usize, 7)}));

    // `{}` is std.fmt text interpolation, so a `/` in the argument separates
    // tokens instead of naming one member.
    const key = "a/b";
    const nested = try doc.ptrGetFmt("/objects/{s}", .{key});
    try testing.expectEqual(@as(u8, 5), try nested.toNumber(.u8));
}

test "mutable conversion" {
    var document = try dom.parse(
        testing.allocator,
        "{\"a\":[1,2,{\"b\":\"x\"}],\"c\":true,\"d\":null,\"e\":-3.5}",
        .{},
    );
    defer document.deinit();

    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();

    const root = mutable.root();
    try testing.expect(root.isObject());
    try testing.expectEqual(@as(usize, 4), try root.len());

    const a = try root.field("a");
    try testing.expect(a.isArray());
    try testing.expectEqual(@as(usize, 3), try a.len());
    try testing.expectEqual(@as(u64, 1), try (try a.at(0)).toNumber(.u64));
    try testing.expectEqual(@as(u64, 2), try (try a.at(1)).toNumber(.u64));
    try testing.expectEqualStrings("x", try (try (try a.at(2)).field("b")).toString());

    try testing.expect(try (try root.field("c")).toBool());
    try testing.expect((try root.field("d")).isNull());
    try testing.expectEqual(@as(f64, -3.5), try (try root.field("e")).toNumber(.f64));
    try testing.expect(root.get("missing") == null);

    var fields = try root.objectIterator();
    var count: usize = 0;
    while (fields.next()) |entry| : (count += 1) try testing.expect(entry.key.len == 1);
    try testing.expectEqual(@as(usize, 4), count);
}

test "mutable conversion of deep documents" {
    const depth = 20_000;
    const input = try testing.allocator.alloc(u8, depth * 2);
    defer testing.allocator.free(input);
    @memset(input[0..depth], '[');
    @memset(input[depth..], ']');

    var document = try dom.parse(testing.allocator, input, .{});
    defer document.deinit();

    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();

    // The innermost array is empty, one level below the root.
    var node = mutable.root();
    var remaining: usize = depth - 1;
    while (remaining != 0) : (remaining -= 1) node = try node.at(0);
    try testing.expect(node.isArray());
    try testing.expectEqual(@as(usize, 0), try node.len());
}

test "mutable parse matches the compact parser" {
    for (valid_inputs) |input| try expectParseMutMatches(input, .{});
    for (permissive_inputs) |entry| {
        if (!try domAccepts(entry.input, entry.options)) continue;
        try expectParseMutMatches(entry.input, entry.options);
    }
}

/// `dom.parseMut` builds the same tree as `dom.parse` plus `toMut`.
fn expectParseMutMatches(input: []const u8, options: dom.ParseOptions) !void {
    var document = try dom.parse(testing.allocator, input, options);
    defer document.deinit();
    var converted = try document.toMut(testing.allocator);
    defer converted.deinit();
    var parsed = try dom.parseMut(testing.allocator, input, options);
    defer parsed.deinit();

    for ([_]bool{ false, true }) |pretty| {
        const write_options: dom.WriteOptions = .{ .pretty = pretty };
        const expected = try converted.toSlice(testing.allocator, write_options);
        defer testing.allocator.free(expected);
        const actual = try parsed.toSlice(testing.allocator, write_options);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }
}

test "mutable parse of deep documents" {
    const depth = 20_000;
    const input = try testing.allocator.alloc(u8, depth * 2);
    defer testing.allocator.free(input);
    @memset(input[0..depth], '[');
    @memset(input[depth..], ']');

    var document = try dom.parseMut(testing.allocator, input, .{});
    defer document.deinit();

    var node = document.root();
    var remaining: usize = depth - 1;
    while (remaining != 0) : (remaining -= 1) node = try node.at(0);
    try testing.expect(node.isArray());
    try testing.expectEqual(@as(usize, 0), try node.len());

    const output = try document.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);
}

test "mutable parse decodes strings and marks members" {
    const input = "{\"k\":\"a\\u00e9\\n\\\"\\\\\",\"a\":1,\"b\":[2]}";
    var document = try dom.parseMut(testing.allocator, input, .{});
    defer document.deinit();

    // Escapes are decoded in place before the string is stored.
    const value = try (try document.root().field("k")).toString();
    try testing.expectEqualStrings("a\u{e9}\n\"\\", value);

    // Both parsers agree on the whole document.
    var compact = try dom.parse(testing.allocator, input, .{});
    defer compact.deinit();
    const compact_text = try compact.toSlice(testing.allocator, .{});
    defer testing.allocator.free(compact_text);
    try expectSerialized(&document, compact_text);

    // The parser marks object values, so a member is removed with its key.
    (try document.root().field("a")).remove();
    try testing.expect(document.root().get("a") == null);

    var expected_document = try dom.parse(
        testing.allocator,
        "{\"k\":\"a\\u00e9\\n\\\"\\\\\",\"b\":[2]}",
        .{},
    );
    defer expected_document.deinit();
    const expected = try expected_document.toSlice(testing.allocator, .{});
    defer testing.allocator.free(expected);
    try expectSerialized(&document, expected);
}

test "mutable parse rejects invalid JSON" {
    try testing.expectError(error.InvalidJson, dom.parseMut(testing.allocator, "", .{}));
    try testing.expectError(error.InvalidJson, dom.parseMut(testing.allocator, "{\"a\":}", .{}));
    try testing.expectError(error.InvalidJson, dom.parseMut(testing.allocator, "[1,]", .{}));
    try testing.expectError(error.InvalidJson, dom.parseMut(testing.allocator, "1 2", .{}));

    var document = try dom.parseMut(testing.allocator, "[1,]", .{ .allow_trailing_commas = true });
    defer document.deinit();
    try expectSerialized(&document, "[1]");
}

test "mutable serialization matches compact output" {
    for (valid_inputs) |input| {
        try expectMutMatches(input, .{});
    }
    for (permissive_inputs) |entry| {
        // Some entries combine options that still reject the input on purpose.
        if (!try domAccepts(entry.input, entry.options)) continue;
        try expectMutMatches(entry.input, entry.options);
    }
}

/// `Document -> toMut -> toSlice` must be byte-identical to the compact output.
fn expectMutMatches(input: []const u8, options: dom.ParseOptions) !void {
    var document = try dom.parse(testing.allocator, input, options);
    defer document.deinit();

    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();

    for ([_]bool{ false, true }) |pretty| {
        const write_options: dom.WriteOptions = .{ .pretty = pretty };
        const expected = try document.toSlice(testing.allocator, write_options);
        defer testing.allocator.free(expected);
        const actual = try mutable.toSlice(testing.allocator, write_options);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }
}

test "mutable json pointer" {
    var document = try dom.parse(
        testing.allocator,
        "{\"foo\":[\"bar\",\"baz\"],\"\":0,\"a/b\":1,\"m~n\":8,\"01\":\"leading\",\"nested\":{\"a\":{\"b\":5}}}",
        .{},
    );
    defer document.deinit();

    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();
    const root = mutable.root();

    try testing.expect((try root.ptrGet("")).isObject());
    try testing.expectEqualStrings("bar", try (try root.ptrGet("/foo/0")).toString());
    try testing.expectEqual(@as(u8, 0), try (try root.ptrGet("/")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 1), try (try root.ptrGet("/a~1b")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 8), try (try root.ptrGet("/m~0n")).toNumber(.u8));
    // A leading zero is not an array index, but it is a valid object member.
    try testing.expectEqualStrings("leading", try (try root.ptrGet("/01")).toString());

    try testing.expectError(error.InvalidArrayIndex, root.ptrGet("/foo/01"));
    try testing.expectError(error.OutOfBounds, root.ptrGet("/foo/2"));
    try testing.expectError(error.OutOfBounds, root.ptrGet("/foo/-"));
    try testing.expectError(error.MissingField, root.ptrGet("/nope"));
    try testing.expectError(error.UnexpectedType, root.ptrGet("/foo/0/deeper"));
    try testing.expectError(error.InvalidPointer, root.ptrGetDyn("foo"));
    try testing.expectError(error.InvalidPointer, root.ptrGetDyn("/~2"));

    const nested = try root.ptrGetFmt("/nested/{s}/{s}", .{ "a", "b" });
    try testing.expectEqual(@as(u8, 5), try nested.toNumber(.u8));
    try testing.expectError(error.OutOfBounds, root.ptrGetFmt("/foo/{}", .{@as(usize, 9)}));
}

test "mutable json pointer keys are exact" {
    var document = try dom.parse(
        testing.allocator,
        "{\"\\u00e9\":1,\"e\\u0301\":2,\"foo\":3,\"foo\":4}",
        .{},
    );
    defer document.deinit();

    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();
    const root = mutable.root();

    // Precomposed and decomposed forms are different members, not normalized.
    try testing.expectEqual(@as(u8, 1), try (try root.ptrGet("/\u{e9}")).toNumber(.u8));
    try testing.expectEqual(@as(u8, 2), try (try root.ptrGet("/e\u{301}")).toNumber(.u8));
    // Duplicate member names resolve to the first match.
    try testing.expectEqual(@as(u8, 3), try (try root.ptrGet("/foo")).toNumber(.u8));
}

test "mutable edits" {
    var document = try dom.parse(testing.allocator, "{\"a\":1,\"b\":[10,20]}", .{});
    defer document.deinit();
    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();
    const root = mutable.root();

    // In-place scalar replacement keeps the node's position.
    const a = try root.field("a");
    try a.replaceString("hi");
    try a.replaceNumber(@as(u8, 7));
    a.replaceBool(true);
    try a.replaceNumber(@as(f64, -1.5));
    a.replaceNull();

    // Numbers are stored as i64, u64 or f64, so anything else is reported.
    try a.replaceNumber(std.math.maxInt(u64));
    try a.replaceNumber(std.math.minInt(i64));
    try testing.expectError(error.OutOfRange, a.replaceNumber(@as(u128, 1) << 100));
    try testing.expectError(error.OutOfRange, a.replaceNumber(@as(i128, -1) << 100));
    // A NaN or an infinity is not JSON, so it must never reach the writer.
    try testing.expectError(error.OutOfRange, a.replaceNumber(std.math.inf(f64)));
    try testing.expectError(error.OutOfRange, a.replaceNumber(std.math.nan(f64)));
    a.replaceNull();

    // Attach scalar values with the shorthands, and detached nodes as they are.
    try root.addString("c", "x");
    try root.addNumber("d", @as(i32, 40));
    try root.addBool("e", true);
    try root.addNull("f");
    try root.addField("g", try mutable.newString("y"));

    const b = try root.field("b");
    try b.insertAt(0, try mutable.newObject());
    try b.insertAt(1, try mutable.newNull());
    try (try b.at(0)).addField("k", try mutable.newBool(true));
    try b.appendString("30");
    try b.appendNumber(@as(i32, 40));
    try b.appendBool(false);
    try b.appendNull();

    try expectSerialized(
        &mutable,
        "{\"a\":null,\"b\":[{\"k\":true},null,10,20,\"30\",40,false,null],\"c\":\"x\",\"d\":40,\"e\":true,\"f\":null,\"g\":\"y\"}",
    );
    try expectSerializedPretty(&mutable);
}

test "mutable removals" {
    var document = try dom.parse(testing.allocator, "{\"a\":1,\"b\":2,\"c\":[1,2,3,4]}", .{});
    defer document.deinit();
    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();
    const root = mutable.root();

    // An object member is removed together with its key.
    (try root.field("a")).remove();
    try testing.expect(root.get("a") == null);

    const c = try root.field("c");
    try testing.expectEqual(@as(usize, 4), try c.len());
    (try c.at(1)).remove();
    try testing.expectEqual(@as(usize, 3), try c.len());
    try expectSerialized(&mutable, "{\"b\":2,\"c\":[1,3,4]}");

    // Removing the last element keeps the tail link correct.
    (try c.at(2)).remove();
    try expectSerialized(&mutable, "{\"b\":2,\"c\":[1,3]}");
    (try c.at(0)).remove();
    (try c.at(0)).remove();
    try expectSerialized(&mutable, "{\"b\":2,\"c\":[]}");

    // The root itself cannot be removed.
    root.remove();
    try expectSerialized(&mutable, "{\"b\":2,\"c\":[]}");
}

test "mutable replacement" {
    var document = try dom.parse(testing.allocator, "{\"a\":1,\"b\":[1,2,3]}", .{});
    defer document.deinit();
    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();
    const root = mutable.root();

    // `replace` splices a detached node into this node's slot.
    try (try root.field("a")).replace(try mutable.newString("z"));
    try expectSerialized(&mutable, "{\"a\":\"z\",\"b\":[1,2,3]}");

    const b = try root.field("b");
    try (try b.at(1)).replace(try mutable.newArray());
    try expectSerialized(&mutable, "{\"a\":\"z\",\"b\":[1,[],3]}");
}

test "mutable attach errors" {
    var document = try dom.parse(testing.allocator, "{\"arr\":[[1],2]}", .{});
    defer document.deinit();
    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();
    const root = mutable.root();

    // A node that is still linked into the tree cannot be attached again.
    const arr = try root.field("arr");
    try testing.expectError(error.AlreadyAttached, arr.append(try arr.at(0)));
    try testing.expectError(error.AlreadyAttached, root.addField("x", root));

    // A node of another document needs `copyFrom`.
    var other = try dom.parse(testing.allocator, "{\"k\":[7]}", .{});
    defer other.deinit();
    var other_mut = try other.toMut(testing.allocator);
    defer other_mut.deinit();
    try testing.expectError(error.DifferentStorage, arr.append(other_mut.root()));

    try testing.expectError(error.UnexpectedType, (try arr.at(0)).addField("k", try mutable.newNull()));
    try testing.expectError(error.UnexpectedType, root.appendString("s"));
    try testing.expectError(error.OutOfBounds, arr.insertAt(9, try mutable.newNull()));

    // The failed operations must not have changed the document.
    try expectSerialized(&mutable, "{\"arr\":[[1],2]}");
}

test "mutable detached nodes" {
    var document = try dom.parse(testing.allocator, "{\"a\":[1,2],\"b\":{}}", .{});
    defer document.deinit();
    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();
    const root = mutable.root();

    // Removing detaches the subtree: its storage stays until `deinit`, and the
    // handle keeps working.
    const list = try root.field("a");
    list.remove();
    try testing.expect(root.get("a") == null);
    try list.appendNumber(@as(u8, 3));
    try testing.expectEqual(@as(usize, 3), try list.len());

    // A detached subtree can be attached somewhere else, and edits through the
    // old handle reach it there.
    try (try root.field("b")).addField("moved", list);
    try expectSerialized(&mutable, "{\"b\":{\"moved\":[1,2,3]}}");
    try list.appendString("x");
    try expectSerialized(&mutable, "{\"b\":{\"moved\":[1,2,3,\"x\"]}}");
}

test "mutable attach cycles" {
    var document = try dom.DocumentMut.init(testing.allocator);
    defer document.deinit();

    // Build a detached tree: outer holds an array and an object.
    const outer = try document.newObject();
    const list = try document.newArray();
    const branch = try document.newObject();
    try outer.addField("list", list);
    try outer.addField("branch", branch);

    // Attaching the ancestor inside its own descendants would cycle.
    try testing.expectError(error.WouldCycle, list.append(outer));
    try testing.expectError(error.WouldCycle, list.insertAt(0, outer));
    try testing.expectError(error.WouldCycle, branch.addField("self", outer));
    try testing.expectError(error.WouldCycle, branch.replace(outer));

    // Attaching it anywhere else is fine.
    try document.root().replace(outer);
    try expectSerialized(&document, "{\"list\":[],\"branch\":{}}");
}

test "mutable edge cases" {
    var document = try dom.parse(
        testing.allocator,
        "{\"a\":[1,2],\"b\":1}",
        .{},
    );
    defer document.deinit();
    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();
    const root = mutable.root();

    // `insertAt` at the length appends; one past it is out of bounds.
    const a = try root.field("a");
    try a.insertAt(2, try mutable.newNumber(@as(u8, 3)));
    try testing.expectError(error.OutOfBounds, a.insertAt(4, try mutable.newNumber(@as(u8, 9))));

    // Replacing a container drops its former children.
    try (try root.field("a")).replaceString("x");
    try expectSerialized(&mutable, "{\"a\":\"x\",\"b\":1}");

    // Removing a detached node does nothing.
    const detached = try mutable.newArray();
    detached.remove();
    try testing.expect(detached.isArray());

    // Removing the root does nothing either.
    root.remove();
    try testing.expect(root.isObject());

    // A scalar container access reports the kind, not a missing member.
    try testing.expectError(error.UnexpectedType, (try root.field("b")).field("x"));
    try testing.expectError(error.UnexpectedType, (try root.field("b")).at(0));
}

test "mutable copyFrom" {
    var document = try dom.parse(testing.allocator, "{\"a\":1,\"b\":[true,{\"n\":\"x\\n\"}]}", .{});
    defer document.deinit();
    var source = try document.toMut(testing.allocator);
    defer source.deinit();

    var other = try dom.parse(testing.allocator, "[0,0,0]", .{});
    defer other.deinit();
    var target = try other.toMut(testing.allocator);
    defer target.deinit();
    const root = target.root();

    // Deep copy across documents.
    try root.copyFrom(source.root());
    try expectSerialized(&target, "{\"a\":1,\"b\":[true,{\"n\":\"x\\n\"}]}");

    // The copy is independent: editing it must not touch the source.
    const copied = try (try (try root.field("b")).at(1)).field("n");
    try copied.replaceString("changed");
    try expectSerialized(&target, "{\"a\":1,\"b\":[true,{\"n\":\"changed\"}]}");
    try expectSerialized(&source, "{\"a\":1,\"b\":[true,{\"n\":\"x\\n\"}]}");

    // And copyFrom must work within one document too.
    try (try root.field("a")).copyFrom(try (try root.field("b")).at(0));
    try expectSerialized(&target, "{\"a\":true,\"b\":[true,{\"n\":\"changed\"}]}");
}

test "mutable large array" {
    const count = 10_000;
    var document = try dom.parse(testing.allocator, "[]", .{});
    defer document.deinit();
    var mutable = try document.toMut(testing.allocator);
    defer mutable.deinit();
    const root = mutable.root();

    for (0..count) |i| {
        try root.append(try mutable.newNumber(@as(u64, i)));
    }
    try testing.expectEqual(@as(usize, count), try root.len());

    // Removing from the front is O(1) per node thanks to `prev`/`next`.
    while (try root.len() != 0) {
        (try root.at(0)).remove();
    }
    try expectSerialized(&mutable, "[]");
}

test "mutable deep copy" {
    const depth = 20_000;
    const input = try testing.allocator.alloc(u8, depth * 2);
    defer testing.allocator.free(input);
    @memset(input[0..depth], '[');
    @memset(input[depth..], ']');

    var document = try dom.parse(testing.allocator, input, .{});
    defer document.deinit();
    var source = try document.toMut(testing.allocator);
    defer source.deinit();

    var other = try dom.parse(testing.allocator, "null", .{});
    defer other.deinit();
    var target = try other.toMut(testing.allocator);
    defer target.deinit();

    try target.root().copyFrom(source.root());
    const output = try target.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);
}

test "mutable document lifecycle" {
    var document = try dom.DocumentMut.init(testing.allocator);
    defer document.deinit();
    try expectSerialized(&document, "null");

    // Build a fresh document and splice a new root in.
    const root = try document.newObject();
    try root.addString("k", "v");
    try document.root().replace(root);
    try expectSerialized(&document, "{\"k\":\"v\"}");

    // A clone is an independent deep copy.
    var copy = try dom.DocumentMut.clone(testing.allocator, &document);
    defer copy.deinit();
    try expectSerialized(&copy, "{\"k\":\"v\"}");
    try (try copy.root().field("k")).replaceString("other");
    try expectSerialized(&copy, "{\"k\":\"other\"}");
    try expectSerialized(&document, "{\"k\":\"v\"}");
}

fn expectSerialized(document: *dom.DocumentMut, expected: []const u8) !void {
    const output = try document.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(expected, output);
}

/// Pretty output must stay valid JSON that reads back as the minified form.
fn expectSerializedPretty(document: *dom.DocumentMut) !void {
    const minified = try document.toSlice(testing.allocator, .{});
    defer testing.allocator.free(minified);
    const pretty = try document.toSlice(testing.allocator, .{ .pretty = true });
    defer testing.allocator.free(pretty);

    var reparsed = try dom.parse(testing.allocator, pretty, .{});
    defer reparsed.deinit();
    const again = try reparsed.toSlice(testing.allocator, .{});
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(minified, again);
}

/// Inputs `dom.parse` rejects, with or without the permissive options.
const malformed_inputs = [_][]const u8{
    "",
    "   ",
    "\xef\xbb\xbf{}",
    "{",
    "}",
    "[",
    "]",
    "[1",
    "[1,",
    "[1,]",
    "[1 2]",
    "[1,,2]",
    "[,1]",
    "[}",
    "[1}",
    "{,}",
    "{\"a\"}",
    "{\"a\":}",
    "{\"a\":1,}",
    "{\"a\":1 \"b\":2}",
    "{\"a\" 1}",
    "{1:2}",
    "{'a':1}",
    "{a:1}",
    "{\"a\":1}}",
    "[1]]",
    "01",
    "-01",
    "1.",
    ".5",
    "1e",
    "1e+",
    "+1",
    "1e309",
    "-1e309",
    "NaN",
    "nan",
    "Infinity",
    "-Infinity",
    "0xFF",
    "0b1010",
    "TRUE",
    "tru",
    "fals",
    "nul",
    "nullx",
    "1 x",
    "{} []",
    "1,2",
    "\"abc",
    "\"a\\q\"",
    "\"a\nb\"",
    "\"a\x01b\"",
    "\"\\u12\"",
    "\"\\uZZZZ\"",
    "\"\\uD800\"",
    "\"\\uD800\\u0041\"",
    "\"\\uDC00\"",
    "\"\xc2",
    "\"\xc2\"",
    "\"\xc0\x80\"",
    "\"\xe0\x80\x80\"",
    "\"\xed\xa0\x80\"",
    "\"\xf4\x90\x80\x80\"",
    "\"\xf5\x80\x80\x80\"",
    "\"\xff\"",
    "\"\x80\"",
    "// comment\n1",
    "/* comment */ 1",
    "1 /* comment */",
    "1 // comment",
    "/* unterminated",
    "[\"a\":1]",
    "{\"a\":[1,2}",
    "[[[[",
    "{\"a\":01}",
    "{\"a\":.5}",
    "{\"a\":+1}",
    "{\"a\":1.}",
    "{\"a\":1e}",
    "{\"a\":NaN}",
    "{\"a\":'b'}",
};

/// Inputs `dom.parse` accepts with the default options.
const valid_inputs = [_][]const u8{
    "null",
    "true",
    "false",
    "0",
    "-0",
    "1",
    "-1",
    "1.5",
    "-1.5e-3",
    "1E+2",
    "18446744073709551615",
    "1e308",
    "1e-308",
    "\"\"",
    "\"jsonz\"",
    "\"\\u0041\\u00e9\\u4e2d\"",
    "\"\\uD83D\\uDE00\"",
    "\"\\n\\t\\\\\\/\\b\\f\\r\"",
    "\"\xe4\xb8\xad\xe6\x96\x87\"",
    "\"\xf0\x9f\x98\x80\"",
    "[]",
    "{}",
    "[1,2,3]",
    "{\"a\":1}",
    "{\"a\":{\"b\":[1,2,{}]}}",
    "[[[[[[[[[]]]]]]]]]",
    " \t\r\n{\n  \"a\": [true, false, null]\n}\n",
    "{\"\":\"\"}",
    "{\"a\":\"\\u0000\"}",
};

/// Inputs that only the permissive options accept.
const permissive_inputs = [_]struct { input: []const u8, options: dom.ParseOptions }{
    .{ .input = "[1,]", .options = .{ .allow_trailing_commas = true } },
    .{ .input = "{\"a\":1,}", .options = .{ .allow_trailing_commas = true } },
    .{ .input = "[[1,],{\"a\":1,},]", .options = .{ .allow_trailing_commas = true } },
    .{ .input = "// comment\n1", .options = .{ .allow_comments = true } },
    .{ .input = "/* comment */ 1", .options = .{ .allow_comments = true } },
    .{ .input = "{\"a\":/* c */1}", .options = .{ .allow_comments = true } },
    .{ .input = "[1,// c\n2]", .options = .{ .allow_comments = true } },
    .{ .input = "[1,/* c */2]", .options = .{ .allow_comments = true } },
    .{ .input = "[[1,/* c */2],3]", .options = .{ .allow_comments = true } },
    .{ .input = "{/* c */ \"a\": 1, // tail\n}", .options = .{ .allow_comments = true, .allow_trailing_commas = true } },
    .{ .input = "// comment\n1", .options = .{ .allow_trailing_commas = true } },
    .{ .input = "[1,]", .options = .{ .allow_comments = true } },
};

/// The option combinations every corpus entry is checked under.
const option_sets = [_]dom.ParseOptions{
    .{},
    .{ .allow_trailing_commas = true },
    .{ .allow_comments = true },
    .{ .allow_comments = true, .allow_trailing_commas = true },
};

fn domAccepts(input: []const u8, options: dom.ParseOptions) !bool {
    var document = dom.parse(testing.allocator, input, options) catch |failure| switch (failure) {
        error.InvalidJson => return false,
        error.OutOfMemory => return failure,
    };
    document.deinit();
    return true;
}

fn expectAgreement(input: []const u8, options: dom.ParseOptions) !void {
    const accepts = try domAccepts(input, options);
    const valid = diag.isValid(input, .{
        .allow_comments = options.allow_comments,
        .allow_trailing_commas = options.allow_trailing_commas,
    });
    if (accepts != valid) {
        std.debug.print("dom and diagnostic disagree on {s} (dom accepts: {}, check: {})\n", .{
            input,
            accepts,
            valid,
        });
        return error.TestUnexpectedResult;
    }
}

test "agreement: malformed" {
    for (malformed_inputs) |input| {
        for (option_sets) |options| try expectAgreement(input, options);
    }
}

test "agreement: valid" {
    for (valid_inputs) |input| {
        for (option_sets) |options| try expectAgreement(input, options);
    }
}

test "agreement: permissive" {
    for (permissive_inputs) |case| try expectAgreement(case.input, case.options);
}

test "agreement: deep nesting" {
    const depth = 20_000;
    const input = try testing.allocator.alloc(u8, depth * 2);
    defer testing.allocator.free(input);
    @memset(input[0..depth], '[');
    @memset(input[depth..], ']');
    try expectAgreement(input, .{});

    input[depth] = 'x';
    try expectAgreement(input[0 .. depth + 1], .{});
}

// Damages valid documents at random: the deterministic counterpart of the fuzz
// target in `tests/fuzzy_tests.zig`, and it runs on every platform.
test "agreement: random mutations" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    const alphabet = ",:{}[]\"\\09e-+ .x\n\t";

    var buffer: [256]u8 = undefined;
    for (0..5_000) |_| {
        const source = valid_inputs[random.uintLessThan(usize, valid_inputs.len)];
        @memcpy(buffer[0..source.len], source);
        var input: []u8 = buffer[0..source.len];

        const rounds = 1 + random.uintLessThan(usize, 4);
        for (0..rounds) |_| {
            if (input.len == 0) break;
            switch (random.uintLessThan(u8, 3)) {
                0 => input[random.uintLessThan(usize, input.len)] = alphabet[random.uintLessThan(usize, alphabet.len)],
                1 => input = input[0..random.uintLessThan(usize, input.len + 1)],
                else => {
                    if (input.len == buffer.len) continue;
                    const index = random.uintLessThan(usize, input.len + 1);
                    std.mem.copyBackwards(u8, buffer[index + 1 .. input.len + 1], buffer[index..input.len]);
                    buffer[index] = alphabet[random.uintLessThan(usize, alphabet.len)];
                    input = buffer[0 .. input.len + 1];
                },
            }
        }

        try expectAgreement(input, .{ .allow_comments = true, .allow_trailing_commas = true });
    }
}
