# Decoder Performance Opportunities

Analysis of optimization opportunities in `Cbor.Decode`, based on
the `Bytes.Decoder` kernel internals (dual-path architecture: fast
`elm/bytes` path + slow state-passing path for error reporting).

Key kernel insight: `BD.andThen` on the fast path composes via
`Decode.andThen` in the elm/bytes kernel. `BD.succeed v |> BD.andThen f`
allocates an intermediate `Decoder` node just to immediately unwrap it.
Avoiding this pattern on hot paths saves one closure + one `Decode.andThen`
composition per call.


## 1. Fuse `decodeArgument` + `andThen` — eliminate intermediate decoder

**Impact: HIGH**

Every typed decoder (int, string, bytes, array, map, tag) follows this pattern:

```elm
decodeArgument additionalInfo
    |> BD.andThen (\len -> BD.string len)
```

For the most common case (additionalInfo <= 23, inline values),
`decodeArgument` returns `BD.succeed additionalInfo`, so the fast path builds:

```
Decode.andThen (\len -> ...) (Decode.succeed 23)
```

This allocates an intermediate `Decoder` to carry the value 23, only to
immediately unwrap it in the next `andThen`. A fused helper eliminates this:

```elm
withArgument : Int -> (Int -> BD.Decoder ctx DecodeError a) -> BD.Decoder ctx DecodeError a
withArgument additionalInfo f =
    if additionalInfo <= 23 then
        f additionalInfo  -- direct call, no intermediate Decoder
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
```

For inline arguments (the common case), this calls `f` directly instead of
going through `BD.succeed` + `BD.andThen`. For multi-byte arguments, it
behaves identically to the current code.

This affects: `int`, `bigInt`, `string`, `bytes`, `array`, `keyValue`,
`foldEntries`, `tag`, `arrayHeader`, `mapHeader`, and every branch of `item`.


## 2. Merge overflow check into `int` — remove second `andThen`

**Impact: HIGH**

The current `int` decoder has two `andThen` calls:

```elm
-- Current
int =
    u8
        |> BD.andThen (\initialByte ->
            ...
            if majorType == 0 then
                decodeArgument additionalInfo          -- andThen #1
                    |> BD.andThen (\n ->               -- andThen #2
                        if n > maxSafeInt then
                            BD.fail IntegerOverflow
                        else
                            BD.succeed n
                    )
            ...
        )
```

But overflow can only happen for 64-bit arguments (additionalInfo == 27).
For all other cases (inline 0-23, u8, u16, u32), the value is always
well below 2^52. Combined with opportunity #1, a specialized helper
handles both concerns:

```elm
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
            |> BD.andThen (\n ->
                if n > maxSafeInt then
                    BD.fail IntegerOverflow
                else
                    BD.succeed n
            )
    else
        BD.fail (ReservedAdditionalInfo additionalInfo)
```

Then `int` simplifies to a single `andThen`:

```elm
-- Proposed
int =
    u8
        |> BD.andThen (\initialByte ->
            let
                majorType = Bitwise.shiftRightZfBy 5 initialByte
                additionalInfo = Bitwise.and 0x1F initialByte
            in
            if majorType == 0 then
                safeArgument additionalInfo
            else if majorType == 1 then
                safeArgument additionalInfo
                    |> BD.map (\n -> -1 - n)
            else
                BD.fail (WrongMajorType { expected = 0, got = majorType })
        )
```

For small integers (the dominant case in Cardano — map keys, array lengths,
enum values), this removes one `andThen` + one closure allocation from the
fast path. The overflow check moves to the only branch where it matters.


## 3. Use `BD.repeat` in `item` decoder for definite-length collections

**Impact: MEDIUM**

The `item` decoder uses manual `BD.loop` with tuple state for
definite-length arrays and maps:

```elm
-- Current (arrays)
decodeArgument additionalInfo
    |> BD.andThen (\count ->
        BD.loop
            (\( remaining, acc ) ->
                if remaining <= 0 then
                    BD.succeed (BD.Done (CborArray Definite (List.reverse acc)))
                else
                    item |> BD.map (\v -> BD.Loop ( remaining - 1, v :: acc ))
            )
            ( count, [] )
    )
```

`BD.repeat` has a dedicated fast path (`repeatFast` in the kernel) that
uses `Decode.loop` directly with its own optimized accumulator:

```elm
-- Proposed (arrays)
decodeArgument additionalInfo
    |> BD.andThen (\count -> BD.repeat item count)
    |> BD.map (\items -> CborArray Definite items)
```

```elm
-- Proposed (maps)
decodeArgument additionalInfo
    |> BD.andThen (\count ->
        BD.repeat (BD.map2 (\k v -> { key = k, value = v }) item item) count
    )
    |> BD.map (\entries -> CborMap Definite entries)
```

This eliminates the per-iteration `( remaining - 1, v :: acc )` tuple
allocation. The `List.reverse` and count tracking are handled inside
`BD.repeat`'s kernel implementation.

Same pattern applies to `decodeArgument64` usage in the 64-bit branches,
though those are rare.


## Recommendation

Start with **#2** (merge overflow check + safeArgument) — it's the
cleanest win and integers are the most decoded type in Cardano CBOR.
Then **#1** (withArgument fusion) across all other decoders. Then **#3**
(BD.repeat in item).
