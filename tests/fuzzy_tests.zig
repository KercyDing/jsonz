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
    deep_arrays,
    deep_broken,
    long_string,
    "{\"id\":7,\"name\":\"jsonz\",\"score\":1.5,\"active\":true,\"role\":\"admin\"," ++
        "\"address\":{\"city\":\"x\",\"zip\":null},\"tags\":[\"a\"],\"counts\":[1,-2]," ++
        "\"history\":[{\"login\":null},{\"update\":{\"field\":\"f\",\"value\":\"v\"}}]," ++
        "\"pair\":[0,1]}",
    "{\"id\":7,\"name\":\"jsonz\",\"score\":1.5,\"active\":true,\"role\":\"nope\"," ++
        "\"address\":{\"city\":\"x\"}}",
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

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    inline for (.{ FuzzTarget, Address, Role, Action, []const i32, []const u8 }) |T| {
        if (typedAccepts(T, allocator, input)) try expectDomAccepts(input, .{});
    }

    _ = jsonz.typed.parseBorrowed(bool, allocator, input, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(i32, allocator, input, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(u64, allocator, input, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(f32, allocator, input, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(f64, allocator, input, .{}) catch {};
}

fn typedAccepts(comptime T: type, allocator: std.mem.Allocator, input: []const u8) bool {
    _ = jsonz.typed.parseBorrowed(T, allocator, input, .{ .ignore_unknown_fields = true }) catch return false;
    return true;
}

fn expectDomAccepts(input: []const u8, options: jsonz.dom.ParseOptions) !void {
    var document = jsonz.dom.parseWith(std.testing.allocator, input, options) catch |failure| switch (failure) {
        error.InvalidJson => {
            std.debug.print("typed parser accepted invalid JSON: {s}\n", .{input});
            return error.TestUnexpectedResult;
        },
        error.OutOfMemory => return failure,
    };
    document.deinit();
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

    try expectAgreement(input, .{});
    try expectAgreement(input, .{ .allow_trailing_commas = true });
    try expectAgreement(input, .{ .allow_comments = true });
    try expectAgreement(input, .{ .allow_comments = true, .allow_trailing_commas = true });
}

fn expectAgreement(input: []const u8, options: jsonz.dom.ParseOptions) !void {
    const accepts = try domAccepts(input, options);
    const valid = jsonz.diagnostic.isValid(input, .{
        .allow_comments = options.allow_comments,
        .allow_trailing_commas = options.allow_trailing_commas,
    });
    if (accepts != valid) {
        std.debug.print("dom and diagnostic disagree on {s} (dom accepts: {}, isValid: {})\n", .{
            input,
            accepts,
            valid,
        });
        return error.TestUnexpectedResult;
    }
}

fn domAccepts(input: []const u8, options: jsonz.dom.ParseOptions) error{OutOfMemory}!bool {
    var document = jsonz.dom.parseWith(std.testing.allocator, input, options) catch |failure| switch (failure) {
        error.InvalidJson => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    document.deinit();
    return true;
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

    try expectAgreement(input.items, .{});
    try expectAgreement(input.items, .{ .allow_comments = true, .allow_trailing_commas = true });
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
