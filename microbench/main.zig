const std = @import("std");
const float = @import("float");
const jsonz = @import("jsonz");
const zbench = @import("zbench");

const number = "123456789.01234567e-3";
const document = "{\"value\":123.456789,\"items\":[1,2,3],\"name\":\"jsonz\"}";

fn parseFloat(allocator: std.mem.Allocator) void {
    _ = allocator;
    var bits: u64 = 0;
    for (0..1_000) |_| {
        const parsed = float.parseNumber(f64, number, 0) catch unreachable;
        bits ^= @bitCast(parsed.value);
    }
    std.mem.doNotOptimizeAway(&bits);
}

fn domRoundTrip(allocator: std.mem.Allocator) void {
    var length: usize = 0;
    for (0..10) |_| {
        var parsed = jsonz.dom.parseWith(allocator, document, .{}) catch unreachable;
        defer parsed.deinit();
        const output = parsed.toSlice(allocator, .{}) catch unreachable;
        length ^= output.len;
        allocator.free(output);
    }
    std.mem.doNotOptimizeAway(&length);
}

pub fn main() !void {
    var io_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_threaded.deinit();

    var benchmark = zbench.Benchmark.init(std.heap.smp_allocator, .{
        .time_budget_ns = 1_000_000_000,
    });
    defer benchmark.deinit();

    try benchmark.add("float.parseNumber x1000", parseFloat, .{});
    try benchmark.add("dom.parse+encode x10", domRoundTrip, .{});
    try benchmark.run(io_threaded.io(), std.Io.File.stdout());
}
