const std = @import("std");
const jsonz = @import("jsonz");

const test_data = @import("test_data");
const iterations = 2_000;
const string_count = 4_096;

const User = struct {
    id: u64,
    name: []const u8,
    screen_name: []const u8,
    followers_count: u32,
    verified: bool,
};

const Status = struct {
    id: u64,
    text: []const u8,
    user: User,
    retweet_count: u32,
    favorite_count: u32,
    lang: []const u8,
    possibly_sensitive: ?bool = null,
};

const SearchMetadata = struct {
    completed_in: f64,
    max_id: u64,
    count: u32,
    query: []const u8,
    next_results: []const u8,
};

const Document = struct {
    statuses: []const Status,
    search_metadata: SearchMetadata,
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var source_arena = std.heap.ArenaAllocator.init(allocator);
    defer source_arena.deinit();
    const source = try jsonz.fromSliceWith(Document, source_arena.allocator(), test_data.content, .{
        .ignore_unknown_fields = true,
    });
    const serialized_sample = try jsonz.toSlice(allocator, source);
    defer allocator.free(serialized_sample);

    try warmup(allocator, source);

    const jsonz_parse_ns = try benchParse(Document, allocator, test_data.content, false, true);
    const std_parse_ns = try benchParse(Document, allocator, test_data.content, true, true);
    const jsonz_serialize_ns = try benchJsonzSerialize(allocator, source);
    const std_serialize_ns = try benchStdSerialize(allocator, source);

    std.debug.print("{s}: {d} bytes, {d} iterations\n", .{ test_data.file_name, test_data.content.len, iterations });
    printResult("jsonz parse", jsonz_parse_ns, test_data.content.len);
    printResult("std.json parse", std_parse_ns, test_data.content.len);
    printResult("jsonz serialize", jsonz_serialize_ns, serialized_sample.len);
    printResult("std.json serialize", std_serialize_ns, serialized_sample.len);

    const string_array = try makeStringArray(allocator);
    defer allocator.free(string_array);
    const jsonz_string_array_ns = try benchParse([]const []const u8, allocator, string_array, false, false);
    const std_string_array_ns = try benchParse([]const []const u8, allocator, string_array, true, false);

    std.debug.print("\nlarge string array: {d} bytes, {d} elements\n", .{ string_array.len, string_count });
    printResult("jsonz parse", jsonz_string_array_ns, string_array.len);
    printResult("std.json parse", std_string_array_ns, string_array.len);
}

fn warmup(allocator: std.mem.Allocator, source: Document) !void {
    for (0..20) |_| {
        var jsonz_arena = std.heap.ArenaAllocator.init(allocator);
        _ = try jsonz.fromSliceWith(Document, jsonz_arena.allocator(), test_data.content, .{
            .ignore_unknown_fields = true,
        });
        jsonz_arena.deinit();

        var std_arena = std.heap.ArenaAllocator.init(allocator);
        _ = try std.json.parseFromSliceLeaky(Document, std_arena.allocator(), test_data.content, .{
            .ignore_unknown_fields = true,
        });
        std_arena.deinit();

        const jsonz_encoded = try jsonz.toSlice(allocator, source);
        allocator.free(jsonz_encoded);
        const std_encoded = try std.json.Stringify.valueAlloc(allocator, source, .{});
        allocator.free(std_encoded);
    }
}

fn benchParse(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    comptime use_std: bool,
    comptime ignore_unknown_fields: bool,
) !u64 {
    const start = nowNs();
    for (0..iterations) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const value = if (use_std)
            try std.json.parseFromSliceLeaky(T, arena.allocator(), input, .{ .ignore_unknown_fields = ignore_unknown_fields })
        else
            try jsonz.fromSliceWith(T, arena.allocator(), input, .{ .ignore_unknown_fields = ignore_unknown_fields });
        std.mem.doNotOptimizeAway(value);
        arena.deinit();
    }
    return nowNs() - start;
}

fn benchJsonzSerialize(allocator: std.mem.Allocator, source: Document) !u64 {
    const start = nowNs();
    for (0..iterations) |_| {
        const encoded = try jsonz.toSlice(allocator, source);
        std.mem.doNotOptimizeAway(encoded);
        allocator.free(encoded);
    }
    return nowNs() - start;
}

fn benchStdSerialize(allocator: std.mem.Allocator, source: Document) !u64 {
    const start = nowNs();
    for (0..iterations) |_| {
        const encoded = try std.json.Stringify.valueAlloc(allocator, source, .{});
        std.mem.doNotOptimizeAway(encoded);
        allocator.free(encoded);
    }
    return nowNs() - start;
}

fn makeStringArray(allocator: std.mem.Allocator) ![]u8 {
    const element = "\"abcdefgh\"";
    const output_len = 2 + string_count * element.len + string_count - 1;
    const output = try allocator.alloc(u8, output_len);

    var pos: usize = 0;
    output[pos] = '[';
    pos += 1;
    for (0..string_count) |index| {
        if (index != 0) {
            output[pos] = ',';
            pos += 1;
        }
        @memcpy(output[pos..][0..element.len], element);
        pos += element.len;
    }
    output[pos] = ']';
    return output;
}

fn nowNs() u64 {
    if (comptime @hasDecl(std.time, "nanoTimestamp")) {
        return @intCast(std.time.nanoTimestamp());
    }
    return @intCast(std.Io.Clock.awake.now(std.Options.debug_io).nanoseconds);
}

fn printResult(name: []const u8, elapsed_ns: u64, bytes_per_iteration: usize) void {
    const operations: f64 = @floatFromInt(iterations);
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / operations;
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const total_bytes: f64 = @floatFromInt(bytes_per_iteration * iterations);
    const gib_per_second = total_bytes / seconds / (1024 * 1024 * 1024);

    std.debug.print("{s: <20} {d: >10.1} ns/op  {d: >6.3} GiB/s\n", .{
        name,
        ns_per_op,
        gib_per_second,
    });
}
