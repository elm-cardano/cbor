# Encoder Performance Opportunities

Analysis of remaining optimization opportunities in `Cbor.Encode`, based on
the `elm/bytes` kernel internals and V8 runtime characteristics.

For context, `BE.encode` works in two passes over the encoder tree:
1. **Width pass** — `getWidths` recursively sums all encoder sizes to compute
   the total byte count.
2. **Write pass** — `write`/`writeSequence` traverses the tree again, writing
   each value into a pre-allocated `DataView`.

Every `BE.sequence [a, b]` allocates a `Seq` constructor + a linked list
(2 cons cells + nil). Every `BE.encode` allocates a new `ArrayBuffer` + `DataView`.


## 1. String encoding: avoid intermediate buffer allocation

**Impact: HIGH**

The `string` encoder encodes the full string into a temporary `DataView` just
to measure the UTF-8 byte length, then copies those bytes into the final buffer:

```elm
-- Current implementation
string s =
    Encoder (\_ ->
        let
            encoded = BE.encode (BE.string s)  -- allocate DataView, write string
            len = Bytes.width encoded
        in
        BE.sequence [ encodeHeader 3 len, BE.bytes encoded ]  -- copy bytes again
    )
```

But `elm/bytes` exposes `getStringWidth` which computes the UTF-8 byte length
without encoding:

```elm
-- Proposed
string s =
    Encoder (\_ ->
        let len = BE.getStringWidth s
        in BE.sequence [ encodeHeader 3 len, BE.string s ]
    )
```

This eliminates:
- Intermediate `ArrayBuffer` + `DataView` allocation
- The first `write_string` call (into the temporary buffer)
- The `write_bytes` copy loop (from temporary to final buffer)

Trade-off: `getStringWidth` is called twice (once by us, once inside
`BE.string`), but it's pure arithmetic on character codes — no allocation.

The same pattern appears in `encodeStringChunk` and
`encodeItem` for `CborString` / `CborStringChunked`.


## 2. `encodeHeader` for argument 24–255: pack into `unsignedInt16`

**Impact: MEDIUM**

For argument values 24–255, the current code creates a 2-element list
and a `Seq` node — 6 heap allocations to write 2 bytes:

```elm
-- Current: Seq + [U8, U8] = 1 Seq + 2 cons + 1 nil + 2 U8 = 6 allocations
BE.sequence [ BE.unsignedInt8 (mt + 24), BE.unsignedInt8 argument ]
```

These are two consecutive big-endian bytes, so they can be packed into a
single `unsignedInt16`:

```elm
-- Proposed: 1 U16 = 1 allocation
BE.unsignedInt16 Bytes.BE (Bitwise.or (Bitwise.shiftLeftBy 8 (mt + 24)) argument)
```

This matters for CBOR byte/text string headers where the payload length is
24–255 bytes. In Cardano, hashes (28 or 32 bytes), addresses, and policy IDs
all hit this branch.

The argument ≤ 23 case is already optimal (single `U8`).
The argument 256–65535 case is 3 bytes — no matching primitive, so it still
needs a sequence.


## 3. `++ [break]` in indefinite-length mode

**Impact: LOW–MEDIUM** (only affects indefinite-length encoding)

Several indefinite-length encoders use `++` to append the break byte,
which traverses the entire list — O(N):

```elm
-- Current
BE.sequence (BE.unsignedInt8 0x9F :: encodedItems ++ [ BE.unsignedInt8 0xFF ])
```

A nested `sequence` avoids the traversal entirely — O(1):

```elm
-- Proposed
BE.sequence [ BE.unsignedInt8 0x9F, BE.sequence encodedItems, BE.unsignedInt8 0xFF ]
```

The extra `Seq` node is trivial (1 allocation vs O(N) list copy).

Affects: `array`, `map`, `bytesChunked`, `stringChunked`,
and `encodeItem` for indefinite-length arrays/maps/byte strings/text strings.


## 4. `List.concatMap` in `encodeItem CborMap`

**Impact: LOW–MEDIUM**

The `CborMap` branch of `encodeItem` uses `List.concatMap`, which allocates
N intermediate 2-element lists and then concatenates them:

```elm
-- Current
List.concatMap (\e -> [ encodeItem e.key, encodeItem e.value ]) entries
```

A `foldr` builds the flat list directly with no intermediate sublists:

```elm
-- Proposed
List.foldr (\e acc -> encodeItem e.key :: encodeItem e.value :: acc) [] entries
```

Same pattern in the indefinite-length `CborMap` branch.


## 5. `encodeFloat`: fast-reject before round-trip

**Impact: LOW** (creative)

The `float16RoundTrips` check allocates a `DataView`, writes 2 bytes, reads
them back, and compares. For values that can never be float16, a cheap numeric
guard can skip this entirely:

```elm
-- Current
if float16RoundTrips f then ...

-- Proposed: skip the round-trip for out-of-range values
if abs f <= 65504 && float16RoundTrips f then ...
```

IEEE 754 float16 can represent values up to 65504. The `abs` + comparison
is a single CPU instruction vs two `DataView` allocations + a decode. This
prevents the allocation for virtually all float32/float64 values.

Edge case: float16 subnormals (tiny values near zero) are within range but
will fail the round-trip anyway, so the guard doesn't hurt them — it just
doesn't help either.

A similar guard could apply to `float32RoundTrips` using the float32 range
(~3.4e38), though the benefit is smaller since float32-range values are more
common.


## 6. Fuse `List.length` + `List.map` in `array`

**Impact: MARGINAL**

The `array` encoder traverses the items list twice — once for `List.map`
(to encode each item) and once for `List.length` (to write the header):

```elm
let encodedItems = List.map (\(Encoder enc) -> enc strategy) items
in BE.sequence (encodeHeader 4 (List.length items) :: encodedItems)
```

A single `foldl` could compute both, but the per-element tuple allocation
may cancel the gain. Worth benchmarking but expected to be marginal.


## Recommendation

Start with **#1** (string encoding) — cleanest win, most real-world impact
in Cardano (addresses, policy IDs, metadata strings). Then **#2** (header
packing for 24–255).
