# jsonz

A tiny, high-performance JSON library for Zig.

- `jsonz.typed` provides native Zig serialization and deserialization for known
  schemas.
- `jsonz.dom` provides a native DOM for arbitrary JSON, with
  [RFC 6901](https://www.rfc-editor.org/info/rfc6901/) JSON Pointer access.
- `jsonz.diagnostic` reports the first JSON syntax error with its location.

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

const input =
    \\[
    \\  {"id": 1, "name": "hello"},
    \\  {"id": 2, "name": "jsonz"}
    \\]
;

var parsed = try jsonz.typed.parse([]User, allocator, input, .{});
defer parsed.deinit();

std.debug.print("{s}\n", .{parsed.value[0].name});

const output = try parsed.toSlice(allocator, .{ .pretty = true });
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
```

`DocView` is the only node type: object, array and scalar access all live on it.
Use `get` and `getAt` for optional access; `field` and `at` return an error when
the container kind is wrong or the element is missing.

```zig
if (document.get("name")) |name| {
    if (name.isString()) {
        std.debug.print("{s}\n", .{try name.toString()});
    }
}
```

Reach nested values with an RFC 6901 JSON Pointer:

```zig
const id_view = try document.ptrGet("/user/profile/id");
const id = try id_view.toNumber(.u64);
```

`ptrGet` takes a comptime pointer, `ptrGetFmt` a comptime format with runtime
arguments, and `ptrGetDyn` a complete pointer known only at runtime:

```zig
const user_view = try document.ptrGetFmt("/statuses/{d}/user", .{index});
const other_view = try document.ptrGetDyn(pointer_from_user);
```

### Diagnosing invalid JSON

`jsonz.diagnostic` reports the first JSON syntax error, with its location and
reason. It reads raw bytes, so it needs no parser, allocator, or schema:

```zig
const broken =
    \\{
    \\  "name": "jsonz",
    \\  "tags": ["zig" "json"],
    \\  "count": 3
    \\}
;

try jsonz.diagnostic.print(broken, .{ .source_name = "config.json" });
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

## API

See [API.md](API.md) for the full API reference: options, types, methods and
error values. The Zig source remains the source of truth.

## Development

Development commands use [only](https://github.com/KercyDing/only) and
[mise](https://github.com/jdx/mise). `mise` provides the Zig version; this project
targets Zig `0.16.0` by default.

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
