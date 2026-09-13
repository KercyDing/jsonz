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
