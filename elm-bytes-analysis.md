# Elm Binary Decoding Libraries: Comparative Analysis

This report analyzes three Elm packages for binary data handling:

1. **elm/bytes** — The standard library for binary encoding/decoding
2. **zwilias/elm-bytes-parser** — Parser combinators with error tracking and backtracking
3. **mpizenberg/elm-bytes-decoder** — Branchable wrapper around elm/bytes with minimal overhead

---

## Table of Contents

1. [elm/bytes](#1-elmbytes)
2. [zwilias/elm-bytes-parser](#2-zwiliaselm-bytes-parser)
3. [mpizenberg/elm-bytes-decoder](#3-mpizenbergelm-bytes-decoder)
4. [Comparative Summary](#4-comparative-summary)

---

## 1. elm/bytes

**Version:** 1.0.8 | **License:** BSD-3-Clause | **Dependencies:** `elm/core` only

### 1.1 Package Structure

Three exposed modules:

| Module | Role |
|--------|------|
| `Bytes` | Opaque `Bytes` type + `Endianness` (LE/BE) + `width` |
| `Bytes.Encode` | Builder-pattern encoders |
| `Bytes.Decode` | Monadic sequential decoders |

### 1.2 Encoding API (Bytes.Encode)

```elm
type Encoder  -- opaque, internally a tagged union:
  -- I8/I16/I32/U8/U16/U32/F32/F64/Seq/Utf8/Bytes

encode : Encoder -> Bytes

-- Primitives
signedInt8    : Int -> Encoder
signedInt16   : Endianness -> Int -> Encoder
signedInt32   : Endianness -> Int -> Encoder
unsignedInt8  : Int -> Encoder
unsignedInt16 : Endianness -> Int -> Encoder
unsignedInt32 : Endianness -> Int -> Encoder
float32       : Endianness -> Float -> Encoder
float64       : Endianness -> Float -> Encoder

-- Compound
bytes          : Bytes -> Encoder
string         : String -> Encoder          -- UTF-8, no length prefix
getStringWidth : String -> Int              -- UTF-8 byte count
sequence       : List Encoder -> Encoder    -- concatenation
```

**Design:** Encoders are an immutable AST. `sequence` pre-computes total width at construction time, so `encode` allocates a single `DataView` of exact size and writes in one pass. Byte copying uses 4-byte chunks when possible.

### 1.3 Decoding API (Bytes.Decode)

```elm
type Decoder a  -- opaque: Bytes -> Int -> (Int, a)

decode : Decoder a -> Bytes -> Maybe a

-- Primitives (mirror Encode)
signedInt8    : Decoder Int
signedInt16   : Endianness -> Decoder Int
signedInt32   : Endianness -> Decoder Int
unsignedInt8  : Decoder Int
unsignedInt16 : Endianness -> Decoder Int
unsignedInt32 : Endianness -> Decoder Int
float32       : Endianness -> Decoder Float
float64       : Endianness -> Decoder Float
bytes         : Int -> Decoder Bytes
string        : Int -> Decoder String

-- Applicative
map  : (a -> b) -> Decoder a -> Decoder b
map2 : (a -> b -> c) -> Decoder a -> Decoder b -> Decoder c
map3 : ... -> Decoder d    -- up to map5

-- Monadic
succeed  : a -> Decoder a
fail     : Decoder a
andThen  : (a -> Decoder b) -> Decoder a -> Decoder b

-- Looping
type Step state a = Loop state | Done a
loop : state -> (state -> Decoder (Step state a)) -> Decoder a
```

**Design:** A decoder is a function `Bytes -> Int -> (Int, a)` — takes bytes + offset, returns new offset + value. Decoders thread offset through sequential composition. On any out-of-bounds read, the JS kernel throws an exception caught by `decode`, which returns `Nothing`.

### 1.4 Kernel Implementation (JavaScript)

- `Bytes` wraps a JavaScript `DataView` over an `ArrayBuffer`
- All reads/writes use `DataView` methods (`getInt8`, `setFloat32`, etc.) with endianness control
- UTF-8 encoding/decoding is hand-rolled: handles 1–4 byte sequences and surrogate pairs
- `Bytes.width` is `DataView.byteLength`
- `getHostEndianness` probes with `new Uint8Array(new Uint32Array([1]))[0] === 1`
- Error mechanism: `_Bytes_decodeFailure = F2(function() { throw 0; })`, caught by `decode`

### 1.5 Limitations

| Limitation | Detail |
|------------|--------|
| No error info | `decode` returns `Maybe a` — no offset, no message, no context |
| No backtracking | Offset only advances; no `oneOf` or alternative combinators |
| No streaming | Entire input required upfront |
| No random access | Strictly sequential reading |
| No validation | Cannot reject logically invalid but well-formed data |
| Limited arity | `map` through `map5` only (6+ fields require nesting) |
| No length prefix | `string` and `bytes` encoders emit raw data; user must encode length separately |

---

## 2. zwilias/elm-bytes-parser

**Version:** 1.0.0 | **License:** BSD-3-Clause | **Dependencies:** `elm/bytes`, `elm/core`

### 2.1 Core Types

```elm
type Parser context error value
    = Parser (State -> ParseResult context error value)

type alias State =
    { offset : Int
    , stack : List Int    -- defined but unused in current implementation
    , input : Bytes
    }

type ParseResult context error value
    = Good value State
    | Bad (Error context error)

type Error context error
    = InContext { label : context, start : Int } (Error context error)
    | OutOfBounds { at : Int, bytes : Int }
    | Custom { at : Int } error
    | BadOneOf { at : Int } (List (Error context error))

type Position  -- opaque wrapper around Int
```

### 2.2 Full API

```elm
-- Running
run : Parser context error value -> Bytes -> Result (Error context error) value

-- Static
succeed  : value -> Parser context error value
fail     : error -> Parser context error value
position : Parser context error Position
startOfInput : Position

-- Primitives (same set as elm/bytes)
unsignedInt8  : Parser context error Int
signedInt8    : Parser context error Int
unsignedInt16 : Endianness -> Parser context error Int
signedInt16   : Endianness -> Parser context error Int
unsignedInt32 : Endianness -> Parser context error Int
signedInt32   : Endianness -> Parser context error Int
float32       : Endianness -> Parser context error Float
float64       : Endianness -> Parser context error Float
string        : Int -> Parser context error String
bytes         : Int -> Parser context error Bytes

-- Applicative
map  : (a -> b) -> Parser c e a -> Parser c e b
map2 : (x -> y -> z) -> Parser c e x -> Parser c e y -> Parser c e z
map3 ... map4 ... map5

-- Pipeline
keep   : Parser c e a -> Parser c e (a -> b) -> Parser c e b
ignore : Parser c e ignore -> Parser c e keep -> Parser c e keep
skip   : Int -> Parser c e value -> Parser c e value

-- Monadic
andThen : (a -> Parser c e b) -> Parser c e a -> Parser c e b

-- Branching
oneOf : List (Parser c e value) -> Parser c e value

-- Looping
type Step state a = Loop state | Done a
loop   : (state -> Parser c e (Step state a)) -> state -> Parser c e a
repeat : Parser c e value -> Int -> Parser c e (List value)

-- Error tracking
inContext : context -> Parser c e value -> Parser c e value

-- Random access
randomAccess : { offset : Int, relativeTo : Position } -> Parser c e value -> Parser c e value
```

### 2.3 Implementation Details

**Primitive parsers wrap elm/bytes decoders via `fromDecoder`:**

```elm
fromDecoder : Decoder v -> Int -> Parser context error v
fromDecoder dec byteLength =
    Parser <| \state ->
        let combined = Decode.map2 (always identity) (Decode.bytes state.offset) dec
        in case Decode.decode combined state.input of
            Just res  -> Good res { state | offset = state.offset + byteLength }
            Nothing   -> Bad (OutOfBounds { at = state.offset, bytes = byteLength })
```

This is a **double-decoding** approach: `Decode.bytes state.offset` skips to the current offset, then `dec` reads the value. Every primitive decoder re-reads from the start of input.

**Backtracking in `oneOf`:**

```elm
oneOfHelp options errors state =
    case options of
        [] -> Bad (BadOneOf { at = state.offset } (List.reverse errors))
        (Parser f) :: xs ->
            case f state of
                Good v s -> Good v s
                Bad e    -> oneOfHelp xs (e :: errors) state  -- same state!
```

Each alternative receives the **same state** — if a parser advances then fails, the state is simply not carried forward (implicit backtracking via functional purity).

**`randomAccess` temporarily shifts offset, then restores it:**

```elm
randomAccess config (Parser f) =
    Parser <| \state ->
        let (Position start) = config.relativeTo
        in case f { state | offset = start + config.offset } of
            Good v newState -> Good v { newState | offset = state.offset }  -- restore!
            Bad e           -> Bad e
```

**`inContext` wraps errors only on failure (lazy):**

```elm
inContext label (Parser f) =
    Parser <| \state ->
        case f state of
            Good v s -> Good v s
            Bad e    -> Bad (InContext { label = label, start = state.offset } e)
```

### 2.4 Error Tracking in Practice

Context stacking produces structured, nested errors:

```elm
-- Given: stream parser with nested string parser
-- Input truncated so second string fails
--> InContext { label = "stream", start = 0 }
-->   (InContext { label = "string", start = 5 }
-->     (OutOfBounds { at = 6, bytes = 4 }))
```

Each level records its starting offset, building a stack trace from outer context to inner failure point.

### 2.5 Unique Features (vs. elm/bytes)

| Feature | How |
|---------|-----|
| Structured errors | `Error context error` ADT with offset, context, custom messages |
| Backtracking | `oneOf` tries alternatives from same state |
| Context nesting | `inContext` wraps errors with labeled stack frames |
| Custom error types | Parametric `error` type in `Parser context error value` |
| Position tracking | `position` parser + `Position` type |
| Random access | `randomAccess` reads at arbitrary offset, resumes at original |
| Pipeline syntax | `keep` / `ignore` / `skip` for applicative pipelines |
| `repeat` | Convenience combinator for N repetitions |

---

## 3. mpizenberg/elm-bytes-decoder

**Version:** 1.0.0 | **License:** BSD-3-Clause | **Dependencies:** `elm/bytes`, `elm/core`
**Single exposed module:** `Bytes.Decode.Branchable`

### 3.1 Core Types

```elm
type Decoder value
    = Decoder (State -> D.Decoder ( State, value ))

type alias State =
    { input : Bytes
    , offset : Int
    }
```

The key insight: this wraps `elm/bytes` `Decoder` rather than replacing it. The state carries offset tracking *around* the standard decoder.

### 3.2 Full API

```elm
-- Running
decode : Decoder value -> Bytes -> Maybe value

-- Static
succeed : value -> Decoder value
fail    : Decoder value

-- Primitives (same set as elm/bytes)
unsignedInt8 ... signedInt32 ... float32 ... float64
string : Int -> Decoder String
bytes  : Int -> Decoder Bytes

-- Applicative
map ... map2 ... map3 ... map4 ... map5

-- Pipeline
keep   : Decoder a -> Decoder (a -> b) -> Decoder b
ignore : Decoder ignore -> Decoder keep -> Decoder keep
skip   : Int -> Decoder value -> Decoder value

-- Monadic
andThen : (a -> Decoder b) -> Decoder a -> Decoder b

-- Branching
oneOf : List (Decoder value) -> Decoder value

-- Looping
type Step state a = Loop state | Done a
loop   : state -> (state -> Decoder (Step state a)) -> Decoder a
repeat : Decoder value -> Int -> Decoder (List value)
```

### 3.3 Implementation: The Key Architectural Difference

**Primitive decoders (`fromDecoder`):**

```elm
fromDecoder : D.Decoder v -> Int -> Decoder v
fromDecoder decoder byteLength =
    Decoder <| \state ->
        D.map (\v -> ( { input = state.input, offset = state.offset + byteLength }, v ))
            decoder
```

Unlike zwilias's approach, the underlying `elm/bytes` decoder is passed through **unchanged**. No double-decoding (no `Decode.bytes offset` skip prefix). The state wrapper simply updates the offset after the elm/bytes decoder runs.

**The `oneOf` implementation — where backtracking happens:**

```elm
oneOf : List (Decoder value) -> Decoder value
oneOf options =
    Decoder <| \state ->
        oneOfHelper (dropBytes state.offset state.input) options state

oneOfHelper : Bytes -> List (Decoder value) -> State -> D.Decoder ( State, value )
oneOfHelper offsetInput options state =
    case options of
        [] -> D.fail
        decoder :: otherDecoders ->
            case runKeepState decoder offsetInput of
                Just ( newState, value ) ->
                    D.bytes newState.offset
                        |> D.map (\_ -> ( { input = state.input, offset = state.offset + newState.offset }, value ))
                Nothing ->
                    oneOfHelper offsetInput otherDecoders state
```

`runKeepState` **eagerly evaluates** each decoder option against a byte slice starting at the current offset. If it succeeds, the result is wrapped back into an elm/bytes decoder that simply advances past the consumed bytes. If it fails, the next alternative is tried with the same state.

**`dropBytes` helper:**

```elm
dropBytes : Int -> Bytes -> Bytes
dropBytes droppedCount input =
    D.decode (D.bytes droppedCount |> D.andThen (\_ -> D.bytes (Bytes.width input - droppedCount))) input
        |> Maybe.withDefault input
```

Creates a sub-slice of bytes starting at offset. This is only called in `oneOf`, not in every primitive decoder.

### 3.4 Design Philosophy

The README explicitly describes the architectural difference from zwilias/elm-bytes-parser:

> **zwilias approach:** Every decoder wraps with `Decode.map2 (always identity) (Decode.bytes state.offset) dec` — double-decoding on every primitive call.
>
> **mpizenberg approach:** Decoders are left unchanged. State wraps them. The byte-slicing cost is paid only in `oneOf` (where backtracking actually requires it).

This means:
- **Sequential decoding** has nearly zero overhead over raw elm/bytes
- **Branching (`oneOf`)** pays the cost of byte slicing, but only when needed
- The package is a **minimal bridge** between elm/bytes and backtracking capability

### 3.5 Benchmarks

The benchmarks directory compares decoding lists of 10 and 1000 floats using raw elm/bytes vs. the branchable decoder.

From the README:
> "In theory, this should result in more performant decoding. In practice, I didn't notice any significant change."

This suggests the overhead of either approach (double-decoding vs. state-wrapping) is dominated by the underlying elm/bytes kernel operations.

### 3.6 Trade-offs vs. zwilias/elm-bytes-parser

| Aspect | zwilias/elm-bytes-parser | mpizenberg/elm-bytes-decoder |
|--------|--------------------------|------------------------------|
| Error type | `Result (Error context error) value` | `Maybe value` |
| Error detail | Offset, context stack, custom messages | None (same as elm/bytes) |
| Context tracking | `inContext` with nested labels | Not available |
| Random access | `randomAccess` combinator | Not available |
| Position tracking | `position` parser + `Position` type | Not available |
| Primitive overhead | Double-decoding on every call | Minimal (pass-through) |
| Backtracking cost | Implicit (functional state discard) | Explicit (byte slicing in `oneOf`) |
| API complexity | 3 type parameters (`Parser context error value`) | 1 type parameter (`Decoder value`) |
| Return type | `Result` | `Maybe` |

---

## 4. Comparative Summary

### 4.1 Feature Matrix

| Feature | elm/bytes | zwilias/elm-bytes-parser | mpizenberg/elm-bytes-decoder |
|---------|-----------|--------------------------|------------------------------|
| Sequential decoding | Yes | Yes | Yes |
| `andThen` (monadic) | Yes | Yes | Yes |
| `map`–`map5` (applicative) | Yes | Yes | Yes |
| `keep`/`ignore` pipeline | No | Yes | Yes |
| `loop` | Yes | Yes | Yes |
| `repeat` | No | Yes | Yes |
| `oneOf` (backtracking) | **No** | Yes | Yes |
| Error messages | **No** (`Maybe`) | Yes (`Result (Error c e)`) | **No** (`Maybe`) |
| Context tracking | **No** | Yes (`inContext`) | **No** |
| Position tracking | **No** | Yes (`position`) | **No** |
| Random access | **No** | Yes (`randomAccess`) | **No** |
| Custom error types | **No** | Yes (parametric `error`) | **No** |
| `skip` combinator | **No** | Yes | Yes |
| Encoding | Yes (`Bytes.Encode`) | No | No |

### 4.2 Architectural Comparison

```
elm/bytes (Decode)
  Decoder a = Bytes -> Int -> (Int, a)
  ├── Minimal, kernel-optimized
  ├── No state wrapper — offset threading is implicit in JS
  ├── Error = throw exception → Maybe Nothing
  └── No backtracking, no branching

zwilias/elm-bytes-parser
  Parser c e a = State -> Good a State | Bad (Error c e)
  ├── Full parser combinator library
  ├── State = { offset, stack, input }
  ├── Double-decoding: skip-to-offset + decode on every primitive
  ├── Rich error ADT with context nesting
  ├── Backtracking via functional state discard in oneOf
  └── Random access via temporary offset shift + restore

mpizenberg/elm-bytes-decoder
  Decoder a = State -> D.Decoder (State, a)
  ├── Thin wrapper around elm/bytes
  ├── State = { offset, input }
  ├── Pass-through: elm/bytes decoders unchanged, state tracks offset
  ├── Error = Maybe Nothing (same as elm/bytes)
  ├── Backtracking via eager evaluation + byte slicing in oneOf only
  └── Minimal API surface — no context, no position, no random access
```

### 4.3 When to Use Which

| Use Case | Recommended |
|----------|-------------|
| Simple, known-format binary decoding | **elm/bytes** |
| Need encoding + decoding | **elm/bytes** (only one with Encode) |
| Binary format with alternatives/branches | **mpizenberg/elm-bytes-decoder** |
| Complex format requiring error diagnostics | **zwilias/elm-bytes-parser** |
| Format with offset tables / random access | **zwilias/elm-bytes-parser** |
| Embedded/constrained (minimal dependencies) | **elm/bytes** |
| Maximum decoding performance | **elm/bytes** (no wrapper overhead) |
| Development/debugging of binary parsers | **zwilias/elm-bytes-parser** (error context) |

### 4.4 Shared Design Patterns

All three libraries share:

- **Monadic composition** via `andThen` / `succeed` / `fail`
- **Applicative composition** via `map` through `map5`
- **Loop/fold** via `Step state a = Loop state | Done a`
- **Endianness as parameter** (not separate types)
- **No streaming** — all require complete input upfront
- **No mutation** — purely functional APIs
- **Built on elm/bytes kernel** — all primitive decoders ultimately use JavaScript `DataView`

### 4.5 Performance Characteristics

| Operation | elm/bytes | zwilias | mpizenberg |
|-----------|-----------|---------|------------|
| Sequential read | Optimal (kernel) | +overhead (double-decode per primitive) | +minimal (state tuple) |
| `andThen` chain | Kernel closure | State threading | State threading via D.andThen |
| `oneOf` branch | N/A | Try each, discard state on failure | Eager eval + byte slice |
| Error path | JS throw → Nothing | Construct Error ADT | JS throw → Nothing |

In practice (from mpizenberg's benchmarks), the overhead differences are negligible for typical workloads, dominated by the underlying DataView operations in the kernel.
