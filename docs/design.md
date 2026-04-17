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

- `elm/bytes` — `Bytes` type, `Bytes.Encode.Encoder` (used internally by the custom `Encoder` type)
- `elm-cardano/bytes-decoder` — `Bytes.Decoder.Decoder` and `Bytes.Decoder.Error` (used directly as the decoding types)
- `elm-cardano/float16` — float16 ↔ float64 conversion for `CborFloat FW16`

### Encoder and Decoder Types

Decoding uses `Bytes.Decoder.Decoder context error value` from `elm-cardano/bytes-decoder` directly. Users call `Bytes.Decoder.decode` to run decoders. The `context` and `error` type parameters remain polymorphic in all `Cbor.Decode` combinators.

Encoding uses a custom `Encoder` type that defers strategy decisions:

```elm
type Encoder = Encoder (Strategy -> Bytes.Encode.Encoder)

encode : Strategy -> Encoder -> Bytes
```

This allows the same encoder definition to produce different byte representations depending on the strategy (key ordering, definite/indefinite length). See Encoding Configuration below.

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
-- Primitives (always use shortest encoding form regardless of strategy)
Cbor.Encode.int : Int -> Encoder
Cbor.Encode.float : Float -> Encoder
Cbor.Encode.bool : Bool -> Encoder
Cbor.Encode.null : Encoder
Cbor.Encode.undefined : Encoder
Cbor.Encode.string : String -> Encoder
Cbor.Encode.bytes : Bytes -> Encoder
Cbor.Encode.simple : Int -> Encoder

-- Explicit width control (ignores strategy for width)
Cbor.Encode.intWithWidth : IntWidth -> Int -> Encoder
Cbor.Encode.floatWithWidth : FloatWidth -> Float -> Encoder

-- Chunked strings/bytes (always indefinite-length encoding)
Cbor.Encode.stringChunked : List String -> Encoder
Cbor.Encode.bytesChunked : List Bytes -> Encoder

-- Collections (strategy determines key ordering and definite/indefinite length)
Cbor.Encode.array : List Encoder -> Encoder
Cbor.Encode.map : List ( Encoder, Encoder ) -> Encoder
Cbor.Encode.tag : Tag -> Encoder -> Encoder

-- Convenience
Cbor.Encode.list : (a -> Encoder) -> List a -> Encoder

-- Escape hatch (lossless: ignores strategy entirely, respects CborItem's stored widths/order/length)
Cbor.Encode.item : CborItem -> Encoder

-- Run encoding
Cbor.Encode.encode : Strategy -> Encoder -> Bytes
```

### Encoding Configuration

```elm
type alias Strategy =
    { sortKeys : List ( Bytes, Bytes.Encode.Encoder ) -> List ( Bytes, Bytes.Encode.Encoder )
    , lengthMode : Length  -- Definite or Indefinite for arrays and maps
    }
```

Primitive combinators always use shortest encoding (all canonical forms agree on this). Collection combinators consult the strategy for key ordering and length mode. The strategy propagates through nested structures automatically via closure capture.

**Key sorting approaches** (from RFC 7049, RFC 8949, and CTAP2):

| Strategy | Sort rule | Specified in |
|----------|-----------|-------------|
| `deterministic` | Lexicographic on encoded key bytes | RFC 8949 §4.2.1 |
| `canonical` | Shorter keys first, then lexicographic within same length | RFC 7049 / RFC 8949 §4.2.3 |
| `ctap2` | Group by major type, then shorter first, then lexicographic | CTAP2 (FIDO) |
| `unsorted` | Preserve insertion order | — |

**Predefined strategies:**

```elm
Cbor.Encode.deterministic : Strategy    -- RFC 8949 §4.2.1, definite length
Cbor.Encode.canonical : Strategy        -- RFC 7049 / §4.2.3, definite length
Cbor.Encode.ctap2 : Strategy            -- CTAP2, definite length
Cbor.Encode.unsorted : Strategy         -- insertion order, definite length
```

**Usage — same encoder, different strategies:**

```elm
personEncoder : Person -> Encoder
personEncoder p =
    Cbor.Encode.map
        [ ( Cbor.Encode.int 0, Cbor.Encode.string p.name )
        , ( Cbor.Encode.int 1, Cbor.Encode.int p.age )
        ]

-- Apply different strategies:
Cbor.Encode.encode Cbor.Encode.deterministic (personEncoder alice)
Cbor.Encode.encode Cbor.Encode.canonical (personEncoder alice)
Cbor.Encode.encode myCustomStrategy (personEncoder alice)
```

**Map key sorting implementation**: `map` applies the strategy to each key encoder to get key `Bytes`, pairs each with its key+value `Bytes.Encode.Encoder`, passes the list to `strategy.sortKeys`, then sequences the result. Keys are encoded once — the encoded key bytes are reused in the output via `Bytes.Encode.bytes`.

**Definite vs indefinite length**: The strategy's `lengthMode` applies to arrays and maps only. Strings and byte strings always use definite length via `string`/`bytes`. For indefinite-length (chunked) strings/bytes, use the explicit `stringChunked`/`bytesChunked` combinators.

**`item` and explicit-width combinators** ignore the strategy entirely — their output is fixed regardless of strategy. This ensures lossless round-tripping and explicit-width encoding are not affected by the strategy.

### Decoding Combinators

```elm
-- Primitives
Cbor.Decode.int : Decoder ctx err Int              -- major types 0, 1; fails if |value| > 2^52
Cbor.Decode.bigInt : Decoder ctx err ( Sign, Bytes ) -- major types 0, 1 + tags 2, 3; minimal big-endian bytes
Cbor.Decode.float : Decoder ctx err Float          -- major type 7, additional info 25/26/27
Cbor.Decode.bool : Decoder ctx err Bool            -- 0xf4 (false), 0xf5 (true)
Cbor.Decode.null : a -> Decoder ctx err a          -- 0xf6; returns the provided value
Cbor.Decode.string : Decoder ctx err String        -- major type 3; concatenates indefinite-length chunks
Cbor.Decode.bytes : Decoder ctx err Bytes          -- major type 2; concatenates indefinite-length chunks

-- Collections
Cbor.Decode.array : Decoder ctx err a -> Decoder ctx err (List a)
Cbor.Decode.keyValue : Decoder ctx err k -> Decoder ctx err v -> Decoder ctx err (List ( k, v ))
Cbor.Decode.field : k -> Decoder ctx err k -> Decoder ctx err v -> Decoder ctx err v
Cbor.Decode.foldEntries : Decoder ctx err k -> (k -> acc -> Decoder ctx err acc) -> acc -> Decoder ctx err acc
Cbor.Decode.tag : Tag -> Decoder ctx err a -> Decoder ctx err a

-- Structure headers (for heterogeneous structures)
Cbor.Decode.arrayHeader : Decoder ctx err (Maybe Int)   -- Nothing for indefinite
Cbor.Decode.mapHeader : Decoder ctx err (Maybe Int)     -- Nothing for indefinite

-- Escape hatch
Cbor.Decode.item : Decoder ctx err CborItem
```

Composition combinators (`succeed`, `fail`, `andThen`, `oneOf`, `map`, `map2`–`map5`, `keep`, `ignore`, `loop`, `repeat`, `inContext`) come from `Bytes.Decoder` directly — no re-exports.

### Map Decoding

#### Ordered keys (sequential field matching)

```elm
field : k -> Decoder ctx err k -> Decoder ctx err v -> Decoder ctx err v
```

Decodes the next key, compares to expected `k` via `==`, decodes value on match, fails on mismatch. Requires keys in expected order — appropriate for deterministic CBOR.

```elm
decodeRecord =
    Cbor.Decode.mapHeader
        |> Bytes.Decoder.andThen (\_ ->
            Bytes.Decoder.map2 MyRecord
                (Cbor.Decode.field 0 Cbor.Decode.int Cbor.Decode.string)
                (Cbor.Decode.field 1 Cbor.Decode.int Cbor.Decode.int)
        )
```

#### Unordered keys (fold over entries)

```elm
foldEntries :
    Decoder ctx err k
    -> (k -> acc -> Decoder ctx err acc)
    -> acc
    -> Decoder ctx err acc
```

Reads the map header, then loops through entries. For each entry: decode the key, call the handler with the key and current accumulator. The handler decodes the value and returns the updated accumulator. Handles both definite and indefinite-length maps.

```elm
type alias Partial = { name : Maybe String, age : Maybe Int }

decodePerson : Decoder ctx err Person
decodePerson =
    Cbor.Decode.foldEntries Cbor.Decode.int
        (\key partial ->
            case key of
                0 ->
                    Cbor.Decode.string
                        |> Bytes.Decoder.map (\v -> { partial | name = Just v })
                1 ->
                    Cbor.Decode.int
                        |> Bytes.Decoder.map (\v -> { partial | age = Just v })
                _ ->
                    Cbor.Decode.item
                        |> Bytes.Decoder.map (\_ -> partial)
        )
        { name = Nothing, age = Nothing }
        |> Bytes.Decoder.andThen (\p ->
            case ( p.name, p.age ) of
                ( Just n, Just a ) ->
                    Bytes.Decoder.succeed (Person n a)
                _ ->
                    Bytes.Decoder.fail MissingFields
        )
```

**Important**: the handler MUST decode exactly one value per call (advancing the byte offset past the entry's value). Failing to consume the value corrupts the offset for subsequent entries.

#### Skipping entries

No dedicated `skipEntry` combinator needed — compose from existing primitives:

```elm
-- Skip one CBOR value (advancing past it)
skipValue = Cbor.Decode.item |> Bytes.Decoder.map (\_ -> ())

-- Skip one key-value pair
skipEntry = Bytes.Decoder.map2 (\_ _ -> ()) Cbor.Decode.item Cbor.Decode.item
```

`Cbor.Decode.item` parses any well-formed CBOR item (including nested structures), so these correctly advance past variable-length data. There is a performance cost — `item` fully constructs a `CborItem` tree that is immediately discarded. A dedicated skip-without-allocating optimization can be added later if profiling shows it matters.

### Break Code Detection

For indefinite-length containers, the break code `0xFF` appears where the next item would start. Without a peek primitive (which would require `randomAccess` and force slow path), break detection uses the initial-byte-first pattern:

```elm
-- Internal structure (not public API):
-- Read one byte, check for break, then dispatch based on major type
unsignedInt8 |> andThen (\byte ->
    if byte == 0xFF then
        succeed Done
    else
        decodeItemFromByte byte |> map (\item -> Loop ...)
)
```

The CBOR decoder reads the initial byte first, then dispatches based on major type and additional info. This is the natural structure for CBOR's tag-length-value format. For definite-length containers, no break check is needed (loop exactly `count` times). For indefinite-length, the break check integrates naturally into the loop via `andThen` — which stays on the fast path as long as the callback doesn't return `fail`.

A peek primitive would add complexity without benefit — the initial-byte-first pattern is both simpler and faster.

### CborItem as Escape Hatch

Bridge functions between the combinator world and the generic tree:

```elm
Cbor.Encode.item : CborItem -> Encoder          -- lossless (ignores Strategy)
Cbor.Decode.item : Decoder ctx err CborItem      -- full CBOR parser
```

Use cases: round-tripping unknown CBOR, diagnostic notation (`Cbor.diagnose : CborItem -> String`), inspecting/debugging arbitrary data, skipping unknown values.

### Resolved Design Decisions

1. **`bigInt` range**: `bigInt` decodes any CBOR integer (major types 0 and 1), including values tagged with `PositiveBigNum` (tag 2) and `NegativeBigNum` (tag 3). Returns `( Sign, Bytes )` where `Bytes` is the minimal big-endian representation (no zero-padding). Small values that fit in Int52 are still accepted — they produce minimal byte sequences.

2. **Indefinite-length string/bytes decoding**: `string` and `bytes` concatenate indefinite-length chunks transparently. The caller receives a single `String` or `Bytes` value regardless of whether definite or indefinite encoding was used. The `item` decoder preserves chunk structure via `CborStringChunked` / `CborByteStringChunked`.

3. **Strategy extensibility**: The current `{ sortKeys, lengthMode }` is sufficient for now. Per-subtree strategy overrides (e.g., `withStrategy : Strategy -> Encoder -> Encoder`) may be needed for formats that impose different constraints on substructures, but this will be deferred until a concrete use case confirms the need.

### Performance Rationale

Direct combinators skip the intermediate `CborItem` representation — bytes flow straight into/from domain types in one pass. The `item` decoder/encoder exists for users who need the generic tree, paying the allocation cost explicitly.

The `Encoder` closure approach (`Strategy -> Bytes.Encode.Encoder`) adds minimal overhead — one function call per node during encoding. No intermediate tree is allocated. Strategy propagates through nested structures via closure capture.
