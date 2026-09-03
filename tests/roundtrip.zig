const std = @import("std");
const jsonz = @import("jsonz");

const test_json = @import("test_data").content;

pub const User = struct {
    id: u64,
    name: []const u8,
    screen_name: []const u8,
    followers_count: u32,
    verified: bool,
};

pub const Status = struct {
    id: u64,
    text: []const u8,
    user: User,
    retweet_count: u32,
    favorite_count: u32,
    lang: []const u8,
    possibly_sensitive: ?bool = null,
};

pub const SearchMetadata = struct {
    completed_in: f64,
    max_id: u64,
    count: u32,
    query: []const u8,
    next_results: []const u8,
};

pub const Document = struct {
    statuses: []const Status,
    search_metadata: SearchMetadata,
};

test "document round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const response = try jsonz.fromSlice(Document, arena.allocator(), test_json, .{
        .ignore_unknown_fields = true,
    });

    try std.testing.expectEqual(@as(usize, 6), response.statuses.len);
    try std.testing.expectEqual(@as(u32, 6), response.search_metadata.count);
    try std.testing.expectEqualStrings("zig json", response.search_metadata.query);
    try std.testing.expectEqualStrings("Alice Zhang", response.statuses[0].user.name);
    try std.testing.expectEqualStrings("日本語のJSONもテストします", response.statuses[2].text);
    try std.testing.expectEqual(@as(?bool, true), response.statuses[1].possibly_sensitive);
    try std.testing.expectEqual(@as(?bool, null), response.statuses[0].possibly_sensitive);

    const encoded = try jsonz.toSlice(std.testing.allocator, response, .{});
    defer std.testing.allocator.free(encoded);

    var roundtrip_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer roundtrip_arena.deinit();
    const roundtrip = try jsonz.fromSlice(Document, roundtrip_arena.allocator(), encoded, .{});

    try std.testing.expectEqual(response.statuses.len, roundtrip.statuses.len);
    try std.testing.expectEqual(response.statuses[5].id, roundtrip.statuses[5].id);
    try std.testing.expectEqualStrings(response.statuses[5].text, roundtrip.statuses[5].text);
}
