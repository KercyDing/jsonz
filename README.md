# jsonz

A high-performance JSON serde library for Zig.

## Usage

```zig
const std = @import("std");
const jsonz = @import("jsonz");

const User = struct {
    id: u64,
    name: []const u8,
};

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const input = "{\"id\":7,\"name\":\"jsonz\"}";
const user = try jsonz.fromSlice(User, arena.allocator(), input, .{});

const output = try jsonz.toSlice(std.heap.page_allocator, user, .{});
defer std.heap.page_allocator.free(output);
```

`fromSlice` owns decoded strings through the allocator. Use `fromSliceBorrowed` to reuse unescaped input strings, `fromSliceInto` for caller-provided fixed storage, or `parse` for an owned contiguous pool.

The project follows Zig `master` by default through `mise.toml`; use `only z16 build` or `only z16 test` for Zig 0.16.

## License

[MIT](LICENSE)
