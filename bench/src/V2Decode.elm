module V2Decode exposing
    ( intV2
    , stringV2
    , itemV2
    )

{-| Alternative decoder implementations for benchmarking against Cbor.Decode.


# Opportunity #2: safeArgument — fused argument + overflow check

Merges the overflow check into `decodeArgument`. For inline values (<=23)
and u8/u16/u32, the overflow check is skipped entirely. Only the 64-bit
path retains the check. This eliminates one `andThen` from the fast path.

@docs intV2


# Opportunity #1: withArgument — fused argument + continuation

For inline arguments (<=23), calls the continuation directly instead of
building `BD.succeed additionalInfo |> BD.andThen f`. Saves one closure
and one `Decode.andThen` composition per inline decode.

@docs stringV2


# Opportunities #1 + #3: withArgument + BD.repeat in item

Combines `withArgument` fusion across all major types with `BD.repeat`
(optimized kernel path) for definite-length arrays and maps, replacing
manual `BD.loop` with tuple state.

@docs itemV2

-}

import Bitwise
import Bytes
import Bytes.Decoder as BD
import Bytes.Encode
import Cbor exposing (CborItem(..), FloatWidth(..), IntWidth(..), Length(..), Sign(..), SimpleWidth(..), Tag(..))
import Cbor.Decode exposing (DecodeError(..))



-- ============================================================================
-- INTERNAL HELPERS (copied from Cbor.Decode — not exposed)
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


intPairToBytes : Int -> Int -> Bytes.Bytes
intPairToBytes hi lo =
    Bytes.Encode.encode
        (Bytes.Encode.sequence
            [ Bytes.Encode.unsignedInt32 Bytes.BE hi
            , Bytes.Encode.unsignedInt32 Bytes.BE lo
            ]
        )


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



-- ============================================================================
-- OPPORTUNITY #2: safeArgument
-- ============================================================================


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



-- ============================================================================
-- OPPORTUNITY #1: withArgument
-- ============================================================================


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



-- ============================================================================
-- V2 INT DECODER (opportunity #2)
-- ============================================================================


{-| V2 int decoder using `safeArgument`.

Current `int` has two `andThen` levels: one for `decodeArgument`, one for
the overflow check. This version merges them via `safeArgument`, leaving
a single `andThen` (the outer one for the initial byte).

-}
intV2 : BD.Decoder ctx DecodeError Int
intV2 =
    u8
        |> BD.andThen
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



-- ============================================================================
-- V2 STRING DECODER (opportunity #1)
-- ============================================================================


{-| V2 string decoder using `withArgument`.

For definite-length strings with length <=23 (common case), calls
`BD.string len` directly instead of `BD.succeed len |> BD.andThen (...)`.

-}
stringV2 : BD.Decoder ctx DecodeError String
stringV2 =
    u8
        |> BD.andThen
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



-- ============================================================================
-- V2 ITEM DECODER (opportunities #1 + #3)
-- ============================================================================


{-| V2 item decoder using `withArgument` + `BD.repeat`.

Changes from V1:

  - Major types 2, 3: `withArgument` for definite-length (opportunity #1)
  - Major type 4 definite: `withArgument` + `BD.repeat` (opportunities #1 + #3)
  - Major type 5 definite: `withArgument` + `BD.repeat` (opportunities #1 + #3)
  - Major type 6: `withArgument` (opportunity #1)
  - Major types 0, 1, 7: unchanged

-}
itemV2 : BD.Decoder ctx DecodeError CborItem
itemV2 =
    u8
        |> BD.andThen decodeItemBodyV2


decodeItemBodyV2 : Int -> BD.Decoder ctx DecodeError CborItem
decodeItemBodyV2 initialByte =
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
            -- Unsigned integer (unchanged)
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
            -- Negative integer (unchanged)
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
            -- Byte string — withArgument (#1)
            if additionalInfo == 31 then
                BD.loop
                    (\chunks ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborByteStringChunked (List.reverse chunks)))

                                    else
                                        withArgument (Bitwise.and 0x1F byte) (\len -> BD.bytes len)
                                            |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                                )
                    )
                    []

            else
                withArgument additionalInfo (\len -> BD.bytes len)
                    |> BD.map CborByteString

        3 ->
            -- Text string — withArgument (#1)
            if additionalInfo == 31 then
                BD.loop
                    (\chunks ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborStringChunked (List.reverse chunks)))

                                    else
                                        withArgument (Bitwise.and 0x1F byte) (\len -> BD.string len)
                                            |> BD.map (\chunk -> BD.Loop (chunk :: chunks))
                                )
                    )
                    []

            else
                withArgument additionalInfo (\len -> BD.string len)
                    |> BD.map CborString

        4 ->
            -- Array — withArgument (#1) + BD.repeat (#3)
            if additionalInfo == 31 then
                BD.loop
                    (\items ->
                        u8
                            |> BD.andThen
                                (\byte ->
                                    if byte == 0xFF then
                                        BD.succeed (BD.Done (CborArray Indefinite (List.reverse items)))

                                    else
                                        decodeItemBodyV2 byte
                                            |> BD.map (\v -> BD.Loop (v :: items))
                                )
                    )
                    []

            else
                withArgument additionalInfo
                    (\count ->
                        BD.repeat itemV2 count
                            |> BD.map (\items -> CborArray Definite items)
                    )

        5 ->
            -- Map — withArgument (#1) + BD.repeat (#3)
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
                                            (decodeItemBodyV2 byte)
                                            itemV2
                                )
                    )
                    []

            else
                withArgument additionalInfo
                    (\count ->
                        BD.repeat (BD.map2 (\k v -> { key = k, value = v }) itemV2 itemV2) count
                            |> BD.map (\entries -> CborMap Definite entries)
                    )

        6 ->
            -- Tag — withArgument (#1)
            withArgument additionalInfo
                (\tagNum ->
                    itemV2
                        |> BD.map (\enclosed -> CborTag (intToTag tagNum) enclosed)
                )

        7 ->
            -- Simple values and floats (unchanged)
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
