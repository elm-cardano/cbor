module DecodeItemPure exposing
    ( CborDecoder
    , toBD, fromBD
    , succeed, fail
    , map, map2, andThen, oneOf, keep, ignore
    , loop, lazy
    , int, bigInt, float, bool, null, string, bytes
    , array, keyValue, field, foldEntries, tag
    , arrayHeader, mapHeader
    , RecordBuilder, record, element, optionalElement, buildRecord
    , KeyedRecordBuilder, keyedRecord, required, optional, buildKeyedRecord
    , item
    , dec_def_array_current, dec_def_array_ip
    , dec_indef_array_current, dec_indef_array_ip
    , dec_def_map_current, dec_def_map_ip
    , dec_indef_map_current, dec_indef_map_ip
    , dec_indef_cert_current, dec_indef_cert_ip
    , dec_plutus_indef_5_current, dec_plutus_indef_5_ip
    , dec_record_10_current, dec_record_10_ip
    , dec_keyed_10_current, dec_keyed_10_ip
    , dec_indef_fold_current, dec_indef_fold_ip
    , dec_indef_nested_current, dec_indef_nested_ip
    , dec_item_current, dec_item_ip
    , dec_opt_record_current, dec_opt_record_ip
    )

{-| Item/Pure body decoder: an opaque `CborDecoder` type with two constructors.

`Item` decoders receive a pre-read initial byte. `Pure` decoders (`succeed`,
`fail`) consume no bytes. The `Item`/`Pure` dispatch in `toBD`, `andThen`,
and `keep` ensures correct byte consumption for all CBOR composition patterns.

See `report-body-decoders.md` for the full design analysis.


# Benchmarks — indefinite collections (expect ~3x improvement)

    elm-bench -f DecodeItemPure.dec_indef_array_current -f DecodeItemPure.dec_indef_array_ip "()"
    elm-bench -f DecodeItemPure.dec_indef_map_current -f DecodeItemPure.dec_indef_map_ip "()"
    elm-bench -f DecodeItemPure.dec_indef_fold_current -f DecodeItemPure.dec_indef_fold_ip "()"
    elm-bench -f DecodeItemPure.dec_indef_nested_current -f DecodeItemPure.dec_indef_nested_ip "()"

@docs dec_indef_array_current, dec_indef_array_ip
@docs dec_indef_map_current, dec_indef_map_ip
@docs dec_indef_fold_current, dec_indef_fold_ip
@docs dec_indef_nested_current, dec_indef_nested_ip


# Benchmarks — Cardano patterns with indefinite outer containers

    elm-bench -f DecodeItemPure.dec_indef_cert_current -f DecodeItemPure.dec_indef_cert_ip "()"
    elm-bench -f DecodeItemPure.dec_plutus_indef_5_current -f DecodeItemPure.dec_plutus_indef_5_ip "()"

@docs dec_indef_cert_current, dec_indef_cert_ip
@docs dec_plutus_indef_5_current, dec_plutus_indef_5_ip


# Benchmarks — controls (definite, expect same performance)

    elm-bench -f DecodeItemPure.dec_def_array_current -f DecodeItemPure.dec_def_array_ip "()"
    elm-bench -f DecodeItemPure.dec_def_map_current -f DecodeItemPure.dec_def_map_ip "()"
    elm-bench -f DecodeItemPure.dec_record_10_current -f DecodeItemPure.dec_record_10_ip "()"
    elm-bench -f DecodeItemPure.dec_opt_record_current -f DecodeItemPure.dec_opt_record_ip "()"
    elm-bench -f DecodeItemPure.dec_keyed_10_current -f DecodeItemPure.dec_keyed_10_ip "()"
    elm-bench -f DecodeItemPure.dec_item_current -f DecodeItemPure.dec_item_ip "()"

@docs dec_def_array_current, dec_def_array_ip
@docs dec_def_map_current, dec_def_map_ip
@docs dec_record_10_current, dec_record_10_ip
@docs dec_keyed_10_current, dec_keyed_10_ip
@docs dec_item_current, dec_item_ip

-}

import Bitwise
import Bytes
import Bytes.Decoder as BD
import Bytes.Encode as BE
import Cbor exposing (CborItem(..), FloatWidth(..), IntWidth(..), Length(..), Sign(..), SimpleWidth(..), Tag(..), tagToInt)
import Cbor.Decode as CD exposing (DecodeError(..))
import Cbor.Encode as CE



-- ============================================================================
-- TYPE
-- ============================================================================


{-| Opaque CBOR decoder. `Item` receives a pre-read initial byte.
`Pure` consumes no bytes (used by `succeed`, `fail`).
-}
type CborDecoder ctx a
    = Item (Int -> BD.Decoder ctx DecodeError a)
    | Pure (BD.Decoder ctx DecodeError a)


{-| Convert to a `BD.Decoder`. `Item` reads `u8` first; `Pure` passes through.
-}
toBD : CborDecoder ctx a -> BD.Decoder ctx DecodeError a
toBD decoder =
    case decoder of
        Item body ->
            u8 |> BD.andThen body

        Pure bd ->
            bd


{-| Wrap a raw `BD.Decoder` as `Pure` (no initial byte convention).
-}
fromBD : BD.Decoder ctx DecodeError a -> CborDecoder ctx a
fromBD bd =
    Pure bd



-- ============================================================================
-- COMBINATORS
-- ============================================================================


succeed : a -> CborDecoder ctx a
succeed a =
    Pure (BD.succeed a)


fail : DecodeError -> CborDecoder ctx a
fail err =
    Pure (BD.fail err)


map : (a -> b) -> CborDecoder ctx a -> CborDecoder ctx b
map f decoder =
    case decoder of
        Item body ->
            Item (\ib -> body ib |> BD.map f)

        Pure bd ->
            Pure (bd |> BD.map f)


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


andThen : (a -> CborDecoder ctx b) -> CborDecoder ctx a -> CborDecoder ctx b
andThen f decoder =
    case decoder of
        Item body ->
            Item (\ib -> body ib |> BD.andThen (\a -> toBD (f a)))

        Pure bd ->
            Pure (bd |> BD.andThen (\a -> toBD (f a)))


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


loop : (state -> CborDecoder ctx (BD.Step state a)) -> state -> CborDecoder ctx a
loop f initialState =
    Pure (BD.loop (\s -> toBD (f s)) initialState)


{-| Deferred construction for recursive decoders. Always produces `Item`.
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



-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================


u8 : BD.Decoder ctx err Int
u8 =
    BD.unsignedInt8


u16 : BD.Decoder ctx err Int
u16 =
    BD.unsignedInt16 Bytes.BE


u32 : BD.Decoder ctx err Int
u32 =
    BD.unsignedInt32 Bytes.BE


maxSafeInt : Int
maxSafeInt =
    4503599627370496


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
    BE.encode (BE.unsignedInt8 n)


intPairToBytes : Int -> Int -> Bytes.Bytes
intPairToBytes hi lo =
    BE.encode
        (BE.sequence
            [ BE.unsignedInt32 Bytes.BE hi
            , BE.unsignedInt32 Bytes.BE lo
            ]
        )


concatBytes : List Bytes.Bytes -> Bytes.Bytes
concatBytes chunks =
    BE.encode (BE.sequence (List.map BE.bytes chunks))


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



-- ============================================================================
-- PRIMITIVES
-- ============================================================================


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


null : a -> CborDecoder ctx a
null default =
    Item
        (\initialByte ->
            if initialByte == 0xF6 then
                BD.succeed default

            else
                BD.fail (WrongInitialByte { got = initialByte })
        )


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



-- ============================================================================
-- COLLECTIONS
-- ============================================================================


{-| Decode a CBOR array. For indefinite-length, the `Item` element body is
called directly after the break check — no `BD.oneOf`, stays on fast path.
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


{-| Decode a CBOR map as key-value pairs. Same indefinite-length optimization
as `array`: the key's initial byte is passed directly to the key body.
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


field : k -> CborDecoder ctx k -> CborDecoder ctx v -> CborDecoder ctx v
field expectedKey keyDecoder valueDecoder =
    andThen
        (\key ->
            if key == expectedKey then
                valueDecoder

            else
                fail KeyMismatch
        )
        keyDecoder


{-| Fold over map entries. The handler returns `BD.Decoder` (not `CborDecoder`)
so it can decode different value types per key using `toBD`.
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



-- ============================================================================
-- STRUCTURE HEADERS
-- ============================================================================


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



-- ============================================================================
-- RECORD BUILDER (CBOR arrays → Elm values)
-- ============================================================================


type RecordBuilder ctx a
    = SimpleBuilder Int (CborDecoder ctx a)
    | CountedBuilder (Int -> BD.Decoder ctx DecodeError ( Int, a ))


record : a -> RecordBuilder ctx a
record constructor =
    SimpleBuilder 0 (succeed constructor)


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



-- ============================================================================
-- KEYED RECORD BUILDER (CBOR maps → Elm values)
-- ============================================================================


type KeyedRecordBuilder ctx k a
    = KeyedRecordBuilder (CborDecoder ctx k) (Int -> BD.Decoder ctx DecodeError (KeyedState k a))


type alias KeyedState k a =
    { remaining : Int
    , pendingKey : Maybe k
    , value : a
    }


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


buildKeyedRecord : KeyedRecordBuilder ctx k a -> CborDecoder ctx a
buildKeyedRecord (KeyedRecordBuilder _ decoder) =
    andThen
        (\maybeN ->
            case maybeN of
                Just n ->
                    fromBD
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
        mapHeader



-- ============================================================================
-- ITEM (full CBOR parser)
-- ============================================================================


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
            withArgument additionalInfo
                (\tagNum ->
                    itemBD
                        |> BD.map (\enclosed -> CborTag (intToTag tagNum) enclosed)
                )

        7 ->
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



-- ============================================================================
-- SHARED TYPES FOR BENCHMARKS
-- ============================================================================


type alias OptR =
    { a : Int
    , b : Int
    , c : Int
    , d : Int
    , e : Int
    , f : Int
    , g : Int
    , h : Int
    , i : Int
    , j : Int
    }


type Certificate
    = Registration Int
    | Delegation Int Int


type alias R10 =
    { a : Int
    , b : Int
    , c : Int
    , d : Int
    , e : Int
    , f : Int
    , g : Int
    , h : Int
    , i : Int
    , j : Int
    }


type PlutusNested
    = PNConstr (List PlutusNested)
    | PNMap (List ( PlutusNested, PlutusNested ))
    | PNArray (List PlutusNested)
    | PNInt Int
    | PNBytes Bytes.Bytes



-- ============================================================================
-- SHARED DECODERS — CURRENT (CD)
-- ============================================================================


decodeCertCurrent : BD.Decoder ctx CD.DecodeError Certificate
decodeCertCurrent =
    CD.arrayHeader
        |> BD.andThen
            (\_ ->
                CD.int
                    |> BD.andThen
                        (\t ->
                            case t of
                                0 ->
                                    BD.map Registration CD.int

                                2 ->
                                    BD.map2 Delegation CD.int CD.int

                                _ ->
                                    BD.fail (WrongInitialByte { got = t })
                        )
            )


decodePlutusCurrent : BD.Decoder ctx CD.DecodeError PlutusNested
decodePlutusCurrent =
    let
        self : BD.Decoder ctx CD.DecodeError PlutusNested
        self =
            BD.andThen (\() -> decodePlutusCurrent) (BD.succeed ())
    in
    BD.oneOf
        [ CD.tag (Unknown 121) (CD.array self) |> BD.map PNConstr
        , CD.keyValue self self |> BD.map PNMap
        , CD.array self |> BD.map PNArray
        , CD.int |> BD.map PNInt
        , CD.bytes |> BD.map PNBytes
        ]


decR10Current : BD.Decoder ctx CD.DecodeError R10
decR10Current =
    CD.record R10
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.buildRecord


decKR10Current : BD.Decoder ctx CD.DecodeError R10
decKR10Current =
    CD.keyedRecord CD.int R10
        |> CD.required 0 CD.int
        |> CD.required 1 CD.int
        |> CD.required 2 CD.int
        |> CD.required 3 CD.int
        |> CD.required 4 CD.int
        |> CD.required 5 CD.int
        |> CD.required 6 CD.int
        |> CD.required 7 CD.int
        |> CD.required 8 CD.int
        |> CD.required 9 CD.int
        |> CD.buildKeyedRecord


decFoldCurrent : BD.Decoder ctx CD.DecodeError (List ( Int, Int ))
decFoldCurrent =
    CD.foldEntries CD.int
        (\key acc -> CD.int |> BD.map (\v -> ( key, v ) :: acc))
        []
        |> BD.map List.reverse



-- ============================================================================
-- SHARED DECODERS — ITEM/PURE (IP)
-- ============================================================================


decodeCertIP : CborDecoder ctx Certificate
decodeCertIP =
    arrayHeader
        |> andThen
            (\_ ->
                int
                    |> andThen
                        (\t ->
                            case t of
                                0 ->
                                    succeed Registration |> keep int

                                2 ->
                                    succeed Delegation |> keep int |> keep int

                                _ ->
                                    fail (WrongInitialByte { got = t })
                        )
            )


decodePlutusIP : CborDecoder ctx PlutusNested
decodePlutusIP =
    let
        self : CborDecoder ctx PlutusNested
        self =
            lazy (\() -> decodePlutusIP)
    in
    oneOf
        [ tag (Unknown 121) (array self) |> map PNConstr
        , keyValue self self |> map PNMap
        , array self |> map PNArray
        , int |> map PNInt
        , bytes |> map PNBytes
        ]


decR10IP : CborDecoder ctx R10
decR10IP =
    record R10
        |> element int
        |> element int
        |> element int
        |> element int
        |> element int
        |> element int
        |> element int
        |> element int
        |> element int
        |> element int
        |> buildRecord


decKR10IP : CborDecoder ctx R10
decKR10IP =
    keyedRecord int R10
        |> required 0 int
        |> required 1 int
        |> required 2 int
        |> required 3 int
        |> required 4 int
        |> required 5 int
        |> required 6 int
        |> required 7 int
        |> required 8 int
        |> required 9 int
        |> buildKeyedRecord


decFoldIP : CborDecoder ctx (List ( Int, Int ))
decFoldIP =
    let
        intBD =
            toBD int
    in
    foldEntries int
        (\key acc -> intBD |> BD.map (\v -> ( key, v ) :: acc))
        []
        |> map List.reverse


decOptRCurrent : BD.Decoder ctx CD.DecodeError OptR
decOptRCurrent =
    CD.record OptR
        |> CD.optionalElement CD.int 0
        |> CD.optionalElement CD.int 0
        |> CD.optionalElement CD.int 0
        |> CD.optionalElement CD.int 0
        |> CD.optionalElement CD.int 0
        |> CD.optionalElement CD.int 0
        |> CD.optionalElement CD.int 0
        |> CD.optionalElement CD.int 0
        |> CD.optionalElement CD.int 0
        |> CD.optionalElement CD.int 0
        |> CD.buildRecord


decOptRIP : CborDecoder ctx OptR
decOptRIP =
    record OptR
        |> optionalElement int 0
        |> optionalElement int 0
        |> optionalElement int 0
        |> optionalElement int 0
        |> optionalElement int 0
        |> optionalElement int 0
        |> optionalElement int 0
        |> optionalElement int 0
        |> optionalElement int 0
        |> optionalElement int 0
        |> buildRecord



-- ============================================================================
-- TEST DATA
-- ============================================================================


cborIntBE : Int -> BE.Encoder
cborIntBE i =
    if i <= 23 then
        BE.unsignedInt8 i

    else if i <= 255 then
        BE.unsignedInt16 Bytes.BE (Bitwise.or 0x1800 i)

    else
        BE.sequence
            [ BE.unsignedInt8 0x19
            , BE.unsignedInt16 Bytes.BE i
            ]


defIntArray100 : Bytes.Bytes
defIntArray100 =
    CE.encode CE.unsorted (CE.list CE.int (List.range 0 99))


indefIntArray100 : Bytes.Bytes
indefIntArray100 =
    BE.encode
        (BE.sequence
            (BE.unsignedInt8 0x9F
                :: List.map cborIntBE (List.range 0 99)
                ++ [ BE.unsignedInt8 0xFF ]
            )
        )


defIntMap100 : Bytes.Bytes
defIntMap100 =
    CE.encode CE.unsorted
        (CE.map
            (List.map (\i -> ( CE.int i, CE.int (i * 7 + 3) ))
                (List.range 0 99)
            )
        )


indefIntMap100 : Bytes.Bytes
indefIntMap100 =
    BE.encode
        (BE.sequence
            (BE.unsignedInt8 0xBF
                :: List.concatMap
                    (\i -> [ cborIntBE i, cborIntBE (i * 7 + 3) ])
                    (List.range 0 99)
                ++ [ BE.unsignedInt8 0xFF ]
            )
        )


encodeCertBytes : Int -> Bytes.Bytes
encodeCertBytes i =
    if modBy 2 i == 0 then
        CE.encode CE.unsorted (CE.list CE.int [ 0, i ])

    else
        CE.encode CE.unsorted (CE.list CE.int [ 2, i, i * 7 ])


indefCert20Data : Bytes.Bytes
indefCert20Data =
    BE.encode
        (BE.sequence
            (BE.unsignedInt8 0x9F
                :: List.map (\i -> BE.bytes (encodeCertBytes i)) (List.range 0 19)
                ++ [ BE.unsignedInt8 0xFF ]
            )
        )


makeIndefNested : Int -> Bytes.Bytes
makeIndefNested depth =
    if depth <= 0 then
        CE.encode CE.unsorted (CE.int 42)

    else
        let
            inner : Bytes.Bytes
            inner =
                makeIndefNested (depth - 1)
        in
        BE.encode
            (BE.sequence
                [ BE.unsignedInt8 0x9F
                , BE.bytes inner
                , BE.unsignedInt8 0xFF
                ]
            )


plutusIndefData5 : Bytes.Bytes
plutusIndefData5 =
    makeIndefNested 5


record10Data : Bytes.Bytes
record10Data =
    CE.encode CE.deterministic (CE.list CE.int (List.range 1 10))


keyedRecord10Data : Bytes.Bytes
keyedRecord10Data =
    CE.encode CE.deterministic
        (CE.map (List.map (\i -> ( CE.int i, CE.int (i * 7) )) (List.range 0 9)))


indefFold10Data : Bytes.Bytes
indefFold10Data =
    BE.encode
        (BE.sequence
            (BE.unsignedInt8 0xBF
                :: List.concatMap
                    (\i -> [ cborIntBE i, cborIntBE (i * 3) ])
                    (List.range 0 9)
                ++ [ BE.unsignedInt8 0xFF ]
            )
        )


indefNestedArraysData : Bytes.Bytes
indefNestedArraysData =
    BE.encode
        (BE.sequence
            (BE.unsignedInt8 0x9F
                :: List.map
                    (\i ->
                        BE.bytes
                            (CE.encode CE.unsorted
                                (CE.list CE.int (List.range (i * 10) (i * 10 + 9)))
                            )
                    )
                    (List.range 0 9)
                ++ [ BE.unsignedInt8 0xFF ]
            )
        )


itemTestData : Bytes.Bytes
itemTestData =
    CE.encode CE.unsorted
        (CE.tag (Unknown 121)
            (CE.list identity
                [ CE.int 42
                , CE.string "hello world"
                , CE.list CE.int [ 1, 2, 3, 4, 5 ]
                , CE.map
                    [ ( CE.int 0, CE.bool True )
                    , ( CE.int 1, CE.string "test" )
                    , ( CE.int 2, CE.list CE.int [ 10, 20, 30 ] )
                    ]
                ]
            )
        )



-- ============================================================================
-- BENCHMARKS — INDEFINITE COLLECTIONS (expect ~3x improvement)
-- ============================================================================


dec_indef_array_current : () -> Maybe (List Int)
dec_indef_array_current () =
    BD.decode (CD.array CD.int) indefIntArray100 |> Result.toMaybe


dec_indef_array_ip : () -> Maybe (List Int)
dec_indef_array_ip () =
    BD.decode (toBD (array int)) indefIntArray100 |> Result.toMaybe


dec_indef_map_current : () -> Maybe (List ( Int, Int ))
dec_indef_map_current () =
    BD.decode (CD.keyValue CD.int CD.int) indefIntMap100 |> Result.toMaybe


dec_indef_map_ip : () -> Maybe (List ( Int, Int ))
dec_indef_map_ip () =
    BD.decode (toBD (keyValue int int)) indefIntMap100 |> Result.toMaybe


dec_indef_fold_current : () -> Maybe (List ( Int, Int ))
dec_indef_fold_current () =
    BD.decode decFoldCurrent indefFold10Data |> Result.toMaybe


dec_indef_fold_ip : () -> Maybe (List ( Int, Int ))
dec_indef_fold_ip () =
    BD.decode (toBD decFoldIP) indefFold10Data |> Result.toMaybe


dec_indef_nested_current : () -> Maybe (List (List Int))
dec_indef_nested_current () =
    BD.decode (CD.array (CD.array CD.int)) indefNestedArraysData |> Result.toMaybe


dec_indef_nested_ip : () -> Maybe (List (List Int))
dec_indef_nested_ip () =
    BD.decode (toBD (array (array int))) indefNestedArraysData |> Result.toMaybe



-- ============================================================================
-- BENCHMARKS — CARDANO PATTERNS WITH INDEFINITE OUTER
-- ============================================================================


dec_indef_cert_current : () -> Maybe (List Certificate)
dec_indef_cert_current () =
    BD.decode (CD.array decodeCertCurrent) indefCert20Data |> Result.toMaybe


dec_indef_cert_ip : () -> Maybe (List Certificate)
dec_indef_cert_ip () =
    BD.decode (toBD (array decodeCertIP)) indefCert20Data |> Result.toMaybe


dec_plutus_indef_5_current : () -> Maybe PlutusNested
dec_plutus_indef_5_current () =
    BD.decode decodePlutusCurrent plutusIndefData5 |> Result.toMaybe


dec_plutus_indef_5_ip : () -> Maybe PlutusNested
dec_plutus_indef_5_ip () =
    BD.decode (toBD decodePlutusIP) plutusIndefData5 |> Result.toMaybe



-- ============================================================================
-- BENCHMARKS — CONTROLS (definite, expect same performance)
-- ============================================================================


dec_def_array_current : () -> Maybe (List Int)
dec_def_array_current () =
    BD.decode (CD.array CD.int) defIntArray100 |> Result.toMaybe


dec_def_array_ip : () -> Maybe (List Int)
dec_def_array_ip () =
    BD.decode (toBD (array int)) defIntArray100 |> Result.toMaybe


dec_def_map_current : () -> Maybe (List ( Int, Int ))
dec_def_map_current () =
    BD.decode (CD.keyValue CD.int CD.int) defIntMap100 |> Result.toMaybe


dec_def_map_ip : () -> Maybe (List ( Int, Int ))
dec_def_map_ip () =
    BD.decode (toBD (keyValue int int)) defIntMap100 |> Result.toMaybe


dec_record_10_current : () -> Maybe R10
dec_record_10_current () =
    BD.decode decR10Current record10Data |> Result.toMaybe


dec_record_10_ip : () -> Maybe R10
dec_record_10_ip () =
    BD.decode (toBD decR10IP) record10Data |> Result.toMaybe


dec_keyed_10_current : () -> Maybe R10
dec_keyed_10_current () =
    BD.decode decKR10Current keyedRecord10Data |> Result.toMaybe


dec_keyed_10_ip : () -> Maybe R10
dec_keyed_10_ip () =
    BD.decode (toBD decKR10IP) keyedRecord10Data |> Result.toMaybe


dec_item_current : () -> Maybe CborItem
dec_item_current () =
    BD.decode CD.item itemTestData |> Result.toMaybe


dec_item_ip : () -> Maybe CborItem
dec_item_ip () =
    BD.decode (toBD item) itemTestData |> Result.toMaybe


dec_opt_record_current : () -> Maybe OptR
dec_opt_record_current () =
    BD.decode decOptRCurrent record10Data |> Result.toMaybe


dec_opt_record_ip : () -> Maybe OptR
dec_opt_record_ip () =
    BD.decode (toBD decOptRIP) record10Data |> Result.toMaybe
