# CBOR Elm Package: Design Decisions

## Data Model

### Design Goal: Lossless Representation

The `CborItem` type is designed to be a **lossless representation** of any well-formed CBOR encoding. This means:

- Round-tripping (decode → re-encode) preserves the exact original bytes
- Encoding details (integer width, float precision, definite vs indefinite length) are captured
- Diagnostic notation (RFC 8949 Section 8) can be faithfully produced, including encoding indicators (`1_0`, `1.5_1`, `[_ ...]`, etc.)
- Debugging and inspection tools can show exactly what's on the wire

This comes at the cost of a more complex type, but the primary user-facing API is the combinator layer (see Module Structure below), which hides this complexity. `CborItem` serves as the lossless escape hatch for generic CBOR handling, diagnostics, and protocol debugging.

### CborItem Type

```elm
type CborItem
    = CborInt52 IntWidth Int
    | CborInt64 Sign Bytes
    | CborByteString Bytes
    | CborByteStringChunked (List Bytes)
    | CborString String
    | CborStringChunked (List String)
    | CborArray Length (List CborItem)
    | CborMap Length (List { key : CborItem, value : CborItem })
    | CborTag Tag CborItem
    | CborBool Bool
    | CborFloat FloatWidth Float
    | CborNull
    | CborUndefined
    | CborSimple SimpleWidth Int
```

### Encoding Width Types

These types preserve how a value was encoded on the wire, enabling lossless round-tripping and accurate diagnostic notation with encoding indicators.

```elm
type IntWidth
    = IW0   -- inline (additional info 0-23, 0 extra bytes)
    | IW8   -- 1-byte uint8 argument
    | IW16  -- 2-byte uint16 argument
    | IW32  -- 4-byte uint32 argument
    | IW64  -- 8-byte uint64 argument


type FloatWidth
    = FW16  -- IEEE 754 half-precision (2 bytes)
    | FW32  -- IEEE 754 single-precision (4 bytes)
    | FW64  -- IEEE 754 double-precision (8 bytes)


type SimpleWidth
    = SW0   -- inline (additional info 0-19, 0 extra bytes)
    | SW8   -- 1-byte argument (values 32-255)
```

For deterministic encoding, the width is ignored and the shortest form is always used. The width is only relevant for lossless round-tripping and diagnostic output.

### Length Type

```elm
type Length
    = Definite
    | Indefinite
```

Distinguishes definite-length arrays/maps from indefinite-length (terminated by break code `0xFF`). In diagnostic notation: `[1, 2]` vs `[_ 1, 2]`.

Arrays and maps use a `Length` parameter because their structure (list of items) is the same either way — only the wire encoding differs.

Byte strings and text strings need separate variants (`CborByteString` vs `CborByteStringChunked`) because indefinite-length changes the structure: a single value vs a list of chunks.

### Integer Representation

Two variants cover the full CBOR integer range (-2^64 to 2^64-1):

- **`CborInt52 IntWidth Int`**: Covers -2^52 to 2^52-1. This is the common case — native Elm `Int`, full arithmetic, comparison, and equality. Comfortably within JavaScript's safe integer range. The `IntWidth` records the original encoding width.

- **`CborInt64 Sign Bytes`**: Covers values outside the CborInt52 range but within CBOR's 64-bit range. `Sign` indicates the CBOR major type (positive = major type 0, negative = major type 1). `Bytes` stores the 8-byte big-endian unsigned CBOR argument. Always encoded with additional info 27 (IW64) by definition, so no width parameter is needed.

  Encode/decode is zero-conversion: the `Sign` maps directly to the major type, and the `Bytes` are the raw wire argument.

  This avoids the unsigned-in-signed footgun of storing two 32-bit Ints, and is consistent with `Bytes` appearing elsewhere in the data model (CborByteString).

### Sign Type

```elm
type Sign
    = Positive  -- CBOR major type 0
    | Negative  -- CBOR major type 1
```

For CborInt64, the mapping to values is:
- `CborInt64 Positive bytes`: value = argument (decoded from bytes)
- `CborInt64 Negative bytes`: value = -1 - argument (decoded from bytes)

### Float Representation

`CborFloat FloatWidth Float` carries the decoded value (always Elm's 64-bit `Float`) plus the original encoding width. On decode, all floats widen to `Float`. On lossless re-encode, the `FloatWidth` determines the output width. On deterministic encode, the shortest form that preserves the value is used regardless of `FloatWidth`.

Elm has no float16 type, but decode/encode only requires converting between 16-bit IEEE 754 and 64-bit IEEE 754 via bitwise arithmetic on the half-precision sign/exponent/mantissa fields.

### Simple Values

`CborSimple SimpleWidth Int` covers CBOR simple values in the range 0-255, excluding:
- 20 (false) → `CborBool False`
- 21 (true) → `CborBool True`
- 22 (null) → `CborNull`
- 23 (undefined) → `CborUndefined`

Most simple values are unassigned in the IANA registry but are valid CBOR. The `CborSimple` variant ensures the decoder can handle any well-formed CBOR without failing.

`SW0` covers inline values (additional info 0-19), `SW8` covers 1-byte argument values (32-255). Values 24-31 in the additional info are reserved and not well-formed.

### Tag Type

```elm
type Tag
    = StandardDateTime
    | EpochDateTime
    | PositiveBigNum
    | NegativeBigNum
    | DecimalFraction
    | BigFloat
    | Base64UrlConversion
    | Base64Conversion
    | Base16Conversion
    | Cbor
    | Uri
    | Base64Url
    | Base64
    | Regex
    | Mime
    | IsCbor
    | Unknown Int
```

Named variants for well-known IANA-registered tags. `Unknown Int` as the catch-all for unrecognized tag numbers.

### Map Representation

Maps use `List { key : CborItem, value : CborItem }` rather than `Dict`:
- CBOR map keys can be any type, not just `comparable`
- Preserves insertion order, which matters for round-tripping and deterministic encoding
- Record fields (`key`, `value`) are more readable than tuples

### Equality and Comparison

`CborItem` is not `comparable` in Elm's type system due to `Bytes` (no structural equality/ordering). For deterministic encoding, map key sorting is implemented by comparing the encoded CBOR byte representations — encoding each key and comparing byte-by-byte. This is correct per RFC 8949 Section 4.2.1 (length-first lexicographic order of encoded forms).

## Module Structure

```
Cbor               -- CborItem type, diagnostic notation
Cbor.Encode        -- combinators for encoding domain types to CBOR bytes
Cbor.Decode        -- combinators for decoding CBOR bytes to domain types
```

### Dependencies

- `elm/bytes` — `Bytes` type, `Bytes.Encode.Encoder` (used directly as the encoding type)
- `elm-cardano/bytes-decoder` — `Bytes.Decoder.Decoder` and `Bytes.Decoder.Error` (used directly as the decoding types)
- `elm-cardano/float16` — float16 ↔ float64 conversion for `CborFloat FW16`

### Encoder and Decoder Types

Encoding uses `Bytes.Encode.Encoder` from `elm/bytes` directly — no custom wrapper type.

Decoding uses `Bytes.Decoder.Decoder context error value` from `elm-cardano/bytes-decoder` directly. Users call `Bytes.Decoder.decode` to run decoders. The `context` and `error` type parameters remain polymorphic in all `Cbor.Decode` combinators.

### Error Handling

Decoding errors use `elm-cardano/bytes-decoder`'s error type:

```elm
type Error context error
    = InContext { label : context, start : Int } (Error context error)
    | OutOfBounds { at : Int, bytes : Int }
    | Custom { at : Int } error
    | BadOneOf { at : Int } (List (Error context error))
```

CBOR-specific errors (wrong major type, value out of range, malformed encoding) are reported via `fail` inside `andThen` chains. The error type is the caller's choice — the library is polymorphic over both `context` and `error` throughout.

### Encoding Combinators

```elm
-- Primitives (deterministic: shortest encoding form)
Cbor.Encode.int : Int -> Encoder
Cbor.Encode.float : Float -> Encoder
Cbor.Encode.bool : Bool -> Encoder
Cbor.Encode.null : Encoder
Cbor.Encode.undefined : Encoder
Cbor.Encode.string : String -> Encoder
Cbor.Encode.bytes : Bytes -> Encoder
Cbor.Encode.simple : Int -> Encoder

-- Collections
Cbor.Encode.array : List Encoder -> Encoder
Cbor.Encode.map : List ( Encoder, Encoder ) -> Encoder
Cbor.Encode.tag : Tag -> Encoder -> Encoder

-- Convenience
Cbor.Encode.list : (a -> Encoder) -> List a -> Encoder

-- Escape hatch (lossless: respects stored widths and entry order)
Cbor.Encode.item : CborItem -> Encoder
```

### Decoding Combinators

```elm
-- Primitives
Cbor.Decode.int : Decoder ctx err Int           -- major types 0, 1; safe range only (±2^52)
Cbor.Decode.float : Decoder ctx err Float       -- major type 7, additional info 25/26/27
Cbor.Decode.bool : Decoder ctx err Bool         -- 0xf4 (false), 0xf5 (true)
Cbor.Decode.null : a -> Decoder ctx err a       -- 0xf6; returns the provided value
Cbor.Decode.string : Decoder ctx err String     -- major type 3
Cbor.Decode.bytes : Decoder ctx err Bytes       -- major type 2

-- Collections
Cbor.Decode.array : Decoder ctx err a -> Decoder ctx err (List a)
Cbor.Decode.keyValue : Decoder ctx err k -> Decoder ctx err v -> Decoder ctx err (List ( k, v ))
Cbor.Decode.field : k -> Decoder ctx err k -> Decoder ctx err v -> Decoder ctx err v
Cbor.Decode.tag : Tag -> Decoder ctx err a -> Decoder ctx err a

-- Structure headers (for heterogeneous structures)
Cbor.Decode.arrayHeader : Decoder ctx err Int
Cbor.Decode.mapHeader : Decoder ctx err Int

-- Escape hatch
Cbor.Decode.item : Decoder ctx err CborItem
```

Composition combinators (`succeed`, `fail`, `andThen`, `oneOf`, `map`, `map2`–`map5`, `keep`, `ignore`, `loop`, `repeat`, `inContext`) come from `Bytes.Decoder` directly — no re-exports.

### Map Decoding

CBOR map keys can be any type, but `CborItem` doesn't support structural equality (contains `Bytes`). The `field` combinator works with decoded key types:

```elm
field : k -> Decoder ctx err k -> Decoder ctx err v -> Decoder ctx err v
```

Semantics: decode the next key using the key decoder, compare the result to expected `k` via `==`, decode the value on match, fail on mismatch. Works for `Int`, `String`, and other types with Elm's structural equality.

**Homogeneous maps** (all entries have same key/value types):

```elm
Cbor.Decode.keyValue Cbor.Decode.string Cbor.Decode.int
-- : Decoder ctx err (List ( String, Int ))
```

**Heterogeneous maps / records** (ordered keys, common in deterministic CBOR):

```elm
decodeRecord =
    Cbor.Decode.mapHeader
        |> Bytes.Decoder.andThen (\_ ->
            Bytes.Decoder.map2 MyRecord
                (Cbor.Decode.field 0 Cbor.Decode.int Cbor.Decode.string)
                (Cbor.Decode.field 1 Cbor.Decode.int Cbor.Decode.int)
        )
```

`mapHeader` reads the major type 5 header and returns the entry count. Then `field` reads entries sequentially, verifying each key. This requires keys in expected order — appropriate for deterministic CBOR with sorted keys.

For unordered maps, decode all entries with `keyValue`, then look up fields from the resulting list.

### Encoding Configuration

Since `Encoder` is `Bytes.Encode.Encoder`, encoding decisions are made at the call site — there is no deferred configuration.

#### Approach A: Deterministic by default + explicit-width variants

Standard combinators produce deterministic output:
- `int` uses the shortest `IntWidth`
- `float` uses the shortest `FloatWidth` that preserves the value
- `map` sorts keys by encoded byte representation (RFC 8949 §4.2.1)

Additional explicit-width variants for non-standard cases:

```elm
Cbor.Encode.intWithWidth : IntWidth -> Int -> Encoder
Cbor.Encode.floatWithWidth : FloatWidth -> Float -> Encoder
Cbor.Encode.mapUnsorted : List ( Encoder, Encoder ) -> Encoder
```

`item : CborItem -> Encoder` produces lossless output — respects stored widths, entry order, and definite/indefinite length.

Pros: explicit control when needed, clean default.
Cons: more API surface.

#### Approach B: item as the only non-deterministic path

Standard combinators always produce deterministic output. For non-deterministic encoding, construct a `CborItem` and use `item`. No `*WithWidth` or `*Unsorted` variants.

Pros: minimal API surface.
Cons: constructing `CborItem` manually is verbose for simple cases like "encode this int as 4 bytes."

**Map key sorting**: `map` calls `Bytes.Encode.encode` on each key encoder to get the key bytes, sorts by length-first lexicographic order (RFC 8949 §4.2.1), then builds the final encoder. Keys are encoded twice (once for sorting, once in the output). Acceptable because map keys are typically small.

### CborItem as Escape Hatch

Bridge functions between the combinator world and the generic tree:

```elm
Cbor.Encode.item : CborItem -> Encoder          -- lossless encoding
Cbor.Decode.item : Decoder ctx err CborItem      -- full CBOR parser
```

Use cases: round-tripping unknown CBOR, diagnostic notation (`Cbor.diagnose : CborItem -> String`), inspecting/debugging arbitrary data.

### Open Design Questions

1. **`int` and large values**: `int` fails for values outside ±2^52. Should there be a dedicated combinator (e.g., `bigInt : Decoder ctx err ( Sign, Bytes )`) or is `item` sufficient as the fallback?

2. **Indefinite-length string/bytes**: Should `string` and `bytes` handle both definite and indefinite-length transparently (concatenating chunks), or expose the chunk structure?

3. **`arrayHeader`/`mapHeader` and indefinite length**: Returns `Int` (count), but indefinite-length containers have no count. Options: return `Maybe Int`, a union type, or fail on indefinite.

4. **`field` and key skipping**: `field` reads one entry and fails if the key doesn't match. For maps with keys you want to skip, should there be an explicit skip combinator (`skipEntry : Decoder ctx err ()`) or should `field` scan forward automatically?

5. **Encoding approach**: Approach A (explicit-width variants) vs Approach B (item-only non-deterministic). See Encoding Configuration above.

6. **Break code detection in indefinite-length decoding**: Detecting the break code (0xFF) requires reading a byte, checking if it's a break, and either stopping or using it as the start of the next item. Since bytes-decoder has no peek/unread, the CBOR initial-byte parsing must be integrated into the loop body rather than delegated to sub-decoders. This affects internal decoder structure but not the public API.

### Performance Rationale

Direct combinators skip the intermediate `CborItem` representation — bytes flow straight into/from domain types in one pass. The `item` decoder/encoder exists for users who need the generic tree, paying the allocation cost explicitly.
