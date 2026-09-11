//! Integration tests for `jsonz.typed`: flows that combine parsing with
//! serialization.

const std = @import("std");
const jsonz = @import("jsonz");

const typed = jsonz.typed;

const testing = std.testing;

test "value round trip" {
    const input = "[\"one\",\"two\"]";

    var parsed = try typed.parse([]const []const u8, testing.allocator, input, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("one", parsed.value[0]);
    try testing.expectEqualStrings("two", parsed.value[1]);

    const output = try parsed.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);
}

test "nested round trip" {
    const Role = enum { admin, member };
    const Address = struct {
        city: []const u8,
        zip: ?[]const u8 = null,
    };
    const User = struct {
        id: u64,
        name: []const u8,
        score: f64,
        active: bool,
        role: Role,
        address: Address,
        tags: []const []const u8,
    };

    const input = "{\"id\":42,\"name\":\"ada\",\"score\":9.5,\"active\":true," ++
        "\"role\":\"admin\",\"address\":{\"city\":\"London\",\"zip\":null}," ++
        "\"tags\":[\"math\",\"code\"]}";

    var parsed = try typed.parse(User, testing.allocator, input, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u64, 42), parsed.value.id);
    try testing.expectEqual(Role.admin, parsed.value.role);
    try testing.expectEqualStrings("London", parsed.value.address.city);
    try testing.expect(parsed.value.address.zip == null);

    // Field order, enum tags and a null optional all survive the round trip.
    const output = try parsed.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);

    var again = try typed.parse(User, testing.allocator, output, .{});
    defer again.deinit();
    try testing.expectEqual(parsed.value.id, again.value.id);
    try testing.expectEqualStrings(parsed.value.name, again.value.name);
    try testing.expectEqual(parsed.value.score, again.value.score);
    try testing.expectEqual(parsed.value.active, again.value.active);
    try testing.expectEqual(parsed.value.role, again.value.role);
    try testing.expectEqualStrings(parsed.value.address.city, again.value.address.city);
    try testing.expect(again.value.address.zip == null);
    try testing.expectEqual(parsed.value.tags.len, again.value.tags.len);
    try testing.expectEqualStrings(parsed.value.tags[1], again.value.tags[1]);
}

test "custom hooks" {
    const Timestamp = struct {
        seconds: i64,

        pub fn jsonzSerialize(self: @This(), serializer: anytype) !void {
            try serializer.serializeInt(self.seconds * 1000);
        }

        pub fn jsonzDeserialize(
            comptime _: type,
            _: std.mem.Allocator,
            deserializer: anytype,
        ) typed.ParseError!@This() {
            const millis = try deserializer.deserialize(i64);
            return .{ .seconds = @divTrunc(millis, 1000) };
        }
    };

    const output = try typed.toSlice(testing.allocator, Timestamp{ .seconds = 7 }, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("7000", output);

    var parsed = try typed.parse(Timestamp, testing.allocator, output, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 7), parsed.value.seconds);
}

test "borrowed matches owning" {
    const Doc = struct {
        name: []const u8,
        tags: []const []const u8,
    };
    const input = "{\"name\":\"jsonz\",\"tags\":[\"a\",\"b\"]}";

    // The borrowed parse only allocates the container, so an arena owns it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const borrowed = try typed.parseBorrowed(Doc, arena.allocator(), input, .{});

    var parsed = try typed.parse(Doc, testing.allocator, input, .{});
    defer parsed.deinit();

    const from_borrowed = try typed.toSlice(testing.allocator, borrowed, .{});
    defer testing.allocator.free(from_borrowed);
    const from_parsed = try parsed.toSlice(testing.allocator, .{});
    defer testing.allocator.free(from_parsed);

    try testing.expectEqualStrings(input, from_borrowed);
    try testing.expectEqualStrings(from_borrowed, from_parsed);
}

test "pretty round trip" {
    const Value = struct {
        a: []const i32,
        b: struct { c: ?u8 },
    };
    const input = "{\"a\":[1,2],\"b\":{\"c\":null}}";

    var parsed = try typed.parse(Value, testing.allocator, input, .{});
    defer parsed.deinit();

    const pretty = try parsed.toSlice(testing.allocator, .{ .pretty = true, .indent = 4 });
    defer testing.allocator.free(pretty);
    try testing.expectEqualStrings(
        \\{
        \\    "a": [
        \\        1,
        \\        2
        \\    ],
        \\    "b": {
        \\        "c": null
        \\    }
        \\}
    , pretty);

    var again = try typed.parse(Value, testing.allocator, pretty, .{});
    defer again.deinit();
    try testing.expectEqualSlices(i32, parsed.value.a, again.value.a);
    try testing.expectEqual(parsed.value.b.c, again.value.b.c);
}

test "unknown fields dropped" {
    const Config = struct {
        name: []const u8,
        retries: u8 = 3,
    };

    var parsed = try typed.parse(Config, testing.allocator, "{\"name\":\"api\",\"timeout\":30,\"retries\":5}", .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testing.expectEqual(@as(u8, 5), parsed.value.retries);

    const output = try parsed.toSlice(testing.allocator, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("{\"name\":\"api\",\"retries\":5}", output);
}

test "caller buffer output" {
    const Entry = struct {
        name: []const u8,
        tags: []const []const u8,
    };
    const input = "{\"name\":\"jsonz\",\"tags\":[\"zig\",\"json\"]}";

    var buffer: [1024]u8 = undefined;
    const entry = try typed.parseInto(Entry, &buffer, input, .{});

    const output = try typed.toSlice(testing.allocator, entry, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);
}
