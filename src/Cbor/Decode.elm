module Cbor.Decode exposing
    ( CborDecoder, decode, toBD, fromBD
    , DecodeError(..), errorToString
    , succeed, fail
    , map, map2, andThen, oneOf, keep, ignore, loop, lazy
    , int, bigInt, float, bool, null, string, bytes
    , array, keyValue, field, foldEntries, tag
    , RecordBuilder, record, element, optionalElement, buildRecord
    , KeyedRecordBuilder, keyedRecord, required, optional, buildKeyedRecord
    , arrayHeader, mapHeader
    , item
    )

{-| CBOR decoding combinators.

Build decoders for your domain types. These produce `CborDecoder` values.
Run them with `decode`, or convert to a `Bytes.Decoder.Decoder` with `toBD`.

    import Cbor.Decode as CD

    type alias Person =
        { name : String, age : Int }

    decodePerson : CD.CborDecoder ctx Person
    decodePerson =
        CD.keyedRecord CD.int Person
            |> CD.required 0 CD.string
            |> CD.required 1 CD.int
            |> CD.buildKeyedRecord

    -- To run: CD.decode decodePerson someBytes


## Type

@docs CborDecoder, decode, toBD, fromBD


## Errors

@docs DecodeError, errorToString


## Combinators

@docs succeed, fail
@docs map, map2, andThen, oneOf, keep, ignore, loop, lazy


## Primitives

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
import Cbor exposing (CborItem(..), FloatWidth(..), IntWidth(..), Length(..), Sign(..), SimpleWidth(..), Tag(..), tagToInt)



-- TYPE


{-| Opaque CBOR decoder.

Internally uses two variants: `Item` receives a pre-read initial byte
(the CBOR byte encoding major type + additional info), and `Pure` consumes
no bytes (used by `succeed`, `fail`). This split enables fast-path decoding
for indefinite-length collections without `BD.oneOf`.

-}
type CborDecoder ctx a
    = Item (Int -> BD.Decoder ctx DecodeError a)
    | Pure (BD.Decoder ctx DecodeError a)


{-| Convert a `CborDecoder` to a `Bytes.Decoder.Decoder`.

`Item` decoders read one byte first; `Pure` decoders pass through.
Use this at the boundary when you need to run a decoder with `BD.decode`.

-}
toBD : CborDecoder ctx a -> BD.Decoder ctx DecodeError a
toBD decoder =
    case decoder of
        Item body ->
            u8 |> BD.andThen body

        Pure bd ->
            bd


{-| Run a `CborDecoder` on some `Bytes`.

Convenience for `Bytes.Decoder.decode (toBD decoder) bytes`.

-}
decode : CborDecoder ctx a -> Bytes.Bytes -> Result (BD.Error ctx DecodeError) a
decode decoder input =
    BD.decode (toBD decoder) input


{-| Wrap a raw `Bytes.Decoder.Decoder` as a `CborDecoder` that consumes
no initial byte.
-}
fromBD : BD.Decoder ctx DecodeError a -> CborDecoder ctx a
fromBD bd =
    Pure bd



-- ERRORS


{-| Structured error type for CBOR decoding failures.
-}
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


{-| Convert a `DecodeError` to a human-readable string.
-}
errorToString : DecodeError -> String
errorToString err =
    case err of
        WrongMajorType { expected, got } ->
            "Expected major type " ++ String.fromInt expected ++ " but got " ++ String.fromInt got

        WrongInitialByte { got } ->
            "Unexpected initial byte: 0x" ++ intToHex got

        WrongTag { expected, got } ->
            "Expected tag " ++ String.fromInt expected ++ " but got " ++ String.fromInt got

        ReservedAdditionalInfo ai ->
            "Reserved additional info: " ++ String.fromInt ai

        IntegerOverflow ->
            "Integer value exceeds safe range (2^52)"

        KeyMismatch ->
            "Map key mismatch"

        TooFewElements ->
            "Array has fewer elements than expected"

        UnexpectedPendingKey ->
            "Unexpected pending key at end of keyed record"

        IndefiniteLengthNotSupported ->
            "Indefinite-length encoding not supported in record builder"

        UnknownMajorType mt ->
            "Unknown major type: " ++ String.fromInt mt



-- COMBINATORS


{-| A decoder that always succeeds with the given value, consuming no bytes.
-}
succeed : a -> CborDecoder ctx a
succeed a =
    Pure (BD.succeed a)


{-| A decoder that always fails with the given error.
-}
fail : DecodeError -> CborDecoder ctx a
fail err =
    Pure (BD.fail err)


{-| Transform the result of a decoder.
-}
map : (a -> b) -> CborDecoder ctx a -> CborDecoder ctx b
map f decoder =
    case decoder of
        Item body ->
            Item (\ib -> body ib |> BD.map f)

        Pure bd ->
            Pure (bd |> BD.map f)


{-| Combine two decoders sequentially.
-}
map2 : (a -> b -> c) -> CborDecoder ctx a -> CborDecoder ctx b -> CborDecoder ctx c
map2 f decoderA decoderB =
    case decoderA of
        Item bodyA ->
            let
                bdB =
                    toBD decoderB
            in
            Item (\ib -> BD.map2 f (bodyA ib) bdB)

        Pure bdA ->
            case decoderB of
                Item bodyB ->
                    Item (\ib -> BD.map2 f bdA (bodyB ib))

                Pure bdB ->
                    Pure (BD.map2 f bdA bdB)


{-| Chain decoders. The continuation is chosen based on the first result.
-}
andThen : (a -> CborDecoder ctx b) -> CborDecoder ctx a -> CborDecoder ctx b
andThen f decoder =
    case decoder of
        Item body ->
            Item (\ib -> body ib |> BD.andThen (\a -> toBD (f a)))

        Pure bd ->
            Pure (bd |> BD.andThen (\a -> toBD (f a)))


{-| Try multiple decoders in order. Each decoder sees the same initial byte.
-}
oneOf : List (CborDecoder ctx a) -> CborDecoder ctx a
oneOf decoders =
    Item
        (\initialByte ->
            BD.oneOf
                (List.map
                    (\d ->
                        case d of
                            Item body ->
                                body initialByte

                            Pure bd ->
                                bd
                    )
                    decoders
                )
        )


{-| Apply a decoder producing a function to a decoder producing an argument.

    succeed Point
        |> keep float
        |> keep float

-}
keep : CborDecoder ctx a -> CborDecoder ctx (a -> b) -> CborDecoder ctx b
keep valueDecoder funcDecoder =
    case funcDecoder of
        Pure funcBd ->
            case valueDecoder of
                Item valueBody ->
                    Item (\ib -> BD.map2 (\f v -> f v) funcBd (valueBody ib))

                Pure valueBd ->
                    Pure (BD.map2 (\f v -> f v) funcBd valueBd)

        Item funcBody ->
            let
                valueBD =
                    toBD valueDecoder
            in
            Item (\ib -> BD.map2 (\f v -> f v) (funcBody ib) valueBD)


{-| Decode and discard a value, keeping the previous result.
-}
ignore : CborDecoder ctx ignored -> CborDecoder ctx keep -> CborDecoder ctx keep
ignore ignoredDecoder keepDecoder =
    case keepDecoder of
        Item keepBody ->
            let
                ignoredBD =
                    toBD ignoredDecoder
            in
            Item (\ib -> BD.map2 (\k _ -> k) (keepBody ib) ignoredBD)

        Pure keepBd ->
            case ignoredDecoder of
                Item ignoredBody ->
                    Item (\ib -> BD.map2 (\k _ -> k) keepBd (ignoredBody ib))

                Pure ignoredBd ->
                    Pure (BD.map2 (\k _ -> k) keepBd ignoredBd)


{-| Loop with state, decoding until `Done`.
-}
loop : (state -> CborDecoder ctx (BD.Step state a)) -> state -> CborDecoder ctx a
loop f initialState =
    Pure (BD.loop (\s -> toBD (f s)) initialState)


{-| Deferred construction for recursive decoders.
-}
lazy : (() -> CborDecoder ctx a) -> CborDecoder ctx a
lazy thunk =
    Item
        (\ib ->
            case thunk () of
                Item body ->
                    body ib

                Pure bd ->
                    bd
        )



-- INTERNAL HELPERS


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


{-| Maximum safe integer value for Elm (2^52).
-}
maxSafeInt : Int
maxSafeInt =
    4503599627370496


{-| Fused `decodeArgument` + overflow check.

For inline values (<=23), returns `BD.succeed` directly (no overflow possible).
For u8/u16/u32, returns the raw read decoder (no overflow possible).
Only the 64-bit path retains the `andThen` for the overflow check.

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


{-| Fused `decodeArgument` + continuation.

For inline arguments (<=23), calls `f` directly — no intermediate
`BD.succeed` + `BD.andThen`. For multi-byte arguments, composes via
`BD.andThen` as before.

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


{-| Decode the CBOR argument, returning the width and value.
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


decodeArgumentBytes : Int -> BD.Decoder ctx DecodeError Bytes.Bytes
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


encodeSingleByte : Int -> Bytes.Bytes
encodeSingleByte n =
    Bytes.Encode.encode (Bytes.Encode.unsignedInt8 n)


intPairToBytes : Int -> Int -> Bytes.Bytes
intPairToBytes hi lo =
    Bytes.Encode.encode
        (Bytes.Encode.sequence
            [ Bytes.Encode.unsignedInt32 Bytes.BE hi
            , Bytes.Encode.unsignedInt32 Bytes.BE lo
            ]
        )


concatBytes : List Bytes.Bytes -> Bytes.Bytes
concatBytes chunks =
    Bytes.Encode.encode
        (Bytes.Encode.sequence (List.map Bytes.Encode.bytes chunks))


decodeBytesRaw : BD.Decoder ctx DecodeError Bytes.Bytes
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


skipItems : Int -> BD.Decoder ctx DecodeError ()
skipItems count =
    BD.loop
        (\remaining ->
            if remaining <= 0 then
                BD.succeed (BD.Done ())

            else
                itemBD |> BD.map (\_ -> BD.Loop (remaining - 1))
        )
        count


skipEntries : Int -> BD.Decoder ctx DecodeError ()
skipEntries count =
    skipItems (count * 2)


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

Fails if the absolute value exceeds 2^52. For larger values, use `bigInt`.

-}
int : CborDecoder ctx Int
int =
    Item
        (\initialByte ->
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
                safeArgument additionalInfo
                    |> BD.map (\n -> -1 - n)

            else
                BD.fail (WrongMajorType { expected = 0, got = majorType })
        )


{-| Decode any CBOR integer, including bignums (tags 2 and 3).

Returns `( Sign, Bytes )` where `Bytes` is the minimal big-endian
representation of the unsigned argument.

-}
bigInt : CborDecoder ctx ( Sign, Bytes.Bytes )
bigInt =
    Item
        (\initialByte ->
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
        )


{-| Decode a CBOR float (major type 7, additional info 25/26/27).
-}
float : CborDecoder ctx Float
float =
    Item
        (\initialByte ->
            let
                majorType : Int
                majorType =
                    Bitwise.shiftRightZfBy 5 initialByte

                additionalInfo : Int
                additionalInfo =
                    Bitwise.and 0x1F initialByte
            in
            if majorType /= 7 then
                BD.fail (WrongMajorType { expected = 7, got = majorType })

            else if additionalInfo == 25 then
                BD.float16 Bytes.BE

            else if additionalInfo == 26 then
                BD.float32 Bytes.BE

            else if additionalInfo == 27 then
                BD.float64 Bytes.BE

            else
                BD.fail (WrongInitialByte { got = initialByte })
        )


{-| Decode a CBOR boolean (0xF4 for false, 0xF5 for true).
-}
bool : CborDecoder ctx Bool
bool =
    Item
        (\initialByte ->
            if initialByte == 0xF4 then
                BD.succeed False

            else if initialByte == 0xF5 then
                BD.succeed True

            else
                BD.fail (WrongInitialByte { got = initialByte })
        )


{-| Decode a CBOR null (0xF6), returning the provided default value.
-}
null : a -> CborDecoder ctx a
null default =
    Item
        (\initialByte ->
            if initialByte == 0xF6 then
                BD.succeed default

            else
                BD.fail (WrongInitialByte { got = initialByte })
        )


{-| Decode a CBOR text string (major type 3).

Concatenates indefinite-length chunks transparently.

-}
string : CborDecoder ctx String
string =
    Item
        (\initialByte ->
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
        )


{-| Decode a CBOR byte string (major type 2).

Concatenates indefinite-length chunks transparently.

-}
bytes : CborDecoder ctx Bytes.Bytes
bytes =
    Item
        (\initialByte ->
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
        )



-- COLLECTIONS


{-| Decode a CBOR array (major type 4) where all elements use the same decoder.

Handles both definite and indefinite-length arrays. For indefinite-length,
the element's initial byte is passed directly to its body function,
staying on the fast `Decode.loop` path without `BD.oneOf`.

-}
array : CborDecoder ctx a -> CborDecoder ctx (List a)
array elementDecoder =
    let
        elementBD =
            toBD elementDecoder
    in
    Item
        (\initialByte ->
            let
                majorType : Int
                majorType =
                    Bitwise.shiftRightZfBy 5 initialByte

                additionalInfo : Int
                additionalInfo =
                    Bitwise.and 0x1F initialByte
            in
            if majorType /= 4 then
                BD.fail (WrongMajorType { expected = 4, got = majorType })

            else if additionalInfo == 31 then
                case elementDecoder of
                    Item elementBody ->
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

                    Pure _ ->
                        BD.fail (WrongInitialByte { got = initialByte })

            else
                withArgument additionalInfo
                    (\count -> BD.repeat elementBD count)
        )


{-| Decode a CBOR map (major type 5) as a list of key-value pairs.

Handles both definite and indefinite-length maps.

-}
keyValue : CborDecoder ctx k -> CborDecoder ctx v -> CborDecoder ctx (List ( k, v ))
keyValue keyDecoder valueDecoder =
    let
        valueBD =
            toBD valueDecoder

        keyBD =
            toBD keyDecoder
    in
    Item
        (\initialByte ->
            let
                majorType : Int
                majorType =
                    Bitwise.shiftRightZfBy 5 initialByte

                additionalInfo : Int
                additionalInfo =
                    Bitwise.and 0x1F initialByte
            in
            if majorType /= 5 then
                BD.fail (WrongMajorType { expected = 5, got = majorType })

            else if additionalInfo == 31 then
                case keyDecoder of
                    Item keyBody ->
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

                    Pure _ ->
                        BD.fail (WrongInitialByte { got = initialByte })

            else
                withArgument additionalInfo
                    (\count ->
                        BD.repeat
                            (BD.map2 Tuple.pair keyBD valueBD)
                            count
                    )
        )


{-| Decode the next map entry, expecting a specific key.

Reads the key, compares via `==`, then decodes the value on match.
Fails on mismatch.

-}
field : k -> CborDecoder ctx k -> CborDecoder ctx v -> CborDecoder ctx v
field expectedKey keyDecoder valueDecoder =
    keyDecoder
        |> andThen
            (\key ->
                if key == expectedKey then
                    valueDecoder

                else
                    fail KeyMismatch
            )


{-| Fold over map entries with a handler for each key.

Reads the map header, then loops through entries. For each entry: decode
the key, call the handler with the key and current accumulator. The handler
decodes the value and returns the updated accumulator.

**Important**: the handler MUST decode exactly one value per call.

The handler returns `BD.Decoder` (not `CborDecoder`) so it can decode
different value types per key. Use `toBD` to convert value decoders:

    handler key acc =
        case key of
            0 ->
                toBD string |> BD.map (\name -> { acc | name = name })

            1 ->
                toBD int |> BD.map (\age -> { acc | age = age })

            _ ->
                toBD item |> BD.map (\_ -> acc)

-}
foldEntries :
    CborDecoder ctx k
    -> (k -> acc -> BD.Decoder ctx DecodeError acc)
    -> acc
    -> CborDecoder ctx acc
foldEntries keyDecoder handler initialAcc =
    let
        keyBD =
            toBD keyDecoder
    in
    Item
        (\initialByte ->
            let
                majorType : Int
                majorType =
                    Bitwise.shiftRightZfBy 5 initialByte

                additionalInfo : Int
                additionalInfo =
                    Bitwise.and 0x1F initialByte
            in
            if majorType /= 5 then
                BD.fail (WrongMajorType { expected = 5, got = majorType })

            else if additionalInfo == 31 then
                case keyDecoder of
                    Item keyBody ->
                        BD.loop
                            (\acc ->
                                u8
                                    |> BD.andThen
                                        (\byte ->
                                            if byte == 0xFF then
                                                BD.succeed (BD.Done acc)

                                            else
                                                keyBody byte
                                                    |> BD.andThen (\key -> handler key acc)
                                                    |> BD.map BD.Loop
                                        )
                            )
                            initialAcc

                    Pure _ ->
                        BD.fail (WrongInitialByte { got = initialByte })

            else
                withArgument additionalInfo
                    (\count ->
                        BD.loop
                            (\( remaining, acc ) ->
                                if remaining <= 0 then
                                    BD.succeed (BD.Done acc)

                                else
                                    keyBD
                                        |> BD.andThen (\key -> handler key acc)
                                        |> BD.map (\newAcc -> BD.Loop ( remaining - 1, newAcc ))
                            )
                            ( count, initialAcc )
                    )
        )


{-| Decode a tagged CBOR value (major type 6).

Expects a specific tag, then decodes the enclosed item.

-}
tag : Tag -> CborDecoder ctx a -> CborDecoder ctx a
tag expectedTag innerDecoder =
    let
        innerBD =
            toBD innerDecoder
    in
    Item
        (\initialByte ->
            let
                majorType : Int
                majorType =
                    Bitwise.shiftRightZfBy 5 initialByte

                additionalInfo : Int
                additionalInfo =
                    Bitwise.and 0x1F initialByte
            in
            if majorType /= 6 then
                BD.fail (WrongMajorType { expected = 6, got = majorType })

            else
                withArgument additionalInfo
                    (\tagNum ->
                        if tagNum == tagToInt expectedTag then
                            innerBD

                        else
                            BD.fail (WrongTag { expected = tagToInt expectedTag, got = tagNum })
                    )
        )



-- STRUCTURE HEADERS


{-| Decode a CBOR array header, returning the count or `Nothing` for
indefinite-length.
-}
arrayHeader : CborDecoder ctx (Maybe Int)
arrayHeader =
    Item
        (\initialByte ->
            let
                majorType : Int
                majorType =
                    Bitwise.shiftRightZfBy 5 initialByte

                additionalInfo : Int
                additionalInfo =
                    Bitwise.and 0x1F initialByte
            in
            if majorType /= 4 then
                BD.fail (WrongMajorType { expected = 4, got = majorType })

            else if additionalInfo == 31 then
                BD.succeed Nothing

            else
                withArgument additionalInfo (Just >> BD.succeed)
        )


{-| Decode a CBOR map header, returning the entry count or `Nothing` for
indefinite-length.
-}
mapHeader : CborDecoder ctx (Maybe Int)
mapHeader =
    Item
        (\initialByte ->
            let
                majorType : Int
                majorType =
                    Bitwise.shiftRightZfBy 5 initialByte

                additionalInfo : Int
                additionalInfo =
                    Bitwise.and 0x1F initialByte
            in
            if majorType /= 5 then
                BD.fail (WrongMajorType { expected = 5, got = majorType })

            else if additionalInfo == 31 then
                BD.succeed Nothing

            else
                withArgument additionalInfo (Just >> BD.succeed)
        )



-- RECORD BUILDER (CBOR arrays → Elm values)


{-| Opaque builder for decoding CBOR arrays into Elm values.

Uses `SimpleBuilder` when all fields are `element` (fast path via `keep`),
or `CountedBuilder` when `optionalElement` is used (counts remaining items).

-}
type RecordBuilder ctx a
    = SimpleBuilder Int (CborDecoder ctx a)
    | CountedBuilder (Int -> BD.Decoder ctx DecodeError ( Int, a ))


{-| Start building a record decoder with the constructor function.

    record Point
        |> element float
        |> element float
        |> buildRecord

-}
record : a -> RecordBuilder ctx a
record constructor =
    SimpleBuilder 0 (succeed constructor)


{-| Decode one array element, applying it to the constructor.
-}
element : CborDecoder ctx v -> RecordBuilder ctx (v -> a) -> RecordBuilder ctx a
element valueDecoder builder =
    case builder of
        SimpleBuilder count funcDecoder ->
            SimpleBuilder (count + 1) (keep valueDecoder funcDecoder)

        CountedBuilder innerDecoder ->
            let
                valueBD =
                    toBD valueDecoder
            in
            CountedBuilder
                (\remaining ->
                    innerDecoder remaining
                        |> BD.andThen
                            (\( rem, f ) ->
                                if rem > 0 then
                                    valueBD
                                        |> BD.map (\v -> ( rem - 1, f v ))

                                else
                                    BD.fail TooFewElements
                            )
                )


{-| Decode an optional array element, using the default if no items remain.

Optional elements must be at the end of the array.

-}
optionalElement : CborDecoder ctx v -> v -> RecordBuilder ctx (v -> a) -> RecordBuilder ctx a
optionalElement valueDecoder default builder =
    let
        valueBD =
            toBD valueDecoder

        counted =
            toCountedInner builder
    in
    CountedBuilder
        (\remaining ->
            counted remaining
                |> BD.andThen
                    (\( rem, f ) ->
                        if rem > 0 then
                            valueBD
                                |> BD.map (\v -> ( rem - 1, f v ))

                        else
                            BD.succeed ( 0, f default )
                    )
        )


toCountedInner : RecordBuilder ctx a -> (Int -> BD.Decoder ctx DecodeError ( Int, a ))
toCountedInner builder =
    case builder of
        SimpleBuilder count decoder ->
            let
                decoderBD =
                    toBD decoder
            in
            \remaining ->
                decoderBD |> BD.map (\value -> ( remaining - count, value ))

        CountedBuilder inner ->
            inner


{-| Finalize a record builder into a decoder.

Reads the array header, runs the builder pipeline, and verifies all
elements were consumed.

-}
buildRecord : RecordBuilder ctx a -> CborDecoder ctx a
buildRecord builder =
    case builder of
        SimpleBuilder expectedCount decoder ->
            arrayHeader
                |> andThen
                    (\maybeN ->
                        case maybeN of
                            Just n ->
                                if n < expectedCount then
                                    fail TooFewElements

                                else if n == expectedCount then
                                    decoder

                                else
                                    decoder
                                        |> ignore (fromBD (skipItems (n - expectedCount)))

                            Nothing ->
                                fail IndefiniteLengthNotSupported
                    )

        CountedBuilder decoder ->
            andThen
                (\maybeN ->
                    case maybeN of
                        Just n ->
                            fromBD
                                (decoder n
                                    |> BD.andThen
                                        (\( rem, value ) ->
                                            if rem == 0 then
                                                BD.succeed value

                                            else
                                                skipItems rem
                                                    |> BD.map (\_ -> value)
                                        )
                                )

                        Nothing ->
                            fail IndefiniteLengthNotSupported
                )
                arrayHeader



-- KEYED RECORD BUILDER (CBOR maps → Elm values)


{-| Opaque builder for decoding CBOR maps into Elm values.
-}
type KeyedRecordBuilder ctx k a
    = KeyedRecordBuilder (CborDecoder ctx k) (Int -> BD.Decoder ctx DecodeError (KeyedState k a))


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
keyedRecord : CborDecoder ctx k -> a -> KeyedRecordBuilder ctx k a
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
required : k -> CborDecoder ctx v -> KeyedRecordBuilder ctx k (v -> a) -> KeyedRecordBuilder ctx k a
required expectedKey valueDecoder (KeyedRecordBuilder keyDecoder innerDecoder) =
    let
        keyBD =
            toBD keyDecoder

        valueBD =
            toBD valueDecoder
    in
    KeyedRecordBuilder keyDecoder
        (\remaining ->
            innerDecoder remaining
                |> BD.andThen
                    (\state ->
                        (case state.pendingKey of
                            Just k ->
                                BD.succeed k

                            Nothing ->
                                keyBD
                        )
                            |> BD.andThen
                                (\key ->
                                    if key == expectedKey then
                                        valueBD
                                            |> BD.map
                                                (\v ->
                                                    { remaining = state.remaining - 1
                                                    , pendingKey = Nothing
                                                    , value = state.value v
                                                    }
                                                )

                                    else
                                        BD.fail KeyMismatch
                                )
                    )
        )


{-| Decode an optional map field by key.

If the next key doesn't match, the key is stashed for the next step
and the default value is used.

-}
optional : k -> CborDecoder ctx v -> v -> KeyedRecordBuilder ctx k (v -> a) -> KeyedRecordBuilder ctx k a
optional expectedKey valueDecoder default (KeyedRecordBuilder keyDecoder innerDecoder) =
    let
        keyBD =
            toBD keyDecoder

        valueBD =
            toBD valueDecoder
    in
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
                                    keyBD
                            )
                                |> BD.andThen
                                    (\key ->
                                        if key == expectedKey then
                                            valueBD
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
buildKeyedRecord : KeyedRecordBuilder ctx k a -> CborDecoder ctx a
buildKeyedRecord (KeyedRecordBuilder _ decoder) =
    mapHeader
        |> andThen
            (\maybeN ->
                case maybeN of
                    Just n ->
                        Pure
                            (decoder n
                                |> BD.andThen
                                    (\state ->
                                        if state.remaining == 0 && state.pendingKey == Nothing then
                                            BD.succeed state.value

                                        else if state.pendingKey == Nothing then
                                            skipEntries state.remaining
                                                |> BD.map (\_ -> state.value)

                                        else
                                            BD.fail UnexpectedPendingKey
                                    )
                            )

                    Nothing ->
                        fail IndefiniteLengthNotSupported
            )



-- ESCAPE HATCH


{-| Decode any well-formed CBOR data item into a `CborItem`.

This is the full CBOR parser. Handles all major types, nested structures,
tags, indefinite-length containers, etc.

-}
item : CborDecoder ctx CborItem
item =
    Item itemBody


itemBD : BD.Decoder ctx DecodeError CborItem
itemBD =
    u8 |> BD.andThen itemBody


itemBody : Int -> BD.Decoder ctx DecodeError CborItem
itemBody initialByte =
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
            -- Unsigned integer
            if additionalInfo == 27 then
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
            -- Negative integer
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
                                        itemBody byte
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
                                            (itemBody byte)
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
            -- Tag
            withArgument additionalInfo
                (\tagNum ->
                    itemBD
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
                BD.fail (ReservedAdditionalInfo additionalInfo)

        _ ->
            BD.fail (UnknownMajorType majorType)
