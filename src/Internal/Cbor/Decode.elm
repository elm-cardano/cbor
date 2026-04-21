module Internal.Cbor.Decode exposing
    ( Decoder
    , int, bigInt, float, bool, null, string, bytes
    , item, skip, skipFull, skipNFull, skipIndefinite, skipEntries
    , mapHeader, arrayHeader
    , array, associativeList, entryLoop, tag
    , u8
    , intToHex
    )

{-| Low-level CBOR decoding primitives.

This module contains the composable building blocks for CBOR decoding.
Each primitive decoder takes a pre-read initial byte and returns a
`BD.Decoder` that consumes the remaining content bytes.


## The initial-byte pattern

Every CBOR data item starts with a single byte encoding two pieces of
information (RFC 8949 §3):

    ┌───────────────────┬─────────────────────────┐
    │ major type (3 bit)│ additional info (5 bit) │
    └───────────────────┴─────────────────────────┘

The `Decoder` type captures this pattern:

    type alias Decoder ctx a =
        Int -> BD.Decoder ctx DecodeError a

The `Int` parameter is the already-read initial byte. This pre-read design
enables two things:

1.  **Break detection** — indefinite-length containers need to peek at the
    next byte to detect `0xFF` without consuming it as an item header.

2.  **Composability** — decoders in this module can be freely combined
    without extra `BD.andThen` wrappers: the caller reads one byte and
    passes it to whichever decoder it selects.

The public `Cbor.Decode` module wraps these with its `Item` constructor
to produce the opaque `CborDecoder` type exposed to package users.


## Type

@docs Decoder


## Primitives

@docs int, bigInt, float, bool, null, string, bytes


## Item and Skip

@docs item, skip, skipFull, skipNFull, skipIndefinite, skipEntries


## Structure Headers

@docs mapHeader, arrayHeader


## Collections

@docs array, associativeList, entryLoop, tag


## Argument Decoders


## Byte Readers

@docs u8


## Byte Helpers

@docs intToHex

-}

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Decoder as BD
import Bytes.Encode
import Cbor exposing (CborItem(..), DecodeError(..), FloatWidth(..), IntWidth(..), Length(..), Sign(..), SimpleWidth(..), Tag(..))



-- TYPE


{-| A decoder that receives an already-read initial byte.

This is the fundamental building block. The `Int` parameter is the raw
initial byte (0x00–0xFF). The decoder consumes any remaining content
bytes from the stream and produces a value of type `a`.

-}
type alias Decoder ctx a =
    Int -> BD.Decoder ctx DecodeError a



-- BYTE READERS


{-| Read one unsigned byte from the stream.
-}
u8 : BD.Decoder ctx err Int
u8 =
    BD.unsignedInt8


{-| Read a big-endian unsigned 16-bit integer.
-}
u16 : BD.Decoder ctx err Int
u16 =
    BD.unsignedInt16 Bytes.BE


{-| Read a big-endian unsigned 32-bit integer.
-}
u32 : BD.Decoder ctx err Int
u32 =
    BD.unsignedInt32 Bytes.BE



-- ARGUMENT DECODERS


{-| Maximum safe integer for Elm's 64-bit floats: 2^52.

Values exceeding this cannot be represented exactly and will trigger
an `IntegerOverflow` error.

-}
maxSafeInt : Int
maxSafeInt =
    4503599627370496


{-| Decode the CBOR argument as a safe integer (≤ 2^52).

For inline values (additional info ≤ 23), returns immediately with no
byte consumption. For multi-byte arguments, reads the appropriate number
of bytes. Fails with `IntegerOverflow` if the 64-bit value exceeds the
safe range.

-}
safeArgument : Int -> BD.Decoder ctx DecodeError Int
safeArgument additionalInfo =
    if additionalInfo <= 23 then
        BD.succeed additionalInfo

    else if additionalInfo == 24 then
        u8

    else if additionalInfo == 25 then
        u16

    else if additionalInfo == 26 then
        u32

    else if additionalInfo == 27 then
        BD.map2 (\hi lo -> hi * 0x0000000100000000 + lo) u32 u32
            |> BD.andThen
                (\n ->
                    if n > maxSafeInt then
                        BD.fail IntegerOverflow

                    else
                        BD.succeed n
                )

    else
        BD.fail (ReservedAdditionalInfo additionalInfo)


{-| Decode the CBOR argument and pass it to a continuation.

This is the CPS (continuation-passing style) variant of `safeArgument`.
For inline arguments (≤ 23) it calls `f` directly — no intermediate
`BD.succeed` + `BD.andThen`, saving one allocation on the hot path.

-}
withArgument : Int -> (Int -> BD.Decoder ctx DecodeError a) -> BD.Decoder ctx DecodeError a
withArgument additionalInfo f =
    if additionalInfo <= 23 then
        f additionalInfo

    else if additionalInfo == 24 then
        u8 |> BD.andThen f

    else if additionalInfo == 25 then
        u16 |> BD.andThen f

    else if additionalInfo == 26 then
        u32 |> BD.andThen f

    else if additionalInfo == 27 then
        BD.map2 (\hi lo -> hi * 0x0000000100000000 + lo) u32 u32
            |> BD.andThen f

    else
        BD.fail (ReservedAdditionalInfo additionalInfo)


{-| Decode the CBOR argument, returning the wire width and value.

Used by the `item` decoder to preserve encoding details in `CborInt52`.

-}
decodeArgument64 : Int -> BD.Decoder ctx DecodeError ( IntWidth, Int )
decodeArgument64 additionalInfo =
    if additionalInfo <= 23 then
        BD.succeed ( IW0, additionalInfo )

    else if additionalInfo == 24 then
        BD.map (\v -> ( IW8, v )) u8

    else if additionalInfo == 25 then
        BD.map (\v -> ( IW16, v )) u16

    else if additionalInfo == 26 then
        BD.map (\v -> ( IW32, v )) u32

    else if additionalInfo == 27 then
        BD.map2 (\hi lo -> ( IW64, hi * 0x0000000100000000 + lo )) u32 u32

    else
        BD.fail (ReservedAdditionalInfo additionalInfo)


{-| Decode the CBOR argument as raw bytes (for lossless bignum handling).

Returns the argument's big-endian byte representation without interpreting
the numeric value. Inline values (≤ 23) are encoded as a single byte.

-}
decodeArgumentBytes : Int -> BD.Decoder ctx DecodeError Bytes
decodeArgumentBytes additionalInfo =
    if additionalInfo <= 23 then
        BD.succeed (encodeSingleByte additionalInfo)

    else if additionalInfo == 24 then
        BD.bytes 1

    else if additionalInfo == 25 then
        BD.bytes 2

    else if additionalInfo == 26 then
        BD.bytes 4

    else if additionalInfo == 27 then
        BD.bytes 8

    else
        BD.fail (ReservedAdditionalInfo additionalInfo)


{-| How many extra bytes a CBOR argument occupies beyond the initial byte.

Used by `skip` to efficiently jump over integer/float arguments without
actually decoding their values.

-}
argumentByteCount : Int -> Int
argumentByteCount additionalInfo =
    if additionalInfo <= 23 then
        0

    else if additionalInfo == 24 then
        1

    else if additionalInfo == 25 then
        2

    else if additionalInfo == 26 then
        4

    else if additionalInfo == 27 then
        8

    else
        0



-- BYTE HELPERS


{-| Encode a single byte value as a 1-byte `Bytes` value.
-}
encodeSingleByte : Int -> Bytes
encodeSingleByte n =
    Bytes.Encode.encode (Bytes.Encode.unsignedInt8 n)


{-| Encode two 32-bit integers as an 8-byte big-endian `Bytes` value.

Used to preserve the raw bytes of 64-bit CBOR integers that exceed
the safe integer range.

-}
intPairToBytes : Int -> Int -> Bytes
intPairToBytes hi lo =
    Bytes.Encode.encode
        (Bytes.Encode.sequence
            [ Bytes.Encode.unsignedInt32 Bytes.BE hi
            , Bytes.Encode.unsignedInt32 Bytes.BE lo
            ]
        )


{-| Concatenate a list of byte chunks into a single `Bytes` value.

Used when decoding indefinite-length byte/text strings.

-}
concatBytes : List Bytes -> Bytes
concatBytes chunks =
    Bytes.Encode.encode
        (Bytes.Encode.sequence (List.map Bytes.Encode.bytes chunks))


{-| Format a byte value as a two-character lowercase hex string.
-}
intToHex : Int -> String
intToHex n =
    let
        hi : Int
        hi =
            Bitwise.shiftRightZfBy 4 n

        lo : Int
        lo =
            Bitwise.and 0x0F n
    in
    String.fromChar (nibbleToHexChar hi) ++ String.fromChar (nibbleToHexChar lo)


nibbleToHexChar : Int -> Char
nibbleToHexChar n =
    if n < 10 then
        Char.fromCode (n + 0x30)

    else
        Char.fromCode (n - 10 + 0x61)


{-| Convert a CBOR tag number to its `Tag` representation.
-}
intToTag : Int -> Tag
intToTag n =
    case n of
        0 ->
            StandardDateTime

        1 ->
            EpochDateTime

        2 ->
            PositiveBigNum

        3 ->
            NegativeBigNum

        4 ->
            DecimalFraction

        5 ->
            BigFloat

        21 ->
            Base64UrlConversion

        22 ->
            Base64Conversion

        23 ->
            Base16Conversion

        24 ->
            Cbor

        32 ->
            Uri

        33 ->
            Base64Url

        34 ->
            Base64

        35 ->
            Regex

        36 ->
            Mime

        55799 ->
            IsCbor

        _ ->
            Unknown n



-- PRIMITIVES


{-| Decode a CBOR integer (major types 0 and 1).

Accepts both unsigned (major type 0) and negative (major type 1) integers.
Fails with `IntegerOverflow` if the absolute value exceeds 2^52.

-}
int : Decoder ctx Int
int initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte

        additionalInfo : Int
        additionalInfo =
            Bitwise.and 0x1F initialByte
    in
    if majorType == 0 then
        safeArgument additionalInfo

    else if majorType == 1 then
        -- CBOR negative: value = -1 - argument
        safeArgument additionalInfo
            |> BD.map (\n -> -1 - n)

    else
        BD.fail (WrongMajorType { expected = 0, got = majorType })


{-| Decode any CBOR integer including bignums (tags 2 and 3).

Returns `( Sign, Bytes )` where `Bytes` is the minimal big-endian
representation of the unsigned argument. Handles:

  - Major type 0 (unsigned integer) → `( Positive, argBytes )`
  - Major type 1 (negative integer) → `( Negative, argBytes )`
  - Tag 2 wrapping a byte string → `( Positive, byteString )`
  - Tag 3 wrapping a byte string → `( Negative, byteString )`

-}
bigInt : Decoder ctx ( Sign, Bytes )
bigInt initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte

        additionalInfo : Int
        additionalInfo =
            Bitwise.and 0x1F initialByte
    in
    if majorType == 0 then
        decodeArgumentBytes additionalInfo
            |> BD.map (\bs -> ( Positive, bs ))

    else if majorType == 1 then
        decodeArgumentBytes additionalInfo
            |> BD.map (\bs -> ( Negative, bs ))

    else if majorType == 6 then
        withArgument additionalInfo
            (\tagNum ->
                if tagNum == 2 then
                    decodeBytesRaw
                        |> BD.map (\bs -> ( Positive, bs ))

                else if tagNum == 3 then
                    decodeBytesRaw
                        |> BD.map (\bs -> ( Negative, bs ))

                else
                    BD.fail (WrongTag { expected = 2, got = tagNum })
            )

    else
        BD.fail (WrongMajorType { expected = 0, got = majorType })


{-| Decode a CBOR float (major type 7, additional info 25/26/27).

Supports half (16-bit), single (32-bit), and double (64-bit) precision.

-}
float : Decoder ctx Float
float initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte
    in
    if majorType /= 7 then
        BD.fail (WrongMajorType { expected = 7, got = majorType })

    else
        let
            additionalInfo : Int
            additionalInfo =
                Bitwise.and 0x1F initialByte
        in
        if additionalInfo == 25 then
            BD.float16 Bytes.BE

        else if additionalInfo == 26 then
            BD.float32 Bytes.BE

        else if additionalInfo == 27 then
            BD.float64 Bytes.BE

        else
            BD.fail (WrongInitialByte { got = initialByte })


{-| Decode a CBOR boolean (initial byte 0xF4 = false, 0xF5 = true).
-}
bool : Decoder ctx Bool
bool initialByte =
    if initialByte == 0xF4 then
        BD.succeed False

    else if initialByte == 0xF5 then
        BD.succeed True

    else
        BD.fail (WrongInitialByte { got = initialByte })


{-| Decode a CBOR null (initial byte 0xF6), returning the given default.
-}
null : a -> Decoder ctx a
null default initialByte =
    if initialByte == 0xF6 then
        BD.succeed default

    else
        BD.fail (WrongInitialByte { got = initialByte })


{-| Decode a CBOR text string (major type 3).

Handles both definite-length (single chunk) and indefinite-length
(multiple chunks terminated by 0xFF break byte). Indefinite-length
chunks are concatenated transparently.

-}
string : Decoder ctx String
string initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte
    in
    if majorType /= 3 then
        BD.fail (WrongMajorType { expected = 3, got = majorType })

    else
        let
            additionalInfo : Int
            additionalInfo =
                Bitwise.and 0x1F initialByte
        in
        if additionalInfo == 31 then
            -- Indefinite-length: collect chunks until break byte
            BD.loop
                (\chunks ->
                    u8
                        |> BD.andThen
                            (\byte ->
                                if byte == 0xFF then
                                    BD.succeed (BD.Done (String.concat (List.reverse chunks)))

                                else
                                    withArgument (Bitwise.and 0x1F byte)
                                        (\len -> BD.string len)
                                        |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                            )
                )
                []

        else
            withArgument additionalInfo (\len -> BD.string len)


{-| Decode a CBOR byte string (major type 2).

Handles both definite-length and indefinite-length (chunked) encoding.
Indefinite-length chunks are concatenated transparently.

-}
bytes : Decoder ctx Bytes
bytes initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte
    in
    if majorType /= 2 then
        BD.fail (WrongMajorType { expected = 2, got = majorType })

    else
        let
            additionalInfo : Int
            additionalInfo =
                Bitwise.and 0x1F initialByte
        in
        if additionalInfo == 31 then
            -- Indefinite-length: collect chunks until break byte
            BD.loop
                (\chunks ->
                    u8
                        |> BD.andThen
                            (\byte ->
                                if byte == 0xFF then
                                    BD.succeed (BD.Done (concatBytes (List.reverse chunks)))

                                else
                                    withArgument (Bitwise.and 0x1F byte)
                                        (\len -> BD.bytes len)
                                        |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                            )
                )
                []

        else
            withArgument additionalInfo (\len -> BD.bytes len)


{-| Decode a raw CBOR byte string (major type 2, definite-length only).

This is an internal helper for bignum decoding — it reads its own
initial byte (not pre-read) and only handles definite-length encoding.

-}
decodeBytesRaw : BD.Decoder ctx DecodeError Bytes
decodeBytesRaw =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType : Int
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte
                in
                if majorType /= 2 then
                    BD.fail (WrongMajorType { expected = 2, got = majorType })

                else
                    withArgument (Bitwise.and 0x1F initialByte) (\len -> BD.bytes len)
            )



-- STRUCTURE HEADERS


{-| Decode a CBOR map header (major type 5).

Returns `Just n` for definite-length maps (n entries),
or `Nothing` for indefinite-length maps.

-}
mapHeader : Decoder ctx (Maybe Int)
mapHeader initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte
    in
    if majorType /= 5 then
        BD.fail (WrongMajorType { expected = 5, got = majorType })

    else
        let
            additionalInfo : Int
            additionalInfo =
                Bitwise.and 0x1F initialByte
        in
        if additionalInfo == 31 then
            BD.succeed Nothing

        else
            withArgument additionalInfo (Just >> BD.succeed)


{-| Decode a CBOR array header (major type 4).

Returns `Just n` for definite-length arrays (n elements),
or `Nothing` for indefinite-length arrays.

-}
arrayHeader : Decoder ctx (Maybe Int)
arrayHeader initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte
    in
    if majorType /= 4 then
        BD.fail (WrongMajorType { expected = 4, got = majorType })

    else
        let
            additionalInfo : Int
            additionalInfo =
                Bitwise.and 0x1F initialByte
        in
        if additionalInfo == 31 then
            BD.succeed Nothing

        else
            withArgument additionalInfo (Just >> BD.succeed)



-- COLLECTIONS


{-| Decode a CBOR array (major type 4) where all elements use the same decoder.

Handles both definite and indefinite-length arrays.
In the definite case, we use the pre-applied (u8 |> BD.andThen elementBody).

-}
array : BD.Decoder ctx DecodeError a -> Decoder ctx a -> Decoder ctx (List a)
array elementBD elementBody initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte
    in
    if majorType /= 4 then
        BD.fail (WrongMajorType { expected = 4, got = majorType })

    else
        let
            additionalInfo : Int
            additionalInfo =
                Bitwise.and 0x1F initialByte
        in
        if additionalInfo == 31 then
            BD.loop
                (\acc ->
                    u8
                        |> BD.andThen
                            (\byte ->
                                if byte == 0xFF then
                                    BD.succeed (BD.Done (List.reverse acc))

                                else
                                    elementBody byte
                                        |> BD.map (\v -> BD.Loop (v :: acc))
                            )
                )
                []

        else
            withArgument additionalInfo
                (\count -> BD.repeat elementBD count)


{-| Decode a CBOR map (major type 5) as a list of key-value pairs.

Handles both definite and indefinite-length maps.
In the definite case, we use the pre-applied key and value decoders.

-}
associativeList : BD.Decoder ctx DecodeError k -> Decoder ctx k -> BD.Decoder ctx DecodeError v -> Decoder ctx (List ( k, v ))
associativeList keyBD keyBody valueBD initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte
    in
    if majorType /= 5 then
        BD.fail (WrongMajorType { expected = 5, got = majorType })

    else
        let
            additionalInfo : Int
            additionalInfo =
                Bitwise.and 0x1F initialByte
        in
        if additionalInfo == 31 then
            BD.loop
                (\acc ->
                    u8
                        |> BD.andThen
                            (\byte ->
                                if byte == 0xFF then
                                    BD.succeed (BD.Done (List.reverse acc))

                                else
                                    BD.map2
                                        (\k v -> BD.Loop (( k, v ) :: acc))
                                        (keyBody byte)
                                        valueBD
                            )
                )
                []

        else
            withArgument additionalInfo
                (\count ->
                    BD.repeat
                        (BD.map2 Tuple.pair keyBD valueBD)
                        count
                )


{-| Helper function to loop over map entries in a fold.
-}
entryLoop : BD.Decoder ctx DecodeError k -> Decoder ctx k -> (k -> acc -> Decoder ctx acc) -> acc -> Decoder ctx acc
entryLoop keyBD keyBody handler initialAcc initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte
    in
    if majorType /= 5 then
        BD.fail (WrongMajorType { expected = 5, got = majorType })

    else
        let
            additionalInfo : Int
            additionalInfo =
                Bitwise.and 0x1F initialByte
        in
        if additionalInfo == 31 then
            BD.loop
                (\acc ->
                    u8
                        |> BD.andThen
                            (\byte ->
                                if byte == 0xFF then
                                    BD.succeed (BD.Done acc)

                                else
                                    keyBody byte
                                        |> BD.andThen (\key -> u8 |> BD.andThen (handler key acc))
                                        |> BD.map BD.Loop
                            )
                )
                initialAcc

        else
            withArgument additionalInfo
                (\count ->
                    BD.loop
                        (\( remaining, acc ) ->
                            if remaining <= 0 then
                                BD.succeed (BD.Done acc)

                            else
                                keyBD
                                    |> BD.andThen (\key -> u8 |> BD.andThen (handler key acc))
                                    |> BD.map (\newAcc -> BD.Loop ( remaining - 1, newAcc ))
                        )
                        ( count, initialAcc )
                )


{-| Decode a tagged CBOR value (major type 6).

Expects a specific tag, then decodes the enclosed item.
We use the pre-applied value decoders.

-}
tag : Tag -> BD.Decoder ctx DecodeError a -> Decoder ctx a
tag expectedTag innerBD initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte
    in
    if majorType /= 6 then
        BD.fail (WrongMajorType { expected = 6, got = majorType })

    else
        withArgument (Bitwise.and 0x1F initialByte)
            (\tagNum ->
                if tagNum == Cbor.tagToInt expectedTag then
                    innerBD

                else
                    BD.fail (WrongTag { expected = Cbor.tagToInt expectedTag, got = tagNum })
            )



-- ITEM DECODER


{-| Decode any well-formed CBOR data item into a `CborItem`.

This is the full generic CBOR parser. It handles all 8 major types,
nested structures, tags, indefinite-length containers, and preserves
encoding details (integer width, float precision, definite/indefinite
length) for lossless round-tripping.

-}
item : Decoder ctx CborItem
item initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte

        additionalInfo : Int
        additionalInfo =
            Bitwise.and 0x1F initialByte
    in
    case majorType of
        0 ->
            -- Unsigned integer (major type 0)
            if additionalInfo == 27 then
                -- 64-bit: may exceed safe range → use CborInt64
                BD.map2
                    (\hi lo ->
                        let
                            n : Int
                            n =
                                hi * 0x0000000100000000 + lo
                        in
                        if n > maxSafeInt then
                            CborInt64 Positive (intPairToBytes hi lo)

                        else
                            CborInt52 IW64 n
                    )
                    u32
                    u32

            else
                decodeArgument64 additionalInfo
                    |> BD.map (\( width, n ) -> CborInt52 width n)

        1 ->
            -- Negative integer (major type 1): value = -1 - argument
            if additionalInfo == 27 then
                BD.map2
                    (\hi lo ->
                        let
                            n : Int
                            n =
                                hi * 0x0000000100000000 + lo
                        in
                        if n > maxSafeInt then
                            CborInt64 Negative (intPairToBytes hi lo)

                        else
                            CborInt52 IW64 (-1 - n)
                    )
                    u32
                    u32

            else
                decodeArgument64 additionalInfo
                    |> BD.map (\( width, n ) -> CborInt52 width (-1 - n))

        2 ->
            -- Byte string (major type 2)
            if additionalInfo == 31 then
                BD.loop
                    (\chunks ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborByteStringChunked (List.reverse chunks)))

                                    else
                                        withArgument (Bitwise.and 0x1F byte)
                                            (\len -> BD.bytes len)
                                            |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                                )
                    )
                    []

            else
                withArgument additionalInfo (\len -> BD.bytes len)
                    |> BD.map CborByteString

        3 ->
            -- Text string (major type 3)
            if additionalInfo == 31 then
                BD.loop
                    (\chunks ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborStringChunked (List.reverse chunks)))

                                    else
                                        withArgument (Bitwise.and 0x1F byte)
                                            (\len -> BD.string len)
                                            |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                                )
                    )
                    []

            else
                withArgument additionalInfo (\len -> BD.string len)
                    |> BD.map CborString

        4 ->
            -- Array (major type 4)
            if additionalInfo == 31 then
                BD.loop
                    (\items ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborArray Indefinite (List.reverse items)))

                                    else
                                        item byte
                                            |> BD.map (\v -> BD.Loop (v :: items))
                                )
                    )
                    []

            else
                withArgument additionalInfo
                    (\count ->
                        BD.repeat itemBD count
                            |> BD.map (\items -> CborArray Definite items)
                    )

        5 ->
            -- Map (major type 5)
            if additionalInfo == 31 then
                BD.loop
                    (\entries ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborMap Indefinite (List.reverse entries)))

                                    else
                                        BD.map2
                                            (\k v -> BD.Loop ({ key = k, value = v } :: entries))
                                            (item byte)
                                            itemBD
                                )
                    )
                    []

            else
                withArgument additionalInfo
                    (\count ->
                        BD.repeat (BD.map2 (\k v -> { key = k, value = v }) itemBD itemBD) count
                            |> BD.map (\entries -> CborMap Definite entries)
                    )

        6 ->
            -- Tag (major type 6)
            withArgument additionalInfo
                (\tagNum ->
                    itemBD
                        |> BD.map (\enclosed -> CborTag (intToTag tagNum) enclosed)
                )

        7 ->
            -- Simple values and floats (major type 7)
            if additionalInfo <= 19 then
                BD.succeed (CborSimple SW0 additionalInfo)

            else if additionalInfo == 20 then
                BD.succeed (CborBool False)

            else if additionalInfo == 21 then
                BD.succeed (CborBool True)

            else if additionalInfo == 22 then
                BD.succeed CborNull

            else if additionalInfo == 23 then
                BD.succeed CborUndefined

            else if additionalInfo == 24 then
                u8 |> BD.map (CborSimple SW8)

            else if additionalInfo == 25 then
                BD.float16 Bytes.BE |> BD.map (CborFloat FW16)

            else if additionalInfo == 26 then
                BD.float32 Bytes.BE |> BD.map (CborFloat FW32)

            else if additionalInfo == 27 then
                BD.float64 Bytes.BE |> BD.map (CborFloat FW64)

            else
                BD.fail (ReservedAdditionalInfo additionalInfo)

        _ ->
            BD.fail (UnknownMajorType majorType)


{-| Pre-built decoder that reads its own initial byte then decodes an item.

This is `u8 |> BD.andThen item` — cached as a top-level value to avoid
re-creating the decoder chain on each use (e.g. inside `BD.repeat`).

-}
itemBD : BD.Decoder ctx DecodeError CborItem
itemBD =
    u8 |> BD.andThen item



-- SKIP (fast path, no allocation)


{-| Skip the content of a CBOR item given its already-read initial byte.

This is the zero-allocation fast path: it uses `BD.skipBytes` throughout,
never constructing intermediate values. For containers it recursively
skips nested items.

-}
skip : Decoder ctx ()
skip initialByte =
    let
        majorType : Int
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte

        additionalInfo : Int
        additionalInfo =
            Bitwise.and 0x1F initialByte
    in
    case majorType of
        0 ->
            -- Unsigned integer: skip argument bytes only
            BD.skipBytes (argumentByteCount additionalInfo)

        1 ->
            -- Negative integer: skip argument bytes only
            BD.skipBytes (argumentByteCount additionalInfo)

        2 ->
            -- Byte string: skip argument + content bytes
            if additionalInfo == 31 then
                skipIndefinite

            else
                withArgument additionalInfo
                    (\contentLen -> BD.skipBytes contentLen)

        3 ->
            -- Text string: skip argument + content bytes
            if additionalInfo == 31 then
                skipIndefinite

            else
                withArgument additionalInfo
                    (\contentLen -> BD.skipBytes contentLen)

        4 ->
            -- Array: skip N items
            if additionalInfo == 31 then
                skipIndefinite

            else
                withArgument additionalInfo
                    skipNFull

        5 ->
            -- Map: skip N*2 items (key + value pairs)
            if additionalInfo == 31 then
                skipIndefinite

            else
                withArgument additionalInfo
                    (\count -> skipNFull (count * 2))

        6 ->
            -- Tag: skip argument bytes, then skip the tagged item
            withArgument additionalInfo
                (\_ -> skipFull)

        7 ->
            -- Simple/float: skip argument bytes (or nothing for inline)
            if additionalInfo <= 23 then
                BD.succeed ()

            else if additionalInfo <= 27 then
                BD.skipBytes (argumentByteCount additionalInfo)

            else
                BD.fail (ReservedAdditionalInfo additionalInfo)

        _ ->
            BD.fail (UnknownMajorType majorType)


{-| Skip one complete CBOR item (reads its own initial byte).
-}
skipFull : BD.Decoder ctx DecodeError ()
skipFull =
    u8 |> BD.andThen skip


{-| Skip N complete CBOR items sequentially.
-}
skipNFull : Int -> BD.Decoder ctx DecodeError ()
skipNFull count =
    BD.repeat skipFull count
        |> BD.map (\_ -> ())


{-| Skip items in an indefinite-length container until the 0xFF break byte.

Works for arrays, maps, and chunked byte/text strings.

-}
skipIndefinite : BD.Decoder ctx DecodeError ()
skipIndefinite =
    BD.loop
        (\() ->
            u8
                |> BD.andThen
                    (\byte ->
                        if byte == 0xFF then
                            BD.succeed (BD.Done ())

                        else
                            skip byte
                                |> BD.map (\() -> BD.Loop ())
                    )
        )
        ()


{-| Skip N map entries (= 2N items: N keys + N values).
-}
skipEntries : Int -> BD.Decoder ctx DecodeError ()
skipEntries count =
    skipNFull (count * 2)
