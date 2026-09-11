const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;

    // float
    const float_mod = b.addModule("float", .{
        .root_source_file = b.path("src/float/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    // jsonz
    const jsonz_mod = b.addModule("jsonz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "float", .module = float_mod },
        },
    });

    // Tests
    const test_step = b.step("test", "Run tests");

    const unit_tests = b.addTest(.{
        .root_module = jsonz_mod,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // `float` is a separate module, so its tests need their own test target.
    const float_tests = b.addTest(.{
        .root_module = float_mod,
    });
    test_step.dependOn(&b.addRunArtifact(float_tests).step);

    const integration_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "jsonz", .module = jsonz_mod },
        },
    });
    const integration_tests = b.addTest(.{ .root_module = integration_tests_mod });
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // The fuzz targets get a step of their own: `zig build fuzzy --fuzz[=limit]`.
    // The plain test suite stays finite.
    const fuzzy_step = b.step("fuzzy", "Run fuzz tests");
    const fuzzy_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzzy_tests.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "jsonz", .module = jsonz_mod },
        },
    });
    const fuzzy_tests = b.addTest(.{ .root_module = fuzzy_tests_mod });
    fuzzy_step.dependOn(&b.addRunArtifact(fuzzy_tests).step);

    // Benchmarks
    addBench(b, target);

    const microbench_step = b.step("microbench", "Run zBench microbenchmarks");
    if (b.option(bool, "microbench", "Enable zBench microbenchmarks") orelse false) {
        addMicrobench(b, microbench_step, target);
    }
}

fn addBench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) void {
    const bench_step = b.step("bench", "Run benchmarks");

    const mode =
        b.option([]const u8, "mode", "Benchmark mode: dom or typed") orelse
        "dom";

    const file =
        b.option([]const u8, "file", "Run one benchmark dataset");

    if (!std.mem.eql(u8, mode, "dom") and
        !std.mem.eql(u8, mode, "typed"))
    {
        @panic("-Dmode must be dom or typed");
    }

    const float_mod = b.createModule(.{
        .root_source_file = b.path("src/float/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const jsonz_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "float", .module = float_mod },
        },
    });

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        // The benchmark uses `std.heap.c_allocator` for its own allocations.
        .link_libc = true,
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

fn addMicrobench(
    b: *std.Build,
    microbench_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
) void {
    const zbench_dep = b.lazyDependency("zbench", .{
        .target = target,
        .optimize = .ReleaseFast,
    }) orelse return;

    const float_mod = b.createModule(.{
        .root_source_file = b.path("src/float/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const jsonz_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "float", .module = float_mod },
        },
    });

    const microbench_mod = b.createModule(.{
        .root_source_file = b.path("microbench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "float", .module = float_mod },
            .{ .name = "jsonz", .module = jsonz_mod },
            .{ .name = "zbench", .module = zbench_dep.module("zbench") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "jsonz-microbench",
        .root_module = microbench_mod,
    });
    exe.use_llvm = true;

    const run = b.addRunArtifact(exe);
    microbench_step.dependOn(&run.step);
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
