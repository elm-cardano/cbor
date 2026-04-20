module CborTests exposing (suite)

import Bytes
import Bytes.Decoder as BD
import Cbor exposing (CborItem(..), FloatWidth(..), IntWidth(..), Length(..), Sign(..), SimpleWidth(..), Tag(..), diagnose)
import Cbor.Decode as CD
import Cbor.Encode as CE
import Expect
import Hex
import Test exposing (Test, describe, test)


{-| Helper: encode and return hex string.
-}
encodeToHex : CE.Encoder -> String
encodeToHex encoder =
    Hex.fromBytes (CE.encode encoder)


{-| Helper: decode from hex using a given CborDecoder.
-}
decodeFromHex : CD.CborDecoder ctx a -> String -> Result (BD.Error ctx CD.DecodeError) a
decodeFromHex decoder hex =
    CD.decode decoder (Hex.toBytesUnchecked hex)


{-| Helper: verify item decode -> re-encode round-trip preserves bytes.
-}
itemRoundTrip : String -> Test
itemRoundTrip hex =
    test ("item round-trip: " ++ hex) <|
        \_ ->
            case decodeFromHex CD.item hex of
                Ok cborItem ->
                    Hex.fromBytes (CE.encode (CE.item cborItem))
                        |> Expect.equal hex

                Err err ->
                    Expect.fail ("decode failed: " ++ Debug.toString err)



-- TESTS


suite : Test
suite =
    describe "CBOR"
        [ encodeIntTests
        , decodeIntTests
        , encodeFloatTests
        , decodeFloatTests
        , encodeBoolTests
        , decodeBoolTests
        , encodeNullTests
        , decodeNullTests
        , encodeStringTests
        , decodeStringTests
        , encodeBytesTests
        , decodeBytesTests
        , encodeArrayTests
        , decodeArrayTests
        , encodeMapTests
        , decodeMapTests
        , encodeTagTests
        , decodeTagTests
        , roundTripTests
        , recordBuilderTests
        , keyedRecordBuilderTests
        , sortTests
        , itemDecoderTests
        , diagnosticTests
        , bigIntTests
        , foldEntriesTests
        , fieldTests
        , unorderedRecordBuilderTests
        , sequenceTests
        , rawUnsafeTests
        , simpleValueTests
        ]



-- ENCODE INTEGER TESTS (RFC 8949 Appendix A)


encodeIntTests : Test
encodeIntTests =
    describe "Cbor.Encode.int"
        [ test "0" <|
            \_ -> encodeToHex (CE.int 0) |> Expect.equal "00"
        , test "1" <|
            \_ -> encodeToHex (CE.int 1) |> Expect.equal "01"
        , test "10" <|
            \_ -> encodeToHex (CE.int 10) |> Expect.equal "0a"
        , test "23" <|
            \_ -> encodeToHex (CE.int 23) |> Expect.equal "17"
        , test "24" <|
            \_ -> encodeToHex (CE.int 24) |> Expect.equal "1818"
        , test "25" <|
            \_ -> encodeToHex (CE.int 25) |> Expect.equal "1819"
        , test "100" <|
            \_ -> encodeToHex (CE.int 100) |> Expect.equal "1864"
        , test "1000" <|
            \_ -> encodeToHex (CE.int 1000) |> Expect.equal "1903e8"
        , test "1000000" <|
            \_ -> encodeToHex (CE.int 1000000) |> Expect.equal "1a000f4240"
        , test "1000000000000" <|
            \_ -> encodeToHex (CE.int 1000000000000) |> Expect.equal "1b000000e8d4a51000"
        , test "-1" <|
            \_ -> encodeToHex (CE.int -1) |> Expect.equal "20"
        , test "-10" <|
            \_ -> encodeToHex (CE.int -10) |> Expect.equal "29"
        , test "-100" <|
            \_ -> encodeToHex (CE.int -100) |> Expect.equal "3863"
        , test "-1000" <|
            \_ -> encodeToHex (CE.int -1000) |> Expect.equal "3903e7"
        , test "4294967295 (max IW32)" <|
            \_ -> encodeToHex (CE.int 4294967295) |> Expect.equal "1affffffff"
        , test "4294967296 (min IW64)" <|
            \_ -> encodeToHex (CE.int 4294967296) |> Expect.equal "1b0000000100000000"
        , test "-24 (max negative IW0)" <|
            \_ -> encodeToHex (CE.int -24) |> Expect.equal "37"
        , test "-25 (requires IW8)" <|
            \_ -> encodeToHex (CE.int -25) |> Expect.equal "3818"
        , test "-256 (max negative IW8)" <|
            \_ -> encodeToHex (CE.int -256) |> Expect.equal "38ff"
        , test "-257 (requires IW16)" <|
            \_ -> encodeToHex (CE.int -257) |> Expect.equal "390100"
        , test "intWithWidth IW16 pads to 2 bytes" <|
            \_ -> encodeToHex (CE.intWithWidth IW16 1) |> Expect.equal "190001"
        , test "intWithWidth IW32 pads to 4 bytes" <|
            \_ -> encodeToHex (CE.intWithWidth IW32 1) |> Expect.equal "1a00000001"
        , test "intWithWidth IW64 pads to 8 bytes" <|
            \_ -> encodeToHex (CE.intWithWidth IW64 1) |> Expect.equal "1b0000000000000001"
        ]



-- DECODE INTEGER TESTS


decodeIntTests : Test
decodeIntTests =
    describe "Cbor.Decode.int"
        [ test "0" <|
            \_ -> decodeFromHex CD.int "00" |> Expect.equal (Ok 0)
        , test "1" <|
            \_ -> decodeFromHex CD.int "01" |> Expect.equal (Ok 1)
        , test "10" <|
            \_ -> decodeFromHex CD.int "0a" |> Expect.equal (Ok 10)
        , test "23" <|
            \_ -> decodeFromHex CD.int "17" |> Expect.equal (Ok 23)
        , test "24" <|
            \_ -> decodeFromHex CD.int "1818" |> Expect.equal (Ok 24)
        , test "25" <|
            \_ -> decodeFromHex CD.int "1819" |> Expect.equal (Ok 25)
        , test "100" <|
            \_ -> decodeFromHex CD.int "1864" |> Expect.equal (Ok 100)
        , test "1000" <|
            \_ -> decodeFromHex CD.int "1903e8" |> Expect.equal (Ok 1000)
        , test "1000000" <|
            \_ -> decodeFromHex CD.int "1a000f4240" |> Expect.equal (Ok 1000000)
        , test "1000000000000" <|
            \_ -> decodeFromHex CD.int "1b000000e8d4a51000" |> Expect.equal (Ok 1000000000000)
        , test "-1" <|
            \_ -> decodeFromHex CD.int "20" |> Expect.equal (Ok -1)
        , test "-10" <|
            \_ -> decodeFromHex CD.int "29" |> Expect.equal (Ok -10)
        , test "-100" <|
            \_ -> decodeFromHex CD.int "3863" |> Expect.equal (Ok -100)
        , test "-1000" <|
            \_ -> decodeFromHex CD.int "3903e7" |> Expect.equal (Ok -1000)
        , test "4294967295" <|
            \_ -> decodeFromHex CD.int "1affffffff" |> Expect.equal (Ok 4294967295)
        , test "4294967296" <|
            \_ -> decodeFromHex CD.int "1b0000000100000000" |> Expect.equal (Ok 4294967296)
        , test "-24" <|
            \_ -> decodeFromHex CD.int "37" |> Expect.equal (Ok -24)
        , test "-25" <|
            \_ -> decodeFromHex CD.int "3818" |> Expect.equal (Ok -25)
        , test "-256" <|
            \_ -> decodeFromHex CD.int "38ff" |> Expect.equal (Ok -256)
        , test "-257" <|
            \_ -> decodeFromHex CD.int "390100" |> Expect.equal (Ok -257)
        , test "rejects value > 2^52" <|
            \_ ->
                decodeFromHex CD.int "1b0010000000000001"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "wrong major type fails" <|
            \_ ->
                decodeFromHex CD.int "60"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- ENCODE FLOAT TESTS


encodeFloatTests : Test
encodeFloatTests =
    describe "Cbor.Encode.float"
        [ test "0.0 as float16" <|
            \_ -> encodeToHex (CE.float 0.0) |> Expect.equal "f90000"
        , test "1.0 as float16" <|
            \_ -> encodeToHex (CE.float 1.0) |> Expect.equal "f93c00"
        , test "1.5 as float16" <|
            \_ -> encodeToHex (CE.float 1.5) |> Expect.equal "f93e00"
        , test "100000.0 as float32" <|
            \_ -> encodeToHex (CE.float 100000.0) |> Expect.equal "fa47c35000"
        , test "1.1 as float64" <|
            \_ -> encodeToHex (CE.float 1.1) |> Expect.equal "fb3ff199999999999a"
        , test "-4.1 as float64" <|
            \_ -> encodeToHex (CE.float -4.1) |> Expect.equal "fbc010666666666666"
        , test "+Infinity as float16" <|
            \_ -> encodeToHex (CE.float (1 / 0)) |> Expect.equal "f97c00"
        , test "-Infinity as float16" <|
            \_ -> encodeToHex (CE.float (-1 / 0)) |> Expect.equal "f9fc00"
        , test "NaN as float16" <|
            \_ -> encodeToHex (CE.float (0 / 0)) |> Expect.equal "f97e00"
        , test "explicit float16" <|
            \_ -> encodeToHex (CE.floatWithWidth FW16 1.5) |> Expect.equal "f93e00"
        , test "explicit float32" <|
            \_ -> encodeToHex (CE.floatWithWidth FW32 1.5) |> Expect.equal "fa3fc00000"
        , test "explicit float64" <|
            \_ -> encodeToHex (CE.floatWithWidth FW64 1.5) |> Expect.equal "fb3ff8000000000000"
        ]



-- DECODE FLOAT TESTS


decodeFloatTests : Test
decodeFloatTests =
    describe "Cbor.Decode.float"
        [ test "0.0 float16" <|
            \_ -> decodeFromHex CD.float "f90000" |> Expect.equal (Ok 0.0)
        , test "1.0 float16" <|
            \_ -> decodeFromHex CD.float "f93c00" |> Expect.equal (Ok 1.0)
        , test "1.5 float16" <|
            \_ -> decodeFromHex CD.float "f93e00" |> Expect.equal (Ok 1.5)
        , test "100000.0 float32" <|
            \_ -> decodeFromHex CD.float "fa47c35000" |> Expect.equal (Ok 100000.0)
        , test "1.1 float64" <|
            \_ -> decodeFromHex CD.float "fb3ff199999999999a" |> Expect.equal (Ok 1.1)
        , test "-4.1 float64" <|
            \_ -> decodeFromHex CD.float "fbc010666666666666" |> Expect.equal (Ok -4.1)
        , test "+Infinity float16" <|
            \_ ->
                decodeFromHex CD.float "f97c00"
                    |> Result.map isInfinite
                    |> Expect.equal (Ok True)
        , test "-Infinity float16" <|
            \_ ->
                decodeFromHex CD.float "f9fc00"
                    |> Result.map (\f -> isInfinite f && f < 0)
                    |> Expect.equal (Ok True)
        , test "NaN float16" <|
            \_ ->
                decodeFromHex CD.float "f97e00"
                    |> Result.map isNaN
                    |> Expect.equal (Ok True)
        , test "rejects bool (non-float major 7)" <|
            \_ ->
                decodeFromHex CD.float "f4"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- ENCODE BOOL TESTS


encodeBoolTests : Test
encodeBoolTests =
    describe "Cbor.Encode.bool"
        [ test "false" <|
            \_ -> encodeToHex (CE.bool False) |> Expect.equal "f4"
        , test "true" <|
            \_ -> encodeToHex (CE.bool True) |> Expect.equal "f5"
        ]



-- DECODE BOOL TESTS


decodeBoolTests : Test
decodeBoolTests =
    describe "Cbor.Decode.bool"
        [ test "false" <|
            \_ -> decodeFromHex CD.bool "f4" |> Expect.equal (Ok False)
        , test "true" <|
            \_ -> decodeFromHex CD.bool "f5" |> Expect.equal (Ok True)
        , test "rejects null" <|
            \_ ->
                decodeFromHex CD.bool "f6"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- ENCODE NULL TESTS


encodeNullTests : Test
encodeNullTests =
    describe "Cbor.Encode.null/undefined"
        [ test "null" <|
            \_ -> encodeToHex CE.null |> Expect.equal "f6"
        , test "undefined" <|
            \_ -> encodeToHex CE.undefined |> Expect.equal "f7"
        ]



-- DECODE NULL TESTS


decodeNullTests : Test
decodeNullTests =
    describe "Cbor.Decode.null"
        [ test "null with custom default" <|
            \_ ->
                decodeFromHex (CD.null "default") "f6"
                    |> Expect.equal (Ok "default")
        , test "rejects non-null byte" <|
            \_ ->
                decodeFromHex (CD.null ()) "f5"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- ENCODE STRING TESTS


encodeStringTests : Test
encodeStringTests =
    describe "Cbor.Encode.string"
        [ test "empty string" <|
            \_ -> encodeToHex (CE.string "") |> Expect.equal "60"
        , test "\"a\"" <|
            \_ -> encodeToHex (CE.string "a") |> Expect.equal "6161"
        , test "\"IETF\"" <|
            \_ -> encodeToHex (CE.string "IETF") |> Expect.equal "6449455446"
        , test "\"\\\"\\\\\"" <|
            \_ -> encodeToHex (CE.string "\"\\") |> Expect.equal "62225c"
        , test "chunked string" <|
            \_ ->
                encodeToHex (CE.stringChunked [ "hel", "lo" ])
                    |> Expect.equal "7f6368656c626c6fff"
        , test "empty chunked string" <|
            \_ ->
                encodeToHex (CE.stringChunked [])
                    |> Expect.equal "7fff"
        ]



-- DECODE STRING TESTS


decodeStringTests : Test
decodeStringTests =
    describe "Cbor.Decode.string"
        [ test "empty string" <|
            \_ -> decodeFromHex CD.string "60" |> Expect.equal (Ok "")
        , test "\"a\"" <|
            \_ -> decodeFromHex CD.string "6161" |> Expect.equal (Ok "a")
        , test "\"IETF\"" <|
            \_ -> decodeFromHex CD.string "6449455446" |> Expect.equal (Ok "IETF")
        , test "\"\\\"\\\\\"" <|
            \_ -> decodeFromHex CD.string "62225c" |> Expect.equal (Ok "\"\\")
        , test "chunked string transparently" <|
            \_ ->
                decodeFromHex CD.string "7f6368656c626c6fff"
                    |> Expect.equal (Ok "hello")
        , test "rejects int" <|
            \_ ->
                decodeFromHex CD.string "01"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- ENCODE BYTES TESTS


encodeBytesTests : Test
encodeBytesTests =
    describe "Cbor.Encode.bytes"
        [ test "empty bytes" <|
            \_ -> encodeToHex (CE.bytes (Hex.toBytesUnchecked "")) |> Expect.equal "40"
        , test "h'01020304'" <|
            \_ -> encodeToHex (CE.bytes (Hex.toBytesUnchecked "01020304")) |> Expect.equal "4401020304"
        , test "chunked bytes" <|
            \_ ->
                encodeToHex
                    (CE.bytesChunked
                        [ Hex.toBytesUnchecked "0102"
                        , Hex.toBytesUnchecked "0304"
                        ]
                    )
                    |> Expect.equal "5f420102420304ff"
        ]



-- DECODE BYTES TESTS


decodeBytesTests : Test
decodeBytesTests =
    describe "Cbor.Decode.bytes"
        [ test "empty bytes" <|
            \_ ->
                decodeFromHex CD.bytes "40"
                    |> Result.map Bytes.width
                    |> Expect.equal (Ok 0)
        , test "h'01020304'" <|
            \_ ->
                decodeFromHex CD.bytes "4401020304"
                    |> Result.map Hex.fromBytes
                    |> Expect.equal (Ok "01020304")
        , test "chunked bytes transparently" <|
            \_ ->
                decodeFromHex CD.bytes "5f420102420304ff"
                    |> Result.map Hex.fromBytes
                    |> Expect.equal (Ok "01020304")
        , test "rejects string" <|
            \_ ->
                decodeFromHex CD.bytes "60"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- ENCODE ARRAY TESTS


encodeArrayTests : Test
encodeArrayTests =
    describe "Cbor.Encode.array"
        [ test "empty array" <|
            \_ -> encodeToHex (CE.array Definite []) |> Expect.equal "80"
        , test "[1, 2, 3]" <|
            \_ ->
                encodeToHex (CE.array Definite [ CE.int 1, CE.int 2, CE.int 3 ])
                    |> Expect.equal "83010203"
        , test "nested [1, [2, 3], [4, 5]]" <|
            \_ ->
                encodeToHex
                    (CE.array Definite
                        [ CE.int 1
                        , CE.array Definite [ CE.int 2, CE.int 3 ]
                        , CE.array Definite [ CE.int 4, CE.int 5 ]
                        ]
                    )
                    |> Expect.equal "8301820203820405"
        , test "[1..25] (length 25, requires 2-byte header)" <|
            \_ ->
                let
                    items : List CE.Encoder
                    items =
                        List.range 1 25 |> List.map CE.int
                in
                encodeToHex (CE.array Definite items)
                    |> String.left 4
                    |> Expect.equal "9819"
        , test "indefinite array" <|
            \_ ->
                encodeToHex (CE.array Indefinite [ CE.int 1, CE.int 2, CE.int 3 ])
                    |> Expect.equal "9f010203ff"
        , test "empty indefinite array" <|
            \_ ->
                encodeToHex (CE.array Indefinite [])
                    |> Expect.equal "9fff"
        ]



-- DECODE ARRAY TESTS


decodeArrayTests : Test
decodeArrayTests =
    describe "Cbor.Decode.array"
        [ test "empty array" <|
            \_ -> decodeFromHex (CD.array CD.int) "80" |> Expect.equal (Ok [])
        , test "[1, 2, 3]" <|
            \_ -> decodeFromHex (CD.array CD.int) "83010203" |> Expect.equal (Ok [ 1, 2, 3 ])
        , test "nested array" <|
            \_ ->
                decodeFromHex (CD.array CD.int) "83010203"
                    |> Expect.equal (Ok [ 1, 2, 3 ])
        , test "indefinite array" <|
            \_ ->
                decodeFromHex (CD.array CD.int) "9f010203ff"
                    |> Expect.equal (Ok [ 1, 2, 3 ])
        , test "empty indefinite array" <|
            \_ ->
                decodeFromHex (CD.array CD.int) "9fff"
                    |> Expect.equal (Ok [])
        , test "rejects map" <|
            \_ ->
                decodeFromHex (CD.array CD.int) "a0"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- ENCODE MAP TESTS


encodeMapTests : Test
encodeMapTests =
    describe "Cbor.Encode.map"
        [ test "empty map" <|
            \_ -> encodeToHex (CE.map CE.Unsorted Definite []) |> Expect.equal "a0"
        , test "{1: 2, 3: 4}" <|
            \_ ->
                encodeToHex
                    (CE.map CE.Unsorted
                        Definite
                        [ ( CE.int 1, CE.int 2 )
                        , ( CE.int 3, CE.int 4 )
                        ]
                    )
                    |> Expect.equal "a201020304"
        , test "indefinite map" <|
            \_ ->
                encodeToHex
                    (CE.map CE.Unsorted
                        Indefinite
                        [ ( CE.int 1, CE.int 2 ), ( CE.int 3, CE.int 4 ) ]
                    )
                    |> Expect.equal "bf01020304ff"
        , test "empty indefinite map" <|
            \_ ->
                encodeToHex (CE.map CE.Unsorted Indefinite [])
                    |> Expect.equal "bfff"
        ]



-- DECODE MAP TESTS


decodeMapTests : Test
decodeMapTests =
    describe "Cbor.Decode.keyValue"
        [ test "empty map" <|
            \_ -> decodeFromHex (CD.keyValue CD.int CD.int) "a0" |> Expect.equal (Ok [])
        , test "{1: 2, 3: 4}" <|
            \_ ->
                decodeFromHex (CD.keyValue CD.int CD.int) "a201020304"
                    |> Expect.equal (Ok [ ( 1, 2 ), ( 3, 4 ) ])
        , test "indefinite map" <|
            \_ ->
                decodeFromHex (CD.keyValue CD.int CD.int) "bf01020304ff"
                    |> Expect.equal (Ok [ ( 1, 2 ), ( 3, 4 ) ])
        , test "empty indefinite map" <|
            \_ ->
                decodeFromHex (CD.keyValue CD.int CD.int) "bfff"
                    |> Expect.equal (Ok [])
        , test "rejects array" <|
            \_ ->
                decodeFromHex (CD.keyValue CD.int CD.int) "80"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- ENCODE TAG TESTS


encodeTagTests : Test
encodeTagTests =
    describe "Cbor.Encode.tag"
        [ test "tag 1 (epoch time)" <|
            \_ ->
                encodeToHex (CE.tag EpochDateTime (CE.int 1363896240))
                    |> Expect.equal "c11a514b67b0"
        ]



-- DECODE TAG TESTS


decodeTagTests : Test
decodeTagTests =
    describe "Cbor.Decode.tag"
        [ test "matching tag succeeds" <|
            \_ ->
                decodeFromHex (CD.tag EpochDateTime CD.int) "c11a514b67b0"
                    |> Expect.equal (Ok 1363896240)
        , test "wrong tag fails" <|
            \_ ->
                decodeFromHex (CD.tag EpochDateTime CD.int) "c001"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "Unknown tag number" <|
            \_ ->
                decodeFromHex (CD.tag (Unknown 256) CD.int) "d9010001"
                    |> Expect.equal (Ok 1)
        , test "rejects non-tag" <|
            \_ ->
                decodeFromHex (CD.tag EpochDateTime CD.int) "01"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- ROUND-TRIP TESTS


roundTripTests : Test
roundTripTests =
    describe "Round-trip encode/decode"
        [ test "int 0" <|
            \_ -> roundTripInt 0
        , test "int 23" <|
            \_ -> roundTripInt 23
        , test "int 24" <|
            \_ -> roundTripInt 24
        , test "int 255" <|
            \_ -> roundTripInt 255
        , test "int 256" <|
            \_ -> roundTripInt 256
        , test "int 65535" <|
            \_ -> roundTripInt 65535
        , test "int 65536" <|
            \_ -> roundTripInt 65536
        , test "int 1000000" <|
            \_ -> roundTripInt 1000000
        , test "int -1" <|
            \_ -> roundTripInt -1
        , test "int -100" <|
            \_ -> roundTripInt -100
        , test "int -1000" <|
            \_ -> roundTripInt -1000
        , test "bool true" <|
            \_ ->
                CE.encode (CE.bool True)
                    |> CD.decode CD.bool
                    |> Expect.equal (Ok True)
        , test "bool false" <|
            \_ ->
                CE.encode (CE.bool False)
                    |> CD.decode CD.bool
                    |> Expect.equal (Ok False)
        , test "string round-trip" <|
            \_ ->
                CE.encode (CE.string "hello")
                    |> CD.decode CD.string
                    |> Expect.equal (Ok "hello")
        , test "string with unicode" <|
            \_ ->
                CE.encode (CE.string "日本語")
                    |> CD.decode CD.string
                    |> Expect.equal (Ok "日本語")
        , test "empty array" <|
            \_ ->
                CE.encode (CE.array Definite [])
                    |> CD.decode (CD.array CD.int)
                    |> Expect.equal (Ok [])
        , test "array of ints" <|
            \_ ->
                CE.encode (CE.list Definite CE.int [ 1, 2, 3, 4, 5 ])
                    |> CD.decode (CD.array CD.int)
                    |> Expect.equal (Ok [ 1, 2, 3, 4, 5 ])
        , test "map of int->string" <|
            \_ ->
                CE.encode
                    (CE.map CE.Unsorted
                        Definite
                        [ ( CE.int 1, CE.string "one" )
                        , ( CE.int 2, CE.string "two" )
                        ]
                    )
                    |> CD.decode (CD.keyValue CD.int CD.string)
                    |> Expect.equal (Ok [ ( 1, "one" ), ( 2, "two" ) ])
        , test "null round-trip" <|
            \_ ->
                CE.encode CE.null
                    |> CD.decode (CD.null ())
                    |> Expect.equal (Ok ())
        , test "Infinity round-trip" <|
            \_ ->
                CE.encode (CE.float (1 / 0))
                    |> CD.decode CD.float
                    |> Result.map isInfinite
                    |> Expect.equal (Ok True)
        , test "NaN round-trip" <|
            \_ ->
                CE.encode (CE.float (0 / 0))
                    |> CD.decode CD.float
                    |> Result.map isNaN
                    |> Expect.equal (Ok True)
        ]


roundTripInt : Int -> Expect.Expectation
roundTripInt n =
    CE.encode (CE.int n)
        |> CD.decode CD.int
        |> Expect.equal (Ok n)



-- RECORD BUILDER TESTS


type alias Point =
    { x : Float, y : Float }


type alias Point3D =
    { x : Float, y : Float, z : Float }


type alias Config =
    { host : String, port_ : Int, debug : Bool, verbose : Bool }


recordBuilderTests : Test
recordBuilderTests =
    describe "Record builder"
        [ test "decode 2-element array as record" <|
            \_ ->
                -- Encode [1.5, 2.5] as CBOR array
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.array Definite [ CE.float 1.5, CE.float 2.5 ])

                    decoder : CD.CborDecoder () Point
                    decoder =
                        CD.record Point
                            |> CD.element CD.float
                            |> CD.element CD.float
                            |> CD.buildRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { x = 1.5, y = 2.5 })
        , test "optional element present" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.array Definite [ CE.float 1.0, CE.float 2.0, CE.float 3.0 ])

                    decoder : CD.CborDecoder () Point3D
                    decoder =
                        CD.record Point3D
                            |> CD.element CD.float
                            |> CD.element CD.float
                            |> CD.optionalElement CD.float 0.0
                            |> CD.buildRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { x = 1.0, y = 2.0, z = 3.0 })
        , test "optional element absent" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.array Definite [ CE.float 1.0, CE.float 2.0 ])

                    decoder : CD.CborDecoder () Point3D
                    decoder =
                        CD.record Point3D
                            |> CD.element CD.float
                            |> CD.element CD.float
                            |> CD.optionalElement CD.float 0.0
                            |> CD.buildRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { x = 1.0, y = 2.0, z = 0.0 })
        , test "extra array elements skipped" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.array Definite [ CE.float 1.0, CE.float 2.0, CE.float 3.0, CE.float 4.0 ])

                    decoder : CD.CborDecoder () Point
                    decoder =
                        CD.record Point
                            |> CD.element CD.float
                            |> CD.element CD.float
                            |> CD.buildRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { x = 1.0, y = 2.0 })
        , test "extra array elements rejected with FailOnExtra" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.array Definite [ CE.float 1.0, CE.float 2.0, CE.float 3.0, CE.float 4.0 ])

                    decoder : CD.CborDecoder () Point
                    decoder =
                        CD.record Point
                            |> CD.element CD.float
                            |> CD.element CD.float
                            |> CD.buildRecord CD.FailOnExtra
                in
                CD.decode decoder encoded
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "too few elements fails" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.array Definite [ CE.float 1.0 ])

                    decoder : CD.CborDecoder () Point
                    decoder =
                        CD.record Point
                            |> CD.element CD.float
                            |> CD.element CD.float
                            |> CD.buildRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "multiple optionals all absent" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.array Definite [ CE.string "localhost", CE.int 8080 ])

                    decoder : CD.CborDecoder () Config
                    decoder =
                        CD.record Config
                            |> CD.element CD.string
                            |> CD.element CD.int
                            |> CD.optionalElement CD.bool False
                            |> CD.optionalElement CD.bool False
                            |> CD.buildRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { host = "localhost", port_ = 8080, debug = False, verbose = False })
        , test "multiple optionals one present" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.array Definite [ CE.string "localhost", CE.int 8080, CE.bool True ])

                    decoder : CD.CborDecoder () Config
                    decoder =
                        CD.record Config
                            |> CD.element CD.string
                            |> CD.element CD.int
                            |> CD.optionalElement CD.bool False
                            |> CD.optionalElement CD.bool False
                            |> CD.buildRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { host = "localhost", port_ = 8080, debug = True, verbose = False })
        ]



-- KEYED RECORD BUILDER TESTS


type alias Person =
    { name : String, age : Int }


type alias PersonOptional =
    { name : String, age : Int, email : String }


type alias PersonFull =
    { name : String, age : Int, email : String, active : Bool }


type alias DetailedPerson =
    { name : String, age : Int, email : String, phone : String }


keyedRecordBuilderTests : Test
keyedRecordBuilderTests =
    describe "Keyed record builder"
        [ test "all required fields" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 1, CE.int 30 )
                                ]
                            )

                    decoder : CD.CborDecoder () Person
                    decoder =
                        CD.keyedRecord CD.int Person
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.buildKeyedRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Alice", age = 30 })
        , test "optional field present" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Bob" )
                                , ( CE.int 1, CE.int 25 )
                                , ( CE.int 2, CE.string "bob@example.com" )
                                ]
                            )

                    decoder : CD.CborDecoder () PersonOptional
                    decoder =
                        CD.keyedRecord CD.int PersonOptional
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.optional 2 CD.string ""
                            |> CD.buildKeyedRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Bob", age = 25, email = "bob@example.com" })
        , test "optional field absent" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Charlie" )
                                , ( CE.int 1, CE.int 35 )
                                ]
                            )

                    decoder : CD.CborDecoder () PersonOptional
                    decoder =
                        CD.keyedRecord CD.int PersonOptional
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.optional 2 CD.string ""
                            |> CD.buildKeyedRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Charlie", age = 35, email = "" })
        , test "stashed key scenario" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 1, CE.int 30 )
                                , ( CE.int 3, CE.bool True )
                                ]
                            )

                    decoder : CD.CborDecoder () PersonFull
                    decoder =
                        CD.keyedRecord CD.int PersonFull
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.optional 2 CD.string ""
                            |> CD.required 3 CD.bool
                            |> CD.buildKeyedRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Alice", age = 30, email = "", active = True })
        , test "multiple consecutive absent optionals" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 1, CE.int 30 )
                                ]
                            )

                    decoder : CD.CborDecoder () DetailedPerson
                    decoder =
                        CD.keyedRecord CD.int DetailedPerson
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.optional 2 CD.string ""
                            |> CD.optional 3 CD.string ""
                            |> CD.buildKeyedRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Alice", age = 30, email = "", phone = "" })
        , test "extra trailing entries skipped" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 1, CE.int 30 )
                                , ( CE.int 99, CE.string "extra" )
                                ]
                            )

                    decoder : CD.CborDecoder () Person
                    decoder =
                        CD.keyedRecord CD.int Person
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.buildKeyedRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Alice", age = 30 })
        , test "extra trailing entries rejected with FailOnExtra" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 1, CE.int 30 )
                                , ( CE.int 99, CE.string "extra" )
                                ]
                            )

                    decoder : CD.CborDecoder () Person
                    decoder =
                        CD.keyedRecord CD.int Person
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.buildKeyedRecord CD.FailOnExtra
                in
                CD.decode decoder encoded
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "required key mismatch fails" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 5, CE.int 30 )
                                ]
                            )

                    decoder : CD.CborDecoder () Person
                    decoder =
                        CD.keyedRecord CD.int Person
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.buildKeyedRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "optional as last step with unmatched key fails" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 1, CE.int 30 )
                                , ( CE.int 3, CE.bool True )
                                ]
                            )

                    decoder : CD.CborDecoder () PersonOptional
                    decoder =
                        CD.keyedRecord CD.int PersonOptional
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.optional 2 CD.string ""
                            |> CD.buildKeyedRecord CD.IgnoreExtra
                in
                CD.decode decoder encoded
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- UNORDERED RECORD BUILDER TESTS


unorderedRecordBuilderTests : Test
unorderedRecordBuilderTests =
    describe "Unordered record builder"
        [ test "keys in declared order" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 1, CE.int 30 )
                                ]
                            )

                    decoder : CD.CborDecoder () Person
                    decoder =
                        CD.unorderedRecord CD.int { name = Nothing, age = Nothing }
                            |> CD.onKey 0 CD.string (\v acc -> { acc | name = Just v })
                            |> CD.onKey 1 CD.int (\v acc -> { acc | age = Just v })
                            |> CD.buildUnorderedRecord CD.IgnoreExtra
                                (\acc -> Maybe.map2 Person acc.name acc.age)
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Alice", age = 30 })
        , test "keys in reverse order" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 1, CE.int 25 )
                                , ( CE.int 0, CE.string "Bob" )
                                ]
                            )

                    decoder : CD.CborDecoder () Person
                    decoder =
                        CD.unorderedRecord CD.int { name = Nothing, age = Nothing }
                            |> CD.onKey 0 CD.string (\v acc -> { acc | name = Just v })
                            |> CD.onKey 1 CD.int (\v acc -> { acc | age = Just v })
                            |> CD.buildUnorderedRecord CD.IgnoreExtra
                                (\acc -> Maybe.map2 Person acc.name acc.age)
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Bob", age = 25 })
        , test "extra keys ignored with IgnoreExtra" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Charlie" )
                                , ( CE.int 99, CE.string "extra" )
                                , ( CE.int 1, CE.int 40 )
                                ]
                            )

                    decoder : CD.CborDecoder () Person
                    decoder =
                        CD.unorderedRecord CD.int { name = Nothing, age = Nothing }
                            |> CD.onKey 0 CD.string (\v acc -> { acc | name = Just v })
                            |> CD.onKey 1 CD.int (\v acc -> { acc | age = Just v })
                            |> CD.buildUnorderedRecord CD.IgnoreExtra
                                (\acc -> Maybe.map2 Person acc.name acc.age)
                in
                CD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Charlie", age = 40 })
        , test "extra keys rejected with FailOnExtra" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 99, CE.string "extra" )
                                , ( CE.int 1, CE.int 30 )
                                ]
                            )

                    decoder : CD.CborDecoder () Person
                    decoder =
                        CD.unorderedRecord CD.int { name = Nothing, age = Nothing }
                            |> CD.onKey 0 CD.string (\v acc -> { acc | name = Just v })
                            |> CD.onKey 1 CD.int (\v acc -> { acc | age = Just v })
                            |> CD.buildUnorderedRecord CD.FailOnExtra
                                (\acc -> Maybe.map2 Person acc.name acc.age)
                in
                CD.decode decoder encoded
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "missing required field fails" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                ]
                            )

                    decoder : CD.CborDecoder () Person
                    decoder =
                        CD.unorderedRecord CD.int { name = Nothing, age = Nothing }
                            |> CD.onKey 0 CD.string (\v acc -> { acc | name = Just v })
                            |> CD.onKey 1 CD.int (\v acc -> { acc | age = Just v })
                            |> CD.buildUnorderedRecord CD.IgnoreExtra
                                (\acc -> Maybe.map2 Person acc.name acc.age)
                in
                CD.decode decoder encoded
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- SORT TESTS


sortTests : Test
sortTests =
    describe "Sort and length"
        [ test "deterministicSort sorts keys lexicographically" <|
            \_ ->
                -- Keys: int 10 (0x0a) and int 1 (0x01)
                -- Encoded key 1 = 0x01, key 10 = 0x0a
                -- Lexicographic order: 0x01 < 0x0a -> key 1 before key 10
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.deterministicSort
                                Definite
                                [ ( CE.int 10, CE.string "ten" )
                                , ( CE.int 1, CE.string "one" )
                                ]
                            )
                in
                Hex.fromBytes encoded
                    |> String.left 6
                    |> Expect.equal "a20163"

        -- a2 = map(2), 01 = key 1, 63 = text(3)
        , test "unsorted preserves insertion order" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 10, CE.string "ten" )
                                , ( CE.int 1, CE.string "one" )
                                ]
                            )
                in
                Hex.fromBytes encoded
                    |> String.left 6
                    |> Expect.equal "a20a63"

        -- a2 = map(2), 0a = key 10, 63 = text(3)
        , test "keyedRecord with deterministicSort matches unsorted for ordered keys" <|
            \_ ->
                let
                    unsortedEncoder : CE.Encoder
                    unsortedEncoder =
                        CE.keyedRecord CE.Unsorted
                            Definite
                            CE.int
                            [ ( 0, Just (CE.string "Alice") )
                            , ( 1, Just (CE.int 30) )
                            ]

                    deterministicEncoder : CE.Encoder
                    deterministicEncoder =
                        CE.keyedRecord CE.deterministicSort
                            Definite
                            CE.int
                            [ ( 1, Just (CE.int 30) )
                            , ( 0, Just (CE.string "Alice") )
                            ]
                in
                Hex.fromBytes (CE.encode deterministicEncoder)
                    |> Expect.equal (Hex.fromBytes (CE.encode unsortedEncoder))

        -- keys 0, 1 are already in order
        , test "keyedRecord omits Nothing entries" <|
            \_ ->
                let
                    encoder : CE.Encoder
                    encoder =
                        CE.keyedRecord CE.Unsorted
                            Definite
                            CE.int
                            [ ( 0, Just (CE.string "Alice") )
                            , ( 1, Nothing )
                            , ( 2, Just (CE.int 30) )
                            ]
                in
                -- Should produce a 2-entry map (key 0 and key 2), not 3
                Hex.fromBytes (CE.encode encoder)
                    |> String.left 2
                    |> Expect.equal "a2"
        , test "deterministicSort: int 256 before string empty (lexicographic)" <|
            \_ ->
                -- Key A: string "" -> 0x60 (1 byte)
                -- Key B: int 256 -> 0x190100 (3 bytes)
                -- Deterministic: 0x19 < 0x60 -> int 256 first
                let
                    entries : List ( CE.Encoder, CE.Encoder )
                    entries =
                        [ ( CE.string "", CE.int 1 )
                        , ( CE.int 256, CE.int 2 )
                        ]
                in
                Hex.fromBytes (CE.encode (CE.map CE.deterministicSort Definite entries))
                    |> Expect.equal "a2190100026001"
        , test "canonicalSort: string empty before int 256 (length-first)" <|
            \_ ->
                -- Canonical: 1 byte < 3 bytes -> string "" first
                let
                    entries : List ( CE.Encoder, CE.Encoder )
                    entries =
                        [ ( CE.string "", CE.int 1 )
                        , ( CE.int 256, CE.int 2 )
                        ]
                in
                Hex.fromBytes (CE.encode (CE.map CE.canonicalSort Definite entries))
                    |> Expect.equal "a2600119010002"
        , test "indefinite map with sorted keys" <|
            \_ ->
                Hex.fromBytes
                    (CE.encode
                        (CE.map CE.deterministicSort
                            Indefinite
                            [ ( CE.int 10, CE.int 20 )
                            , ( CE.int 1, CE.int 2 )
                            ]
                        )
                    )
                    |> Expect.equal "bf01020a14ff"
        ]



-- ITEM DECODER TESTS


itemDecoderTests : Test
itemDecoderTests =
    describe "Cbor.Decode.item"
        [ test "unsigned int" <|
            \_ ->
                case decodeFromHex CD.item "0a" of
                    Ok (CborInt52 IW0 10) ->
                        Expect.pass

                    other ->
                        Expect.fail ("Expected CborInt52 IW0 10, got " ++ Debug.toString other)
        , test "negative int" <|
            \_ ->
                case decodeFromHex CD.item "3863" of
                    Ok (CborInt52 IW8 n) ->
                        Expect.equal -100 n

                    other ->
                        Expect.fail ("Expected CborInt52 IW8 -100, got " ++ Debug.toString other)
        , test "byte string" <|
            \_ ->
                case decodeFromHex CD.item "4401020304" of
                    Ok (CborByteString bs) ->
                        Expect.equal "01020304" (Hex.fromBytes bs)

                    other ->
                        Expect.fail ("Expected CborByteString, got " ++ Debug.toString other)
        , test "text string" <|
            \_ ->
                case decodeFromHex CD.item "6449455446" of
                    Ok (CborString s) ->
                        Expect.equal "IETF" s

                    other ->
                        Expect.fail ("Expected CborString \"IETF\", got " ++ Debug.toString other)
        , test "empty array" <|
            \_ ->
                case decodeFromHex CD.item "80" of
                    Ok (CborArray Definite []) ->
                        Expect.pass

                    other ->
                        Expect.fail ("Expected empty CborArray, got " ++ Debug.toString other)
        , test "bool false" <|
            \_ ->
                case decodeFromHex CD.item "f4" of
                    Ok (CborBool False) ->
                        Expect.pass

                    other ->
                        Expect.fail ("Expected CborBool False, got " ++ Debug.toString other)
        , test "bool true" <|
            \_ ->
                case decodeFromHex CD.item "f5" of
                    Ok (CborBool True) ->
                        Expect.pass

                    other ->
                        Expect.fail ("Expected CborBool True, got " ++ Debug.toString other)
        , test "null" <|
            \_ ->
                case decodeFromHex CD.item "f6" of
                    Ok CborNull ->
                        Expect.pass

                    other ->
                        Expect.fail ("Expected CborNull, got " ++ Debug.toString other)
        , test "undefined" <|
            \_ ->
                case decodeFromHex CD.item "f7" of
                    Ok CborUndefined ->
                        Expect.pass

                    other ->
                        Expect.fail ("Expected CborUndefined, got " ++ Debug.toString other)
        , test "float16 1.5" <|
            \_ ->
                case decodeFromHex CD.item "f93e00" of
                    Ok (CborFloat FW16 f) ->
                        Expect.within (Expect.Absolute 0.001) 1.5 f

                    other ->
                        Expect.fail ("Expected CborFloat FW16 1.5, got " ++ Debug.toString other)
        , test "tagged value" <|
            \_ ->
                case decodeFromHex CD.item "c11a514b67b0" of
                    Ok (CborTag EpochDateTime (CborInt52 _ n)) ->
                        Expect.equal 1363896240 n

                    other ->
                        Expect.fail ("Expected tagged epoch time, got " ++ Debug.toString other)
        , test "array [1, 2, 3]" <|
            \_ ->
                case decodeFromHex CD.item "83010203" of
                    Ok (CborArray Definite items) ->
                        Expect.equal 3 (List.length items)

                    other ->
                        Expect.fail ("Expected CborArray with 3 items, got " ++ Debug.toString other)
        , test "map {1: 2, 3: 4}" <|
            \_ ->
                case decodeFromHex CD.item "a201020304" of
                    Ok (CborMap Definite entries) ->
                        Expect.equal 2 (List.length entries)

                    other ->
                        Expect.fail ("Expected CborMap with 2 entries, got " ++ Debug.toString other)
        , test "indefinite array" <|
            \_ ->
                case decodeFromHex CD.item "9f010203ff" of
                    Ok (CborArray Indefinite items) ->
                        Expect.equal 3 (List.length items)

                    other ->
                        Expect.fail ("Expected CborArray Indefinite, got " ++ Debug.toString other)
        , test "indefinite map" <|
            \_ ->
                case decodeFromHex CD.item "bf01020304ff" of
                    Ok (CborMap Indefinite entries) ->
                        Expect.equal 2 (List.length entries)

                    other ->
                        Expect.fail ("Expected CborMap Indefinite, got " ++ Debug.toString other)
        , test "chunked text" <|
            \_ ->
                case decodeFromHex CD.item "7f6368656c626c6fff" of
                    Ok (CborStringChunked chunks) ->
                        Expect.equal [ "hel", "lo" ] chunks

                    other ->
                        Expect.fail ("Expected CborStringChunked, got " ++ Debug.toString other)
        , test "chunked bytes" <|
            \_ ->
                case decodeFromHex CD.item "5f420102420304ff" of
                    Ok (CborByteStringChunked chunks) ->
                        Expect.equal 2 (List.length chunks)

                    other ->
                        Expect.fail ("Expected CborByteStringChunked, got " ++ Debug.toString other)
        , itemRoundTrip "00"
        , itemRoundTrip "17"
        , itemRoundTrip "1864"
        , itemRoundTrip "1b000000e8d4a51000"
        , itemRoundTrip "20"
        , itemRoundTrip "3903e7"
        , itemRoundTrip "f93e00"
        , itemRoundTrip "f4"
        , itemRoundTrip "f5"
        , itemRoundTrip "f6"
        , itemRoundTrip "f7"
        , itemRoundTrip "6449455446"
        , itemRoundTrip "4401020304"
        , itemRoundTrip "83010203"
        , itemRoundTrip "a201020304"
        , itemRoundTrip "c11a514b67b0"
        , test "encode CborInt64 positive" <|
            \_ ->
                Hex.fromBytes
                    (CE.encode
                        (CE.item (CborInt64 Positive (Hex.toBytesUnchecked "000000000000002a")))
                    )
                    |> Expect.equal "1b000000000000002a"
        , test "encode CborInt64 negative" <|
            \_ ->
                Hex.fromBytes
                    (CE.encode
                        (CE.item (CborInt64 Negative (Hex.toBytesUnchecked "000000000000002a")))
                    )
                    |> Expect.equal "3b000000000000002a"
        , test "64-bit value > 2^52 decodes as CborInt64 Positive" <|
            \_ ->
                -- 0x0010000000000001 = 2^52 + 1
                case decodeFromHex CD.item "1b0010000000000001" of
                    Ok (CborInt64 Positive bs) ->
                        Hex.fromBytes bs |> Expect.equal "0010000000000001"

                    other ->
                        Expect.fail ("Expected CborInt64 Positive, got " ++ Debug.toString other)
        , test "negative 64-bit value > 2^52 decodes as CborInt64 Negative" <|
            \_ ->
                -- argument = 0x0010000000000001 = 2^52 + 1
                case decodeFromHex CD.item "3b0010000000000001" of
                    Ok (CborInt64 Negative bs) ->
                        Hex.fromBytes bs |> Expect.equal "0010000000000001"

                    other ->
                        Expect.fail ("Expected CborInt64 Negative, got " ++ Debug.toString other)
        , test "64-bit value at exactly 2^52 stays CborInt52" <|
            \_ ->
                -- 0x0010000000000000 = 2^52 = maxSafeInt
                case decodeFromHex CD.item "1b0010000000000000" of
                    Ok (CborInt52 IW64 n) ->
                        Expect.equal 4503599627370496 n

                    other ->
                        Expect.fail ("Expected CborInt52 IW64, got " ++ Debug.toString other)
        , test "CborInt64 round-trip via item" <|
            \_ ->
                let
                    hex : String
                    hex =
                        "1b0010000000000001"
                in
                case decodeFromHex CD.item hex of
                    Ok cborItem ->
                        Hex.fromBytes (CE.encode (CE.item cborItem))
                            |> Expect.equal hex

                    Err err ->
                        Expect.fail ("decode failed: " ++ Debug.toString err)
        ]



-- DIAGNOSTIC NOTATION TESTS


diagnosticTests : Test
diagnosticTests =
    describe "Cbor.diagnose"
        [ test "integer" <|
            \_ -> diagnose (CborInt52 IW0 10) |> Expect.equal "10"
        , test "negative integer" <|
            \_ -> diagnose (CborInt52 IW8 -100) |> Expect.equal "-100_0"
        , test "bool true" <|
            \_ -> diagnose (CborBool True) |> Expect.equal "true"
        , test "bool false" <|
            \_ -> diagnose (CborBool False) |> Expect.equal "false"
        , test "null" <|
            \_ -> diagnose CborNull |> Expect.equal "null"
        , test "undefined" <|
            \_ -> diagnose CborUndefined |> Expect.equal "undefined"
        , test "string" <|
            \_ -> diagnose (CborString "hello") |> Expect.equal "\"hello\""
        , test "string with escapes" <|
            \_ -> diagnose (CborString "a\nb") |> Expect.equal "\"a\\nb\""
        , test "float" <|
            \_ -> diagnose (CborFloat FW16 1.5) |> Expect.equal "1.5_1"
        , test "empty array" <|
            \_ -> diagnose (CborArray Definite []) |> Expect.equal "[]"
        , test "array" <|
            \_ ->
                diagnose
                    (CborArray Definite
                        [ CborInt52 IW0 1
                        , CborInt52 IW0 2
                        , CborInt52 IW0 3
                        ]
                    )
                    |> Expect.equal "[1, 2, 3]"
        , test "indefinite array" <|
            \_ ->
                diagnose
                    (CborArray Indefinite
                        [ CborInt52 IW0 1
                        , CborInt52 IW0 2
                        ]
                    )
                    |> Expect.equal "[_ 1, 2]"
        , test "map" <|
            \_ ->
                diagnose
                    (CborMap Definite
                        [ { key = CborInt52 IW0 1, value = CborInt52 IW0 2 }
                        , { key = CborInt52 IW0 3, value = CborInt52 IW0 4 }
                        ]
                    )
                    |> Expect.equal "{1: 2, 3: 4}"
        , test "tag" <|
            \_ ->
                diagnose (CborTag EpochDateTime (CborInt52 IW0 100))
                    |> Expect.equal "1(100)"
        , test "simple value" <|
            \_ ->
                diagnose (CborSimple SW8 255)
                    |> Expect.equal "simple(255)"
        , test "IW16 suffix" <|
            \_ -> diagnose (CborInt52 IW16 1000) |> Expect.equal "1000_1"
        , test "IW32 suffix" <|
            \_ -> diagnose (CborInt52 IW32 1000000) |> Expect.equal "1000000_2"
        , test "IW64 suffix" <|
            \_ -> diagnose (CborInt52 IW64 1000000000000) |> Expect.equal "1000000000000_3"
        , test "CborInt64 positive" <|
            \_ ->
                diagnose (CborInt64 Positive (Hex.toBytesUnchecked "000000000000002a"))
                    |> Expect.equal "42_3"
        , test "CborInt64 negative" <|
            \_ ->
                diagnose (CborInt64 Negative (Hex.toBytesUnchecked "000000000000002a"))
                    |> Expect.equal "-43_3"
        , test "CborByteString" <|
            \_ ->
                diagnose (CborByteString (Hex.toBytesUnchecked "01020304"))
                    |> Expect.equal "h'01020304'"
        , test "CborByteStringChunked" <|
            \_ ->
                diagnose
                    (CborByteStringChunked
                        [ Hex.toBytesUnchecked "0102"
                        , Hex.toBytesUnchecked "0304"
                        ]
                    )
                    |> Expect.equal "(_ h'0102', h'0304')"
        , test "CborStringChunked" <|
            \_ ->
                diagnose (CborStringChunked [ "hel", "lo" ])
                    |> Expect.equal "(_ \"hel\", \"lo\")"
        , test "CborMap Indefinite" <|
            \_ ->
                diagnose
                    (CborMap Indefinite
                        [ { key = CborInt52 IW0 1, value = CborInt52 IW0 2 } ]
                    )
                    |> Expect.equal "{_ 1: 2}"
        , test "CborFloat FW32" <|
            \_ -> diagnose (CborFloat FW32 1.5) |> Expect.equal "1.5_2"
        , test "CborFloat FW64" <|
            \_ -> diagnose (CborFloat FW64 1.5) |> Expect.equal "1.5_3"
        , test "NaN" <|
            \_ -> diagnose (CborFloat FW16 (0 / 0)) |> Expect.equal "NaN_1"
        , test "Infinity" <|
            \_ -> diagnose (CborFloat FW16 (1 / 0)) |> Expect.equal "Infinity_1"
        , test "-Infinity" <|
            \_ -> diagnose (CborFloat FW16 (-1 / 0)) |> Expect.equal "-Infinity_1"
        , test "integer-valued float" <|
            \_ -> diagnose (CborFloat FW32 1.0) |> Expect.equal "1.0_2"
        ]



-- BIGINT DECODER TESTS


bigIntTests : Test
bigIntTests =
    describe "Cbor.Decode.bigInt"
        [ test "positive small value" <|
            \_ ->
                decodeFromHex CD.bigInt "0a"
                    |> Result.map (\( sign, bs ) -> ( sign, Hex.fromBytes bs ))
                    |> Expect.equal (Ok ( Positive, "0a" ))
        , test "negative small value" <|
            \_ ->
                decodeFromHex CD.bigInt "29"
                    |> Result.map (\( sign, bs ) -> ( sign, Hex.fromBytes bs ))
                    |> Expect.equal (Ok ( Negative, "09" ))
        , test "tag 2 PositiveBigNum" <|
            \_ ->
                decodeFromHex CD.bigInt "c24401020304"
                    |> Result.map (\( sign, bs ) -> ( sign, Hex.fromBytes bs ))
                    |> Expect.equal (Ok ( Positive, "01020304" ))
        , test "tag 3 NegativeBigNum" <|
            \_ ->
                decodeFromHex CD.bigInt "c34401020304"
                    |> Result.map (\( sign, bs ) -> ( sign, Hex.fromBytes bs ))
                    |> Expect.equal (Ok ( Negative, "01020304" ))
        , test "rejects text string" <|
            \_ ->
                decodeFromHex CD.bigInt "60"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "rejects wrong tag" <|
            \_ ->
                decodeFromHex CD.bigInt "c101"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- FOLD ENTRIES TESTS


foldEntriesTests : Test
foldEntriesTests =
    describe "Cbor.Decode.foldEntries"
        [ test "definite map sums values" <|
            \_ ->
                let
                    handler : Int -> Int -> BD.Decoder () CD.DecodeError Int
                    handler _ acc =
                        CD.toBD CD.int |> BD.map (\v -> acc + v)
                in
                decodeFromHex (CD.foldEntries CD.int handler 0) "a201020304"
                    |> Expect.equal (Ok 6)
        , test "empty map" <|
            \_ ->
                decodeFromHex
                    (CD.foldEntries CD.int (\_ acc -> CD.toBD CD.int |> BD.map (\v -> acc + v)) 0)
                    "a0"
                    |> Expect.equal (Ok 0)
        , test "indefinite map" <|
            \_ ->
                let
                    handler : Int -> Int -> BD.Decoder () CD.DecodeError Int
                    handler _ acc =
                        CD.toBD CD.int |> BD.map (\v -> acc + v)
                in
                decodeFromHex (CD.foldEntries CD.int handler 0) "bf01020304ff"
                    |> Expect.equal (Ok 6)
        , test "dispatch on keys with unknown skip" <|
            \_ ->
                let
                    encoded : Bytes.Bytes
                    encoded =
                        CE.encode
                            (CE.map CE.Unsorted
                                Definite
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 1, CE.int 30 )
                                , ( CE.int 99, CE.string "extra" )
                                ]
                            )

                    handler : Int -> Person -> BD.Decoder () CD.DecodeError Person
                    handler key acc =
                        case key of
                            0 ->
                                CD.toBD CD.string |> BD.map (\name -> { acc | name = name })

                            1 ->
                                CD.toBD CD.int |> BD.map (\age -> { acc | age = age })

                            _ ->
                                CD.toBD CD.item |> BD.map (\_ -> acc)
                in
                CD.decode (CD.foldEntries CD.int handler { name = "", age = 0 }) encoded
                    |> Expect.equal (Ok { name = "Alice", age = 30 })
        ]



-- FIELD COMBINATOR TESTS


fieldTests : Test
fieldTests =
    describe "Cbor.Decode.field"
        [ test "key match decodes value" <|
            \_ ->
                decodeFromHex (CD.field 1 CD.int CD.string) "0163666f6f"
                    |> Expect.equal (Ok "foo")
        , test "key mismatch fails" <|
            \_ ->
                decodeFromHex (CD.field 1 CD.int CD.string) "0263666f6f"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- SEQUENCE TESTS


sequenceTests : Test
sequenceTests =
    describe "CE.sequence"
        [ test "concatenates items without wrapping array" <|
            \_ ->
                encodeToHex (CE.sequence [ CE.int 1, CE.string "a" ])
                    |> Expect.equal "016161"
        ]



-- RAW UNSAFE TESTS


rawUnsafeTests : Test
rawUnsafeTests =
    describe "CE.rawUnsafe"
        [ test "pre-encoded bytes pass through unchanged" <|
            \_ ->
                encodeToHex (CE.rawUnsafe (Hex.toBytesUnchecked "f97c00"))
                    |> Expect.equal "f97c00"
        , test "rawUnsafe produces correct bytes" <|
            \_ ->
                Hex.fromBytes
                    (CE.encode
                        (CE.rawUnsafe (Hex.toBytesUnchecked "83010203"))
                    )
                    |> Expect.equal "83010203"
        ]



-- SIMPLE VALUE TESTS


simpleValueTests : Test
simpleValueTests =
    describe "Simple values"
        [ test "simple 0 encodes as SW0" <|
            \_ -> encodeToHex (CE.simple 0) |> Expect.equal "e0"
        , test "simple 19 encodes as SW0" <|
            \_ -> encodeToHex (CE.simple 19) |> Expect.equal "f3"
        , test "simple 32 encodes as SW8" <|
            \_ -> encodeToHex (CE.simple 32) |> Expect.equal "f820"
        , test "simple 255 encodes as SW8" <|
            \_ -> encodeToHex (CE.simple 255) |> Expect.equal "f8ff"
        , test "decode simple 0 via item" <|
            \_ ->
                case decodeFromHex CD.item "e0" of
                    Ok (CborSimple SW0 0) ->
                        Expect.pass

                    other ->
                        Expect.fail ("Expected CborSimple SW0 0, got " ++ Debug.toString other)
        , test "decode simple 32 via item" <|
            \_ ->
                case decodeFromHex CD.item "f820" of
                    Ok (CborSimple SW8 32) ->
                        Expect.pass

                    other ->
                        Expect.fail ("Expected CborSimple SW8 32, got " ++ Debug.toString other)
        ]
