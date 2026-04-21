module VsToulouse exposing
    ( enc_ec_list100, enc_tl_list100
    , enc_ec_map100, enc_tl_map100
    , enc_ec_float1000, enc_tl_float1000
    , enc_ec_tuple10, enc_tl_tuple10
    , enc_ec_keyed10, enc_tl_keyed10
    , enc_ec_nested100, enc_tl_nested100
    , enc_ec_list100_mixed, enc_tl_list100_mixed
    , enc_ec_map100_mixed, enc_tl_map100_mixed
    , dec_ec_array100, dec_tl_array100
    , dec_ec_map100, dec_tl_map100
    , dec_ec_record10, dec_tl_record10
    , dec_ec_keyed10, dec_tl_keyed10
    )

{-| Head-to-head benchmarks: elm-cardano/cbor (`ec`) vs elm-toulouse/cbor (`tl`).

Uses [elm-bench](https://github.com/elm-menagerie/elm-bench).


# Encode array of 100 ints

```sh
elm-bench -f VsToulouse.enc_ec_list100 -f VsToulouse.enc_tl_list100 "()"
```

@docs enc_ec_list100, enc_tl_list100


# Encode map of 100 int→int pairs

```sh
elm-bench -f VsToulouse.enc_ec_map100 -f VsToulouse.enc_tl_map100 "()"
```

@docs enc_ec_map100, enc_tl_map100


# Encode 1000 floats (float64)

Both use explicit float64. Fair apples-to-apples comparison of the encode path.

```sh
elm-bench -f VsToulouse.enc_ec_float1000 -f VsToulouse.enc_tl_float1000 "()"
```

@docs enc_ec_float1000, enc_tl_float1000


# Encode 10-field record as CBOR array (tuple)

elm-cardano uses `CE.array`; elm-toulouse uses `TE.tuple` builder with field accessors.
Includes both encoder construction and serialization.

```sh
elm-bench -f VsToulouse.enc_ec_tuple10 -f VsToulouse.enc_tl_tuple10 "()"
```

@docs enc_ec_tuple10, enc_tl_tuple10


# Encode 10-field keyed record as CBOR map

elm-cardano uses `CE.keyedRecord`; elm-toulouse uses `TE.record` builder.
Includes both encoder construction and serialization.

```sh
elm-bench -f VsToulouse.enc_ec_keyed10 -f VsToulouse.enc_tl_keyed10 "()"
```

@docs enc_ec_keyed10, enc_tl_keyed10


# Encode 100 nested records (list of 3-field tuples)

Amplifies per-element overhead: each of the 100 elements goes through
the tuple/array builder.

```sh
elm-bench -f VsToulouse.enc_ec_nested100 -f VsToulouse.enc_tl_nested100 "()"
```

@docs enc_ec_nested100, enc_tl_nested100


# Encode list of 100 wrapped ints

Each element is a 1-element CBOR array wrapping an int.

```sh
elm-bench -f VsToulouse.enc_ec_list100_mixed -f VsToulouse.enc_tl_list100_mixed "()"
```

@docs enc_ec_list100_mixed, enc_tl_list100_mixed


# Encode map of 100 wrapped int pairs

Each value is a 1-element CBOR array wrapping an int.

```sh
elm-bench -f VsToulouse.enc_ec_map100_mixed -f VsToulouse.enc_tl_map100_mixed "()"
```

@docs enc_ec_map100_mixed, enc_tl_map100_mixed


# Decode array of 100 ints

```sh
elm-bench -f VsToulouse.dec_ec_array100 -f VsToulouse.dec_tl_array100 "()"
```

@docs dec_ec_array100, dec_tl_array100


# Decode map of 100 int→int pairs

```sh
elm-bench -f VsToulouse.dec_ec_map100 -f VsToulouse.dec_tl_map100 "()"
```

@docs dec_ec_map100, dec_tl_map100


# Decode 10-field record from CBOR array

elm-cardano uses `CD.record` builder; elm-toulouse uses `TD.tuple` builder.

```sh
elm-bench -f VsToulouse.dec_ec_record10 -f VsToulouse.dec_tl_record10 "()"
```

@docs dec_ec_record10, dec_tl_record10


# Decode 10-field keyed record from CBOR map

elm-cardano uses `CD.keyedRecord` builder; elm-toulouse uses `TD.record` builder.

```sh
elm-bench -f VsToulouse.dec_ec_keyed10 -f VsToulouse.dec_tl_keyed10 "()"
```

@docs dec_ec_keyed10, dec_tl_keyed10

-}

import Bytes exposing (Bytes)
import Cbor exposing (FloatWidth(..), Length(..))
import Cbor.Decode as CD
import Cbor.Encode as CE
import Toulouse.Cbor.Decode as TD
import Toulouse.Cbor.Encode as TE



-- ============================================================================
-- SHARED TYPES
-- ============================================================================


type alias R3 =
    { a : Int, b : Int, c : Int }


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



-- ============================================================================
-- TEST DATA
-- ============================================================================


intRange100 : List Int
intRange100 =
    List.range 0 99


intPairs100 : List ( Int, Int )
intPairs100 =
    List.map (\i -> ( i, i * 7 + 3 )) (List.range 0 99)


float64Values : List Float
float64Values =
    List.map (\i -> pi * toFloat (i + 1)) (List.range 0 999)


intRange100Mixed : List (List Int)
intRange100Mixed =
    List.map (\i -> [ i ]) intRange100


intPairs100Mixed : List ( Int, List Int )
intPairs100Mixed =
    List.map (\( i, v ) -> ( i, [ v ] )) intPairs100


r10 : R10
r10 =
    { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9, j = 10 }


r3List : List R3
r3List =
    List.map (\i -> { a = i, b = i * 3, c = i * 7 }) (List.range 0 99)



-- ============================================================================
-- ENCODERS (functions accepting data, measuring construction + serialization)
-- ============================================================================


ecListEncoder : List Int -> CE.Encoder
ecListEncoder ints =
    CE.list Definite CE.int ints


tlListEncoder : List Int -> TE.Encoder
tlListEncoder =
    TE.list TE.int


ecMapEncoder : List ( Int, Int ) -> CE.Encoder
ecMapEncoder pairs =
    CE.map CE.Unsorted Definite (List.map (\( k, v ) -> ( CE.int k, CE.int v )) pairs)


tlMapEncoder : List ( Int, Int ) -> TE.Encoder
tlMapEncoder =
    TE.associativeList TE.int TE.int


ecFloatEncoder : List Float -> CE.Encoder
ecFloatEncoder floats =
    CE.list Definite (\f -> CE.floatWithWidth FW64 f) floats


tlFloatEncoder : List Float -> TE.Encoder
tlFloatEncoder =
    TE.list TE.float


ecListMixedEncoder : List (List Int) -> CE.Encoder
ecListMixedEncoder items =
    CE.list Definite (\vs -> CE.list Definite CE.int vs) items


tlListMixedEncoder : List (List Int) -> TE.Encoder
tlListMixedEncoder =
    TE.list (TE.list TE.int)


ecMapMixedEncoder : List ( Int, List Int ) -> CE.Encoder
ecMapMixedEncoder pairs =
    CE.map CE.Unsorted Definite (List.map (\( k, vs ) -> ( CE.int k, CE.list Definite CE.int vs )) pairs)


tlMapMixedEncoder : List ( Int, List Int ) -> TE.Encoder
tlMapMixedEncoder =
    TE.associativeList TE.int (TE.list TE.int)


ecTuple10Encoder : R10 -> CE.Encoder
ecTuple10Encoder r =
    CE.array Definite
        [ CE.int r.a
        , CE.int r.b
        , CE.int r.c
        , CE.int r.d
        , CE.int r.e
        , CE.int r.f
        , CE.int r.g
        , CE.int r.h
        , CE.int r.i
        , CE.int r.j
        ]


tlTuple10Encoder : R10 -> TE.Encoder
tlTuple10Encoder =
    TE.tuple <|
        TE.elems
            >> TE.elem TE.int .a
            >> TE.elem TE.int .b
            >> TE.elem TE.int .c
            >> TE.elem TE.int .d
            >> TE.elem TE.int .e
            >> TE.elem TE.int .f
            >> TE.elem TE.int .g
            >> TE.elem TE.int .h
            >> TE.elem TE.int .i
            >> TE.elem TE.int .j


ecKeyed10Encoder : R10 -> CE.Encoder
ecKeyed10Encoder r =
    CE.keyedRecord CE.Unsorted
        Definite
        CE.int
        [ ( 0, Just (CE.int r.a) )
        , ( 1, Just (CE.int r.b) )
        , ( 2, Just (CE.int r.c) )
        , ( 3, Just (CE.int r.d) )
        , ( 4, Just (CE.int r.e) )
        , ( 5, Just (CE.int r.f) )
        , ( 6, Just (CE.int r.g) )
        , ( 7, Just (CE.int r.h) )
        , ( 8, Just (CE.int r.i) )
        , ( 9, Just (CE.int r.j) )
        ]


tlKeyed10Encoder : R10 -> TE.Encoder
tlKeyed10Encoder =
    TE.record TE.int <|
        TE.fields
            >> TE.field 0 TE.int .a
            >> TE.field 1 TE.int .b
            >> TE.field 2 TE.int .c
            >> TE.field 3 TE.int .d
            >> TE.field 4 TE.int .e
            >> TE.field 5 TE.int .f
            >> TE.field 6 TE.int .g
            >> TE.field 7 TE.int .h
            >> TE.field 8 TE.int .i
            >> TE.field 9 TE.int .j


ecNested100Encoder : List R3 -> CE.Encoder
ecNested100Encoder rs =
    CE.list Definite (\r -> CE.array Definite [ CE.int r.a, CE.int r.b, CE.int r.c ]) rs


tlNested100Encoder : List R3 -> TE.Encoder
tlNested100Encoder =
    TE.list <|
        TE.tuple <|
            TE.elems
                >> TE.elem TE.int .a
                >> TE.elem TE.int .b
                >> TE.elem TE.int .c



-- Pre-encoded CBOR bytes (decode benchmarks)
-- Both libraries produce standard CBOR, so we encode once and both decode.


array100Data : Bytes
array100Data =
    CE.encode (ecListEncoder intRange100)


map100Data : Bytes
map100Data =
    CE.encode (ecMapEncoder intPairs100)


record10Data : Bytes
record10Data =
    CE.encode (CE.list Definite CE.int (List.range 1 10))


keyedRecord10Data : Bytes
keyedRecord10Data =
    CE.encode
        (CE.map CE.Unsorted Definite (List.map (\i -> ( CE.int i, CE.int (i * 7) )) (List.range 0 9)))



-- ============================================================================
-- SHARED DECODERS
-- ============================================================================


ecDecR10 : CD.CborDecoder ctx R10
ecDecR10 =
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
        |> CD.buildRecord CD.IgnoreExtra


tlDecR10 : TD.Decoder R10
tlDecR10 =
    TD.tuple R10 <|
        TD.elems
            >> TD.elem TD.int
            >> TD.elem TD.int
            >> TD.elem TD.int
            >> TD.elem TD.int
            >> TD.elem TD.int
            >> TD.elem TD.int
            >> TD.elem TD.int
            >> TD.elem TD.int
            >> TD.elem TD.int
            >> TD.elem TD.int


ecDecKR10 : CD.CborDecoder ctx R10
ecDecKR10 =
    CD.keyedRecord CD.int String.fromInt R10
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
        |> CD.buildKeyedRecord CD.IgnoreExtra


tlDecKR10 : TD.Decoder R10
tlDecKR10 =
    TD.record TD.int R10 <|
        TD.fields
            >> TD.field 0 TD.int
            >> TD.field 1 TD.int
            >> TD.field 2 TD.int
            >> TD.field 3 TD.int
            >> TD.field 4 TD.int
            >> TD.field 5 TD.int
            >> TD.field 6 TD.int
            >> TD.field 7 TD.int
            >> TD.field 8 TD.int
            >> TD.field 9 TD.int



-- ============================================================================
-- 1. ENCODE LIST OF 100 INTS
-- ============================================================================


enc_ec_list100 : () -> Bytes
enc_ec_list100 () =
    CE.encode (ecListEncoder intRange100)


enc_tl_list100 : () -> Bytes
enc_tl_list100 () =
    TE.encode (tlListEncoder intRange100)



-- ============================================================================
-- 2. ENCODE MAP OF 100 INT PAIRS
-- ============================================================================


enc_ec_map100 : () -> Bytes
enc_ec_map100 () =
    CE.encode (ecMapEncoder intPairs100)


enc_tl_map100 : () -> Bytes
enc_tl_map100 () =
    TE.encode (tlMapEncoder intPairs100)



-- ============================================================================
-- 3. ENCODE 1000 FLOATS
-- ============================================================================


enc_ec_float1000 : () -> Bytes
enc_ec_float1000 () =
    CE.encode (ecFloatEncoder float64Values)


enc_tl_float1000 : () -> Bytes
enc_tl_float1000 () =
    TE.encode (tlFloatEncoder float64Values)



-- ============================================================================
-- 4. ENCODE 10-FIELD RECORD AS CBOR ARRAY (TUPLE)
-- ============================================================================
-- elm-cardano: CE.array with explicit encoder list
-- elm-toulouse: TE.tuple builder with field accessors
-- Measures encoder construction + serialization together.


enc_ec_tuple10 : () -> Bytes
enc_ec_tuple10 () =
    CE.encode (ecTuple10Encoder r10)


enc_tl_tuple10 : () -> Bytes
enc_tl_tuple10 () =
    TE.encode (tlTuple10Encoder r10)



-- ============================================================================
-- 5. ENCODE 10-FIELD KEYED RECORD AS CBOR MAP
-- ============================================================================
-- elm-cardano: CE.keyedRecord with key encoder + list of (key, Maybe encoder)
-- elm-toulouse: TE.record builder with field accessors


enc_ec_keyed10 : () -> Bytes
enc_ec_keyed10 () =
    CE.encode (ecKeyed10Encoder r10)


enc_tl_keyed10 : () -> Bytes
enc_tl_keyed10 () =
    TE.encode (tlKeyed10Encoder r10)



-- ============================================================================
-- 6. ENCODE 100 NESTED RECORDS (LIST OF 3-FIELD TUPLES)
-- ============================================================================
-- Each element goes through the tuple/array builder, amplifying per-element overhead.


enc_ec_nested100 : () -> Bytes
enc_ec_nested100 () =
    CE.encode (ecNested100Encoder r3List)


enc_tl_nested100 : () -> Bytes
enc_tl_nested100 () =
    TE.encode (tlNested100Encoder r3List)



-- ============================================================================
-- 6b. ENCODE LIST OF 100 WRAPPED INTS
-- ============================================================================
-- Each element is CE.list Definite CE.int [i], a 1-element CBOR array wrapping an int.


enc_ec_list100_mixed : () -> Bytes
enc_ec_list100_mixed () =
    CE.encode (ecListMixedEncoder intRange100Mixed)


enc_tl_list100_mixed : () -> Bytes
enc_tl_list100_mixed () =
    TE.encode (tlListMixedEncoder intRange100Mixed)



-- ============================================================================
-- 6c. ENCODE MAP OF 100 WRAPPED INT PAIRS
-- ============================================================================
-- Each value is CE.list Definite CE.int [v], a 1-element CBOR array wrapping an int.


enc_ec_map100_mixed : () -> Bytes
enc_ec_map100_mixed () =
    CE.encode (ecMapMixedEncoder intPairs100Mixed)


enc_tl_map100_mixed : () -> Bytes
enc_tl_map100_mixed () =
    TE.encode (tlMapMixedEncoder intPairs100Mixed)



-- ============================================================================
-- 7. DECODE ARRAY OF 100 INTS
-- ============================================================================


dec_ec_array100 : () -> Maybe (List Int)
dec_ec_array100 () =
    CD.decode (CD.array CD.int) array100Data |> Result.toMaybe


dec_tl_array100 : () -> Maybe (List Int)
dec_tl_array100 () =
    TD.decode (TD.list TD.int) array100Data



-- ============================================================================
-- 8. DECODE MAP OF 100 INT PAIRS
-- ============================================================================


dec_ec_map100 : () -> Maybe (List ( Int, Int ))
dec_ec_map100 () =
    CD.decode (CD.associativeList CD.int CD.int) map100Data |> Result.toMaybe


dec_tl_map100 : () -> Maybe (List ( Int, Int ))
dec_tl_map100 () =
    TD.decode (TD.associativeList TD.int TD.int) map100Data



-- ============================================================================
-- 9. DECODE 10-FIELD RECORD FROM ARRAY
-- ============================================================================


dec_ec_record10 : () -> Maybe R10
dec_ec_record10 () =
    CD.decode ecDecR10 record10Data |> Result.toMaybe


dec_tl_record10 : () -> Maybe R10
dec_tl_record10 () =
    TD.decode tlDecR10 record10Data



-- ============================================================================
-- 10. DECODE 10-FIELD KEYED RECORD FROM MAP
-- ============================================================================


dec_ec_keyed10 : () -> Maybe R10
dec_ec_keyed10 () =
    CD.decode ecDecKR10 keyedRecord10Data |> Result.toMaybe


dec_tl_keyed10 : () -> Maybe R10
dec_tl_keyed10 () =
    TD.decode tlDecKR10 keyedRecord10Data
