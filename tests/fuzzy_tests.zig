const std = @import("std");
const jsonz = @import("jsonz");

const Address = struct {
    city: []const u8,
    zip: ?[]const u8 = null,
};

const Role = enum { admin, user, guest };

const Action = union(enum) {
    login: void,
    update: struct { field: []const u8, value: []const u8 },
};

const FuzzTarget = struct {
    id: u64,
    name: []const u8,
    score: f64,
    active: bool,
    role: Role,
    address: Address,
    tags: []const []const u8 = &.{},
    counts: []const i32 = &.{},
    history: []const Action = &.{},
    pair: [2]f64 = .{ 0, 0 },
};

/// Seeds the fuzzer with documents that already sit near a branch: valid
/// values, values only the permissive options accept, and broken ones.
const deep_arrays = "[" ** 300 ++ "]" ** 300;
const deep_broken = "[" ** 300 ++ "x";
const long_string = "\"" ++ "a" ** 100 ++ "\\n" ++ "b" ** 100 ++ "\"";
const escape_run = "\"" ++ "\\n\\u0041\\t\\\\" ++ "a" ** 40 ++ "\\\"" ++ "b" ** 40 ++ "\"";

const corpus = [_][]const u8{
    "{}",
    "[]",
    "null",
    "true",
    "-0.0",
    "1e309",
    "-1e309",
    "01",
    "-01",
    "1.",
    ".5",
    "1e",
    "1e+",
    "+1",
    "0xFF",
    "NaN",
    "tru",
    "\"\"",
    "\"\\u0041\"",
    "\"\\uD83D\\uDE00\"",
    "\"\\uD800\"",
    "\"\\uD800\\u0041\"",
    "\"\\uDC00\"",
    "\"\\uZZZZ\"",
    "\"\\u12\"",
    "\"a\nb\"",
    "\"a\\q\"",
    "\"/\"",
    "\"\xc3\xa9\"",
    "\"\xff\"",
    "\"\xc0\x80\"",
    "\"\xed\xa0\x80\"",
    "\"\xe4\xb8\xad\"",
    "\"\xf0\x9f\x98\x80\"",
    "\"\xe4\xb8\xad\xe6\x96\x87\xf0\x9f\x98\x80\"",
    "\"\xc2\x80\"",
    "\"\xdf\xbf\"",
    "\"\xe0\xa0\x80\"",
    "\"\xef\xbf\xbf\"",
    "\"\xf0\x90\x80\x80\"",
    "\"\xf4\x8f\xbf\xbf\"",
    "\"\xc3\xa9",
    "\"\xe4\xb8\xad",
    "\"\xf0\x9f\x98\x80",
    "\"a\\n\xe4\xb8\xadb\"",
    "\"\\u00e9\\u4e2d\\u00e9\"",
    "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"",
    "\"\\u0000\\u007f\\u0080\\u07ff\\u0800\\uffff\"",
    "\"\\uD83D\\uDE00\\uD83D\\uDE39\"",
    "18446744073709551615",
    "-9223372036854775808",
    "1e-400",
    "{\"a\":[[[]]],\"b\":{\"c\":{}}}",
    long_string,
    escape_run,
    " \t\r\n{\n  \"a\" : [ true , false , null ]\n}\n",
    "[1,2,3]",
    "[1 2]",
    "[1,]",
    "[1,,2]",
    "[}",
    "{\"a\":1}",
    "{\"a\":01}",
    "{\"a\":1,}",
    "{\"a\" 1}",
    "{\"a\":1 \"b\":2}",
    "{1:2}",
    "{} []",
    "1 x",
    "// c\n1",
    "// c\r\n1",
    "/* c */ 1",
    "/* a * b */1",
    "/* a **/1",
    "/* c",
    "\xef\xbb\xbf{}",
    "{\"id\":7,\"name\":\"jsonz\",\"score\":1.5,\"active\":true,\"role\":\"admin\"," ++
        "\"address\":{\"city\":\"x\",\"zip\":null},\"tags\":[\"a\"],\"counts\":[1,-2]," ++
        "\"history\":[{\"login\":null},{\"update\":{\"field\":\"f\",\"value\":\"v\"}}]," ++
        "\"pair\":[0,1]}",
    "{\"id\":7,\"name\":\"jsonz\",\"score\":1.5,\"active\":true,\"role\":\"nope\"," ++
        "\"address\":{\"city\":\"x\"}}",
    deep_arrays,
    deep_broken,
};

const option_sets = [_]jsonz.dom.ParseOptions{
    .{},
    .{ .allow_trailing_commas = true },
    .{ .allow_comments = true },
    .{ .allow_comments = true, .allow_trailing_commas = true },
};

test "JSON parser fuzz" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &corpus });
}

/// Feeds raw fuzz bytes to the typed parser and holds it to the DOM's verdict:
/// whatever the typed parser accepts has to be valid JSON.
fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const length = smith.slice(&buffer);
    const input = buffer[0..length];

    inline for (types) |T| {
        if (typedAccepts(T, input)) try expectDomAccepts(input, .{});
        try expectTypedEntriesAgree(T, input);
    }

    _ = jsonz.typed.parseBorrowed(bool, std.testing.allocator, input, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(i32, std.testing.allocator, input, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(u64, std.testing.allocator, input, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(f32, std.testing.allocator, input, .{}) catch {};

    try expectNumbersMatchStd(input);
}

/// The typed types every target agrees on.
const types = .{ FuzzTarget, Address, Role, Action, []const i32, []const u8, u64, i64, f64 };

fn typedAccepts(comptime T: type, input: []const u8) bool {
    _ = jsonz.typed.parseBorrowed(T, std.testing.allocator, input, .{ .ignore_unknown_fields = true }) catch return false;
    return true;
}

fn expectDomAccepts(input: []const u8, options: jsonz.dom.ParseOptions) !void {
    var document = jsonz.dom.parse(std.testing.allocator, input, options) catch |failure| switch (failure) {
        error.InvalidJson => {
            std.debug.print("typed parser accepted invalid JSON: {s}\n", .{input});
            return error.TestUnexpectedResult;
        },
        error.OutOfMemory => return failure,
    };
    document.deinit();
}

/// `parse`, `parseBorrowed` and `parseInto` see the same grammar, so they must
/// accept the same inputs and serialize the same values.
fn expectTypedEntriesAgree(comptime T: type, input: []const u8) !void {
    const allocator = std.testing.allocator;
    const options: jsonz.typed.ParseOptions = .{ .ignore_unknown_fields = true };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var owned = jsonz.typed.parse(T, allocator, input, options);
    const borrowed = jsonz.typed.parseBorrowed(T, scratch, input, options);

    if (owned) |*parsed| {
        defer parsed.deinit();
        const borrowed_value = borrowed catch |failure| switch (failure) {
            error.OutOfMemory => return,
            else => {
                std.debug.print("parse accepted but parseBorrowed rejected: {s} ({s})\n", .{ input, @errorName(failure) });
                return error.TestUnexpectedResult;
            },
        };

        const from_owned = try parsed.toSlice(allocator, .{});
        defer allocator.free(from_owned);
        const from_borrowed = try jsonz.typed.toSlice(allocator, borrowed_value, .{});
        defer allocator.free(from_borrowed);
        if (!std.mem.eql(u8, from_owned, from_borrowed)) {
            std.debug.print("parse and parseBorrowed serialize differently: {s}\n", .{input});
            return error.TestUnexpectedResult;
        }

        const buffer = scratch.alloc(u8, 64 * 1024) catch return;
        _ = jsonz.typed.parseInto(T, buffer, input, options) catch |failure| switch (failure) {
            error.OutOfMemory => {},
            else => {
                std.debug.print("parse accepted but parseInto rejected: {s} ({s})\n", .{ input, @errorName(failure) });
                return error.TestUnexpectedResult;
            },
        };
    } else |owned_failure| switch (owned_failure) {
        error.OutOfMemory => return,
        else => {
            _ = borrowed catch return;
            std.debug.print("parseBorrowed accepted but parse rejected: {s}\n", .{input});
            return error.TestUnexpectedResult;
        },
    }
}

/// A bare JSON number must convert the way `std.fmt` does.
fn expectNumbersMatchStd(input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    if (jsonz.typed.parseBorrowed(f64, scratch, input, .{})) |value| {
        const expected = std.fmt.parseFloat(f64, trimmed) catch return;
        if (@as(u64, @bitCast(value)) != @as(u64, @bitCast(expected))) {
            std.debug.print("f64 mismatch on {s}: {d} != {d}\n", .{ input, value, expected });
            return error.TestUnexpectedResult;
        }
    } else |_| {}

    if (jsonz.typed.parseBorrowed(u64, scratch, input, .{})) |value| {
        const expected = std.fmt.parseInt(u64, trimmed, 10) catch return;
        if (value != expected) {
            std.debug.print("u64 mismatch on {s}: {d} != {d}\n", .{ input, value, expected });
            return error.TestUnexpectedResult;
        }
    } else |_| {}

    if (jsonz.typed.parseBorrowed(i64, scratch, input, .{})) |value| {
        const expected = std.fmt.parseInt(i64, trimmed, 10) catch return;
        if (value != expected) {
            std.debug.print("i64 mismatch on {s}: {d} != {d}\n", .{ input, value, expected });
            return error.TestUnexpectedResult;
        }
    } else |_| {}
}

test "JSON diagnostic parity fuzz" {
    try std.testing.fuzz({}, fuzzParity, .{ .corpus = &corpus });
}

/// Requires `jsonz.diagnostic` and `jsonz.dom` to agree on the raw fuzz bytes,
/// under every combination of the permissive options.
fn fuzzParity(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const length = smith.slice(&buffer);
    const input = buffer[0..length];

    for (option_sets) |options| try expectAllInvariants(input, options);
}

test "JSON mutation fuzz" {
    try std.testing.fuzz({}, fuzzMutation, .{ .corpus = &corpus });
}

/// Builds a valid document from the generator, then overwrites part of it with
/// raw fuzz bytes. The generator keeps the input structured, the overwrite lets
/// the fuzzer steer the damage.
fn fuzzMutation(_: void, smith: *std.testing.Smith) !void {
    var patch: [128]u8 = undefined;
    const patch_len = smith.slice(&patch);

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try writeValue(smith, &input, 0);

    if (patch_len != 0 and input.items.len != 0) {
        const offset = smith.index(input.items.len);
        const length = @min(patch_len, input.items.len - offset);
        @memcpy(input.items[offset..][0..length], patch[0..length]);
    }

    for (option_sets) |options| try expectAllInvariants(input.items, options);
}

/// Everything the fuzzer checks about one input under one option set:
/// the dom/diagnostic verdict, an external reference, the diagnostic report,
/// and a dom round trip.
fn expectAllInvariants(input: []const u8, options: jsonz.dom.ParseOptions) !void {
    const allocator = std.testing.allocator;
    const check: jsonz.diagnostic.Options = .{
        .allow_comments = options.allow_comments,
        .allow_trailing_commas = options.allow_trailing_commas,
    };

    const accepts = try domAccepts(input, options);
    const valid = jsonz.diagnostic.isValid(input, check);
    if (accepts != valid) {
        std.debug.print("dom and diagnostic disagree on {s} (dom accepts: {}, isValid: {})\n", .{
            input,
            accepts,
            valid,
        });
        return error.TestUnexpectedResult;
    }

    // `std.json` has no comments or trailing commas, so it only speaks for the
    // strict option set. It also rejects every number jsonz rejects, so the
    // safe direction is: what jsonz accepts, the reference has to accept too.
    if (isStrict(options)) {
        if (valid) {
            const reference_accepts = std.json.validate(std.heap.page_allocator, input) catch true;
            if (!reference_accepts) {
                std.debug.print("jsonz accepted what std.json rejects: {s}\n", .{input});
                return error.TestUnexpectedResult;
            }
        }
    }

    try expectDiagnosticReport(allocator, input, check, valid);
    if (accepts) try expectDomRoundTrip(allocator, input, options);
}

fn isStrict(options: jsonz.dom.ParseOptions) bool {
    return !options.allow_comments and !options.allow_trailing_commas;
}

fn domAccepts(input: []const u8, options: jsonz.dom.ParseOptions) error{OutOfMemory}!bool {
    var document = jsonz.dom.parse(std.testing.allocator, input, options) catch |failure| switch (failure) {
        error.InvalidJson => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    document.deinit();
    return true;
}

/// The two rendering entry points must agree, the report must name a span
/// inside the input, and `isValid` must match `diagnose`.
fn expectDiagnosticReport(
    allocator: std.mem.Allocator,
    input: []const u8,
    check: jsonz.diagnostic.Options,
    valid: bool,
) !void {
    const diagnostic = jsonz.diagnostic.diagnose(input, check);
    if (valid) {
        if (diagnostic != null) {
            std.debug.print("isValid accepted but diagnose reported a problem: {s}\n", .{input});
            return error.TestUnexpectedResult;
        }
        return;
    }

    const problem = diagnostic orelse {
        std.debug.print("isValid rejected but diagnose found nothing: {s}\n", .{input});
        return error.TestUnexpectedResult;
    };
    if (problem.span.offset > input.len or problem.span.offset + problem.span.len > input.len) {
        std.debug.print("diagnostic span {d}+{d} outside input of {d} bytes: {s}\n", .{
            problem.span.offset,
            problem.span.len,
            input.len,
            input,
        });
        return error.TestUnexpectedResult;
    }

    const options: jsonz.diagnostic.ReportOptions = .{ .check = check };
    const slice = (try jsonz.diagnostic.toSlice(allocator, input, options)) orelse {
        std.debug.print("toSlice returned null for invalid input: {s}\n", .{input});
        return error.TestUnexpectedResult;
    };
    defer allocator.free(slice);
    if (slice.len == 0) {
        std.debug.print("toSlice returned an empty report: {s}\n", .{input});
        return error.TestUnexpectedResult;
    }

    var streamed: std.Io.Writer.Allocating = .init(allocator);
    defer streamed.deinit();
    try jsonz.diagnostic.printWith(input, options, .{ .writer = &streamed.writer, .mode = .no_color });
    if (!std.mem.eql(u8, slice, streamed.written())) {
        std.debug.print("toSlice and printWith disagree on {s}\n", .{input});
        return error.TestUnexpectedResult;
    }
}

/// Serializing a parsed document must reach a fixed point, so parsing and
/// writing it again cannot drift.
fn expectDomRoundTrip(allocator: std.mem.Allocator, input: []const u8, options: jsonz.dom.ParseOptions) !void {
    var document = try jsonz.dom.parse(allocator, input, options);
    defer document.deinit();
    const first = try document.toSlice(allocator, .{});
    defer allocator.free(first);

    // The mutable tree is a copy of the same document, so it must serialize
    // identically.
    var mutable = try document.toMut(allocator);
    defer mutable.deinit();
    const from_mut = try mutable.toSlice(allocator, .{});
    defer allocator.free(from_mut);
    if (!std.mem.eql(u8, first, from_mut)) {
        std.debug.print("mut serialization differs on {s}: {s} -> {s}\n", .{ input, first, from_mut });
        return error.TestUnexpectedResult;
    }

    var again = try jsonz.dom.parse(allocator, first, options);
    defer again.deinit();
    const second = try again.toSlice(allocator, .{});
    defer allocator.free(second);

    if (!std.mem.eql(u8, first, second)) {
        std.debug.print("dom round trip drifted on {s}: {s} -> {s}\n", .{ input, first, second });
        return error.TestUnexpectedResult;
    }
}

fn writeValue(smith: *std.testing.Smith, out: *std.ArrayList(u8), depth: u8) anyerror!void {
    const choice = if (depth >= 3) 0 else smith.valueRangeAtMost(u8, 0, 6);
    switch (choice) {
        0 => try out.appendSlice(std.testing.allocator, "null"),
        1 => try out.appendSlice(std.testing.allocator, if (smith.value(bool)) "true" else "false"),
        2 => try out.appendSlice(std.testing.allocator, if (smith.value(bool)) "-42" else "123456"),
        3 => try writeString(smith, out),
        4 => try writeArray(smith, out, depth),
        5 => try writeObject(smith, out, depth),
        6 => try writeNumber(smith, out),
        else => unreachable,
    }
}

/// Writes a random JSON number, including ones with more significant digits
/// than a `u64` holds and exponents long enough to saturate the parser.
fn writeNumber(smith: *std.testing.Smith, out: *std.ArrayList(u8)) anyerror!void {
    if (smith.value(bool)) try out.append(std.testing.allocator, '-');

    if (smith.value(bool)) {
        try out.append(std.testing.allocator, '0');
    } else {
        const integer_digits = smith.valueRangeAtMost(u8, 1, 24);
        try out.append(std.testing.allocator, '0' + smith.valueRangeAtMost(u8, 1, 9));
        for (1..integer_digits) |_| {
            try out.append(std.testing.allocator, '0' + smith.valueRangeAtMost(u8, 0, 9));
        }
    }

    if (smith.value(bool)) {
        try out.append(std.testing.allocator, '.');
        const fraction_digits = smith.valueRangeAtMost(u8, 1, 24);
        for (0..fraction_digits) |_| {
            try out.append(std.testing.allocator, '0' + smith.valueRangeAtMost(u8, 0, 9));
        }
    }

    if (smith.value(bool)) {
        try out.append(std.testing.allocator, if (smith.value(bool)) 'e' else 'E');
        if (smith.value(bool)) try out.append(std.testing.allocator, if (smith.value(bool)) '+' else '-');
        const exponent_digits = smith.valueRangeAtMost(u8, 1, 4);
        for (0..exponent_digits) |_| {
            try out.append(std.testing.allocator, '0' + smith.valueRangeAtMost(u8, 0, 9));
        }
    }
}

fn writeString(smith: *std.testing.Smith, out: *std.ArrayList(u8)) anyerror!void {
    try out.append(std.testing.allocator, '"');
    const length = smith.valueRangeAtMost(u8, 0, 16);
    for (0..length) |_| {
        const alphabet = "abcdefghijklmnopqrstuvwxyz 0123456789";
        try out.append(std.testing.allocator, alphabet[smith.valueRangeAtMost(u8, 0, alphabet.len - 1)]);
    }
    try out.append(std.testing.allocator, '"');
}

fn writeArray(smith: *std.testing.Smith, out: *std.ArrayList(u8), depth: u8) anyerror!void {
    try out.append(std.testing.allocator, '[');
    const length = smith.valueRangeAtMost(u8, 0, 4);
    for (0..length) |index| {
        if (index != 0) try out.append(std.testing.allocator, ',');
        try writeValue(smith, out, depth + 1);
    }
    try out.append(std.testing.allocator, ']');
}

fn writeObject(smith: *std.testing.Smith, out: *std.ArrayList(u8), depth: u8) anyerror!void {
    const keys = [_][]const u8{ "id", "name", "score", "active", "address", "tags" };
    try out.append(std.testing.allocator, '{');
    const length = smith.valueRangeAtMost(u8, 0, 4);
    for (0..length) |index| {
        if (index != 0) try out.append(std.testing.allocator, ',');
        const key = keys[smith.valueRangeAtMost(u8, 0, keys.len - 1)];
        try out.appendSlice(std.testing.allocator, "\"");
        try out.appendSlice(std.testing.allocator, key);
        try out.appendSlice(std.testing.allocator, "\":");
        try writeValue(smith, out, depth + 1);
    }
    try out.append(std.testing.allocator, '}');
}

/// A fixed document with no duplicate members, so a JSON Pointer has exactly
/// one answer and the reference resolver cannot disagree about ambiguity.
const pointer_document = "{\"a\":[1,2,{\"b\":\"x\"}],\"\":{\"d\":[true,null]},\"a/b\":{\"~\":1,\"c\":2},\"0\":\"zero\",\"~1\":\"tilde-one\",\"n\":123,\"s\":\"str\"}";

const pointer_corpus = [_][]const u8{
    "",
    "/",
    "/a/0",
    "/a/2/b",
    "/a~1b",
    "/~01",
    "/0",
    "/a/-",
    "/a/01",
    "/~2",
    "/nope",
    "relative",
};

const PointerFuzz = struct {
    reference: std.json.Value,
    document: jsonz.dom.Document,
};

test "JSON pointer fuzz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const reference = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        pointer_document,
        .{},
    );

    var document = try jsonz.dom.parse(std.testing.allocator, pointer_document, .{});
    defer document.deinit();

    const context: PointerFuzz = .{ .reference = reference, .document = document };
    try std.testing.fuzz(context, fuzzPointer, .{ .corpus = &pointer_corpus });
}

/// Resolves a generated pointer against both the DOM and an independent
/// `std.json` reference, and requires the same verdict and the same kind.
fn fuzzPointer(context: PointerFuzz, smith: *std.testing.Smith) !void {
    var pointer: std.ArrayList(u8) = .empty;
    defer pointer.deinit(std.testing.allocator);
    try writePointer(smith, &pointer);

    const expected = referencePointer(context.reference, pointer.items);
    const actual = context.document.ptrGetDyn(pointer.items);

    if (expected) |value| {
        const node = actual catch |failure| {
            std.debug.print("jsonz rejected valid pointer {s}: {s}\n", .{ pointer.items, @errorName(failure) });
            return error.TestUnexpectedResult;
        };
        const expected_kind = referenceKind(value);
        const actual_kind = documentKind(node.kind());
        if (expected_kind != actual_kind) {
            std.debug.print("pointer {s} kind mismatch: {s} != {s}\n", .{
                pointer.items,
                @tagName(actual_kind),
                @tagName(expected_kind),
            });
            return error.TestUnexpectedResult;
        }
    } else if (actual) |node| {
        std.debug.print("jsonz accepted pointer {s} -> {s}\n", .{ pointer.items, @tagName(node.kind()) });
        return error.TestUnexpectedResult;
    } else |_| {}
}

/// Builds a pointer-shaped string: an optional leading token run drawn from an
/// alphabet full of `/`, `~`, digits, and signs, so escapes and indices both get
/// exercised.
fn writePointer(smith: *std.testing.Smith, out: *std.ArrayList(u8)) !void {
    if (smith.value(bool)) return;

    try out.append(std.testing.allocator, '/');
    const tokens = smith.valueRangeAtMost(u8, 0, 4);
    for (0..tokens) |token_index| {
        if (token_index != 0) try out.append(std.testing.allocator, '/');
        const length = smith.valueRangeAtMost(u8, 0, 6);
        const alphabet = "ab~01/-9 ";
        for (0..length) |_| {
            try out.append(std.testing.allocator, alphabet[smith.valueRangeAtMost(u8, 0, alphabet.len - 1)]);
        }
    }
}

/// An RFC 6901 resolver written against `std.json`, independent of `jsonz.dom`.
fn referencePointer(root: std.json.Value, pointer: []const u8) ?std.json.Value {
    if (pointer.len == 0) return root;
    if (pointer[0] != '/') return null;
    if (!std.unicode.utf8ValidateSlice(pointer)) return null;

    var current = root;
    var rest: []const u8 = pointer[1..];
    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, '/');
        const token: []const u8 = if (end) |index| rest[0..index] else rest;
        var buffer: [256]u8 = undefined;
        const decoded = referenceDecode(token, &buffer) orelse return null;
        current = switch (current) {
            .object => |object| object.get(decoded) orelse return null,
            .array => |array| blk: {
                if (std.mem.eql(u8, decoded, "-")) return null;
                const index = referenceIndex(decoded) orelse return null;
                if (index >= array.items.len) return null;
                break :blk array.items[index];
            },
            else => return null,
        };
        rest = if (end) |index| rest[index + 1 ..] else return current;
    }
}

fn referenceDecode(token: []const u8, buffer: []u8) ?[]const u8 {
    var length: usize = 0;
    var index: usize = 0;
    while (index < token.len) {
        if (token[index] == '~') {
            if (index + 1 >= token.len or length == buffer.len) return null;
            buffer[length] = switch (token[index + 1]) {
                '0' => '~',
                '1' => '/',
                else => return null,
            };
            length += 1;
            index += 2;
        } else {
            if (length == buffer.len) return null;
            buffer[length] = token[index];
            length += 1;
            index += 1;
        }
    }
    return buffer[0..length];
}

fn referenceIndex(token: []const u8) ?usize {
    if (token.len == 0) return null;
    if (token[0] == '0') return if (token.len == 1) 0 else null;
    if (token[0] < '1' or token[0] > '9') return null;
    var value: usize = 0;
    for (token) |byte| {
        if (byte < '0' or byte > '9') return null;
        value = std.math.mul(usize, value, 10) catch return null;
        value = std.math.add(usize, value, byte - '0') catch return null;
    }
    return value;
}

const PointerKind = enum { null, bool, number, string, array, object };

fn referenceKind(value: std.json.Value) PointerKind {
    return switch (value) {
        .null => .null,
        .bool => .bool,
        .integer, .float, .number_string => .number,
        .string => .string,
        .array => .array,
        .object => .object,
    };
}

fn documentKind(kind: jsonz.dom.Kind) PointerKind {
    return switch (kind) {
        .null => .null,
        .bool => .bool,
        .number => .number,
        .string => .string,
        .array => .array,
        .object => .object,
    };
}
