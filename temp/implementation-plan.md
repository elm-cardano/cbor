# Elm CBOR Implementation Plan: Three Decoder Approaches

## Goal

Implement a CBOR encoder + three decoder variants to empirically measure the performance/error-quality tradeoff. All three decoders share the same public API (types, function names) so benchmarks and tests are directly comparable.

---

## 1. Project Structure

```
src/
  Cbor.elm                          -- Shared types: CborItem, Tag, MajorType
  Cbor/Tag.elm                      -- Tag enum + encode/decode helpers
  Cbor/Encode.elm                   -- Encoder (shared, single implementation)
  Cbor/Decode.elm                   -- "Blessed" decoder (TBD after benchmarks)
  Cbor/Decode/Raw.elm               -- Approach 1: raw elm/bytes
  Cbor/Decode/Erroring.elm          -- Approach 2: zwilias-style, rich errors
  Cbor/Decode/Branchable.elm        -- Approach 3: mpizenberg-style, pass-through
  Cbor/Decode/Error.elm             -- Error types for Erroring (rich) and Branchable (approximate)
  Bytes/Decode/Branchable.elm       -- Low-level branchable byte decoder (mpizenberg-style, with State)
  Bytes/Decode/Erroring.elm         -- Low-level erroring byte decoder (zwilias-style)

tests/
  TestVectors.elm                   -- RFC 8949 Appendix A hex/value pairs
  Cbor/EncodeTests.elm              -- Encoder tests
  Cbor/Decode/RawTests.elm          -- Tests for approach 1
  Cbor/Decode/ErroringTests.elm     -- Tests for approach 2
  Cbor/Decode/BranchableTests.elm   -- Tests for approach 3
  Cbor/Decode/SharedTests.elm       -- Shared test logic, parameterized

benchmarks/
  src/Main.elm                      -- Benchmark runner
  src/Benchmarks/Decode.elm         -- Comparative decode benchmarks
  src/Benchmarks/Encode.elm         -- Encode benchmarks (baseline)
```

---

## 2. Shared Types (`Cbor.elm`, `Cbor/Tag.elm`)

### `Cbor.elm`

```elm
type CborItem
    = CborInt Int
    | CborInt64 ( Int, Int )          -- (msb, lsb) for > 2^53
    | CborBytes Bytes
    | CborString String
    | CborList (List CborItem)
    | CborMap (List ( CborItem, CborItem ))
    | CborTag Tag CborItem
    | CborBool Bool
    | CborFloat Float
    | CborNull
    | CborUndefined

type Sign = Positive | Negative
```

### `Cbor/Tag.elm`

```elm
type Tag
    = StandardDateTime       -- 0
    | EpochDateTime          -- 1
    | PositiveBigNum         -- 2
    | NegativeBigNum         -- 3
    | DecimalFraction        -- 4
    | BigFloat               -- 5
    | Cbor                   -- 24
    | Uri                    -- 32
    | IsCbor                 -- 55799
    | Unknown Int            -- anything else
```

---

## 3. Encoder (`Cbor/Encode.elm`)

Single implementation, shared by all approaches. Encoding cannot fail, so there's no error/performance tradeoff.

### API

```elm
type Encoder

encode : Encoder -> Bytes

-- Primitives
bool : Bool -> Encoder
int : Int -> Encoder
float : Float -> Encoder          -- auto-shrinks to smallest lossless IEEE 754
float16 : Float -> Encoder
float32 : Float -> Encoder
float64 : Float -> Encoder
string : String -> Encoder
bytes : Bytes -> Encoder
null : Encoder
undefined : Encoder

-- Collections
list : (a -> Encoder) -> List a -> Encoder
dict : (k -> Encoder) -> (v -> Encoder) -> Dict k v -> Encoder
keyValue : List ( Encoder, Encoder ) -> Encoder    -- heterogeneous map

-- Tags
tag : Tag -> Encoder
tagged : Tag -> Encoder -> Encoder

-- Streaming / indefinite-length
beginList : Encoder
beginDict : Encoder
beginString : Encoder
beginBytes : Encoder
break : Encoder

-- Records (map-based with string keys)
record : RecordEncoder a -> a -> Encoder
-- Tuples (array-based, positional)
tuple : TupleEncoder a -> a -> Encoder

-- Low-level
sequence : List Encoder -> Encoder
any : CborItem -> Encoder
raw : Bytes -> Encoder
```

### Internal Encoding Strategy

- `Encoder` wraps `Bytes.Encode.Encoder` (same as elm-toulouse)
- `majorType : Int -> Int -> Encoder` combines 3-bit major + 5-bit additional info
- `unsigned : Int -> Encoder` emits the variable-length argument (0-8 extra bytes)
- Float auto-shrink: try float16 first (if lossless), then float32, then float64
- `sequence` concatenates encoders via `Bytes.Encode.sequence`

---

## 4. Three Decoder Approaches

All three expose the **same CBOR-level API** (same function names, same type signatures where possible). The difference is in:
- The `Decoder` type definition
- The return type of `decode` (`Maybe a` vs `Result Error a`)
- The internal mechanism

### Common CBOR Decoder API

```elm
-- Running (Raw returns Maybe; Erroring and Branchable return Result with different Error types)
decode : Decoder a -> Bytes -> {Maybe a | Result Error a}

-- Primitives
bool : Decoder Bool
int : Decoder Int
bigint : Decoder ( Sign, Bytes )
float : Decoder Float
string : Decoder String
bytes : Decoder Bytes

-- Collections
list : Decoder a -> Decoder (List a)
dict : Decoder comparable -> Decoder v -> Decoder (Dict comparable v)
associativeList : Decoder k -> Decoder v -> Decoder (List ( k, v ))

-- Records & Tuples
record : builder -> Decoder builder        -- begins map, returns builder
field : String -> Decoder a -> Decoder (a -> b) -> Decoder b
optionalField : String -> Decoder a -> Decoder (Maybe a -> b) -> Decoder b
tuple : builder -> Decoder builder         -- begins array, returns builder
elem : Decoder a -> Decoder (a -> b) -> Decoder b
optionalElem : Decoder a -> Decoder (Maybe a -> b) -> Decoder b

-- Tags
tag : Decoder Tag
tagged : Decoder a -> Decoder ( Tag, a )

-- Combinators
succeed : a -> Decoder a
fail : Decoder a
map : (a -> b) -> Decoder a -> Decoder b
map2 : (a -> b -> c) -> Decoder a -> Decoder b -> Decoder c
map3-5 : ...
andThen : (a -> Decoder b) -> Decoder a -> Decoder b
oneOf : List (Decoder a) -> Decoder a
keep : Decoder a -> Decoder (a -> b) -> Decoder b
ignore : Decoder x -> Decoder a -> Decoder a

-- Streaming
beginString : Decoder (List String -> a) -> Decoder a
beginBytes : Decoder (List Bytes -> a) -> Decoder a
beginList : Decoder a -> Decoder (List a)
beginDict : Decoder k -> Decoder v -> Decoder (List (k, v))

-- Looping
type Step state a = Loop state | Done a
loop : state -> (state -> Decoder (Step state a)) -> Decoder a
fold : (k -> v -> acc -> acc) -> acc -> Decoder k -> Decoder v -> Decoder acc

-- Debugging
any : Decoder CborItem
raw : Decoder Bytes
```

---

### 4.1 Approach 1: Raw elm/bytes (`Cbor/Decode/Raw.elm`)

**Internal architecture:**

```elm
-- Re-export elm/bytes decoder directly
type alias Decoder a = Bytes.Decode.Decoder a

decode : Decoder a -> Bytes -> Maybe a
decode = Bytes.Decode.decode
```

**CBOR dispatch pattern (no wrapping):**

```elm
int : Decoder Int
int =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen (\byte ->
            let major = Bitwise.shiftRightBy 5 byte
                info  = Bitwise.and 0x1F byte
            in
            if major == 0 then
                unsigned info
            else if major == 1 then
                unsigned info |> Bytes.Decode.map (\n -> negate n - 1)
            else
                Bytes.Decode.fail
        )
```

**`oneOf` implementation:**

elm/bytes has no built-in `oneOf`. We have two options:

- **(a) No `oneOf` at all.** CBOR is self-describing, so `andThen` dispatch on the initial byte covers most cases. For the rare case where you want "int or string key", users compose via `andThen` on `any` and then pattern-match.

- **(b) Vendored peek-based `oneOf`.** Use the elm-toulouse trick: peek at the initial byte (without consuming), try to match each alternative's expected major type. This avoids backtracking entirely — the peek is a single extra byte read. But this limits `oneOf` to dispatching on the first byte only, not arbitrary lookahead. For CBOR, this is sufficient.

**We choose (b)** — peek-based dispatch. This requires a minimal shim: a `peek` that reads one byte without advancing. We can implement this by wrapping in a thin state tracker only for `oneOf`, or by using the pattern from elm-toulouse where `oneOf` builds a Branchable decoder internally.

Actually, for a truly "raw" baseline, we go with **(a)**: no `oneOf`. Provide a `peekAndThen` combinator instead:

```elm
-- Read the initial byte, dispatch without consuming it
peekMajorType : Decoder Int
peekMajorType = ???  -- Cannot do with raw elm/bytes without consuming

-- Alternative: provide `any` and let users dispatch
any : Decoder CborItem
any = unsignedInt8 |> andThen (\byte -> dispatchOnMajor byte)
```

The fundamental limitation: **raw elm/bytes cannot peek** (read without consuming). So we provide `oneOf` as a helper that reads the initial byte once, then dispatches based on major type:

```elm
oneOf : List (Decoder a) -> Decoder a
-- Internally: read initial byte, try to decode via andThen for each option
-- This has a semantic difference: it commits after reading the initial byte
-- For CBOR, this is acceptable since the initial byte IS the discriminator
```

**Error quality:** `Maybe a` — no offset, no context, no message.

**Expected performance:** Fastest. No wrapper overhead. Kernel-optimized.

---

### 4.2 Approach 2: Zwilias-style Erroring (`Cbor/Decode/Erroring.elm`)

**Low-level byte decoder (`Bytes/Decode/Erroring.elm`):**

```elm
type Decoder a
    = Decoder (State -> ParseResult a)

type alias State =
    { input : Bytes
    , offset : Int
    , context : List String
    }

type ParseResult a
    = Good a State
    | Bad Error

type Error
    = OutOfBounds { offset : Int, needed : Int, available : Int }
    | UnexpectedByte { offset : Int, expected : String, got : Int }
    | InvalidUtf8 { offset : Int }
    | CustomError { offset : Int, message : String }
    | InContext String Error
    | OneOfErrors (List Error)
```

**Primitive implementation (double-decode):**

```elm
unsignedInt8 : Decoder Int
unsignedInt8 =
    Decoder <| \state ->
        let
            combined =
                Bytes.Decode.map2 (always identity)
                    (Bytes.Decode.bytes state.offset)
                    Bytes.Decode.unsignedInt8
        in
        case Bytes.Decode.decode combined state.input of
            Just v  -> Good v { state | offset = state.offset + 1 }
            Nothing -> Bad (OutOfBounds { offset = state.offset, needed = 1, available = Bytes.width state.input - state.offset })
```

Every primitive call: skip `state.offset` bytes, read value. This is the "double-decode" — `Bytes.Decode.bytes state.offset` re-reads from byte 0 every time.

**CBOR-level error enrichment:**

```elm
int : Decoder Int
int =
    unsignedInt8
        |> andThen (\byte ->
            let major = Bitwise.shiftRightBy 5 byte
                info  = Bitwise.and 0x1F byte
            in
            if major == 0 then
                unsigned info
            else if major == 1 then
                unsigned info |> map (\n -> negate n - 1)
            else
                failWith ("expected integer (major 0 or 1), got major " ++ String.fromInt major)
        )
        |> inContext "int"

-- failWith : String -> Decoder a
-- inContext : String -> Decoder a -> Decoder a
```

**`oneOf` with backtracking:**

```elm
oneOf : List (Decoder a) -> Decoder a
oneOf options =
    Decoder <| \state ->
        oneOfHelp options [] state

oneOfHelp options errors state =
    case options of
        [] -> Bad (OneOfErrors (List.reverse errors))
        (Decoder f) :: rest ->
            case f state of
                Good v s -> Good v s
                Bad e    -> oneOfHelp rest (e :: errors) state
```

Each alternative gets the **same state** — if one fails 5 bytes in, those bytes are not consumed. Full backtracking.

**Error quality:** Excellent. Exact offset, context stack, what was expected vs found.

**Expected performance:** Slowest. Double-decode on every primitive.

---

### 4.3 Approach 3: Mpizenberg-style Branchable (`Cbor/Decode/Branchable.elm`)

**Low-level byte decoder (`Bytes/Decode/Branchable.elm`):**

```elm
type Decoder a
    = Decoder (State -> D.Decoder ( State, a ))

type alias State =
    { input : Bytes
    , offset : Int
    , context : List String       -- lightweight context stack
    , lastLabel : String           -- label of the most recent primitive/combinator
    }
```

The State carries a `context` stack (pushed by `inContext`) and a `lastLabel` that each CBOR-level decoder sets before calling into elm/bytes. On success, this is pure bookkeeping. On failure, `decode` captures whatever was in State at the point elm/bytes threw.

**Primitive implementation (pass-through):**

```elm
unsignedInt8 : Decoder Int
unsignedInt8 =
    fromDecoder D.unsignedInt8 1

fromDecoder : D.Decoder v -> Int -> Decoder v
fromDecoder decoder byteLength =
    Decoder <| \state ->
        D.map (\v -> ( { state | offset = state.offset + byteLength }, v ))
            decoder
```

The underlying `D.Decoder` (elm/bytes) is passed through unchanged. No double-decode. State updates the offset in parallel. The happy path cost is one record update per primitive — no skip-to-offset re-reading.

**Error reporting — the key difference from original mpizenberg:**

The original mpizenberg decoder returns `Maybe a`, discarding State on failure. We change `decode` to capture the last-known State:

```elm
type Error
    = DecodingError
        { offset : Int
        , context : List String
        , label : String
        }

decode : Decoder a -> Bytes -> Result Error a
decode (Decoder f) input =
    let
        initialState =
            { input = input, offset = 0, context = [], lastLabel = "" }

        -- Run the decoder. On success, elm/bytes returns Just (finalState, value).
        -- On failure, elm/bytes throws internally → Nothing.
        -- We need the State at failure time. Since elm/bytes doesn't give it to us,
        -- we use a trick: thread the state through the elm/bytes decoder chain
        -- so that *each step* updates a mutable-ish "high-water mark".
    in
    case D.decode (f initialState) input of
        Just ( _, value ) ->
            Ok value

        Nothing ->
            -- We don't have the exact failure state, but we have the offset of
            -- the last *successful* primitive. This is approximate but useful:
            -- it tells you "decoding succeeded up to offset N, then failed."
            --
            -- In practice, for CBOR this is close to exact because the pattern
            -- is: read initial byte (succeeds, offset advances) → andThen →
            -- read argument (fails here). The reported offset is 1 byte before
            -- the actual failure.
            Err (DecodingError { offset = ???, context = ???, label = ??? })
```

**The State-capture problem and solution:**

The issue is that when elm/bytes throws, the Elm-land State is lost — it only exists inside the `D.Decoder` chain as closure-captured values. We solve this with a **side-channel**: each primitive writes the current state into a shared reference *before* calling the elm/bytes primitive. Since elm/bytes decoders are evaluated eagerly and sequentially in JavaScript, the last write before a throw is the failure point.

In pure Elm (no kernel tricks), we approximate this differently: the `Decoder` type becomes:

```elm
type Decoder a
    = Decoder (State -> D.Decoder ( State, Result Error a ))
```

Instead of letting elm/bytes throw on failure, we **catch failures at the primitive level** and convert them to `Result`:

```elm
fromDecoder : String -> D.Decoder v -> Int -> Decoder v
fromDecoder label decoder byteLength =
    Decoder <| \state ->
        D.map2
            (\_ v -> ( { state | offset = state.offset + byteLength, lastLabel = label }, Ok v ))
            (D.bytes 0)  -- no-op, just to stay in the D.Decoder chain
            decoder
            -- If decoder fails (elm/bytes throws), we need a fallback...
```

Actually, the cleanest approach: **wrap each elm/bytes primitive in a `Maybe`-catching layer, then lift to `Result`:**

```elm
fromDecoder : String -> D.Decoder v -> Int -> Decoder v
fromDecoder label decoder byteLength =
    Decoder <| \state ->
        -- Try the elm/bytes decoder. If it succeeds, great.
        -- If it fails, we can't catch it inline in D.Decoder...
        -- So we use the same strategy as the original mpizenberg oneOf:
        -- eager evaluation via runKeepState on a sub-slice.
        let
            subInput = dropBytes state.offset state.input
        in
        case D.decode decoder subInput of
            Just v ->
                -- Success: advance the real elm/bytes offset and return Ok
                D.bytes byteLength
                    |> D.map (\_ ->
                        ( { state | offset = state.offset + byteLength, lastLabel = label }
                        , Ok v
                        )
                    )

            Nothing ->
                -- Failure: report error with current state, don't advance
                D.succeed
                    ( state
                    , Err (DecodingError
                        { offset = state.offset
                        , context = state.context
                        , label = label
                        })
                    )
```

**Wait — this introduces per-primitive byte-slicing + eager eval, which is the zwilias double-decode cost!**

So we have a spectrum of implementation strategies for Branchable error reporting:

| Strategy | Happy-path cost | Error info |
|----------|----------------|------------|
| **(a) Original mpizenberg** | Near-zero (pass-through) | `Maybe` only — no info |
| **(b) Result in return type, catch at `decode`** | Near-zero | Offset approximate (last `andThen` boundary) |
| **(c) Per-primitive eager eval** | Byte-slice + `D.decode` per primitive | Exact offset + label |
| **(d) Hybrid: pass-through + retry on error** | Near-zero happy path; on failure, re-run with eager eval | Exact on error path, zero overhead on success |

**Our choice: (d) Hybrid.** The decoder runs in two modes:

1. **Fast mode (default):** Pure pass-through, same as original mpizenberg. Returns `D.Decoder (State, a)`. On success: zero overhead. On failure: elm/bytes throws, we get `Nothing`.

2. **Error recovery mode (on failure only):** Re-run the same decoder with eager evaluation (strategy c) to pinpoint the failure offset and context. This is slower but only runs once, on the error path.

```elm
decode : Decoder a -> Bytes -> Result Error a
decode decoder input =
    case decodefast decoder input of
        Just value ->
            Ok value

        Nothing ->
            -- Re-run with error tracking to find where it failed
            Err (diagnose decoder input)

-- Fast path: original mpizenberg, returns Maybe
decodeFast : Decoder a -> Bytes -> Maybe a
decodeFast = ... -- pass-through, no overhead

-- Slow path: only called on failure, pinpoints the error
diagnose : Decoder a -> Bytes -> Error
diagnose = ... -- eager eval per primitive, collects offset + context + label
```

This gives us:
- **Happy path:** Same performance as original mpizenberg (near-raw)
- **Error path:** Exact offset, context stack, label of the failing decoder
- **Cost:** The `Decoder` type must carry enough structure for both modes. In practice, each decoder is a pair of functions: a fast one (pass-through) and a diagnostic one (eager eval).

**Simplified implementation:**

Rather than literally storing two functions, we use a flag in State:

```elm
type alias State =
    { input : Bytes
    , offset : Int
    , context : List String
    , lastLabel : String
    }

-- The Decoder type stays the same as original mpizenberg
type Decoder a
    = Decoder (State -> D.Decoder ( State, a ))

-- decode tries fast path, falls back to diagnostic
decode : Decoder a -> Bytes -> Result Error a
decode (Decoder f) input =
    let
        state = { input = input, offset = 0, context = [], lastLabel = "" }
    in
    case D.decode (f state) input of
        Just ( _, value ) ->
            Ok value

        Nothing ->
            Err (diagnose (Decoder f) input)
```

`diagnose` re-runs the decoder but with per-primitive `D.decode` calls (the eager eval approach) to find exactly where it fails. The `Decoder` function is the same — `diagnose` just evaluates it differently by intercepting `fromDecoder` calls.

**Actually, the simplest correct approach:** Since the `Decoder` is a function `State -> D.Decoder (State, a)`, and we can't "intercept" `fromDecoder` after construction, `diagnose` needs a separate decoder. This means the CBOR-level decoders would need to be written generically over the evaluation strategy.

**Final pragmatic choice:** Use strategy **(b)** — track State alongside elm/bytes, return `Result` with the offset from the last successful step. The offset is approximate (typically within 1-8 bytes of the actual failure, since CBOR primitives are 1-9 bytes). This is:

- Zero extra cost on happy path (just State record updates)
- Useful error info (offset ± a few bytes, full context stack, label)
- Simple implementation (no dual-mode, no re-running)

For CBOR specifically, the approximation is good because:
- `int`: read initial byte (1B, succeeds) → `andThen` → read argument (1-8B, might fail). Reported offset: the initial byte. Actual failure: 1 byte later. Off by 1.
- `string`: read initial byte + length → read N bytes of content. If content read fails, reported offset is at the length byte. Off by the length prefix size (1-9 bytes).
- `field`: context says "field:name", offset says where the map entry started.

```elm
type Error
    = DecodingError
        { offset : Int            -- offset of last successful decoder step
        , context : List String   -- stack of inContext labels, outermost first
        , label : String          -- what was being decoded ("int", "string", "field:name")
        }

decode : Decoder a -> Bytes -> Result Error a
```

**`oneOf` with byte-slicing (unchanged from original):**

```elm
oneOf : List (Decoder a) -> Decoder a
oneOf options =
    Decoder <| \state ->
        let offsetInput = dropBytes state.offset state.input
        in oneOfHelper offsetInput options state

oneOfHelper offsetInput options state =
    case options of
        [] ->
            D.succeed
                ( state
                , Err (DecodingError
                    { offset = state.offset, context = state.context, label = "oneOf (all branches failed)" })
                )
        (Decoder f) :: rest ->
            case runKeepState (Decoder f) offsetInput of
                Just ( newState, Ok value ) ->
                    D.bytes (state.offset + newState.offset)
                        |> D.map (\_ -> ( { state | offset = state.offset + newState.offset }, Ok value ))
                _ ->
                    oneOfHelper offsetInput rest state
```

**`inContext` (lightweight, zero cost on success):**

```elm
inContext : String -> Decoder a -> Decoder a
inContext label (Decoder f) =
    Decoder <| \state ->
        f { state | context = label :: state.context }
```

Just prepends to the context list. On success, the context is discarded with the State. On failure, it's captured in the error.

**CBOR-level decoder with labels:**

```elm
int : Decoder Int
int =
    unsignedInt8
        |> andThen (\byte ->
            let major = Bitwise.shiftRightBy 5 byte
                info  = Bitwise.and 0x1F byte
            in
            if major == 0 then unsigned info
            else if major == 1 then unsigned info |> map (\n -> negate n - 1)
            else failWith "expected integer (major 0 or 1)"
        )
        |> inContext "int"
```

**Error quality: Good.** Approximate offset (within a few bytes), context stack, label. Not as precise as Erroring (which has exact offset + expected-vs-found byte), but substantially better than `Maybe Nothing`.

**Expected performance:** Near-raw for sequential decoding. The only happy-path overhead vs raw elm/bytes is State record updates (offset + context threading). Extra cost in `oneOf` (byte-slicing).

---

## 5. Implementation Phases

### Phase 1: Foundation

**Tasks:**
1. Set up `elm.json` with dependencies (`elm/bytes`, `elm/core`, `elm-explorations/test`, `elm-explorations/benchmark`)
2. Implement `Cbor.elm` — shared types (`CborItem`, `Sign`)
3. Implement `Cbor/Tag.elm` — tag enum with `toInt`/`fromInt`
4. Implement `Cbor/Encode.elm` — full encoder
5. Write `TestVectors.elm` — RFC 8949 Appendix A as `List { hex : String, item : CborItem }`
6. Write `Cbor/EncodeTests.elm` — test encoder against vectors

### Phase 2: Raw Decoder (Approach 1)

**Tasks:**
1. Implement `Cbor/Decode/Raw.elm` — primitives (`int`, `float`, `bool`, `string`, `bytes`, `null`)
2. Add collections (`list`, `dict`, `associativeList`)
3. Add tags (`tag`, `tagged`)
4. Add records/tuples (`record`, `field`, `optionalField`, `tuple`, `elem`, `optionalElem`)
5. Add streaming/indefinite-length (`beginString`, `beginBytes`, `beginList`, `beginDict`)
6. Add `any : Decoder CborItem` (generic decoder)
7. Add `oneOf` (peek-based or `any`-based dispatch)
8. Write `Cbor/Decode/RawTests.elm` — full test suite

### Phase 3: Erroring Decoder (Approach 2)

**Tasks:**
1. Implement `Bytes/Decode/Erroring.elm` — low-level byte decoder with error tracking
2. Implement `Cbor/Decode/Error.elm` — error types
3. Implement `Cbor/Decode/Erroring.elm` — same CBOR API, built on erroring byte decoder
4. Add `inContext` wrapping at each CBOR decoder level
5. Add `failWith` for CBOR-specific error messages (wrong major type, etc.)
6. Write `Cbor/Decode/ErroringTests.elm` — same vectors + error-specific tests

### Phase 4: Branchable Decoder (Approach 3)

**Tasks:**
1. Implement `Bytes/Decode/Branchable.elm` — low-level branchable byte decoder with State (offset, context, label)
2. Implement `Cbor/Decode/Branchable.elm` — same CBOR API, built on branchable byte decoder, with `inContext` and labels
3. Write `Cbor/Decode/BranchableTests.elm` — shared vectors + approximate error tests

### Phase 5: Tests & Benchmarks

**Tasks:**
1. Ensure all three decoders pass the same test vectors
2. Add property-based tests: `encode X |> decode == Ok X` for each approach
3. Add error-quality tests for Erroring (exact offset, context, expected-vs-found) and Branchable (approximate offset, context, label)
4. Implement benchmarks comparing all three on:
   - Small payload (single int, bool, short string)
   - Medium payload (10-field record)
   - Large payload (1000-element list of records)
   - Deeply nested payload (nested maps/lists)
   - Pathological payload (many small items — amplifies per-item overhead)
   - Branching payload (uses `oneOf` heavily)

---

## 6. Test Suite Design

### 6.1 RFC 8949 Appendix A Vectors (`TestVectors.elm`)

Encode each test vector as a pair: hex string + expected `CborItem`:

```elm
-- Helper to convert hex string to Bytes
hexToBytes : String -> Bytes

-- Each vector
vectors : List { hex : String, item : CborItem, label : String }
vectors =
    [ { hex = "00", item = CborInt 0, label = "unsigned 0" }
    , { hex = "01", item = CborInt 1, label = "unsigned 1" }
    , { hex = "0a", item = CborInt 10, label = "unsigned 10" }
    , { hex = "17", item = CborInt 23, label = "unsigned 23" }
    , { hex = "1818", item = CborInt 24, label = "unsigned 24 (1-byte)" }
    , { hex = "1864", item = CborInt 100, label = "unsigned 100" }
    , { hex = "1903e8", item = CborInt 1000, label = "unsigned 1000" }
    , { hex = "20", item = CborInt -1, label = "negative -1" }
    , { hex = "3863", item = CborInt -100, label = "negative -100" }
    , { hex = "f4", item = CborBool False, label = "false" }
    , { hex = "f5", item = CborBool True, label = "true" }
    , { hex = "f6", item = CborNull, label = "null" }
    , { hex = "f7", item = CborUndefined, label = "undefined" }
    , { hex = "f93c00", item = CborFloat 1.0, label = "float16 1.0" }
    , { hex = "f93e00", item = CborFloat 1.5, label = "float16 1.5" }
    , { hex = "fb3ff199999999999a", item = CborFloat 1.1, label = "float64 1.1" }
    , { hex = "40", item = CborBytes emptyBytes, label = "empty bytes" }
    , { hex = "60", item = CborString "", label = "empty string" }
    , { hex = "6161", item = CborString "a", label = "string a" }
    , { hex = "80", item = CborList [], label = "empty list" }
    , { hex = "83010203", item = CborList [ CborInt 1, CborInt 2, CborInt 3 ], label = "[1,2,3]" }
    , { hex = "a0", item = CborMap [], label = "empty map" }
    , { hex = "a201020304", item = CborMap [ (CborInt 1, CborInt 2), (CborInt 3, CborInt 4) ], label = "{1:2,3:4}" }
    -- ... full appendix A
    ]
```

### 6.2 Encoder Tests (`Cbor/EncodeTests.elm`)

```elm
-- For each vector where roundtrip is expected:
-- Cbor.Encode.encode (Cbor.Encode.any vector.item) == hexToBytes vector.hex
```

### 6.3 Decoder Tests (per approach)

Each approach gets the same test structure. To avoid duplication, we use a shared helper.

Since Raw returns `Maybe` while Erroring and Branchable return `Result`, we normalize to `Maybe` for the shared tests (which only check success/failure + decoded value, not error details):

```elm
-- In Cbor/Decode/SharedTests.elm
type alias DecoderKit =
    { decodeAny : Bytes -> Maybe CborItem
    , decodeInt : Bytes -> Maybe Int
    , decodeBool : Bytes -> Maybe Bool
    , decodeFloat : Bytes -> Maybe Float
    , decodeString : Bytes -> Maybe String
    -- ... etc
    }

-- Generate test suite from a DecoderKit
commonTests : String -> DecoderKit -> Test
commonTests label kit =
    describe label
        [ describe "RFC 8949 Appendix A" (vectorTests kit)
        , describe "integers" (intTests kit)
        , describe "strings" (stringTests kit)
        , describe "collections" (collectionTests kit)
        , describe "tags" (tagTests kit)
        , describe "streaming" (streamingTests kit)
        , describe "round-trip" (roundTripTests kit)
        ]
```

Each approach module creates its `DecoderKit` and passes it to `commonTests`.
Raw passes decoders directly. Erroring and Branchable convert `Result` to `Maybe` via `Result.toMaybe`:

```elm
-- In Cbor/Decode/RawTests.elm
suite = SharedTests.commonTests "Raw"
    { decodeAny = Raw.decode Raw.any
    , decodeInt = Raw.decode Raw.int
    , ...
    }

-- In Cbor/Decode/BranchableTests.elm
suite = SharedTests.commonTests "Branchable"
    { decodeAny = Branchable.decode Branchable.any >> Result.toMaybe
    , decodeInt = Branchable.decode Branchable.int >> Result.toMaybe
    , ...
    }

-- In Cbor/Decode/ErroringTests.elm (same pattern)
suite = SharedTests.commonTests "Erroring"
    { decodeAny = Erroring.decode Erroring.any >> Result.toMaybe
    , ...
    }
```

### 6.4 Error-Specific Tests

#### Erroring (exact errors)

```elm
-- In Cbor/Decode/ErroringTests.elm
errorTests : Test
errorTests =
    describe "error quality"
        [ test "wrong major type reports exact offset and byte" <|
            \_ ->
                -- Try to decode string as int: hex "6161" = "a"
                case Erroring.decode Erroring.int (hexToBytes "6161") of
                    Err (UnexpectedByte { offset, expected, got }) ->
                        Expect.all
                            [ \_ -> Expect.equal 0 offset
                            , \_ -> Expect.equal 0x61 got
                            ]
                    _ -> Expect.fail "expected UnexpectedByte error"

        , test "nested context on record field failure" <|
            \_ ->
                case Erroring.decode myRecordDecoder badInput of
                    Err (InContext "field:name" (InContext "string" (UnexpectedByte _))) ->
                        Expect.pass
                    _ -> Expect.fail "expected nested context"

        , test "oneOf collects all branch errors" <|
            ...

        , test "out of bounds reports available bytes" <|
            ...
        ]
```

#### Branchable (approximate errors)

```elm
-- In Cbor/Decode/BranchableTests.elm
errorTests : Test
errorTests =
    describe "error quality"
        [ test "wrong major type reports approximate offset" <|
            \_ ->
                -- Try to decode string as int: hex "6161" = "a"
                case Branchable.decode Branchable.int (hexToBytes "6161") of
                    Err (DecodingError { offset, context }) ->
                        -- Offset is approximate: at or near byte 0
                        Expect.true "offset should be near 0" (offset <= 1)
                    Ok _ -> Expect.fail "expected error"

        , test "context stack is populated" <|
            \_ ->
                case Branchable.decode myRecordDecoder badInput of
                    Err (DecodingError { context }) ->
                        -- Context should include "int" and/or "field:name"
                        Expect.true "context should not be empty"
                            (not (List.isEmpty context))
                    Ok _ -> Expect.fail "expected error"

        , test "label identifies failing decoder" <|
            \_ ->
                case Branchable.decode Branchable.string (hexToBytes "00") of
                    Err (DecodingError { label }) ->
                        Expect.equal "string" label
                    Ok _ -> Expect.fail "expected error"

        , test "oneOf failure reports offset" <|
            ...
        ]
```

The Branchable error tests are **less strict** than Erroring tests: they check that offset is *reasonable* (not exact), that context is *present* (not structurally nested), and that labels are *populated*. This reflects the "good but approximate" error quality of the approach.

### 6.5 Property-Based Tests

```elm
-- Fuzz: encode → decode round-trip
fuzz Fuzz.int "int round-trip" <| \n ->
    Cbor.Encode.encode (Cbor.Encode.int n)
        |> decode int
        |> Expect.equal (Just n)

-- Fuzz: encoded bytes always start with expected major type
fuzz Fuzz.string "string major type" <| \s ->
    let bs = Cbor.Encode.encode (Cbor.Encode.string s)
    in case Bytes.Decode.decode Bytes.Decode.unsignedInt8 bs of
        Just byte -> Expect.equal 3 (Bitwise.shiftRightBy 5 byte)
        Nothing -> Expect.fail "empty bytes"
```

---

## 7. Benchmark Design

### 7.1 Payloads

```elm
-- 1. Tiny: single integer
tinyPayload = Cbor.Encode.encode (Cbor.Encode.int 42)

-- 2. Small record: 5 fields, string keys
smallRecord = Cbor.Encode.encode (Cbor.Encode.keyValue
    [ ( Cbor.Encode.string "id", Cbor.Encode.int 1 )
    , ( Cbor.Encode.string "name", Cbor.Encode.string "Alice" )
    , ( Cbor.Encode.string "age", Cbor.Encode.int 30 )
    , ( Cbor.Encode.string "active", Cbor.Encode.bool True )
    , ( Cbor.Encode.string "score", Cbor.Encode.float 98.5 )
    ])

-- 3. Large list: 1000 integers
largeList = Cbor.Encode.encode (Cbor.Encode.list Cbor.Encode.int (List.range 0 999))

-- 4. Nested: list of 100 small records
nestedPayload = Cbor.Encode.encode (Cbor.Encode.list encodeSmallRecord (List.repeat 100 sampleRecord))

-- 5. Many small items: list of 1000 booleans (amplifies per-item overhead)
manySmallItems = Cbor.Encode.encode (Cbor.Encode.list Cbor.Encode.bool (List.repeat 1000 True))

-- 6. Large record: 25 string-keyed fields (tests record field lookup)
largeRecord = ... -- 25 fields

-- 7. oneOf-heavy: list of mixed types decoded via oneOf
mixedPayload = Cbor.Encode.encode (Cbor.Encode.list Cbor.Encode.any
    [ CborInt 1, CborString "a", CborBool True, CborFloat 1.5, ... ])
```

### 7.2 Benchmark Structure

```elm
suite : Benchmark
suite =
    Benchmark.describe "CBOR Decode"
        [ Benchmark.compare "tiny int"
            "Raw"     (\_ -> Raw.decode Raw.int tinyPayload)
            "Erroring"  (\_ -> Erroring.decode Erroring.int tinyPayload)
        -- elm-explorations/benchmark only supports compare with 2 items
        -- so we benchmark each approach individually:
        , Benchmark.describe "small record"
            [ Benchmark.benchmark "Raw" (\_ -> Raw.decode rawSmallRecordDecoder smallRecord)
            , Benchmark.benchmark "Erroring" (\_ -> Erroring.decode erroringSmallRecordDecoder smallRecord)
            , Benchmark.benchmark "Branchable" (\_ -> Branchable.decode branchableSmallRecordDecoder smallRecord)
            ]
        , Benchmark.describe "1000 ints"
            [ Benchmark.benchmark "Raw" (\_ -> Raw.decode (Raw.list Raw.int) largeList)
            , Benchmark.benchmark "Erroring" (\_ -> Erroring.decode (Erroring.list Erroring.int) largeList)
            , Benchmark.benchmark "Branchable" (\_ -> Branchable.decode (Branchable.list Branchable.int) largeList)
            ]
        -- ... same pattern for all payloads
        ]
```

### 7.3 What We're Measuring

| Benchmark | What it tests |
|-----------|---------------|
| Tiny int | Per-call overhead of the decoder wrapper |
| Small record | Typical real-world decode with field lookup |
| 1000 ints | Sequential decode throughput |
| 100 records | Compound decode with nested andThen |
| 1000 bools | Maximum per-item overhead amplification |
| 25-field record | Record field lookup performance |
| Mixed oneOf | Branching/backtracking cost |

---

## 8. Implementation Order

```
Phase 1  ──────────────────────────────────────────
  1. elm.json setup
  2. Cbor.elm (types)
  3. Cbor/Tag.elm
  4. Cbor/Encode.elm
  5. TestVectors.elm (hex→Bytes helper + RFC vectors)
  6. Cbor/EncodeTests.elm
  ✓ Verify: elm-test passes for encoding

Phase 2  ──────────────────────────────────────────
  7. Cbor/Decode/Raw.elm (primitives + collections)
  8. Cbor/Decode/Raw.elm (records, tuples, tags, streaming)
  9. Cbor/Decode/SharedTests.elm + RawTests.elm
  ✓ Verify: all vectors pass with Raw decoder

Phase 3  ──────────────────────────────────────────
  10. Bytes/Decode/Erroring.elm (low-level)
  11. Cbor/Decode/Error.elm
  12. Cbor/Decode/Erroring.elm (CBOR-level)
  13. Cbor/Decode/ErroringTests.elm (shared + error-specific)
  ✓ Verify: all vectors pass + error tests pass

Phase 4  ──────────────────────────────────────────
  14. Bytes/Decode/Branchable.elm (low-level, with State: offset + context + label)
  15. Cbor/Decode/Branchable.elm (CBOR-level, with inContext + labels)
  16. Cbor/Decode/BranchableTests.elm (shared vectors + approximate error tests)
  ✓ Verify: all vectors pass + error tests pass

Phase 5  ──────────────────────────────────────────
  17. Property-based (fuzz) tests
  18. Benchmark payloads + runner
  19. Run benchmarks, collect results
  20. Analysis & decision on "blessed" Cbor/Decode.elm
```

---

## 9. Key Design Decisions

### 9.1 Two-Phase Decoder Pattern (from elm-toulouse)

elm-toulouse's `Decoder (D.Decoder Int) (Int -> D.Decoder a)` splits "consume initial byte" from "process based on initial byte." This is elegant but couples the Decoder type to a CBOR-specific two-phase model.

**Our choice:** We do NOT adopt the two-phase type. Instead, we use a standard `Decoder a` and implement the two-phase pattern as an internal helper:

```elm
-- Internal, not exposed
initialByteAndThen : (Int -> Int -> Decoder a) -> Decoder a
initialByteAndThen f =
    unsignedInt8 |> andThen (\byte ->
        f (Bitwise.shiftRightBy 5 byte) (Bitwise.and 0x1F byte)
    )
```

**Rationale:** A standard `Decoder a` type is simpler, composes better with generic combinators, and doesn't leak CBOR internals into the type.

### 9.2 `oneOf` Strategy per Approach

| Approach | `oneOf` mechanism | Cost |
|----------|-------------------|------|
| Raw | `any` → pattern match (or peek-based dispatch) | 1 extra byte read (peek) |
| Erroring | True backtracking (same state to each alternative) | Zero extra cost on success path |
| Branchable | Eager eval + byte-slicing | `dropBytes` + re-decode on each attempt |

### 9.3 Record Decoding Strategy

Records (CBOR maps with known keys) need field lookup. Two approaches:

- **Linear scan** (elm-toulouse `field`): For each expected field, scan all map entries. O(n×m) worst case. Simple.
- **Pre-decode to association list** (elm-toulouse `fold`): Decode the map once into `List (key, CborItem)`, then extract fields. O(n+m). Faster for large records.

**Our choice:** Implement both. `record`+`field` for the simple API, `fold` for performance-critical paths. Benchmark to see where the crossover point is.

### 9.4 Float Handling

CBOR has 3 float sizes (16/32/64-bit). Elm has only `Float` (64-bit).

- **Decoding:** Accept all three, always produce `Float`. Requires a float16 decoder (not in elm/bytes — must be hand-rolled or use an existing package).
- **Encoding:** `float` auto-shrinks to smallest lossless form. `float16`/`float32`/`float64` for explicit control.

Float16 decoding needs either:
- A kernel-level implementation (not possible in a published package)
- Pure Elm bit manipulation (decode float16 as uint16, then convert using IEEE 754 formula)
- A dependency on a float16 package

**Our choice:** Pure Elm float16 conversion. The formula is simple (~20 lines) and avoids kernel/dependency issues.

### 9.5 64-bit Integers

Elm's `Int` is safe up to 2^53 (JavaScript Number). CBOR supports up to 2^64.

**Our choice:** Same as elm-toulouse: `int` decoder returns `Int` (capped at 2^53), `bigint` decoder returns `(Sign, Bytes)` for arbitrary-precision.

---

## 10. Dependencies

```json
{
    "elm-version": "0.19.1",
    "dependencies": {
        "direct": {
            "elm/bytes": "1.0.8",
            "elm/core": "1.0.5"
        }
    },
    "test-dependencies": {
        "direct": {
            "elm-explorations/test": "2.2.0"
        }
    }
}
```

Benchmark app has a separate `elm.json` with `elm-explorations/benchmark` added.
