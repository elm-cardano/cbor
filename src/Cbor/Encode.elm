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


{-| An encoder that produces CBOR bytes when given a `Strategy`.
-}
type Encoder
    = Encoder (Strategy -> BE.Encoder)


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
    { sortKeys = List.sortWith compareByteKeys
    , lengthMode = Definite
    }


{-| RFC 7049 / RFC 8949 §4.2.3 Canonical CBOR.

Shorter keys first, then lexicographic within same length. Definite length.

-}
canonical : Strategy
canonical =
    { sortKeys = List.sortWith canonicalCompare
    , lengthMode = Definite
    }


{-| CTAP2 (FIDO) canonical encoding.

Shorter keys first, then lexicographic within same length. Definite length.
(Same ordering as canonical for CBOR-encoded keys.)

-}
ctap2 : Strategy
ctap2 =
    { sortKeys = List.sortWith canonicalCompare
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
encode strategy (Encoder enc) =
    BE.encode (enc strategy)



-- PRIMITIVES


{-| Encode an integer using the shortest form.

Handles both positive and negative values within Elm's safe integer range.

-}
int : Int -> Encoder
int n =
    Encoder (\_ -> encodeInt n)


{-| Encode a float using the shortest IEEE 754 form that preserves the value.
-}
float : Float -> Encoder
float f =
    Encoder (\_ -> encodeFloat f)


{-| Encode a boolean.
-}
bool : Bool -> Encoder
bool b =
    Encoder
        (\_ ->
            if b then
                BE.unsignedInt8 0xF5

            else
                BE.unsignedInt8 0xF4
        )


{-| Encode a CBOR null.
-}
null : Encoder
null =
    Encoder (\_ -> BE.unsignedInt8 0xF6)


{-| Encode a CBOR undefined.
-}
undefined : Encoder
undefined =
    Encoder (\_ -> BE.unsignedInt8 0xF7)


{-| Encode a UTF-8 text string (major type 3).
-}
string : String -> Encoder
string s =
    Encoder
        (\_ ->
            let
                encoded =
                    BE.encode (BE.string s)

                len =
                    Bytes.width encoded
            in
            BE.sequence
                [ encodeHeader 3 len
                , BE.bytes encoded
                ]
        )


{-| Encode a byte string (major type 2).
-}
bytes : Bytes.Bytes -> Encoder
bytes bs =
    Encoder
        (\_ ->
            BE.sequence
                [ encodeHeader 2 (Bytes.width bs)
                , BE.bytes bs
                ]
        )


{-| Encode a CBOR simple value (major type 7, values 0–255 excluding 20–23).
-}
simple : Int -> Encoder
simple n =
    Encoder
        (\_ ->
            if n < 24 then
                BE.unsignedInt8 (0xE0 + n)

            else
                BE.sequence
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
    Encoder (\_ -> encodeIntWithWidth width n)


{-| Encode a float with a specific IEEE 754 width. Ignores strategy.
-}
floatWithWidth : FloatWidth -> Float -> Encoder
floatWithWidth width f =
    Encoder
        (\_ ->
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
        )



-- CHUNKED


{-| Encode a chunked text string using indefinite-length encoding (major type 3).
-}
stringChunked : List String -> Encoder
stringChunked chunks =
    Encoder
        (\_ ->
            let
                encodeChunk s =
                    let
                        encoded =
                            BE.encode (BE.string s)

                        len =
                            Bytes.width encoded
                    in
                    BE.sequence
                        [ encodeHeader 3 len
                        , BE.bytes encoded
                        ]
            in
            BE.sequence
                (BE.unsignedInt8 0x7F
                    :: List.map encodeChunk chunks
                    ++ [ BE.unsignedInt8 0xFF ]
                )
        )


{-| Encode chunked bytes using indefinite-length encoding (major type 2).
-}
bytesChunked : List Bytes.Bytes -> Encoder
bytesChunked chunks =
    Encoder
        (\_ ->
            let
                encodeChunk bs =
                    BE.sequence
                        [ encodeHeader 2 (Bytes.width bs)
                        , BE.bytes bs
                        ]
            in
            BE.sequence
                (BE.unsignedInt8 0x5F
                    :: List.map encodeChunk chunks
                    ++ [ BE.unsignedInt8 0xFF ]
                )
        )



-- COLLECTIONS


{-| Encode a CBOR array (major type 4).

The strategy determines whether definite or indefinite length encoding is used.

-}
array : List Encoder -> Encoder
array items =
    Encoder
        (\strategy ->
            let
                encodedItems =
                    List.map (\(Encoder enc) -> enc strategy) items
            in
            case strategy.lengthMode of
                Definite ->
                    BE.sequence (encodeHeader 4 (List.length items) :: encodedItems)

                Indefinite ->
                    BE.sequence
                        (BE.unsignedInt8 0x9F
                            :: encodedItems
                            ++ [ BE.unsignedInt8 0xFF ]
                        )
        )


{-| Encode a CBOR map (major type 5).

The strategy determines key ordering and length mode.

-}
map : List ( Encoder, Encoder ) -> Encoder
map entries =
    Encoder
        (\strategy ->
            let
                encodedEntries =
                    List.map
                        (\( Encoder keyEnc, Encoder valEnc ) ->
                            let
                                keyBytes =
                                    BE.encode (keyEnc strategy)

                                entryEncoder =
                                    BE.sequence
                                        [ BE.bytes keyBytes
                                        , valEnc strategy
                                        ]
                            in
                            ( keyBytes, entryEncoder )
                        )
                        entries

                sorted =
                    strategy.sortKeys encodedEntries

                entryEncoders =
                    List.map Tuple.second sorted
            in
            case strategy.lengthMode of
                Definite ->
                    BE.sequence (encodeHeader 5 (List.length entries) :: entryEncoders)

                Indefinite ->
                    BE.sequence
                        (BE.unsignedInt8 0xBF
                            :: entryEncoders
                            ++ [ BE.unsignedInt8 0xFF ]
                        )
        )


{-| Encode a CBOR semantic tag (major type 6).
-}
tag : Tag -> Encoder -> Encoder
tag t (Encoder enclosedEnc) =
    Encoder
        (\strategy ->
            BE.sequence
                [ encodeHeader 6 (tagToInt t)
                , enclosedEnc strategy
                ]
        )


{-| Encode a keyed record as a CBOR map with a shared key encoder.

`Nothing` entries are omitted from the output — this distinguishes
"field absent" from "field is null."

-}
keyedRecord : (k -> Encoder) -> List ( k, Maybe Encoder ) -> Encoder
keyedRecord keyEncoder entries =
    let
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
    Encoder
        (\strategy ->
            BE.sequence (List.map (\(Encoder enc) -> enc strategy) encoders)
        )



-- ESCAPE HATCHES


{-| Encode a `CborItem` losslessly. Ignores strategy entirely.
-}
item : CborItem -> Encoder
item cborItem =
    Encoder (\_ -> encodeItem cborItem)


{-| Inject pre-encoded CBOR bytes without validation. Ignores strategy.

If the bytes are not valid CBOR, the output is malformed.

-}
rawUnsafe : Bytes.Bytes -> Encoder
rawUnsafe bs =
    Encoder (\_ -> BE.bytes bs)



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
        majorType =
            if n >= 0 then
                0

            else
                1

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

    else if argument <= 0xFFFFFFFF then
        BE.sequence
            [ BE.unsignedInt8 (mt + 26)
            , BE.unsignedInt32 Bytes.BE argument
            ]

    else
        -- 64-bit: split into two 32-bit halves
        let
            hi =
                argument // 0x0000000100000000

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
                hi =
                    argument // 0x0000000100000000

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
    if float16RoundTrips f then
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
        encoded =
            BE.encode
                (BE.sequence
                    [ Bytes.Floating.Encode.float16 Bytes.BE f
                    ]
                )

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
        encoded =
            BE.encode (BE.float32 Bytes.BE f)

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
                (BE.unsignedInt8 0x5F
                    :: List.map
                        (\bs ->
                            BE.sequence
                                [ encodeHeader 2 (Bytes.width bs)
                                , BE.bytes bs
                                ]
                        )
                        chunks
                    ++ [ BE.unsignedInt8 0xFF ]
                )

        CborString s ->
            let
                encoded =
                    BE.encode (BE.string s)
            in
            BE.sequence
                [ encodeHeader 3 (Bytes.width encoded)
                , BE.bytes encoded
                ]

        CborStringChunked chunks ->
            BE.sequence
                (BE.unsignedInt8 0x7F
                    :: List.map
                        (\s ->
                            let
                                encoded =
                                    BE.encode (BE.string s)
                            in
                            BE.sequence
                                [ encodeHeader 3 (Bytes.width encoded)
                                , BE.bytes encoded
                                ]
                        )
                        chunks
                    ++ [ BE.unsignedInt8 0xFF ]
                )

        CborArray length items ->
            case length of
                Definite ->
                    BE.sequence (encodeHeader 4 (List.length items) :: List.map encodeItem items)

                Indefinite ->
                    BE.sequence
                        (BE.unsignedInt8 0x9F
                            :: List.map encodeItem items
                            ++ [ BE.unsignedInt8 0xFF ]
                        )

        CborMap length entries ->
            case length of
                Definite ->
                    BE.sequence
                        (encodeHeader 5 (List.length entries)
                            :: List.concatMap
                                (\e ->
                                    [ encodeItem e.key, encodeItem e.value ]
                                )
                                entries
                        )

                Indefinite ->
                    BE.sequence
                        (BE.unsignedInt8 0xBF
                            :: List.concatMap
                                (\e ->
                                    [ encodeItem e.key, encodeItem e.value ]
                                )
                                entries
                            ++ [ BE.unsignedInt8 0xFF ]
                        )

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


compareByteKeys : ( Bytes.Bytes, a ) -> ( Bytes.Bytes, a ) -> Order
compareByteKeys ( a, _ ) ( b, _ ) =
    compareBytes a b


canonicalCompare : ( Bytes.Bytes, a ) -> ( Bytes.Bytes, a ) -> Order
canonicalCompare ( a, _ ) ( b, _ ) =
    let
        lenA =
            Bytes.width a

        lenB =
            Bytes.width b
    in
    case compare lenA lenB of
        EQ ->
            compareBytes a b

        other ->
            other


compareBytes : Bytes.Bytes -> Bytes.Bytes -> Order
compareBytes a b =
    let
        lenA =
            Bytes.width a

        lenB =
            Bytes.width b

        aList =
            bytesToList a

        bList =
            bytesToList b
    in
    compareByteLists aList bList lenA lenB


compareByteLists : List Int -> List Int -> Int -> Int -> Order
compareByteLists a b lenA lenB =
    case ( a, b ) of
        ( [], [] ) ->
            compare lenA lenB

        ( x :: xs, y :: ys ) ->
            case compare x y of
                EQ ->
                    compareByteLists xs ys lenA lenB

                other ->
                    other

        ( [], _ ) ->
            LT

        ( _, [] ) ->
            GT


bytesToList : Bytes.Bytes -> List Int
bytesToList bs =
    let
        len =
            Bytes.width bs

        decoder =
            Bytes.Decode.loop ( len, [] )
                (\( remaining, acc ) ->
                    if remaining <= 0 then
                        Bytes.Decode.succeed (Bytes.Decode.Done (List.reverse acc))

                    else
                        Bytes.Decode.unsignedInt8
                            |> Bytes.Decode.map
                                (\byte -> Bytes.Decode.Loop ( remaining - 1, byte :: acc ))
                )
    in
    case Bytes.Decode.decode decoder bs of
        Just result ->
            result

        Nothing ->
            []
