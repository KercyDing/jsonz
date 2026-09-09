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
    "canada.json",
    "github_events.json",
    "poet.json",
    "twitter.json",
    "twitterescaped.json",
};

const Mode = enum { dynamic, typed };

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
        if (!isDataset(file) or (mode == .typed and !isTypedDataset(file))) return error.InvalidArguments;
    }

    std.debug.print("jsonz benchmark ({s})\n", .{@tagName(@import("builtin").mode)});
    std.debug.print("data: bench/json, input read and cleanup excluded\n", .{});

    for (datasets) |name| {
        if (mode == .typed and !isTypedDataset(name)) continue;
        if (selected_file) |file| if (!std.mem.eql(u8, file, name)) continue;

        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "bench/json/{s}", .{name});
        const input = try std.Io.Dir.cwd().readFileAlloc(
            std.Options.debug_io,
            path,
            allocator,
            .limited(data_limit),
        );
        defer allocator.free(input);

        const repeats = repeatCount(input.len);
        std.debug.print("\n{s} ({d} bytes, {d} repeats)\n", .{ name, input.len, repeats });

        const jsonz_time = if (mode == .dynamic)
            try benchJsonz(input, repeats)
        else
            try benchJsonzTyped(name, input, repeats);
        printResult("jsonz", jsonz_time, input.len, repeats);
        if (!jsonz_only) {
            const std_time = if (mode == .dynamic)
                try benchStd(input, repeats)
            else
                try benchStdTyped(name, input, repeats);
            printResult("std.json", std_time, input.len, repeats);
        }
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

fn benchJsonzTyped(name: []const u8, input: []const u8, repeats: usize) !u64 {
    return switch (typedType(name)) {
        .canada => benchTypedJsonz(CanadaDocument, input, repeats),
        .github_events => benchTypedJsonz([]const GithubEvent, input, repeats),
        .poet => benchTypedJsonz([]const Poem, input, repeats),
        .twitter => benchTypedJsonz(TwitterDocument, input, repeats),
    };
}

fn benchStdTyped(name: []const u8, input: []const u8, repeats: usize) !u64 {
    return switch (typedType(name)) {
        .canada => benchTypedStd(CanadaDocument, input, repeats),
        .github_events => benchTypedStd([]const GithubEvent, input, repeats),
        .poet => benchTypedStd([]const Poem, input, repeats),
        .twitter => benchTypedStd(TwitterDocument, input, repeats),
    };
}

const TypedType = enum { canada, github_events, poet, twitter };

fn typedType(name: []const u8) TypedType {
    if (std.mem.eql(u8, name, "canada.json")) return .canada;
    if (std.mem.eql(u8, name, "github_events.json")) return .github_events;
    if (std.mem.eql(u8, name, "poet.json")) return .poet;
    return .twitter;
}

fn benchTypedJsonz(comptime T: type, input: []const u8, repeats: usize) !u64 {
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

fn benchTypedStd(comptime T: type, input: []const u8, repeats: usize) !u64 {
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
    const milliseconds = @as(f64, @floatFromInt(elapsed)) /
        @as(f64, @floatFromInt(repeats)) /
        std.time.ns_per_ms;
    std.debug.print("  {s}: {d:.3} ms/op, {d:.2} MiB/s\n", .{
        name,
        milliseconds,
        mebibytes_per_second,
    });
}
