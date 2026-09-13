# API

A quick reference for the Zig API. The Zig source remains the source of truth.

## Contents

- [Rules](#rules)
- [Module layout](#module-layout)
- [Public types](#public-types)
- [`jsonz.typed`](#jsonztyped)
- [`jsonz.dom`](#jsonzdom)
- [`jsonz.diagnostic`](#jsonzdiagnostic)
- [Error values](#error-values)

## Rules

### Ownership

The owning entry points return a value with `deinit`. Call it exactly once.

- `typed.parse` returns `Parsed(T)`.
- `dom.parse` and `dom.parseInto` return `Document`.

`typed.parseBorrowed`, `typed.parseInto` and `dom.parseBufferSize` have no owner
to release.

```zig
var document = try jsonz.dom.parse(allocator, input, .{});
defer document.deinit();
```

Invalid:

```zig
var document = try jsonz.dom.parse(allocator, input, .{});
var other = document;

document.deinit();
other.deinit(); // double release
```

### Borrowed data

Values returned by views and strings decoded in place borrow the owner's
storage.

- `DocView` and the `[]const u8` returned by `toString` are only valid while
  the `Document` lives.
- `parseBorrowed` borrows unescaped strings directly from the input, which must
  outlive the value.
- `parseInto` borrows caller-provided storage, which must outlive the value.

DOM string escapes are decoded in place, so `dom.parse` copies the input into
the document; the caller's buffer can be freed right after parsing.

### Errors

Zig error sets are explicit. `AccessError` and `PointerError` cover node access;
`ParseError` covers parsing; serialization returns allocator and IO errors.

## Module layout

| Module | Purpose |
| --- | --- |
| `jsonz.typed` | Parse and serialize known Zig types. |
| `jsonz.dom` | A DOM for arbitrary JSON documents. |
| `jsonz.diagnostic` | Report the first JSON syntax error. |

## Public types

| Name | Kind | Purpose |
| --- | --- | --- |
| `typed.Parsed(T)` | owner | Owning typed parse result. |
| `typed.ParseOptions` | struct | Typed parse options. |
| `typed.ParseError` | error set | Typed parse errors. |
| `typed.SerializeOptions` | struct | Typed serialization options. |
| `dom.Document` | owner | Owns parsed DOM storage. |
| `dom.DocView` | view | A borrowed JSON node. |
| `dom.DocView.ObjectIterator` | view | Iterator over object fields. |
| `dom.DocView.ArrayIterator` | view | Iterator over array elements. |
| `dom.DocView.ObjectEntry` | view | One `key`/`value` pair. |
| `dom.Kind` | enum | `null`, `bool`, `number`, `string`, `array`, `object`. |
| `dom.NumberType` | enum | Numeric targets for `toNumber` and `asNumber`. |
| `dom.AccessError` | error set | Node access and conversion errors. |
| `dom.PointerError` | error set | JSON Pointer resolution errors. |
| `dom.ParseOptions` | struct | DOM parse options. |
| `dom.ParseError` | error set | DOM parse errors. |
| `dom.WriteOptions` | struct | DOM serialization options. |
| `diagnostic.Diagnostic` | struct | One syntax error and where it is. |
| `diagnostic.Span` | struct | A byte range of the input. |
| `diagnostic.Note` | struct | Extra context for a report. |
| `diagnostic.Problem` | union | Everything that can be wrong. |
| `diagnostic.Options` | struct | What counts as valid JSON. |
| `diagnostic.ReportOptions` | struct | How a report looks. |

## `jsonz.typed`

| API | Returns | Purpose |
| --- | --- | --- |
| `typed.parse(T, allocator, input, options)` | `ParseError!Parsed(T)` | Parse into an owning result. |
| `typed.parseBorrowed(T, allocator, input, options)` | `ParseError!T` | Parse, borrowing strings from `input` when possible. |
| `typed.parseInto(T, buffer, input, options)` | `ParseError!T` | Parse using caller-provided storage. |
| `typed.toSlice(allocator, value, options)` | `![]u8` | Serialize a Zig value. |
| `typed.toWriter(writer, value, options)` | `!void` | Serialize straight to a writer. |

`parseBorrowed` and `parseInto` return the value directly; the caller keeps the
borrowed storage alive.

### `Parsed(T)`

| API | Purpose |
| --- | --- |
| `.value` | The decoded value. |
| `.deinit()` | Release the input copy and any fallback allocation. |
| `.toSlice(allocator, options)` | Serialize `.value`. |
| `.toWriter(writer, options)` | Serialize `.value`. |

`T` may define `jsonzDeserialize` / `jsonzSerialize` hooks for custom
representations. See `src/typed/deserialize.zig`.

### Parse options

`typed.ParseOptions`:

| Field | Default | Description |
| --- | --- | --- |
| `ignore_unknown_fields` | `false` | Skip JSON fields not declared by `T`. |
| `max_depth` | `256` | Reject input nested deeper than this. |

### Serialize options

`typed.SerializeOptions`:

| Field | Default | Description |
| --- | --- | --- |
| `pretty` | `false` | Format with indentation and line breaks. |
| `indent` | `2` | Spaces per level when `pretty` is set. |

## `jsonz.dom`

| API | Returns | Purpose |
| --- | --- | --- |
| `dom.parse(allocator, input, options)` | `ParseError!Document` | Parse arbitrary JSON. |
| `dom.parseInto(storage, input, options)` | `ParseError!Document` | Parse using caller-provided storage. |
| `dom.parseBufferSize(input_len, options)` | `usize` | Storage size required by `parseInto`. |
| `dom.toSlice(allocator, view, options)` | `![]u8` | Serialize a `DocView`. |
| `dom.toWriter(writer, view, options)` | `!void` | Serialize a `DocView`. |

For workloads that parse many documents in one process,
`std.heap.c_allocator` is recommended because it reuses freed heap blocks
efficiently. Link libc to use it:

```zig
exe.root_module.link_libc = true;
const allocator = std.heap.c_allocator;
```

### Parse options

`dom.ParseOptions`:

| Field | Default | Description |
| --- | --- | --- |
| `allow_comments` | `false` | Accept `//` and `/* ... */` comments. |
| `allow_trailing_commas` | `false` | Accept a comma before `]` or `}`. |

### Write options

`dom.WriteOptions`:

| Field | Default | Description |
| --- | --- | --- |
| `pretty` | `false` | Format with indentation and line breaks. |

### `Document`

`Document` forwards the root node's accessors, so `document.field(...)` and
`document.root().field(...)` are the same call.

| API | Purpose |
| --- | --- |
| `deinit()` | Release the DOM storage. |
| `root()` | The root `DocView`. |
| `kind()` | Kind of the root. |
| `isNull()`, `isBool()`, `isNumber(.xxx)`, `isString()`, `isArray()`, `isObject()` | Root type checks. |
| `len()` | Field or element count of a root container. |
| `toBool()`, `toNumber(.xxx)`, `toString()` | Strict root conversion. |
| `asBool()`, `asNumber(.xxx)`, `asString()` | Optional root conversion. |
| `get(key)`, `field(key)` | Root object member. |
| `getAt(index)`, `at(index)` | Root array element. |
| `objectIterator()`, `arrayIterator()` | Root container iteration. |
| `ptrGet(ptr)`, `ptrGetFmt(fmt, args)`, `ptrGetDyn(ptr)` | Root JSON Pointer. |
| `toSlice(allocator, options)`, `toWriter(writer, options)` | Serialize the root. |

For caller-provided storage:

```zig
const size = jsonz.dom.parseBufferSize(input.len, .{});
const storage = try allocator.alloc(u8, size);
defer allocator.free(storage);

var document = try jsonz.dom.parseInto(storage, input, .{});
defer document.deinit();
```

### `DocView`

A `DocView` is the only node type; object, array and scalar operations live on
it directly.

Access:

| Method | Returns | Failure |
| --- | --- | --- |
| `kind()` | `Kind` | — |
| `isNull()`, `isBool()`, `isString()`, `isArray()`, `isObject()` | `bool` | — |
| `isNumber(.xxx)` | `bool` | Not convertible. |
| `len()` | `AccessError!usize` | Not a container. |
| `toBool()` | `AccessError!bool` | Not a boolean. |
| `toNumber(.xxx)` | `AccessError!T` | Not numeric, or out of range. |
| `toString()` | `AccessError![]const u8` | Not a string. |
| `asBool()` | `?bool` | Not a boolean. |
| `asNumber(.xxx)` | `?T` | Not numeric, or out of range. |
| `asString()` | `?[]const u8` | Not a string. |

Containers:

| Method | Returns | Failure |
| --- | --- | --- |
| `get(key)` | `?DocView` | Not an object, or absent. |
| `field(key)` | `AccessError!DocView` | Not an object, or absent. |
| `getAt(index)` | `?DocView` | Not an array, or out of range. |
| `at(index)` | `AccessError!DocView` | Not an array, or out of range. |
| `objectIterator()` | `AccessError!ObjectIterator` | Not an object. |
| `arrayIterator()` | `AccessError!ArrayIterator` | Not an array. |

Iteration:

```zig
var fields = try view.objectIterator();
while (fields.next()) |entry| {
    entry.key;   // []const u8
    entry.value; // DocView
}

var elements = try view.arrayIterator();
while (elements.next()) |element| {
    _ = element; // DocView
}
```

Serialization:

| Method | Purpose |
| --- | --- |
| `toSlice(allocator, options)` | Serialize to a new slice owned by `allocator`. |
| `toWriter(writer, options)` | Serialize straight to a writer. |

Integer-to-floating-point conversion may lose precision.

### JSON Pointer

| API | Returns | Purpose |
| --- | --- | --- |
| `ptrGet("/user/id")` | `PointerError!DocView` | Comptime RFC 6901 pointer. |
| `ptrGetFmt("/users/{}/id", .{index})` | `PointerError!DocView` | Comptime format plus runtime arguments. |
| `ptrGetDyn(ptr)` | `PointerError!DocView` | A complete pointer known only at runtime. |

`ptrGet` checks syntax, escapes and UTF-8 at compile time and splits tokens
there. `ptrGetFmt` expands its format with `std.fmt` semantics into a fixed
stack buffer, so interpolation is textual and never escapes anything: a `/` in
an interpolated value separates tokens, and an object member containing `/` or
`~` must be written as `~1` and `~0` by hand. `error.PointerTooLong` is reported
when a formatted pointer does not fit the buffer.

A token is an object member or an array index depending on the node it meets, as
[RFC 6901](https://www.rfc-editor.org/info/rfc6901/) requires. `~1` decodes to
`/`, `~0` to `~`, and object keys match by exact code point without Unicode
normalization. A pointer that matches more than one object member is
`error.AmbiguousMember`.

The RFC 6901 URI fragment representation (`#/user/id`) is not implemented;
`ptrGetDyn` accepts the JSON string representation only.

## `jsonz.diagnostic`

| API | Returns | Purpose |
| --- | --- | --- |
| `diagnostic.diagnose(input, options)` | `?Diagnostic` | The first syntax error, or null. |
| `diagnostic.isValid(input, options)` | `bool` | Whether the input is valid. |
| `diagnostic.print(input, options)` | `!void` | Write the report to standard error; silent when valid. |
| `diagnostic.printWith(input, options, terminal)` | `!void` | Write the report to a terminal; silent when valid. |
| `diagnostic.toSlice(allocator, input, options)` | `!?[]const u8` | The report as a new slice, or null when valid. |

Nothing here needs a parser, a schema, or a mutable input. `print` and
`printWith` stream the report, so nothing is allocated and its size is
unbounded; `toSlice` materialises it. Syntax is checked, not a schema, and only
the first error is reported.

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

### Check options

`diagnostic.Options`, used by `isValid` and `diagnose`:

| Field | Default | Description |
| --- | --- | --- |
| `allow_comments` | `false` | Accept C-style comments. |
| `allow_trailing_commas` | `false` | Accept a trailing comma. |

### Report options

`diagnostic.ReportOptions`, used by `print`, `printWith` and `toSlice`:

| Field | Default | Description |
| --- | --- | --- |
| `check` | `.{}` | Check options for this document. |
| `source_name` | `"<input>"` | Name shown in the header. |
| `context_lines` | `3` | Source lines shown above and below. |
| `max_line_width` | `200` | Cut longer lines around the problem; `0` shows all. |

Colour is not an option: it belongs to the stream. `print` colours standard
error whenever it is a terminal that takes escape codes, honouring `NO_COLOR`
and `CLICOLOR_FORCE`; `printWith` writes to the `std.Io.Terminal` you hand it,
so that stream decides; `toSlice` returns plain text.

## Error values

`AccessError`:

| Value | Cause |
| --- | --- |
| `UnexpectedType` | The node is not the requested JSON kind. |
| `OutOfRange` | The number does not fit the requested type. |
| `MissingField` | The object member is absent. |
| `OutOfBounds` | The array index is past the end. |

`PointerError` is `AccessError` plus:

| Value | Cause |
| --- | --- |
| `InvalidPointer` | Malformed pointer, invalid escape, or invalid UTF-8. |
| `InvalidArrayIndex` | A token that is not an RFC 6901 array index. |
| `AmbiguousMember` | The pointer matches more than one object member. |
| `PointerTooLong` | A `ptrGetFmt` result does not fit the stack buffer. |

`typed.ParseError`:

| Value | Cause |
| --- | --- |
| `UnexpectedToken` | The input does not match the target type. |
| `UnexpectedEof` | The input ended early. |
| `InvalidNumber` | A number is malformed or overflows its target. |
| `InvalidEscape` | A string escape is malformed. |
| `InvalidControlCharacter` | A raw control byte appears in a string. |
| `InvalidUtf8` | A string is not valid UTF-8. |
| `InvalidUnicode` | A `\u` escape is not a valid code point. |
| `MaxDepthExceeded` | Nesting passes `max_depth`. |
| `WrongType` | The JSON kind does not match `T`. |
| `UnknownField` | An object field has no match in `T`. |
| `MissingField` | A declared field is absent. |
| `TrailingData` | Bytes remain after the value. |
| `OutOfMemory` | Allocation failed. |

`dom.ParseError`:

| Value | Cause |
| --- | --- |
| `InvalidJson` | The input is not valid JSON. |
| `OutOfMemory` | Allocation failed. |
