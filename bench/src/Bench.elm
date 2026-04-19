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
    , dec_keyed_30_keyValue, dec_keyed_30_fold
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

The encoder tries float16, then float32, then float64 (up to 3 roundtrip checks per float).

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
`keyValue` = `CD.keyValue` (pair decoder loop).

```sh
elm-bench -f Bench.dec_keyed_3_builder -f Bench.dec_keyed_3_fold "()"
elm-bench -f Bench.dec_keyed_10_builder -f Bench.dec_keyed_10_fold "()"
elm-bench -f Bench.dec_keyed_30_keyValue -f Bench.dec_keyed_30_fold "()"
```

@docs dec_keyed_3_builder, dec_keyed_3_fold
@docs dec_keyed_10_builder, dec_keyed_10_fold
@docs dec_keyed_30_keyValue, dec_keyed_30_fold

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
-- Map encoders (pre-built, encoding benchmarks measure CE.encode only)


mapIntEncoder : Int -> CE.Encoder
mapIntEncoder n =
    CE.map
        (List.map (\i -> ( CE.int i, CE.int (i * 7 + 3) ))
            (List.range 0 (n - 1))
        )


mapIntEncoder10 : CE.Encoder
mapIntEncoder10 =
    mapIntEncoder 10


mapIntEncoder100 : CE.Encoder
mapIntEncoder100 =
    mapIntEncoder 100


mapIntEncoder1000 : CE.Encoder
mapIntEncoder1000 =
    mapIntEncoder 1000


mapStrEncoder100 : CE.Encoder
mapStrEncoder100 =
    CE.map
        (List.map
            (\i ->
                ( CE.string (String.padLeft 32 '0' (String.fromInt i))
                , CE.int i
                )
            )
            (List.range 0 99)
        )



-- Pre-encoded CBOR bytes (decode benchmarks)


record3Data : Bytes
record3Data =
    CE.encode CE.unsorted (CE.list CE.int [ 1, 2, 3 ])


record10Data : Bytes
record10Data =
    CE.encode CE.unsorted (CE.list CE.int (List.range 1 10))


record30Data : Bytes
record30Data =
    CE.encode CE.unsorted (CE.list CE.int (List.range 1 30))


array100Data : Bytes
array100Data =
    CE.encode CE.unsorted (CE.list CE.int (List.range 0 99))


keyedRecord3Data : Bytes
keyedRecord3Data =
    CE.encode CE.unsorted
        (CE.map (List.map (\i -> ( CE.int i, CE.int (i * 3) )) (List.range 0 2)))


keyedRecord10Data : Bytes
keyedRecord10Data =
    CE.encode CE.unsorted
        (CE.map (List.map (\i -> ( CE.int i, CE.int (i * 7) )) (List.range 0 9)))


keyedRecord30Data : Bytes
keyedRecord30Data =
    CE.encode CE.unsorted
        (CE.map (List.map (\i -> ( CE.int i, CE.int (i * 3) )) (List.range 0 29)))



-- Direct vs item encoders (pre-built)


listEncoder100 : CE.Encoder
listEncoder100 =
    CE.list CE.int (List.range 0 99)


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
    CE.encode CE.unsorted (CE.tag (Unknown 121) (CE.list CE.int [ 42 ]))


oneOfLastData : Bytes
oneOfLastData =
    CE.encode CE.unsorted (CE.bytes singleByte)


makeNestedArray : Int -> CE.Encoder
makeNestedArray depth =
    if depth <= 0 then
        CE.int 42

    else
        CE.list identity [ makeNestedArray (depth - 1) ]


nestedData1 : Bytes
nestedData1 =
    CE.encode CE.unsorted (makeNestedArray 1)


nestedData5 : Bytes
nestedData5 =
    CE.encode CE.unsorted (makeNestedArray 5)


nestedData10 : Bytes
nestedData10 =
    CE.encode CE.unsorted (makeNestedArray 10)



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
        , CD.keyValue CD.int CD.int |> CD.map (\_ -> PFMap)
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
        , CD.keyValue self self |> CD.map PNMap
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
    CD.keyedRecord CD.int R3
        |> CD.required 0 CD.int
        |> CD.required 1 CD.int
        |> CD.required 2 CD.int
        |> CD.buildKeyedRecord CD.IgnoreExtra


decKR10Builder : CD.CborDecoder ctx R10
decKR10Builder =
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
        |> CD.buildKeyedRecord CD.IgnoreExtra


decFold : CD.CborDecoder ctx (List ( Int, Int ))
decFold =
    let
        intBD : BD.Decoder ctx CD.DecodeError Int
        intBD =
            CD.toBD CD.int
    in
    CD.foldEntries CD.int
        (\key acc -> intBD |> BD.map (\v -> ( key, v ) :: acc))
        []
        |> CD.map List.reverse



-- ============================================================================
-- 1. MAP KEY SORTING COST
-- ============================================================================
-- Measures the cost of key sorting during map encoding.
-- unsorted = baseline (no sorting), deterministic/canonical add sort overhead.
-- The encoder is pre-built; benchmark measures CE.encode only.


enc_map_unsorted_10 : () -> Bytes
enc_map_unsorted_10 () =
    CE.encode CE.unsorted mapIntEncoder10


enc_map_deterministic_10 : () -> Bytes
enc_map_deterministic_10 () =
    CE.encode CE.deterministic mapIntEncoder10


enc_map_canonical_10 : () -> Bytes
enc_map_canonical_10 () =
    CE.encode CE.canonical mapIntEncoder10


enc_map_unsorted_100 : () -> Bytes
enc_map_unsorted_100 () =
    CE.encode CE.unsorted mapIntEncoder100


enc_map_deterministic_100 : () -> Bytes
enc_map_deterministic_100 () =
    CE.encode CE.deterministic mapIntEncoder100


enc_map_canonical_100 : () -> Bytes
enc_map_canonical_100 () =
    CE.encode CE.canonical mapIntEncoder100


enc_map_unsorted_1000 : () -> Bytes
enc_map_unsorted_1000 () =
    CE.encode CE.unsorted mapIntEncoder1000


enc_map_deterministic_1000 : () -> Bytes
enc_map_deterministic_1000 () =
    CE.encode CE.deterministic mapIntEncoder1000


enc_map_canonical_1000 : () -> Bytes
enc_map_canonical_1000 () =
    CE.encode CE.canonical mapIntEncoder1000


enc_map_unsorted_str100 : () -> Bytes
enc_map_unsorted_str100 () =
    CE.encode CE.unsorted mapStrEncoder100


enc_map_deterministic_str100 : () -> Bytes
enc_map_deterministic_str100 () =
    CE.encode CE.deterministic mapStrEncoder100


enc_map_canonical_str100 : () -> Bytes
enc_map_canonical_str100 () =
    CE.encode CE.canonical mapStrEncoder100



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
    CE.encode CE.unsorted listEncoder100


enc_item_list100 : () -> Bytes
enc_item_list100 () =
    CE.encode CE.unsorted listItemEncoder100



-- ============================================================================
-- 3. FLOAT SHORTEST-FORM DETECTION
-- ============================================================================
-- The encoder tries float16, then float32, then float64 (up to 3 roundtrips).
-- f16: best case (1 roundtrip check succeeds)
-- f32: middle case (f16 fails, f32 succeeds = 2 checks)
-- f64: worst case (f16 and f32 both fail = 3 checks)
-- explicit64: skip detection entirely (0 checks, baseline)


enc_float_f16_1000 : () -> Bytes
enc_float_f16_1000 () =
    CE.encode CE.unsorted (CE.list CE.float float16Values)


enc_float_f32_1000 : () -> Bytes
enc_float_f32_1000 () =
    CE.encode CE.unsorted (CE.list CE.float float32Values)


enc_float_f64_1000 : () -> Bytes
enc_float_f64_1000 () =
    CE.encode CE.unsorted (CE.list CE.float float64Values)


enc_float_explicit64_1000 : () -> Bytes
enc_float_explicit64_1000 () =
    CE.encode CE.unsorted (CE.list (\f -> CE.floatWithWidth FW64 f) float64Values)



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
--   keyValue = CD.keyValue (pair decoder loop, baseline for 30 entries)


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


dec_keyed_30_keyValue : () -> Maybe (List ( Int, Int ))
dec_keyed_30_keyValue () =
    CD.decode (CD.keyValue CD.int CD.int) keyedRecord30Data |> Result.toMaybe


dec_keyed_30_fold : () -> Maybe (List ( Int, Int ))
dec_keyed_30_fold () =
    CD.decode decFold keyedRecord30Data |> Result.toMaybe
