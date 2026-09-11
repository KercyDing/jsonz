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

    addTest(
        b,
        test_step,
        "fuzzy/fuzzy.zig",
        jsonz_mod,
        target,
        optimize,
        strip,
    );

    // Benchmarks
    addBench(b, target);

    const microbench_step = b.step("microbench", "Run zBench microbenchmarks");
    if (b.option(bool, "microbench", "Enable zBench microbenchmarks") orelse false) {
        addMicrobench(b, microbench_step, target);
    }
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
