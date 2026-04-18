module V2 exposing
    ( deterministicV2, canonicalV2
    , deterministicV3
    , deterministicV5
    , floatV2
    , stringBEv1, stringBEv2, stringBEv2b
    , bytesWithHeaderV1, bytesWithHeaderV2
    , arrayIndefiniteV1, arrayIndefiniteV2
    , mapIntV1, mapIntV2
    , floatV3
    )

{-| Alternative implementations for benchmarking against Cbor.Encode internals.


# Strategies with O(N) byte comparison

Decodes each key to `List Int` once before sorting, then uses Elm's built-in
`compare` on `List Int` (kernel-level lexicographic comparison).

Current `Cbor.Encode.compareBytes` uses `byteAt i` which creates a fresh
decoder skipping `i` bytes each time, making each comparison O(K^2) where
K is key length. This V2 approach is O(K) per comparison.

@docs deterministicV2, canonicalV2


# V3: String sort key

Decodes each byte via `unsignedInt8` + `Char.fromCode`, builds a `String`
via `String.fromList`. String comparison in `_Utils_cmp` is a single JS `<`
operator (V8-optimized), avoiding linked-list pointer chasing entirely.

(`Bytes.Decode.string` cannot be used because it interprets bytes as UTF-8,
consuming multiple bytes for values >= 128.)

@docs deterministicV3


# V5: Hex string sort key

Uses `Hex.fromBytes` from the x-bytes package to convert each key to a
hex string. Hex digits (0-9, a-f) preserve byte ordering, so string
comparison gives correct lexicographic byte ordering. The string is 2x
the byte count but comparison is a single V8-optimized `<`.

@docs deterministicV5


# Float encoding with float32-first detection

Current `Cbor.Encode.encodeFloat` tries float16 first, then float32, then
float64. A true float64 value pays for 2 failed round-trip checks.

V2 checks float32 first: if it fails, emit float64 immediately (1 check
instead of 2). If float32 succeeds, then check float16.

@docs floatV2


# Opportunity 1: String encoding without intermediate buffer

V1 encodes the string to a temporary `Bytes`, measures its width, then
copies the bytes. V2 uses `BE.getStringWidth` (pure arithmetic) and
feeds the string directly to `BE.string`.

@docs stringBEv1, stringBEv2, stringBEv2b


# Opportunity 2: Header packing for argument 24–255

V1 uses `BE.sequence [U8, U8]` (6 heap allocations). V2 packs both bytes
into a single `BE.unsignedInt16` (1 allocation).

@docs bytesWithHeaderV1, bytesWithHeaderV2


# Opportunity 3: Break appending in indefinite-length mode

V1 uses `++ [break]` which traverses the entire item list (O(N)).
V2 uses a nested `BE.sequence` which is O(1).

@docs arrayIndefiniteV1, arrayIndefiniteV2


# Opportunity 4: concatMap → foldr in map entry encoding

V1 uses `List.concatMap` (allocates N intermediate 2-element lists).
V2 uses `List.foldr` (builds the flat list directly).

@docs mapIntV1, mapIntV2


# Opportunity 5: Float fast-reject guard

V3 adds `abs f <= 65504` before the float16 round-trip check, skipping
the expensive allocation for values that can never be float16.

@docs floatV3

-}

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode as BE
import Bytes.Floating.Decode
import Bytes.Floating.Encode
import Cbor exposing (FloatWidth(..), Length(..))
import Cbor.Encode as CE
import Hex



-- ============================================================================
-- COMPAREBYTES V2: decode keys to List Int, sort with built-in compare
-- ============================================================================


{-| Deterministic strategy using O(N) byte comparison.

Keys are decoded to `List Int` once before sorting, then compared using
Elm's built-in `compare` on `List Int` (lexicographic, kernel-level).

-}
deterministicV2 : CE.Strategy
deterministicV2 =
    { sortKeys = sortKeysByteList
    , lengthMode = Definite
    }


{-| Canonical strategy using O(N) byte comparison.

Shorter keys first, then lexicographic within same length.
Uses `( Bytes.width, List Int )` as sort key so tuple comparison
gives canonical ordering automatically.

-}
canonicalV2 : CE.Strategy
canonicalV2 =
    { sortKeys = sortKeysCanonicalByteList
    , lengthMode = Definite
    }


sortKeysByteList : List ( Bytes, BE.Encoder ) -> List ( Bytes, BE.Encoder )
sortKeysByteList entries =
    entries
        |> List.map (\( bs, enc ) -> ( bytesToList bs, ( bs, enc ) ))
        |> List.sortBy Tuple.first
        |> List.map Tuple.second


sortKeysCanonicalByteList : List ( Bytes, BE.Encoder ) -> List ( Bytes, BE.Encoder )
sortKeysCanonicalByteList entries =
    entries
        |> List.map (\( bs, enc ) -> ( ( Bytes.width bs, bytesToList bs ), ( bs, enc ) ))
        |> List.sortBy Tuple.first
        |> List.map Tuple.second


bytesToList : Bytes -> List Int
bytesToList bs =
    let
        len : Int
        len =
            Bytes.width bs
    in
    Bytes.Decode.decode (Bytes.Decode.loop ( len, [] ) bytesToListStep) bs
        |> Maybe.withDefault []


bytesToListStep : ( Int, List Int ) -> Bytes.Decode.Decoder (Bytes.Decode.Step ( Int, List Int ) (List Int))
bytesToListStep ( remaining, acc ) =
    if remaining <= 0 then
        Bytes.Decode.succeed (Bytes.Decode.Done (List.reverse acc))

    else
        Bytes.Decode.unsignedInt8
            |> Bytes.Decode.map (\b -> Bytes.Decode.Loop ( remaining - 1, b :: acc ))



-- ============================================================================
-- COMPAREBYTES V3: decode keys to String, sort with native JS string <
-- ============================================================================


{-| Deterministic strategy using String sort keys.

Each byte is decoded via `unsignedInt8` and converted to a `Char` via
`Char.fromCode`. Code points 0-255 are all BMP single code units, so
JS string `<` comparison preserves byte ordering.

The comparison itself is a single V8-optimized `<` operation (no linked
list traversal), but building the string costs `List Char` + `String.fromList`.

-}
deterministicV3 : CE.Strategy
deterministicV3 =
    { sortKeys = sortKeysByString
    , lengthMode = Definite
    }


sortKeysByString : List ( Bytes, BE.Encoder ) -> List ( Bytes, BE.Encoder )
sortKeysByString entries =
    entries
        |> List.map (\( bs, enc ) -> ( bytesToComparableString bs, ( bs, enc ) ))
        |> List.sortBy Tuple.first
        |> List.map Tuple.second


bytesToComparableString : Bytes -> String
bytesToComparableString bs =
    let
        len : Int
        len =
            Bytes.width bs
    in
    Bytes.Decode.decode (Bytes.Decode.loop ( len, [] ) bytesToCharsStep) bs
        |> Maybe.withDefault ""


bytesToCharsStep : ( Int, List Char ) -> Bytes.Decode.Decoder (Bytes.Decode.Step ( Int, List Char ) String)
bytesToCharsStep ( remaining, acc ) =
    if remaining <= 0 then
        Bytes.Decode.succeed
            (Bytes.Decode.Done (String.reverse (String.fromList acc)))

    else
        Bytes.Decode.unsignedInt8
            |> Bytes.Decode.map
                (\b -> Bytes.Decode.Loop ( remaining - 1, Char.fromCode b :: acc ))



-- ============================================================================
-- COMPAREBYTES V5: Hex string sort key
-- ============================================================================


{-| Deterministic strategy using hex string sort keys.

Uses `Hex.fromBytes` from the x-bytes package. Hex digits (0-9, a-f)
preserve byte ordering, so `List.sortBy` with string comparison gives
correct lexicographic byte order. The hex string is 2x the byte count
but comparison is a single V8-optimized `<` with no list traversal.

-}
deterministicV5 : CE.Strategy
deterministicV5 =
    { sortKeys = sortKeysByHex
    , lengthMode = Definite
    }


sortKeysByHex : List ( Bytes, BE.Encoder ) -> List ( Bytes, BE.Encoder )
sortKeysByHex entries =
    entries
        |> List.map (\( bs, enc ) -> ( Hex.fromBytes bs, ( bs, enc ) ))
        |> List.sortBy Tuple.first
        |> List.map Tuple.second



-- ============================================================================
-- FLOAT V2: check float32 first, skip float16 if float32 fails
-- ============================================================================


{-| Encode a float using float32-first detection order.

Checks float32 round-trip first. If it fails, emit float64 immediately
(1 check instead of 2 for true float64 values). If float32 succeeds,
then check float16.

Trade-off: float16 values pay 2 checks (float32 + float16) instead of 1.

-}
floatV2 : Float -> CE.Encoder
floatV2 f =
    if float32RoundTrips f then
        if float16RoundTrips f then
            CE.floatWithWidth FW16 f

        else
            CE.floatWithWidth FW32 f

    else
        CE.floatWithWidth FW64 f


float16RoundTrips : Float -> Bool
float16RoundTrips f =
    let
        encoded : Bytes
        encoded =
            BE.encode (Bytes.Floating.Encode.float16 Bytes.BE f)
    in
    case Bytes.Decode.decode (Bytes.Floating.Decode.float16 Bytes.BE) encoded of
        Just roundTripped ->
            if isNaN f then
                isNaN roundTripped

            else
                roundTripped == f

        Nothing ->
            False


float32RoundTrips : Float -> Bool
float32RoundTrips f =
    let
        encoded : Bytes
        encoded =
            BE.encode (BE.float32 Bytes.BE f)
    in
    case Bytes.Decode.decode (Bytes.Decode.float32 Bytes.BE) encoded of
        Just roundTripped ->
            if isNaN f then
                isNaN roundTripped

            else
                roundTripped == f

        Nothing ->
            False



-- ============================================================================
-- OPPORTUNITY #1: STRING ENCODING — AVOID INTERMEDIATE BUFFER
-- ============================================================================


{-| V1: current string encoding (encode to Bytes, measure width, copy).

Allocates an intermediate `ArrayBuffer` + `DataView`, writes the string once
into the temporary buffer, then copies the bytes into the final buffer.

-}
stringBEv1 : String -> BE.Encoder
stringBEv1 s =
    let
        encoded : Bytes
        encoded =
            BE.encode (BE.string s)

        len : Int
        len =
            Bytes.width encoded
    in
    BE.sequence
        [ encodeHeaderLocal 3 len
        , BE.bytes encoded
        ]


{-| V2: use `getStringWidth` to measure UTF-8 length without encoding.

Eliminates the intermediate buffer allocation and the copy. The string is
written directly into the final buffer by `BE.string`.

-}
stringBEv2 : String -> BE.Encoder
stringBEv2 s =
    let
        len : Int
        len =
            BE.getStringWidth s
    in
    BE.sequence
        [ encodeHeaderLocal 3 len
        , BE.string s
        ]


{-| V2b: `getStringWidth` + packed header (opportunities #1 + #2 combined).
-}
stringBEv2b : String -> BE.Encoder
stringBEv2b s =
    let
        len : Int
        len =
            BE.getStringWidth s
    in
    BE.sequence
        [ encodeHeaderPacked 3 len
        , BE.string s
        ]



-- ============================================================================
-- OPPORTUNITY #2: HEADER PACKING FOR ARGUMENT 24–255
-- ============================================================================


{-| V1: current header encoding (copy of `Cbor.Encode.encodeHeader`).

For argument 24–255, emits `BE.sequence [U8, U8]` — a `Seq` constructor,
2 cons cells, nil, and 2 `U8` constructors = 6 heap allocations.

-}
encodeHeaderLocal : Int -> Int -> BE.Encoder
encodeHeaderLocal majorType argument =
    let
        mt : Int
        mt =
            Bitwise.shiftLeftBy 5 majorType
    in
    if argument <= 23 then
        BE.unsignedInt8 (mt + argument)

    else if argument <= 0xFF then
        BE.sequence
            [ BE.unsignedInt8 (mt + 24)
            , BE.unsignedInt8 argument
            ]

    else if argument <= 0xFFFF then
        BE.sequence
            [ BE.unsignedInt8 (mt + 25)
            , BE.unsignedInt16 Bytes.BE argument
            ]

    else
        BE.sequence
            [ BE.unsignedInt8 (mt + 26)
            , BE.unsignedInt32 Bytes.BE argument
            ]


{-| V2: packed header for argument 24–255 (single `unsignedInt16`).

Packs the initial byte and argument into one `U16` write, reducing
6 heap allocations to 1. Other branches are unchanged.

-}
encodeHeaderPacked : Int -> Int -> BE.Encoder
encodeHeaderPacked majorType argument =
    let
        mt : Int
        mt =
            Bitwise.shiftLeftBy 5 majorType
    in
    if argument <= 23 then
        BE.unsignedInt8 (mt + argument)

    else if argument <= 0xFF then
        BE.unsignedInt16 Bytes.BE
            (Bitwise.or (Bitwise.shiftLeftBy 8 (mt + 24)) argument)

    else if argument <= 0xFFFF then
        BE.sequence
            [ BE.unsignedInt8 (mt + 25)
            , BE.unsignedInt16 Bytes.BE argument
            ]

    else
        BE.sequence
            [ BE.unsignedInt8 (mt + 26)
            , BE.unsignedInt32 Bytes.BE argument
            ]


{-| V1: byte string encoding with current header.
-}
bytesWithHeaderV1 : Bytes -> BE.Encoder
bytesWithHeaderV1 bs =
    BE.sequence
        [ encodeHeaderLocal 2 (Bytes.width bs)
        , BE.bytes bs
        ]


{-| V2: byte string encoding with packed header.
-}
bytesWithHeaderV2 : Bytes -> BE.Encoder
bytesWithHeaderV2 bs =
    BE.sequence
        [ encodeHeaderPacked 2 (Bytes.width bs)
        , BE.bytes bs
        ]



-- ============================================================================
-- OPPORTUNITY #3: BREAK APPENDING IN INDEFINITE-LENGTH MODE
-- ============================================================================


{-| V1: indefinite-length array with `++ [break]` — O(N) list append.
-}
arrayIndefiniteV1 : List BE.Encoder -> BE.Encoder
arrayIndefiniteV1 items =
    BE.sequence
        (BE.unsignedInt8 0x9F
            :: items
            ++ [ BE.unsignedInt8 0xFF ]
        )


{-| V2: indefinite-length array with nested `sequence` — O(1).

The extra `Seq` node is trivial compared to the O(N) list copy.

-}
arrayIndefiniteV2 : List BE.Encoder -> BE.Encoder
arrayIndefiniteV2 items =
    BE.sequence
        [ BE.unsignedInt8 0x9F
        , BE.sequence items
        , BE.unsignedInt8 0xFF
        ]



-- ============================================================================
-- OPPORTUNITY #4: CONCATMAP → FOLDR IN MAP ENTRY ENCODING
-- ============================================================================


{-| V1: map encoding using `List.concatMap` (current approach).

Allocates N intermediate 2-element lists, then concatenates them.

-}
mapIntV1 : List ( Int, Int ) -> BE.Encoder
mapIntV1 entries =
    BE.sequence
        (encodeHeaderLocal 5 (List.length entries)
            :: List.concatMap
                (\( k, v ) ->
                    [ encodeHeaderLocal 0 k
                    , encodeHeaderLocal 0 v
                    ]
                )
                entries
        )


{-| V2: map encoding using `List.foldr` (no intermediate sublists).

Builds the flat encoder list directly with cons operations.

-}
mapIntV2 : List ( Int, Int ) -> BE.Encoder
mapIntV2 entries =
    BE.sequence
        (encodeHeaderLocal 5 (List.length entries)
            :: List.foldr
                (\( k, v ) acc ->
                    encodeHeaderLocal 0 k
                        :: encodeHeaderLocal 0 v
                        :: acc
                )
                []
                entries
        )



-- ============================================================================
-- OPPORTUNITY #5: FLOAT FAST-REJECT GUARD
-- ============================================================================


{-| V3: float encoding with range guard before float16 round-trip.

If `abs f > 65504`, skip the float16 round-trip check entirely. IEEE 754
float16 can represent values up to 65504, so larger values can never be
float16. The `abs` + comparison is a single CPU instruction vs two
`DataView` allocations + a decode for the round-trip check.

-}
floatV3 : Float -> CE.Encoder
floatV3 f =
    if abs f <= 65504 && float16RoundTrips f then
        CE.floatWithWidth FW16 f

    else if float32RoundTrips f then
        CE.floatWithWidth FW32 f

    else
        CE.floatWithWidth FW64 f
