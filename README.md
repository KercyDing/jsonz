# jsonz

A high-performance JSON document library for Zig.

- `jsonz.dom` provides a native DOM for arbitrary JSON: a compact read-only
  `Document` and an editable `DocumentMut`, with
  [RFC 6901](https://www.rfc-editor.org/info/rfc6901/) JSON Pointer access on
  both, and [RFC 6902](https://www.rfc-editor.org/info/rfc6902/) JSON Patch for
  editable documents.
- `jsonz.typed` provides native Zig serialization and deserialization for known
  schemas.
- `jsonz.diagnostic` reports the first JSON syntax error with its location.

## Install

Add the stable `0.7.0` release:

```sh
zig fetch --save git+https://github.com/KercyDing/jsonz#v0.7.0
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

`Node` is a borrowed view into a `Document`. Object, array and scalar access
all live on it. Use `get` and `getAt` for optional access; `field` and `at`
return an error when the container kind is wrong or the element is missing.

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

### Mutable DOM

`Document` is compact and read-only, which keeps parsing and querying fast.
When a document has to change, copy it into a `DocumentMut` and edit that:

```zig
var mutable = try document.toMut(allocator);
defer mutable.deinit();

const root = mutable.root();

// Add a member to the root object.
try root.addString("name", "jsonz");

// Take a node, then edit that node.
const tags = try root.field("tags");
try tags.appendString("dom");

const age = try root.field("age");
try age.replaceNumber(@as(u8, 3));

const old = try root.field("old");
old.remove();

const edited = try mutable.toSlice(allocator, .{ .pretty = true });
```

`NodeMut` is a handle to one node of the document: taking one copies nothing,
and every edit goes through the document it came from. Reading works exactly
like `Node`, JSON Pointer included:

```zig
const name = try mutable.ptrGet("/user/name");
try name.replaceString("jsonz");
```

`DocumentMut` owns its nodes, so it borrows nothing from the caller and the
original `Document` stays valid and unchanged.

Editing methods split into three groups:

- **In place** — `replaceNull`, `replaceBool`, `replaceNumber`, `replaceString`
  change a node's value but keep its position.
- **Structure** — `addField`, `addString`, `append`, `appendString`, `insertAt`
  attach a node; `remove` detaches one; `replace` splices a detached node into
  the node's own slot.
- **Copy** — `copyFrom` deep-copies a subtree, including one from another
  document.

New nodes come from `DocumentMut.newNull` / `newBool` / `newNumber` /
`newString` / `newArray` / `newObject`, and start out detached. Attaching a node
that is already linked into a tree fails with `error.AlreadyAttached`, and a
node from another document fails with `error.DifferentStorage`; use `copyFrom`
to move data across documents.

Editing never overflows the stack, however deep the document is.

A document can also be parsed straight into a mutable one, without building a
compact tree first:

```zig
var mutable = try jsonz.dom.parseMut(allocator, input, .{});
defer mutable.deinit();
```

### JSON Patch

`DocumentMut.applyPatch` applies an
[RFC 6902](https://www.rfc-editor.org/info/rfc6902/) patch, which is just a
scripted sequence of the edits above:

```zig
const patch =
    \\[
    \\  {"op": "test", "path": "/name", "value": "jsonz"},
    \\  {"op": "replace", "path": "/name", "value": "jsonz dom"},
    \\  {"op": "add", "path": "/tags/-", "value": "dom"}
    \\]
;

try mutable.applyPatch(patch, .{});
```

All six operations are supported: `add`, `remove`, `replace`, `move`, `copy`
and `test`. Applying is atomic: the operations run on a private copy, so a
failed operation leaves the document untouched. `jsonz.dom.patch.applyOps`
applies an already parsed patch in place instead, which skips that copy but
keeps the operations that ran before a failure.

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
