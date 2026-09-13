# jsonz

A tiny, high-performance JSON library for Zig.

`jsonz.typed` provides native Zig serialization and deserialization for known schemas.

`jsonz.dom` provides a high-performance DOM for arbitrary JSON, a Zig port of [yyjson](https://github.com/ibireme/yyjson).

`jsonz.diagnostic` reviews JSON and points at the first format problem, with a line number and a snippet.

## Install

Add the stable `0.5.1` release:

```sh
zig fetch --save git+https://github.com/KercyDing/jsonz#v0.5.1
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

var document = try jsonz.dom.parse(allocator, input, .{});
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

### Diagnosing invalid JSON

`jsonz.diagnostic` reviews JSON: it reports the first format problem, with the
line, the column, and the reason. It reads raw bytes, so it needs no parser,
allocator, or schema:

```zig
try jsonz.diagnostic.print(input, .{ .source_name = "config.json" });
```

```console
config.json:3:18: error: expected ',' or ']', found '"'
1 | {
2 |   "name": "jsonz",
3 |   "tags": ["zig" "json"],
  |                  ^
4 |   "count": 3
5 | }
```

`printWith` writes to a writer of yours, `toSlice` returns the report as a
slice, `isValid` answers with a `bool`, and `diagnose` hands back the
`Diagnostic` for callers that want the span or the problem tag. Nothing is
allocated on the way to a writer, and only the first problem is reported.
Syntax is checked, not a schema, and the module stands on its own: it is
independent of `jsonz.typed` and `jsonz.dom`.

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

| API                   | Description                                             |
| --------------------- | ------------------------------------------------------- |
| `dom.parse`           | Parse arbitrary JSON into a `Document` with the given allocator. |
| `dom.parseInto`       | Parse using caller-provided DOM storage.                |
| `dom.parseBufferSize` | Compute the storage required by `parseInto`.            |

Pass an allocator to `parse` to choose the allocation strategy, or reuse a
buffer through `parseInto` to avoid allocating on every parse.

For workloads that parse many documents in one process,
`std.heap.c_allocator` is recommended because it reuses freed heap blocks
efficiently. The application must link libc when using it:

```zig
exe.root_module.link_libc = true;
const allocator = std.heap.c_allocator;
```

A `Document` owns its parsed storage. `Value` instances and returned strings borrow that storage and must not outlive the document.

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

### `jsonz.diagnostic`

| API                    | Description                                            |
| ---------------------- | ------------------------------------------------------ |
| `diagnostic.isValid`   | Return whether the input is valid JSON.                |
| `diagnostic.print`     | Write the report to standard error; silent when valid. |
| `diagnostic.printWith` | Write the report to a writer; silent when valid.       |
| `diagnostic.toSlice`   | Return the report as a new slice, or `null` if valid.  |
| `diagnostic.diagnose`  | Low level: return the problem and where it is.         |

`isValid` and `diagnose` take the check options, which decide what counts as
valid JSON:

| Field                   | Description                                    |
| ----------------------- | ---------------------------------------------- |
| `allow_comments`        | Accept C-style comments. Defaults to `false`.  |
| `allow_trailing_commas` | Accept a trailing comma in an object or array. |

`print`, `printWith` and `toSlice` take the report options, which include the
check options for documents read with extensions enabled:

| Field            | Description                                                |
| ---------------- | ---------------------------------------------------------- |
| `check`          | Check options for this document; defaults to `.{}`.        |
| `source_name`    | Name shown in the header. Defaults to `<input>`.           |
| `context_lines`  | Source lines shown above and below. Defaults to `3`.       |
| `max_line_width` | Cut longer source lines around the problem. `0` shows all. |

Colour is not an option: it belongs to the stream. `print` colours standard
error whenever it is a terminal that takes escape codes, honouring `NO_COLOR`
and `CLICOLOR_FORCE`; `printWith` writes to the `std.Io.Terminal` you hand it,
so that stream decides; `toSlice` returns plain text.

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

[MIT License](LICENSE).
