module BenchOptimize exposing
    ( enc_string_v1, enc_string_v2, enc_string_v2b
    , enc_header_v1, enc_header_v2
    , enc_indef_v1_100, enc_indef_v2_100
    , enc_indef_v1_1000, enc_indef_v2_1000
    , enc_mapfold_v1_100, enc_mapfold_v2_100
    , enc_guard_v1, enc_guard_v2
    )

{-| Benchmarks for encoder optimization opportunities 1–5 identified in
`bench/opportunities-encode.md`.


# 1. String encoding: avoid intermediate buffer

V1 encodes the string to a temporary `Bytes` to measure UTF-8 length,
then copies those bytes. V2 uses `BE.getStringWidth` (pure arithmetic)
and writes the string directly.

Test data: 1000 × 32-char hex strings (typical Cardano hash size).

```sh
elm-bench -f BenchOptimize.enc_string_v1 -f BenchOptimize.enc_string_v2 -f BenchOptimize.enc_string_v2b "()"
```

@docs enc_string_v1, enc_string_v2, enc_string_v2b


# 2. Header packing for argument 24–255

V1 emits `BE.sequence [U8, U8]` (6 allocations). V2 packs into a single
`BE.unsignedInt16` (1 allocation).

Test data: 1000 × 32-byte values (hash-sized, hits the 24–255 branch).

```sh
elm-bench -f BenchOptimize.enc_header_v1 -f BenchOptimize.enc_header_v2 "()"
```

@docs enc_header_v1, enc_header_v2


# 3. Break appending: `++ [break]` vs nested sequence

V1 appends the break byte with `++` (O(N) list traversal).
V2 wraps items in a nested `BE.sequence` (O(1)).

Test data: 100 and 1000 single-byte encoders.

```sh
elm-bench -f BenchOptimize.enc_indef_v1_100 -f BenchOptimize.enc_indef_v2_100 "()"
elm-bench -f BenchOptimize.enc_indef_v1_1000 -f BenchOptimize.enc_indef_v2_1000 "()"
```

@docs enc_indef_v1_100, enc_indef_v2_100
@docs enc_indef_v1_1000, enc_indef_v2_1000


# 4. Map entries: `List.concatMap` vs `List.foldr`

V1 uses `List.concatMap` (N intermediate 2-element lists + concat).
V2 uses `List.foldr` (builds the flat list with cons operations).

Test data: 100-entry map with int keys and values.

```sh
elm-bench -f BenchOptimize.enc_mapfold_v1_100 -f BenchOptimize.enc_mapfold_v2_100 "()"
```

@docs enc_mapfold_v1_100, enc_mapfold_v2_100


# 5. Float fast-reject: range guard before float16 round-trip

V1 always runs the float16 round-trip check (2 DataView allocations).
V2 skips it when `abs f > 65504` (float16 max value).

Test data: 1000 float64 values > 65504 (where the guard fires).

```sh
elm-bench -f BenchOptimize.enc_guard_v1 -f BenchOptimize.enc_guard_v2 "()"
```

@docs enc_guard_v1, enc_guard_v2

-}

import Bytes exposing (Bytes)
import Bytes.Encode as BE
import Cbor exposing (FloatWidth(..))
import Cbor.Encode as CE
import V2



-- ============================================================================
-- TEST DATA
-- ============================================================================
-- #1: 1000 x 32-char hex strings (like Cardano hashes/addresses)


hashStrings : List String
hashStrings =
    List.map (\i -> String.padLeft 32 '0' (String.fromInt i))
        (List.range 0 999)



-- #2: 1000 x 32-byte values (hash-sized byte strings)


hash32Bytes : Bytes
hash32Bytes =
    BE.encode (BE.sequence (List.repeat 32 (BE.unsignedInt8 0xAB)))


hashBytesList : List Bytes
hashBytesList =
    List.repeat 1000 hash32Bytes



-- #3: pre-built lists of single-byte encoders


intEncoders100 : List BE.Encoder
intEncoders100 =
    List.map BE.unsignedInt8 (List.range 0 99)


intEncoders1000 : List BE.Encoder
intEncoders1000 =
    List.map BE.unsignedInt8 (List.range 0 255)
        ++ List.map BE.unsignedInt8 (List.range 0 255)
        ++ List.map BE.unsignedInt8 (List.range 0 255)
        ++ List.map BE.unsignedInt8 (List.range 0 232)



-- #4: 100-entry map with int keys and values


mapPairs100 : List ( Int, Int )
mapPairs100 =
    List.map (\i -> ( i, i * 7 + 3 )) (List.range 0 99)



-- #5: 1000 float64 values above 65504 (float16 max)


float64LargeValues : List Float
float64LargeValues =
    List.map (\i -> 100000 * pi + toFloat i) (List.range 0 999)



-- ============================================================================
-- 1. STRING ENCODING
-- ============================================================================


{-| V1: current string encoding (encode → measure → copy).
-}
enc_string_v1 : () -> Bytes
enc_string_v1 () =
    BE.encode (BE.sequence (List.map V2.stringBEv1 hashStrings))


{-| V2: getStringWidth, no intermediate buffer.
-}
enc_string_v2 : () -> Bytes
enc_string_v2 () =
    BE.encode (BE.sequence (List.map V2.stringBEv2 hashStrings))


{-| V2b: getStringWidth + packed header (opportunities #1 + #2 combined).
-}
enc_string_v2b : () -> Bytes
enc_string_v2b () =
    BE.encode (BE.sequence (List.map V2.stringBEv2b hashStrings))



-- ============================================================================
-- 2. HEADER PACKING
-- ============================================================================


{-| V1: current header (sequence of two U8 for 24–255 args).
-}
enc_header_v1 : () -> Bytes
enc_header_v1 () =
    BE.encode (BE.sequence (List.map V2.bytesWithHeaderV1 hashBytesList))


{-| V2: packed header (single U16 for 24–255 args).
-}
enc_header_v2 : () -> Bytes
enc_header_v2 () =
    BE.encode (BE.sequence (List.map V2.bytesWithHeaderV2 hashBytesList))



-- ============================================================================
-- 3. BREAK APPENDING
-- ============================================================================


{-| V1: `++ [break]` with 100 items (O(100) list append).
-}
enc_indef_v1_100 : () -> Bytes
enc_indef_v1_100 () =
    BE.encode (V2.arrayIndefiniteV1 intEncoders100)


{-| V2: nested sequence with 100 items (O(1)).
-}
enc_indef_v2_100 : () -> Bytes
enc_indef_v2_100 () =
    BE.encode (V2.arrayIndefiniteV2 intEncoders100)


{-| V1: `++ [break]` with 1000 items (O(1000) list append).
-}
enc_indef_v1_1000 : () -> Bytes
enc_indef_v1_1000 () =
    BE.encode (V2.arrayIndefiniteV1 intEncoders1000)


{-| V2: nested sequence with 1000 items (O(1)).
-}
enc_indef_v2_1000 : () -> Bytes
enc_indef_v2_1000 () =
    BE.encode (V2.arrayIndefiniteV2 intEncoders1000)



-- ============================================================================
-- 4. CONCATMAP VS FOLDR
-- ============================================================================


{-| V1: map encoding with `List.concatMap` (100 entries).
-}
enc_mapfold_v1_100 : () -> Bytes
enc_mapfold_v1_100 () =
    BE.encode (V2.mapIntV1 mapPairs100)


{-| V2: map encoding with `List.foldr` (100 entries).
-}
enc_mapfold_v2_100 : () -> Bytes
enc_mapfold_v2_100 () =
    BE.encode (V2.mapIntV2 mapPairs100)



-- ============================================================================
-- 5. FLOAT FAST-REJECT GUARD
-- ============================================================================


{-| V1: current float encoding (float16 round-trip always attempted).

Test data is 1000 float64 values > 65504. V1 runs the float16 round-trip
check on every value (always fails), then the float32 check (also fails).

-}
enc_guard_v1 : () -> Bytes
enc_guard_v1 () =
    CE.encode CE.unsorted (CE.list CE.float float64LargeValues)


{-| V2: float encoding with `abs f <= 65504` guard.

For values > 65504, skips the float16 round-trip entirely. Saves one
`DataView` allocation + decode per value.

-}
enc_guard_v2 : () -> Bytes
enc_guard_v2 () =
    CE.encode CE.unsorted (CE.list V2.floatV3 float64LargeValues)
