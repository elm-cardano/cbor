module ToulouseVsPhantom exposing
    ( enc_tl_list100, enc_ph_list100, enc_pt_list100, enc_ar_list100
    , enc_tl_map100, enc_ph_map100, enc_pt_map100, enc_ar_map100
    , enc_tl_tuple10, enc_ph_tuple10, enc_pt_tuple10, enc_ar_tuple10
    , enc_tl_keyed10, enc_ph_keyed10, enc_pt_keyed10, enc_ar_keyed10
    , enc_tl_nested100, enc_ph_nested100, enc_pt_nested100, enc_ar_nested100
    , enc_tl_list100_mixed, enc_ph_list100_mixed, enc_pt_list100_mixed, enc_ar_list100_mixed
    , enc_tl_map100_mixed, enc_ph_map100_mixed, enc_pt_map100_mixed, enc_ar_map100_mixed
    )

{-| Head-to-head benchmarks: elm-toulouse/cbor (`tl`) vs
PhantomEncode (`ph`, flat) vs PhantomTreeEncode (`pt`, tree)
vs ArgEncode (`ar`, argument-based).

Uses [elm-bench](https://github.com/elm-menagerie/elm-bench).


# Encode array of 100 ints

```sh
elm-bench -f ToulouseVsPhantom.enc_tl_list100 -f ToulouseVsPhantom.enc_ph_list100 -f ToulouseVsPhantom.enc_pt_list100 -f ToulouseVsPhantom.enc_ar_list100 "()"
```

@docs enc_tl_list100, enc_ph_list100, enc_pt_list100, enc_ar_list100


# Encode map of 100 int→int pairs

```sh
elm-bench -f ToulouseVsPhantom.enc_tl_map100 -f ToulouseVsPhantom.enc_ph_map100 -f ToulouseVsPhantom.enc_pt_map100 -f ToulouseVsPhantom.enc_ar_map100 "()"
```

@docs enc_tl_map100, enc_ph_map100, enc_pt_map100, enc_ar_map100


# Encode 10-field record as CBOR array (tuple)

Includes both encoder construction and serialization.

```sh
elm-bench -f ToulouseVsPhantom.enc_tl_tuple10 -f ToulouseVsPhantom.enc_ph_tuple10 -f ToulouseVsPhantom.enc_pt_tuple10 -f ToulouseVsPhantom.enc_ar_tuple10 "()"
```

@docs enc_tl_tuple10, enc_ph_tuple10, enc_pt_tuple10, enc_ar_tuple10


# Encode 10-field keyed record as CBOR map

Includes both encoder construction and serialization.

```sh
elm-bench -f ToulouseVsPhantom.enc_tl_keyed10 -f ToulouseVsPhantom.enc_ph_keyed10 -f ToulouseVsPhantom.enc_pt_keyed10 -f ToulouseVsPhantom.enc_ar_keyed10 "()"
```

@docs enc_tl_keyed10, enc_ph_keyed10, enc_pt_keyed10, enc_ar_keyed10


# Encode 100 nested records (list of 3-field tuples)

```sh
elm-bench -f ToulouseVsPhantom.enc_tl_nested100 -f ToulouseVsPhantom.enc_ph_nested100 -f ToulouseVsPhantom.enc_pt_nested100 -f ToulouseVsPhantom.enc_ar_nested100 "()"
```

@docs enc_tl_nested100, enc_ph_nested100, enc_pt_nested100, enc_ar_nested100


# Encode list of 100 wrapped ints (non-Direct path)

Each element is a 1-element CBOR array wrapping an int.

```sh
elm-bench -f ToulouseVsPhantom.enc_tl_list100_mixed -f ToulouseVsPhantom.enc_ph_list100_mixed -f ToulouseVsPhantom.enc_pt_list100_mixed -f ToulouseVsPhantom.enc_ar_list100_mixed "()"
```

@docs enc_tl_list100_mixed, enc_ph_list100_mixed, enc_pt_list100_mixed, enc_ar_list100_mixed


# Encode map of 100 wrapped int pairs (non-Direct path)

Each value is a 1-element CBOR array wrapping an int.

```sh
elm-bench -f ToulouseVsPhantom.enc_tl_map100_mixed -f ToulouseVsPhantom.enc_ph_map100_mixed -f ToulouseVsPhantom.enc_pt_map100_mixed -f ToulouseVsPhantom.enc_ar_map100_mixed "()"
```

@docs enc_tl_map100_mixed, enc_ph_map100_mixed, enc_pt_map100_mixed, enc_ar_map100_mixed

-}

import ArgEncode as AE
import Bytes exposing (Bytes)
import PhantomEncode as PE
import PhantomTreeEncode as PT
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


tlListEncoder : List Int -> TE.Encoder
tlListEncoder =
    TE.list TE.int


phListEncoder : List Int -> PE.Encoder {}
phListEncoder ints =
    PE.list PE.int ints
        |> PE.definite


ptListEncoder : List Int -> PT.Encoder {}
ptListEncoder ints =
    PT.list PT.int ints
        |> PT.definite


arListEncoder : List Int -> AE.Encoder
arListEncoder ints =
    AE.list AE.Definite AE.int ints


tlMapEncoder : List ( Int, Int ) -> TE.Encoder
tlMapEncoder =
    TE.associativeList TE.int TE.int


phMapEncoder : List ( Int, Int ) -> PE.Encoder {}
phMapEncoder pairs =
    PE.map (List.map (\( k, v ) -> ( PE.int k, PE.int v )) pairs)
        |> PE.unsorted
        |> PE.definite


ptMapEncoder : List ( Int, Int ) -> PT.Encoder {}
ptMapEncoder pairs =
    PT.map (List.map (\( k, v ) -> ( PT.int k, PT.int v )) pairs)
        |> PT.unsorted
        |> PT.definite


arMapEncoder : List ( Int, Int ) -> AE.Encoder
arMapEncoder pairs =
    AE.map AE.Unsorted AE.Definite (List.map (\( k, v ) -> ( AE.int k, AE.int v )) pairs)


tlListMixedEncoder : List (List Int) -> TE.Encoder
tlListMixedEncoder =
    TE.list (TE.list TE.int)


phListMixedEncoder : List (List Int) -> PE.Encoder {}
phListMixedEncoder items =
    PE.list (\vs -> PE.list PE.int vs |> PE.definite) items
        |> PE.definite


ptListMixedEncoder : List (List Int) -> PT.Encoder {}
ptListMixedEncoder items =
    PT.list (PT.list PT.int) items
        |> PT.definite


arListMixedEncoder : List (List Int) -> AE.Encoder
arListMixedEncoder items =
    AE.list AE.Definite (\vs -> AE.list AE.Definite AE.int vs) items


tlMapMixedEncoder : List ( Int, List Int ) -> TE.Encoder
tlMapMixedEncoder =
    TE.associativeList TE.int (TE.list TE.int)


phMapMixedEncoder : List ( Int, List Int ) -> PE.Encoder {}
phMapMixedEncoder pairs =
    PE.map (List.map (\( k, vs ) -> ( PE.int k, PE.list PE.int vs |> PE.definite )) pairs)
        |> PE.unsorted
        |> PE.definite


ptMapMixedEncoder : List ( Int, List Int ) -> PT.Encoder {}
ptMapMixedEncoder pairs =
    PT.map (List.map (\( k, vs ) -> ( PT.int k, PT.list PT.int vs )) pairs)
        |> PT.unsorted
        |> PT.definite


arMapMixedEncoder : List ( Int, List Int ) -> AE.Encoder
arMapMixedEncoder pairs =
    AE.map AE.Unsorted AE.Definite (List.map (\( k, vs ) -> ( AE.int k, AE.list AE.Definite AE.int vs )) pairs)



-- ============================================================================
-- 1. ENCODE LIST OF 100 INTS (pre-built)
-- ============================================================================


enc_tl_list100 : () -> Bytes
enc_tl_list100 () =
    TE.encode (tlListEncoder intRange100)


enc_ph_list100 : () -> Bytes
enc_ph_list100 () =
    PE.encode (phListEncoder intRange100)


enc_pt_list100 : () -> Bytes
enc_pt_list100 () =
    PT.encode (ptListEncoder intRange100)


enc_ar_list100 : () -> Bytes
enc_ar_list100 () =
    AE.encode (arListEncoder intRange100)


-- ============================================================================
-- 2. ENCODE MAP OF 100 INT PAIRS (pre-built)
-- ============================================================================


enc_tl_map100 : () -> Bytes
enc_tl_map100 () =
    TE.encode (tlMapEncoder intPairs100)


enc_ph_map100 : () -> Bytes
enc_ph_map100 () =
    PE.encode (phMapEncoder intPairs100)


enc_pt_map100 : () -> Bytes
enc_pt_map100 () =
    PT.encode (ptMapEncoder intPairs100)


enc_ar_map100 : () -> Bytes
enc_ar_map100 () =
    AE.encode (arMapEncoder intPairs100)



-- ============================================================================
-- 3. ENCODE 10-FIELD RECORD AS CBOR ARRAY (TUPLE)
-- ============================================================================
-- Measures encoder construction + serialization together.


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


phTuple10Encoder : R10 -> PE.Encoder {}
phTuple10Encoder r =
    PE.array
        [ PE.int r.a
        , PE.int r.b
        , PE.int r.c
        , PE.int r.d
        , PE.int r.e
        , PE.int r.f
        , PE.int r.g
        , PE.int r.h
        , PE.int r.i
        , PE.int r.j
        ]
        |> PE.definite


ptTuple10Encoder : R10 -> PT.Encoder {}
ptTuple10Encoder r =
    PT.array
        [ PT.int r.a
        , PT.int r.b
        , PT.int r.c
        , PT.int r.d
        , PT.int r.e
        , PT.int r.f
        , PT.int r.g
        , PT.int r.h
        , PT.int r.i
        , PT.int r.j
        ]
        |> PT.definite


enc_tl_tuple10 : () -> Bytes
enc_tl_tuple10 () =
    TE.encode (tlTuple10Encoder r10)


enc_ph_tuple10 : () -> Bytes
enc_ph_tuple10 () =
    PE.encode (phTuple10Encoder r10)


enc_pt_tuple10 : () -> Bytes
enc_pt_tuple10 () =
    PT.encode (ptTuple10Encoder r10)


enc_ar_tuple10 : () -> Bytes
enc_ar_tuple10 () =
    AE.encode (arTuple10Encoder r10)


arTuple10Encoder : R10 -> AE.Encoder
arTuple10Encoder r =
    AE.array AE.Definite
        [ AE.int r.a
        , AE.int r.b
        , AE.int r.c
        , AE.int r.d
        , AE.int r.e
        , AE.int r.f
        , AE.int r.g
        , AE.int r.h
        , AE.int r.i
        , AE.int r.j
        ]



-- ============================================================================
-- 4. ENCODE 10-FIELD KEYED RECORD AS CBOR MAP
-- ============================================================================


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


phKeyed10Encoder : R10 -> PE.Encoder {}
phKeyed10Encoder r =
    PE.map
        [ ( PE.int 0, PE.int r.a )
        , ( PE.int 1, PE.int r.b )
        , ( PE.int 2, PE.int r.c )
        , ( PE.int 3, PE.int r.d )
        , ( PE.int 4, PE.int r.e )
        , ( PE.int 5, PE.int r.f )
        , ( PE.int 6, PE.int r.g )
        , ( PE.int 7, PE.int r.h )
        , ( PE.int 8, PE.int r.i )
        , ( PE.int 9, PE.int r.j )
        ]
        |> PE.unsorted
        |> PE.definite


ptKeyed10Encoder : R10 -> PT.Encoder {}
ptKeyed10Encoder r =
    PT.map
        [ ( PT.int 0, PT.int r.a )
        , ( PT.int 1, PT.int r.b )
        , ( PT.int 2, PT.int r.c )
        , ( PT.int 3, PT.int r.d )
        , ( PT.int 4, PT.int r.e )
        , ( PT.int 5, PT.int r.f )
        , ( PT.int 6, PT.int r.g )
        , ( PT.int 7, PT.int r.h )
        , ( PT.int 8, PT.int r.i )
        , ( PT.int 9, PT.int r.j )
        ]
        |> PT.unsorted
        |> PT.definite


enc_tl_keyed10 : () -> Bytes
enc_tl_keyed10 () =
    TE.encode (tlKeyed10Encoder r10)


enc_ph_keyed10 : () -> Bytes
enc_ph_keyed10 () =
    PE.encode (phKeyed10Encoder r10)


enc_pt_keyed10 : () -> Bytes
enc_pt_keyed10 () =
    PT.encode (ptKeyed10Encoder r10)


enc_ar_keyed10 : () -> Bytes
enc_ar_keyed10 () =
    AE.encode (arKeyed10Encoder r10)


arKeyed10Encoder : R10 -> AE.Encoder
arKeyed10Encoder r =
    AE.map AE.Unsorted AE.Definite
        [ ( AE.int 0, AE.int r.a )
        , ( AE.int 1, AE.int r.b )
        , ( AE.int 2, AE.int r.c )
        , ( AE.int 3, AE.int r.d )
        , ( AE.int 4, AE.int r.e )
        , ( AE.int 5, AE.int r.f )
        , ( AE.int 6, AE.int r.g )
        , ( AE.int 7, AE.int r.h )
        , ( AE.int 8, AE.int r.i )
        , ( AE.int 9, AE.int r.j )
        ]



-- ============================================================================
-- 5. ENCODE 100 NESTED RECORDS (LIST OF 3-FIELD TUPLES)
-- ============================================================================


tlNested100Encoder : List R3 -> TE.Encoder
tlNested100Encoder =
    TE.list <|
        TE.tuple <|
            TE.elems
                >> TE.elem TE.int .a
                >> TE.elem TE.int .b
                >> TE.elem TE.int .c


phNested100Encoder : List R3 -> PE.Encoder {}
phNested100Encoder rs =
    PE.list (\r -> PE.array [ PE.int r.a, PE.int r.b, PE.int r.c ] |> PE.definite) rs
        |> PE.definite


ptNested100Encoder : List R3 -> PT.Encoder {}
ptNested100Encoder rs =
    PT.list (\r -> PT.array [ PT.int r.a, PT.int r.b, PT.int r.c ]) rs
        |> PT.definite


enc_tl_nested100 : () -> Bytes
enc_tl_nested100 () =
    TE.encode (tlNested100Encoder r3List)


enc_ph_nested100 : () -> Bytes
enc_ph_nested100 () =
    PE.encode (phNested100Encoder r3List)


enc_pt_nested100 : () -> Bytes
enc_pt_nested100 () =
    PT.encode (ptNested100Encoder r3List)


enc_ar_nested100 : () -> Bytes
enc_ar_nested100 () =
    AE.encode (arNested100Encoder r3List)


arNested100Encoder : List R3 -> AE.Encoder
arNested100Encoder rs =
    AE.list AE.Definite (\r -> AE.array AE.Definite [ AE.int r.a, AE.int r.b, AE.int r.c ]) rs



-- ============================================================================
-- 6. ENCODE LIST OF 100 WRAPPED INTS (NON-DIRECT PATH)
-- ============================================================================


enc_tl_list100_mixed : () -> Bytes
enc_tl_list100_mixed () =
    TE.encode (tlListMixedEncoder intRange100Mixed)


enc_ph_list100_mixed : () -> Bytes
enc_ph_list100_mixed () =
    PE.encode (phListMixedEncoder intRange100Mixed)


enc_pt_list100_mixed : () -> Bytes
enc_pt_list100_mixed () =
    PT.encode (ptListMixedEncoder intRange100Mixed)


enc_ar_list100_mixed : () -> Bytes
enc_ar_list100_mixed () =
    AE.encode (arListMixedEncoder intRange100Mixed)


-- ============================================================================
-- 7. ENCODE MAP OF 100 WRAPPED INT PAIRS (NON-DIRECT PATH)
-- ============================================================================


enc_tl_map100_mixed : () -> Bytes
enc_tl_map100_mixed () =
    TE.encode (tlMapMixedEncoder intPairs100Mixed)


enc_ph_map100_mixed : () -> Bytes
enc_ph_map100_mixed () =
    PE.encode (phMapMixedEncoder intPairs100Mixed)


enc_pt_map100_mixed : () -> Bytes
enc_pt_map100_mixed () =
    PT.encode (ptMapMixedEncoder intPairs100Mixed)


enc_ar_map100_mixed : () -> Bytes
enc_ar_map100_mixed () =
    AE.encode (arMapMixedEncoder intPairs100Mixed)
