# Analysis of elm/bytes, Elm's Number Types, and Bitwise Limitations

## 1. Elm's Integer and Float Type System

### Int

Elm's `Int` is defined as an opaque type in `Basics.elm`. At runtime (JavaScript target), integers are IEEE 754 64-bit doubles -- there is no separate integer representation. The documented well-defined range is **-2^31 to 2^31 - 1** (32-bit signed). On the JavaScript target, some operations are safe up to ±(2^53 - 1), but this is target-dependent and not guaranteed.

Key implementation details from `Elm/Kernel/Basics.js`:

```javascript
var _Basics_idiv = F2(function(a, b) { return (a / b) | 0; });
function _Basics_truncate(n) { return n | 0; }
function _Basics_toFloat(x) { return x; }  // no-op: Int IS a JS number
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

| Function | Elm Signature | JS Operator |
|----------|--------------|-------------|
| `and` | `Int -> Int -> Int` | `a & b` |
| `or` | `Int -> Int -> Int` | `a \| b` |
| `xor` | `Int -> Int -> Int` | `a ^ b` |
| `complement` | `Int -> Int` | `~a` |
| `shiftLeftBy` | `Int -> Int -> Int` | `a << offset` |
| `shiftRightBy` | `Int -> Int -> Int` | `a >> offset` (arithmetic, sign-propagating) |
| `shiftRightZfBy` | `Int -> Int -> Int` | `a >>> offset` (logical, zero-fill) |

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

| Function | Width | Range |
|----------|-------|-------|
| `signedInt8` | 1 byte | -128 to 127 |
| `signedInt16 Endianness` | 2 bytes | -32,768 to 32,767 |
| `signedInt32 Endianness` | 4 bytes | -2,147,483,648 to 2,147,483,647 |
| `unsignedInt8` | 1 byte | 0 to 255 |
| `unsignedInt16 Endianness` | 2 bytes | 0 to 65,535 |
| `unsignedInt32 Endianness` | 4 bytes | 0 to 4,294,967,295 |
| `float32 Endianness` | 4 bytes | IEEE 754 single-precision |
| `float64 Endianness` | 8 bytes | IEEE 754 double-precision |
| `string` | variable | UTF-8 encoded |
| `bytes` | variable | raw copy |
| `sequence` | variable | list of encoders |

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
    try { return Just(A2(decoder, bytes, 0).b); }
    catch(e) { return Nothing; }
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

| Function | Elm Signature | Implementation |
|----------|--------------|----------------|
| `toCode` | `Char -> Int` | `charCodeAt(0)`, with surrogate-pair decoding for astral plane |
| `fromCode` | `Int -> Char` | `String.fromCharCode(code)`, with surrogate encoding for > 0xFFFF |
| `isHexDigit` | `Char -> Bool` | Pure Elm: checks 0x30-0x39, 0x41-0x46, 0x61-0x66 |
| `isDigit` | `Char -> Bool` | Pure Elm: checks 0x30-0x39 |

Key hex character code points:

| Char | Code (hex) | Code (dec) |
|------|-----------|------------|
| `'0'`-`'9'` | 0x30-0x39 | 48-57 |
| `'A'`-`'F'` | 0x41-0x46 | 65-70 |
| `'a'`-`'f'` | 0x61-0x66 | 97-102 |

### String Kernel Functions (Elm/Kernel/String.js)

**Concatenation:**

```javascript
var _String_append = F2(function(a, b) { return a + b; });
var _String_cons = F2(function(chr, str) { return chr + str; });
```

Simple `+` operator. No rope structure. Repeated concatenation is O(n²) in total length.

**Building strings from parts:**

```javascript
// _String_map and _String_filter both use this pattern:
var array = new Array(len);
// ... fill array ...
return array.join('');

// _String_fromList:
function _String_fromList(chars) {
    return __List_toArray(chars).join('');
}
```

The kernel consistently uses `Array.join('')` rather than repeated concatenation for building strings. This is the efficient pattern.

**Length and slicing:**

```javascript
function _String_length(str) { return str.length; }  // O(1), counts UTF-16 code units
var _String_slice = F3(function(start, end, str) { return str.slice(start, end); });
```

`String.length` returns UTF-16 code unit count, not character count. For pure-ASCII hex strings, code units = characters, so length gives the expected result.

**Folding (character iteration):**

```javascript
// foldl: iterates left-to-right
var _String_foldl = F3(function(func, state, string) {
    var len = string.length;
    var i = 0;
    while (i < len) {
        var char = string[i];
        var word = string.charCodeAt(i);
        i++;
        if (0xD800 <= word && word <= 0xDBFF) { char += string[i]; i++; }
        state = A2(func, __Utils_chr(char), state);
    }
    return state;
});
```

Each iteration calls `A2(func, __Utils_chr(char), state)` -- one Elm function application per character. For a 64-char hex string, that's 64 function calls with `__Utils_chr` wrapper allocation each time.

**Number conversion:**

```javascript
// fromInt / fromFloat:
function _String_fromNumber(number) { return number + ''; }

// toInt: manual digit-by-digit parsing
function _String_toInt(str) {
    var total = 0;
    var code0 = str.charCodeAt(0);
    var start = code0 == 0x2B || code0 == 0x2D ? 1 : 0;
    for (var i = start; i < str.length; ++i) {
        var code = str.charCodeAt(i);
        if (code < 0x30 || 0x39 < code) return __Maybe_Nothing;
        total = 10 * total + code - 0x30;
    }
    return i == start ? __Maybe_Nothing : __Maybe_Just(code0 == 0x2D ? -total : total);
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

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| `String.length` | O(1) | Code unit count = char count for ASCII |
| `String.slice i j` | O(j-i) | JS `.slice()`, allocates new string |
| `String.append a b` | O(\|a\|+\|b\|) | Simple `+`, new string allocation |
| `String.concat list` | O(total) | Uses JS `Array.join('')` |
| `String.foldl f z s` | O(n) | One Elm function call + `__Utils_chr` alloc per char |
| `String.fromList cs` | O(n) | List→Array→`.join('')` |
| `String.toList s` | O(n) | `foldr (::) []`, builds linked list right-to-left |
| `Char.toCode c` | O(1) | `charCodeAt(0)` |
| `Char.fromCode n` | O(1) | `String.fromCharCode(n)` |

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
var _Bytes_write_i8  = F3(function(mb, i, n) { mb.setInt8(i, n); return i + 1; });
var _Bytes_write_u8  = F3(function(mb, i, n) { mb.setUint8(i, n); return i + 1; });
var _Bytes_write_i16 = F4(function(mb, i, n, isLE) { mb.setInt16(i, n, isLE); return i + 2; });
var _Bytes_write_u16 = F4(function(mb, i, n, isLE) { mb.setUint16(i, n, isLE); return i + 2; });
var _Bytes_write_i32 = F4(function(mb, i, n, isLE) { mb.setInt32(i, n, isLE); return i + 4; });
var _Bytes_write_u32 = F4(function(mb, i, n, isLE) { mb.setUint32(i, n, isLE); return i + 4; });
var _Bytes_write_f32 = F4(function(mb, i, n, isLE) { mb.setFloat32(i, n, isLE); return i + 4; });
var _Bytes_write_f64 = F4(function(mb, i, n, isLE) { mb.setFloat64(i, n, isLE); return i + 8; });
```

### Bytes Copy Optimization

```javascript
var _Bytes_write_bytes = F3(function(mb, offset, bytes) {
    for (var i = 0, len = bytes.byteLength, limit = len - 4; i <= limit; i += 4)
        mb.setUint32(offset + i, bytes.getUint32(i));
    for (; i < len; i++)
        mb.setUint8(offset + i, bytes.getUint8(i));
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
        width += (code < 0x80) ? 1 : (code < 0x800) ? 2 :
                 (code < 0xD800 || 0xDBFF < code) ? 3 : (i++, 4);
    }
    return width;
}
```

The write function encodes each code point as 1-4 UTF-8 bytes using `setUint8`/`setUint16`/`setUint32` directly on the DataView.

### Decode Flow

```javascript
var _Bytes_decode = F2(function(decoder, bytes) {
    try { return __Maybe_Just(A2(decoder, bytes, 0).b); }
    catch(e) { return __Maybe_Nothing; }
});
```

A decoder is `(DataView, offset) -> (newOffset, value)`. Out-of-bounds reads throw JS exceptions, caught by the top-level `decode` which returns `Nothing`.

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
