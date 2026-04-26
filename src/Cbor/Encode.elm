module Cbor.Encode exposing
    ( Encoder, encode
    , int, bigInt, float, bool, null, undefined, maybe, string, bytes, simple
    , intWithWidth, floatWithWidth
    , stringChunked, bytesChunked
    , Sort(..), list, array, map, associativeList, dict, tagged, keyedRecord, sequence
    , item, rawUnsafe
    , deterministicSort, canonicalSort
    )

{-| CBOR encoding combinators.

Build encoders for your domain types, then produce bytes.
Length and sort decisions are made at construction time —
no separate strategy parameter is needed.

    import Cbor exposing (Length(..))
    import Cbor.Encode as CE

    type alias Person =
        { name : String, age : Int }

    encodePerson : Person -> CE.Encoder
    encodePerson p =
        CE.keyedRecord CE.Unsorted Definite CE.int
            [ ( 0, Just (CE.string p.name) )
            , ( 1, Just (CE.int p.age) )
            ]

    CE.encode (encodePerson alice)

@docs Encoder, encode


## Primitives

@docs int, bigInt, float, bool, null, undefined, maybe, string, bytes, simple


## Explicit Width Control

@docs intWithWidth, floatWithWidth


## Chunked Strings/Bytes

@docs stringChunked, bytesChunked


## Collections

@docs Sort, list, array, map, associativeList, dict, tagged, keyedRecord, sequence


## Escape Hatches

@docs item, rawUnsafe


## Predefined Sort Orders

@docs deterministicSort, canonicalSort

-}

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode as BE
import Bytes.Floating.Decode
import Bytes.Floating.Encode
import Cbor exposing (CborItem(..), FloatWidth(..), IntWidth(..), Length(..), Sign(..), Tag, tagToInt)
import Dict exposing (Dict)
import Hex


{-| An encoder that produces CBOR bytes.
-}
type Encoder
    = Encoder BE.Encoder


{-| Sort strategy for map keys.

  - `Unsorted` preserves insertion order (fast path — no key serialization).
  - `Sorted toComparable` serializes each key to `Bytes`, extracts a
    comparable via `toComparable`, and sorts entries by that value.

-}
type Sort comparable
    = Unsorted
    | Sorted (Bytes.Bytes -> comparable)



-- PREDEFINED SORT ORDERS


{-| RFC 8949 §4.2.1 Core Deterministic Encoding.

Lexicographic byte order on encoded keys.

-}
deterministicSort : Sort String
deterministicSort =
    Sorted Hex.fromBytes


{-| RFC 7049 / RFC 8949 §4.2.3 Canonical CBOR.

Shorter keys first, then lexicographic within same length.
(Also used by CTAP2/FIDO canonical encoding.)

-}
canonicalSort : Sort ( Int, String )
canonicalSort =
    Sorted (\bs -> ( Bytes.width bs, Hex.fromBytes bs ))



-- RUNNING


{-| Produce CBOR bytes from an encoder.
-}
encode : Encoder -> Bytes.Bytes
encode (Encoder be) =
    BE.encode be



-- PRIMITIVES


{-| Encode an integer using the shortest form.

Only reliable for values in `[-(2^53 - 1), 2^53 - 1]` (JavaScript's safe
integer range). Outside that range, Elm's `Int` loses precision and the
encoded bytes will be wrong. For arbitrarily large integers, use `bigInt`
with a raw bytes representation.

-}
int : Int -> Encoder
int n =
    Encoder (encodeInt n)


{-| Encode an integer that does not fit in a 32-bit CBOR argument.

For values that fit in `Encode.int`, prefer `int` instead. This function
is for magnitudes that exceed 32 bits.
You should even prefer `Encode.int` on numbers up to 2^53-1.

  - If the magnitude fits in 8 bytes, encodes as a 64-bit CBOR integer
    (major type 0 or 1, additional info 27).
  - If the magnitude exceeds 8 bytes, encodes as a bignum
    (tag 2 for `Positive`, tag 3 for `Negative`) wrapping the byte string.

The bytes are the **unsigned magnitude** in big-endian byte order.
For `Negative`, the actual mathematical value is `−1 − magnitude`,
matching the CBOR spec for both major type 1 and tag 3.

Leading zero bytes are stripped before encoding.

-}
bigInt : Sign -> Bytes -> Encoder
bigInt sign magnitude =
    let
        stripped : Bytes
        stripped =
            stripLeadingZeros magnitude

        width : Int
        width =
            Bytes.width stripped
    in
    if width <= 8 then
        -- Decode as two U32 halves and emit as 64-bit CBOR integer.
        let
            majorType : Int
            majorType =
                case sign of
                    Positive ->
                        0

                    Negative ->
                        1

            ( hi, lo ) =
                if width <= 4 then
                    ( 0
                    , Bytes.Decode.decode (unsignedDecoder width) stripped
                        |> Maybe.withDefault 0
                    )

                else
                    Bytes.Decode.decode
                        (Bytes.Decode.map2 Tuple.pair
                            (unsignedDecoder (width - 4))
                            (Bytes.Decode.unsignedInt32 Bytes.BE)
                        )
                        stripped
                        |> Maybe.withDefault ( 0, 0 )
        in
        Encoder
            (BE.sequence
                [ BE.unsignedInt8 (Bitwise.shiftLeftBy 5 majorType + 27)
                , BE.unsignedInt32 Bytes.BE hi
                , BE.unsignedInt32 Bytes.BE lo
                ]
            )

    else
        -- Exceeds 64 bits — encode as bignum (tag 2 or 3).
        let
            bigNumTag : Tag
            bigNumTag =
                case sign of
                    Positive ->
                        Cbor.PositiveBigNum

                    Negative ->
                        Cbor.NegativeBigNum
        in
        Encoder
            (BE.sequence
                [ encodeHeader 6 (tagToInt bigNumTag)
                , encodeHeader 2 width
                , BE.bytes stripped
                ]
            )


{-| Encode a float using the shortest IEEE 754 form that preserves the value.
-}
float : Float -> Encoder
float f =
    Encoder (encodeFloat f)


{-| Encode a boolean.
-}
bool : Bool -> Encoder
bool b =
    if b then
        Encoder (BE.unsignedInt8 0xF5)

    else
        Encoder (BE.unsignedInt8 0xF4)


{-| Encode a CBOR null.
-}
null : Encoder
null =
    Encoder (BE.unsignedInt8 0xF6)


{-| Encode a CBOR undefined.
-}
undefined : Encoder
undefined =
    Encoder (BE.unsignedInt8 0xF7)


{-| Encode a `Maybe` value: `Nothing` becomes CBOR null, `Just x` is encoded
with the given encoder.
-}
maybe : (a -> Encoder) -> Maybe a -> Encoder
maybe encodeValue m =
    case m of
        Just a ->
            encodeValue a

        Nothing ->
            null


{-| Encode a UTF-8 text string (major type 3).
-}
string : String -> Encoder
string s =
    let
        len : Int
        len =
            BE.getStringWidth s
    in
    Encoder
        (BE.sequence
            [ encodeHeader 3 len
            , BE.string s
            ]
        )


{-| Encode a byte string (major type 2).
-}
bytes : Bytes.Bytes -> Encoder
bytes bs =
    Encoder
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
        Encoder (BE.unsignedInt8 (0xE0 + n))

    else
        Encoder
            (BE.sequence
                [ BE.unsignedInt8 0xF8
                , BE.unsignedInt8 n
                ]
            )



-- EXPLICIT WIDTH


{-| Encode an integer with a specific wire width.

The value is encoded in the given width regardless of whether a shorter
encoding exists. Useful for lossless round-tripping.

-}
intWithWidth : IntWidth -> Int -> Encoder
intWithWidth width n =
    Encoder (encodeIntWithWidth width n)


{-| Encode a float with a specific IEEE 754 width.
-}
floatWithWidth : FloatWidth -> Float -> Encoder
floatWithWidth width f =
    Encoder
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
    Encoder
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
    Encoder
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


{-| Encode a list of items using the same element encoder.
This is a helper function for [`array`](#array) when all elements are of the same type.
-}
list : Length -> (a -> Encoder) -> List a -> Encoder
list len encodeElement items =
    let
        { count, inner } =
            List.foldr
                (\x acc ->
                    let
                        (Encoder be) =
                            encodeElement x
                    in
                    { count = acc.count + 1
                    , inner = be :: acc.inner
                    }
                )
                { count = 0, inner = [] }
                items
    in
    buildArray4 len count inner


{-| Encode a CBOR array (major type 4).
-}
array : Length -> List Encoder -> Encoder
array len items =
    let
        { count, inner } =
            List.foldr
                (\(Encoder be) acc ->
                    { count = acc.count + 1
                    , inner = be :: acc.inner
                    }
                )
                { count = 0, inner = [] }
                items
    in
    buildArray4 len count inner


{-| Encode a CBOR map (major type 5).
-}
map : Sort comparable -> Length -> List ( Encoder, Encoder ) -> Encoder
map sort len entries =
    case sort of
        Unsorted ->
            let
                { count, flatEntries } =
                    List.foldr
                        (\( Encoder k, Encoder v ) acc ->
                            { count = acc.count + 1
                            , flatEntries = BE.sequence [ k, v ] :: acc.flatEntries
                            }
                        )
                        { count = 0, flatEntries = [] }
                        entries
            in
            buildMap5 len count flatEntries

        Sorted toComparable ->
            let
                { count, taggedEntries } =
                    List.foldr
                        (\( Encoder k, Encoder v ) acc ->
                            let
                                keyBytes : Bytes.Bytes
                                keyBytes =
                                    BE.encode k
                            in
                            { count = acc.count + 1
                            , taggedEntries = ( toComparable keyBytes, BE.sequence [ BE.bytes keyBytes, v ] ) :: acc.taggedEntries
                            }
                        )
                        { count = 0, taggedEntries = [] }
                        entries
            in
            buildSortedMap5 len count taggedEntries


{-| Encode an associative list as a CBOR map (major type 5).

This is a convenience wrapper around [`map`](#map) that takes encoder
functions for keys and values instead of pre-built encoder pairs.

    CE.associativeList CE.Unsorted
        Definite
        CE.int
        CE.string
        [ ( 1, "Alice" ), ( 2, "Bob" ) ]

-}
associativeList : Sort comparable -> Length -> (k -> Encoder) -> (v -> Encoder) -> List ( k, v ) -> Encoder
associativeList sort len encodeKey encodeValue entries =
    map sort len (List.map (\( k, v ) -> ( encodeKey k, encodeValue v )) entries)


{-| Encode a `Dict` as a CBOR map (major type 5).
-}
dict : Sort comparable2 -> Length -> (k -> Encoder) -> (v -> Encoder) -> Dict k v -> Encoder
dict sort len encodeKey encodeValue d =
    case sort of
        Unsorted ->
            let
                { count, flatEntries } =
                    Dict.foldr
                        (\k v acc ->
                            let
                                (Encoder kEnc) =
                                    encodeKey k

                                (Encoder vEnc) =
                                    encodeValue v
                            in
                            { count = acc.count + 1
                            , flatEntries = BE.sequence [ kEnc, vEnc ] :: acc.flatEntries
                            }
                        )
                        { count = 0, flatEntries = [] }
                        d
            in
            buildMap5 len count flatEntries

        Sorted toComparable ->
            let
                { count, taggedEntries } =
                    Dict.foldr
                        (\k v acc ->
                            let
                                (Encoder kEnc) =
                                    encodeKey k

                                (Encoder vEnc) =
                                    encodeValue v

                                keyBytes : Bytes.Bytes
                                keyBytes =
                                    BE.encode kEnc
                            in
                            { count = acc.count + 1
                            , taggedEntries = ( toComparable keyBytes, BE.sequence [ BE.bytes keyBytes, vEnc ] ) :: acc.taggedEntries
                            }
                        )
                        { count = 0, taggedEntries = [] }
                        d
            in
            buildSortedMap5 len count taggedEntries


{-| Encode a CBOR semantic tag (major type 6).
-}
tagged : Tag -> Encoder -> Encoder
tagged t (Encoder be) =
    Encoder
        (BE.sequence
            [ encodeHeader 6 (tagToInt t)
            , be
            ]
        )


{-| Encode a keyed record as a CBOR map with a shared key encoder.

`Nothing` entries are omitted from the output — this distinguishes
"field absent" from "field is null."

-}
keyedRecord : Sort comparable -> Length -> (k -> Encoder) -> List ( k, Maybe Encoder ) -> Encoder
keyedRecord sort len keyEncoder entries =
    case sort of
        Unsorted ->
            let
                { count, flatEntries } =
                    List.foldr
                        (\( k, maybeEnc ) acc ->
                            case maybeEnc of
                                Just (Encoder vEnc) ->
                                    let
                                        (Encoder kEnc) =
                                            keyEncoder k
                                    in
                                    { count = acc.count + 1
                                    , flatEntries = BE.sequence [ kEnc, vEnc ] :: acc.flatEntries
                                    }

                                Nothing ->
                                    acc
                        )
                        { count = 0, flatEntries = [] }
                        entries
            in
            buildMap5 len count flatEntries

        Sorted toComparable ->
            let
                { count, taggedEntries } =
                    List.foldr
                        (\( k, maybeEnc ) acc ->
                            case maybeEnc of
                                Just (Encoder vEnc) ->
                                    let
                                        (Encoder kEnc) =
                                            keyEncoder k

                                        keyBytes : Bytes.Bytes
                                        keyBytes =
                                            BE.encode kEnc
                                    in
                                    { count = acc.count + 1
                                    , taggedEntries = ( toComparable keyBytes, BE.sequence [ BE.bytes keyBytes, vEnc ] ) :: acc.taggedEntries
                                    }

                                Nothing ->
                                    acc
                        )
                        { count = 0, taggedEntries = [] }
                        entries
            in
            buildSortedMap5 len count taggedEntries


{-| Concatenate multiple CBOR items without a wrapping array.

Produces a CBOR Sequence (RFC 8742).

-}
sequence : List Encoder -> Encoder
sequence encoders =
    Encoder (BE.sequence (List.map unwrap encoders))



-- ESCAPE HATCHES


{-| Encode a `CborItem` losslessly.
-}
item : CborItem -> Encoder
item cborItem =
    Encoder (encodeItem cborItem)


{-| Inject pre-encoded CBOR bytes without validation.

If the bytes are not valid CBOR, the output is malformed.

-}
rawUnsafe : Bytes.Bytes -> Encoder
rawUnsafe bs =
    Encoder (BE.bytes bs)



-- INTERNAL


unwrap : Encoder -> BE.Encoder
unwrap (Encoder be) =
    be


buildArray4 : Length -> Int -> List BE.Encoder -> Encoder
buildArray4 len count inner =
    case len of
        Definite ->
            Encoder (BE.sequence (encodeHeader 4 count :: inner))

        Indefinite ->
            Encoder
                (BE.sequence
                    [ BE.unsignedInt8 0x9F
                    , BE.sequence inner
                    , BE.unsignedInt8 0xFF
                    ]
                )


buildSortedMap5 : Length -> Int -> List ( comparable, BE.Encoder ) -> Encoder
buildSortedMap5 len count taggedEntries =
    let
        flatEntries : List BE.Encoder
        flatEntries =
            taggedEntries
                |> List.sortBy Tuple.first
                |> List.map Tuple.second
    in
    buildMap5 len count flatEntries


buildMap5 : Length -> Int -> List BE.Encoder -> Encoder
buildMap5 len count flatEntries =
    case len of
        Definite ->
            Encoder (BE.sequence (encodeHeader 5 count :: flatEntries))

        Indefinite ->
            Encoder
                (BE.sequence
                    [ BE.unsignedInt8 0xBF
                    , BE.sequence flatEntries
                    , BE.unsignedInt8 0xFF
                    ]
                )



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


{-| Strip leading zero bytes from a big-endian Bytes value.
-}
stripLeadingZeros : Bytes.Bytes -> Bytes.Bytes
stripLeadingZeros bs =
    let
        width : Int
        width =
            Bytes.width bs
    in
    if width == 0 then
        bs

    else
        case Bytes.Decode.decode (countLeadingZeros width) bs of
            Just zeros ->
                if zeros == width then
                    -- All zeros (or empty) → represent as empty bytes (value 0).
                    BE.encode (BE.sequence [])

                else if zeros == 0 then
                    bs

                else
                    -- Drop the leading zeros by decoding only the tail.
                    case Bytes.Decode.decode (Bytes.Decode.map2 (\_ tail -> tail) (Bytes.Decode.bytes zeros) (Bytes.Decode.bytes (width - zeros))) bs of
                        Just tail ->
                            tail

                        Nothing ->
                            bs

            Nothing ->
                bs


countLeadingZeros : Int -> Bytes.Decode.Decoder Int
countLeadingZeros width =
    countLeadingZerosU32 width 0


countLeadingZerosU32 : Int -> Int -> Bytes.Decode.Decoder Int
countLeadingZerosU32 remaining acc =
    if remaining >= 4 then
        Bytes.Decode.unsignedInt32 Bytes.BE
            |> Bytes.Decode.andThen
                (\word ->
                    if word == 0 then
                        countLeadingZerosU32 (remaining - 4) (acc + 4)

                    else
                        Bytes.Decode.succeed (acc + countLeadingZerosInU32 word)
                )

    else
        countLeadingZerosU8 remaining acc


countLeadingZerosU8 : Int -> Int -> Bytes.Decode.Decoder Int
countLeadingZerosU8 remaining acc =
    if remaining <= 0 then
        Bytes.Decode.succeed acc

    else
        Bytes.Decode.unsignedInt8
            |> Bytes.Decode.andThen
                (\byte ->
                    if byte == 0 then
                        countLeadingZerosU8 (remaining - 1) (acc + 1)

                    else
                        Bytes.Decode.succeed acc
                )


countLeadingZerosInU32 : Int -> Int
countLeadingZerosInU32 word =
    if word >= 0x01000000 then
        0

    else if word >= 0x00010000 then
        1

    else if word >= 0x0100 then
        2

    else
        3


{-| Decode 0–4 big-endian bytes as an unsigned Int.
-}
unsignedDecoder : Int -> Bytes.Decode.Decoder Int
unsignedDecoder width =
    case width of
        0 ->
            Bytes.Decode.succeed 0

        1 ->
            Bytes.Decode.unsignedInt8

        2 ->
            Bytes.Decode.unsignedInt16 Bytes.BE

        3 ->
            Bytes.Decode.map2 (\hi lo -> hi * 256 + lo)
                (Bytes.Decode.unsignedInt16 Bytes.BE)
                Bytes.Decode.unsignedInt8

        _ ->
            Bytes.Decode.unsignedInt32 Bytes.BE


encodeFloat : Float -> BE.Encoder
encodeFloat f =
    if float32RoundTrips f then
        if (isNaN f || isInfinite f || abs f <= 65504) && float16RoundTrips f then
            BE.sequence
                [ BE.unsignedInt8 0xF9
                , Bytes.Floating.Encode.float16 Bytes.BE f
                ]

        else
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
            let
                { count, inner } =
                    List.foldr
                        (\ci acc ->
                            { count = acc.count + 1
                            , inner = encodeItem ci :: acc.inner
                            }
                        )
                        { count = 0, inner = [] }
                        items
            in
            case length of
                Definite ->
                    BE.sequence (encodeHeader 4 count :: inner)

                Indefinite ->
                    BE.sequence
                        [ BE.unsignedInt8 0x9F
                        , BE.sequence inner
                        , BE.unsignedInt8 0xFF
                        ]

        CborMap length entries ->
            let
                { count, flatEntries } =
                    List.foldr
                        (\e acc ->
                            { count = acc.count + 1
                            , flatEntries = encodeItem e.key :: encodeItem e.value :: acc.flatEntries
                            }
                        )
                        { count = 0, flatEntries = [] }
                        entries
            in
            case length of
                Definite ->
                    BE.sequence (encodeHeader 5 count :: flatEntries)

                Indefinite ->
                    BE.sequence
                        [ BE.unsignedInt8 0xBF
                        , BE.sequence flatEntries
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
