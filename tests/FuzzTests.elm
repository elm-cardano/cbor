module FuzzTests exposing (suite)

import Bytes exposing (Bytes)
import Bytes.Encode as BE
import Cbor exposing (CborItem(..), Error, Length(..), Sign(..), Tag(..))
import Cbor.Decode as CD
import Cbor.Encode as CE
import Expect
import Fuzz exposing (Fuzzer)
import Hex
import Test exposing (Test, describe, fuzz, fuzz2)



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
        original : Bytes
        original =
            CE.encode encoder
    in
    case CD.decode CD.item original of
        Ok cborItem ->
            CE.encode (CE.item cborItem)
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
        , sortProperties
        , escapeHatchProperties
        ]



-- 1. ROUND-TRIP IDENTITY
-- encode value -> decode -> should equal original value


roundTripProperties : Test
roundTripProperties =
    describe "Round-trip encode/decode identity"
        [ fuzz Fuzz.int "int" <|
            \n ->
                CE.encode (CE.int n)
                    |> CD.decode CD.int
                    |> Expect.equal (Ok n)
        , fuzz Fuzz.niceFloat "float" <|
            \f ->
                CE.encode (CE.float f)
                    |> CD.decode CD.float
                    |> Expect.equal (Ok f)
        , fuzz Fuzz.bool "bool" <|
            \b ->
                CE.encode (CE.bool b)
                    |> CD.decode CD.bool
                    |> Expect.equal (Ok b)
        , fuzz Fuzz.string "string" <|
            \s ->
                CE.encode (CE.string s)
                    |> CD.decode CD.string
                    |> Expect.equal (Ok s)
        , fuzz smallBytes "bytes" <|
            \bs ->
                CE.encode (CE.bytes bs)
                    |> CD.decode CD.bytes
                    |> Result.map Hex.fromBytes
                    |> Expect.equal (Ok (Hex.fromBytes bs))
        , fuzz (Fuzz.list Fuzz.int) "list of ints" <|
            \xs ->
                CE.encode (CE.list Definite CE.int xs)
                    |> CD.decode (CD.array CD.int)
                    |> Expect.equal (Ok xs)
        , fuzz (Fuzz.list (Fuzz.pair Fuzz.int Fuzz.int)) "map of int->int" <|
            \pairs ->
                let
                    unique : List ( Int, Int )
                    unique =
                        deduplicateKeys pairs
                in
                CE.encode (CE.map CE.Unsorted Definite (List.map (\( k, v ) -> ( CE.int k, CE.int v )) unique))
                    |> CD.decode (CD.associativeList CD.int CD.int)
                    |> Result.map (List.sortBy Tuple.first)
                    |> Expect.equal (Ok (List.sortBy Tuple.first unique))
        , fuzz Fuzz.int "tagged int" <|
            \n ->
                CE.encode (CE.tagged EpochDateTime (CE.int n))
                    |> CD.decode (CD.tagged EpochDateTime CD.int)
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
                    argBytes : Bytes
                    argBytes =
                        BE.encode
                            (BE.sequence
                                [ BE.unsignedInt32 Bytes.BE hi
                                , BE.unsignedInt32 Bytes.BE lo
                                ]
                            )

                    encoded : Bytes
                    encoded =
                        CE.encode (CE.item (CborInt64 Positive argBytes))
                in
                case CD.decode CD.item encoded of
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
                    argBytes : Bytes
                    argBytes =
                        BE.encode
                            (BE.sequence
                                [ BE.unsignedInt32 Bytes.BE hi
                                , BE.unsignedInt32 Bytes.BE lo
                                ]
                            )

                    encoded : Bytes
                    encoded =
                        CE.encode (CE.item (CborInt64 Negative argBytes))
                in
                case CD.decode CD.item encoded of
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
                Bytes.width (CE.encode (CE.int n))
                    |> Expect.equal 1
        , fuzz (Fuzz.intRange 24 255) "positive 24..255 -> 2 bytes" <|
            \n ->
                Bytes.width (CE.encode (CE.int n))
                    |> Expect.equal 2
        , fuzz (Fuzz.intRange 256 65535) "positive 256..65535 -> 3 bytes" <|
            \n ->
                Bytes.width (CE.encode (CE.int n))
                    |> Expect.equal 3
        , fuzz (Fuzz.intRange 65536 2147483647) "positive 65536..2^31-1 -> 5 bytes" <|
            \n ->
                Bytes.width (CE.encode (CE.int n))
                    |> Expect.equal 5
        , fuzz (Fuzz.intRange -24 -1) "negative -24..-1 -> 1 byte" <|
            \n ->
                Bytes.width (CE.encode (CE.int n))
                    |> Expect.equal 1
        , fuzz (Fuzz.intRange -256 -25) "negative -256..-25 -> 2 bytes" <|
            \n ->
                Bytes.width (CE.encode (CE.int n))
                    |> Expect.equal 2
        , fuzz (Fuzz.intRange -65536 -257) "negative -65536..-257 -> 3 bytes" <|
            \n ->
                Bytes.width (CE.encode (CE.int n))
                    |> Expect.equal 3
        , fuzz (Fuzz.intRange -2147483648 -65537) "negative -2^31..-65537 -> 5 bytes" <|
            \n ->
                Bytes.width (CE.encode (CE.int n))
                    |> Expect.equal 5
        , fuzz2 (Fuzz.intRange 0 2147483647) (Fuzz.intRange 0 2147483647) "width monotonic for positives" <|
            \a b ->
                let
                    small : Int
                    small =
                        min a b

                    big : Int
                    big =
                        max a b
                in
                Bytes.width (CE.encode (CE.int big))
                    |> Expect.atLeast (Bytes.width (CE.encode (CE.int small)))
        ]



-- 4. DEFINITE / INDEFINITE LENGTH EQUIVALENCE
-- typed decoders are transparent to the length encoding


lengthEquivalenceProperties : Test
lengthEquivalenceProperties =
    describe "Definite/indefinite decode equivalence"
        [ fuzz (Fuzz.list Fuzz.int) "array" <|
            \xs ->
                let
                    decoder : CD.CborDecoder ctx (List Int)
                    decoder =
                        CD.array CD.int
                in
                Expect.equal
                    (CD.decode decoder (CE.encode (CE.list Definite CE.int xs)))
                    (CD.decode decoder (CE.encode (CE.list Indefinite CE.int xs)))
        , fuzz (Fuzz.list (Fuzz.pair Fuzz.int Fuzz.int)) "map" <|
            \pairs ->
                let
                    unique : List ( Int, Int )
                    unique =
                        deduplicateKeys pairs

                    encodeEntries : Length -> CE.Encoder
                    encodeEntries len =
                        CE.map CE.Unsorted len (List.map (\( k, v ) -> ( CE.int k, CE.int v )) unique)

                    decoder : CD.CborDecoder ctx (List ( Int, Int ))
                    decoder =
                        CD.associativeList CD.int CD.int

                    sortResult : Result x (List ( Int, Int )) -> Result x (List ( Int, Int ))
                    sortResult =
                        Result.map (List.sortBy Tuple.first)
                in
                Expect.equal
                    (sortResult (CD.decode decoder (CE.encode (encodeEntries Definite))))
                    (sortResult (CD.decode decoder (CE.encode (encodeEntries Indefinite))))
        , fuzz (Fuzz.list Fuzz.string) "chunked string decodes to concatenation" <|
            \chunks ->
                CE.encode (CE.stringChunked chunks)
                    |> CD.decode CD.string
                    |> Expect.equal (Ok (String.concat chunks))
        , fuzz (Fuzz.list smallBytes) "chunked bytes decodes to concatenation" <|
            \chunks ->
                CE.encode (CE.bytesChunked chunks)
                    |> CD.decode CD.bytes
                    |> Result.map Hex.fromBytes
                    |> Expect.equal (Ok (Hex.fromBytes (concatBytes chunks)))
        ]



-- 5. SORT EQUIVALENCE
-- all sort orders produce the same decoded key-value set


sortProperties : Test
sortProperties =
    describe "Sort equivalence"
        [ fuzz (Fuzz.list (Fuzz.pair (Fuzz.intRange 0 1000) (Fuzz.intRange 0 1000)))
            "deterministicSort, canonicalSort, and Unsorted decode to same values"
          <|
            \pairs ->
                let
                    unique : List ( Int, Int )
                    unique =
                        deduplicateKeys pairs

                    entries : List ( CE.Encoder, CE.Encoder )
                    entries =
                        List.map (\( k, v ) -> ( CE.int k, CE.int v )) unique

                    decoder : CD.CborDecoder ctx (List ( Int, Int ))
                    decoder =
                        CD.associativeList CD.int CD.int

                    sortResult : Result x (List ( Int, Int )) -> Result x (List ( Int, Int ))
                    sortResult =
                        Result.map (List.sortBy Tuple.first)

                    detResult : Result (Error ctx) (List ( Int, Int ))
                    detResult =
                        sortResult (CD.decode decoder (CE.encode (CE.map CE.deterministicSort Definite entries)))

                    canResult : Result (Error ctx) (List ( Int, Int ))
                    canResult =
                        sortResult (CD.decode decoder (CE.encode (CE.map CE.canonicalSort Definite entries)))

                    unsResult : Result (Error ctx) (List ( Int, Int ))
                    unsResult =
                        sortResult (CD.decode decoder (CE.encode (CE.map CE.Unsorted Definite entries)))
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
                CE.encode (CE.rawUnsafe bs)
                    |> Hex.fromBytes
                    |> Expect.equal (Hex.fromBytes bs)
        , fuzz2 Fuzz.int Fuzz.asciiString "sequence is byte concatenation without wrapping" <|
            \n s ->
                let
                    seqBytes : Bytes
                    seqBytes =
                        CE.encode (CE.sequence [ CE.int n, CE.string s ])

                    intBytes : Bytes
                    intBytes =
                        CE.encode (CE.int n)

                    strBytes : Bytes
                    strBytes =
                        CE.encode (CE.string s)
                in
                Hex.fromBytes seqBytes
                    |> Expect.equal (Hex.fromBytes intBytes ++ Hex.fromBytes strBytes)
        , fuzz (Fuzz.list Fuzz.bool) "keyedRecord omits Nothing entries" <|
            \presentFlags ->
                let
                    entries : List ( Int, Maybe CE.Encoder )
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

                    encoded : Bytes
                    encoded =
                        CE.encode (CE.keyedRecord CE.Unsorted Definite CE.int entries)
                in
                case CD.decode CD.item encoded of
                    Ok (CborMap _ mapEntries) ->
                        let
                            expectedCount : Int
                            expectedCount =
                                List.length (List.filter identity presentFlags)
                        in
                        List.length mapEntries
                            |> Expect.equal expectedCount

                    other ->
                        Expect.fail ("Expected CborMap, got " ++ Debug.toString other)
        ]
