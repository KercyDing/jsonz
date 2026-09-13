# jsonz

A tiny, high-performance JSON library for Zig.

`jsonz.typed` provides native Zig serialization and deserialization for known schemas.

`jsonz.dom` provides a high-performance DOM for arbitrary JSON, a Zig port of [yyjson](https://github.com/ibireme/yyjson).

`jsonz.diagnostic` reviews JSON and points at the first format problem, with a line number and a snippet.

## Install

Add the stable `0.6.1` release:

```sh
zig fetch --save git+https://github.com/KercyDing/jsonz#v0.6.1
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

const name_view = try document.field("name");
const name = try name_view.toString();

const tags = try document.field("tags");
const first_tag_view = try tags.at(0);
const first_tag = try first_tag_view.toString();

std.debug.print("{s}: {s}\n", .{ name, first_tag });
```

Use `get` or `getAt` when a field or array element may be absent:

```zig
if (document.get("name")) |name| {
    if (name.isString()) {
        std.debug.print("{s}\n", .{try name.toString()});
    }
}
```

`get` and `getAt` return `null` when the container type does not match or the
element is missing. `field` and `at` return an error when the container type is
wrong or the requested element does not exist.
`isString`, `isArray`, and other `isXxx` methods check the runtime JSON type.

A `DocView` is the only node type: object and array operations live on it
directly, so a lookup never needs an intermediate view.

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

A `Document` owns its parsed storage. `DocView` instances and returned strings borrow that storage and must not outlive the document.

Object access through `DocView`:

```zig
view.get("name")        // ?DocView
try view.field("name")  // DocView
```

Array access through `DocView`:

```zig
view.getAt(0)        // ?DocView
try view.at(0)       // DocView
```

Container iteration through `DocView`:

```zig
var fields = try view.objectIterator();
while (fields.next()) |entry| {
    entry.key;
    entry.value;
}

var elements = try view.arrayIterator();
while (elements.next()) |element| {
    _ = element;
}
```

JSON Pointer access (RFC 6901):

```zig
const id_view = try document.ptrGet("/user/profile/id");
const id = try id_view.toNumber(.u64);
```

`ptrGet` takes a comptime pointer whose syntax, escapes, and UTF-8 are checked
at compile time and whose tokens are split there. `ptrGetFmt` takes a comptime
format expanded with `std.fmt` semantics, plus runtime arguments:

```zig
const name_view = try document.ptrGet("/user/profile/name");
const name = try name_view.toString();

const index: usize = 0;
const user_view = try document.ptrGetFmt("/statuses/{d}/user", .{index});
```

`ptrGetSlice` takes a complete RFC 6901 pointer as a runtime slice:

```zig
const user_view = try document.ptrGetSlice(pointer_from_user);
```

Interpolation is textual, exactly like `std.fmt`, and never escapes anything: a
`/` in an interpolated value separates tokens, so an object member containing
`/` or `~` must be written as `~1` and `~0` by hand.

A token is an object member or an array index depending on the node it meets,
as RFC 6901 requires; `~1` decodes to `/`, `~0` to `~`, and object keys match by
exact code point without Unicode normalization.

Resolution reports `dom.PointerError`: `error.InvalidPointer` for a malformed
pointer or invalid escape, `error.InvalidArrayIndex` for a token that is not an
RFC 6901 array index (a leading zero, a sign, or an overflow),
`error.MissingField` for an absent object member, `error.OutOfBounds` for an
index past the end or the `-` token, `error.UnexpectedType` for a step into a
scalar, and `error.AmbiguousMember` when a matching object member is not
unique. `error.PointerTooLong` is possible only when a `ptrGetFmt` result does
not fit the internal stack buffer.

The RFC 6901 URI fragment representation (`#/user/id`) is not implemented;
`pointer` accepts the JSON string representation only.

`isXxx` type checks:

| Method | Returns |
| --- | --- |
| `isNull()` | `bool` |
| `isBool()` | `bool` |
| `isNumber(.xxx)` | `bool` |
| `isString()` | `bool` |
| `isArray()` | `bool` |
| `isObject()` | `bool` |

`toXxx` strict access:

| Method | Returns | Failure |
| --- | --- | --- |
| `toBool()` | `AccessError!bool` | not a boolean |
| `toNumber(.xxx)` | `AccessError!T` | not numeric or out of range |
| `toString()` | `AccessError![]const u8` | not a string |

`asXxx` optional access:

| Method | Returns | Failure |
| --- | --- | --- |
| `asNumber(.xxx)` | `?T` | not numeric or out of range |
| `asBool()` | `?bool` | not a boolean |
| `asString()` | `?[]const u8` | not a string |

Integer-to-floating-point conversion may lose precision.

Both `Document` and `DocView` provide `.toSlice()` and `.toWriter()`.

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
