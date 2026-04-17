# Analysis of elm/bytes, Elm's Number Types, and Bitwise Limitations

## 1. Elm's Integer and Float Type System

### Int

Elm's `Int` is defined as an opaque type in `Basics.elm`. At runtime (JavaScript target), integers are IEEE 754 64-bit doubles -- there is no separate integer representation. The documented well-defined range is **-2^31 to 2^31 - 1** (32-bit signed). On the JavaScript target, some operations are safe up to ±(2^53 - 1), but this is target-dependent and not guaranteed.

Key implementation details from `Elm/Kernel/Basics.js`:

```javascript
var _Basics_idiv = F2(function (a, b) {
  return (a / b) | 0;
});
function _Basics_truncate(n) {
  return n | 0;
}
function _Basics_toFloat(x) {
  return x;
} // no-op: Int IS a JS number
```

Integer division uses `| 0` to truncate the floating-point result back to a 32-bit signed integer. The `toFloat` conversion is a no-op because both types are JavaScript numbers internally.

### Float

Elm's `Float` follows IEEE 754 double-precision (64-bit). It supports `NaN` and `Infinity`. All math operations delegate directly to JavaScript's `Math` object. There is no single-precision float type at the language level.

### Implications

- Elm has **no 64-bit integer type**. The `Int` type is semantically 32-bit.
- Conversion between Int and Float is explicit (`toFloat`, `round`, `floor`, `ceiling`, `truncate`), even though both are JavaScript doubles at runtime.
- Integers beyond 2^31 - 1 silently become imprecise or wrap depending on the operation.

---

## 2. Bitwise Module

### API

All functions in `Bitwise.elm`, implemented in `Elm/Kernel/Bitwise.js`:

| Function         | Elm Signature       | JS Operator                                  |
| ---------------- | ------------------- | -------------------------------------------- |
| `and`            | `Int -> Int -> Int` | `a & b`                                      |
| `or`             | `Int -> Int -> Int` | `a \| b`                                     |
| `xor`            | `Int -> Int -> Int` | `a ^ b`                                      |
| `complement`     | `Int -> Int`        | `~a`                                         |
| `shiftLeftBy`    | `Int -> Int -> Int` | `a << offset`                                |
| `shiftRightBy`   | `Int -> Int -> Int` | `a >> offset` (arithmetic, sign-propagating) |
| `shiftRightZfBy` | `Int -> Int -> Int` | `a >>> offset` (logical, zero-fill)          |

### Limitations

1. **32-bit only**: All JavaScript bitwise operators implicitly convert operands to 32-bit signed integers. There is no way to perform 64-bit bitwise operations.

2. **No rotation operators**: There are no `rotateLeft` or `rotateRight` functions.

3. **Signed semantics**: `shiftRightZfBy` (the `>>>` operator) returns an **unsigned** 32-bit result, but Elm treats it as a signed `Int`. For example: `-32 |> shiftRightZfBy 1 == 2147483632`. This creates a value outside the documented Int range.

4. **No bit counting**: No `popcount`, `clz` (count leading zeros), or `ctz` (count trailing zeros).

5. **No byte-level extraction**: No built-in way to extract individual bytes from an integer.

---

## 3. elm/bytes Package

### Overview

Package `elm/bytes` v1.0.8 exposes three modules: `Bytes`, `Bytes.Encode`, and `Bytes.Decode`. Internally, bytes are JavaScript `DataView` objects wrapping `ArrayBuffer`.

### Bytes Type

```elm
type Bytes = Bytes          -- opaque; backed by JS DataView
type Endianness = LE | BE   -- explicit in all multi-byte operations

width : Bytes -> Int
getHostEndianness : Task x Endianness
```

Host endianness is detected at runtime by writing a `Uint32Array([1])` and reading it back as `Uint8Array`.

### Encoding API

| Function                   | Width    | Range                           |
| -------------------------- | -------- | ------------------------------- |
| `signedInt8`               | 1 byte   | -128 to 127                     |
| `signedInt16 Endianness`   | 2 bytes  | -32,768 to 32,767               |
| `signedInt32 Endianness`   | 4 bytes  | -2,147,483,648 to 2,147,483,647 |
| `unsignedInt8`             | 1 byte   | 0 to 255                        |
| `unsignedInt16 Endianness` | 2 bytes  | 0 to 65,535                     |
| `unsignedInt32 Endianness` | 4 bytes  | 0 to 4,294,967,295              |
| `float32 Endianness`       | 4 bytes  | IEEE 754 single-precision       |
| `float64 Endianness`       | 8 bytes  | IEEE 754 double-precision       |
| `string`                   | variable | UTF-8 encoded                   |
| `bytes`                    | variable | raw copy                        |
| `sequence`                 | variable | list of encoders                |

The `Encoder` type is a tagged union:

```elm
type Encoder
    = I8 Int | I16 Endianness Int | I32 Endianness Int
    | U8 Int | U16 Endianness Int | U32 Endianness Int
    | F32 Endianness Float | F64 Endianness Float
    | Seq Int (List Encoder) | Utf8 Int String | Bytes Bytes
```

The `Seq` variant stores a pre-calculated total width, allowing `encode` to allocate the `ArrayBuffer` in a single allocation with no resizing.

### Decoding API

```elm
type Decoder a = Decoder (Bytes -> Int -> (Int, a))
```

A decoder is a function from `(Bytes, offset)` to `(newOffset, value)`. Decoding integer/float types mirrors encoding. Combinators include `map`, `map2`..`map5`, `andThen`, `succeed`, `fail`, and `loop`. Out-of-bounds reads throw JS exceptions caught by the top-level `decode`:

```javascript
function _Bytes_decode(decoder, bytes) {
  try {
    return Just(A2(decoder, bytes, 0).b);
  } catch (e) {
    return Nothing;
  }
}
```

### Key Design Choices

- **Endianness is always explicit** for multi-byte values. No default byte order.
- **Pre-computed widths** avoid buffer reallocations during encoding.
- **Bytes copy optimization**: copies 4 bytes at a time via `setUint32`, then handles the remainder byte-by-byte.
- **UTF-8 width calculation**: handles surrogate pairs correctly, counting 1/2/3/4 bytes per code point.

### Limitations

1. **No 64-bit integer encoding/decoding**: Maximum integer width is 32 bits. There is no `signedInt64` or `unsignedInt64`.
2. **No variable-length integer encoding**: Protocols using varint (protobuf, etc.) must implement custom encoding.
3. **No bit-level access**: Cannot read/write individual bits or sub-byte fields.
4. **No float16**: Only 32-bit and 64-bit floats.

---

## 4. String and Char Handling

### Runtime Representation

Elm strings are JavaScript strings -- UTF-16 encoded, immutable, with no rope or tree structure. `Char` is a JS string of length 1 (or 2 for astral-plane characters via surrogate pairs). Since hex digits are ASCII, surrogate pair handling is irrelevant for this library but shapes the kernel code.

### Char API (Char.elm + Char.js)

| Function     | Elm Signature  | Implementation                                                    |
| ------------ | -------------- | ----------------------------------------------------------------- |
| `toCode`     | `Char -> Int`  | `charCodeAt(0)`, with surrogate-pair decoding for astral plane    |
| `fromCode`   | `Int -> Char`  | `String.fromCharCode(code)`, with surrogate encoding for > 0xFFFF |
| `isHexDigit` | `Char -> Bool` | Pure Elm: checks 0x30-0x39, 0x41-0x46, 0x61-0x66                  |
| `isDigit`    | `Char -> Bool` | Pure Elm: checks 0x30-0x39                                        |

Key hex character code points:

| Char        | Code (hex) | Code (dec) |
| ----------- | ---------- | ---------- |
| `'0'`-`'9'` | 0x30-0x39  | 48-57      |
| `'A'`-`'F'` | 0x41-0x46  | 65-70      |
| `'a'`-`'f'` | 0x61-0x66  | 97-102     |

### String Kernel Functions (Elm/Kernel/String.js)

**Concatenation:**

```javascript
var _String_append = F2(function (a, b) {
  return a + b;
});
var _String_cons = F2(function (chr, str) {
  return chr + str;
});
```

Simple `+` operator. No rope structure. Repeated concatenation is O(n²) in total length.

**Building strings from parts:**

```javascript
// _String_map and _String_filter both use this pattern:
var array = new Array(len);
// ... fill array ...
return array.join("");

// _String_fromList:
function _String_fromList(chars) {
  return __List_toArray(chars).join("");
}
```

The kernel consistently uses `Array.join('')` rather than repeated concatenation for building strings. This is the efficient pattern.

**Length and slicing:**

```javascript
function _String_length(str) {
  return str.length;
} // O(1), counts UTF-16 code units
var _String_slice = F3(function (start, end, str) {
  return str.slice(start, end);
});
```

`String.length` returns UTF-16 code unit count, not character count. For pure-ASCII hex strings, code units = characters, so length gives the expected result.

**Folding (character iteration):**

```javascript
// foldl: iterates left-to-right
var _String_foldl = F3(function (func, state, string) {
  var len = string.length;
  var i = 0;
  while (i < len) {
    var char = string[i];
    var word = string.charCodeAt(i);
    i++;
    if (0xd800 <= word && word <= 0xdbff) {
      char += string[i];
      i++;
    }
    state = A2(func, __Utils_chr(char), state);
  }
  return state;
});
```

Each iteration calls `A2(func, __Utils_chr(char), state)` -- one Elm function application per character. For a 64-char hex string, that's 64 function calls with `__Utils_chr` wrapper allocation each time.

**Number conversion:**

```javascript
// fromInt / fromFloat:
function _String_fromNumber(number) {
  return number + "";
}

// toInt: manual digit-by-digit parsing
function _String_toInt(str) {
  var total = 0;
  var code0 = str.charCodeAt(0);
  var start = code0 == 0x2b || code0 == 0x2d ? 1 : 0;
  for (var i = start; i < str.length; ++i) {
    var code = str.charCodeAt(i);
    if (code < 0x30 || 0x39 < code) return __Maybe_Nothing;
    total = 10 * total + code - 0x30;
  }
  return i == start
    ? __Maybe_Nothing
    : __Maybe_Just(code0 == 0x2d ? -total : total);
}
```

`String.toInt` does manual character-by-character decimal parsing. There is no built-in hex integer parsing.

**List conversions:**

```elm
-- String.elm
toList string = foldr (::) [] string    -- uses foldr, so right-to-left
fromList = Elm.Kernel.String.fromList   -- kernel: toArray(chars).join('')
```

`toList` converts a string to `List Char` by folding right, consing each character. `fromList` converts the Elm list to a JS array then joins.

### Performance Characteristics for Hex Strings

| Operation            | Complexity     | Notes                                                |
| -------------------- | -------------- | ---------------------------------------------------- |
| `String.length`      | O(1)           | Code unit count = char count for ASCII               |
| `String.slice i j`   | O(j-i)         | JS `.slice()`, allocates new string                  |
| `String.append a b`  | O(\|a\|+\|b\|) | Simple `+`, new string allocation                    |
| `String.concat list` | O(total)       | Uses JS `Array.join('')`                             |
| `String.foldl f z s` | O(n)           | One Elm function call + `__Utils_chr` alloc per char |
| `String.fromList cs` | O(n)           | List→Array→`.join('')`                               |
| `String.toList s`    | O(n)           | `foldr (::) []`, builds linked list right-to-left    |
| `Char.toCode c`      | O(1)           | `charCodeAt(0)`                                      |
| `Char.fromCode n`    | O(1)           | `String.fromCharCode(n)`                             |

### Implications for a Hex-String-Backed Bytes Type

1. **String as backing store**: A hex string "0a1b2c" stores 3 bytes in 6 characters. Each byte is 2 hex chars. For N bytes, the string has 2N characters.

2. **Byte access via slicing**: Extract byte at index `i` with `String.slice (2*i) (2*i+2)`. This is O(1) amortized in JS engines with string slicing optimizations.

3. **Building hex strings**: Prefer collecting parts into a list and using `String.concat` (which maps to `Array.join('')`) over repeated `String.append`. The kernel uses this pattern internally for good reason.

4. **Hex digit ↔ nibble conversion**: Must be implemented manually. `Char.toCode` and `Char.fromCode` provide the bridge. Arithmetic: `code - 0x30` for digits, `code - 0x57` for lowercase a-f, `code - 0x37` for uppercase A-F.

5. **No built-in hex parsing**: `String.toInt` only handles decimal. Hex parsing must be hand-rolled using `Char.toCode` and bitwise/arithmetic operations.

6. **Validation**: `Char.isHexDigit` is available in core for validating hex characters.

---

## 5. elm/bytes Kernel: Encoding and Decoding Internals

### Encode Flow

```javascript
function _Bytes_encode(encoder) {
  var mutableBytes = new DataView(new ArrayBuffer(__Encode_getWidth(encoder)));
  __Encode_write(encoder)(mutableBytes)(0);
  return mutableBytes;
}
```

1. `getWidth` traverses the `Encoder` tree to compute total byte count.
2. A single `ArrayBuffer` is allocated with that exact size.
3. `write` fills the buffer in one pass. No resizing.

### Writer Functions

All writers take `(DataView, offset, value[, isLE])` and return the new offset:

```javascript
var _Bytes_write_i8 = F3(function (mb, i, n) {
  mb.setInt8(i, n);
  return i + 1;
});
var _Bytes_write_u8 = F3(function (mb, i, n) {
  mb.setUint8(i, n);
  return i + 1;
});
var _Bytes_write_i16 = F4(function (mb, i, n, isLE) {
  mb.setInt16(i, n, isLE);
  return i + 2;
});
var _Bytes_write_u16 = F4(function (mb, i, n, isLE) {
  mb.setUint16(i, n, isLE);
  return i + 2;
});
var _Bytes_write_i32 = F4(function (mb, i, n, isLE) {
  mb.setInt32(i, n, isLE);
  return i + 4;
});
var _Bytes_write_u32 = F4(function (mb, i, n, isLE) {
  mb.setUint32(i, n, isLE);
  return i + 4;
});
var _Bytes_write_f32 = F4(function (mb, i, n, isLE) {
  mb.setFloat32(i, n, isLE);
  return i + 4;
});
var _Bytes_write_f64 = F4(function (mb, i, n, isLE) {
  mb.setFloat64(i, n, isLE);
  return i + 8;
});
```

### Bytes Copy Optimization

```javascript
var _Bytes_write_bytes = F3(function (mb, offset, bytes) {
  for (var i = 0, len = bytes.byteLength, limit = len - 4; i <= limit; i += 4)
    mb.setUint32(offset + i, bytes.getUint32(i));
  for (; i < len; i++) mb.setUint8(offset + i, bytes.getUint8(i));
  return offset + len;
});
```

Copies 4 bytes at a time via `setUint32`, then handles the remainder byte-by-byte.

### UTF-8 String Encoding in Bytes

```javascript
// Width calculation: 1/2/3/4 bytes per code point
function _Bytes_getStringWidth(string) {
  for (var width = 0, i = 0; i < string.length; i++) {
    var code = string.charCodeAt(i);
    width +=
      code < 0x80
        ? 1
        : code < 0x800
          ? 2
          : code < 0xd800 || 0xdbff < code
            ? 3
            : (i++, 4);
  }
  return width;
}
```

The write function encodes each code point as 1-4 UTF-8 bytes using `setUint8`/`setUint16`/`setUint32` directly on the DataView.

### Decode Flow

```javascript
var _Bytes_decode = F2(function (decoder, bytes) {
  try {
    return __Maybe_Just(A2(decoder, bytes, 0).b);
  } catch (e) {
    return __Maybe_Nothing;
  }
});
```

A decoder is `(DataView, offset) -> (newOffset, value)`. Out-of-bounds reads throw JS exceptions, caught by the top-level `decode` which returns `Nothing`.

---

## 6. elm-cardano/bytes-decoder Package

### Overview

`elm-cardano/bytes-decoder` (v1.1.0, BSD-3-Clause) is a drop-in replacement for `Bytes.Decode` that adds structured error reporting, `oneOf` backtracking, and random access while maintaining near-zero overhead on the happy path. It exposes a single module `Bytes.Decoder` and depends on `elm/bytes`, `elm/core`, and `elm-cardano/float16`.

### Core Architecture: Dual-Path Decoding

The central design is a decoder that carries **two execution strategies**:

```elm
type Decoder context error value
    = Decoder (Maybe (Decode.Decoder value)) (State -> DecodeResult context error value)

type DecodeResult context error value
    = Good value State
    | Bad (Error context error)

type alias State =
    { offset : Int
    , input : Bytes
    }
```

1. **Fast path** — an optional raw `Bytes.Decode.Decoder` composed via `Decode.map2`, `Decode.andThen`, `Decode.loop`, etc. When present, `decode` executes a single `Decode.decode` call through the JS kernel with zero per-step overhead.

2. **Slow path** — a state-passing function that tracks byte offsets, reports structured errors, and supports backtracking. Only executed when the fast path is absent or returns `Nothing` (i.e. an error occurred).

The entry point tries the fast path first and falls back on failure:

```elm
decode : Decoder context error value -> Bytes -> Result (Error context error) value
decode (Decoder maybeDec slow) input =
    case maybeDec of
        Just dec ->
            case Decode.decode dec input of
                Just v -> Ok v
                Nothing -> decodeSlow slow input
        Nothing ->
            decodeSlow slow input
```

The key insight: most decoders succeed on well-formed input. By deferring error tracking to a re-decode, the happy path pays no cost for error reporting.

### Error Type

```elm
type Error context error
    = InContext { label : context, start : Int } (Error context error)
    | OutOfBounds { at : Int, bytes : Int }
    | Custom { at : Int } error
    | BadOneOf { at : Int } (List (Error context error))
```

Both `context` and `error` are user-chosen type parameters, allowing custom context labels and custom error payloads. The recursive `InContext` variant creates a context stack from outer to inner failure point.

### Primitive Decoders

All primitives delegate to `elm/bytes` decoders and have fast paths:

```elm
unsignedInt8 : Decoder context error Int
unsignedInt16 : Bytes.Endianness -> Decoder context error Int
unsignedInt32 : Bytes.Endianness -> Decoder context error Int
signedInt8 : Decoder context error Int
signedInt16 : Bytes.Endianness -> Decoder context error Int
signedInt32 : Bytes.Endianness -> Decoder context error Int
float16 : Bytes.Endianness -> Decoder context error Float  -- via elm-cardano/float16
float32 : Bytes.Endianness -> Decoder context error Float
float64 : Bytes.Endianness -> Decoder context error Float
bytes : Int -> Decoder context error Bytes
string : Int -> Decoder context error String
```

All are built with a shared `fromInnerDecoder` helper:

```elm
fromInnerDecoder : Decode.Decoder v -> Int -> Decoder context error v
fromInnerDecoder dec byteLength =
    Decoder
        (Just dec)
        (\state ->
            let combined = Decode.map2 (\_ v -> v) (Decode.bytes state.offset) dec
            in
            case Decode.decode combined state.input of
                Just res -> Good res { offset = state.offset + byteLength, input = state.input }
                Nothing -> Bad (OutOfBounds { at = state.offset, bytes = byteLength })
        )
```

The slow path skips to the current offset (via `Decode.bytes state.offset`), decodes, and reports `OutOfBounds` on failure.

### Combinators and Fast-Path Preservation

| Combinator                      | Fast Path   | Notes                                                                                         |
| ------------------------------- | ----------- | --------------------------------------------------------------------------------------------- |
| `succeed`, `map`, `map2`–`map5` | Always      | Composed via `Decode.map`, `Decode.map2`, etc.                                                |
| `keep`, `ignore`, `skip`        | Conditional | Fast if both operands are fast                                                                |
| `andThen`                       | Conditional | Fast if callback returns a decoder with a fast path                                           |
| `loop`, `repeat`                | Conditional | `loop` uses `Decode.loop` (tight JS while loop); stays fast if callback returns fast decoders |
| `fail`                          | Never       | No value can be produced; forces slow path                                                    |
| `oneOf`                         | Never       | Requires backtracking, which `Bytes.Decode` cannot do                                         |
| `position`, `randomAccess`      | Never       | Offset tracking requires slow path state                                                      |
| `inContext`                     | Preserved   | Wraps error only on failure; fast path passed through unchanged                               |

The `map2` implementation illustrates the pattern — compose fast paths when both exist, otherwise drop to slow:

```elm
map2 f (Decoder maybeDecX slowX) (Decoder maybeDecY slowY) =
    Decoder
        (case ( maybeDecX, maybeDecY ) of
            ( Just decX, Just decY ) -> Just (Decode.map2 f decX decY)
            _ -> Nothing
        )
        (\state ->
            case slowX state of
                Good x s1 ->
                    case slowY s1 of
                        Good y s2 -> Good (f x y) s2
                        Bad e -> Bad e
                Bad e -> Bad e
        )
```

### Pipeline API

Applicative-style pipeline combinators for sequential decoding:

```elm
keep : Decoder context error a -> Decoder context error (a -> b) -> Decoder context error b
ignore : Decoder context error ignore -> Decoder context error keep -> Decoder context error keep
skip : Int -> Decoder context error value -> Decoder context error value
```

Usage:

```elm
succeed MyRecord
    |> keep unsignedInt8
    |> keep (unsignedInt16 BE)
    |> ignore unsignedInt8
    |> keep (bytes 4)
```

### Backtracking with oneOf

```elm
oneOf : List (Decoder context error value) -> Decoder context error value
```

All alternatives receive the **same state** (same offset). On failure, the error is collected but state is not carried forward. Returns the first success or a `BadOneOf` containing all sub-errors.

### Random Access

```elm
type Position
position : Decoder context error Position
startOfInput : Position
randomAccess : { offset : Int, relativeTo : Position } -> Decoder context error value -> Decoder context error value
```

`randomAccess` decodes at an absolute offset (`relativeTo + offset`) then **restores the original state** — sequential parsing resumes where it was before the jump.

### Escape Hatch

```elm
fromDecoderUnsafe : error -> Int -> Decode.Decoder value -> Decoder context error value
```

Wraps a raw `Bytes.Decode.Decoder` with error reporting. The caller must provide the **exact** byte width; incorrect width corrupts offset tracking. Only safe for fixed-width decoders.

### Performance Characteristics

Benchmarks from the package (48-byte applicative packet, 57-byte dynamic message):

| Implementation              | Applicative Packet  | Dynamic Message     |
| --------------------------- | ------------------- | ------------------- |
| `elm/bytes` (baseline)      | 822 ns/run          | 509 ns/run          |
| `elm-cardano/bytes-decoder` | 869 ns/run (+5%)    | 756 ns/run (+49%)   |
| `zwilias/elm-bytes-parser`  | 3452 ns/run (+320%) | 2949 ns/run (+480%) |

The +5% overhead for pure applicative decoding comes from the thin `Decoder` wrapper. The +49% for `andThen` + `loop` is higher because conditional fast-path checks add branching, but still well under alternatives.

### Comparison to elm/bytes and Alternatives

| Feature                | elm/bytes         | elm-cardano/bytes-decoder | zwilias/elm-bytes-parser |
| ---------------------- | ----------------- | ------------------------- | ------------------------ |
| Sequential decode      | Yes               | Yes                       | Yes                      |
| Applicative (map2–5)   | Yes               | Yes                       | Yes                      |
| Monadic (andThen)      | Yes               | Yes                       | Yes                      |
| Loop/repeat            | Yes               | Yes                       | Yes                      |
| Backtracking (oneOf)   | No                | Yes                       | Yes                      |
| Error reporting        | `Maybe` (no info) | Rich ADT with offsets     | Rich ADT with offsets    |
| Error context nesting  | No                | Yes                       | Yes                      |
| Position tracking      | No                | Yes                       | Yes                      |
| Random access          | No                | Yes                       | Yes                      |
| Pipeline (keep/ignore) | No                | Yes                       | Yes                      |
| float16 support        | No                | Yes                       | No                       |
| Happy path overhead    | 0%                | +5–50%                    | +300–480%                |

### Implications for the CBOR Library

1. **Decoder foundation**: `elm-cardano/bytes-decoder` is a strong candidate as the decoding foundation for `Cbor.Decode`. Its combinator API mirrors `elm/json` patterns (which is the design goal from `design.md`), and its `andThen` + `loop` performance is acceptable for CBOR's tag-dispatched, length-prefixed structure.

2. **Error reporting**: CBOR decoding benefits from structured errors. The `inContext` mechanism maps naturally to CBOR's nested structure (e.g., `InContext "map key 3"`, `InContext "tag 24 payload"`). The `context` type parameter can be specialized to a CBOR-specific context type.

3. **No 64-bit integers**: Like `elm/bytes`, there is no `unsignedInt64` or `signedInt64`. CBOR's 64-bit integer arguments (additional info 27) must still be handled by reading two 32-bit words or 8 individual bytes, consistent with the constraints described in Section 3 above.

4. **float16 support**: The `float16` decoder (via `elm-cardano/float16`) directly covers CBOR major type 7 half-precision floats (additional info 25), eliminating the need for a custom implementation.

5. **No encoding**: The package only covers decoding. `Cbor.Encode` will still build on `Bytes.Encode` from `elm/bytes` directly.

6. **oneOf for CBOR**: While `oneOf` has no fast path, it maps to CBOR's tag-dispatched decoding pattern. However, explicit `andThen`-based tag dispatch (read tag byte, then branch) is both faster and more natural for CBOR's wire format — `oneOf` is better reserved for genuinely ambiguous formats.

7. **Random access**: Potentially useful for CBOR's tag 24 (encoded CBOR data item embedded in a byte string), where the decoder may need to jump into a nested byte string payload.

---

## References

- `/Users/piz/git/elm/core/src/Basics.elm` -- Int and Float type definitions
- `/Users/piz/git/elm/core/src/Bitwise.elm` -- Bitwise operations API
- `/Users/piz/git/elm/core/src/Elm/Kernel/Basics.js` -- JS implementation of arithmetic
- `/Users/piz/git/elm/core/src/Elm/Kernel/Bitwise.js` -- JS implementation of bitwise ops
- `/Users/piz/git/elm/bytes/src/Bytes.elm` -- Bytes type and endianness
- `/Users/piz/git/elm/bytes/src/Bytes/Encode.elm` -- Encoder API
- `/Users/piz/git/elm/bytes/src/Bytes/Decode.elm` -- Decoder API
- `/Users/piz/git/elm/bytes/src/Elm/Kernel/Bytes.js` -- JS implementation of byte operations
- `/Users/piz/git/elm/core/src/String.elm` -- String public API
- `/Users/piz/git/elm/core/src/Elm/Kernel/String.js` -- JS implementation of string operations
- `/Users/piz/git/elm/core/src/Char.elm` -- Char type and classification functions
- `/Users/piz/git/elm/core/src/Elm/Kernel/Char.js` -- JS implementation of Char operations
