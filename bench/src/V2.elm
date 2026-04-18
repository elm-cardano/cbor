module V2 exposing
    ( deterministicV2, canonicalV2
    , deterministicV3
    , deterministicV5
    , floatV2
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

-}

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
