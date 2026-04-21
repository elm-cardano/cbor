module Bench exposing
    ( enc_map_unsorted_10, enc_map_deterministic_10, enc_map_canonical_10
    , enc_map_unsorted_100, enc_map_deterministic_100, enc_map_canonical_100
    , enc_map_unsorted_1000, enc_map_deterministic_1000, enc_map_canonical_1000
    , enc_map_unsorted_str100, enc_map_deterministic_str100, enc_map_canonical_str100
    , dec_direct_array100, dec_item_array100
    , enc_direct_list100, enc_item_list100
    , enc_float_f16_1000, enc_float_f32_1000, enc_float_f64_1000, enc_float_explicit64_1000
    , dec_oneOf_flat_first, dec_oneOf_flat_last
    , dec_oneOf_nested_1, dec_oneOf_nested_5, dec_oneOf_nested_10
    , dec_record_3_builder, dec_record_3_manual
    , dec_record_10_builder, dec_record_10_manual
    , dec_record_30_array
    , dec_keyed_3_builder, dec_keyed_3_fold
    , dec_keyed_10_builder, dec_keyed_10_fold
    , dec_keyed_30_associativeList, dec_keyed_30_fold
    , dec_keyed_3_unordered, dec_keyed_10_unordered
    , dec_item_array100int, dec_item_array100str
    , dec_item_nested10, dec_item_map50str
    , dec_itemSkip_array100int, dec_itemSkip_array100str
    , dec_itemSkip_nested10, dec_itemSkip_map50str
    )

{-| Benchmarks for elm-cardano/cbor performance characteristics.

Uses [elm-bench](https://github.com/elm-menagerie/elm-bench).


# Map key sorting

Measures `compareBytes` cost during sorted map encoding.
`unsorted` = baseline (no sorting); `deterministic`/`canonical` add sort overhead.


## Int keys

```sh
elm-bench -f Bench.enc_map_unsorted_10 -f Bench.enc_map_deterministic_10 -f Bench.enc_map_canonical_10 "()"
elm-bench -f Bench.enc_map_unsorted_100 -f Bench.enc_map_deterministic_100 -f Bench.enc_map_canonical_100 "()"
elm-bench -f Bench.enc_map_unsorted_1000 -f Bench.enc_map_deterministic_1000 -f Bench.enc_map_canonical_1000 "()"
```

@docs enc_map_unsorted_10, enc_map_deterministic_10, enc_map_canonical_10
@docs enc_map_unsorted_100, enc_map_deterministic_100, enc_map_canonical_100
@docs enc_map_unsorted_1000, enc_map_deterministic_1000, enc_map_canonical_1000


## 32-char string keys

```sh
elm-bench -f Bench.enc_map_unsorted_str100 -f Bench.enc_map_deterministic_str100 -f Bench.enc_map_canonical_str100 "()"
```

@docs enc_map_unsorted_str100, enc_map_deterministic_str100, enc_map_canonical_str100


# Direct combinators vs item escape hatch

Validates the core "Performance Rationale" claim: direct combinators skip the
intermediate `CborItem` tree.

```sh
elm-bench -f Bench.dec_direct_array100 -f Bench.dec_item_array100 "()"
elm-bench -f Bench.enc_direct_list100 -f Bench.enc_item_list100 "()"
```

@docs dec_direct_array100, dec_item_array100
@docs enc_direct_list100, enc_item_list100


# Float shortest-form detection

The encoder tries float32 first, then float16 within range (up to 2 roundtrip checks per float).

```sh
elm-bench -f Bench.enc_float_f16_1000 -f Bench.enc_float_f32_1000 -f Bench.enc_float_f64_1000 -f Bench.enc_float_explicit64_1000 "()"
```

@docs enc_float_f16_1000, enc_float_f32_1000, enc_float_f64_1000, enc_float_explicit64_1000


# oneOf backtracking

5-branch `oneOf` matching the `plutus_data` dispatch pattern.


## Flat

`first` hits branch 1 (no backtracking); `last` hits branch 5 (4 failed attempts).

```sh
elm-bench -f Bench.dec_oneOf_flat_first -f Bench.dec_oneOf_flat_last "()"
```

@docs dec_oneOf_flat_first, dec_oneOf_flat_last


## Nested

Recursive 5-branch `oneOf` on nested arrays wrapping an int.
Each nesting level adds 2 backtracks (constr + map fail before array matches).

```sh
elm-bench -f Bench.dec_oneOf_nested_1 -f Bench.dec_oneOf_nested_5 -f Bench.dec_oneOf_nested_10 "()"
```

@docs dec_oneOf_nested_1, dec_oneOf_nested_5, dec_oneOf_nested_10


# Record builder scaling (CBOR arrays)

`builder` = `CD.record` + `CD.element` pipeline (tracks remaining counter).
`manual` = `CD.arrayHeader` + `BD.keep` pipeline (no counter).

```sh
elm-bench -f Bench.dec_record_3_builder -f Bench.dec_record_3_manual "()"
elm-bench -f Bench.dec_record_10_builder -f Bench.dec_record_10_manual "()"
elm-bench -f Bench.dec_record_30_array "()"
```

@docs dec_record_3_builder, dec_record_3_manual
@docs dec_record_10_builder, dec_record_10_manual
@docs dec_record_30_array


# Keyed record builder scaling (CBOR maps)

`builder` = `CD.keyedRecord` + `CD.required` pipeline (pendingKey state).
`fold` = `CD.foldEntries` (simple accumulator loop).
`associativeList` = `CD.associativeList` (pair decoder loop).

```sh
elm-bench -f Bench.dec_keyed_3_builder -f Bench.dec_keyed_3_fold -f Bench.dec_keyed_3_unordered "()"
elm-bench -f Bench.dec_keyed_10_builder -f Bench.dec_keyed_10_fold -f Bench.dec_keyed_10_unordered "()"
elm-bench -f Bench.dec_keyed_30_associativeList -f Bench.dec_keyed_30_fold "()"
```

@docs dec_keyed_3_builder, dec_keyed_3_fold
@docs dec_keyed_10_builder, dec_keyed_10_fold
@docs dec_keyed_30_associativeList, dec_keyed_30_fold
@docs dec_keyed_3_unordered, dec_keyed_10_unordered


# item vs itemSkip

`item` builds the full `CborItem` tree (strings decoded, lists allocated).
`itemSkip` skips content using `skipBytes` staying entirely in the fast lane.

```sh
elm-bench -f Bench.dec_item_array100int -f Bench.dec_itemSkip_array100int "()"
elm-bench -f Bench.dec_item_array100str -f Bench.dec_itemSkip_array100str "()"
elm-bench -f Bench.dec_item_nested10 -f Bench.dec_itemSkip_nested10 "()"
elm-bench -f Bench.dec_item_map50str -f Bench.dec_itemSkip_map50str "()"
```

@docs dec_item_array100int, dec_item_array100str
@docs dec_item_nested10, dec_item_map50str
@docs dec_itemSkip_array100int, dec_itemSkip_array100str
@docs dec_itemSkip_nested10, dec_itemSkip_map50str

-}

import Bytes exposing (Bytes)
import Bytes.Decoder as BD
import Bytes.Encode as BE
import Cbor exposing (CborItem(..), FloatWidth(..), IntWidth(..), Length(..), Sign(..), Tag(..))
import Cbor.Decode as CD
import Cbor.Encode as CE



-- ============================================================================
-- TEST DATA
-- ============================================================================
-- Map entry lists (pre-built; encoding benchmarks measure CE.map + CE.encode)


mapIntEntries : Int -> List ( CE.Encoder, CE.Encoder )
mapIntEntries n =
    List.map (\i -> ( CE.int i, CE.int (i * 7 + 3) ))
        (List.range 0 (n - 1))


mapIntEntries10 : List ( CE.Encoder, CE.Encoder )
mapIntEntries10 =
    mapIntEntries 10


mapIntEntries100 : List ( CE.Encoder, CE.Encoder )
mapIntEntries100 =
    mapIntEntries 100


mapIntEntries1000 : List ( CE.Encoder, CE.Encoder )
mapIntEntries1000 =
    mapIntEntries 1000


mapStrEntries100 : List ( CE.Encoder, CE.Encoder )
mapStrEntries100 =
    List.map
        (\i ->
            ( CE.string (String.padLeft 32 '0' (String.fromInt i))
            , CE.int i
            )
        )
        (List.range 0 99)



-- Pre-encoded CBOR bytes (decode benchmarks)


record3Data : Bytes
record3Data =
    CE.encode (CE.list Definite CE.int [ 1, 2, 3 ])


record10Data : Bytes
record10Data =
    CE.encode (CE.list Definite CE.int (List.range 1 10))


record30Data : Bytes
record30Data =
    CE.encode (CE.list Definite CE.int (List.range 1 30))


array100Data : Bytes
array100Data =
    CE.encode (CE.list Definite CE.int (List.range 0 99))


keyedRecord3Data : Bytes
keyedRecord3Data =
    CE.encode
        (CE.map CE.Unsorted Definite (List.map (\i -> ( CE.int i, CE.int (i * 3) )) (List.range 0 2)))


keyedRecord10Data : Bytes
keyedRecord10Data =
    CE.encode
        (CE.map CE.Unsorted Definite (List.map (\i -> ( CE.int i, CE.int (i * 7) )) (List.range 0 9)))


keyedRecord30Data : Bytes
keyedRecord30Data =
    CE.encode
        (CE.map CE.Unsorted Definite (List.map (\i -> ( CE.int i, CE.int (i * 3) )) (List.range 0 29)))



-- Direct vs item encoders (pre-built)


listEncoder100 : CE.Encoder
listEncoder100 =
    CE.list Definite CE.int (List.range 0 99)


listItemEncoder100 : CE.Encoder
listItemEncoder100 =
    CE.item (itemFromBytes array100Data)


itemFromBytes : Bytes -> CborItem
itemFromBytes bs =
    CD.decode CD.item bs
        |> Result.withDefault CborNull


itemToListInt : CborItem -> Maybe (List Int)
itemToListInt cborItem =
    case cborItem of
        CborArray _ items ->
            items
                |> List.foldr
                    (\item acc ->
                        case ( item, acc ) of
                            ( CborInt52 _ n, Just list ) ->
                                Just (n :: list)

                            _ ->
                                Nothing
                    )
                    (Just [])

        _ ->
            Nothing



-- Float value lists
-- float16: small integers (0-999), all exact in float16
-- float32: half-integers above 2048, too precise for float16, exact in float32
-- float64: irrational multiples, too precise for float32


float16Values : List Float
float16Values =
    List.map toFloat (List.range 0 999)


float32Values : List Float
float32Values =
    List.map (\i -> toFloat (2048 + i) + 0.5) (List.range 1 1000)


float64Values : List Float
float64Values =
    List.map (\i -> pi * toFloat (i + 1)) (List.range 0 999)



-- oneOf test data


singleByte : Bytes
singleByte =
    BE.encode (BE.unsignedInt8 0xAB)


oneOfFirstData : Bytes
oneOfFirstData =
    CE.encode (CE.tag (Unknown 121) (CE.list Definite CE.int [ 42 ]))


oneOfLastData : Bytes
oneOfLastData =
    CE.encode (CE.bytes singleByte)


makeNestedArray : Int -> CE.Encoder
makeNestedArray depth =
    if depth <= 0 then
        CE.int 42

    else
        CE.list Definite identity [ makeNestedArray (depth - 1) ]


nestedData1 : Bytes
nestedData1 =
    CE.encode (makeNestedArray 1)


nestedData5 : Bytes
nestedData5 =
    CE.encode (makeNestedArray 5)


nestedData10 : Bytes
nestedData10 =
    CE.encode (makeNestedArray 10)



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


type PlutusFlat
    = PFConstr (List Int)
    | PFMap
    | PFArray
    | PFInt Int
    | PFBytes Bytes


type PlutusNested
    = PNConstr (List PlutusNested)
    | PNMap (List ( PlutusNested, PlutusNested ))
    | PNArray (List PlutusNested)
    | PNInt Int
    | PNBytes Bytes



-- ============================================================================
-- SHARED DECODERS
-- ============================================================================
-- Non-recursive oneOf with 5 branches matching the plutus_data pattern:
-- branch 1: tag 121 (constr) -> major type 6
-- branch 2: map             -> major type 5
-- branch 3: array           -> major type 4
-- branch 4: int             -> major type 0/1
-- branch 5: bytes           -> major type 2


decodePlutusFlat : CD.CborDecoder ctx PlutusFlat
decodePlutusFlat =
    CD.oneOf
        [ CD.tag (Unknown 121) (CD.array CD.int) |> CD.map PFConstr
        , CD.associativeList CD.int CD.int |> CD.map (\_ -> PFMap)
        , CD.array CD.int |> CD.map (\_ -> PFArray)
        , CD.int |> CD.map PFInt
        , CD.bytes |> CD.map PFBytes
        ]


{-| Recursive decoder for nested plutus\_data-like structures.
Self-references deferred via `CD.lazy` to avoid Elm's eager-evaluation cycle.
-}
decodePlutusNested : CD.CborDecoder ctx PlutusNested
decodePlutusNested =
    let
        self : CD.CborDecoder ctx PlutusNested
        self =
            CD.lazy (\() -> decodePlutusNested)
    in
    CD.oneOf
        [ CD.tag (Unknown 121) (CD.array self) |> CD.map PNConstr
        , CD.associativeList self self |> CD.map PNMap
        , CD.array self |> CD.map PNArray
        , CD.int |> CD.map PNInt
        , CD.bytes |> CD.map PNBytes
        ]



-- Record builder decoders


decR3Builder : CD.CborDecoder ctx R3
decR3Builder =
    CD.record R3
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.element CD.int
        |> CD.buildRecord CD.IgnoreExtra


decR3Manual : CD.CborDecoder ctx R3
decR3Manual =
    CD.arrayHeader
        |> CD.andThen
            (\_ ->
                CD.succeed R3
                    |> CD.keep CD.int
                    |> CD.keep CD.int
                    |> CD.keep CD.int
            )


decR10Builder : CD.CborDecoder ctx R10
decR10Builder =
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


decR10Manual : CD.CborDecoder ctx R10
decR10Manual =
    CD.arrayHeader
        |> CD.andThen
            (\_ ->
                CD.succeed R10
                    |> CD.keep CD.int
                    |> CD.keep CD.int
                    |> CD.keep CD.int
                    |> CD.keep CD.int
                    |> CD.keep CD.int
                    |> CD.keep CD.int
                    |> CD.keep CD.int
                    |> CD.keep CD.int
                    |> CD.keep CD.int
                    |> CD.keep CD.int
            )



-- Keyed record builder decoders


decKR3Builder : CD.CborDecoder ctx R3
decKR3Builder =
    CD.keyedRecord CD.int String.fromInt R3
        |> CD.required 0 CD.int
        |> CD.required 1 CD.int
        |> CD.required 2 CD.int
        |> CD.buildKeyedRecord CD.IgnoreExtra


decKR10Builder : CD.CborDecoder ctx R10
decKR10Builder =
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


decFold : CD.CborDecoder ctx (List ( Int, Int ))
decFold =
    CD.foldEntries CD.int
        (\key acc -> CD.int |> CD.map (\v -> ( key, v ) :: acc))
        []
        |> CD.map List.reverse



-- Unordered record decoders (Dict-based dispatch)


type alias R3Acc =
    { a : Maybe Int, b : Maybe Int, c : Maybe Int }


type alias R10Acc =
    { a : Maybe Int
    , b : Maybe Int
    , c : Maybe Int
    , d : Maybe Int
    , e : Maybe Int
    , f : Maybe Int
    , g : Maybe Int
    , h : Maybe Int
    , i : Maybe Int
    , j : Maybe Int
    }


decKR3Unordered : CD.CborDecoder ctx R3
decKR3Unordered =
    CD.unorderedRecord CD.int { a = Nothing, b = Nothing, c = Nothing }
        |> CD.onKey 0 CD.int (\v acc -> { acc | a = Just v })
        |> CD.onKey 1 CD.int (\v acc -> { acc | b = Just v })
        |> CD.onKey 2 CD.int (\v acc -> { acc | c = Just v })
        |> CD.buildUnorderedRecord CD.IgnoreExtra
            (\acc -> Maybe.map3 R3 acc.a acc.b acc.c)


decKR10Unordered : CD.CborDecoder ctx R10
decKR10Unordered =
    CD.unorderedRecord CD.int
        { a = Nothing, b = Nothing, c = Nothing, d = Nothing, e = Nothing, f = Nothing, g = Nothing, h = Nothing, i = Nothing, j = Nothing }
        |> CD.onKey 0 CD.int setMaybeA
        |> CD.onKey 1 CD.int setMaybeB
        |> CD.onKey 2 CD.int setMaybeC
        |> CD.onKey 3 CD.int setMaybeD
        |> CD.onKey 4 CD.int setMaybeE
        |> CD.onKey 5 CD.int setMaybeF
        |> CD.onKey 6 CD.int setMaybeG
        |> CD.onKey 7 CD.int setMaybeH
        |> CD.onKey 8 CD.int setMaybeI
        |> CD.onKey 9 CD.int setMaybeJ
        |> CD.buildUnorderedRecord CD.IgnoreExtra
            (\acc ->
                Maybe.map5 (\a b c d e -> R10 a b c d e)
                    acc.a
                    acc.b
                    acc.c
                    acc.d
                    acc.e
                    |> Maybe.andThen
                        (\partial ->
                            Maybe.map5 (\f g h i j -> partial f g h i j)
                                acc.f
                                acc.g
                                acc.h
                                acc.i
                                acc.j
                        )
            )


setMaybeA v acc =
    { a = Just v, b = acc.b, c = acc.c, d = acc.d, e = acc.e, f = acc.f, g = acc.g, h = acc.h, i = acc.i, j = acc.i }


setMaybeB v acc =
    { a = acc.a, b = Just v, c = acc.c, d = acc.d, e = acc.e, f = acc.f, g = acc.g, h = acc.h, i = acc.i, j = acc.i }


setMaybeC v acc =
    { a = acc.a, b = acc.b, c = Just v, d = acc.d, e = acc.e, f = acc.f, g = acc.g, h = acc.h, i = acc.i, j = acc.i }


setMaybeD v acc =
    { a = acc.a, b = acc.b, c = acc.c, d = Just v, e = acc.e, f = acc.f, g = acc.g, h = acc.h, i = acc.i, j = acc.i }


setMaybeE v acc =
    { a = acc.a, b = acc.b, c = acc.c, d = acc.d, e = Just v, f = acc.f, g = acc.g, h = acc.h, i = acc.i, j = acc.i }


setMaybeF v acc =
    { a = acc.a, b = acc.b, c = acc.c, d = acc.d, e = acc.e, f = Just v, g = acc.g, h = acc.h, i = acc.i, j = acc.i }


setMaybeG v acc =
    { a = acc.a, b = acc.b, c = acc.c, d = acc.d, e = acc.e, f = acc.f, g = Just v, h = acc.h, i = acc.i, j = acc.i }


setMaybeH v acc =
    { a = acc.a, b = acc.b, c = acc.c, d = acc.d, e = acc.e, f = acc.f, g = acc.g, h = Just v, i = acc.i, j = acc.i }


setMaybeI v acc =
    { a = acc.a, b = acc.b, c = acc.c, d = acc.d, e = acc.e, f = acc.f, g = acc.g, h = acc.h, i = Just v, j = acc.i }


setMaybeJ v acc =
    { a = acc.a, b = acc.b, c = acc.c, d = acc.d, e = acc.e, f = acc.f, g = acc.g, h = acc.h, i = acc.i, j = Just v }



-- ============================================================================
-- 1. MAP KEY SORTING COST
-- ============================================================================
-- Measures the cost of key sorting during map construction and encoding.
-- unsorted = baseline (no sorting), deterministic/canonical add sort overhead.
-- Entry lists are pre-built; benchmark measures CE.map + CE.encode.


enc_map_unsorted_10 : () -> Bytes
enc_map_unsorted_10 () =
    CE.encode (CE.map CE.Unsorted Definite mapIntEntries10)


enc_map_deterministic_10 : () -> Bytes
enc_map_deterministic_10 () =
    CE.encode (CE.map CE.deterministicSort Definite mapIntEntries10)


enc_map_canonical_10 : () -> Bytes
enc_map_canonical_10 () =
    CE.encode (CE.map CE.canonicalSort Definite mapIntEntries10)


enc_map_unsorted_100 : () -> Bytes
enc_map_unsorted_100 () =
    CE.encode (CE.map CE.Unsorted Definite mapIntEntries100)


enc_map_deterministic_100 : () -> Bytes
enc_map_deterministic_100 () =
    CE.encode (CE.map CE.deterministicSort Definite mapIntEntries100)


enc_map_canonical_100 : () -> Bytes
enc_map_canonical_100 () =
    CE.encode (CE.map CE.canonicalSort Definite mapIntEntries100)


enc_map_unsorted_1000 : () -> Bytes
enc_map_unsorted_1000 () =
    CE.encode (CE.map CE.Unsorted Definite mapIntEntries1000)


enc_map_deterministic_1000 : () -> Bytes
enc_map_deterministic_1000 () =
    CE.encode (CE.map CE.deterministicSort Definite mapIntEntries1000)


enc_map_canonical_1000 : () -> Bytes
enc_map_canonical_1000 () =
    CE.encode (CE.map CE.canonicalSort Definite mapIntEntries1000)


enc_map_unsorted_str100 : () -> Bytes
enc_map_unsorted_str100 () =
    CE.encode (CE.map CE.Unsorted Definite mapStrEntries100)


enc_map_deterministic_str100 : () -> Bytes
enc_map_deterministic_str100 () =
    CE.encode (CE.map CE.deterministicSort Definite mapStrEntries100)


enc_map_canonical_str100 : () -> Bytes
enc_map_canonical_str100 () =
    CE.encode (CE.map CE.canonicalSort Definite mapStrEntries100)



-- ============================================================================
-- 2. DIRECT COMBINATORS VS ITEM ESCAPE HATCH
-- ============================================================================
-- Validates the "Performance Rationale" claim: direct combinators skip the
-- intermediate CborItem representation.
-- Decode: CD.array CD.int (direct to List Int) vs CD.item (builds CborItem tree)
-- Encode: CE.list CE.int (closures) vs CE.item (pattern matching on CborItem)


dec_direct_array100 : () -> Maybe (List Int)
dec_direct_array100 () =
    CD.decode (CD.array CD.int) array100Data |> Result.toMaybe


dec_item_array100 : () -> Maybe (List Int)
dec_item_array100 () =
    CD.decode CD.item array100Data
        |> Result.toMaybe
        |> Maybe.andThen itemToListInt


enc_direct_list100 : () -> Bytes
enc_direct_list100 () =
    CE.encode listEncoder100


enc_item_list100 : () -> Bytes
enc_item_list100 () =
    CE.encode listItemEncoder100



-- ============================================================================
-- 3. FLOAT SHORTEST-FORM DETECTION
-- ============================================================================
-- The encoder tries float32 first, then float16 within range (up to 2 roundtrips).
-- f16: float32 succeeds + float16 succeeds (2 roundtrip checks)
-- f32: float32 succeeds + float16 fails (2 roundtrip checks)
-- f64: float32 fails (1 roundtrip check)
-- explicit64: skip detection entirely (0 checks, baseline)


enc_float_f16_1000 : () -> Bytes
enc_float_f16_1000 () =
    CE.encode (CE.list Definite CE.float float16Values)


enc_float_f32_1000 : () -> Bytes
enc_float_f32_1000 () =
    CE.encode (CE.list Definite CE.float float32Values)


enc_float_f64_1000 : () -> Bytes
enc_float_f64_1000 () =
    CE.encode (CE.list Definite CE.float float64Values)


enc_float_explicit64_1000 : () -> Bytes
enc_float_explicit64_1000 () =
    CE.encode (CE.list Definite (\f -> CE.floatWithWidth FW64 f) float64Values)



-- ============================================================================
-- 4. ONEOF BACKTRACKING
-- ============================================================================
-- Flat: 5-branch oneOf matching the plutus_data pattern.
--   first = tag 121 (branch 1, 0 backtracks)
--   last  = byte string (branch 5, 4 backtracks)
-- Nested: recursive 5-branch oneOf on arrays wrapping an int.
--   Each outer level: 2 backtracks (constr, map fail; array succeeds).
--   Innermost int: 3 backtracks (constr, map, array fail; int succeeds).


dec_oneOf_flat_first : () -> Maybe PlutusFlat
dec_oneOf_flat_first () =
    CD.decode decodePlutusFlat oneOfFirstData |> Result.toMaybe


dec_oneOf_flat_last : () -> Maybe PlutusFlat
dec_oneOf_flat_last () =
    CD.decode decodePlutusFlat oneOfLastData |> Result.toMaybe


dec_oneOf_nested_1 : () -> Maybe PlutusNested
dec_oneOf_nested_1 () =
    CD.decode decodePlutusNested nestedData1 |> Result.toMaybe


dec_oneOf_nested_5 : () -> Maybe PlutusNested
dec_oneOf_nested_5 () =
    CD.decode decodePlutusNested nestedData5 |> Result.toMaybe


dec_oneOf_nested_10 : () -> Maybe PlutusNested
dec_oneOf_nested_10 () =
    CD.decode decodePlutusNested nestedData10 |> Result.toMaybe



-- ============================================================================
-- 5. BUILDER SCALING
-- ============================================================================
-- Record builder (CBOR arrays -> Elm records):
--   builder = CD.record + CD.element pipeline (remaining counter tracking)
--   manual  = CD.arrayHeader + BD.keep pipeline (no counter)
--   array   = CD.array CD.int (simple loop, baseline for 30 fields)
--
-- Keyed record builder (CBOR maps -> Elm records):
--   builder = CD.keyedRecord + CD.required pipeline (pendingKey state)
--   fold    = CD.foldEntries (simple accumulator loop)
--   associativeList = CD.associativeList (pair decoder loop, baseline for 30 entries)


dec_record_3_builder : () -> Maybe R3
dec_record_3_builder () =
    CD.decode decR3Builder record3Data |> Result.toMaybe


dec_record_3_manual : () -> Maybe R3
dec_record_3_manual () =
    CD.decode decR3Manual record3Data |> Result.toMaybe


dec_record_10_builder : () -> Maybe R10
dec_record_10_builder () =
    CD.decode decR10Builder record10Data |> Result.toMaybe


dec_record_10_manual : () -> Maybe R10
dec_record_10_manual () =
    CD.decode decR10Manual record10Data |> Result.toMaybe


dec_record_30_array : () -> Maybe (List Int)
dec_record_30_array () =
    CD.decode (CD.array CD.int) record30Data |> Result.toMaybe


dec_keyed_3_builder : () -> Maybe (List ( Int, Int ))
dec_keyed_3_builder () =
    CD.decode decKR3Builder keyedRecord3Data
        |> Result.toMaybe
        |> Maybe.map (\r -> [ ( 0, r.a ), ( 1, r.b ), ( 2, r.c ) ])


dec_keyed_3_fold : () -> Maybe (List ( Int, Int ))
dec_keyed_3_fold () =
    CD.decode decFold keyedRecord3Data |> Result.toMaybe


dec_keyed_10_builder : () -> Maybe (List ( Int, Int ))
dec_keyed_10_builder () =
    CD.decode decKR10Builder keyedRecord10Data
        |> Result.toMaybe
        |> Maybe.map (\r -> [ ( 0, r.a ), ( 1, r.b ), ( 2, r.c ), ( 3, r.d ), ( 4, r.e ), ( 5, r.f ), ( 6, r.g ), ( 7, r.h ), ( 8, r.i ), ( 9, r.j ) ])


dec_keyed_10_fold : () -> Maybe (List ( Int, Int ))
dec_keyed_10_fold () =
    CD.decode decFold keyedRecord10Data |> Result.toMaybe


dec_keyed_30_associativeList : () -> Maybe (List ( Int, Int ))
dec_keyed_30_associativeList () =
    CD.decode (CD.associativeList CD.int CD.int) keyedRecord30Data |> Result.toMaybe


dec_keyed_30_fold : () -> Maybe (List ( Int, Int ))
dec_keyed_30_fold () =
    CD.decode decFold keyedRecord30Data |> Result.toMaybe


dec_keyed_3_unordered : () -> Maybe (List ( Int, Int ))
dec_keyed_3_unordered () =
    CD.decode decKR3Unordered keyedRecord3Data
        |> Result.toMaybe
        |> Maybe.map (\r -> [ ( 0, r.a ), ( 1, r.b ), ( 2, r.c ) ])


dec_keyed_10_unordered : () -> Maybe (List ( Int, Int ))
dec_keyed_10_unordered () =
    CD.decode decKR10Unordered keyedRecord10Data
        |> Result.toMaybe
        |> Maybe.map (\r -> [ ( 0, r.a ), ( 1, r.b ), ( 2, r.c ), ( 3, r.d ), ( 4, r.e ), ( 5, r.f ), ( 6, r.g ), ( 7, r.h ), ( 8, r.i ), ( 9, r.j ) ])



-- ============================================================================
-- 6. ITEM VS ITEM SKIP
-- ============================================================================
-- Compares full CborItem decoding (item) vs fast skip (itemSkip).
--
-- array100int: 100 small integers (cheapest items — measures overhead)
-- array100str: 100 × 32-char strings (string decoding is expensive)
-- nested10:    10-deep nested arrays wrapping an int (recursive structure)
-- map50str:    map with 50 string→string entries (both keys and values expensive)


array100strData : Bytes
array100strData =
    CE.encode
        (CE.list Definite
            CE.string
            (List.map (\i -> String.padLeft 32 '0' (String.fromInt i))
                (List.range 0 99)
            )
        )


nested10Data : Bytes
nested10Data =
    CE.encode (makeNestedArray 10)


map50strData : Bytes
map50strData =
    CE.encode
        (CE.map CE.Unsorted
            Definite
            (List.map
                (\i ->
                    ( CE.string ("key_" ++ String.padLeft 28 '0' (String.fromInt i))
                    , CE.string ("val_" ++ String.padLeft 28 '0' (String.fromInt i))
                    )
                )
                (List.range 0 49)
            )
        )


dec_item_array100int : () -> Maybe ()
dec_item_array100int () =
    CD.decode CD.item array100Data |> Result.toMaybe |> Maybe.map (\_ -> ())


dec_item_array100str : () -> Maybe ()
dec_item_array100str () =
    CD.decode CD.item array100strData |> Result.toMaybe |> Maybe.map (\_ -> ())


dec_item_nested10 : () -> Maybe ()
dec_item_nested10 () =
    CD.decode CD.item nested10Data |> Result.toMaybe |> Maybe.map (\_ -> ())


dec_item_map50str : () -> Maybe ()
dec_item_map50str () =
    CD.decode CD.item map50strData |> Result.toMaybe |> Maybe.map (\_ -> ())


dec_itemSkip_array100int : () -> Maybe ()
dec_itemSkip_array100int () =
    CD.decode (CD.array CD.itemSkip) array100Data |> Result.toMaybe |> Maybe.map (\_ -> ())


dec_itemSkip_array100str : () -> Maybe ()
dec_itemSkip_array100str () =
    CD.decode (CD.array CD.itemSkip) array100strData |> Result.toMaybe |> Maybe.map (\_ -> ())


dec_itemSkip_nested10 : () -> Maybe ()
dec_itemSkip_nested10 () =
    CD.decode CD.itemSkip nested10Data |> Result.toMaybe |> Maybe.map (\_ -> ())


dec_itemSkip_map50str : () -> Maybe ()
dec_itemSkip_map50str () =
    CD.decode (CD.associativeList CD.itemSkip CD.itemSkip) map50strData |> Result.toMaybe |> Maybe.map (\_ -> ())
