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

The byte comparison uses `Bytes.Decode` to read one byte at a time by offset, avoiding the allocation of intermediate lists. The `byteAt` helper decodes a single `unsignedInt8` at a given position, and `compareBytesFrom` recurses through both byte sequences from a starting offset, comparing corresponding bytes until a difference is found or one sequence ends.

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

Decoding uses `Bytes.Decoder.Decoder context error value` from `elm-cardano/bytes-decoder` directly. Users call `Bytes.Decoder.decode` to run decoders. All `Cbor.Decode` combinators fix the `error` parameter to `DecodeError` for structured, pattern-matchable errors. The `context` parameter remains polymorphic.

Encoding uses a custom `Encoder` type that defers strategy decisions:

```elm
type Encoder = Encoder (Strategy -> Bytes.Encode.Encoder)

encode : Strategy -> Encoder -> Bytes
```

This allows the same encoder definition to produce different byte representations depending on the strategy (key ordering, definite/indefinite length). See Encoding Configuration below.

### Error Handling

All `Cbor.Decode` combinators use a concrete `DecodeError` type for CBOR-specific errors:

```elm
type DecodeError
    = WrongMajorType { expected : Int, got : Int }
    | WrongInitialByte { got : Int }
    | WrongTag { expected : Int, got : Int }
    | ReservedAdditionalInfo Int
    | IntegerOverflow
    | KeyMismatch
    | TooFewElements
    | UnexpectedPendingKey
    | IndefiniteLengthNotSupported
    | UnknownMajorType Int
```

This replaces the previous design where the `error` type parameter was polymorphic and errors were opaque `String` values passed to `BD.fail`. With `DecodeError`, callers can pattern-match on specific failure modes (e.g., distinguish a type mismatch from an integer overflow) and produce domain-specific error messages.

The `errorToString` function converts any `DecodeError` to a human-readable message for logging or display.

These errors are wrapped by `elm-cardano/bytes-decoder`'s `Error` type, which adds position tracking and context:

```elm
type Error context error
    = InContext { label : context, start : Int } (Error context error)
    | OutOfBounds { at : Int, bytes : Int }
    | Custom { at : Int } error
    | BadOneOf { at : Int } (List (Error context error))
```

A CBOR decode failure produces `Custom { at = byteOffset } (WrongMajorType { expected = 0, got = 3 })`, giving both the byte position and the structured reason. The `context` type parameter remains polymorphic — callers can use `BD.inContext` to add domain-specific labels.

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
Cbor.Encode.tagged : Tag -> Encoder -> Encoder

-- Record encoding (strategy determines key ordering and definite/indefinite length)
-- Nothing entries are omitted from the output (optional field absent)
Cbor.Encode.keyedRecord : (k -> Encoder) -> List ( k, Maybe Encoder ) -> Encoder

-- Convenience
Cbor.Encode.list : (a -> Encoder) -> List a -> Encoder
Cbor.Encode.sequence : List Encoder -> Encoder

-- Escape hatches
Cbor.Encode.item : CborItem -> Encoder          -- lossless (ignores strategy entirely)
Cbor.Encode.rawUnsafe : Bytes -> Encoder        -- inject pre-encoded CBOR (no validation)

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

| Strategy        | Sort rule                                                   | Specified in               |
| --------------- | ----------------------------------------------------------- | -------------------------- |
| `deterministic` | Lexicographic on encoded key bytes                          | RFC 8949 §4.2.1            |
| `canonical`     | Shorter keys first, then lexicographic within same length   | RFC 7049 / RFC 8949 §4.2.3 |
| `ctap2`         | Group by major type, then shorter first, then lexicographic | CTAP2 (FIDO)               |
| `unsorted`      | Preserve insertion order                                    | —                          |

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
    Cbor.Encode.keyedRecord Cbor.Encode.int
        [ ( 0, Just (Cbor.Encode.string p.name) )
        , ( 1, Just (Cbor.Encode.int p.age) )
        ]

-- Apply different strategies:
Cbor.Encode.encode Cbor.Encode.deterministic (personEncoder alice)
Cbor.Encode.encode Cbor.Encode.canonical (personEncoder alice)
Cbor.Encode.encode myCustomStrategy (personEncoder alice)
```

**Map key sorting implementation**: `map` applies the strategy to each key encoder to get key `Bytes`, pairs each with its key+value `Bytes.Encode.Encoder`, passes the list to `strategy.sortKeys`, then sequences the result. Keys are encoded once — the encoded key bytes are reused in the output via `Bytes.Encode.bytes`.

**Definite vs indefinite length**: The strategy's `lengthMode` applies to arrays and maps only. Strings and byte strings always use definite length via `string`/`bytes`. For indefinite-length (chunked) strings/bytes, use the explicit `stringChunked`/`bytesChunked` combinators.

**`item`, `rawUnsafe`, and explicit-width combinators** ignore the strategy entirely — their output is fixed regardless of strategy. This ensures lossless round-tripping, raw injection, and explicit-width encoding are not affected by the strategy.

### Decoding Combinators

All combinators use `DecodeError` as the error type. The `ctx` parameter remains polymorphic for caller-defined context labels via `BD.inContext`.

```elm
-- Primitives
Cbor.Decode.int : Decoder ctx DecodeError Int              -- major types 0, 1; fails if |value| > 2^52
Cbor.Decode.bigInt : Decoder ctx DecodeError ( Sign, Bytes ) -- major types 0, 1 + tags 2, 3; minimal big-endian bytes
Cbor.Decode.float : Decoder ctx DecodeError Float          -- major type 7, additional info 25/26/27
Cbor.Decode.bool : Decoder ctx DecodeError Bool            -- 0xf4 (false), 0xf5 (true)
Cbor.Decode.null : a -> Decoder ctx DecodeError a          -- 0xf6; returns the provided value
Cbor.Decode.string : Decoder ctx DecodeError String        -- major type 3; concatenates indefinite-length chunks
Cbor.Decode.bytes : Decoder ctx DecodeError Bytes          -- major type 2; concatenates indefinite-length chunks

-- Collections
Cbor.Decode.array : Decoder ctx DecodeError a -> Decoder ctx DecodeError (List a)
Cbor.Decode.keyValue : Decoder ctx DecodeError k -> Decoder ctx DecodeError v -> Decoder ctx DecodeError (List ( k, v ))
Cbor.Decode.field : k -> Decoder ctx DecodeError k -> Decoder ctx DecodeError v -> Decoder ctx DecodeError v
Cbor.Decode.foldEntries : Decoder ctx DecodeError k -> (k -> acc -> Decoder ctx DecodeError acc) -> acc -> Decoder ctx DecodeError acc
Cbor.Decode.tag : Tag -> Decoder ctx DecodeError a -> Decoder ctx DecodeError a

-- Record builder (CBOR arrays → Elm values, positional)
Cbor.Decode.record : a -> RecordBuilder ctx DecodeError a
Cbor.Decode.element : Decoder ctx DecodeError v -> RecordBuilder ctx DecodeError (v -> a) -> RecordBuilder ctx DecodeError a
Cbor.Decode.optionalElement : Decoder ctx DecodeError v -> v -> RecordBuilder ctx DecodeError (v -> a) -> RecordBuilder ctx DecodeError a
Cbor.Decode.buildRecord : RecordBuilder ctx DecodeError a -> Decoder ctx DecodeError a

-- Keyed record builder (CBOR maps → Elm values, key-based)
Cbor.Decode.keyedRecord : Decoder ctx DecodeError k -> a -> KeyedRecordBuilder ctx DecodeError k a
Cbor.Decode.required : k -> Decoder ctx DecodeError v -> KeyedRecordBuilder ctx DecodeError k (v -> a) -> KeyedRecordBuilder ctx DecodeError k a
Cbor.Decode.optional : k -> Decoder ctx DecodeError v -> v -> KeyedRecordBuilder ctx DecodeError k (v -> a) -> KeyedRecordBuilder ctx DecodeError k a
Cbor.Decode.buildKeyedRecord : KeyedRecordBuilder ctx DecodeError k a -> Decoder ctx DecodeError a

-- Structure headers (for manual heterogeneous structures)
Cbor.Decode.arrayHeader : Decoder ctx DecodeError (Maybe Int)   -- Nothing for indefinite
Cbor.Decode.mapHeader : Decoder ctx DecodeError (Maybe Int)     -- Nothing for indefinite

-- Escape hatch
Cbor.Decode.item : Decoder ctx DecodeError CborItem
```

Composition combinators (`succeed`, `fail`, `andThen`, `oneOf`, `map`, `map2`–`map5`, `keep`, `ignore`, `loop`, `repeat`, `inContext`) come from `Bytes.Decoder` directly — no re-exports.

### Keyed Record Encoding

```elm
keyedRecord : (k -> Encoder) -> List ( k, Maybe Encoder ) -> Encoder
```

Encodes a keyed record as a CBOR map with a shared key encoder. `Nothing` entries are omitted from the output — this distinguishes "field absent" from "field is null".

```elm
personEncoder : Person -> Encoder
personEncoder p =
    Cbor.Encode.keyedRecord Cbor.Encode.int
        [ ( 0, Just (Cbor.Encode.string p.name) )
        , ( 1, Just (Cbor.Encode.int p.age) )
        , ( 2, Maybe.map Cbor.Encode.string p.email )  -- omitted when Nothing
        ]
```

Internally, `keyedRecord` filters out `Nothing` entries, applies the key encoder, and delegates to `map`. Strategy (key sorting, length mode) still applies.

### Sequence Encoding

```elm
sequence : List Encoder -> Encoder
```

Concatenates multiple CBOR items into a single byte output without a wrapping array. Supports CBOR Sequences (RFC 8742).

```elm
-- Log file: one CBOR item per entry
encodeLog : List LogEntry -> Bytes
encodeLog entries =
    entries
        |> List.map encodeEntry
        |> Cbor.Encode.sequence
        |> Cbor.Encode.encode Cbor.Encode.deterministic
```

Implementation: apply the strategy to each encoder, combine with `Bytes.Encode.sequence`.

### Raw Bytes Injection

```elm
rawUnsafe : Bytes -> Encoder
```

Injects pre-encoded CBOR bytes directly without validation. Ignores strategy (like `item`). If the bytes are not valid CBOR, the output is malformed — hence "Unsafe". Use case: caching pre-encoded fragments, embedding CBOR from external sources.

### Structured Decoding Builders

#### Record builder (CBOR arrays → Elm values)

```elm
type RecordBuilder ctx DecodeError a  -- opaque

record : a -> RecordBuilder ctx DecodeError a
element : Decoder ctx DecodeError v -> RecordBuilder ctx DecodeError (v -> a) -> RecordBuilder ctx DecodeError a
optionalElement : Decoder ctx DecodeError v -> v -> RecordBuilder ctx DecodeError (v -> a) -> RecordBuilder ctx DecodeError a
buildRecord : RecordBuilder ctx DecodeError a -> Decoder ctx DecodeError a
```

Decodes a CBOR array into an Elm value. Each `element`/`optionalElement` step decodes one array item positionally.

**`element`**: decodes one value. Fails if no items remain (definite) or break code encountered (indefinite).

**`optionalElement`**: if items remain, decodes one value. Otherwise, uses the default. Optional elements must be at the end of the decoded array, and if present, all preceeding optional elements must also be present. Otherwise decoding will fail.

Internally, the builder threads a `remaining` counter through the pipeline via `andThen`. The result is a `( Int, a )` tuple carrying the updated remaining count and the partially applied constructor:

```elm
-- Internal (not public API):
type RecordBuilder ctx DecodeError a
    = RecordBuilder (Int -> Decoder ctx DecodeError ( Int, a ))
    -- remaining -> decoder producing (updated remaining, value)

record : a -> RecordBuilder ctx DecodeError a
record constructor =
    RecordBuilder (\remaining -> succeed ( remaining, constructor ))

element : Decoder ctx DecodeError v -> RecordBuilder ctx DecodeError (v -> a) -> RecordBuilder ctx DecodeError a
element valueDecoder (RecordBuilder innerDecoder) =
    RecordBuilder (\remaining ->
        innerDecoder remaining
            |> andThen (\( rem, f ) ->
                if rem > 0 then
                    valueDecoder |> map (\v -> ( rem - 1, f v ))
                else
                    fail ...
            )
    )

optionalElement : Decoder ctx DecodeError v -> v -> RecordBuilder ctx DecodeError (v -> a) -> RecordBuilder ctx DecodeError a
optionalElement valueDecoder default (RecordBuilder innerDecoder) =
    RecordBuilder (\remaining ->
        innerDecoder remaining
            |> andThen (\( rem, f ) ->
                if rem > 0 then
                    valueDecoder |> map (\v -> ( rem - 1, f v ))
                else
                    succeed ( 0, f default )
            )
    )

buildRecord : RecordBuilder ctx DecodeError a -> Decoder ctx DecodeError a
buildRecord (RecordBuilder decoder) =
    arrayHeader
        |> andThen (\maybeN ->
            case maybeN of
                Just n ->
                    decoder n
                        |> andThen (\( rem, value ) ->
                            if rem == 0 then
                                succeed value
                            else
                                fail ...
                        )

                Nothing ->
                    ... -- indefinite: use break detection (see below)
        )
```

Each `element` wraps the inner decoder in `andThen`, decodes one value, decrements `remaining`, and applies the value to the partially applied constructor. For definite-length arrays, `remaining` starts at the header count and must reach 0.

```elm
decodePoint : Decoder ctx DecodeError Point
decodePoint =
    Cbor.Decode.record Point
        |> Cbor.Decode.element Cbor.Decode.float
        |> Cbor.Decode.element Cbor.Decode.float
        |> Cbor.Decode.optionalElement Cbor.Decode.float 0.0
        |> Cbor.Decode.buildRecord
```

#### Keyed record builder (CBOR maps → Elm values)

```elm
type KeyedRecordBuilder ctx DecodeError k a  -- opaque

keyedRecord : Decoder ctx DecodeError k -> a -> KeyedRecordBuilder ctx DecodeError k a
required : k -> Decoder ctx DecodeError v -> KeyedRecordBuilder ctx DecodeError k (v -> a) -> KeyedRecordBuilder ctx DecodeError k a
optional : k -> Decoder ctx DecodeError v -> v -> KeyedRecordBuilder ctx DecodeError k (v -> a) -> KeyedRecordBuilder ctx DecodeError k a
buildKeyedRecord : KeyedRecordBuilder ctx DecodeError k a -> Decoder ctx DecodeError a
```

Decodes a CBOR map into an Elm value. Each `required`/`optional` step decodes one map entry by key.

Internally, the builder threads a `State` through the pipeline via `andThen`, similar to the record builder but with `pendingKey` for handling absent optional fields:

```elm
-- Internal (not public API):
type KeyedRecordBuilder ctx DecodeError k a
    = KeyedRecordBuilder (Decoder ctx DecodeError k) (Int -> Decoder ctx DecodeError (State k a))
    -- (key decoder, remaining -> decoder producing State)

type alias State k a =
    { remaining : Int       -- entries left to consume from stream
    , pendingKey : Maybe k  -- key read but not yet matched
    , value : a             -- partially applied constructor
    }

keyedRecord : Decoder ctx DecodeError k -> a -> KeyedRecordBuilder ctx DecodeError k a
keyedRecord keyDecoder constructor =
    KeyedRecordBuilder keyDecoder
        (\remaining ->
            succeed { remaining = remaining, pendingKey = Nothing, value = constructor }
        )

required : k -> Decoder ctx DecodeError v -> KeyedRecordBuilder ctx DecodeError k (v -> a) -> KeyedRecordBuilder ctx DecodeError k a
required expectedKey valueDecoder (KeyedRecordBuilder keyDecoder innerDecoder) =
    KeyedRecordBuilder keyDecoder
        (\remaining ->
            innerDecoder remaining
                |> andThen (\state ->
                    (case state.pendingKey of
                        Just k  -> succeed k
                        Nothing -> keyDecoder
                    )
                    |> andThen (\key ->
                        if key == expectedKey then
                            valueDecoder
                                |> map (\v ->
                                    { remaining = state.remaining - 1
                                    , pendingKey = Nothing
                                    , value = state.value v
                                    }
                                )
                        else
                            fail ...
                    )
                )
        )

optional : k -> Decoder ctx DecodeError v -> v -> KeyedRecordBuilder ctx DecodeError k (v -> a) -> KeyedRecordBuilder ctx DecodeError k a
optional expectedKey valueDecoder default (KeyedRecordBuilder keyDecoder innerDecoder) =
    KeyedRecordBuilder keyDecoder
        (\remaining ->
            innerDecoder remaining
                |> andThen (\state ->
                    if state.remaining == 0 && state.pendingKey == Nothing then
                        succeed { state | value = state.value default }
                    else
                        (case state.pendingKey of
                            Just k  -> succeed k
                            Nothing -> keyDecoder
                        )
                        |> andThen (\key ->
                            if key == expectedKey then
                                valueDecoder
                                    |> map (\v ->
                                        { remaining = state.remaining - 1
                                        , pendingKey = Nothing
                                        , value = state.value v
                                        }
                                    )
                            else
                                succeed
                                    { remaining = state.remaining
                                    , pendingKey = Just key
                                    , value = state.value default
                                    }
                        )
                )
        )

buildKeyedRecord : KeyedRecordBuilder ctx DecodeError k a -> Decoder ctx DecodeError a
buildKeyedRecord (KeyedRecordBuilder _ decoder) =
    mapHeader
        |> andThen (\maybeN ->
            case maybeN of
                Just n ->
                    decoder n
                        |> andThen (\state ->
                            if state.remaining == 0 && state.pendingKey == Nothing then
                                succeed state.value
                            else
                                fail ...
                        )

                Nothing ->
                    ... -- indefinite: use break detection (see below)
        )
```

- `remaining` tracks entries left to consume. Only decrements when a value is decoded from the stream.
- `pendingKey` stores a key read from the stream that didn't match an `optional` field. The next step uses it instead of reading a new key.

**Constraint**: the order of `required`/`optional` steps must match the key order in the CBOR data. When a key doesn't match an `optional` field, it's stashed for the next step — this only works if subsequent keys are "ahead" in the stream. For unordered keys, use `foldEntries`.

**All required fields:**

```elm
decodePerson : Decoder ctx DecodeError Person
decodePerson =
    Cbor.Decode.keyedRecord Cbor.Decode.int Person
        |> Cbor.Decode.required 0 Cbor.Decode.string
        |> Cbor.Decode.required 1 Cbor.Decode.int
        |> Cbor.Decode.buildKeyedRecord
```

**With optional fields:**

```elm
decodePerson : Decoder ctx DecodeError Person
decodePerson =
    Cbor.Decode.keyedRecord Cbor.Decode.int Person
        |> Cbor.Decode.required 0 Cbor.Decode.string
        |> Cbor.Decode.required 1 Cbor.Decode.int
        |> Cbor.Decode.optional 2 Cbor.Decode.string ""
        |> Cbor.Decode.required 3 Cbor.Decode.bool
        |> Cbor.Decode.buildKeyedRecord
```

**Trace — optional field absent** (`{ 0: "Alice", 1: 30, 3: true }`, 3 entries):

| Step       | Stream after          | remaining | pendingKey | value                       |
| ---------- | --------------------- | --------- | ---------- | --------------------------- |
| start      | `[k0,v0,k1,v1,k3,v3]` | 3         | Nothing    | `Person`                    |
| required 0 | `[k1,v1,k3,v3]`       | 2         | Nothing    | `Person "Alice"`            |
| required 1 | `[k3,v3]`             | 1         | Nothing    | `Person "Alice" 30`         |
| optional 2 | `[v3]`                | 1         | Just 3     | `Person "Alice" 30 ""`      |
| required 3 | `[]`                  | 0         | Nothing    | `Person "Alice" 30 "" True` |

`optional 2` reads key 3, no match, stashes it. `required 3` uses the stashed key, only reads the value. Total consumed entries (3) equals header count (3).

#### Indefinite-length support

Both builders support indefinite-length containers. For indefinite-length arrays and maps, the builder reads the initial byte before each element/key step. If the byte is 0xFF (break code), decoding stops: remaining `optional`/`optionalElement` steps use their defaults, remaining `required`/`element` steps fail. Otherwise, the initial byte begins key/element decoding. This reuses the same initial-byte-first pattern described in Break Code Detection — the CBOR decoder reads the initial byte and dispatches based on major type, staying on the fast path.

#### Low-level field combinator

```elm
field : k -> Decoder ctx DecodeError k -> Decoder ctx DecodeError v -> Decoder ctx DecodeError v
```

Decodes the next key, compares to expected `k` via `==`, decodes value on match, fails on mismatch. This is the primitive used internally by `required`. It can also be used directly with `mapHeader` + `keep`/`ignore` for manual decoding without the builder.

#### Unordered keys (fold over entries)

```elm
foldEntries :
    Decoder ctx DecodeError k
    -> (k -> acc -> Decoder ctx DecodeError acc)
    -> acc
    -> Decoder ctx DecodeError acc
```

Reads the map header, then loops through entries. For each entry: decode the key, call the handler with the key and current accumulator. The handler decodes the value and returns the updated accumulator. Handles both definite and indefinite-length maps.

```elm
type alias Partial = { name : Maybe String, age : Maybe Int }

decodePerson : Decoder ctx DecodeError Person
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
                    Bytes.Decoder.fail KeyMismatch
        )
```

**Important**: the handler MUST decode exactly one value per call (advancing the byte offset past the entry's value). Failing to consume the value corrupts the offset for subsequent entries.

Use `foldEntries` when: keys are unordered, or complex dispatch logic that doesn't fit the builder pattern.

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
Cbor.Decode.item : Decoder ctx DecodeError CborItem      -- full CBOR parser
```

Use cases: round-tripping unknown CBOR, diagnostic notation (`Cbor.diagnose : CborItem -> String`), inspecting/debugging arbitrary data, skipping unknown values.

### Resolved Design Decisions

1. **`bigInt` range**: `bigInt` decodes any CBOR integer (major types 0 and 1), including values tagged with `PositiveBigNum` (tag 2) and `NegativeBigNum` (tag 3). Returns `( Sign, Bytes )` where `Bytes` is the minimal big-endian representation (no zero-padding). Small values that fit in Int52 are still accepted — they produce minimal byte sequences.

2. **Indefinite-length string/bytes decoding**: `string` and `bytes` concatenate indefinite-length chunks transparently. The caller receives a single `String` or `Bytes` value regardless of whether definite or indefinite encoding was used. The `item` decoder preserves chunk structure via `CborStringChunked` / `CborByteStringChunked`.

3. **Strategy extensibility**: The current `{ sortKeys, lengthMode }` is sufficient for now. Per-subtree strategy overrides (e.g., `withStrategy : Strategy -> Encoder -> Encoder`) may be needed for formats that impose different constraints on substructures, but this will be deferred until a concrete use case confirms the need.

### Performance Rationale

Direct combinators skip the intermediate `CborItem` representation — bytes flow straight into/from domain types in one pass. The `item` decoder/encoder exists for users who need the generic tree, paying the allocation cost explicitly.

The `Encoder` closure approach (`Strategy -> Bytes.Encode.Encoder`) adds minimal overhead — one function call per node during encoding. No intermediate tree is allocated. Strategy propagates through nested structures via closure capture.

## Cardano CDDL Decoding Patterns

The Conway-era Cardano ledger spec (`conway.cddl`) defines ~90 CBOR types. Most are trivial to decode with the combinators above (primitives, fixed-position arrays via `record` builder, keyed maps via `keyedRecord` builder, simple tagged values, homogeneous maps). The challenging types fall into three categories.

### Sum types with discriminant dispatch

Every discriminated union in the Cardano CDDL is a CBOR array where the first element is a uint tag: `certificate` (17 variants), `gov_action` (7), `script` (4), `native_script` (6), `credential` (2), `drep` (4), `voter` (5), `relay` (3), `datum_option` (2).

Approach: read the array header, read the discriminant int, dispatch via `andThen` + `case`. Remaining fields decoded with `succeed`/`keep`. No new combinators needed.

```elm
decodeCertificate : Decoder ctx DecodeError Certificate
decodeCertificate =
    arrayHeader
        |> andThen (\_ ->
            int |> andThen (\tag ->
                case tag of
                    0 ->
                        succeed AccountRegistrationCert
                            |> keep decodeStakeCredential
                    2 ->
                        succeed DelegationToStakePoolCert
                            |> keep decodeStakeCredential
                            |> keep decodePoolKeyhash
                    ...
                    _ ->
                        fail (WrongInitialByte { got = tag })
            )
        )
```

Note: `pool_params` is an inline group — its 9 fields are spliced into the `pool_registration_cert` array (tag 3), so that branch simply has more `keep` steps.

### Recursive types

`native_script`, `plutus_data`, and `metadatum` are recursive.

**Recursion itself works naturally** when self-references appear inside `andThen` callbacks — the lambda captures the decoder reference without evaluating it at definition time:

```elm
decodeNativeScript =
    arrayHeader |> andThen (\_ ->
        int |> andThen (\tag ->
            case tag of
                1 -> array decodeNativeScript |> map ScriptAll  -- recursive, fine
                2 -> array decodeNativeScript |> map ScriptAny
                3 -> succeed ScriptNOfK |> keep int |> keep (array decodeNativeScript)
                ...
        )
    )
```

No `lazy` combinator is needed for this pattern. A `lazy` would only be necessary if a self-reference appeared as a direct argument at the top level (e.g., `oneOf [ array decodePlutusData, ... ]` where `decodePlutusData` is eagerly evaluated before being defined). The dispatch patterns below avoid that.

**`native_script`** dispatches on an int discriminant inside an array — same pattern as sum types, just happens to be recursive. Straightforward.

**`plutus_data` and `metadatum`** are different: their variants are distinguished by CBOR major type, not a discriminant integer:

```
plutus_data =
    constr<plutus_data>               -- major type 6 (tags 121-127, 102)
    / {* plutus_data => plutus_data}  -- major type 5
    / [* plutus_data]                 -- major type 4
    / big_int                         -- major type 0, 1, or 6 (tags 2, 3)
    / bounded_bytes                   -- major type 2
```

Three approaches were considered:

**(A) `oneOf` — start here.** Each branch fails on the first byte if the major type doesn't match, so backtracking is cheap. Constr (tags 121–127, 102) must come before bigInt (tags 2, 3) since both are major type 6:

```elm
decodePlutusData =
    oneOf
        [ decodeConstr
        , keyValue decodePlutusData decodePlutusData |> map PlutusMap
        , array decodePlutusData |> map PlutusArray
        , bigInt |> map PlutusBigInt
        , bytes |> map PlutusBytes
        ]
```

**(B) Initial-byte dispatch.** Read one byte, extract major type (top 3 bits), dispatch in O(1) without backtracking. Requires internal `fromByte` helpers (which already exist inside `Cbor.Decode.item`) to be either exposed or composed differently. More efficient but more API surface.

**(C) `item` + convert.** Decode the entire tree via `Cbor.Decode.item` into `CborItem`, then walk it to produce the domain type. Simple, but two-pass.

**Decision: start with (A).** `oneOf` is clean and correct. Benchmark before optimizing. If profiling shows `oneOf` backtracking is a bottleneck for deeply nested `plutus_data`, revisit other approaches.

### Multiple valid encodings

Several types accept multiple CBOR shapes for the same semantic value. In every case in this CDDL, the variants differ by major type, so `oneOf` fails fast on the first byte:

| Type                                         | Variants                                     |
| -------------------------------------------- | -------------------------------------------- |
| `set<a0>` / `nonempty_set` / `nonempty_oset` | tag 258 + array (mt 6) vs plain array (mt 4) |
| `transaction_output`                         | array (mt 4) vs map (mt 5)                   |
| `redeemers`                                  | array (mt 4) vs map (mt 5)                   |
| `auxiliary_data`                             | map (mt 5) vs array (mt 4) vs tag 259 (mt 6) |
| `value`                                      | uint (mt 0) vs array (mt 4)                  |
| `big_int`                                    | int (mt 0/1) vs tag (mt 6)                   |

Approach: `oneOf` with each encoding as a branch. Since major types differ, the first byte is enough to reject a wrong branch — backtracking cost is one byte.

```elm
decodeSet : Decoder ctx DecodeError a -> Decoder ctx DecodeError (List a)
decodeSet elementDecoder =
    oneOf
        [ tag (Unknown 258) (array elementDecoder)
        , array elementDecoder
        ]

decodeValue : Decoder ctx DecodeError Value
decodeValue =
    oneOf
        [ int |> map Coin
        , record Tuple.pair
            |> element int
            |> element (decodeMultiasset positiveInt)
            |> buildRecord
            |> map (\( c, ma ) -> CoinAndAssets c ma)
        ]
```

None of these types are recursive or high-frequency-per-node, so `oneOf` overhead is negligible.

### Non-challenging patterns

The remaining complex-looking types are handled by existing combinators without difficulty:

- **Embedded CBOR** (`data`, `script_ref`): `tag Cbor (bytes |> andThen decodeEmbedded)` — decode tag 24, decode bytes, run a nested CBOR decoder on the bytes.
- **Large optional maps** (`transaction_body`, `protocol_param_update`, `transaction_witness_set`): `keyedRecord` builder with many `required`/`optional` steps — tedious but mechanical. `protocol_param_update` (all optional fields) may be better suited for `foldEntries`.
- **Inline groups** (`pool_params`): `succeed`/`keep` from `Bytes.Decoder` directly — the fields are positional within the enclosing array.
- **Nested homogeneous maps** (`voting_procedures`): `keyValue` for the outer and inner maps.
