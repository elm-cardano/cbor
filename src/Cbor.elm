module Cbor exposing
    ( CborItem(..), IntWidth(..), FloatWidth(..), SimpleWidth(..), Length(..), Sign(..), Tag(..), tagToInt
    , diagnose
    )

{-| CBOR (Concise Binary Object Representation) data model and diagnostic notation.

This module defines `CborItem`, a lossless representation of any well-formed
CBOR encoding per [RFC 8949](https://datatracker.ietf.org/doc/html/rfc8949).

@docs CborItem, IntWidth, FloatWidth, SimpleWidth, Length, Sign, Tag, tagToInt
@docs diagnose

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Hex


{-| A lossless representation of a CBOR data item.

Round-tripping (decode → re-encode) preserves the exact original bytes.
Encoding details (integer width, float precision, definite vs indefinite
length) are captured for faithful diagnostic output.

The primary user-facing API is the combinator layer in `Cbor.Encode` and
`Cbor.Decode`. Use `CborItem` as an escape hatch for generic CBOR handling,
diagnostics, and protocol debugging.

-}
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


{-| How an integer value was encoded on the wire.

  - `IW0` — inline in the additional info (values 0–23, 0 extra bytes)
  - `IW8` — 1-byte uint8 argument
  - `IW16` — 2-byte uint16 argument
  - `IW32` — 4-byte uint32 argument
  - `IW64` — 8-byte uint64 argument

-}
type IntWidth
    = IW0
    | IW8
    | IW16
    | IW32
    | IW64


{-| How a float was encoded on the wire.

  - `FW16` — IEEE 754 half-precision (2 bytes)
  - `FW32` — IEEE 754 single-precision (4 bytes)
  - `FW64` — IEEE 754 double-precision (8 bytes)

-}
type FloatWidth
    = FW16
    | FW32
    | FW64


{-| How a simple value was encoded on the wire.

  - `SW0` — inline in the additional info (values 0–19, 0 extra bytes)
  - `SW8` — 1-byte argument (values 32–255)

-}
type SimpleWidth
    = SW0
    | SW8


{-| Whether an array or map used definite or indefinite length encoding.
-}
type Length
    = Definite
    | Indefinite


{-| The sign of a CBOR integer, corresponding to the major type.

  - `Positive` — CBOR major type 0 (unsigned integer)
  - `Negative` — CBOR major type 1 (negative integer, value = −1 − argument)

-}
type Sign
    = Positive
    | Negative


{-| CBOR semantic tags from the IANA registry.

Named variants for well-known tags. `Unknown Int` as the catch-all for
unrecognized tag numbers.

-}
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



-- DIAGNOSTICS


{-| Produce CBOR diagnostic notation (RFC 8949 Section 8) for a CborItem.

Encoding indicators are appended as suffixes (e.g., `1_0`, `1.5_1`).
Indefinite-length containers use the `[_ ...]` and `{_ ...}` notation.

-}
diagnose : CborItem -> String
diagnose item =
    case item of
        CborInt52 width n ->
            String.fromInt n ++ intWidthSuffix width

        CborInt64 sign bs ->
            let
                arg =
                    bytesToDiagInt bs
            in
            case sign of
                Positive ->
                    arg ++ "_3"

                Negative ->
                    "-" ++ addOneToString arg ++ "_3"

        CborByteString bs ->
            "h'" ++ Hex.fromBytes bs ++ "'"

        CborByteStringChunked chunks ->
            "(_ " ++ String.join ", " (List.map (\b -> "h'" ++ Hex.fromBytes b ++ "'") chunks) ++ ")"

        CborString s ->
            "\"" ++ escapeString s ++ "\""

        CborStringChunked chunks ->
            "(_ " ++ String.join ", " (List.map (\c -> "\"" ++ escapeString c ++ "\"") chunks) ++ ")"

        CborArray length items ->
            let
                prefix =
                    case length of
                        Definite ->
                            "["

                        Indefinite ->
                            "[_ "

                contents =
                    String.join ", " (List.map diagnose items)
            in
            prefix ++ contents ++ "]"

        CborMap length entries ->
            let
                prefix =
                    case length of
                        Definite ->
                            "{"

                        Indefinite ->
                            "{_ "

                contents =
                    String.join ", "
                        (List.map (\e -> diagnose e.key ++ ": " ++ diagnose e.value) entries)
            in
            prefix ++ contents ++ "}"

        CborTag tag enclosed ->
            String.fromInt (tagToInt tag) ++ "(" ++ diagnose enclosed ++ ")"

        CborBool b ->
            if b then
                "true"

            else
                "false"

        CborFloat width f ->
            floatToString f ++ floatWidthSuffix width

        CborNull ->
            "null"

        CborUndefined ->
            "undefined"

        CborSimple _ n ->
            "simple(" ++ String.fromInt n ++ ")"


intWidthSuffix : IntWidth -> String
intWidthSuffix w =
    case w of
        IW0 ->
            ""

        IW8 ->
            "_0"

        IW16 ->
            "_1"

        IW32 ->
            "_2"

        IW64 ->
            "_3"


floatWidthSuffix : FloatWidth -> String
floatWidthSuffix w =
    case w of
        FW16 ->
            "_1"

        FW32 ->
            "_2"

        FW64 ->
            "_3"


floatToString : Float -> String
floatToString f =
    if isNaN f then
        "NaN"

    else if isInfinite f then
        if f > 0 then
            "Infinity"

        else
            "-Infinity"

    else
        let
            s =
                String.fromFloat f
        in
        if String.contains "." s || String.contains "e" s then
            s

        else
            s ++ ".0"


{-| Convert a tag to its IANA-registered integer number.
-}
tagToInt : Tag -> Int
tagToInt tag =
    case tag of
        StandardDateTime ->
            0

        EpochDateTime ->
            1

        PositiveBigNum ->
            2

        NegativeBigNum ->
            3

        DecimalFraction ->
            4

        BigFloat ->
            5

        Base64UrlConversion ->
            21

        Base64Conversion ->
            22

        Base16Conversion ->
            23

        Cbor ->
            24

        Uri ->
            32

        Base64Url ->
            33

        Base64 ->
            34

        Regex ->
            35

        Mime ->
            36

        IsCbor ->
            55799

        Unknown n ->
            n


escapeString : String -> String
escapeString s =
    String.foldl
        (\c acc ->
            acc ++ escapeChar c
        )
        ""
        s


escapeChar : Char -> String
escapeChar c =
    case c of
        '\\' ->
            "\\\\"

        '"' ->
            "\\\""

        '\n' ->
            "\\n"

        '\u{000D}' ->
            "\\r"

        '\t' ->
            "\\t"

        _ ->
            String.fromChar c


bytesToDiagInt : Bytes -> String
bytesToDiagInt bs =
    let
        len =
            Bytes.width bs

        decoder =
            Bytes.Decode.loop ( len, 0 ) diagIntStep
    in
    case Bytes.Decode.decode decoder bs of
        Just n ->
            String.fromInt n

        Nothing ->
            "0"


diagIntStep : ( Int, Int ) -> Bytes.Decode.Decoder (Bytes.Decode.Step ( Int, Int ) Int)
diagIntStep ( remaining, acc ) =
    if remaining <= 0 then
        Bytes.Decode.succeed (Bytes.Decode.Done acc)

    else
        Bytes.Decode.unsignedInt8
            |> Bytes.Decode.map
                (\byte ->
                    Bytes.Decode.Loop ( remaining - 1, acc * 256 + byte )
                )


addOneToString : String -> String
addOneToString s =
    case String.toInt s of
        Just n ->
            String.fromInt (n + 1)

        Nothing ->
            s
