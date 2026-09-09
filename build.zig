const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;

    // yyjson
    const yyjson_c = b.addTranslateC(.{
        .root_source_file = b.path("src/yyjson/yyjson_bridge.h"),
        .target = target,
        .optimize = optimize,
    });
    yyjson_c.addIncludePath(b.path("src/yyjson"));

    const yyjson_mod = yyjson_c.createModule();
    yyjson_mod.addIncludePath(b.path("src/yyjson"));
    yyjson_mod.addCSourceFiles(.{
        .files = &.{
            "src/yyjson/yyjson.c",
            "src/yyjson/yyjson_bridge.c",
        },
        .flags = &.{"-std=c99"},
    });

    // jsonz
    const jsonz_mod = b.addModule("jsonz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "yyjson_c", .module = yyjson_mod },
        },
    });

    // Tests
    const test_step = b.step("test", "Run tests");

    const unit_tests = b.addTest(.{
        .root_module = jsonz_mod,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    addTest(
        b,
        test_step,
        "tests/roundtrip.zig",
        jsonz_mod,
        target,
        optimize,
        strip,
    );

    addTest(
        b,
        test_step,
        "tests/fuzzy.zig",
        jsonz_mod,
        target,
        optimize,
        strip,
    );

    // Benchmarks
    addBench(b, target);
}

fn addTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    source: []const u8,
    jsonz_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "jsonz", .module = jsonz_mod },
        },
    });

    const tests = b.addTest(.{
        .root_module = mod,
    });

    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addBench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) void {
    const bench_step = b.step("bench", "Run benchmarks");

    const mode =
        b.option([]const u8, "mode", "Benchmark mode: dynamic or typed") orelse
        "dynamic";

    const file =
        b.option([]const u8, "file", "Run one benchmark dataset");

    if (!std.mem.eql(u8, mode, "dynamic") and
        !std.mem.eql(u8, mode, "typed"))
    {
        @panic("-Dmode must be dynamic or typed");
    }

    const yyjson_c = b.addTranslateC(.{
        .root_source_file = b.path("src/yyjson/yyjson_bridge.h"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    yyjson_c.addIncludePath(b.path("src/yyjson"));

    const yyjson_mod = yyjson_c.createModule();
    yyjson_mod.addIncludePath(b.path("src/yyjson"));
    yyjson_mod.addCSourceFiles(.{
        .files = &.{
            "src/yyjson/yyjson.c",
            "src/yyjson/yyjson_bridge.c",
        },
        .flags = &.{"-std=c99"},
    });

    const jsonz_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "yyjson_c", .module = yyjson_mod },
        },
    });

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "jsonz", .module = jsonz_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "jsonz-bench",
        .root_module = bench_mod,
    });

    exe.use_llvm = true;

    const run = b.addRunArtifact(exe);
    run.addArg(mode);

    if (file) |path| {
        run.addArgs(&.{ "--file", path });
    }

    bench_step.dependOn(&run.step);
}

comptime {
    const minimum = std.SemanticVersion.parse("0.16.0") catch unreachable;

    if (builtin.zig_version.order(minimum) == .lt) {
        @compileError(std.fmt.comptimePrint(
            \\Your version of Zig is too old.
            \\Minimum required version: 0.16.0
        , .{}));
    }
}
