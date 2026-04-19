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


### Encoder: `Maybe sortKeys` for map key double-encoding

**Result**: map100 pre-built encoding went from 23314 ns to 3139 ns (now 4%
faster than toulouse, was 85% slower). keyed10 construction+serialization went
from 2592 ns to 1009 ns (now 22% faster than toulouse, was 53% slower).

The original `Strategy.sortKeys` was always a function
`List (Bytes, Encoder) -> List (Bytes, Encoder)`. Even with `unsorted`
(where `sortKeys = identity`), the map encoder serialized every key to `Bytes`
to produce the `(keyBytes, entryEncoder)` pairs — then `identity` returned
them unsorted. This double-encoding (serialize key to `Bytes`, then embed
via `BE.bytes keyBytes`) was the dominant cost for unsorted maps.

Changing `sortKeys` to `Maybe (...)` lets the encoder branch:

- `Nothing` (unsorted): encode keys inline via `applyStrategy`, no
  serialization to intermediate `Bytes`.
- `Just sortFn` (deterministic/canonical): serialize keys to `Bytes` for
  comparison and sort — same as before.

Combined with the `Direct` optimization (below), `allDirectPairs` pre-builds
the entry encoder list at construction time when all keys and values are
`Direct`, so the encode-time closure only checks `lengthMode`.

Breaking change: users with custom strategies must wrap their sort function
in `Just`.


### Encoder: `Direct` fast path for strategy-independent encoders

**Result**: list100 pre-built encoding went from 3146 ns to 1428 ns (tl gap
narrowed from 59% to ~13%).

elm-cardano's `Encoder` is a closure `Encoder (Strategy -> BE.Encoder)` to
support configurable strategies (key sorting, length mode). Primitives like
`int` and `bool` ignore the strategy, but still pay for closure dispatch at
`encode` time. A second constructor `Direct BE.Encoder` eliminates this:

```elm
type Encoder
    = Encoder (Strategy -> BE.Encoder)
    | Direct BE.Encoder
```

All primitives (`int`, `float`, `bool`, `null`, `string`, `bytes`, etc.) use
`Direct`, building the `BE.Encoder` tree eagerly at construction time.

**Key insight**: `Direct` on primitives alone gains nothing — containers like
`array` and `sequence` still create `Encoder` closures that dispatch per child
at encode time, replacing closure calls with pattern matches (net zero).
The fix is propagating `Direct` upward through containers:

- `sequence`: if `allDirect`, returns `Direct (BE.sequence ...)` — no closure.
- `tag`: if enclosed is `Direct`, returns `Direct`.
- `array`: if `allDirect`, pre-collects `BE.Encoder` list at construction time.
  Still `Encoder` (needs `lengthMode`), but the closure captures the pre-built
  list — no per-item dispatch at encode time.

`allDirect` is a short-circuiting traversal with no allocation. `list` does not
probe the first element because `a -> Encoder` could vary per value; it
delegates to `array` which checks every element.

Backward-compatible: constructors are opaque.

**Non-Direct path gap**: when elements are `Encoder` (not `Direct`), the fast
path cannot trigger. Pre-built encoders with wrapped elements (e.g. each int
inside a 1-element array) show the inherent strategy dispatch cost:

| Benchmark | ec (ns/run) | tl (ns/run) | Delta |
|---|---:|---:|---|
| list of 100 wrapped ints | 8151 | 2244 | tl 72% faster |
| map of 100 wrapped int pairs | 12187 | 4377 | tl 64% faster |

This gap is the irreducible cost of the `Encoder (Strategy -> BE.Encoder)`
architecture: at encode time, each `Encoder` child requires a pattern match +
closure call + `lengthMode`/`sortKeys` check. Toulouse's pre-built
`Bytes.Encode.Encoder` tree has zero encode-time overhead.


### Encoder micro-optimizations

Five micro-optimizations applied to `Cbor.Encode` internals.

#### 1. String encoding: `getStringWidth` (no intermediate buffer)

The `string` encoder used to encode the full string into a temporary `DataView`
just to measure the UTF-8 byte length, then copy into the final buffer. The
optimized version uses `BE.getStringWidth` (pure arithmetic on character codes)
and writes the string directly — eliminating the intermediate `ArrayBuffer` +
`DataView` allocation, the first `write_string` call, and the `write_bytes`
copy loop.

```
  enc_string_v1    ████████████████████   332129 ns/run   baseline
  enc_string_v2    █████████████          222452 ns/run   33% faster
  enc_string_v2b   ████████████           200625 ns/run   40% faster
```

**V2b adopted** (40% faster). Uses `BE.getStringWidth` + packed header.

#### 2. Header packing: `unsignedInt16` for argument 24-255

For argument values 24-255, the encoder created `BE.sequence [U8, U8]`
(6 heap allocations: 1 Seq + 2 cons + 1 nil + 2 U8). Since these are two
consecutive big-endian bytes, they pack into a single `BE.unsignedInt16`
(1 allocation). This matters for Cardano hashes (28 or 32 bytes), addresses,
and policy IDs which all hit this branch.

```
  enc_header_v1   ████████████████████   82090 ns/run   baseline
  enc_header_v2   ██████████████         58689 ns/run   29% faster
```

**V2 adopted** (29% faster). Packs initial byte + argument into a single `U16`.

#### 3. Break appending: nested sequence vs `++ [break]`

Indefinite-length encoders used `++` to append the break byte (O(N) list
traversal). Wrapping items in a nested `BE.sequence` avoids the traversal
entirely (O(1)). The extra `Seq` node is trivial compared to the O(N) copy.

```
  enc_indef_v1_100    ████████████████████   1095 ns/run    baseline
  enc_indef_v2_100    ██████████████████     976 ns/run     11% faster

  enc_indef_v1_1000   ████████████████████   10159 ns/run   baseline
  enc_indef_v2_1000   ████████████████       8253 ns/run    19% faster
```

**V2 adopted** (11-19% faster). Wraps items in a nested `BE.sequence`.

#### 4. Map entries: `List.foldr` vs `List.concatMap`

`encodeItem CborMap` used `List.concatMap` (N intermediate 2-element lists +
concat). `List.foldr` builds the flat list directly with cons operations.

```
  enc_mapfold_v1_100   ████████████████████   10176 ns/run   baseline
  enc_mapfold_v2_100   █████████████████      8746 ns/run    14% faster
```

**V2 adopted** (14% faster). Builds flat list directly with cons.

#### 5. Float fast-reject: range guard before float16 round-trip

The `float16RoundTrips` check allocates a `DataView`, writes 2 bytes, reads
them back, and compares. For values that can never be float16, a cheap
`abs f <= 65504` guard skips the round-trip entirely (IEEE 754 float16 max is
65504). Special values (NaN, +-Infinity) bypass the guard.

```
  enc_guard_v1   ████████████████████   481971 ns/run   baseline
  enc_guard_v2   ██████████             248229 ns/run   48% faster
```

**V2 adopted** (48% faster). Skips float16 round-trip when `abs f > 65504`.


### Decoder optimizations

Three optimizations applied to `Cbor.Decode` internals, based on the
`Bytes.Decoder` architecture (dual-path: fast `elm/bytes` path +
slow state-passing path for error reporting).

Key insight: `BD.andThen` on the fast path composes via
`Decode.andThen` in the elm/bytes kernel. `BD.succeed v |> BD.andThen f`
allocates an intermediate `Decoder` node just to immediately unwrap it.
Avoiding this on hot paths saves one closure + one `Decode.andThen`
composition per call.

#### 1. Int decoder: `safeArgument` (merged overflow check)

The int decoder had two `andThen` layers: `decodeArgument |> andThen` then
a second `andThen` for the overflow check. But overflow can only happen for
64-bit arguments (`additionalInfo == 27`). `safeArgument` merges both:
for inline/u8/u16/u32, it returns the value directly with no overflow check;
for 64-bit, the check is inside `safeArgument`.

```
  dec_int_v1   ████████████████████   106933 ns/run   baseline
  dec_int_v2   ████████████           62250 ns/run   42% faster
```

**V2 adopted** (42% faster). Merges overflow check into `safeArgument`;
for inline/u8/u16/u32 values, no overflow check needed.

#### 2. String decoder: `withArgument` (fused continuation)

The string decoder used `decodeArgument |> andThen (\len -> BD.string len)`.
For inline lengths (<=23), `decodeArgument` returns `BD.succeed len`, which
allocates an intermediate `Decoder` node just to unwrap it in the next
`andThen`. `withArgument` calls the continuation directly for inline args.

```
  dec_string_v1   ████████████████████   12608 ns/run   baseline
  dec_string_v2   ████████████           7726 ns/run   39% faster
```

**V2 adopted** (39% faster). Calls continuation directly for inline args
instead of `BD.succeed len |> BD.andThen f`.

#### 3. Item decoder: `withArgument` + `BD.repeat`

The item decoder used `decodeArgument |> andThen` + manual `BD.loop` with
tuple state `(remaining, acc)` for definite-length collections. `BD.repeat`
has a dedicated fast path (`repeatFast`) with an optimized
accumulator, eliminating per-iteration tuple allocation.

```
  dec_item_array_v1   ████████████████████   14903 ns/run   baseline
  dec_item_array_v2   ███████████████        11444 ns/run   23% faster

  dec_item_map_v1   ████████████████████   25332 ns/run   baseline
  dec_item_map_v2   ██████████████████     22864 ns/run   10% faster
```

**V2 adopted** (10-23% faster). Uses `withArgument` across all major types
and `BD.repeat` for definite-length arrays and maps.


### Body decoder: `CborDecoder` Item/Pure migration

Replacing `BD.Decoder ctx DecodeError a` with an opaque `CborDecoder ctx a`
type where every decoder receives its initial byte pre-read, enabling
fast-path indefinite-length decoding.

#### Problem

Indefinite-length `array`, `keyValue`, and `foldEntries` used
`BD.oneOf [breakCode, elementDecoder]` to detect the `0xFF` break byte.
But `BD.oneOf` has **no fast path** in `elm-cardano/bytes-decoder` — it
forces the entire loop onto the slow state-passing path.

#### Core type

```elm
type CborDecoder ctx a
    = Item (Int -> BD.Decoder ctx DecodeError a)
    | Pure (BD.Decoder ctx DecodeError a)
```

Every CBOR item decoder is `Item` — a function from initial byte to body
decoder. Non-consuming operations (`succeed`, `fail`) are `Pure`. The
initial byte read is handled at composition boundaries via `toBD`:

```elm
toBD : CborDecoder ctx a -> BD.Decoder ctx DecodeError a
toBD decoder =
    case decoder of
        Item body -> u8 |> BD.andThen body
        Pure bd   -> bd
```

#### Why Item/Pure?

A naive body decoder (only `Item`, no `Pure`) breaks the sum type dispatch
pattern. `succeed Foo` doesn't consume a CBOR item — with only `Item`,
`andThen` always reads a new initial byte for the continuation, wasting a
byte and corrupting the decode position. The `Item`/`Pure` distinction
makes `andThen` dispatch correctly.

#### Key optimization: indefinite-length arrays

```elm
array elementDecoder =
    Item (\initialByte ->
        ...
        if additionalInfo == 31 then
            case elementDecoder of
                Item elementBody ->
                    -- FAST PATH: read byte, check break, dispatch to body
                    BD.loop (\acc ->
                        u8 |> BD.andThen (\byte ->
                            if byte == 0xFF then
                                BD.succeed (BD.Done (List.reverse acc))
                            else
                                elementBody byte
                                    |> BD.map (\v -> BD.Loop (v :: acc))
                        )
                    ) []
                ...
        else
            withArgument additionalInfo
                (\count -> BD.repeat (toBD elementDecoder) count)
    )
```

For `Item` elements, the indefinite loop reads one byte, checks for break,
and calls the body directly. No `BD.oneOf`, stays on the fast `Decode.loop` path.

#### Performance: `toBD` hoisting

When `toBD` appears inside a lambda that runs at decode time, it allocates
a fresh `u8 |> BD.andThen body` decoder on every decode. Hoisting into a
`let` binding computes it once at definition time. Without hoisting, keyed
records are **45% slower** (vs 4% with hoisting).

#### Record builders

The `RecordBuilder` uses `SimpleBuilder` (all `element`, composed via `keep`
at definition time) and `CountedBuilder` (for `optionalElement`, threads
remaining count).

- `SimpleBuilder`: the chain is pre-built before decoding — no `toBD` in
  the common path
- `CountedBuilder`: hoisted `toBD` avoids per-decode allocations
- `KeyedRecordBuilder`: key matching requires `andThen`, so `toBD` hoisting
  (not elimination) is the best optimization available

#### Results

##### Indefinite-length collections

```
indef_array_100    current   ████████████████████   36639 ns/run   baseline
                   ip        ██████                 11416 ns/run   69% faster

indef_map_100      current   ████████████████████   61327 ns/run   baseline
                   ip        ██████                 17351 ns/run   72% faster

indef_fold_10      current   ████████████████████    6370 ns/run   baseline
                   ip        ████████                2610 ns/run   59% faster

indef_nested       current   ████████████████████   23061 ns/run   baseline
                   ip        ████████                8788 ns/run   62% faster
```

##### Cardano patterns with indefinite outer containers

```
indef_cert_20      current   ████████████████████   16906 ns/run   baseline
                   ip        ███████████             9384 ns/run   44% faster

plutus_indef_5     current   ████████████████████    5501 ns/run   baseline
                   ip        █████████████████       4550 ns/run   17% faster
```

##### Definite-length controls (unchanged)

```
def_array_100      current   ████████████████████    5873 ns/run   baseline
                   ip        ████████████████████    5885 ns/run   same

def_map_100        current   ████████████████████   10523 ns/run   baseline
                   ip        ████████████████████   10657 ns/run   same
```

##### Record builders

```
record_10          current   ████████████████████    1180 ns/run   baseline
                   ip        ████████████████         957 ns/run   19% faster

opt_record_10      current   ████████████████████    1195 ns/run   baseline
                   ip        █████████████████████   1255 ns/run   5% slower

keyed_10           current   ████████████████████    1870 ns/run   baseline
                   ip        █████████████████████   1937 ns/run   4% slower
```

**Indefinite-length collections**: 59-72% faster (eliminating `BD.oneOf`
from loops, keeping the fast `Decode.loop` path).

**Cardano patterns**: 17-44% faster for indefinite outer containers.

**Records**: 19% faster with `SimpleBuilder`/`keep` (all `element`).
5% slower with `CountedBuilder` (`optionalElement`). 4% slower for keyed records.

**Definite-length**: Unchanged.


### Encoder API exploration: argument-based vs phantom types

We explored three alternative encoder APIs to compare ergonomics and
performance against `elm-toulouse/cbor` (`tl`):

| Approach | Module | Idea |
|----------|--------|------|
| **Phantom flat** (`ph`) | `PhantomEncode` | Phantom extensible records track pending decisions. Containers require resolved (`Encoder {}`) children. Resolution via pipeline: `\|> PE.unsorted \|> PE.definite`. |
| **Phantom tree** (`pt`) | `PhantomTreeEncode` | Same phantom types, but containers accept unresolved children. A single `\|> PT.definite` walks the subtree resolving all pending decisions. |
| **Argument-based** (`ar`) | `ArgEncode` | No phantom types. `Length` and `Sort comparable` passed directly as arguments: `AE.array AE.Definite [...]`, `AE.map AE.Unsorted AE.Definite [...]`. |

#### API comparison

```elm
-- Phantom flat (ph): pipeline resolution, children must be Encoder {}
PE.map [ ( PE.int 0, PE.array [ PE.int 1 ] |> PE.definite ) ]
    |> PE.unsorted
    |> PE.definite

-- Phantom tree (pt): deferred resolution, one call resolves the subtree
PT.map [ ( PT.int 0, PT.array [ PT.int 1 ] ) ]
    |> PT.unsorted
    |> PT.definite

-- Argument-based (ar): decisions at construction, no resolution step
AE.map AE.Unsorted AE.Definite [ ( AE.int 0, AE.array AE.Definite [ AE.int 1 ] ) ]
```

#### Results: all approaches vs toulouse

| Benchmark | tl (ns) | ph (ns) | pt (ns) | ar (ns) |
|-----------|--------:|--------:|--------:|--------:|
| list100 | 6132 | 4548 (26% faster) | 6135 (same) | 4410 (28% faster) |
| map100 | 16571 | 11391 (31% faster) | 12114 (27% faster) | 8820 (47% faster) |
| tuple10 | 593 | 523 (12% faster) | 695 (17% slower) | 515 (13% faster) |
| keyed10 | 970 | 979 (1% slower) | 1047 (8% slower) | 761 (22% faster) |
| nested100 | 31631 | 21148 (33% faster) | 32239 (2% slower) | 20385 (36% faster) |
| list100_mixed | 15861 | 13626 (14% faster) | 20220 (27% slower) | 12994 (18% faster) |
| map100_mixed | 25625 | 20525 (20% faster) | 30248 (18% slower) | 17156 (33% faster) |

#### Results: argument-based vs phantom flat (head-to-head)

| Benchmark | ar vs ph |
|-----------|----------|
| list100 | 3% faster |
| map100 | **17% faster** |
| tuple10 | 2% faster |
| keyed10 | **20% faster** |
| nested100 | 4% faster |
| list100_mixed | 2% faster |
| map100_mixed | **14% faster** |

#### Analysis

**Argument-based wins on all counts.** It is the fastest approach across
every benchmark, the simplest implementation (single `Encoder` constructor,
no phantom types, no `coerce`, no multi-step state machine), and arguably
the best ergonomics (one function call per container, decisions are explicit).

The map benchmarks show the largest `ar` vs `ph` gains (14-20%) because
`PhantomEncode` routes maps through multiple intermediate constructors
(`MapNeedsBoth` → `MapNeedsLength` → `Resolved`) while `ArgEncode` builds
the `BE.Encoder` directly in a single `map` call.

The phantom tree approach suffers from tree-walk overhead during resolution.
An `allLeaf` early-exit optimization brought it to parity with toulouse on
homogeneous collections, but it remains slower on mixed/nested structures.
Pre-resolving inner containers (matching the flat phantom pattern) recovers
performance, but at that point the phantom machinery adds no value.

**Key insight**: users can surface the `Sort` and `Length` parameters in
their own encoder functions for flexibility:

```elm
encodeMyRecord : AE.Length -> MyRecord -> AE.Encoder
encodeMyRecord len r =
    AE.array len [ AE.int r.x, AE.string r.name ]
```

This provides the same composability as phantom types without the complexity.
