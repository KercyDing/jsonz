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

test "JSON parser fuzz" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    if (smith.value(bool)) {
        try writeTarget(smith, &input);
    } else {
        try writeValue(smith, &input, 0);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = jsonz.typed.parseBorrowed(FuzzTarget, allocator, input.items, .{ .ignore_unknown_fields = true }) catch {};
    _ = jsonz.typed.parseBorrowed(bool, allocator, input.items, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(i32, allocator, input.items, .{}) catch {};
    _ = jsonz.typed.parseBorrowed([]const i32, allocator, input.items, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(Address, allocator, input.items, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(Role, allocator, input.items, .{}) catch {};
    _ = jsonz.typed.parseBorrowed(Action, allocator, input.items, .{}) catch {};
}

fn writeTarget(smith: *std.testing.Smith, out: *std.ArrayList(u8)) anyerror!void {
    try out.appendSlice(std.testing.allocator, "{\"id\":123,\"name\":");
    try writeString(smith, out);
    try out.appendSlice(std.testing.allocator, ",\"score\":1.25,\"active\":true,\"role\":\"");
    const roles = [_][]const u8{ "admin", "user", "guest" };
    try out.appendSlice(std.testing.allocator, roles[smith.valueRangeAtMost(u8, 0, roles.len - 1)]);
    try out.appendSlice(std.testing.allocator, "\",\"address\":{\"city\":");
    try writeString(smith, out);
    try out.appendSlice(std.testing.allocator, "},\"tags\":[");
    const tags = smith.valueRangeAtMost(u8, 0, 3);
    for (0..tags) |index| {
        if (index != 0) try out.append(std.testing.allocator, ',');
        try writeString(smith, out);
    }
    try out.appendSlice(std.testing.allocator, "],\"counts\":[1,-2,3],\"history\":[");
    if (smith.value(bool)) {
        try out.appendSlice(std.testing.allocator, "{\"login\":null}");
    } else {
        try out.appendSlice(std.testing.allocator, "{\"update\":{\"field\":\"x\",\"value\":\"y\"}}");
    }
    try out.appendSlice(std.testing.allocator, "],\"pair\":[1.0,-2.5]}");
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

test "JSON diagnostic parity fuzz" {
    try std.testing.fuzz({}, fuzzParity, .{});
}

/// Generates a value, damages it, and requires `jsonz.diagnostic` to agree with
/// `jsonz.dom` about whether the result is valid JSON.
fn fuzzParity(_: void, smith: *std.testing.Smith) !void {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try writeValue(smith, &input, 0);
    mutate(smith, &input);

    const accepts = blk: {
        var document = jsonz.dom.parseWith(std.testing.allocator, input.items, .{}) catch |failure| switch (failure) {
            error.InvalidJson => break :blk false,
            error.OutOfMemory => return failure,
        };
        document.deinit();
        break :blk true;
    };

    const valid = jsonz.diagnostic.isValid(input.items, .{});
    if (accepts != valid) {
        std.debug.print("dom and diagnostic disagree on {s} (dom accepts: {}, isValid: {})\n", .{
            input.items,
            accepts,
            valid,
        });
        return error.TestUnexpectedResult;
    }
}

fn mutate(smith: *std.testing.Smith, input: *std.ArrayList(u8)) void {
    const rounds = smith.valueRangeAtMost(u8, 0, 3);
    for (0..rounds) |_| {
        if (input.items.len == 0) return;
        switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => {
                const replacements = [_]u8{
                    ',', ':', '{', '}', '[', ']', '"',  '\\', '0',  '9',
                    'e', '-', '+', '.', 'x', ' ', '\n', '\t', 0x01, 0xff,
                };
                const index = smith.valueRangeAtMost(u32, 0, @intCast(input.items.len - 1));
                input.items[index] = replacements[smith.valueRangeAtMost(u8, 0, replacements.len - 1)];
            },
            1 => {
                input.shrinkRetainingCapacity(smith.valueRangeAtMost(u32, 0, @intCast(input.items.len)));
            },
            else => {
                const insertions = [_]u8{
                    ',', '"', '\\', '{', '}', '[', ']', 'x', '1', ' ', 0x7f, 0xc3,
                };
                const index = smith.valueRangeAtMost(u32, 0, @intCast(input.items.len));
                const byte = insertions[smith.valueRangeAtMost(u8, 0, insertions.len - 1)];
                input.insert(std.testing.allocator, index, byte) catch return;
            },
        }
    }
}
