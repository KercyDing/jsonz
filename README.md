# jsonz

A tiny, high-performance JSON library for Zig.

`jsonz.typed` provides native Zig serialization and deserialization for known schemas.

`jsonz.dom` provides a high-performance DOM for arbitrary JSON, backed by [yyjson](https://github.com/ibireme/yyjson).

## Install

Add the stable `0.2.2` release:

```sh
zig fetch --save git+https://github.com/KercyDing/jsonz#v0.2.2
```

Or track `main`:

```sh
zig fetch --save git+https://github.com/KercyDing/jsonz#main
```

Add the module in `build.zig`:

```zig
const jsonz = b.dependency("jsonz", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("jsonz", jsonz.module("jsonz"));
```

## Quick Start

### Typed JSON

Use `jsonz.typed` when the JSON schema is known:

```zig
const std = @import("std");
const jsonz = @import("jsonz");

const User = struct {
    id: u64,
    name: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const input =
        \\[
        \\  {"id": 1, "name": "hello"},
        \\  {"id": 2, "name": "jsonz"}
        \\]
    ;

    var parsed = try jsonz.typed.parse(
        []User,
        allocator,
        input,
        .{},
    );
    defer parsed.deinit();

    std.debug.print("{s}\n", .{parsed.value[0].name});

    const output = try parsed.toSlice(allocator, .{
        .pretty = true,
    });

    std.debug.print("{s}\n", .{output});
}
```

### DOM

Use `jsonz.dom` when the JSON schema is not known:

```zig
const input =
    \\{
    \\  "name": "jsonz",
    \\  "tags": ["zig", "json"]
    \\}
;

var document = try jsonz.dom.parse(input, .{});
defer document.deinit();

const name = document.field("name").string();
const first_tag = document.field("tags").array().at(0).string();

std.debug.print("{s}: {s}\n", .{ name, first_tag });
```

Use `Object.get` or `Array.get` when a field or array element may be absent:

```zig
if (document.get("name")) |name| {
    if (name.isString()) {
        std.debug.print("{s}\n", .{name.string()});
    }
}
```

`field` and `at` assert that the requested element exists.
`isString`, `isArray`, and other `isXxx` methods check the runtime JSON type; `string`, `array`, and other value accessors assert that the type matches.

## API

### `jsonz.typed`

| API                   | Description                                                 |
| --------------------- | ----------------------------------------------------------- |
| `typed.parse`         | Parse into an owning `Parsed(T)`.                           |
| `typed.parseBorrowed` | Parse while borrowing strings from the input when possible. |
| `typed.parseInto`     | Parse using caller-provided storage.                        |
| `typed.toSlice`       | Serialize a Zig value to `[]u8`.                            |
| `typed.toWriter`      | Serialize a Zig value directly to a writer.                 |

`Parsed(T)` exposes `.value`, `.deinit()`, `.toSlice()`, and `.toWriter()`.

#### Options

Parse options:

| Field                   | Description                           |
| ----------------------- | ------------------------------------- |
| `ignore_unknown_fields` | Skip JSON fields not declared by `T`. |
| `max_depth`             | Limit JSON nesting depth.             |

Serialization options:

| Field    | Description                                     |
| -------- | ----------------------------------------------- |
| `pretty` | Format output with indentation and line breaks. |
| `indent` | Number of spaces per indentation level.         |

### `jsonz.dom`

| API                   | Description                                  |
| --------------------- | -------------------------------------------- |
| `dom.parse`           | Parse arbitrary JSON into a `Document`.      |
| `dom.parseInto`       | Parse using caller-provided DOM storage.     |
| `dom.parseBufferSize` | Compute the storage required by `parseInto`. |

A `Document` owns its yyjson storage. `Value` instances and returned strings borrow that storage and must not outlive the document.

Object access:

```zig
object.get("name")    // ?Value
object.field("name")  // Value
```

Array access:

```zig
array.get(0)          // ?Value
array.at(0)           // Value
```

Type access:

```zig
value.isString()      // bool
value.string()        // []const u8

value.isArray()       // bool
value.array()         // Array

value.isObject()      // bool
value.object()        // Object
```

Both `Document` and `Value` provide `.toSlice()` and `.toWriter()`.

For caller-provided storage:

```zig
const size = jsonz.dom.parseBufferSize(input.len, .{});
const storage = try allocator.alloc(u8, size);
defer allocator.free(storage);

var document = try jsonz.dom.parseInto(storage, input, .{});
defer document.deinit();
```

#### Options

Parse options:

| Field                   | Description                                    |
| ----------------------- | ---------------------------------------------- |
| `allow_comments`        | Accept C-style comments.                       |
| `allow_trailing_commas` | Accept a trailing comma in an object or array. |

Write options:

| Field    | Description                                     |
| -------- | ----------------------------------------------- |
| `pretty` | Format output with indentation and line breaks. |

## Development

Development commands use [only](https://github.com/KercyDing/only) and [mise](https://github.com/jdx/mise). `mise` provides the Zig version; this project targets Zig `0.16.0` by default.

```sh
only build             # debug build
only test              # run tests
only bench             # DOM benchmarks
only bench typed       # typed benchmarks
only release           # optimized build with symbols stripped
```

Use the `master` group to run a command with Zig `master` from `mise.master.toml`:

```sh
only master build
only master test
only master release
```

## License

jsonz is licensed under the [MIT License](LICENSE).

The bundled yyjson source is also MIT licensed; see its [license](src/yyjson/LICENSE).
