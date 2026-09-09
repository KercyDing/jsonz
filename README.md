# jsonz

A tiny, high-performance JSON library for Zig.

The typed API is native Zig; the unknown-schema DOM API is a thin wrapper around [yyjson](https://github.com/ibireme/yyjson).

## Usage

Add the stable `0.2.0` release:

```sh
zig fetch --save git+https://github.com/KercyDing/jsonz#v0.2.0
```

To track the latest changes, use the `main` branch:

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

For a known schema, use `jsonz.typed`:

```zig
const std = @import("std");
const jsonz = @import("jsonz");

const User = struct {
    id: u64,
    name: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const input = "[{\"id\": 1,\"name\": \"hello\"},{\"id\": 2,\"name\": \"jsonz\"}]";

    var parsed = try jsonz.typed.parse([]User, allocator, input, .{});
    defer parsed.deinit();

    const output = try parsed.toSlice(allocator, .{
        .pretty = true,
    });

    std.debug.print("{s}\n", .{output});
}
```

For JSON without a known schema, use `jsonz.dom`. The document owns the yyjson storage; values and strings borrow it until `deinit`:

```zig
const input = "{\"name\":\"jsonz\"}";
var document = try jsonz.dom.parse(input, .{});
defer document.deinit();

const name = document.field("name").string();
const output = try document.toSlice(allocator, .{});
```

### Typed API

| API | Use it when | Notes |
| --- | --- | --- |
| `typed.parse` | You want an owning typed result | Returns `Parsed(T)`; call `.deinit()` when done. |
| `typed.parseBorrowed` | You want strings to borrow the input | Borrowed strings reference the input; other storage may still use the allocator. |
| `typed.parseInto` | You want decoding to use caller-provided storage | Fails if the buffer is too small. |
| `typed.toSlice` | You want serialized JSON as `[]u8` | The returned bytes belong to the allocator. |
| `typed.toWriter` | You want to write JSON directly | Does not create an output slice. |

`Parsed(T)` also provides `.toSlice()` and `.toWriter()` methods for its value.

### DOM API

Use `get` for checked object-field or array-index access. `field` and `at` assert that the requested element exists. Type checks return `bool`; typed accessors assert that the value has the expected JSON type:

```zig
if (document.get("name")) |name| {
    if (name.isString()) {
        std.debug.print("{s}\n", .{name.string()});
    }
}

const first = document.field("items").array().at(0);
```

| API | Use it when | Notes |
| --- | --- | --- |
| `dom.parse` | You need to inspect arbitrary JSON | Returns `Document`; call `.deinit()` when done. |
| `dom.parseInto` | You provide DOM storage | Use `parseBufferSize` to size the buffer. |
| `dom.parseBufferSize` | You need storage for `parseInto` | Returns the required buffer size. |

Both `Document` and `Value` provide `.toSlice()` and `.toWriter()` methods.

Caller-provided DOM storage is sized and used explicitly:

```zig
const size = jsonz.dom.parseBufferSize(input.len, .{});
const storage = try allocator.alloc(u8, size);
defer allocator.free(storage);

var document = try jsonz.dom.parseInto(storage, input, .{});
defer document.deinit();
```

## Options

Pass `.{}` to use the defaults.

| Namespace | Options | Fields |
| --- | --- | --- |
| `typed` | `typed.ParseOptions` | `ignore_unknown_fields`, `max_depth` |
| `typed` | `typed.SerializeOptions` | `pretty`, `indent` |
| `dom` | `dom.ParseOptions` | `allow_comments`, `allow_trailing_commas` |
| `dom` | `dom.WriteOptions` | `pretty` |

## Development

Development commands use [only](https://github.com/KercyDing/only) and [mise](https://github.com/jdx/mise). `mise` provides the Zig version; this project follows Zig `master` by default.

```sh
only build             # debug build
only test              # run tests
only bench             # DOM benchmarks
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

jsonz is licensed under the [MIT License](LICENSE).

The bundled yyjson source is also MIT licensed; see its [license](src/yyjson/LICENSE).
