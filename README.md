# elm-cardano/cbor

CBOR ([RFC 8949](https://datatracker.ietf.org/doc/html/rfc8949)) encoder and
decoder for Elm, with lossless round-tripping.

## Install

```
elm install elm-cardano/cbor
```

## Quick start

```elm
import Cbor.Decode as CD
import Cbor.Encode as CE

-- Encode a string to CBOR bytes
CE.encode (CE.string "hello")

-- Decode CBOR bytes back
CD.decode CD.string someBytes
```

## Encoding

Build encoders from primitives and combinators, then call `CE.encode` to
produce `Bytes`.

```elm
import Cbor exposing (Length(..))
import Cbor.Encode as CE

type alias Person =
    { name : String, age : Int }

encodePerson : Person -> CE.Encoder
encodePerson p =
    CE.keyedRecord CE.Unsorted Definite CE.int
        [ ( 0, Just (CE.string p.name) )
        , ( 1, Just (CE.int p.age) )
        ]
```

Primitives: `int`, `bigInt`, `float`, `bool`, `null`, `undefined`, `string`,
`bytes`, `maybe`

Collections: `list`, `array`, `map`, `associativeList`, `dict`,
`keyedRecord`, `sequence`

Use `tagged` to wrap any encoder with a semantic tag, `intWithWidth` /
`floatWithWidth` for explicit wire widths, and `stringChunked` /
`bytesChunked` for indefinite-length encodings of strings / bytes.

### Map sort orders

Pass `CE.Unsorted` to preserve insertion order, or `CE.Sorted toComparable`
to sort keys. Two predefined orders are provided:

- `CE.deterministicSort` -- RFC 8949 Section 4.2.1
- `CE.canonicalSort` -- RFC 7049 Section 3.9

## Decoding

Build decoders and run them with `CD.decode`.

```elm
import Cbor.Decode as CD

type alias Person =
    { name : String, age : Int }

decodePerson : CD.CborDecoder ctx Person
decodePerson =
    CD.keyedRecord CD.int String.fromInt Person
        |> CD.required 0 CD.string
        |> CD.required 1 CD.int
        |> CD.buildKeyedRecord CD.IgnoreExtra
```

Primitives: `int`, `bigInt`, `float`, `bool`, `null`, `undefined`, `string`,
`bytes`, `maybe`

Collections: `array`, `associativeList`, `dict`, `field`, `foldEntries`,
`tagged`

Combinators: `map`, `map2`..`map5`, `andThen`, `oneOf`, `keep`, `ignore`,
`lazy`, `succeed`, `fail`, `inContext`

### Record builders

Three styles for decoding structured data into Elm records:

- **Positional** (`record` / `element` / `buildRecord`) -- CBOR arrays where
  fields are identified by position.
- **Keyed** (`keyedRecord` / `required` / `optional` / `buildKeyedRecord`) --
  CBOR maps with known keys, decoded in key order.
- **Unordered** (`unorderedRecord` / `onKey` / `buildUnorderedRecord`) -- CBOR
  maps where keys may appear in any order.

### Streaming-style decoding

`arrayHeader`, `mapHeader`, `break`, and `untilBreak` for manual iteration
over CBOR structures. `item`, `itemSkip`, and `rawBytes` as escape hatches.

## Error handling

Use `inContext` to annotate decoders with context labels. On failure, the
error includes the label and byte offset, making it easier to locate the
problem.

```elm
decodePerson : CD.CborDecoder String Person
decodePerson =
    CD.inContext "Person"
        (CD.keyedRecord CD.int String.fromInt Person
            |> CD.required 0 (CD.inContext "name" CD.string)
            |> CD.required 1 (CD.inContext "age" CD.int)
            |> CD.buildKeyedRecord CD.IgnoreExtra
        )
```

Use `errorToString` to render errors as human-readable messages:

```elm
CD.errorToString contextToString err
```

## Generic CBOR and diagnostics

The `Cbor` module exposes `CborItem`, a lossless representation of any
well-formed CBOR encoding. Use `Cbor.Decode.item` to decode into a `CborItem`
and `Cbor.Encode.item` to re-encode it -- the round-trip preserves the exact
original bytes.

`Cbor.diagnose` produces the diagnostic notation from RFC 8949 Section 8,
useful for debugging and logging:

```elm
Cbor.diagnose (CborArray Definite [ CborInt52 IW0 1, CborString "two" ])
-- "[1, \"two\"]"
```

## License

BSD-3-Clause
