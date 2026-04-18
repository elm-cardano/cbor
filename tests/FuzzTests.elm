module FuzzTests exposing (suite)

import Bytes exposing (Bytes)
import Bytes.Decoder as BD
import Bytes.Encode as BE
import Cbor exposing (..)
import Cbor.Decode as CD
import Cbor.Encode as CE
import Expect
import Fuzz exposing (Fuzzer)
import Hex
import Test exposing (..)



-- FUZZERS


smallBytes : Fuzzer Bytes
smallBytes =
    Fuzz.listOfLengthBetween 0 20 (Fuzz.intRange 0 255)
        |> Fuzz.map (\ints -> BE.encode (BE.sequence (List.map BE.unsignedInt8 ints)))



-- HELPERS


concatBytes : List Bytes -> Bytes
concatBytes chunks =
    BE.encode (BE.sequence (List.map BE.bytes chunks))


deduplicateKeys : List ( comparable, a ) -> List ( comparable, a )
deduplicateKeys pairs =
    List.foldl
        (\( k, v ) ( seen, acc ) ->
            if List.member k seen then
                ( seen, acc )

            else
                ( k :: seen, ( k, v ) :: acc )
        )
        ( [], [] )
        pairs
        |> Tuple.second
        |> List.reverse


{-| Verify encode -> decode via item -> re-encode preserves exact bytes.
-}
byteRoundTrip : CE.Encoder -> Expect.Expectation
byteRoundTrip encoder =
    let
        original =
            CE.encode CE.deterministic encoder
    in
    case BD.decode CD.item original of
        Ok cborItem ->
            CE.encode CE.deterministic (CE.item cborItem)
                |> Hex.fromBytes
                |> Expect.equal (Hex.fromBytes original)

        Err _ ->
            Expect.fail "item decode failed"



-- TESTS


suite : Test
suite =
    describe "CBOR Properties"
        [ roundTripProperties
        , byteLevelRoundTripProperties
        , shortestFormProperties
        , lengthEquivalenceProperties
        , strategyProperties
        , escapeHatchProperties
        ]



-- 1. ROUND-TRIP IDENTITY
-- encode value -> decode -> should equal original value


roundTripProperties : Test
roundTripProperties =
    describe "Round-trip encode/decode identity"
        [ fuzz Fuzz.int "int" <|
            \n ->
                CE.encode CE.deterministic (CE.int n)
                    |> BD.decode CD.int
                    |> Expect.equal (Ok n)
        , fuzz Fuzz.niceFloat "float" <|
            \f ->
                CE.encode CE.deterministic (CE.float f)
                    |> BD.decode CD.float
                    |> Expect.equal (Ok f)
        , fuzz Fuzz.bool "bool" <|
            \b ->
                CE.encode CE.deterministic (CE.bool b)
                    |> BD.decode CD.bool
                    |> Expect.equal (Ok b)
        , fuzz Fuzz.string "string" <|
            \s ->
                CE.encode CE.deterministic (CE.string s)
                    |> BD.decode CD.string
                    |> Expect.equal (Ok s)
        , fuzz smallBytes "bytes" <|
            \bs ->
                CE.encode CE.deterministic (CE.bytes bs)
                    |> BD.decode CD.bytes
                    |> Result.map Hex.fromBytes
                    |> Expect.equal (Ok (Hex.fromBytes bs))
        , fuzz (Fuzz.list Fuzz.int) "list of ints" <|
            \xs ->
                CE.encode CE.deterministic (CE.list CE.int xs)
                    |> BD.decode (CD.array CD.int)
                    |> Expect.equal (Ok xs)
        , fuzz (Fuzz.list (Fuzz.pair Fuzz.int Fuzz.int)) "map of int->int" <|
            \pairs ->
                let
                    unique =
                        deduplicateKeys pairs

                    encoder =
                        CE.map (List.map (\( k, v ) -> ( CE.int k, CE.int v )) unique)
                in
                CE.encode CE.deterministic encoder
                    |> BD.decode (CD.keyValue CD.int CD.int)
                    |> Result.map (List.sortBy Tuple.first)
                    |> Expect.equal (Ok (List.sortBy Tuple.first unique))
        , fuzz Fuzz.int "tagged int" <|
            \n ->
                CE.encode CE.deterministic (CE.tag EpochDateTime (CE.int n))
                    |> BD.decode (CD.tag EpochDateTime CD.int)
                    |> Expect.equal (Ok n)
        ]



-- 2. BYTE-LEVEL LOSSLESS ROUND-TRIP
-- encode -> decode via item -> re-encode via item -> bytes match original


byteLevelRoundTripProperties : Test
byteLevelRoundTripProperties =
    describe "Byte-level lossless round-trip via item"
        [ fuzz Fuzz.int "int preserves bytes" <|
            \n -> byteRoundTrip (CE.int n)
        , fuzz Fuzz.niceFloat "float preserves bytes" <|
            \f -> byteRoundTrip (CE.float f)
        , fuzz Fuzz.bool "bool preserves bytes" <|
            \b -> byteRoundTrip (CE.bool b)
        , fuzz Fuzz.string "string preserves bytes" <|
            \s -> byteRoundTrip (CE.string s)
        , fuzz smallBytes "bytes preserves bytes" <|
            \bs -> byteRoundTrip (CE.bytes bs)
        , fuzz2 (Fuzz.intRange 1048577 2147483647)
            (Fuzz.intRange 0 2147483647)
            "CborInt64 positive round-trips via item"
          <|
            \hi lo ->
                let
                    argBytes =
                        BE.encode
                            (BE.sequence
                                [ BE.unsignedInt32 Bytes.BE hi
                                , BE.unsignedInt32 Bytes.BE lo
                                ]
                            )

                    encoded =
                        CE.encode CE.deterministic (CE.item (CborInt64 Positive argBytes))
                in
                case BD.decode CD.item encoded of
                    Ok (CborInt64 Positive bs) ->
                        Hex.fromBytes bs |> Expect.equal (Hex.fromBytes argBytes)

                    other ->
                        Expect.fail ("Expected CborInt64 Positive, got " ++ Debug.toString other)
        , fuzz2 (Fuzz.intRange 1048577 2147483647)
            (Fuzz.intRange 0 2147483647)
            "CborInt64 negative round-trips via item"
          <|
            \hi lo ->
                let
                    argBytes =
                        BE.encode
                            (BE.sequence
                                [ BE.unsignedInt32 Bytes.BE hi
                                , BE.unsignedInt32 Bytes.BE lo
                                ]
                            )

                    encoded =
                        CE.encode CE.deterministic (CE.item (CborInt64 Negative argBytes))
                in
                case BD.decode CD.item encoded of
                    Ok (CborInt64 Negative bs) ->
                        Hex.fromBytes bs |> Expect.equal (Hex.fromBytes argBytes)

                    other ->
                        Expect.fail ("Expected CborInt64 Negative, got " ++ Debug.toString other)
        ]



-- 3. INTEGER SHORTEST FORM
-- encoder always picks the minimal width for a given value


shortestFormProperties : Test
shortestFormProperties =
    describe "Integer shortest form"
        [ fuzz (Fuzz.intRange 0 23) "positive 0..23 -> 1 byte" <|
            \n ->
                Bytes.width (CE.encode CE.deterministic (CE.int n))
                    |> Expect.equal 1
        , fuzz (Fuzz.intRange 24 255) "positive 24..255 -> 2 bytes" <|
            \n ->
                Bytes.width (CE.encode CE.deterministic (CE.int n))
                    |> Expect.equal 2
        , fuzz (Fuzz.intRange 256 65535) "positive 256..65535 -> 3 bytes" <|
            \n ->
                Bytes.width (CE.encode CE.deterministic (CE.int n))
                    |> Expect.equal 3
        , fuzz (Fuzz.intRange 65536 2147483647) "positive 65536..2^31-1 -> 5 bytes" <|
            \n ->
                Bytes.width (CE.encode CE.deterministic (CE.int n))
                    |> Expect.equal 5
        , fuzz (Fuzz.intRange -24 -1) "negative -24..-1 -> 1 byte" <|
            \n ->
                Bytes.width (CE.encode CE.deterministic (CE.int n))
                    |> Expect.equal 1
        , fuzz (Fuzz.intRange -256 -25) "negative -256..-25 -> 2 bytes" <|
            \n ->
                Bytes.width (CE.encode CE.deterministic (CE.int n))
                    |> Expect.equal 2
        , fuzz (Fuzz.intRange -65536 -257) "negative -65536..-257 -> 3 bytes" <|
            \n ->
                Bytes.width (CE.encode CE.deterministic (CE.int n))
                    |> Expect.equal 3
        , fuzz (Fuzz.intRange -2147483648 -65537) "negative -2^31..-65537 -> 5 bytes" <|
            \n ->
                Bytes.width (CE.encode CE.deterministic (CE.int n))
                    |> Expect.equal 5
        , fuzz2 (Fuzz.intRange 0 2147483647) (Fuzz.intRange 0 2147483647) "width monotonic for positives" <|
            \a b ->
                let
                    small =
                        min a b

                    big =
                        max a b
                in
                Bytes.width (CE.encode CE.deterministic (CE.int big))
                    |> Expect.atLeast (Bytes.width (CE.encode CE.deterministic (CE.int small)))
        ]



-- 4. DEFINITE / INDEFINITE LENGTH EQUIVALENCE
-- typed decoders are transparent to the length encoding


lengthEquivalenceProperties : Test
lengthEquivalenceProperties =
    let
        indefiniteStrategy =
            { sortKeys = identity, lengthMode = Indefinite }
    in
    describe "Definite/indefinite decode equivalence"
        [ fuzz (Fuzz.list Fuzz.int) "array" <|
            \xs ->
                let
                    encoder =
                        CE.list CE.int xs

                    decoder =
                        CD.array CD.int
                in
                Expect.equal
                    (BD.decode decoder (CE.encode CE.deterministic encoder))
                    (BD.decode decoder (CE.encode indefiniteStrategy encoder))
        , fuzz (Fuzz.list (Fuzz.pair Fuzz.int Fuzz.int)) "map" <|
            \pairs ->
                let
                    unique =
                        deduplicateKeys pairs

                    encoder =
                        CE.map (List.map (\( k, v ) -> ( CE.int k, CE.int v )) unique)

                    decoder =
                        CD.keyValue CD.int CD.int

                    sortResult =
                        Result.map (List.sortBy Tuple.first)
                in
                Expect.equal
                    (sortResult (BD.decode decoder (CE.encode CE.deterministic encoder)))
                    (sortResult (BD.decode decoder (CE.encode indefiniteStrategy encoder)))
        , fuzz (Fuzz.list Fuzz.string) "chunked string decodes to concatenation" <|
            \chunks ->
                CE.encode CE.deterministic (CE.stringChunked chunks)
                    |> BD.decode CD.string
                    |> Expect.equal (Ok (String.concat chunks))
        , fuzz (Fuzz.list smallBytes) "chunked bytes decodes to concatenation" <|
            \chunks ->
                CE.encode CE.deterministic (CE.bytesChunked chunks)
                    |> BD.decode CD.bytes
                    |> Result.map Hex.fromBytes
                    |> Expect.equal (Ok (Hex.fromBytes (concatBytes chunks)))
        ]



-- 5. STRATEGY EQUIVALENCE
-- all strategies produce the same decoded key-value set


strategyProperties : Test
strategyProperties =
    describe "Strategy equivalence"
        [ fuzz (Fuzz.list (Fuzz.pair (Fuzz.intRange 0 1000) (Fuzz.intRange 0 1000)))
            "deterministic, canonical, and unsorted decode to same values"
          <|
            \pairs ->
                let
                    unique =
                        deduplicateKeys pairs

                    encoder =
                        CE.map (List.map (\( k, v ) -> ( CE.int k, CE.int v )) unique)

                    decoder =
                        CD.keyValue CD.int CD.int

                    sortResult =
                        Result.map (List.sortBy Tuple.first)

                    detResult =
                        sortResult (BD.decode decoder (CE.encode CE.deterministic encoder))

                    canResult =
                        sortResult (BD.decode decoder (CE.encode CE.canonical encoder))

                    unsResult =
                        sortResult (BD.decode decoder (CE.encode CE.unsorted encoder))
                in
                Expect.all
                    [ \_ -> Expect.equal detResult canResult
                    , \_ -> Expect.equal detResult unsResult
                    ]
                    ()
        ]



-- 6. ESCAPE HATCH PROPERTIES


escapeHatchProperties : Test
escapeHatchProperties =
    describe "Escape hatches"
        [ fuzz smallBytes "rawUnsafe passes through unchanged" <|
            \bs ->
                CE.encode CE.deterministic (CE.rawUnsafe bs)
                    |> Hex.fromBytes
                    |> Expect.equal (Hex.fromBytes bs)
        , fuzz2 Fuzz.int Fuzz.asciiString "sequence is byte concatenation without wrapping" <|
            \n s ->
                let
                    seqBytes =
                        CE.encode CE.deterministic (CE.sequence [ CE.int n, CE.string s ])

                    intBytes =
                        CE.encode CE.deterministic (CE.int n)

                    strBytes =
                        CE.encode CE.deterministic (CE.string s)
                in
                Hex.fromBytes seqBytes
                    |> Expect.equal (Hex.fromBytes intBytes ++ Hex.fromBytes strBytes)
        , fuzz (Fuzz.list Fuzz.bool) "keyedRecord omits Nothing entries" <|
            \presentFlags ->
                let
                    entries =
                        List.indexedMap
                            (\i present ->
                                ( i
                                , if present then
                                    Just (CE.int i)

                                  else
                                    Nothing
                                )
                            )
                            presentFlags

                    expectedCount =
                        List.length (List.filter identity presentFlags)

                    encoded =
                        CE.encode CE.deterministic (CE.keyedRecord CE.int entries)
                in
                case BD.decode CD.item encoded of
                    Ok (CborMap _ mapEntries) ->
                        List.length mapEntries
                            |> Expect.equal expectedCount

                    other ->
                        Expect.fail ("Expected CborMap, got " ++ Debug.toString other)
        ]
