module DecodeBody exposing
    ( CborDecoder
    , andThen
    , array
    , bool
    , bytes
    , dec_def_array_body
    , dec_def_array_current
    , dec_indef_array_body
    , dec_indef_array_current
    , dec_indef_map_body
    , dec_indef_map_current
    , float
    , int
    , item
    , keyValue
    , map
    , map2
    , null
    , oneOf
    , string
    , tag
    , toBD
    )

{-| Body decoder prototype: every `CborDecoder` receives its initial byte
pre-read, enabling fast-path indefinite-length decoding.


# The Problem

In the current `Cbor.Decode`, indefinite-length `array` and `keyValue` use
`BD.oneOf [ breakCode, elementDecoder ]` to detect the break byte. But
`BD.oneOf` has **no fast path** — it forces the entire loop onto the slow
state-passing path. Meanwhile, `decodeItemBody` already uses the efficient
pattern: read `u8`, branch on `0xFF`, and pass the byte to the body decoder.

The body decoder approach lifts this pattern to the type level.


# The Solution

    type CborDecoder ctx a
        = CborDecoder (Int -> BD.Decoder ctx DecodeError a)

Every CBOR decoder is a function from initial byte to body decoder. The
initial byte read (`u8`) is handled at composition boundaries:

  - **`toBD`**: wraps with `u8 |> BD.andThen body`
  - **`array` indefinite**: reads `u8`, checks for `0xFF` break, passes byte
    directly to element body — no `oneOf`, stays on fast path
  - **`array` definite**: `BD.repeat (u8 |> BD.andThen body) count`
  - **`map2`**: first decoder uses shared initial byte, second reads its own
  - **`oneOf`**: all branches share the same initial byte


# API Implications

Users cannot use `Bytes.Decoder` combinators (`BD.map`, `BD.andThen`, etc.)
directly on `CborDecoder` values. The module provides its own:

  - `map`, `map2` — pure value transformations
  - `andThen` — sequential CBOR items (reads new initial byte for continuation)
  - `oneOf` — dispatch on initial byte (all branches share it)

`succeed` and `fail` are intentionally omitted: they don't consume a CBOR
item, but `CborDecoder` semantics assume the initial byte has been consumed.
For pure value injection, use `map`. For error reporting, use `BD.fail`
inside the body function.


# Benchmarks

```sh
elm-bench -f DecodeBody.dec_def_array_current -f DecodeBody.dec_def_array_body -f DecodeBody.dec_indef_array_current -f DecodeBody.dec_indef_array_body "()"
elm-bench -f DecodeBody.dec_indef_map_current -f DecodeBody.dec_indef_map_body "()"
```

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


{-| An opaque CBOR decoder. Internally wraps a function from initial byte
to `BD.Decoder`. The initial byte is consumed by the caller; the body
function decodes everything after it.
-}
type CborDecoder ctx a
    = CborDecoder (Int -> BD.Decoder ctx DecodeError a)



-- ============================================================================
-- RUNNING
-- ============================================================================


{-| Convert to a `BD.Decoder` that reads the initial byte then the body.
-}
toBD : CborDecoder ctx a -> BD.Decoder ctx DecodeError a
toBD (CborDecoder body) =
    u8 |> BD.andThen body



-- ============================================================================
-- COMBINATORS
-- ============================================================================


{-| Transform the decoded value.
-}
map : (a -> b) -> CborDecoder ctx a -> CborDecoder ctx b
map f (CborDecoder body) =
    CborDecoder (\ib -> body ib |> BD.map f)


{-| Decode two sequential CBOR items and combine them.

The first decoder uses the shared initial byte. The second reads
its own initial byte.

-}
map2 : (a -> b -> c) -> CborDecoder ctx a -> CborDecoder ctx b -> CborDecoder ctx c
map2 f (CborDecoder bodyA) (CborDecoder bodyB) =
    CborDecoder
        (\ib ->
            BD.map2 f
                (bodyA ib)
                (u8 |> BD.andThen bodyB)
        )


{-| Decode a CBOR item, then use its value to choose the next decoder.

The continuation returns a `CborDecoder` for the next CBOR item, which
reads its own initial byte. For pure value transformations, use `map`.

-}
andThen : (a -> CborDecoder ctx b) -> CborDecoder ctx a -> CborDecoder ctx b
andThen f (CborDecoder bodyA) =
    CborDecoder
        (\ib ->
            bodyA ib
                |> BD.andThen
                    (\a ->
                        let
                            (CborDecoder bodyB) =
                                f a
                        in
                        u8 |> BD.andThen bodyB
                    )
        )


{-| Try each decoder in order, sharing the initial byte.

Unlike `BD.oneOf` (which re-reads the initial byte for each branch
via backtracking), all branches receive the same pre-read byte. The
`BD.oneOf` is only used for body-level backtracking.

-}
oneOf : List (CborDecoder ctx a) -> CborDecoder ctx a
oneOf decoders =
    CborDecoder
        (\initialByte ->
            BD.oneOf (List.map (\(CborDecoder body) -> body initialByte) decoders)
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



-- ============================================================================
-- PRIMITIVES
-- ============================================================================


{-| Decode a CBOR integer (major types 0 and 1).
-}
int : CborDecoder ctx Int
int =
    CborDecoder
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


{-| Decode a CBOR text string (major type 3).
-}
string : CborDecoder ctx String
string =
    CborDecoder
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
-}
bytes : CborDecoder ctx Bytes.Bytes
bytes =
    CborDecoder
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


{-| Decode a CBOR boolean (0xF4 / 0xF5).
-}
bool : CborDecoder ctx Bool
bool =
    CborDecoder
        (\initialByte ->
            if initialByte == 0xF4 then
                BD.succeed False

            else if initialByte == 0xF5 then
                BD.succeed True

            else
                BD.fail (WrongInitialByte { got = initialByte })
        )


{-| Decode a CBOR float (major type 7, additional info 25/26/27).
-}
float : CborDecoder ctx Float
float =
    CborDecoder
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


{-| Decode a CBOR null (0xF6), returning the given default value.
-}
null : a -> CborDecoder ctx a
null default =
    CborDecoder
        (\initialByte ->
            if initialByte == 0xF6 then
                BD.succeed default

            else
                BD.fail (WrongInitialByte { got = initialByte })
        )



-- ============================================================================
-- COLLECTIONS
-- ============================================================================


{-| Decode a CBOR array (major type 4).

**Key optimization**: for indefinite-length arrays, reads the byte once
and passes it directly to the element body — no `BD.oneOf`, stays on
the fast `Decode.loop` kernel path.

-}
array : CborDecoder ctx a -> CborDecoder ctx (List a)
array (CborDecoder elementBody) =
    CborDecoder
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
                -- INDEFINITE: read byte, check break, dispatch to body
                -- This stays on the fast path (no BD.oneOf)
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
                -- DEFINITE: same as current, using BD.repeat
                withArgument additionalInfo
                    (\count ->
                        BD.repeat (u8 |> BD.andThen elementBody) count
                    )
        )


{-| Decode a CBOR map (major type 5) as key-value pairs.

Same indefinite-length optimization as `array`: the key's initial byte
is read once and passed directly to the key body.

-}
keyValue : CborDecoder ctx k -> CborDecoder ctx v -> CborDecoder ctx (List ( k, v ))
keyValue (CborDecoder keyBody) (CborDecoder valueBody) =
    CborDecoder
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
                                            (u8 |> BD.andThen valueBody)
                                )
                    )
                    []

            else
                withArgument additionalInfo
                    (\count ->
                        BD.repeat
                            (BD.map2 Tuple.pair
                                (u8 |> BD.andThen keyBody)
                                (u8 |> BD.andThen valueBody)
                            )
                            count
                    )
        )


{-| Decode a tagged CBOR value (major type 6).
-}
tag : Tag -> CborDecoder ctx a -> CborDecoder ctx a
tag expectedTag (CborDecoder innerBody) =
    CborDecoder
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
                            u8 |> BD.andThen innerBody

                        else
                            BD.fail (WrongTag { expected = tagToInt expectedTag, got = tagNum })
                    )
        )



-- ============================================================================
-- ITEM (ESCAPE HATCH)
-- ============================================================================


{-| Decode any well-formed CBOR data item into a `CborItem`.
-}
item : CborDecoder ctx CborItem
item =
    CborDecoder itemBody


{-| Pre-composed `BD.Decoder` for a full item (initial byte + body).
Used internally by `itemBody` for recursive calls.
-}
itemDecoder : BD.Decoder ctx DecodeError CborItem
itemDecoder =
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
                        BD.repeat itemDecoder count
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
                                            itemDecoder
                                )
                    )
                    []

            else
                withArgument additionalInfo
                    (\count ->
                        BD.repeat
                            (BD.map2 (\k v -> { key = k, value = v }) itemDecoder itemDecoder)
                            count
                            |> BD.map (\entries -> CborMap Definite entries)
                    )

        6 ->
            -- Tag
            withArgument additionalInfo
                (\tagNum ->
                    itemDecoder
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



-- ============================================================================
-- TEST DATA
-- ============================================================================


{-| Encode an integer as a CBOR unsigned int (major type 0) using Bytes.Encode.
-}
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


{-| Definite-length array of 100 ints (0–99).
Header: 0x98 0x64 (major type 4, AI=24, count=100).
-}
defIntArray100 : Bytes.Bytes
defIntArray100 =
    CE.encode CE.unsorted (CE.list CE.int (List.range 0 99))


{-| Indefinite-length array of 100 ints (0–99).
Header: 0x9F, items, 0xFF.
-}
indefIntArray100 : Bytes.Bytes
indefIntArray100 =
    BE.encode
        (BE.sequence
            (BE.unsignedInt8 0x9F
                :: List.map cborIntBE (List.range 0 99)
                ++ [ BE.unsignedInt8 0xFF ]
            )
        )


{-| Indefinite-length map of 100 int→int entries.
Keys: 0–99, values: i\*7+3. Header: 0xBF, pairs, 0xFF.
-}
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



-- ============================================================================
-- BENCHMARKS
-- ============================================================================


{-| Current: definite-length array of 100 ints.
Uses `BD.repeat` — already fast path. Control benchmark.
-}
dec_def_array_current : () -> Maybe (List Int)
dec_def_array_current () =
    BD.decode (CD.array CD.int) defIntArray100 |> Result.toMaybe


{-| Body decoder: definite-length array of 100 ints.
Also uses `BD.repeat` — should match current performance.
-}
dec_def_array_body : () -> Maybe (List Int)
dec_def_array_body () =
    BD.decode (toBD (array int)) defIntArray100 |> Result.toMaybe


{-| Current: indefinite-length array of 100 ints.
Uses `BD.oneOf` — **no fast path**, entire loop on slow path.
-}
dec_indef_array_current : () -> Maybe (List Int)
dec_indef_array_current () =
    BD.decode (CD.array CD.int) indefIntArray100 |> Result.toMaybe


{-| Body decoder: indefinite-length array of 100 ints.
Uses `u8 |> BD.andThen` with break check — stays on fast path.
-}
dec_indef_array_body : () -> Maybe (List Int)
dec_indef_array_body () =
    BD.decode (toBD (array int)) indefIntArray100 |> Result.toMaybe


{-| Current: indefinite-length map of 100 int→int entries.
Uses `BD.oneOf` — no fast path.
-}
dec_indef_map_current : () -> Maybe (List ( Int, Int ))
dec_indef_map_current () =
    BD.decode (CD.keyValue CD.int CD.int) indefIntMap100 |> Result.toMaybe


{-| Body decoder: indefinite-length map of 100 int→int entries.
Uses `u8 |> BD.andThen` with break check — stays on fast path.
-}
dec_indef_map_body : () -> Maybe (List ( Int, Int ))
dec_indef_map_body () =
    BD.decode (toBD (keyValue int int)) indefIntMap100 |> Result.toMaybe
