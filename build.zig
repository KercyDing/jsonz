const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;

    const jsonz_mod = b.addModule("jsonz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const test_step = b.step("test", "Run tests");
    const test_data_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_data.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const tests = b.addTest(.{
        .root_module = tests_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const roundtrip_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/roundtrip.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "jsonz", .module = jsonz_mod },
            .{ .name = "test_data", .module = test_data_mod },
        },
    });
    const roundtrip_tests = b.addTest(.{ .root_module = roundtrip_test_mod });
    const run_roundtrip_tests = b.addRunArtifact(roundtrip_tests);
    test_step.dependOn(&run_roundtrip_tests.step);

    const fuzzy_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzzy.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{.{ .name = "jsonz", .module = jsonz_mod }},
    });
    const fuzzy_tests = b.addTest(.{ .root_module = fuzzy_test_mod });
    const run_fuzzy_tests = b.addRunArtifact(fuzzy_tests);
    test_step.dependOn(&run_fuzzy_tests.step);

    const bench_step = b.step("bench", "Run benchmarks");
    const bench_mode = b.option([]const u8, "mode", "Benchmark mode: dynamic or typed") orelse "dynamic";
    const bench_file = b.option([]const u8, "file", "Run one benchmark dataset") orelse null;
    if (!std.mem.eql(u8, bench_mode, "dynamic") and !std.mem.eql(u8, bench_mode, "typed")) {
        @panic("-Dmode must be dynamic or typed");
    }
    const bench_jsonz_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .strip = false,
    });
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .strip = false,
        .imports = &.{
            .{ .name = "jsonz", .module = bench_jsonz_mod },
        },
    });
    const bench_exe = b.addExecutable(.{
        .name = "jsonz-bench",
        .root_module = bench_mod,
    });
    bench_exe.root_module.link_libc = true;
    bench_exe.use_llvm = true;
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addArg(bench_mode);
    if (bench_file) |file| {
        run_bench.addArg("--file");
        run_bench.addArg(file);
    }
    bench_step.dependOn(&run_bench.step);
}

comptime {
    const minimum_zig_version = "0.16.0";
    const minimum = std.SemanticVersion.parse(minimum_zig_version) catch unreachable;

    if (builtin.zig_version.order(minimum) == .lt) {
        @compileError(std.fmt.comptimePrint(
            \\Your version of Zig is too old.
            \\Minimum required version: {s}
        , .{minimum_zig_version}));
    }
}
