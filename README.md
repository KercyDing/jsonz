# jsonz

A tiny, high-performance JSON serde library for Zig.

## Usage

Add the dependency:

```sh
zig fetch --save git+https://github.com/KercyDing/jsonz#main
```

Then import its module in `build.zig`:

```zig
const jsonz = b.dependency("jsonz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("jsonz", jsonz.module("jsonz"));
```

Use it from Zig:

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

### Choose an API

| API | Use it when | Notes |
| --- | --- | --- |
| `fromSlice` | You want to decode JSON normally | Strings are copied using the allocator. |
| `fromSliceBorrowed` | You want to avoid copying simple strings | Keep the input JSON alive while using the result. |
| `fromSliceInto` | You already have a fixed-size buffer | Fails if the buffer is too small. |
| `parse` | You want one owned result that is easy to release | Returns a parsed value; call `.deinit()` when done. |
| `toSlice` | You want serialized JSON as `[]u8` | The returned bytes belong to the allocator. |
| `toWriter` | You want to write JSON directly to a writer | Does not create an output slice. |

All decode functions take `options`; use `.{}` for the defaults. Common decode options are `.ignore_unknown_fields = true` to skip extra JSON fields and `.max_depth = 256` to limit nesting.

Serialization options are `.pretty = true` for readable output and `.indent = 4` to choose the indentation width.

## Development

Development commands use [only](https://github.com/KercyDing/only) and [mise](https://github.com/jdx/mise). `mise` provides the Zig version; this project follows Zig `master` by default.

```sh
only build             # debug build
only test              # run tests
only bench             # dynamic benchmarks
only bench typed       # typed benchmarks
only release           # optimized build with symbols stripped
```

Prefix a command with `z16` to run it with Zig 0.16 from `mise.zig16.toml`:

```sh
only z16 build
only z16 test
only z16 release
```

## License

[MIT](LICENSE)
