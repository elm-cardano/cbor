# CBOR Benchmarks

Performance benchmarks for `elm-cardano/cbor`, targeting the key architectural trade-offs documented in [docs/design.md](../docs/design.md).

## Running

Uses [elm-bench](https://github.com/elm-menagerie/elm-bench):

```sh
cd bench
```

### 1. Map key sorting — int keys, 10/100/1000 entries

Measures `compareBytes` cost during sorted map encoding.
`unsorted` = baseline (no sorting); `deterministic`/`canonical` add sort overhead.

```sh
elm-bench -f Bench.enc_map_unsorted_10 -f Bench.enc_map_deterministic_10 -f Bench.enc_map_canonical_10 "()"
elm-bench -f Bench.enc_map_unsorted_100 -f Bench.enc_map_deterministic_100 -f Bench.enc_map_canonical_100 "()"
elm-bench -f Bench.enc_map_unsorted_1000 -f Bench.enc_map_deterministic_1000 -f Bench.enc_map_canonical_1000 "()"
```

### 2. Map key sorting — 32-char string keys, 100 entries

Same as above but with longer keys, highlighting byte-comparison scaling.

```sh
elm-bench -f Bench.enc_map_unsorted_str100 -f Bench.enc_map_deterministic_str100 -f Bench.enc_map_canonical_str100 "()"
```

### 3. Direct combinators vs item escape hatch

Validates the core "Performance Rationale" claim: direct combinators skip the intermediate `CborItem` tree.

```sh
elm-bench -f Bench.dec_direct_array100 -f Bench.dec_item_array100 "()"
elm-bench -f Bench.enc_direct_list100 -f Bench.enc_item_list100 "()"
```

### 4. Float shortest-form detection

The encoder tries float16, then float32, then float64 (up to 3 roundtrip checks per float).

```sh
elm-bench -f Bench.enc_float_f16_1000 -f Bench.enc_float_f32_1000 -f Bench.enc_float_f64_1000 -f Bench.enc_float_explicit64_1000 "()"
```

### 5. oneOf backtracking — flat

5-branch `oneOf` matching the `plutus_data` dispatch pattern.
`first` hits branch 1 (no backtracking); `last` hits branch 5 (4 failed attempts).

```sh
elm-bench -f Bench.dec_oneOf_flat_first -f Bench.dec_oneOf_flat_last "()"
```

### 6. oneOf backtracking — nested

Recursive 5-branch `oneOf` on nested arrays wrapping an int.
Each nesting level adds 2 backtracks (constr + map fail before array matches).

```sh
elm-bench -f Bench.dec_oneOf_nested_1 -f Bench.dec_oneOf_nested_5 -f Bench.dec_oneOf_nested_10 "()"
```

### 7. Record builder scaling (CBOR arrays)

`builder` = `CD.record` + `CD.element` pipeline (tracks remaining counter).
`manual` = `CD.arrayHeader` + `BD.keep` pipeline (no counter).

```sh
elm-bench -f Bench.dec_record_3_builder -f Bench.dec_record_3_manual "()"
elm-bench -f Bench.dec_record_10_builder -f Bench.dec_record_10_manual "()"
elm-bench -f Bench.dec_record_30_array "()"
```

### 8. Keyed record builder scaling (CBOR maps)

`builder` = `CD.keyedRecord` + `CD.required` pipeline (pendingKey state).
`fold` = `CD.foldEntries` (simple accumulator loop).
`keyValue` = `CD.keyValue` (pair decoder loop).

```sh
elm-bench -f Bench.dec_keyed_3_builder -f Bench.dec_keyed_3_fold "()"
elm-bench -f Bench.dec_keyed_10_builder -f Bench.dec_keyed_10_fold "()"
elm-bench -f Bench.dec_keyed_30_keyValue -f Bench.dec_keyed_30_fold "()"
```


### 9. String encoding — avoid intermediate buffer

V1 encodes the string to a temporary `Bytes` to measure UTF-8 length,
then copies. V2 uses `BE.getStringWidth` and writes directly. V2b adds
packed header (#2) on top.

```sh
elm-bench -f BenchOptimize.enc_string_v1 -f BenchOptimize.enc_string_v2 -f BenchOptimize.enc_string_v2b "()"
```

### 10. Header packing for argument 24–255

For CBOR headers with argument 24–255 (e.g. 32-byte hashes), V1 emits
`sequence [U8, U8]` (6 allocations). V2 packs into a single `U16` (1 allocation).

```sh
elm-bench -f BenchOptimize.enc_header_v1 -f BenchOptimize.enc_header_v2 "()"
```

### 11. Break appending — `++ [break]` vs nested sequence

In indefinite-length mode, V1 appends the break byte with `++` (O(N)).
V2 wraps items in a nested `sequence` (O(1)).

```sh
elm-bench -f BenchOptimize.enc_indef_v1_100 -f BenchOptimize.enc_indef_v2_100 "()"
elm-bench -f BenchOptimize.enc_indef_v1_1000 -f BenchOptimize.enc_indef_v2_1000 "()"
```

### 12. Map entries — `List.concatMap` vs `List.foldr`

In `encodeItem CborMap`, V1 uses `List.concatMap` (N intermediate 2-element
lists). V2 uses `List.foldr` (direct cons).

```sh
elm-bench -f BenchOptimize.enc_mapfold_v1_100 -f BenchOptimize.enc_mapfold_v2_100 "()"
```

### 13. Float fast-reject — range guard before float16 round-trip

V1 always runs the float16 round-trip check. V2 skips it when
`abs f > 65504` (float16 max). Test data: large float64 values.

```sh
elm-bench -f BenchOptimize.enc_guard_v1 -f BenchOptimize.enc_guard_v2 "()"
```


## Optimization results

### Key sorting: `compareBytes` (V1 -> V5)

The original byte comparison (`V1`) used `byteAt i` which creates a fresh
`DataView` per byte position, making each comparison O(K^2) where K is
key byte length. We benchmarked four alternatives:

| Strategy | Approach |
|----------|----------|
| V1 (original) | `byteAt i` per position, O(K^2) per comparison |
| V2 | Decode keys to `List Int`, sort with `List.sortBy` |
| V3 | Decode bytes to `String` via `Char.fromCode`, sort by string |
| V5 | Convert to hex string via `Hex.fromBytes`, sort by string |

#### Int keys (1-3 bytes), 100 entries

```
  enc_v1_map_int100   ████████████████████   54593 ns/run   baseline
  enc_v2_map_int100   ████████████████       44945 ns/run   18% faster
  enc_v3_map_int100   ███████████████████    53029 ns/run   3% faster
  enc_v5_map_int100   █████████████████      45217 ns/run   17% faster
```

#### Int keys (1-3 bytes), 1000 entries

```
  enc_v1_map_int1000   ████████████████████   699164 ns/run   baseline
  enc_v2_map_int1000   ███████████████        518449 ns/run   26% faster
  enc_v3_map_int1000   ██████████████████     618659 ns/run   12% faster
  enc_v5_map_int1000   ███████████████        517822 ns/run   26% faster
```

#### String keys (33 bytes), late diff (worst case), 100 entries

Keys share a long common prefix (`padLeft`), differing only at the end.

```
  enc_v1_map_str100   ████████████████████   533664 ns/run   baseline
  enc_v2_map_str100   ████████               218478 ns/run   59% faster
  enc_v3_map_str100   ██████████             255839 ns/run   52% faster
  enc_v5_map_str100   █████                  141493 ns/run   73% faster
```

#### String keys (33 bytes), early diff (best case), 100 entries

Keys differ in the first bytes (`padRight`), so comparison short-circuits.

```
  enc_v1_map_str100_early   ████████████████████   329639 ns/run   baseline
  enc_v2_map_str100_early   █████████████          215514 ns/run   35% faster
  enc_v3_map_str100_early   ████████████████       264535 ns/run   20% faster
  enc_v5_map_str100_early   █████████              144224 ns/run   56% faster
```

**V5 (hex string) wins across all scenarios** (17-73% faster).
Adopted as the new default for `deterministic`, `canonical`, and `ctap2`.


### Float detection order: V1 kept

| Strategy | Order | Checks for f16 | Checks for f32 | Checks for f64 |
|----------|-------|-----------------|-----------------|-----------------|
| V1 (current) | f16 -> f32 -> f64 | 1 | 2 | 2 |
| V2 | f32 -> f16 -> f64 | 2 | 2 | 1 |

```
  enc_v1_float_f16   ████████████████████   313838 ns/run   baseline
  enc_v2_float_f16   ██████████████████████████████   473960 ns/run   51% slower

  enc_v1_float_f64   ████████████████████   492618 ns/run   baseline
  enc_v2_float_f64   ██████████             247375 ns/run   50% faster
```

Symmetric trade-off (~50% each way). **V1 kept** — small integers
(float16-representable) are common in Cardano CBOR data.


### Encoder optimizations (opportunities 1–5)

Five micro-optimizations applied to `Cbor.Encode` internals.

#### 1. String encoding: `getStringWidth` (no intermediate buffer)

```
  enc_string_v1    ████████████████████   332129 ns/run   baseline
  enc_string_v2    █████████████          222452 ns/run   33% faster
  enc_string_v2b   ████████████           200625 ns/run   40% faster
```

**V2b adopted** (40% faster). Uses `BE.getStringWidth` + packed header.

#### 2. Header packing: `unsignedInt16` for argument 24–255

```
  enc_header_v1   ████████████████████   82090 ns/run   baseline
  enc_header_v2   ██████████████         58689 ns/run   29% faster
```

**V2 adopted** (29% faster). Packs initial byte + argument into a single `U16`.

#### 3. Break appending: nested sequence vs `++ [break]`

```
  enc_indef_v1_100    ████████████████████   1095 ns/run    baseline
  enc_indef_v2_100    ██████████████████     976 ns/run     11% faster

  enc_indef_v1_1000   ████████████████████   10159 ns/run   baseline
  enc_indef_v2_1000   ████████████████       8253 ns/run    19% faster
```

**V2 adopted** (11-19% faster). Wraps items in a nested `BE.sequence`.

#### 4. Map entries: `List.foldr` vs `List.concatMap`

```
  enc_mapfold_v1_100   ████████████████████   10176 ns/run   baseline
  enc_mapfold_v2_100   █████████████████      8746 ns/run    14% faster
```

**V2 adopted** (14% faster). Builds flat list directly with cons.

#### 5. Float fast-reject: range guard before float16 round-trip

```
  enc_guard_v1   ████████████████████   481971 ns/run   baseline
  enc_guard_v2   ██████████             248229 ns/run   48% faster
```

**V2 adopted** (48% faster). Skips float16 round-trip when `abs f > 65504`.
Special values (NaN, ±Infinity) bypass the guard.
