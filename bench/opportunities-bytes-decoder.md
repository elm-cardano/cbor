# Bytes.Decoder Improvement Opportunities

Primitives that would enable fast-path indefinite-length CBOR decoding
directly, without the body decoder (`CborDecoder`) wrapper pattern.

All three proposals target the same problem: `BD.oneOf` has no fast path,
so any loop using `oneOf` for break detection runs entirely on the slow
state-passing path. These primitives would keep the loop on the fast
`Decode.loop` kernel path.


## 1. `peekU8` — peek without consuming

Read the byte at the current offset without advancing.

### API

```elm
peekU8 : Decoder context error Int
```

### Fast-path implementation

Requires a kernel-level `Decode.Decoder` that reads one byte but reports
a width of 0 (so the runtime doesn't advance the offset):

```js
// In Bytes.Decode kernel
var _Bytes_decode_peekU8 = F2(function(bytes, offset) {
    return _Utils_Tuple2(
        offset,  // don't advance
        new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
            .getUint8(offset)
    );
});
```

Then in `Bytes.Decoder`:

```elm
peekU8 : Decoder context error Int
peekU8 =
    Decoder
        (Just _Bytes_Decode_peekU8)
        (\state ->
            if state.offset < Bytes.width state.input then
                Good (byteAt state.offset state.input) state  -- same state, no advance
            else
                Bad (OutOfBounds { at = state.offset, bytes = Bytes.width state.input })
        )
```

### Usage in Cbor.Decode

```elm
array : BD.Decoder ctx DecodeError a -> BD.Decoder ctx DecodeError (List a)
array elementDecoder =
    u8
        |> BD.andThen
            (\initialByte ->
                ...
                if additionalInfo == 31 then
                    BD.loop
                        (\acc ->
                            BD.peekU8
                                |> BD.andThen
                                    (\byte ->
                                        if byte == 0xFF then
                                            BD.skip 1
                                                |> BD.map (\_ -> BD.Done (List.reverse acc))

                                        else
                                            elementDecoder
                                                |> BD.map (\v -> BD.Loop (v :: acc))
                                    )
                        )
                        []
                ...
            )
```

The byte is read twice (peek + elementDecoder's internal `u8`), but the
entire loop stays on the fast `Decode.loop` kernel path. The double read
is a single `DataView.getUint8` call — negligible cost compared to the
fast-path vs slow-path difference.

### Impact

**HIGH**. The simplest primitive that solves the problem. One kernel
function, one new decoder. No changes to existing decoders. Also useful
beyond CBOR — any format with sentinel-terminated sequences benefits.


## 2. `breakOr` — try break, otherwise run decoder

Specialized combinator for the CBOR break-or-continue pattern.

### API

```elm
breakOr : Decoder context error a -> Decoder context error (Maybe a)
```

Semantics:
- Peek at the next byte.
- If `0xFF`: consume it, return `Nothing`.
- Otherwise: run the inner decoder (which reads its own initial byte),
  return `Just value`.

### Fast-path implementation

```elm
breakOr : Decoder context error a -> Decoder context error (Maybe a)
breakOr (Decoder maybeDec slow) =
    Decoder
        (Maybe.map
            (\dec ->
                Decode.unsignedInt8
                    |> Decode.andThen
                        (\byte ->
                            if byte == 0xFF then
                                Decode.succeed Nothing
                            else
                                -- Problem: byte consumed, but dec wants to read it too.
                                -- Need peekU8 or a way to "push back" the byte.
                                ???
                        )
            )
            maybeDec
        )
        (...)
```

Without `peekU8`, `breakOr` can't have a fast path. With `peekU8`:

```elm
breakOr (Decoder maybeDec slow) =
    Decoder
        (Maybe.map
            (\dec ->
                _Bytes_Decode_peekU8
                    |> Decode.andThen
                        (\byte ->
                            if byte == 0xFF then
                                Decode.map (\_ -> Nothing) (Decode.bytes 1)  -- consume break
                            else
                                Decode.map Just dec
                        )
            )
            maybeDec
        )
        (...)
```

Alternatively, implement `breakOr` as a single kernel primitive that
fuses the peek + branch + optional skip:

```js
var _Bytes_decode_breakOr = function(decoder) {
    return F2(function(bytes, offset) {
        var byte = new DataView(...).getUint8(offset);
        if (byte === 0xFF) {
            return _Utils_Tuple2(offset + 1, $elm$core$Maybe$Nothing);
        } else {
            var result = A2(decoder, bytes, offset);
            return _Utils_Tuple2(result.a, $elm$core$Maybe$Just(result.b));
        }
    });
};
```

### Usage in Cbor.Decode

```elm
array elementDecoder =
    ...
    if additionalInfo == 31 then
        BD.loop
            (\acc ->
                BD.breakOr elementDecoder
                    |> BD.map
                        (\result ->
                            case result of
                                Nothing ->
                                    BD.Done (List.reverse acc)

                                Just v ->
                                    BD.Loop (v :: acc)
                        )
            )
            []
    ...
```

### Impact

**HIGH**. Cleaner API than `peekU8` + manual branching. But requires
`peekU8` internally (or a fused kernel primitive). If `peekU8` is added
first, `breakOr` can be built on top without additional kernel changes.


## 3. `loopUntilBreak` — fully fused indefinite-length loop

A single combinator that handles the entire break-terminated loop pattern.

### API

```elm
loopUntilBreak : Decoder context error a -> Decoder context error (List a)
```

Semantics: peek at byte; if `0xFF` consume it and return the accumulated
list; otherwise run the element decoder and continue looping.

### Fast-path implementation

Fully fused in the kernel — no per-iteration `BD.andThen` / `BD.map`
composition overhead:

```js
var _Bytes_decode_loopUntilBreak = function(decoder) {
    return F2(function(bytes, offset) {
        var view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        var acc = _List_Nil;
        while (true) {
            if (offset >= bytes.byteLength) return _Bytes_decodeFailure;
            var byte = view.getUint8(offset);
            if (byte === 0xFF) {
                offset++;
                return _Utils_Tuple2(offset, _List_reverse(acc));
            }
            var result = A2(decoder, bytes, offset);
            offset = result.a;
            acc = _List_Cons(result.b, acc);
        }
    });
};
```

The Elm wrapper:

```elm
loopUntilBreak : Decoder context error a -> Decoder context error (List a)
loopUntilBreak (Decoder maybeDec slow) =
    Decoder
        (Maybe.map _Bytes_decode_loopUntilBreak maybeDec)
        (\state -> loopUntilBreakSlow slow state [])


loopUntilBreakSlow : (State -> DecodeResult ctx err a) -> State -> List a -> DecodeResult ctx err (List a)
loopUntilBreakSlow slow state acc =
    if byteAt state.offset state.input == 0xFF then
        Good (List.reverse acc) { state | offset = state.offset + 1 }
    else
        case slow state of
            Good v newState ->
                loopUntilBreakSlow slow newState (v :: acc)
            Bad e ->
                Bad e
```

### Usage in Cbor.Decode

```elm
array elementDecoder =
    ...
    if additionalInfo == 31 then
        BD.loopUntilBreak elementDecoder
    ...
```

### Impact

**HIGHEST**. Zero per-iteration combinator overhead on the fast path —
the break check, element decode, accumulation, and `List.reverse` all
happen inside a tight JS `while` loop. But it's the most invasive change
(custom kernel function) and the most CBOR-specific (the `0xFF` break
byte is hardcoded).


## Recommendation

Start with **#1 (`peekU8`)** — it's the simplest kernel change, solves
the core problem, and is useful beyond CBOR. Then consider **#2
(`breakOr`)** as a convenience built on top. Reserve **#3
(`loopUntilBreak`)** for if benchmarks show that per-iteration combinator
overhead is still significant after #1.

All three can coexist; they target different levels of abstraction.
