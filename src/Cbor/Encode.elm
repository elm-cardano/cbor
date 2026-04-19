module Cbor.Encode exposing
    ( Encoder, Strategy, encode
    , int, float, bool, null, undefined, string, bytes, simple
    , intWithWidth, floatWithWidth
    , stringChunked, bytesChunked
    , array, map, tag, keyedRecord, list, sequence
    , item, rawUnsafe
    , deterministic, canonical, ctap2, unsorted
    )

{-| CBOR encoding combinators.

Build encoders for your domain types, then apply a `Strategy` to produce bytes.

    import Cbor.Encode as CE

    type alias Person =
        { name : String, age : Int }

    encodePerson : Person -> CE.Encoder
    encodePerson p =
        CE.keyedRecord CE.int
            [ ( 0, Just (CE.string p.name) )
            , ( 1, Just (CE.int p.age) )
            ]

    CE.encode CE.deterministic (encodePerson alice)

@docs Encoder, Strategy, encode


## Primitives

@docs int, float, bool, null, undefined, string, bytes, simple


## Explicit Width Control

@docs intWithWidth, floatWithWidth


## Chunked Strings/Bytes

@docs stringChunked, bytesChunked


## Collections

@docs array, map, tag, keyedRecord, list, sequence


## Escape Hatches

@docs item, rawUnsafe


## Predefined Strategies

@docs deterministic, canonical, ctap2, unsorted

-}

import Bitwise
import Bytes
import Bytes.Decode
import Bytes.Encode as BE
import Bytes.Floating.Decode
import Bytes.Floating.Encode
import Cbor exposing (CborItem(..), FloatWidth(..), IntWidth(..), Length(..), Sign(..), Tag, tagToInt)
import Hex


{-| An encoder that produces CBOR bytes when given a `Strategy`.
-}
type Encoder
    = Encoder (Strategy -> BE.Encoder)
    | Direct BE.Encoder


{-| Controls key ordering and length mode for collections.

  - `sortKeys` reorders map entries. Each entry is `( keyBytes, entryEncoder )`
    where `keyBytes` is the encoded key (for comparison) and `entryEncoder`
    encodes the full key+value pair.
  - `lengthMode` controls whether arrays and maps use definite or indefinite
    length encoding.

-}
type alias Strategy =
    { sortKeys : List ( Bytes.Bytes, BE.Encoder ) -> List ( Bytes.Bytes, BE.Encoder )
    , lengthMode : Length
    }



-- PREDEFINED STRATEGIES


{-| RFC 8949 §4.2.1 Core Deterministic Encoding.

Lexicographic byte order on encoded keys. Definite length.

-}
deterministic : Strategy
deterministic =
    { sortKeys = sortKeysByHex
    , lengthMode = Definite
    }


{-| RFC 7049 / RFC 8949 §4.2.3 Canonical CBOR.

Shorter keys first, then lexicographic within same length. Definite length.

-}
canonical : Strategy
canonical =
    { sortKeys = sortKeysCanonicalByHex
    , lengthMode = Definite
    }


{-| CTAP2 (FIDO) canonical encoding.

Shorter keys first, then lexicographic within same length. Definite length.
(Same ordering as canonical for CBOR-encoded keys.)

-}
ctap2 : Strategy
ctap2 =
    { sortKeys = sortKeysCanonicalByHex
    , lengthMode = Definite
    }


{-| Preserve insertion order. Definite length.
-}
unsorted : Strategy
unsorted =
    { sortKeys = identity
    , lengthMode = Definite
    }



-- RUNNING


{-| Apply a strategy to an encoder and produce CBOR bytes.
-}
encode : Strategy -> Encoder -> Bytes.Bytes
encode strategy encoder =
    BE.encode (applyStrategy strategy encoder)


applyStrategy : Strategy -> Encoder -> BE.Encoder
applyStrategy strategy encoder =
    case encoder of
        Encoder enc ->
            enc strategy

        Direct be ->
            be


allDirect : List Encoder -> Bool
allDirect encoders =
    case encoders of
        [] ->
            True

        (Direct _) :: rest ->
            allDirect rest

        (Encoder _) :: _ ->
            False


unwrapDirect : Encoder -> BE.Encoder
unwrapDirect encoder =
    case encoder of
        Direct be ->
            be

        Encoder _ ->
            -- unreachable when guarded by allDirect
            BE.sequence []



-- PRIMITIVES


{-| Encode an integer using the shortest form.

Handles both positive and negative values within Elm's safe integer range.

-}
int : Int -> Encoder
int n =
    Direct (encodeInt n)


{-| Encode a float using the shortest IEEE 754 form that preserves the value.
-}
float : Float -> Encoder
float f =
    Direct (encodeFloat f)


{-| Encode a boolean.
-}
bool : Bool -> Encoder
bool b =
    if b then
        Direct (BE.unsignedInt8 0xF5)

    else
        Direct (BE.unsignedInt8 0xF4)


{-| Encode a CBOR null.
-}
null : Encoder
null =
    Direct (BE.unsignedInt8 0xF6)


{-| Encode a CBOR undefined.
-}
undefined : Encoder
undefined =
    Direct (BE.unsignedInt8 0xF7)


{-| Encode a UTF-8 text string (major type 3).
-}
string : String -> Encoder
string s =
    let
        len : Int
        len =
            BE.getStringWidth s
    in
    Direct
        (BE.sequence
            [ encodeHeader 3 len
            , BE.string s
            ]
        )


{-| Encode a byte string (major type 2).
-}
bytes : Bytes.Bytes -> Encoder
bytes bs =
    Direct
        (BE.sequence
            [ encodeHeader 2 (Bytes.width bs)
            , BE.bytes bs
            ]
        )


{-| Encode a CBOR simple value (major type 7, values 0–255 excluding 20–23).
-}
simple : Int -> Encoder
simple n =
    if n < 24 then
        Direct (BE.unsignedInt8 (0xE0 + n))

    else
        Direct
            (BE.sequence
                [ BE.unsignedInt8 0xF8
                , BE.unsignedInt8 n
                ]
            )



-- EXPLICIT WIDTH


{-| Encode an integer with a specific wire width. Ignores strategy.

The value is encoded in the given width regardless of whether a shorter
encoding exists. Useful for lossless round-tripping.

-}
intWithWidth : IntWidth -> Int -> Encoder
intWithWidth width n =
    Direct (encodeIntWithWidth width n)


{-| Encode a float with a specific IEEE 754 width. Ignores strategy.
-}
floatWithWidth : FloatWidth -> Float -> Encoder
floatWithWidth width f =
    Direct
        (case width of
            FW16 ->
                BE.sequence
                    [ BE.unsignedInt8 0xF9
                    , Bytes.Floating.Encode.float16 Bytes.BE f
                    ]

            FW32 ->
                BE.sequence
                    [ BE.unsignedInt8 0xFA
                    , BE.float32 Bytes.BE f
                    ]

            FW64 ->
                BE.sequence
                    [ BE.unsignedInt8 0xFB
                    , BE.float64 Bytes.BE f
                    ]
        )



-- CHUNKED


{-| Encode a chunked text string using indefinite-length encoding (major type 3).
-}
stringChunked : List String -> Encoder
stringChunked chunks =
    Direct
        (BE.sequence
            [ BE.unsignedInt8 0x7F
            , BE.sequence (List.map encodeStringChunk chunks)
            , BE.unsignedInt8 0xFF
            ]
        )


encodeStringChunk : String -> BE.Encoder
encodeStringChunk s =
    let
        len : Int
        len =
            BE.getStringWidth s
    in
    BE.sequence
        [ encodeHeader 3 len
        , BE.string s
        ]


{-| Encode chunked bytes using indefinite-length encoding (major type 2).
-}
bytesChunked : List Bytes.Bytes -> Encoder
bytesChunked chunks =
    Direct
        (BE.sequence
            [ BE.unsignedInt8 0x5F
            , BE.sequence (List.map encodeByteChunk chunks)
            , BE.unsignedInt8 0xFF
            ]
        )


encodeByteChunk : Bytes.Bytes -> BE.Encoder
encodeByteChunk bs =
    BE.sequence
        [ encodeHeader 2 (Bytes.width bs)
        , BE.bytes bs
        ]



-- COLLECTIONS


{-| Encode a CBOR array (major type 4).

The strategy determines whether definite or indefinite length encoding is used.

-}
array : List Encoder -> Encoder
array items =
    let
        arraySequence : List BE.Encoder -> Strategy -> BE.Encoder
        arraySequence itemsEncoders strategy =
            case strategy.lengthMode of
                Definite ->
                    BE.sequence (encodeHeader 4 (List.length items) :: itemsEncoders)

                Indefinite ->
                    BE.sequence
                        [ BE.unsignedInt8 0x9F
                        , BE.sequence itemsEncoders
                        , BE.unsignedInt8 0xFF
                        ]
    in
    if allDirect items then
        Encoder (arraySequence (List.map unwrapDirect items))

    else
        Encoder (\strategy -> arraySequence (List.map (applyStrategy strategy) items) strategy)


{-| Encode a CBOR map (major type 5).

The strategy determines key ordering and length mode.

-}
map : List ( Encoder, Encoder ) -> Encoder
map entries =
    Encoder
        (\strategy ->
            let
                encodedEntries : List ( Bytes.Bytes, BE.Encoder )
                encodedEntries =
                    List.map
                        (\( keyEnc, valEnc ) ->
                            let
                                keyBytes : Bytes.Bytes
                                keyBytes =
                                    BE.encode (applyStrategy strategy keyEnc)

                                entryEncoder : BE.Encoder
                                entryEncoder =
                                    BE.sequence
                                        [ BE.bytes keyBytes
                                        , applyStrategy strategy valEnc
                                        ]
                            in
                            ( keyBytes, entryEncoder )
                        )
                        entries

                sorted : List ( Bytes.Bytes, BE.Encoder )
                sorted =
                    strategy.sortKeys encodedEntries

                entryEncoders : List BE.Encoder
                entryEncoders =
                    List.map Tuple.second sorted
            in
            case strategy.lengthMode of
                Definite ->
                    BE.sequence (encodeHeader 5 (List.length entries) :: entryEncoders)

                Indefinite ->
                    BE.sequence
                        [ BE.unsignedInt8 0xBF
                        , BE.sequence entryEncoders
                        , BE.unsignedInt8 0xFF
                        ]
        )


{-| Encode a CBOR semantic tag (major type 6).
-}
tag : Tag -> Encoder -> Encoder
tag t enclosed =
    case enclosed of
        Direct be ->
            Direct
                (BE.sequence
                    [ encodeHeader 6 (tagToInt t)
                    , be
                    ]
                )

        Encoder enc ->
            Encoder
                (\strategy ->
                    BE.sequence
                        [ encodeHeader 6 (tagToInt t)
                        , enc strategy
                        ]
                )


{-| Encode a keyed record as a CBOR map with a shared key encoder.

`Nothing` entries are omitted from the output — this distinguishes
"field absent" from "field is null."

-}
keyedRecord : (k -> Encoder) -> List ( k, Maybe Encoder ) -> Encoder
keyedRecord keyEncoder entries =
    let
        presentEntries : List ( Encoder, Encoder )
        presentEntries =
            List.filterMap
                (\( k, maybeEnc ) ->
                    case maybeEnc of
                        Just enc ->
                            Just ( keyEncoder k, enc )

                        Nothing ->
                            Nothing
                )
                entries
    in
    map presentEntries


{-| Encode a list of items using the same element encoder.
-}
list : (a -> Encoder) -> List a -> Encoder
list encodeElement items =
    array (List.map encodeElement items)


{-| Concatenate multiple CBOR items without a wrapping array.

Produces a CBOR Sequence (RFC 8742).

-}
sequence : List Encoder -> Encoder
sequence encoders =
    if allDirect encoders then
        Direct (BE.sequence (List.map unwrapDirect encoders))

    else
        Encoder
            (\strategy ->
                BE.sequence (List.map (applyStrategy strategy) encoders)
            )



-- ESCAPE HATCHES


{-| Encode a `CborItem` losslessly. Ignores strategy entirely.
-}
item : CborItem -> Encoder
item cborItem =
    Direct (encodeItem cborItem)


{-| Inject pre-encoded CBOR bytes without validation. Ignores strategy.

If the bytes are not valid CBOR, the output is malformed.

-}
rawUnsafe : Bytes.Bytes -> Encoder
rawUnsafe bs =
    Direct (BE.bytes bs)



-- INTERNAL: CBOR ENCODING HELPERS


encodeInt : Int -> BE.Encoder
encodeInt n =
    if n >= 0 then
        encodeHeader 0 n

    else
        encodeHeader 1 (-1 - n)


encodeIntWithWidth : IntWidth -> Int -> BE.Encoder
encodeIntWithWidth width n =
    let
        majorType : Int
        majorType =
            if n >= 0 then
                0

            else
                1

        arg : Int
        arg =
            if n >= 0 then
                n

            else
                -1 - n
    in
    encodeHeaderWithWidth width majorType arg


encodeHeader : Int -> Int -> BE.Encoder
encodeHeader majorType argument =
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

    else if argument <= 0xFFFFFFFF then
        BE.sequence
            [ BE.unsignedInt8 (mt + 26)
            , BE.unsignedInt32 Bytes.BE argument
            ]

    else
        -- 64-bit: split into two 32-bit halves
        let
            hi : Int
            hi =
                argument // 0x0000000100000000

            lo : Int
            lo =
                argument - hi * 0x0000000100000000
        in
        BE.sequence
            [ BE.unsignedInt8 (mt + 27)
            , BE.unsignedInt32 Bytes.BE hi
            , BE.unsignedInt32 Bytes.BE lo
            ]


encodeHeaderWithWidth : IntWidth -> Int -> Int -> BE.Encoder
encodeHeaderWithWidth width majorType argument =
    let
        mt : Int
        mt =
            Bitwise.shiftLeftBy 5 majorType
    in
    case width of
        IW0 ->
            BE.unsignedInt8 (mt + argument)

        IW8 ->
            BE.sequence
                [ BE.unsignedInt8 (mt + 24)
                , BE.unsignedInt8 argument
                ]

        IW16 ->
            BE.sequence
                [ BE.unsignedInt8 (mt + 25)
                , BE.unsignedInt16 Bytes.BE argument
                ]

        IW32 ->
            BE.sequence
                [ BE.unsignedInt8 (mt + 26)
                , BE.unsignedInt32 Bytes.BE argument
                ]

        IW64 ->
            let
                hi : Int
                hi =
                    argument // 0x0000000100000000

                lo : Int
                lo =
                    argument - hi * 0x0000000100000000
            in
            BE.sequence
                [ BE.unsignedInt8 (mt + 27)
                , BE.unsignedInt32 Bytes.BE hi
                , BE.unsignedInt32 Bytes.BE lo
                ]


encodeFloat : Float -> BE.Encoder
encodeFloat f =
    if (isNaN f || isInfinite f || abs f <= 65504) && float16RoundTrips f then
        BE.sequence
            [ BE.unsignedInt8 0xF9
            , Bytes.Floating.Encode.float16 Bytes.BE f
            ]

    else if float32RoundTrips f then
        BE.sequence
            [ BE.unsignedInt8 0xFA
            , BE.float32 Bytes.BE f
            ]

    else
        BE.sequence
            [ BE.unsignedInt8 0xFB
            , BE.float64 Bytes.BE f
            ]


float16RoundTrips : Float -> Bool
float16RoundTrips f =
    let
        encoded : Bytes.Bytes
        encoded =
            BE.encode <| Bytes.Floating.Encode.float16 Bytes.BE f

        decoded : Maybe Float
        decoded =
            Bytes.Decode.decode (Bytes.Floating.Decode.float16 Bytes.BE) encoded
    in
    case decoded of
        Just roundTripped ->
            -- Use bitwise comparison for NaN
            if isNaN f then
                isNaN roundTripped

            else
                roundTripped == f

        Nothing ->
            False


float32RoundTrips : Float -> Bool
float32RoundTrips f =
    let
        encoded : Bytes.Bytes
        encoded =
            BE.encode (BE.float32 Bytes.BE f)

        decoded : Maybe Float
        decoded =
            Bytes.Decode.decode (Bytes.Decode.float32 Bytes.BE) encoded
    in
    case decoded of
        Just roundTripped ->
            if isNaN f then
                isNaN roundTripped

            else
                roundTripped == f

        Nothing ->
            False


encodeItem : CborItem -> BE.Encoder
encodeItem cborItem =
    case cborItem of
        CborInt52 width n ->
            encodeIntWithWidth width n

        CborInt64 sign bs ->
            let
                mt : Int
                mt =
                    case sign of
                        Positive ->
                            0

                        Negative ->
                            1
            in
            BE.sequence
                [ BE.unsignedInt8 (Bitwise.shiftLeftBy 5 mt + 27)
                , BE.bytes bs
                ]

        CborByteString bs ->
            BE.sequence
                [ encodeHeader 2 (Bytes.width bs)
                , BE.bytes bs
                ]

        CborByteStringChunked chunks ->
            BE.sequence
                [ BE.unsignedInt8 0x5F
                , BE.sequence
                    (List.map
                        (\bs ->
                            BE.sequence
                                [ encodeHeader 2 (Bytes.width bs)
                                , BE.bytes bs
                                ]
                        )
                        chunks
                    )
                , BE.unsignedInt8 0xFF
                ]

        CborString s ->
            let
                len : Int
                len =
                    BE.getStringWidth s
            in
            BE.sequence
                [ encodeHeader 3 len
                , BE.string s
                ]

        CborStringChunked chunks ->
            BE.sequence
                [ BE.unsignedInt8 0x7F
                , BE.sequence
                    (List.map
                        (\s ->
                            let
                                len : Int
                                len =
                                    BE.getStringWidth s
                            in
                            BE.sequence
                                [ encodeHeader 3 len
                                , BE.string s
                                ]
                        )
                        chunks
                    )
                , BE.unsignedInt8 0xFF
                ]

        CborArray length items ->
            case length of
                Definite ->
                    BE.sequence (encodeHeader 4 (List.length items) :: List.map encodeItem items)

                Indefinite ->
                    BE.sequence
                        [ BE.unsignedInt8 0x9F
                        , BE.sequence (List.map encodeItem items)
                        , BE.unsignedInt8 0xFF
                        ]

        CborMap length entries ->
            let
                entryEncoders : List BE.Encoder
                entryEncoders =
                    List.foldr
                        (\e acc ->
                            encodeItem e.key :: encodeItem e.value :: acc
                        )
                        []
                        entries
            in
            case length of
                Definite ->
                    BE.sequence
                        (encodeHeader 5 (List.length entries)
                            :: entryEncoders
                        )

                Indefinite ->
                    BE.sequence
                        [ BE.unsignedInt8 0xBF
                        , BE.sequence entryEncoders
                        , BE.unsignedInt8 0xFF
                        ]

        CborTag t enclosed ->
            BE.sequence
                [ encodeHeader 6 (tagToInt t)
                , encodeItem enclosed
                ]

        CborBool b ->
            if b then
                BE.unsignedInt8 0xF5

            else
                BE.unsignedInt8 0xF4

        CborFloat width f ->
            case width of
                FW16 ->
                    BE.sequence
                        [ BE.unsignedInt8 0xF9
                        , Bytes.Floating.Encode.float16 Bytes.BE f
                        ]

                FW32 ->
                    BE.sequence
                        [ BE.unsignedInt8 0xFA
                        , BE.float32 Bytes.BE f
                        ]

                FW64 ->
                    BE.sequence
                        [ BE.unsignedInt8 0xFB
                        , BE.float64 Bytes.BE f
                        ]

        CborNull ->
            BE.unsignedInt8 0xF6

        CborUndefined ->
            BE.unsignedInt8 0xF7

        CborSimple _ n ->
            if n < 24 then
                BE.unsignedInt8 (0xE0 + n)

            else
                BE.sequence
                    [ BE.unsignedInt8 0xF8
                    , BE.unsignedInt8 n
                    ]



-- INTERNAL: KEY SORTING


sortKeysByHex : List ( Bytes.Bytes, BE.Encoder ) -> List ( Bytes.Bytes, BE.Encoder )
sortKeysByHex entries =
    entries
        |> List.map (\( bs, enc ) -> ( Hex.fromBytes bs, ( bs, enc ) ))
        |> List.sortBy Tuple.first
        |> List.map Tuple.second


sortKeysCanonicalByHex : List ( Bytes.Bytes, BE.Encoder ) -> List ( Bytes.Bytes, BE.Encoder )
sortKeysCanonicalByHex entries =
    entries
        |> List.map (\( bs, enc ) -> ( ( Bytes.width bs, Hex.fromBytes bs ), ( bs, enc ) ))
        |> List.sortBy Tuple.first
        |> List.map Tuple.second
