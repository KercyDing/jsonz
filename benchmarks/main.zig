const std = @import("std");
const jsonz = @import("jsonz");

const allocator = std.heap.c_allocator;
const data_limit = 128 * 1024 * 1024;

const datasets = [_][]const u8{
    "canada.json",
    "citm_catalog.json",
    "fgo.json",
    "github_events.json",
    "gsoc-2018.json",
    "lottie.json",
    "otfcc.json",
    "poet.json",
    "twitter.json",
    "twitterescaped.json",
};

const typed_datasets = [_][]const u8{
    "small.json",
    "canada.json",
    "github_events.json",
    "poet.json",
    "twitter.json",
    "twitterescaped.json",
};

const Mode = enum { dynamic, typed };

const Timing = struct {
    elapsed: u64,
    output_bytes: usize,
};

const GeometricMean = struct {
    log_sum: f64 = 0,
    count: usize = 0,

    fn add(self: *GeometricMean, elapsed: u64, bytes: usize, repeats: usize) void {
        const seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
        const mib_per_second = @as(f64, @floatFromInt(bytes * repeats)) / seconds / (1024 * 1024);
        self.log_sum += @log(mib_per_second);
        self.count += 1;
    }

    fn value(self: GeometricMean) f64 {
        return @exp(self.log_sum / @as(f64, @floatFromInt(self.count)));
    }
};

const TwitterUser = struct {
    id: u64,
    name: []const u8,
    screen_name: []const u8,
    location: []const u8,
    description: []const u8,
    verified: bool,
    followers_count: u64,
    friends_count: u64,
    statuses_count: ?u64,
};

const TwitterStatus = struct {
    created_at: []const u8,
    id: u64,
    text: []const u8,
    user: TwitterUser,
    retweet_count: u64,
    favorite_count: u64,
};

const TwitterDocument = struct {
    statuses: []const TwitterStatus,
};

const CanadaGeometry = struct {
    type: []const u8,
    coordinates: []const []const [2]f64,
};

const CanadaFeature = struct {
    type: []const u8,
    properties: struct { name: []const u8 },
    geometry: CanadaGeometry,
};

const CanadaDocument = struct {
    type: []const u8,
    features: []const CanadaFeature,
};

const Poem = struct {
    desc: []const u8,
    name: []const u8,
    id: []const u8,
};

const SmallDocument = struct {
    id: u64,
    ok: bool,
    name: []const u8,
    score: f64,
    tags: []const []const u8,
};

const GithubActor = struct {
    gravatar_id: []const u8,
    login: []const u8,
    avatar_url: []const u8,
    url: []const u8,
    id: u64,
};

const GithubRepository = struct {
    url: []const u8,
    id: u64,
    name: []const u8,
};

const GithubEvent = struct {
    type: []const u8,
    created_at: []const u8,
    actor: GithubActor,
    repo: GithubRepository,
    public: bool,
    id: []const u8,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args.deinit();
    _ = args.skip();

    const mode_arg = args.next() orelse "dynamic";
    const mode = if (std.mem.eql(u8, mode_arg, "dynamic"))
        Mode.dynamic
    else if (std.mem.eql(u8, mode_arg, "typed"))
        Mode.typed
    else if (std.mem.eql(u8, mode_arg, "--help")) {
        printHelp();
        return;
    } else return error.InvalidArguments;

    var selected_file: ?[]const u8 = null;
    var jsonz_only = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--file")) {
            selected_file = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--jsonz-only")) {
            jsonz_only = true;
        } else return error.InvalidArguments;
    }

    if (selected_file) |file| {
        if (mode == .dynamic and !isDataset(file)) return error.InvalidArguments;
        if (mode == .typed and !isTypedDataset(file)) return error.InvalidArguments;
    }

    std.debug.print("jsonz benchmark ({s})\n", .{@tagName(@import("builtin").mode)});
    std.debug.print("data: benchmarks/json, input read and cleanup excluded\n", .{});

    var jsonz_decode_geomean = GeometricMean{};
    var jsonz_encode_geomean = GeometricMean{};
    var std_decode_geomean = GeometricMean{};
    var std_encode_geomean = GeometricMean{};

    const active_datasets = if (mode == .dynamic) datasets[0..] else typed_datasets[0..];
    for (active_datasets) |name| {
        if (selected_file) |file| if (!std.mem.eql(u8, file, name)) continue;

        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "benchmarks/json/{s}", .{name});
        const input = try std.Io.Dir.cwd().readFileAlloc(
            std.Options.debug_io,
            path,
            allocator,
            .limited(data_limit),
        );
        defer allocator.free(input);

        const repeats = repeatCount(input.len);
        std.debug.print("\n{s} ({d} bytes, {d} repeats)\n", .{ name, input.len, repeats });

        const jsonz_decode = if (mode == .dynamic)
            try benchJsonz(input, repeats)
        else
            try benchJsonzTyped(name, input, repeats);
        const jsonz_encode = if (mode == .dynamic)
            try benchJsonzEncode(input, repeats)
        else
            try benchJsonzTypedEncode(name, input, repeats);
        const std_decode: ?u64 = if (jsonz_only)
            null
        else if (mode == .dynamic)
            try benchStd(input, repeats)
        else
            try benchStdTyped(name, input, repeats);
        const std_encode: ?Timing = if (jsonz_only)
            null
        else if (mode == .dynamic)
            try benchStdEncode(input, repeats)
        else
            try benchStdTypedEncode(name, input, repeats);

        std.debug.print("  decode\n", .{});
        printResult("jsonz", jsonz_decode, input.len, repeats);
        if (std_decode) |elapsed| printResult("std.json", elapsed, input.len, repeats);
        jsonz_decode_geomean.add(jsonz_decode, input.len, repeats);
        if (std_decode) |elapsed| std_decode_geomean.add(elapsed, input.len, repeats);

        std.debug.print("  encode\n", .{});
        printResult("jsonz", jsonz_encode.elapsed, jsonz_encode.output_bytes, repeats);
        if (std_encode) |timing| printResult("std.json", timing.elapsed, timing.output_bytes, repeats);
        jsonz_encode_geomean.add(jsonz_encode.elapsed, jsonz_encode.output_bytes, repeats);
        if (std_encode) |timing| {
            std_encode_geomean.add(timing.elapsed, timing.output_bytes, repeats);
        }
    }

    std.debug.print("\ngeometric mean throughput\n", .{});
    printGeometricMean("jsonz", "decode", jsonz_decode_geomean);
    printGeometricMean("jsonz", "encode", jsonz_encode_geomean);
    if (!jsonz_only) {
        printGeometricMean("std.json", "decode", std_decode_geomean);
        printGeometricMean("std.json", "encode", std_encode_geomean);
    }
}

fn printHelp() void {
    std.debug.print(
        "usage: jsonz-bench [dynamic|typed] [--file name.json]\n" ++
            "\n  dynamic  parse every dataset into a generic JSON value (default)\n" ++
            "  typed    parse datasets with a known Zig type\n" ++
            "  --file  run one dataset instead of all datasets\n" ++
            "  --jsonz-only  skip the std.json comparison\n",
        .{},
    );
}

fn isDataset(name: []const u8) bool {
    for (datasets) |dataset| {
        if (std.mem.eql(u8, name, dataset)) return true;
    }
    return false;
}

fn isTypedDataset(name: []const u8) bool {
    for (typed_datasets) |dataset| {
        if (std.mem.eql(u8, name, dataset)) return true;
    }
    return false;
}

fn repeatCount(size: usize) usize {
    // Tiny inputs model workloads that serialize many small JSON documents.
    // Keep this high enough to smooth scheduler noise without dominating a
    // normal full-suite run.
    if (size <= 256) return 100_000;

    if (size >= 32 * 1024 * 1024) return 1;
    if (size >= 4 * 1024 * 1024) return 2;
    return 32;
}

fn benchJsonz(input: []const u8, repeats: usize) !u64 {
    var warmup = try jsonz.dom.parse(input, .{});
    warmup.deinit();

    var elapsed: u64 = 0;
    for (0..repeats) |_| {
        const start = nowNs();
        var parsed = try jsonz.dom.parse(input, .{});
        const end = nowNs();
        std.mem.doNotOptimizeAway(parsed.root());
        parsed.deinit();
        elapsed += @max(end - start, 1);
    }
    return elapsed;
}

fn benchStd(input: []const u8, repeats: usize) !u64 {
    var warmup = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    warmup.deinit();

    var elapsed: u64 = 0;
    for (0..repeats) |_| {
        const start = nowNs();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
        const end = nowNs();
        std.mem.doNotOptimizeAway(parsed.value);
        parsed.deinit();
        elapsed += @max(end - start, 1);
    }
    return elapsed;
}

fn benchJsonzEncode(input: []const u8, repeats: usize) !Timing {
    var fixture = try jsonz.dom.parse(input, .{});
    defer fixture.deinit();
    const warmup = try fixture.toSlice(allocator, .{});
    defer allocator.free(warmup);

    var elapsed: u64 = 0;
    for (0..repeats) |_| {
        const start = nowNs();
        const output = try fixture.toSlice(allocator, .{});
        const end = nowNs();
        std.mem.doNotOptimizeAway(output.ptr);
        allocator.free(output);
        elapsed += @max(end - start, 1);
    }
    return .{ .elapsed = elapsed, .output_bytes = warmup.len };
}

fn benchStdEncode(input: []const u8, repeats: usize) !Timing {
    var fixture = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer fixture.deinit();
    const warmup = try std.json.Stringify.valueAlloc(allocator, fixture.value, .{});
    defer allocator.free(warmup);

    var elapsed: u64 = 0;
    for (0..repeats) |_| {
        const start = nowNs();
        const output = try std.json.Stringify.valueAlloc(allocator, fixture.value, .{});
        const end = nowNs();
        std.mem.doNotOptimizeAway(output.ptr);
        allocator.free(output);
        elapsed += @max(end - start, 1);
    }
    return .{ .elapsed = elapsed, .output_bytes = warmup.len };
}

fn benchJsonzTyped(name: []const u8, input: []const u8, repeats: usize) !u64 {
    return switch (typedType(name)) {
        .small => benchTypedJsonz(SmallDocument, input, repeats),
        .canada => benchTypedJsonz(CanadaDocument, input, repeats),
        .github_events => benchTypedJsonz([]const GithubEvent, input, repeats),
        .poet => benchTypedJsonz([]const Poem, input, repeats),
        .twitter => benchTypedJsonz(TwitterDocument, input, repeats),
    };
}

fn benchStdTyped(name: []const u8, input: []const u8, repeats: usize) !u64 {
    return switch (typedType(name)) {
        .small => benchTypedStd(SmallDocument, input, repeats),
        .canada => benchTypedStd(CanadaDocument, input, repeats),
        .github_events => benchTypedStd([]const GithubEvent, input, repeats),
        .poet => benchTypedStd([]const Poem, input, repeats),
        .twitter => benchTypedStd(TwitterDocument, input, repeats),
    };
}

fn benchJsonzTypedEncode(name: []const u8, input: []const u8, repeats: usize) !Timing {
    return switch (typedType(name)) {
        .small => benchTypedJsonzEncode(SmallDocument, input, repeats),
        .canada => benchTypedJsonzEncode(CanadaDocument, input, repeats),
        .github_events => benchTypedJsonzEncode([]const GithubEvent, input, repeats),
        .poet => benchTypedJsonzEncode([]const Poem, input, repeats),
        .twitter => benchTypedJsonzEncode(TwitterDocument, input, repeats),
    };
}

fn benchStdTypedEncode(name: []const u8, input: []const u8, repeats: usize) !Timing {
    return switch (typedType(name)) {
        .small => benchTypedStdEncode(SmallDocument, input, repeats),
        .canada => benchTypedStdEncode(CanadaDocument, input, repeats),
        .github_events => benchTypedStdEncode([]const GithubEvent, input, repeats),
        .poet => benchTypedStdEncode([]const Poem, input, repeats),
        .twitter => benchTypedStdEncode(TwitterDocument, input, repeats),
    };
}

const TypedType = enum { small, canada, github_events, poet, twitter };

fn typedType(name: []const u8) TypedType {
    if (std.mem.eql(u8, name, "small.json")) return .small;
    if (std.mem.eql(u8, name, "canada.json")) return .canada;
    if (std.mem.eql(u8, name, "github_events.json")) return .github_events;
    if (std.mem.eql(u8, name, "poet.json")) return .poet;
    return .twitter;
}

fn benchTypedJsonz(comptime T: type, input: []const u8, repeats: usize) !u64 {
    if (comptime T == SmallDocument) return benchTypedJsonzBatched(T, input, repeats);

    var warmup = try jsonz.typed.parse(T, allocator, input, .{ .ignore_unknown_fields = true });
    std.mem.doNotOptimizeAway(warmup.value);
    warmup.deinit();

    var elapsed: u64 = 0;
    for (0..repeats) |_| {
        const start = nowNs();
        var parsed = try jsonz.typed.parse(T, allocator, input, .{ .ignore_unknown_fields = true });
        const end = nowNs();
        std.mem.doNotOptimizeAway(parsed.value);
        parsed.deinit();
        elapsed += @max(end - start, 1);
    }
    return elapsed;
}

fn benchTypedJsonzBatched(comptime T: type, input: []const u8, repeats: usize) !u64 {
    const batch_size = 256;
    var elapsed: u64 = 0;
    var offset: usize = 0;
    while (offset < repeats) {
        const count = @min(batch_size, repeats - offset);
        var parsed_values: [batch_size]jsonz.typed.Parsed(T) = undefined;

        const start = nowNs();
        for (parsed_values[0..count]) |*parsed| {
            parsed.* = try jsonz.typed.parse(T, allocator, input, .{ .ignore_unknown_fields = true });
            std.mem.doNotOptimizeAway(parsed.value);
        }
        elapsed += @max(nowNs() - start, 1);

        for (parsed_values[0..count]) |*parsed| parsed.deinit();
        offset += count;
    }
    return elapsed;
}

fn benchTypedStd(comptime T: type, input: []const u8, repeats: usize) !u64 {
    if (comptime T == SmallDocument) return benchTypedStdBatched(T, input, repeats);

    var warmup_arena = std.heap.ArenaAllocator.init(allocator);
    const warmup = try std.json.parseFromSliceLeaky(T, warmup_arena.allocator(), input, .{ .ignore_unknown_fields = true });
    std.mem.doNotOptimizeAway(warmup);
    warmup_arena.deinit();

    var elapsed: u64 = 0;
    for (0..repeats) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const start = nowNs();
        const value = try std.json.parseFromSliceLeaky(T, arena.allocator(), input, .{ .ignore_unknown_fields = true });
        const end = nowNs();
        std.mem.doNotOptimizeAway(value);
        arena.deinit();
        elapsed += @max(end - start, 1);
    }
    return elapsed;
}

fn benchTypedStdBatched(comptime T: type, input: []const u8, repeats: usize) !u64 {
    const batch_size = 256;
    var elapsed: u64 = 0;
    var offset: usize = 0;
    while (offset < repeats) {
        const count = @min(batch_size, repeats - offset);
        var arenas: [batch_size]std.heap.ArenaAllocator = undefined;
        var values: [batch_size]T = undefined;

        const start = nowNs();
        for (arenas[0..count], values[0..count]) |*arena, *value| {
            arena.* = .init(allocator);
            value.* = try std.json.parseFromSliceLeaky(T, arena.allocator(), input, .{ .ignore_unknown_fields = true });
            std.mem.doNotOptimizeAway(value.*);
        }
        elapsed += @max(nowNs() - start, 1);

        for (arenas[0..count]) |*arena| arena.deinit();
        offset += count;
    }
    return elapsed;
}

fn benchTypedJsonzEncode(comptime T: type, input: []const u8, repeats: usize) !Timing {
    if (comptime T == SmallDocument) return benchTypedJsonzEncodeBatched(T, input, repeats);

    var fixture = try jsonz.typed.parse(T, allocator, input, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    const warmup = try jsonz.typed.toSlice(allocator, fixture.value, .{});
    defer allocator.free(warmup);

    var elapsed: u64 = 0;
    for (0..repeats) |_| {
        const start = nowNs();
        const output = try jsonz.typed.toSlice(allocator, fixture.value, .{});
        const end = nowNs();
        std.mem.doNotOptimizeAway(output.ptr);
        allocator.free(output);
        elapsed += @max(end - start, 1);
    }
    return .{ .elapsed = elapsed, .output_bytes = warmup.len };
}

fn benchTypedJsonzEncodeBatched(comptime T: type, input: []const u8, repeats: usize) !Timing {
    var fixture = try jsonz.typed.parse(T, allocator, input, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    const warmup = try jsonz.typed.toSlice(allocator, fixture.value, .{});
    defer allocator.free(warmup);

    const batch_size = 256;
    var elapsed: u64 = 0;
    var offset: usize = 0;
    while (offset < repeats) {
        const count = @min(batch_size, repeats - offset);
        var outputs: [batch_size][]u8 = undefined;

        const start = nowNs();
        for (outputs[0..count]) |*output| {
            output.* = try jsonz.typed.toSlice(allocator, fixture.value, .{});
            std.mem.doNotOptimizeAway(output.ptr);
        }
        elapsed += @max(nowNs() - start, 1);

        for (outputs[0..count]) |output| allocator.free(output);
        offset += count;
    }
    return .{ .elapsed = elapsed, .output_bytes = warmup.len };
}

fn benchTypedStdEncode(comptime T: type, input: []const u8, repeats: usize) !Timing {
    if (comptime T == SmallDocument) return benchTypedStdEncodeBatched(T, input, repeats);

    var fixture_arena = std.heap.ArenaAllocator.init(allocator);
    defer fixture_arena.deinit();
    const fixture = try std.json.parseFromSliceLeaky(T, fixture_arena.allocator(), input, .{ .ignore_unknown_fields = true });
    const warmup = try std.json.Stringify.valueAlloc(allocator, fixture, .{});
    defer allocator.free(warmup);

    var elapsed: u64 = 0;
    for (0..repeats) |_| {
        const start = nowNs();
        const output = try std.json.Stringify.valueAlloc(allocator, fixture, .{});
        const end = nowNs();
        std.mem.doNotOptimizeAway(output.ptr);
        allocator.free(output);
        elapsed += @max(end - start, 1);
    }
    return .{ .elapsed = elapsed, .output_bytes = warmup.len };
}

fn benchTypedStdEncodeBatched(comptime T: type, input: []const u8, repeats: usize) !Timing {
    var fixture_arena = std.heap.ArenaAllocator.init(allocator);
    defer fixture_arena.deinit();
    const fixture = try std.json.parseFromSliceLeaky(T, fixture_arena.allocator(), input, .{ .ignore_unknown_fields = true });
    const warmup = try std.json.Stringify.valueAlloc(allocator, fixture, .{});
    defer allocator.free(warmup);

    const batch_size = 256;
    var elapsed: u64 = 0;
    var offset: usize = 0;
    while (offset < repeats) {
        const count = @min(batch_size, repeats - offset);
        var outputs: [batch_size][]u8 = undefined;

        const start = nowNs();
        for (outputs[0..count]) |*output| {
            output.* = try std.json.Stringify.valueAlloc(allocator, fixture, .{});
            std.mem.doNotOptimizeAway(output.ptr);
        }
        elapsed += @max(nowNs() - start, 1);

        for (outputs[0..count]) |output| allocator.free(output);
        offset += count;
    }
    return .{ .elapsed = elapsed, .output_bytes = warmup.len };
}

fn nowNs() u64 {
    if (comptime @hasDecl(std.time, "nanoTimestamp")) {
        return @intCast(std.time.nanoTimestamp());
    }
    return @intCast(std.Io.Clock.awake.now(std.Options.debug_io).nanoseconds);
}

fn printResult(name: []const u8, elapsed: u64, bytes: usize, repeats: usize) void {
    const seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
    const total_bytes: f64 = @floatFromInt(bytes * repeats);
    const mebibytes_per_second = total_bytes / seconds / (1024 * 1024);
    const nanoseconds = @as(f64, @floatFromInt(elapsed)) /
        @as(f64, @floatFromInt(repeats)) /
        1.0;
    if (nanoseconds < 1_000) {
        std.debug.print("  {s}: {d:.1} ns/op, {d:.2} MiB/s\n", .{
            name,
            nanoseconds,
            mebibytes_per_second,
        });
    } else {
        std.debug.print("  {s}: {d:.3} ms/op, {d:.2} MiB/s\n", .{
            name,
            nanoseconds / std.time.ns_per_ms,
            mebibytes_per_second,
        });
    }
}

fn printGeometricMean(name: []const u8, operation: []const u8, geomean: GeometricMean) void {
    std.debug.print("  {s} {s}: {d:.2} MiB/s ({d} datasets)\n", .{
        name,
        operation,
        geomean.value(),
        geomean.count,
    });
}
