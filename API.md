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
- `dom.Document.toMut` returns `DocumentMut`.

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

- `Node` and the `[]const u8` returned by `toString` are only valid while
  the `Document` lives.
- `NodeMut` and the `[]const u8` returned by `toString` are only valid while
  the `DocumentMut` lives. A `DocumentMut` owns its nodes and strings, so it
  borrows nothing from the caller.
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
| `jsonz.dom` | A DOM for arbitrary JSON documents. `Document` is compact and read-only; `DocumentMut` is an independent editable copy, with [RFC 6902](https://www.rfc-editor.org/info/rfc6902/) JSON Patch as `DocumentMut.patch`. |
| `jsonz.diagnostic` | Report the first JSON syntax error. |

## Public types

| Name | Kind | Purpose |
| --- | --- | --- |
| `typed.Parsed(T)` | owner | Owning typed parse result. |
| `typed.ParseOptions` | struct | Typed parse options. |
| `typed.ParseError` | error set | Typed parse errors. |
| `typed.SerializeOptions` | struct | Typed serialization options. |
| `dom.Document` | owner | Owns parsed DOM storage. |
| `dom.Node` | view | A borrowed JSON node. |
| `dom.Node.ObjectIterator` | view | Iterator over object fields. |
| `dom.Node.ArrayIterator` | view | Iterator over array elements. |
| `dom.Node.ObjectEntry` | view | One `key`/`value` pair. |
| `dom.DocumentMut` | owner | Owns an editable DOM. |
| `dom.NodeMut` | view | A borrowed handle to one node of a `DocumentMut`. |
| `dom.NodeMut.ObjectIterator` | view | Iterator over object fields. |
| `dom.NodeMut.ArrayIterator` | view | Iterator over array elements. |
| `dom.NodeMut.ObjectEntry` | view | One `key`/`value` pair. |
| `dom.Kind` | enum | `null`, `bool`, `number`, `string`, `array`, `object`. |
| `dom.NumberType` | enum | Numeric targets for `toNumber` and `asNumber`. |
| `dom.AccessError` | error set | Node access and conversion errors. |
| `dom.PointerError` | error set | JSON Pointer resolution errors. |
| `dom.MutateError` | error set | Structural edit errors. |
| `dom.ParseOptions` | struct | DOM parse options. |
| `dom.ParseError` | error set | DOM parse errors. |
| `dom.WriteOptions` | struct | DOM serialization options. |
| `dom.DocumentMut.patch.Error` | error set | Patch application errors. |
| `dom.DocumentMut.patch.Options` | struct | Patch parse options. |
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
| `Document.toMut(allocator)` | `Allocator.Error!DocumentMut` | Copy into an editable document. |
| `dom.parseMut(allocator, input, options)` | `ParseError!DocumentMut` | Parse straight into an editable document. |

For workloads that parse many documents in one process,
`std.heap.c_allocator` is recommended because it reuses freed heap blocks
efficiently. Link libc to use it:

```zig
exe.root_module.link_libc = true;
const allocator = std.heap.c_allocator;
```

### Source layout

`jsonz.dom` is two independent models over one shared vocabulary:

```text
src/dom/
  root.zig          the jsonz.dom module: re-exports both models
  common.zig        Kind, NumberType, AccessError, PointerError, WriteOptions, Storage
  pool.zig          the compact node pool
  reader.zig        the JSON reader shared by both models
  rfc.zig           RFC 6901 JSON Pointer resolution
  encode.zig        scalar encoding shared by both writers
  Document/
    root.zig        the read-only model's exports
    Document.zig    the Document type: parse, access, pointer, serialize
    Node.zig        the Node view and the storage it borrows
    writer.zig      compact traversal
  DocumentMut/
    root.zig        the mutable model's exports
    DocumentMut.zig the DocumentMut type: root, serialize, pointer, new*
    NodeMut.zig     the linked node, its storage, edits and traversal
    patch.zig       RFC 6902 JSON Patch over the edits above
```

Each model is reached through its own `root.zig`; neither reaches into the
other's internals. `DocumentMut` reads the compact storage through the shared
`Storage`, so the conversion depends on shared types only.

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
| `root()` | The root `Node`. |
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
| `toMut(allocator)` | Copy the document into a new `DocumentMut`. |

For caller-provided storage:

```zig
const size = jsonz.dom.parseBufferSize(input.len, .{});
const storage = try allocator.alloc(u8, size);
defer allocator.free(storage);

var document = try jsonz.dom.parseInto(storage, input, .{});
defer document.deinit();
```

### `Node`

A `Node` is the only node type; object, array and scalar operations live on
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
| `get(key)` | `?Node` | Not an object, or absent. |
| `field(key)` | `AccessError!Node` | Not an object, or absent. |
| `getAt(index)` | `?Node` | Not an array, or out of range. |
| `at(index)` | `AccessError!Node` | Not an array, or out of range. |
| `objectIterator()` | `AccessError!ObjectIterator` | Not an object. |
| `arrayIterator()` | `AccessError!ArrayIterator` | Not an array. |

Iteration:

```zig
var fields = try view.objectIterator();
while (fields.next()) |entry| {
    entry.key;   // []const u8
    entry.value; // Node
}

var elements = try view.arrayIterator();
while (elements.next()) |element| {
    _ = element; // Node
}
```

Serialization:

| Method | Purpose |
| --- | --- |
| `toSlice(allocator, options)` | Serialize to a new slice owned by `allocator`. |
| `toWriter(writer, options)` | Serialize straight to a writer. |

Integer-to-floating-point conversion may lose precision.

### `DocumentMut`

`DocumentMut` is an independent, editable DOM. Get one with
`Document.toMut(allocator)`: the copy is deep, the original `Document` stays
valid and unchanged, and the two share nothing. Editing is in place and does
not re-parse or re-serialize anything.

| API | Purpose |
| --- | --- |
| `init(allocator)` | A document whose root is `null`, ready to be filled. |
| `parse(allocator, input, options)` | Parse JSON straight into a mutable document. |
| `applyPatch(text, options)` | Apply an RFC 6902 JSON Patch, atomically. |
| `fromStorage(allocator, storage, root_index)` | Copy a compact document's storage. |
| `clone(allocator, source)` | Deep-copy another document. |
| `deinit()` | Release the node and string storage. |
| `root()` | The root `NodeMut`. |
| `toSlice(allocator, options)`, `toWriter(writer, options)` | Serialize the root. |
| `toDocument(allocator)` | Copy the document into a compact, read-only `Document`. |
| `ptrGet(ptr)`, `ptrGetFmt(fmt, args)`, `ptrGetDyn(ptr)` | Root JSON Pointer, with the same semantics as `Document`. |
| `newNull()`, `newBool(value)`, `newNumber(value)`, `newString(value)`, `newArray()`, `newObject()` | Create a detached node to attach later. |

`toDocument(allocator)` goes the other way: it freezes the edited document into
a compact, read-only `Document`. The copy is deep, so the frozen document stays
valid after this one is freed, and only the nodes the tree still holds are
copied. Freezing is how a finished document is shared for reading: `Node`
borrows `*const Storage`, so a `*const Document` has no mutating API at all,
while a `DocumentMut` cannot even be *read* through a constant pointer.

```zig
var mutable = try jsonz.dom.parseMut(allocator, input, .{});
defer mutable.deinit();

try mutable.root().addString("state", "done");

var frozen = try mutable.toDocument(allocator);
defer frozen.deinit();

// `frozen` is a plain `Document`: hand out `&frozen` and nothing can change it.
```

`newNumber` takes a Zig integer or float: a signed integer is stored as a
negative-capable number, an unsigned integer as an unsigned one, and a float as
a real. The same limits as `replaceNumber` apply, so an integer that does not
fit, or a NaN or an infinity, reports `error.OutOfRange`.

### `NodeMut`

`NodeMut` reads exactly like `Node`: `kind`, `is*`, `len`, `get`/`field`,
`getAt`/`at`, `to*`/`as*`, `objectIterator`/`arrayIterator`, `ptrGet` /
`ptrGetFmt` / `ptrGetDyn`, and `toSlice`/`toWriter` all exist with the same
names, arguments, and errors. It adds the editing methods below.

Detached nodes are what editors attach. Create them with the `DocumentMut.new*`
methods. Every editing method takes the document's own storage as a given; a
node from a different `DocumentMut` reports `error.DifferentStorage`.

| Method | Effect |
| --- | --- |
| `replaceNull()` | Set this node to `null`, keeping its position. |
| `replaceBool(value)` | Set this node to a boolean, keeping its position. |
| `replaceNumber(value)` | Set this node to a number, keeping its position. |
| `replaceString(value)` | Set this node to a string, keeping its position. |
| `remove()` | Detach this node. An object member is removed with its key; the root and already-detached nodes are left alone. |
| `replace(value)` | Splice a detached node into this node's position; this node becomes detached. |
| `copyFrom(source)` | Deep-copy `source` into this node, keeping this node's position. `source` may belong to another document. |
| `addField(key, value)` | Append an object member. |
| `addNull(key)` | Append an object member whose value is `null`. |
| `addBool(key, value)` | Append an object member whose value is a boolean. |
| `addNumber(key, value)` | Append an object member whose value is a number. |
| `addString(key, value)` | Append an object member whose value is a string. |
| `append(value)` | Append an array element. |
| `appendNull()` | Append a `null` array element. |
| `appendBool(value)` | Append a boolean array element. |
| `appendNumber(value)` | Append a number array element. |
| `appendString(value)` | Append a string array element. |
| `insertAt(index, value)` | Insert an array element at `index`; `index == len` appends. |

`addNull` and friends are shorthands: they create the value node and append the
member or element, exactly like `addField` and `append` with a node from
`DocumentMut.newNull` and friends.

Storage is append-only, so the document is a good fit for a document's whole
lifecycle, not for a stream of unrelated documents:

- `remove` detaches in constant time and does not reclaim nodes.
- A detached subtree stays valid and editable, and can be attached again.
- `deinit` releases everything the document allocated.

`replaceNull`, `replaceBool` and `remove` cannot fail. `replaceNumber` reports
`error.OutOfRange` for an integer that does not fit the document's `i64`/`u64`
storage, and for a float JSON cannot carry at all (a NaN or an infinity);
`replaceString` only runs out of memory. `copyFrom` only returns allocation
errors. The methods that attach a node
return `MutateError`: `error.AlreadyAttached` when the node is still linked
into a tree (including attaching a node to itself), `error.DifferentStorage`
when it belongs to another document, `error.WouldCycle` when the attach would
make the node its own descendant, `error.UnexpectedType` when the container
kind is wrong, and `error.OutOfBounds` when an `insertAt` index is past the
end. A failed attach leaves the document unchanged.

The cycle check walks from the target up to the root, so an attach costs the
document's depth. The other checks are constant time.

Details worth knowing:

- An object member is one key/value pair, so `remove` on a member value takes
  its key with it.
- `remove` on the root, or on a node that is already detached, does nothing.
- Adding a key that already exists appends a second member; lookups return the
  first match, like a parser resolving duplicate member names.
- `insertAt(len)` appends, and any larger index reports `error.OutOfBounds`.
- The `replace*` methods and `replace` change only the value. Children a
  container used to have become unreachable; their storage is freed by
  `deinit`, not by the edit.
- `copyFrom` is iterative, so copying a very deep subtree cannot overflow the
  stack, and the source may belong to another document.

### JSON Pointer

| API | Returns | Purpose |
| --- | --- | --- |
| `ptrGet("/user/id")` | `PointerError!Node` | Comptime RFC 6901 pointer. |
| `ptrGetFmt("/users/{}/id", .{index})` | `PointerError!Node` | Comptime format plus runtime arguments. |
| `ptrGetDyn(ptr)` | `PointerError!Node` | A complete pointer known only at runtime. |

`ptrGet` checks syntax, escapes and UTF-8 at compile time and splits tokens
there. `ptrGetFmt` expands its format with `std.fmt` semantics into a fixed
stack buffer, so interpolation is textual and never escapes anything: a `/` in
an interpolated value separates tokens, and an object member containing `/` or
`~` must be written as `~1` and `~0` by hand. `error.PointerTooLong` is reported
when a formatted pointer does not fit the buffer.

A token is an object member or an array index depending on the node it meets, as
[RFC 6901](https://www.rfc-editor.org/info/rfc6901/) requires. `~1` decodes to
`/`, `~0` to `~`, and object keys match by exact code point without Unicode
normalization. Duplicate member names resolve to the first match.

The RFC 6901 URI fragment representation (`#/user/id`) is not implemented;
`ptrGetDyn` accepts the JSON string representation only.

### JSON Patch

[RFC 6902](https://www.rfc-editor.org/info/rfc6902/) JSON Patch. A patch is a
scripted sequence of the `NodeMut` edits above, so it lives on the mutable
document rather than in a module of its own.

| API | Returns | Purpose |
| --- | --- | --- |
| `DocumentMut.applyPatch(text, options)` | `Error!void` | Parse and apply a patch, atomically. |
| `DocumentMut.patch.apply(document, text, options)` | `Error!void` | The same, as a free function. |
| `DocumentMut.patch.applyOps(document, ops)` | `Error!void` | Apply an already parsed patch in place. |

A patch is a JSON array of operation objects. Each names its target with an
RFC 6901 JSON Pointer and they are applied in order; the six operations are
`add`, `remove`, `replace`, `move`, `copy`, and `test`.

```zig
var mutable = try jsonz.dom.parseMut(allocator, input, .{});
defer mutable.deinit();

try mutable.applyPatch(patch_text, .{});
```

`applyPatch` is atomic: the operations run on a private deep copy that is
committed only when the whole patch succeeds, so a failure leaves the document
exactly as it was. That copy is the price of the guarantee; `applyOps` edits the document
in place and keeps the operations that ran before a failure.

#### Operation notes

- `add` sets an object member, inserts an array element (`-` appends), and
  replaces the whole document when the path is empty.
- `remove` needs its target to exist, and removes an object member with its key.
- `replace` needs its target to exist. A path of `""` replaces the document.
- `move` removes `from` and then adds at `path`, so an array index is read
  after the removal. The destination must not be inside the moved value
  (`error.InvalidMove`).
- `copy` deep-copies `from` into `path`; copying into the source's own child is
  allowed, and the copy is independent.
- `test` compares by value: numbers compare numerically (`1` equals `1.0`) and
  exactly for integers, object members compare as an unordered set, and array
  elements compare in order. A mismatch reports `error.TestFailed`.

#### Patch options

`DocumentMut.patch.Options`:

| Field | Default | Description |
| --- | --- | --- |
| `parse` | `.{}` | Parse options for the patch document, e.g. comments. |

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
| `OutOfRange` | A number does not fit the requested or the stored type. |
| `MissingField` | The object member is absent. |
| `OutOfBounds` | The array index is past the end. |

`PointerError` is `AccessError` plus:

| Value | Cause |
| --- | --- |
| `InvalidPointer` | Malformed pointer, invalid escape, or invalid UTF-8. |
| `InvalidArrayIndex` | A token that is not an RFC 6901 array index. |
| `PointerTooLong` | A `ptrGetFmt` result does not fit the stack buffer. |

`MutateError` is `Allocator.Error` plus `AccessError` plus:

| Value | Cause |
| --- | --- |
| `AlreadyAttached` | The node is already linked into a tree. |
| `DifferentStorage` | The node belongs to another document. |
| `WouldCycle` | The attach would make the node its own descendant. |

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

`DocumentMut.patch.Error` is `dom.ParseError`, `dom.PointerError` and
`dom.MutateError`
combined, plus:

| Value | Cause |
| --- | --- |
| `InvalidPatch` | The patch is not an array of valid operation objects. |
| `InvalidTarget` | The operation is not defined for the target location. |
| `InvalidMove` | `move` would move a value into its own child. |
| `TestFailed` | A `test` operation found a different value. |
