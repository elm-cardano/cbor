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
Cbor               -- CborItem type, diagnostic notation, generic CBOR handling
Cbor.Encode        -- combinators for encoding domain types directly to CBOR bytes
Cbor.Decode        -- combinators for decoding CBOR bytes directly to domain types
```

### Combinators as Primary API

The primary encoding/decoding API uses combinators that go directly between domain types and CBOR bytes in a single pass, following the `elm/json` pattern:

```elm
-- Encoding
Cbor.Encode.int : Int -> Encoder
Cbor.Encode.string : String -> Encoder
Cbor.Encode.array : List Encoder -> Encoder
Cbor.Encode.map : List ( Encoder, Encoder ) -> Encoder

-- Decoding
Cbor.Decode.int : Decoder Int
Cbor.Decode.string : Decoder String
Cbor.Decode.array : Decoder a -> Decoder (List a)
-- TODO: actually we need a little bit of thinking here.
Cbor.Decode.field : CborItem -> Decoder a -> Decoder a
```

### CborItem as Escape Hatch

`CborItem` and its conversion functions exist for cases that need generic CBOR handling:
- Inspecting or debugging arbitrary CBOR data
- Round-tripping unknown CBOR without a schema
- Diagnostic notation (`diagnose : CborItem -> String`) per RFC 8949 Section 8
- Interop with tools that produce/consume generic CBOR

Bridge functions connect the two worlds:

```elm
Cbor.Encode.item : CborItem -> Cbor.Encode.Encoder
Cbor.Decode.item : Cbor.Decode.Decoder CborItem
```

### Performance Rationale

The two-step approach (domain type → CborItem → bytes) allocates an intermediate tree where every node is a tagged union and every collection is a linked list. This means two traversal passes and significant GC pressure for large payloads.

Direct combinators skip the intermediate representation — bytes flow straight into/from domain types in one pass. Users who need the generic tree pay for it explicitly via `Cbor.Item.decoder`.
