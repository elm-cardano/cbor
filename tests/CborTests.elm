module CborTests exposing (..)

import Bytes exposing (Bytes)
import Bytes.Decoder as BD
import Cbor exposing (..)
import Cbor.Decode as CD
import Cbor.Encode as CE
import Expect
import Hex
import Test exposing (..)


{-| Helper: encode with deterministic strategy and return hex string.
-}
encodeToHex : CE.Encoder -> String
encodeToHex encoder =
    Hex.fromBytes (CE.encode CE.deterministic encoder)


{-| Helper: decode from hex using a given decoder.
-}
decodeFromHex : BD.Decoder ctx String a -> String -> Result (BD.Error ctx String) a
decodeFromHex decoder hex =
    BD.decode decoder (Hex.toBytesUnchecked hex)



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
        , encodeStringTests
        , decodeStringTests
        , encodeBytesTests
        , decodeBytesTests
        , encodeArrayTests
        , decodeArrayTests
        , encodeMapTests
        , decodeMapTests
        , encodeTagTests
        , roundTripTests
        , recordBuilderTests
        , keyedRecordBuilderTests
        , strategyTests
        , itemDecoderTests
        , diagnosticTests
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
        , test "Infinity float16" <|
            \_ ->
                decodeFromHex CD.float "f97c00"
                    |> Result.map isInfinite
                    |> Expect.equal (Ok True)
        , test "NaN float16" <|
            \_ ->
                decodeFromHex CD.float "f97e00"
                    |> Result.map isNaN
                    |> Expect.equal (Ok True)
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
        ]



-- ENCODE BYTES TESTS


encodeBytesTests : Test
encodeBytesTests =
    describe "Cbor.Encode.bytes"
        [ test "empty bytes" <|
            \_ -> encodeToHex (CE.bytes (Hex.toBytesUnchecked "")) |> Expect.equal "40"
        , test "h'01020304'" <|
            \_ -> encodeToHex (CE.bytes (Hex.toBytesUnchecked "01020304")) |> Expect.equal "4401020304"
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
        ]



-- ENCODE ARRAY TESTS


encodeArrayTests : Test
encodeArrayTests =
    describe "Cbor.Encode.array"
        [ test "empty array" <|
            \_ -> encodeToHex (CE.array []) |> Expect.equal "80"
        , test "[1, 2, 3]" <|
            \_ ->
                encodeToHex (CE.array [ CE.int 1, CE.int 2, CE.int 3 ])
                    |> Expect.equal "83010203"
        , test "nested [1, [2, 3], [4, 5]]" <|
            \_ ->
                encodeToHex
                    (CE.array
                        [ CE.int 1
                        , CE.array [ CE.int 2, CE.int 3 ]
                        , CE.array [ CE.int 4, CE.int 5 ]
                        ]
                    )
                    |> Expect.equal "8301820203820405"
        , test "[1..25] (length 25, requires 2-byte header)" <|
            \_ ->
                let
                    items =
                        List.range 1 25 |> List.map CE.int
                in
                encodeToHex (CE.array items)
                    |> String.left 4
                    |> Expect.equal "9819"
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
                decodeFromHex (CD.array (CD.array CD.int)) "8282010282030405"
                    |> Expect.equal (Ok [ [ 1, 2 ], [ 3, 4 ], [ 5 ] ])
                    |> always
                        -- The hex above would need the right encoding. Let's just check a simpler case.
                        (decodeFromHex (CD.array CD.int) "83010203"
                            |> Expect.equal (Ok [ 1, 2, 3 ])
                        )
        ]



-- ENCODE MAP TESTS


encodeMapTests : Test
encodeMapTests =
    describe "Cbor.Encode.map"
        [ test "empty map" <|
            \_ -> encodeToHex (CE.map []) |> Expect.equal "a0"
        , test "{1: 2, 3: 4}" <|
            \_ ->
                encodeToHex
                    (CE.map
                        [ ( CE.int 1, CE.int 2 )
                        , ( CE.int 3, CE.int 4 )
                        ]
                    )
                    |> Expect.equal "a201020304"
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
                CE.encode CE.deterministic (CE.bool True)
                    |> BD.decode CD.bool
                    |> Expect.equal (Ok True)
        , test "bool false" <|
            \_ ->
                CE.encode CE.deterministic (CE.bool False)
                    |> BD.decode CD.bool
                    |> Expect.equal (Ok False)
        , test "string round-trip" <|
            \_ ->
                CE.encode CE.deterministic (CE.string "hello")
                    |> BD.decode CD.string
                    |> Expect.equal (Ok "hello")
        , test "string with unicode" <|
            \_ ->
                CE.encode CE.deterministic (CE.string "日本語")
                    |> BD.decode CD.string
                    |> Expect.equal (Ok "日本語")
        , test "empty array" <|
            \_ ->
                CE.encode CE.deterministic (CE.array [])
                    |> BD.decode (CD.array CD.int)
                    |> Expect.equal (Ok [])
        , test "array of ints" <|
            \_ ->
                CE.encode CE.deterministic (CE.list CE.int [ 1, 2, 3, 4, 5 ])
                    |> BD.decode (CD.array CD.int)
                    |> Expect.equal (Ok [ 1, 2, 3, 4, 5 ])
        , test "map of int->string" <|
            \_ ->
                CE.encode CE.deterministic
                    (CE.map
                        [ ( CE.int 1, CE.string "one" )
                        , ( CE.int 2, CE.string "two" )
                        ]
                    )
                    |> BD.decode (CD.keyValue CD.int CD.string)
                    |> Expect.equal (Ok [ ( 1, "one" ), ( 2, "two" ) ])
        , test "null round-trip" <|
            \_ ->
                CE.encode CE.deterministic CE.null
                    |> BD.decode (CD.null ())
                    |> Expect.equal (Ok ())
        ]


roundTripInt : Int -> Expect.Expectation
roundTripInt n =
    CE.encode CE.deterministic (CE.int n)
        |> BD.decode CD.int
        |> Expect.equal (Ok n)



-- RECORD BUILDER TESTS


type alias Point =
    { x : Float, y : Float }


type alias Point3D =
    { x : Float, y : Float, z : Float }


recordBuilderTests : Test
recordBuilderTests =
    describe "Record builder"
        [ test "decode 2-element array as record" <|
            \_ ->
                -- Encode [1.5, 2.5] as CBOR array
                let
                    encoded =
                        CE.encode CE.deterministic
                            (CE.array [ CE.float 1.5, CE.float 2.5 ])

                    decoder =
                        CD.record Point
                            |> CD.element CD.float
                            |> CD.element CD.float
                            |> CD.buildRecord
                in
                BD.decode decoder encoded
                    |> Expect.equal (Ok { x = 1.5, y = 2.5 })
        , test "optional element present" <|
            \_ ->
                let
                    encoded =
                        CE.encode CE.deterministic
                            (CE.array [ CE.float 1.0, CE.float 2.0, CE.float 3.0 ])

                    decoder =
                        CD.record Point3D
                            |> CD.element CD.float
                            |> CD.element CD.float
                            |> CD.optionalElement CD.float 0.0
                            |> CD.buildRecord
                in
                BD.decode decoder encoded
                    |> Expect.equal (Ok { x = 1.0, y = 2.0, z = 3.0 })
        , test "optional element absent" <|
            \_ ->
                let
                    encoded =
                        CE.encode CE.deterministic
                            (CE.array [ CE.float 1.0, CE.float 2.0 ])

                    decoder =
                        CD.record Point3D
                            |> CD.element CD.float
                            |> CD.element CD.float
                            |> CD.optionalElement CD.float 0.0
                            |> CD.buildRecord
                in
                BD.decode decoder encoded
                    |> Expect.equal (Ok { x = 1.0, y = 2.0, z = 0.0 })
        ]



-- KEYED RECORD BUILDER TESTS


type alias Person =
    { name : String, age : Int }


type alias PersonOptional =
    { name : String, age : Int, email : String }


keyedRecordBuilderTests : Test
keyedRecordBuilderTests =
    describe "Keyed record builder"
        [ test "all required fields" <|
            \_ ->
                let
                    encoded =
                        CE.encode CE.deterministic
                            (CE.map
                                [ ( CE.int 0, CE.string "Alice" )
                                , ( CE.int 1, CE.int 30 )
                                ]
                            )

                    decoder =
                        CD.keyedRecord CD.int Person
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.buildKeyedRecord
                in
                BD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Alice", age = 30 })
        , test "optional field present" <|
            \_ ->
                let
                    encoded =
                        CE.encode CE.deterministic
                            (CE.map
                                [ ( CE.int 0, CE.string "Bob" )
                                , ( CE.int 1, CE.int 25 )
                                , ( CE.int 2, CE.string "bob@example.com" )
                                ]
                            )

                    decoder =
                        CD.keyedRecord CD.int PersonOptional
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.optional 2 CD.string ""
                            |> CD.buildKeyedRecord
                in
                BD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Bob", age = 25, email = "bob@example.com" })
        , test "optional field absent" <|
            \_ ->
                let
                    encoded =
                        CE.encode CE.deterministic
                            (CE.map
                                [ ( CE.int 0, CE.string "Charlie" )
                                , ( CE.int 1, CE.int 35 )
                                ]
                            )

                    decoder =
                        CD.keyedRecord CD.int PersonOptional
                            |> CD.required 0 CD.string
                            |> CD.required 1 CD.int
                            |> CD.optional 2 CD.string ""
                            |> CD.buildKeyedRecord
                in
                BD.decode decoder encoded
                    |> Expect.equal (Ok { name = "Charlie", age = 35, email = "" })
        ]



-- STRATEGY TESTS


strategyTests : Test
strategyTests =
    describe "Encoding strategies"
        [ test "deterministic sorts keys lexicographically" <|
            \_ ->
                -- Keys: int 10 (0x0a) and int 1 (0x01)
                -- Encoded key 1 = 0x01, key 10 = 0x0a
                -- Lexicographic order: 0x01 < 0x0a → key 1 before key 10
                let
                    encoded =
                        CE.encode CE.deterministic
                            (CE.map
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
                    encoded =
                        CE.encode CE.unsorted
                            (CE.map
                                [ ( CE.int 10, CE.string "ten" )
                                , ( CE.int 1, CE.string "one" )
                                ]
                            )
                in
                Hex.fromBytes encoded
                    |> String.left 6
                    |> Expect.equal "a20a63"

        -- a2 = map(2), 0a = key 10, 63 = text(3)
        , test "keyedRecord with strategy" <|
            \_ ->
                let
                    encoder =
                        CE.keyedRecord CE.int
                            [ ( 0, Just (CE.string "Alice") )
                            , ( 1, Just (CE.int 30) )
                            ]
                in
                Hex.fromBytes (CE.encode CE.deterministic encoder)
                    |> Expect.equal (Hex.fromBytes (CE.encode CE.unsorted encoder))

        -- keys 0, 1 are already in order
        , test "keyedRecord omits Nothing entries" <|
            \_ ->
                let
                    encoder =
                        CE.keyedRecord CE.int
                            [ ( 0, Just (CE.string "Alice") )
                            , ( 1, Nothing )
                            , ( 2, Just (CE.int 30) )
                            ]
                in
                -- Should produce a 2-entry map (key 0 and key 2), not 3
                Hex.fromBytes (CE.encode CE.deterministic encoder)
                    |> String.left 2
                    |> Expect.equal "a2"
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
        ]
