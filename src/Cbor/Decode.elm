module Cbor.Decode exposing
    ( int
    , bigInt
    , float
    , bool
    , null
    , string
    , bytes
    , array
    , keyValue
    , field
    , foldEntries
    , tag
    , RecordBuilder
    , record
    , element
    , optionalElement
    , buildRecord
    , KeyedRecordBuilder
    , keyedRecord
    , required
    , optional
    , buildKeyedRecord
    , arrayHeader
    , mapHeader
    , item
    )

{-| CBOR decoding combinators.

Build decoders for your domain types. These produce `Bytes.Decoder.Decoder`
values — use `Bytes.Decoder.decode` to run them.

    import Bytes.Decoder as BD
    import Cbor.Decode as CD

    type alias Person =
        { name : String, age : Int }

    decodePerson : BD.Decoder ctx String Person
    decodePerson =
        CD.keyedRecord CD.int Person
            |> CD.required 0 CD.string
            |> CD.required 1 CD.int
            |> CD.buildKeyedRecord

Composition combinators (`succeed`, `fail`, `andThen`, `oneOf`, `map`,
`map2`–`map5`, `keep`, `ignore`, `loop`, `repeat`, `inContext`) come from
`Bytes.Decoder` directly.

@docs int, bigInt, float, bool, null, string, bytes


## Collections

@docs array, keyValue, field, foldEntries, tag


## Record Builder (CBOR arrays → Elm values)

@docs RecordBuilder, record, element, optionalElement, buildRecord


## Keyed Record Builder (CBOR maps → Elm values)

@docs KeyedRecordBuilder, keyedRecord, required, optional, buildKeyedRecord


## Structure Headers

@docs arrayHeader, mapHeader


## Escape Hatch

@docs item

-}

import Bitwise
import Bytes
import Bytes.Decoder as BD
import Bytes.Encode
import Cbor exposing (..)



-- INTERNAL HELPERS


{-| Read a single unsigned byte.
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


{-| Decode the CBOR argument from the additional info (low 5 bits).
-}
decodeArgument : Int -> BD.Decoder ctx String Int
decodeArgument additionalInfo =
    if additionalInfo <= 23 then
        BD.succeed additionalInfo

    else if additionalInfo == 24 then
        u8

    else if additionalInfo == 25 then
        u16

    else if additionalInfo == 26 then
        u32

    else if additionalInfo == 27 then
        BD.map2 (\hi lo -> hi * 0x0100000000 + lo) u32 u32

    else
        BD.fail ("Reserved additional info: " ++ String.fromInt additionalInfo)


{-| Decode the CBOR argument, returning the width and value.
-}
decodeArgument64 : Int -> BD.Decoder ctx String ( IntWidth, Int )
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
        BD.map2 (\hi lo -> ( IW64, hi * 0x0100000000 + lo )) u32 u32

    else
        BD.fail ("Reserved additional info: " ++ String.fromInt additionalInfo)


decodeArgumentBytes : Int -> BD.Decoder ctx String Bytes.Bytes
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
        BD.fail ("Reserved additional info: " ++ String.fromInt additionalInfo)


encodeSingleByte : Int -> Bytes.Bytes
encodeSingleByte n =
    Bytes.Encode.encode (Bytes.Encode.unsignedInt8 n)


{-| Maximum safe integer value for Elm (2^52).
-}
maxSafeInt : Int
maxSafeInt =
    4503599627370496



-- PRIMITIVES


{-| Decode a CBOR integer (major types 0 and 1).

Fails if the absolute value exceeds 2^52. For larger values, use `bigInt`.

-}
int : BD.Decoder ctx String Int
int =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType == 0 then
                    decodeArgument additionalInfo
                        |> BD.andThen
                            (\n ->
                                if n > maxSafeInt then
                                    BD.fail "Integer value exceeds safe range (2^52)"

                                else
                                    BD.succeed n
                            )

                else if majorType == 1 then
                    decodeArgument additionalInfo
                        |> BD.andThen
                            (\n ->
                                if n > maxSafeInt then
                                    BD.fail "Integer value exceeds safe range (2^52)"

                                else
                                    BD.succeed (-1 - n)
                            )

                else
                    BD.fail ("Expected integer (major type 0 or 1) but got major type " ++ String.fromInt majorType)
            )


{-| Decode any CBOR integer, including bignums (tags 2 and 3).

Returns `( Sign, Bytes )` where `Bytes` is the minimal big-endian
representation of the unsigned argument.

-}
bigInt : BD.Decoder ctx String ( Sign, Bytes.Bytes )
bigInt =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

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
                    decodeArgument additionalInfo
                        |> BD.andThen
                            (\tagNum ->
                                if tagNum == 2 then
                                    decodeBytesRaw
                                        |> BD.map (\bs -> ( Positive, bs ))

                                else if tagNum == 3 then
                                    decodeBytesRaw
                                        |> BD.map (\bs -> ( Negative, bs ))

                                else
                                    BD.fail ("Expected bignum tag (2 or 3) but got tag " ++ String.fromInt tagNum)
                            )

                else
                    BD.fail ("Expected integer or bignum but got major type " ++ String.fromInt majorType)
            )


{-| Decode a CBOR float (major type 7, additional info 25/26/27).
-}
float : BD.Decoder ctx String Float
float =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 7 then
                    BD.fail ("Expected float (major type 7) but got major type " ++ String.fromInt majorType)

                else if additionalInfo == 25 then
                    BD.float16 Bytes.BE

                else if additionalInfo == 26 then
                    BD.float32 Bytes.BE

                else if additionalInfo == 27 then
                    BD.float64 Bytes.BE

                else
                    BD.fail ("Expected float (additional info 25/26/27) but got " ++ String.fromInt additionalInfo)
            )


{-| Decode a CBOR boolean (0xF4 for false, 0xF5 for true).
-}
bool : BD.Decoder ctx String Bool
bool =
    u8
        |> BD.andThen
            (\byte ->
                if byte == 0xF4 then
                    BD.succeed False

                else if byte == 0xF5 then
                    BD.succeed True

                else
                    BD.fail ("Expected boolean (0xF4 or 0xF5) but got 0x" ++ intToHex byte)
            )


{-| Decode a CBOR null (0xF6), returning the provided default value.
-}
null : a -> BD.Decoder ctx String a
null default =
    u8
        |> BD.andThen
            (\byte ->
                if byte == 0xF6 then
                    BD.succeed default

                else
                    BD.fail ("Expected null (0xF6) but got 0x" ++ intToHex byte)
            )


{-| Decode a CBOR text string (major type 3).

Concatenates indefinite-length chunks transparently.

-}
string : BD.Decoder ctx String String
string =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 3 then
                    BD.fail ("Expected text string (major type 3) but got major type " ++ String.fromInt majorType)

                else if additionalInfo == 31 then
                    BD.loop
                        (\chunks ->
                            u8
                                |> BD.andThen
                                    (\byte ->
                                        if byte == 0xFF then
                                            BD.succeed (BD.Done (String.concat (List.reverse chunks)))

                                        else
                                            let
                                                chunkAI =
                                                    Bitwise.and 0x1F byte
                                            in
                                            decodeArgument chunkAI
                                                |> BD.andThen (\len -> BD.string len)
                                                |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                                    )
                        )
                        []

                else
                    decodeArgument additionalInfo
                        |> BD.andThen (\len -> BD.string len)
            )


{-| Decode a CBOR byte string (major type 2).

Concatenates indefinite-length chunks transparently.

-}
bytes : BD.Decoder ctx String Bytes.Bytes
bytes =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 2 then
                    BD.fail ("Expected byte string (major type 2) but got major type " ++ String.fromInt majorType)

                else if additionalInfo == 31 then
                    BD.loop
                        (\chunks ->
                            u8
                                |> BD.andThen
                                    (\byte ->
                                        if byte == 0xFF then
                                            BD.succeed (BD.Done (concatBytes (List.reverse chunks)))

                                        else
                                            let
                                                chunkAI =
                                                    Bitwise.and 0x1F byte
                                            in
                                            decodeArgument chunkAI
                                                |> BD.andThen (\len -> BD.bytes len)
                                                |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                                    )
                        )
                        []

                else
                    decodeArgument additionalInfo
                        |> BD.andThen (\len -> BD.bytes len)
            )


decodeBytesRaw : BD.Decoder ctx String Bytes.Bytes
decodeBytesRaw =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 2 then
                    BD.fail ("Expected byte string (major type 2) but got major type " ++ String.fromInt majorType)

                else
                    decodeArgument additionalInfo
                        |> BD.andThen (\len -> BD.bytes len)
            )



-- COLLECTIONS


{-| Decode a CBOR array (major type 4) where all elements use the same decoder.

Handles both definite and indefinite-length arrays.

-}
array : BD.Decoder ctx String a -> BD.Decoder ctx String (List a)
array elementDecoder =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 4 then
                    BD.fail ("Expected array (major type 4) but got major type " ++ String.fromInt majorType)

                else if additionalInfo == 31 then
                    BD.loop
                        (\acc ->
                            BD.oneOf
                                [ breakCode |> BD.map (\_ -> BD.Done (List.reverse acc))
                                , elementDecoder |> BD.map (\v -> BD.Loop (v :: acc))
                                ]
                        )
                        []

                else
                    decodeArgument additionalInfo
                        |> BD.andThen (\count -> BD.repeat elementDecoder count)
            )


{-| Decode a CBOR map (major type 5) as a list of key-value pairs.

Handles both definite and indefinite-length maps.

-}
keyValue : BD.Decoder ctx String k -> BD.Decoder ctx String v -> BD.Decoder ctx String (List ( k, v ))
keyValue keyDecoder valueDecoder =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 5 then
                    BD.fail ("Expected map (major type 5) but got major type " ++ String.fromInt majorType)

                else if additionalInfo == 31 then
                    BD.loop
                        (\acc ->
                            BD.oneOf
                                [ breakCode |> BD.map (\_ -> BD.Done (List.reverse acc))
                                , BD.map2 Tuple.pair keyDecoder valueDecoder
                                    |> BD.map (\pair -> BD.Loop (pair :: acc))
                                ]
                        )
                        []

                else
                    decodeArgument additionalInfo
                        |> BD.andThen
                            (\count ->
                                BD.repeat (BD.map2 Tuple.pair keyDecoder valueDecoder) count
                            )
            )


{-| Decode the next map entry, expecting a specific key.

Reads the key, compares via `==`, then decodes the value on match.
Fails on mismatch.

-}
field : k -> BD.Decoder ctx String k -> BD.Decoder ctx String v -> BD.Decoder ctx String v
field expectedKey keyDecoder valueDecoder =
    keyDecoder
        |> BD.andThen
            (\key ->
                if key == expectedKey then
                    valueDecoder

                else
                    BD.fail "Map key mismatch"
            )


{-| Fold over map entries with a handler for each key.

Reads the map header, then loops through entries. For each entry: decode
the key, call the handler with the key and current accumulator. The handler
decodes the value and returns the updated accumulator.

**Important**: the handler MUST decode exactly one value per call.

-}
foldEntries :
    BD.Decoder ctx String k
    -> (k -> acc -> BD.Decoder ctx String acc)
    -> acc
    -> BD.Decoder ctx String acc
foldEntries keyDecoder handler initialAcc =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 5 then
                    BD.fail ("Expected map (major type 5) but got major type " ++ String.fromInt majorType)

                else if additionalInfo == 31 then
                    BD.loop
                        (\acc ->
                            BD.oneOf
                                [ breakCode |> BD.map (\_ -> BD.Done acc)
                                , keyDecoder
                                    |> BD.andThen (\key -> handler key acc)
                                    |> BD.map BD.Loop
                                ]
                        )
                        initialAcc

                else
                    decodeArgument additionalInfo
                        |> BD.andThen
                            (\count ->
                                BD.loop
                                    (\( remaining, acc ) ->
                                        if remaining <= 0 then
                                            BD.succeed (BD.Done acc)

                                        else
                                            keyDecoder
                                                |> BD.andThen (\key -> handler key acc)
                                                |> BD.map (\newAcc -> BD.Loop ( remaining - 1, newAcc ))
                                    )
                                    ( count, initialAcc )
                            )
            )


{-| Decode a tagged CBOR value (major type 6).

Expects a specific tag, then decodes the enclosed item.

-}
tag : Tag -> BD.Decoder ctx String a -> BD.Decoder ctx String a
tag expectedTag innerDecoder =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 6 then
                    BD.fail ("Expected tag (major type 6) but got major type " ++ String.fromInt majorType)

                else
                    decodeArgument additionalInfo
                        |> BD.andThen
                            (\tagNum ->
                                if tagNum == tagToInt expectedTag then
                                    innerDecoder

                                else
                                    BD.fail ("Expected tag " ++ String.fromInt (tagToInt expectedTag) ++ " but got " ++ String.fromInt tagNum)
                            )
            )



-- STRUCTURE HEADERS


{-| Decode a CBOR array header, returning the count or `Nothing` for
indefinite-length.
-}
arrayHeader : BD.Decoder ctx String (Maybe Int)
arrayHeader =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 4 then
                    BD.fail ("Expected array (major type 4) but got major type " ++ String.fromInt majorType)

                else if additionalInfo == 31 then
                    BD.succeed Nothing

                else
                    decodeArgument additionalInfo
                        |> BD.map Just
            )


{-| Decode a CBOR map header, returning the entry count or `Nothing` for
indefinite-length.
-}
mapHeader : BD.Decoder ctx String (Maybe Int)
mapHeader =
    u8
        |> BD.andThen
            (\initialByte ->
                let
                    majorType =
                        Bitwise.shiftRightZfBy 5 initialByte

                    additionalInfo =
                        Bitwise.and 0x1F initialByte
                in
                if majorType /= 5 then
                    BD.fail ("Expected map (major type 5) but got major type " ++ String.fromInt majorType)

                else if additionalInfo == 31 then
                    BD.succeed Nothing

                else
                    decodeArgument additionalInfo
                        |> BD.map Just
            )



-- RECORD BUILDER (CBOR arrays → Elm values)


{-| Opaque builder for decoding CBOR arrays into Elm values.
-}
type RecordBuilder ctx a
    = RecordBuilder (Int -> BD.Decoder ctx String ( Int, a ))


{-| Start building a record decoder with the constructor function.

    record Point
        |> element float
        |> element float
        |> buildRecord

-}
record : a -> RecordBuilder ctx a
record constructor =
    RecordBuilder (\remaining -> BD.succeed ( remaining, constructor ))


{-| Decode one array element, applying it to the constructor.
-}
element : BD.Decoder ctx String v -> RecordBuilder ctx (v -> a) -> RecordBuilder ctx a
element valueDecoder (RecordBuilder innerDecoder) =
    RecordBuilder
        (\remaining ->
            innerDecoder remaining
                |> BD.andThen
                    (\( rem, f ) ->
                        if rem > 0 then
                            valueDecoder
                                |> BD.map (\v -> ( rem - 1, f v ))

                        else
                            BD.fail "Array has fewer elements than expected"
                    )
        )


{-| Decode an optional array element, using the default if no items remain.

Optional elements must be at the end of the array.

-}
optionalElement : BD.Decoder ctx String v -> v -> RecordBuilder ctx (v -> a) -> RecordBuilder ctx a
optionalElement valueDecoder default (RecordBuilder innerDecoder) =
    RecordBuilder
        (\remaining ->
            innerDecoder remaining
                |> BD.andThen
                    (\( rem, f ) ->
                        if rem > 0 then
                            valueDecoder
                                |> BD.map (\v -> ( rem - 1, f v ))

                        else
                            BD.succeed ( 0, f default )
                    )
        )


{-| Finalize a record builder into a decoder.

Reads the array header, runs the builder pipeline, and verifies all
elements were consumed.

-}
buildRecord : RecordBuilder ctx a -> BD.Decoder ctx String a
buildRecord (RecordBuilder decoder) =
    arrayHeader
        |> BD.andThen
            (\maybeN ->
                case maybeN of
                    Just n ->
                        decoder n
                            |> BD.andThen
                                (\( rem, value ) ->
                                    if rem == 0 then
                                        BD.succeed value

                                    else
                                        skipItems rem
                                            |> BD.map (\_ -> value)
                                )

                    Nothing ->
                        BD.fail "Indefinite-length arrays in record builder not yet supported"
            )



-- KEYED RECORD BUILDER (CBOR maps → Elm values)


{-| Opaque builder for decoding CBOR maps into Elm values.
-}
type KeyedRecordBuilder ctx k a
    = KeyedRecordBuilder (BD.Decoder ctx String k) (Int -> BD.Decoder ctx String (KeyedState k a))


type alias KeyedState k a =
    { remaining : Int
    , pendingKey : Maybe k
    , value : a
    }


{-| Start building a keyed record decoder.

    keyedRecord int Person
        |> required 0 string
        |> required 1 int
        |> buildKeyedRecord

-}
keyedRecord : BD.Decoder ctx String k -> a -> KeyedRecordBuilder ctx k a
keyedRecord keyDecoder constructor =
    KeyedRecordBuilder keyDecoder
        (\remaining ->
            BD.succeed
                { remaining = remaining
                , pendingKey = Nothing
                , value = constructor
                }
        )


{-| Decode a required map field by key.

The key order in the builder must match the key order in the CBOR data.

-}
required : k -> BD.Decoder ctx String v -> KeyedRecordBuilder ctx k (v -> a) -> KeyedRecordBuilder ctx k a
required expectedKey valueDecoder (KeyedRecordBuilder keyDecoder innerDecoder) =
    KeyedRecordBuilder keyDecoder
        (\remaining ->
            innerDecoder remaining
                |> BD.andThen
                    (\state ->
                        (case state.pendingKey of
                            Just k ->
                                BD.succeed k

                            Nothing ->
                                keyDecoder
                        )
                            |> BD.andThen
                                (\key ->
                                    if key == expectedKey then
                                        valueDecoder
                                            |> BD.map
                                                (\v ->
                                                    { remaining = state.remaining - 1
                                                    , pendingKey = Nothing
                                                    , value = state.value v
                                                    }
                                                )

                                    else
                                        BD.fail "Map key mismatch in required field"
                                )
                    )
        )


{-| Decode an optional map field by key.

If the next key doesn't match, the key is stashed for the next step
and the default value is used.

-}
optional : k -> BD.Decoder ctx String v -> v -> KeyedRecordBuilder ctx k (v -> a) -> KeyedRecordBuilder ctx k a
optional expectedKey valueDecoder default (KeyedRecordBuilder keyDecoder innerDecoder) =
    KeyedRecordBuilder keyDecoder
        (\remaining ->
            innerDecoder remaining
                |> BD.andThen
                    (\state ->
                        if state.remaining == 0 && state.pendingKey == Nothing then
                            BD.succeed
                                { remaining = 0
                                , pendingKey = Nothing
                                , value = state.value default
                                }

                        else
                            (case state.pendingKey of
                                Just k ->
                                    BD.succeed k

                                Nothing ->
                                    keyDecoder
                            )
                                |> BD.andThen
                                    (\key ->
                                        if key == expectedKey then
                                            valueDecoder
                                                |> BD.map
                                                    (\v ->
                                                        { remaining = state.remaining - 1
                                                        , pendingKey = Nothing
                                                        , value = state.value v
                                                        }
                                                    )

                                        else
                                            BD.succeed
                                                { remaining = state.remaining
                                                , pendingKey = Just key
                                                , value = state.value default
                                                }
                                    )
                    )
        )


{-| Finalize a keyed record builder into a decoder.

Reads the map header, runs the builder pipeline, and verifies all
entries were consumed.

-}
buildKeyedRecord : KeyedRecordBuilder ctx k a -> BD.Decoder ctx String a
buildKeyedRecord (KeyedRecordBuilder _ decoder) =
    mapHeader
        |> BD.andThen
            (\maybeN ->
                case maybeN of
                    Just n ->
                        decoder n
                            |> BD.andThen
                                (\state ->
                                    if state.remaining == 0 && state.pendingKey == Nothing then
                                        BD.succeed state.value

                                    else if state.pendingKey == Nothing then
                                        skipEntries state.remaining
                                            |> BD.map (\_ -> state.value)

                                    else
                                        BD.fail "Unexpected pending key at end of keyed record"
                                )

                    Nothing ->
                        BD.fail "Indefinite-length maps in keyed record builder not yet supported"
            )



-- ESCAPE HATCH


{-| Decode any well-formed CBOR data item into a `CborItem`.

This is the full CBOR parser. Handles all major types, nested structures,
tags, indefinite-length containers, etc.

-}
item : BD.Decoder ctx String CborItem
item =
    u8
        |> BD.andThen decodeItemBody


decodeItemBody : Int -> BD.Decoder ctx String CborItem
decodeItemBody initialByte =
    let
        majorType =
            Bitwise.shiftRightZfBy 5 initialByte

        additionalInfo =
            Bitwise.and 0x1F initialByte
    in
    case majorType of
        0 ->
            -- Unsigned integer
            decodeArgument64 additionalInfo
                |> BD.map (\( width, n ) -> CborInt52 width n)

        1 ->
            -- Negative integer
            decodeArgument64 additionalInfo
                |> BD.map (\( width, n ) -> CborInt52 width (-1 - n))

        2 ->
            -- Byte string
            if additionalInfo == 31 then
                BD.loop
                    (\chunks ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborByteStringChunked (List.reverse chunks)))

                                    else
                                        decodeArgument (Bitwise.and 0x1F byte)
                                            |> BD.andThen (\len -> BD.bytes len)
                                            |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                                )
                    )
                    []

            else
                decodeArgument additionalInfo
                    |> BD.andThen (\len -> BD.bytes len)
                    |> BD.map CborByteString

        3 ->
            -- Text string
            if additionalInfo == 31 then
                BD.loop
                    (\chunks ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborStringChunked (List.reverse chunks)))

                                    else
                                        decodeArgument (Bitwise.and 0x1F byte)
                                            |> BD.andThen (\len -> BD.string len)
                                            |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                                )
                    )
                    []

            else
                decodeArgument additionalInfo
                    |> BD.andThen (\len -> BD.string len)
                    |> BD.map CborString

        4 ->
            -- Array
            if additionalInfo == 31 then
                BD.loop
                    (\items ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborArray Indefinite (List.reverse items)))

                                    else
                                        decodeItemBody byte
                                            |> BD.map (\v -> BD.Loop (v :: items))
                                )
                    )
                    []

            else
                decodeArgument additionalInfo
                    |> BD.andThen
                        (\count ->
                            BD.loop
                                (\( remaining, acc ) ->
                                    if remaining <= 0 then
                                        BD.succeed (BD.Done (CborArray Definite (List.reverse acc)))

                                    else
                                        item
                                            |> BD.map (\v -> BD.Loop ( remaining - 1, v :: acc ))
                                )
                                ( count, [] )
                        )

        5 ->
            -- Map
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
                                            (decodeItemBody byte)
                                            item
                                )
                    )
                    []

            else
                decodeArgument additionalInfo
                    |> BD.andThen
                        (\count ->
                            BD.loop
                                (\( remaining, acc ) ->
                                    if remaining <= 0 then
                                        BD.succeed (BD.Done (CborMap Definite (List.reverse acc)))

                                    else
                                        BD.map2
                                            (\k v -> BD.Loop ( remaining - 1, { key = k, value = v } :: acc ))
                                            item
                                            item
                                )
                                ( count, [] )
                        )

        6 ->
            -- Tag
            decodeArgument additionalInfo
                |> BD.andThen
                    (\tagNum ->
                        item
                            |> BD.map (\enclosed -> CborTag (intToTag tagNum) enclosed)
                    )

        7 ->
            -- Simple values and floats
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
                BD.fail ("Reserved additional info: " ++ String.fromInt additionalInfo)

        _ ->
            BD.fail ("Unknown major type: " ++ String.fromInt majorType)



-- INTERNAL HELPERS


{-| Decode a break code (0xFF). Used in oneOf for indefinite-length containers.
-}
breakCode : BD.Decoder ctx String ()
breakCode =
    u8
        |> BD.andThen
            (\byte ->
                if byte == 0xFF then
                    BD.succeed ()

                else
                    BD.fail "Expected break code (0xFF)"
            )


concatBytes : List Bytes.Bytes -> Bytes.Bytes
concatBytes chunks =
    Bytes.Encode.encode
        (Bytes.Encode.sequence (List.map Bytes.Encode.bytes chunks))


skipItems : Int -> BD.Decoder ctx String ()
skipItems count =
    BD.loop
        (\remaining ->
            if remaining <= 0 then
                BD.succeed (BD.Done ())

            else
                item |> BD.map (\_ -> BD.Loop (remaining - 1))
        )
        count


skipEntries : Int -> BD.Decoder ctx String ()
skipEntries count =
    skipItems (count * 2)


intToHex : Int -> String
intToHex n =
    let
        hi =
            Bitwise.shiftRightZfBy 4 n

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
