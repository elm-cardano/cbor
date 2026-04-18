module BenchEncode exposing
    ( enc_v1_map_int100, enc_v2_map_int100, enc_v3_map_int100, enc_v5_map_int100
    , enc_v1_map_int1000, enc_v2_map_int1000, enc_v3_map_int1000, enc_v5_map_int1000
    , enc_v1_map_str100, enc_v2_map_str100, enc_v3_map_str100, enc_v5_map_str100
    , enc_v1_canonical_str100, enc_v2_canonical_str100
    , enc_v1_map_str100_early, enc_v2_map_str100_early, enc_v3_map_str100_early, enc_v5_map_str100_early
    , enc_v1_float_f16, enc_v2_float_f16
    , enc_v1_float_f32, enc_v2_float_f32
    , enc_v1_float_f64, enc_v2_float_f64
    )

{-| V1 vs V2 encoder benchmarks.

Compares current `Cbor.Encode` internals against alternative implementations
in `V2` to validate the performance opportunities identified.


# compareBytes: O(N^2) byteAt vs O(N) List Int

V1 (`Cbor.Encode.compareBytes`) creates a fresh `Bytes.Decode` decoder per
byte position, each skipping an increasing prefix. O(K^2) per comparison
where K = key byte length.

V2 (`V2.deterministicV2`) decodes all keys to `List Int` once before sorting,
then uses Elm's built-in `compare` on `List Int`. O(K) per comparison.

Expected: V2 wins on long keys (string, 33 bytes), marginal on short keys
(int, 1-3 bytes) due to list allocation overhead.


## Int keys (1-3 bytes)

```sh
elm-bench -f BenchEncode.enc_v1_map_int100 -f BenchEncode.enc_v2_map_int100 -f BenchEncode.enc_v3_map_int100 -f BenchEncode.enc_v5_map_int100 "()"
elm-bench -f BenchEncode.enc_v1_map_int1000 -f BenchEncode.enc_v2_map_int1000 -f BenchEncode.enc_v3_map_int1000 -f BenchEncode.enc_v5_map_int1000 "()"
```

@docs enc_v1_map_int100, enc_v2_map_int100, enc_v3_map_int100, enc_v5_map_int100
@docs enc_v1_map_int1000, enc_v2_map_int1000, enc_v3_map_int1000, enc_v5_map_int1000


## String keys (33 bytes) — late diff (worst case)

Keys share a long common prefix (`padLeft`), differing only at the end.
Forces full byte traversal on every comparison.

```sh
elm-bench -f BenchEncode.enc_v1_map_str100 -f BenchEncode.enc_v2_map_str100 -f BenchEncode.enc_v3_map_str100 -f BenchEncode.enc_v5_map_str100 "()"
elm-bench -f BenchEncode.enc_v1_canonical_str100 -f BenchEncode.enc_v2_canonical_str100 "()"
```

@docs enc_v1_map_str100, enc_v2_map_str100, enc_v3_map_str100, enc_v5_map_str100
@docs enc_v1_canonical_str100, enc_v2_canonical_str100


## String keys (33 bytes) — early diff (best case)

Keys differ in the first bytes (`padRight`), so comparison short-circuits.

```sh
elm-bench -f BenchEncode.enc_v1_map_str100_early -f BenchEncode.enc_v2_map_str100_early -f BenchEncode.enc_v3_map_str100_early -f BenchEncode.enc_v5_map_str100_early "()"
```

@docs enc_v1_map_str100_early, enc_v2_map_str100_early, enc_v3_map_str100_early, enc_v5_map_str100_early


# encodeFloat: float16-first vs float32-first detection

V1 tries float16 -> float32 -> float64 (up to 2 failed round-trip checks
for true float64 values).

V2 tries float32 first: if it fails, emit float64 immediately (1 check).
If float32 succeeds, then check float16 (2 checks).

Expected: V2 wins on float64 values (1 check vs 2), regresses slightly
on float16 values (2 checks vs 1), neutral on float32 (2 checks either way).

```sh
elm-bench -f BenchEncode.enc_v1_float_f16 -f BenchEncode.enc_v2_float_f16 "()"
elm-bench -f BenchEncode.enc_v1_float_f32 -f BenchEncode.enc_v2_float_f32 "()"
elm-bench -f BenchEncode.enc_v1_float_f64 -f BenchEncode.enc_v2_float_f64 "()"
```

@docs enc_v1_float_f16, enc_v2_float_f16
@docs enc_v1_float_f32, enc_v2_float_f32
@docs enc_v1_float_f64, enc_v2_float_f64

-}

import Bytes exposing (Bytes)
import Cbor exposing (FloatWidth(..))
import Cbor.Encode as CE
import V2



-- ============================================================================
-- TEST DATA
-- ============================================================================


mapIntEncoder100 : CE.Encoder
mapIntEncoder100 =
    CE.map
        (List.map (\i -> ( CE.int i, CE.int (i * 7 + 3) ))
            (List.range 0 99)
        )


mapIntEncoder1000 : CE.Encoder
mapIntEncoder1000 =
    CE.map
        (List.map (\i -> ( CE.int i, CE.int (i * 7 + 3) ))
            (List.range 0 999)
        )


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


mapStrEarlyDiffEncoder100 : CE.Encoder
mapStrEarlyDiffEncoder100 =
    CE.map
        (List.map
            (\i ->
                ( CE.string (String.padRight 32 '0' (String.fromInt i))
                , CE.int i
                )
            )
            (List.range 0 99)
        )


float16Values : List Float
float16Values =
    List.map toFloat (List.range 0 999)


float32Values : List Float
float32Values =
    List.map (\i -> toFloat (2048 + i) + 0.5) (List.range 1 1000)


float64Values : List Float
float64Values =
    List.map (\i -> pi * toFloat (i + 1)) (List.range 0 999)



-- ============================================================================
-- COMPAREBYTES: V1 vs V2 vs V3 vs V4 vs V5
-- ============================================================================


{-| V1: deterministic map encoding with 100 int keys.
-}
enc_v1_map_int100 : () -> Bytes
enc_v1_map_int100 () =
    CE.encode CE.deterministic mapIntEncoder100


{-| V2: 100 int keys (List Int sort key).
-}
enc_v2_map_int100 : () -> Bytes
enc_v2_map_int100 () =
    CE.encode V2.deterministicV2 mapIntEncoder100


{-| V3: 100 int keys (String sort key).
-}
enc_v3_map_int100 : () -> Bytes
enc_v3_map_int100 () =
    CE.encode V2.deterministicV3 mapIntEncoder100


{-| V5: 100 int keys (Hex string sort key).
-}
enc_v5_map_int100 : () -> Bytes
enc_v5_map_int100 () =
    CE.encode V2.deterministicV5 mapIntEncoder100


{-| V1: deterministic map encoding with 1000 int keys.
-}
enc_v1_map_int1000 : () -> Bytes
enc_v1_map_int1000 () =
    CE.encode CE.deterministic mapIntEncoder1000


{-| V2: 1000 int keys (List Int sort key).
-}
enc_v2_map_int1000 : () -> Bytes
enc_v2_map_int1000 () =
    CE.encode V2.deterministicV2 mapIntEncoder1000


{-| V3: 1000 int keys (String sort key).
-}
enc_v3_map_int1000 : () -> Bytes
enc_v3_map_int1000 () =
    CE.encode V2.deterministicV3 mapIntEncoder1000


{-| V5: 1000 int keys (Hex string sort key).
-}
enc_v5_map_int1000 : () -> Bytes
enc_v5_map_int1000 () =
    CE.encode V2.deterministicV5 mapIntEncoder1000


{-| V1: deterministic map encoding with 100 string keys (32 chars each).
-}
enc_v1_map_str100 : () -> Bytes
enc_v1_map_str100 () =
    CE.encode CE.deterministic mapStrEncoder100


{-| V2: 100 string keys (List Int sort key).
-}
enc_v2_map_str100 : () -> Bytes
enc_v2_map_str100 () =
    CE.encode V2.deterministicV2 mapStrEncoder100


{-| V3: 100 string keys (String sort key).
-}
enc_v3_map_str100 : () -> Bytes
enc_v3_map_str100 () =
    CE.encode V2.deterministicV3 mapStrEncoder100


{-| V5: 100 string keys (Hex string sort key).
-}
enc_v5_map_str100 : () -> Bytes
enc_v5_map_str100 () =
    CE.encode V2.deterministicV5 mapStrEncoder100


{-| V1: deterministic map encoding with 100 early-diff string keys.
-}
enc_v1_map_str100_early : () -> Bytes
enc_v1_map_str100_early () =
    CE.encode CE.deterministic mapStrEarlyDiffEncoder100


{-| V2: 100 early-diff string keys (List Int sort key).
-}
enc_v2_map_str100_early : () -> Bytes
enc_v2_map_str100_early () =
    CE.encode V2.deterministicV2 mapStrEarlyDiffEncoder100


{-| V3: 100 early-diff string keys (String sort key).
-}
enc_v3_map_str100_early : () -> Bytes
enc_v3_map_str100_early () =
    CE.encode V2.deterministicV3 mapStrEarlyDiffEncoder100


{-| V5: 100 early-diff string keys (Hex string sort key).
-}
enc_v5_map_str100_early : () -> Bytes
enc_v5_map_str100_early () =
    CE.encode V2.deterministicV5 mapStrEarlyDiffEncoder100


{-| V1: canonical map encoding with 100 string keys (32 chars each).
-}
enc_v1_canonical_str100 : () -> Bytes
enc_v1_canonical_str100 () =
    CE.encode CE.canonical mapStrEncoder100


{-| V2: canonical 100 string keys (tuple comparison).
-}
enc_v2_canonical_str100 : () -> Bytes
enc_v2_canonical_str100 () =
    CE.encode V2.canonicalV2 mapStrEncoder100



-- ============================================================================
-- ENCODEFLOAT: V1 vs V2
-- ============================================================================


{-| V1: 1000 float16-representable values (best case, 1 check).
-}
enc_v1_float_f16 : () -> Bytes
enc_v1_float_f16 () =
    CE.encode CE.unsorted (CE.list CE.float float16Values)


{-| V2: 1000 float16-representable values (regression case, 2 checks).
-}
enc_v2_float_f16 : () -> Bytes
enc_v2_float_f16 () =
    CE.encode CE.unsorted (CE.list V2.floatV2 float16Values)


{-| V1: 1000 float32-representable values (2 checks).
-}
enc_v1_float_f32 : () -> Bytes
enc_v1_float_f32 () =
    CE.encode CE.unsorted (CE.list CE.float float32Values)


{-| V2: 1000 float32-representable values (2 checks).
-}
enc_v2_float_f32 : () -> Bytes
enc_v2_float_f32 () =
    CE.encode CE.unsorted (CE.list V2.floatV2 float32Values)


{-| V1: 1000 float64 values (worst case, 2 failed checks).
-}
enc_v1_float_f64 : () -> Bytes
enc_v1_float_f64 () =
    CE.encode CE.unsorted (CE.list CE.float float64Values)


{-| V2: 1000 float64 values (best case for V2, 1 check).
-}
enc_v2_float_f64 : () -> Bytes
enc_v2_float_f64 () =
    CE.encode CE.unsorted (CE.list V2.floatV2 float64Values)
