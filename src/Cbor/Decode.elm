module Cbor.Decode exposing
    ( CborDecoder, decode
    , errorToString
    , succeed, fail
    , map, map2, andThen, oneOf, keep, ignore, lazy
    , int, bigInt, float, bool, null, string, bytes
    , array, keyValue, field, foldEntries, tag
    , RecordBuilder, record, element, optionalElement, ExtraElements(..), buildRecord
    , KeyedRecordBuilder, keyedRecord, required, optional, buildKeyedRecord
    , UnorderedRecordBuilder, unorderedRecord, onKey, buildUnorderedRecord
    , arrayHeader, mapHeader
    , item, itemSkip
    )

{-| CBOR decoding combinators.

Build decoders for your domain types. These produce `CborDecoder` values.
Run them with `decode`.

    import Cbor.Decode as CD

    type alias Person =
        { name : String, age : Int }

    decodePerson : CD.CborDecoder ctx Person
    decodePerson =
        CD.keyedRecord CD.int String.fromInt Person
            |> CD.required 0 CD.string
            |> CD.required 1 CD.int
            |> CD.buildKeyedRecord CD.IgnoreExtra

    -- To run: CD.decode decodePerson someBytes


## Type

@docs CborDecoder, decode


## Errors

@docs errorToString


## Combinators

@docs succeed, fail
@docs map, map2, andThen, oneOf, keep, ignore, lazy


## Primitives

@docs int, bigInt, float, bool, null, string, bytes


## Collections

@docs array, keyValue, field, foldEntries, tag


## Record Builder (CBOR arrays → Elm values)

@docs RecordBuilder, record, element, optionalElement, ExtraElements, buildRecord


## Keyed Record Builder (CBOR maps → Elm values)

@docs KeyedRecordBuilder, keyedRecord, required, optional, buildKeyedRecord


## Unordered Record Builder (CBOR maps → Elm values, any key order)

@docs UnorderedRecordBuilder, unorderedRecord, onKey, buildUnorderedRecord


## Structure Headers

@docs arrayHeader, mapHeader


## Escape Hatch

@docs item, itemSkip

-}

import Bitwise
import Bytes
import Bytes.Decoder as BD
import Cbor exposing (CborItem, DecodeError(..), Sign, Tag, tagToInt)
import Dict exposing (Dict)
import Internal.Cbor.Decode as Inner



-- TYPE


{-| Opaque CBOR decoder.

Internally uses two variants: `Item` receives a pre-read initial byte
(the CBOR byte encoding major type + additional info), and `Pure` consumes
no initial byte (used only by `succeed` and `fail`). This split lets
combinators route the initial byte to the first decoder that needs it,
and lets collection decoders detect indefinite-length break bytes on
the fast path without `BD.oneOf`.

-}
type CborDecoder ctx a
    = Item (Int -> BD.Decoder ctx DecodeError a)
    | Pure (BD.Decoder ctx DecodeError a)


toBD : CborDecoder ctx a -> BD.Decoder ctx DecodeError a
toBD decoder =
    case decoder of
        Item body ->
            u8 |> BD.andThen body

        Pure bd ->
            bd


{-| Run a `CborDecoder` on some `Bytes`.
-}
decode : CborDecoder ctx a -> Bytes.Bytes -> Result (BD.Error ctx DecodeError) a
decode decoder input =
    BD.decode (toBD decoder) input



-- ERRORS


{-| Convert a `DecodeError` to a human-readable string.
-}
errorToString : DecodeError -> String
errorToString err =
    case err of
        WrongMajorType { expected, got } ->
            "Expected major type " ++ String.fromInt expected ++ " but got " ++ String.fromInt got

        WrongInitialByte { got } ->
            "Unexpected initial byte: 0x" ++ Inner.intToHex got

        WrongTag { expected, got } ->
            "Expected tag " ++ String.fromInt expected ++ " but got " ++ String.fromInt got

        ReservedAdditionalInfo ai ->
            "Reserved additional info: " ++ String.fromInt ai

        IntegerOverflow ->
            "Integer value exceeds safe range (2^52)"

        MissingKey key ->
            "Missing required key: " ++ key

        KeyMismatch { expected, got } ->
            "Key mismatch: expected " ++ expected ++ " but got " ++ got

        TooFewElements maybeCounts ->
            case maybeCounts of
                Just { expected, got } ->
                    "Too few elements: expected " ++ String.fromInt expected ++ " but got " ++ String.fromInt got

                Nothing ->
                    "Too few elements"

        TooManyElements maybeCounts ->
            case maybeCounts of
                Just { expected, got } ->
                    "Too many elements: expected " ++ String.fromInt expected ++ " but got " ++ String.fromInt got

                Nothing ->
                    "Too many elements"

        FailedToFinalizeRecord ->
            "Failed to finalize record: not all required fields were decoded"

        ForbiddenPureInCollection ->
            "A non-consuming decoder (succeed/fail) cannot be used as a direct element of a collection"

        UnknownMajorType mt ->
            "Unknown major type: " ++ String.fromInt mt



-- COMBINATORS


{-| A decoder that always succeeds with the given value, consuming no bytes.
-}
succeed : a -> CborDecoder ctx a
succeed a =
    Pure (BD.succeed a)


{-| A decoder that always fails with the given error.
-}
fail : DecodeError -> CborDecoder ctx a
fail err =
    Pure (BD.fail err)


{-| Transform the result of a decoder.
-}
map : (a -> b) -> CborDecoder ctx a -> CborDecoder ctx b
map f decoder =
    case decoder of
        Item body ->
            Item (\ib -> body ib |> BD.map f)

        Pure bd ->
            Pure (bd |> BD.map f)


{-| Combine two decoders sequentially.
-}
map2 : (a -> b -> c) -> CborDecoder ctx a -> CborDecoder ctx b -> CborDecoder ctx c
map2 f decoderA decoderB =
    case decoderA of
        Item bodyA ->
            let
                bdB : BD.Decoder ctx DecodeError b
                bdB =
                    toBD decoderB
            in
            Item (\ib -> BD.map2 f (bodyA ib) bdB)

        Pure bdA ->
            case decoderB of
                Item bodyB ->
                    Item (\ib -> BD.map2 f bdA (bodyB ib))

                Pure bdB ->
                    Pure (BD.map2 f bdA bdB)


{-| Chain decoders. The continuation is chosen based on the first result.
-}
andThen : (a -> CborDecoder ctx b) -> CborDecoder ctx a -> CborDecoder ctx b
andThen f decoder =
    case decoder of
        Item body ->
            Item (\ib -> body ib |> BD.andThen (\a -> toBD (f a)))

        Pure bd ->
            Pure (bd |> BD.andThen (\a -> toBD (f a)))


{-| Try multiple decoders in order. Each decoder sees the same initial byte.
-}
oneOf : List (CborDecoder ctx a) -> CborDecoder ctx a
oneOf decoders =
    Item
        (\initialByte ->
            BD.oneOf
                (List.map
                    (\d ->
                        case d of
                            Item body ->
                                body initialByte

                            Pure bd ->
                                bd
                    )
                    decoders
                )
        )


{-| Apply a decoder producing a function to a decoder producing an argument.

    succeed Point
        |> keep float
        |> keep float

-}
keep : CborDecoder ctx a -> CborDecoder ctx (a -> b) -> CborDecoder ctx b
keep valueDecoder funcDecoder =
    case funcDecoder of
        Pure funcBd ->
            case valueDecoder of
                Item valueBody ->
                    Item (\ib -> BD.map2 (\f v -> f v) funcBd (valueBody ib))

                Pure valueBd ->
                    Pure (BD.map2 (\f v -> f v) funcBd valueBd)

        Item funcBody ->
            let
                valueBD : BD.Decoder ctx DecodeError a
                valueBD =
                    toBD valueDecoder
            in
            Item (\ib -> BD.map2 (\f v -> f v) (funcBody ib) valueBD)


{-| Decode and discard a value, keeping the previous result.
-}
ignore : CborDecoder ctx ignored -> CborDecoder ctx keep -> CborDecoder ctx keep
ignore ignoredDecoder keepDecoder =
    case keepDecoder of
        Item keepBody ->
            let
                ignoredBD : BD.Decoder ctx DecodeError ignored
                ignoredBD =
                    toBD ignoredDecoder
            in
            Item (\ib -> BD.map2 (\k _ -> k) (keepBody ib) ignoredBD)

        Pure keepBd ->
            case ignoredDecoder of
                Item ignoredBody ->
                    Item (\ib -> BD.map2 (\k _ -> k) keepBd (ignoredBody ib))

                Pure ignoredBd ->
                    Pure (BD.map2 (\k _ -> k) keepBd ignoredBd)


{-| Deferred construction for recursive decoders.
-}
lazy : (() -> CborDecoder ctx a) -> CborDecoder ctx a
lazy thunk =
    Item
        (\ib ->
            case thunk () of
                Item body ->
                    body ib

                Pure bd ->
                    bd
        )



-- INTERNAL HELPERS


u8 : BD.Decoder ctx err Int
u8 =
    Inner.u8


withArgument : Int -> (Int -> BD.Decoder ctx DecodeError a) -> BD.Decoder ctx DecodeError a
withArgument =
    Inner.withArgument


skipEntries : Int -> BD.Decoder ctx DecodeError ()
skipEntries =
    Inner.skipEntries



-- PRIMITIVES


{-| Decode a CBOR integer (major types 0 and 1).

Fails if the absolute value exceeds 2^52. For larger values, use `bigInt`.

-}
int : CborDecoder ctx Int
int =
    Item Inner.int


{-| Decode any CBOR integer, including bignums (tags 2 and 3).

Returns `( Sign, Bytes )` where `Bytes` is the minimal big-endian
representation of the unsigned argument.

-}
bigInt : CborDecoder ctx ( Sign, Bytes.Bytes )
bigInt =
    Item Inner.bigInt


{-| Decode a CBOR float (major type 7, additional info 25/26/27).
-}
float : CborDecoder ctx Float
float =
    Item Inner.float


{-| Decode a CBOR boolean (0xF4 for false, 0xF5 for true).
-}
bool : CborDecoder ctx Bool
bool =
    Item Inner.bool


{-| Decode a CBOR null (0xF6), returning the provided default value.
-}
null : a -> CborDecoder ctx a
null default =
    Item (Inner.null default)


{-| Decode a CBOR text string (major type 3).

Concatenates indefinite-length chunks transparently.

-}
string : CborDecoder ctx String
string =
    Item Inner.string


{-| Decode a CBOR byte string (major type 2).

Concatenates indefinite-length chunks transparently.

-}
bytes : CborDecoder ctx Bytes.Bytes
bytes =
    Item Inner.bytes



-- COLLECTIONS


{-| Decode a CBOR array (major type 4) where all elements use the same decoder.

Handles both definite and indefinite-length arrays. The element decoder
must be an `Item` (i.e. consume bytes); using `succeed` or `fail` directly
as an element decoder will produce a `ForbiddenPureInCollection` error.

-}
array : CborDecoder ctx a -> CborDecoder ctx (List a)
array elementDecoder =
    case elementDecoder of
        Pure _ ->
            Item (\_ -> BD.fail ForbiddenPureInCollection)

        Item elementBody ->
            let
                elementBD : BD.Decoder ctx DecodeError a
                elementBD =
                    u8 |> BD.andThen elementBody
            in
            Item
                (\initialByte ->
                    let
                        majorType : Int
                        majorType =
                            Bitwise.shiftRightZfBy 5 initialByte
                    in
                    if majorType /= 4 then
                        BD.fail (WrongMajorType { expected = 4, got = majorType })

                    else
                        let
                            additionalInfo : Int
                            additionalInfo =
                                Bitwise.and 0x1F initialByte
                        in
                        if additionalInfo == 31 then
                            BD.loop
                                (\acc ->
                                    u8
                                        |> BD.andThen
                                            (\byte ->
                                                if byte == 0xFF then
                                                    BD.succeed (BD.Done (List.reverse acc))

                                                else
                                                    elementBody byte
                                                        |> BD.map (\v -> BD.Loop (v :: acc))
                                            )
                                )
                                []

                        else
                            withArgument additionalInfo
                                (\count -> BD.repeat elementBD count)
                )


{-| Decode a CBOR map (major type 5) as a list of key-value pairs.

Handles both definite and indefinite-length maps.

-}
keyValue : CborDecoder ctx k -> CborDecoder ctx v -> CborDecoder ctx (List ( k, v ))
keyValue keyDecoder valueDecoder =
    case keyDecoder of
        Pure _ ->
            Item (\_ -> BD.fail ForbiddenPureInCollection)

        Item keyBody ->
            let
                valueBD : BD.Decoder ctx DecodeError v
                valueBD =
                    toBD valueDecoder

                keyBD : BD.Decoder ctx DecodeError k
                keyBD =
                    u8 |> BD.andThen keyBody
            in
            Item
                (\initialByte ->
                    let
                        majorType : Int
                        majorType =
                            Bitwise.shiftRightZfBy 5 initialByte
                    in
                    if majorType /= 5 then
                        BD.fail (WrongMajorType { expected = 5, got = majorType })

                    else
                        let
                            additionalInfo : Int
                            additionalInfo =
                                Bitwise.and 0x1F initialByte
                        in
                        if additionalInfo == 31 then
                            BD.loop
                                (\acc ->
                                    u8
                                        |> BD.andThen
                                            (\byte ->
                                                if byte == 0xFF then
                                                    BD.succeed (BD.Done (List.reverse acc))

                                                else
                                                    BD.map2
                                                        (\k v -> BD.Loop (( k, v ) :: acc))
                                                        (keyBody byte)
                                                        valueBD
                                            )
                                )
                                []

                        else
                            withArgument additionalInfo
                                (\count ->
                                    BD.repeat
                                        (BD.map2 Tuple.pair keyBD valueBD)
                                        count
                                )
                )


{-| Decode the next map entry, expecting a specific key.

Reads the key, compares via `==`, then decodes the value on match.
Fails on mismatch.

-}
field : k -> (k -> String) -> CborDecoder ctx k -> CborDecoder ctx v -> CborDecoder ctx v
field expectedKey displayKey keyDecoder valueDecoder =
    keyDecoder
        |> andThen
            (\key ->
                if key == expectedKey then
                    valueDecoder

                else
                    fail (KeyMismatch { expected = displayKey expectedKey, got = displayKey key })
            )


{-| Fold over map entries with a handler for each key.

Reads the map header, then loops through entries. For each entry: decode
the key, call the handler with the key and current accumulator. The handler
decodes the value and returns the updated accumulator.

**Important**: the handler MUST decode exactly one value per call.

    handler key acc =
        case key of
            0 ->
                map (\name -> { acc | name = name }) string

            1 ->
                map (\age -> { acc | age = age }) int

            _ ->
                map (\_ -> acc) itemSkip

-}
foldEntries :
    CborDecoder ctx k
    -> (k -> acc -> CborDecoder ctx acc)
    -> acc
    -> CborDecoder ctx acc
foldEntries keyDecoder handler initialAcc =
    case keyDecoder of
        Pure _ ->
            Item (\_ -> BD.fail ForbiddenPureInCollection)

        Item keyBody ->
            let
                keyBD : BD.Decoder ctx DecodeError k
                keyBD =
                    u8 |> BD.andThen keyBody
            in
            Item
                (\initialByte ->
                    let
                        majorType : Int
                        majorType =
                            Bitwise.shiftRightZfBy 5 initialByte
                    in
                    if majorType /= 5 then
                        BD.fail (WrongMajorType { expected = 5, got = majorType })

                    else
                        let
                            additionalInfo : Int
                            additionalInfo =
                                Bitwise.and 0x1F initialByte
                        in
                        if additionalInfo == 31 then
                            BD.loop
                                (\acc ->
                                    u8
                                        |> BD.andThen
                                            (\byte ->
                                                if byte == 0xFF then
                                                    BD.succeed (BD.Done acc)

                                                else
                                                    keyBody byte
                                                        |> BD.andThen (\key -> toBD (handler key acc))
                                                        |> BD.map BD.Loop
                                            )
                                )
                                initialAcc

                        else
                            withArgument additionalInfo
                                (\count ->
                                    BD.loop
                                        (\( remaining, acc ) ->
                                            if remaining <= 0 then
                                                BD.succeed (BD.Done acc)

                                            else
                                                keyBD
                                                    |> BD.andThen (\key -> toBD (handler key acc))
                                                    |> BD.map (\newAcc -> BD.Loop ( remaining - 1, newAcc ))
                                        )
                                        ( count, initialAcc )
                                )
                )


{-| Decode a tagged CBOR value (major type 6).

Expects a specific tag, then decodes the enclosed item.

-}
tag : Tag -> CborDecoder ctx a -> CborDecoder ctx a
tag expectedTag innerDecoder =
    let
        innerBD : BD.Decoder ctx DecodeError a
        innerBD =
            toBD innerDecoder
    in
    Item
        (\initialByte ->
            let
                majorType : Int
                majorType =
                    Bitwise.shiftRightZfBy 5 initialByte
            in
            if majorType /= 6 then
                BD.fail (WrongMajorType { expected = 6, got = majorType })

            else
                withArgument (Bitwise.and 0x1F initialByte)
                    (\tagNum ->
                        if tagNum == tagToInt expectedTag then
                            innerBD

                        else
                            BD.fail (WrongTag { expected = tagToInt expectedTag, got = tagNum })
                    )
        )



-- STRUCTURE HEADERS


{-| Decode a CBOR array header, returning the count or `Nothing` for
indefinite-length.
-}
arrayHeader : CborDecoder ctx (Maybe Int)
arrayHeader =
    Item Inner.arrayHeader


{-| Decode a CBOR map header, returning the entry count or `Nothing` for
indefinite-length.
-}
mapHeader : CborDecoder ctx (Maybe Int)
mapHeader =
    Item Inner.mapHeader



-- RECORD BUILDER (CBOR arrays → Elm values)


{-| Opaque builder for decoding CBOR arrays into Elm values.

Uses `SimpleBuilder` when all fields are `element` (fast path via `keep`),
or `CountedBuilder` when `optionalElement` is used (counts remaining items).

-}
type RecordBuilder ctx a
    = SimpleBuilder Int (CborDecoder ctx a)
    | CountedBuilder (Int -> BD.Decoder ctx DecodeError ( Int, a ))


{-| Start building a record decoder with the constructor function.

    record Point
        |> element float
        |> element float
        |> buildRecord IgnoreExtra

-}
record : a -> RecordBuilder ctx a
record constructor =
    SimpleBuilder 0 (succeed constructor)


{-| Decode one array element, applying it to the constructor.
-}
element : CborDecoder ctx v -> RecordBuilder ctx (v -> a) -> RecordBuilder ctx a
element valueDecoder builder =
    case builder of
        SimpleBuilder count funcDecoder ->
            SimpleBuilder (count + 1) (keep valueDecoder funcDecoder)

        CountedBuilder innerDecoder ->
            let
                valueBD : BD.Decoder ctx DecodeError v
                valueBD =
                    toBD valueDecoder
            in
            CountedBuilder
                (\remaining ->
                    innerDecoder remaining
                        |> BD.andThen
                            (\( rem, f ) ->
                                if rem > 0 then
                                    valueBD
                                        |> BD.map (\v -> ( rem - 1, f v ))

                                else if rem < 0 then
                                    -- Indefinite mode: check for break byte
                                    u8
                                        |> BD.andThen (breakOrRead valueDecoder)
                                        |> BD.andThen
                                            (\maybeV ->
                                                case maybeV of
                                                    Nothing ->
                                                        BD.fail (TooFewElements Nothing)

                                                    Just v ->
                                                        BD.succeed ( rem, f v )
                                            )

                                else
                                    BD.fail (TooFewElements Nothing)
                            )
                )


{-| Decode an optional array element, using the default if no items remain.

Optional elements must be at the end of the array.

-}
optionalElement : CborDecoder ctx v -> v -> RecordBuilder ctx (v -> a) -> RecordBuilder ctx a
optionalElement valueDecoder default builder =
    let
        valueBD : BD.Decoder ctx DecodeError v
        valueBD =
            toBD valueDecoder

        counted : Int -> BD.Decoder ctx DecodeError ( Int, v -> a )
        counted =
            toCountedInner builder
    in
    CountedBuilder
        (\remaining ->
            counted remaining
                |> BD.andThen
                    (\( rem, f ) ->
                        if rem > 0 then
                            valueBD
                                |> BD.map (\v -> ( rem - 1, f v ))

                        else if rem < 0 then
                            -- Indefinite mode: check for break byte
                            u8
                                |> BD.andThen (breakOrRead valueDecoder)
                                |> BD.andThen
                                    (\maybeV ->
                                        case maybeV of
                                            Nothing ->
                                                BD.succeed ( 0, f default )

                                            Just v ->
                                                BD.succeed ( rem, f v )
                                    )

                        else
                            BD.succeed ( 0, f default )
                    )
        )


toCountedInner : RecordBuilder ctx a -> (Int -> BD.Decoder ctx DecodeError ( Int, a ))
toCountedInner builder =
    case builder of
        SimpleBuilder count decoder ->
            let
                decoderBD : BD.Decoder ctx DecodeError a
                decoderBD =
                    toBD decoder
            in
            \remaining ->
                decoderBD |> BD.map (\value -> ( remaining - count, value ))

        CountedBuilder inner ->
            inner


{-| What to do when the CBOR array has more elements than the builder expects.

  - `IgnoreExtra` — silently skip trailing elements (forward-compatible).
  - `FailOnExtra` — fail with `TooManyElements` (strict validation).

-}
type ExtraElements
    = IgnoreExtra
    | FailOnExtra


{-| Finalize a record builder into a decoder.

Reads the array header, runs the builder pipeline, and handles any
extra elements according to the `ExtraElements` strategy.

-}
buildRecord : ExtraElements -> RecordBuilder ctx a -> CborDecoder ctx a
buildRecord extra builder =
    case builder of
        SimpleBuilder expectedCount decoder ->
            arrayHeader
                |> andThen
                    (\maybeN ->
                        case maybeN of
                            Just n ->
                                if n < expectedCount then
                                    fail (TooFewElements (Just { expected = expectedCount, got = n }))

                                else if n == expectedCount then
                                    decoder

                                else
                                    case extra of
                                        IgnoreExtra ->
                                            decoder
                                                |> ignore (Pure (skipNFullItems (n - expectedCount)))

                                        FailOnExtra ->
                                            fail (TooManyElements (Just { expected = expectedCount, got = n }))

                            Nothing ->
                                case extra of
                                    IgnoreExtra ->
                                        decoder
                                            |> ignore (Pure skipIndefiniteElements)

                                    FailOnExtra ->
                                        decoder
                                            |> ignore (Item expectBreak)
                    )

        CountedBuilder decoder ->
            andThen
                (\maybeN ->
                    case maybeN of
                        Just n ->
                            Pure
                                (decoder n
                                    |> BD.andThen
                                        (\( rem, value ) ->
                                            if rem == 0 then
                                                BD.succeed value

                                            else
                                                case extra of
                                                    IgnoreExtra ->
                                                        skipNFullItems rem
                                                            |> BD.map (\_ -> value)

                                                    FailOnExtra ->
                                                        BD.fail (TooManyElements Nothing)
                                        )
                                )

                        Nothing ->
                            Pure
                                (decoder -1
                                    |> BD.andThen
                                        (\( rem, value ) ->
                                            if rem == 0 then
                                                -- Break was consumed by optionalElement
                                                BD.succeed value

                                            else
                                                -- rem < 0: indefinite, need to consume remaining entries
                                                case extra of
                                                    IgnoreExtra ->
                                                        skipIndefiniteElements
                                                            |> BD.map (\_ -> value)

                                                    FailOnExtra ->
                                                        u8
                                                            |> BD.andThen expectBreak
                                                            |> BD.map (\_ -> value)
                                        )
                                )
                )
                arrayHeader



-- KEYED RECORD BUILDER (CBOR maps → Elm values)


{-| Opaque builder for decoding CBOR maps into Elm values.
-}
type KeyedRecordBuilder ctx k a
    = KeyedRecordBuilder (CborDecoder ctx k) (k -> String) (Int -> BD.Decoder ctx DecodeError (KeyedState k a))


type alias KeyedState k a =
    { remaining : Int
    , pendingKey : Maybe k
    , value : a
    }


{-| Start building a keyed record decoder.

    keyedRecord int String.fromInt Person
        |> required 0 string
        |> required 1 int
        |> buildKeyedRecord IgnoreExtra

-}
keyedRecord : CborDecoder ctx k -> (k -> String) -> a -> KeyedRecordBuilder ctx k a
keyedRecord keyDecoder displayKey constructor =
    KeyedRecordBuilder keyDecoder
        displayKey
        (\remaining ->
            BD.succeed
                { remaining = remaining
                , pendingKey = Nothing
                , value = constructor
                }
        )


{-| Decode a required map field by key.

The key order in the builder must match the key order in the CBOR data.

-}
required : k -> CborDecoder ctx v -> KeyedRecordBuilder ctx k (v -> a) -> KeyedRecordBuilder ctx k a
required expectedKey valueDecoder (KeyedRecordBuilder keyDecoder displayKey innerDecoder) =
    let
        keyBD : BD.Decoder ctx DecodeError k
        keyBD =
            toBD keyDecoder

        valueBD : BD.Decoder ctx DecodeError v
        valueBD =
            toBD valueDecoder

        matchKey : k -> KeyedState k (v -> a) -> BD.Decoder ctx DecodeError (KeyedState k a)
        matchKey key state =
            if key == expectedKey then
                valueBD
                    |> BD.map
                        (\v ->
                            { remaining = state.remaining - 1
                            , pendingKey = Nothing
                            , value = state.value v
                            }
                        )

            else
                BD.fail (KeyMismatch { expected = displayKey expectedKey, got = displayKey key })
    in
    KeyedRecordBuilder keyDecoder
        displayKey
        (\remaining ->
            innerDecoder remaining
                |> BD.andThen
                    (\state ->
                        case state.pendingKey of
                            Just k ->
                                matchKey k state

                            Nothing ->
                                if state.remaining == 0 then
                                    BD.fail (MissingKey (displayKey expectedKey))

                                else if state.remaining < 0 then
                                    -- IndefiniteLength
                                    u8
                                        |> BD.andThen (breakOrRead keyDecoder)
                                        |> BD.andThen
                                            (\maybeKey ->
                                                case maybeKey of
                                                    Nothing ->
                                                        BD.fail (MissingKey (displayKey expectedKey))

                                                    Just key ->
                                                        matchKey key state
                                            )

                                else
                                    keyBD |> BD.andThen (\key -> matchKey key state)
                    )
        )


{-| Decode an optional map field by key.

If the next key doesn't match, the key is stashed for the next step
and the default value is used.

-}
optional : k -> CborDecoder ctx v -> v -> KeyedRecordBuilder ctx k (v -> a) -> KeyedRecordBuilder ctx k a
optional expectedKey valueDecoder default (KeyedRecordBuilder keyDecoder displayKey innerDecoder) =
    let
        keyBD : BD.Decoder ctx DecodeError k
        keyBD =
            toBD keyDecoder

        valueBD : BD.Decoder ctx DecodeError v
        valueBD =
            toBD valueDecoder

        matchKey : k -> KeyedState k (v -> a) -> BD.Decoder ctx DecodeError (KeyedState k a)
        matchKey key state =
            if key == expectedKey then
                valueBD
                    |> BD.map
                        (\v ->
                            { remaining = state.remaining - 1
                            , pendingKey = Nothing
                            , value = state.value v
                            }
                        )

            else
                BD.succeed
                    { remaining = state.remaining
                    , pendingKey = Just key
                    , value = state.value default
                    }
    in
    KeyedRecordBuilder keyDecoder
        displayKey
        (\remaining ->
            innerDecoder remaining
                |> BD.andThen
                    (\state ->
                        if state.remaining == 0 && state.pendingKey == Nothing then
                            BD.succeed
                                { remaining = state.remaining
                                , pendingKey = Nothing
                                , value = state.value default
                                }

                        else
                            case state.pendingKey of
                                Just k ->
                                    matchKey k state

                                Nothing ->
                                    if state.remaining < 0 then
                                        -- IndefiniteLength
                                        u8
                                            |> BD.andThen (breakOrRead keyDecoder)
                                            |> BD.andThen
                                                (\maybeKey ->
                                                    case maybeKey of
                                                        Nothing ->
                                                            BD.succeed
                                                                { remaining = 0
                                                                , pendingKey = Nothing
                                                                , value = state.value default
                                                                }

                                                        Just key ->
                                                            matchKey key state
                                                )

                                    else
                                        keyBD |> BD.andThen (\key -> matchKey key state)
                    )
        )


{-| Finalize a keyed record builder into a decoder.

Reads the map header, runs the builder pipeline, and verifies all
entries were consumed.

-}
buildKeyedRecord : ExtraElements -> KeyedRecordBuilder ctx k a -> CborDecoder ctx a
buildKeyedRecord extra (KeyedRecordBuilder _ _ decoder) =
    mapHeader
        |> andThen
            (\maybeN ->
                case maybeN of
                    Just n ->
                        Pure
                            (decoder n
                                |> BD.andThen
                                    (\state ->
                                        if state.remaining == 0 && state.pendingKey == Nothing then
                                            BD.succeed state.value

                                        else if state.pendingKey == Nothing then
                                            case extra of
                                                IgnoreExtra ->
                                                    skipEntries state.remaining
                                                        |> BD.map (\_ -> state.value)

                                                FailOnExtra ->
                                                    BD.fail (TooManyElements Nothing)

                                        else
                                            -- A pending key exists: an optional read a key that didn't match.
                                            -- The value for that key is still in the stream.
                                            case extra of
                                                IgnoreExtra ->
                                                    -- Skip the pending key's value + remaining entries
                                                    skipFullItem
                                                        |> BD.andThen (\() -> skipEntries (state.remaining - 1))
                                                        |> BD.map (\_ -> state.value)

                                                FailOnExtra ->
                                                    BD.fail (TooManyElements Nothing)
                                    )
                            )

                    Nothing ->
                        -- IndefiniteLength
                        Pure
                            (decoder -1
                                |> BD.andThen
                                    (\state ->
                                        if state.remaining == 0 && state.pendingKey == Nothing then
                                            -- Break was consumed by optional
                                            BD.succeed state.value

                                        else if state.remaining < 0 && state.pendingKey == Nothing then
                                            case extra of
                                                IgnoreExtra ->
                                                    skipIndefiniteElements
                                                        |> BD.map (\_ -> state.value)

                                                FailOnExtra ->
                                                    u8
                                                        |> BD.andThen expectBreak
                                                        |> BD.map (\_ -> state.value)

                                        else if state.pendingKey /= Nothing then
                                            -- A pending key exists: handle like extra elements
                                            case extra of
                                                IgnoreExtra ->
                                                    -- Skip pending key's value + remaining indefinite entries
                                                    skipFullItem
                                                        |> BD.andThen (\() -> skipIndefiniteElements)
                                                        |> BD.map (\_ -> state.value)

                                                FailOnExtra ->
                                                    BD.fail (TooManyElements Nothing)

                                        else
                                            -- remaining == 0 but pendingKey exists (shouldn't happen)
                                            BD.fail (TooManyElements Nothing)
                                    )
                            )
            )



-- UNORDERED RECORD BUILDER


{-| Builder for decoding CBOR maps into records regardless of key order.

Unlike `KeyedRecordBuilder` which requires keys in the declared order,
this builder uses a `Dict` to dispatch on each key. Unknown keys are
handled according to the `ExtraElements` policy.

The trade-off: the caller must define an accumulator type and a finalize
function, since the constructor-threading pattern requires ordered application.

-}
type UnorderedRecordBuilder ctx comparable acc
    = UnorderedRecordBuilder (CborDecoder ctx comparable) acc (Dict comparable (BD.Decoder ctx DecodeError (acc -> acc)))


{-| Start building an unordered record decoder.

    type alias PersonAcc =
        { name : Maybe String, age : Maybe Int }

    decodePerson : CborDecoder ctx Person
    decodePerson =
        unorderedRecord int { name = Nothing, age = Nothing }
            |> onKey 0 string (\v acc -> { acc | name = Just v })
            |> onKey 1 int (\v acc -> { acc | age = Just v })
            |> buildUnorderedRecord IgnoreExtra
                (\acc -> Maybe.map2 Person acc.name acc.age)

-}
unorderedRecord : CborDecoder ctx comparable -> acc -> UnorderedRecordBuilder ctx comparable acc
unorderedRecord keyDecoder init =
    UnorderedRecordBuilder keyDecoder init Dict.empty


{-| Register a field handler for a specific key.

When the key is encountered during decoding, the value decoder runs
and the setter updates the accumulator.

-}
onKey : comparable -> CborDecoder ctx v -> (v -> acc -> acc) -> UnorderedRecordBuilder ctx comparable acc -> UnorderedRecordBuilder ctx comparable acc
onKey key valueDecoder setter (UnorderedRecordBuilder keyDecoder init handlers) =
    let
        handlerBD : BD.Decoder ctx DecodeError (acc -> acc)
        handlerBD =
            case valueDecoder of
                Item body ->
                    u8 |> BD.andThen body |> BD.map setter

                Pure _ ->
                    BD.fail ForbiddenPureInCollection
    in
    UnorderedRecordBuilder keyDecoder
        init
        (Dict.insert key handlerBD handlers)


{-| Finalize an unordered record builder into a decoder.

Reads the map header, scans all entries dispatching to registered handlers,
then calls the finalize function. If finalize returns `Nothing`, decoding
fails with `TooFewElements`.

**Note:** uses O(N) stack depth where N is the number of map entries.
Safe for typical CBOR maps (up to a few hundred entries).

-}
buildUnorderedRecord : ExtraElements -> (acc -> Maybe a) -> UnorderedRecordBuilder ctx comparable acc -> CborDecoder ctx a
buildUnorderedRecord extra finalize (UnorderedRecordBuilder keyDecoder init handlers) =
    let
        keyInner : Inner.Decoder ctx comparable
        keyInner =
            unwrap keyDecoder

        config : MapConfig ctx comparable acc a
        config =
            { extra = extra
            , handlers = handlers
            , finalize = finalize
            , keyBD = u8 |> BD.andThen keyInner
            , keyInner = keyInner
            }
    in
    Item
        (\byte ->
            Inner.mapHeader byte
                |> BD.andThen
                    (\maybeN ->
                        case maybeN of
                            Just n ->
                                processDefiniteEntry n config init

                            Nothing ->
                                u8 |> BD.andThen (processIndefiniteEntry config init)
                    )
        )


unwrap : CborDecoder context value -> Inner.Decoder context value
unwrap decoder =
    case decoder of
        Item inner ->
            inner

        _ ->
            \_ -> BD.fail ForbiddenPureInCollection


type alias MapConfig ctx comparable acc a =
    { extra : ExtraElements
    , handlers : Dict comparable (BD.Decoder ctx DecodeError (acc -> acc))
    , finalize : acc -> Maybe a
    , keyBD : BD.Decoder ctx DecodeError comparable
    , keyInner : Inner.Decoder ctx comparable
    }


processIndefiniteEntry : MapConfig ctx comparable acc a -> acc -> Inner.Decoder ctx a
processIndefiniteEntry config acc byte =
    if byte == 0xFF then
        finalizeWith config.finalize acc

    else
        config.keyInner byte
            |> BD.andThen
                (\key ->
                    case Dict.get key config.handlers of
                        Just handler ->
                            handler
                                |> BD.andThen
                                    (\update ->
                                        u8 |> BD.andThen (processIndefiniteEntry config (update acc))
                                    )

                        Nothing ->
                            case config.extra of
                                IgnoreExtra ->
                                    skipFullItem
                                        |> BD.andThen
                                            (\() ->
                                                u8 |> BD.andThen (processIndefiniteEntry config acc)
                                            )

                                FailOnExtra ->
                                    BD.fail (TooManyElements Nothing)
                )


processDefiniteEntry : Int -> MapConfig ctx comparable acc a -> acc -> BD.Decoder ctx DecodeError a
processDefiniteEntry remaining config acc =
    if remaining <= 0 then
        finalizeWith config.finalize acc

    else
        config.keyBD
            |> BD.andThen
                (\key ->
                    case Dict.get key config.handlers of
                        Just handler ->
                            handler
                                |> BD.andThen
                                    (\update ->
                                        processDefiniteEntry (remaining - 1) config (update acc)
                                    )

                        Nothing ->
                            case config.extra of
                                IgnoreExtra ->
                                    skipFullItem
                                        |> BD.andThen
                                            (\() ->
                                                processDefiniteEntry (remaining - 1) config acc
                                            )

                                FailOnExtra ->
                                    BD.fail (TooManyElements Nothing)
                )


finalizeWith : (acc -> Maybe a) -> acc -> BD.Decoder ctx DecodeError a
finalizeWith finalize acc =
    case finalize acc of
        Just a ->
            BD.succeed a

        Nothing ->
            BD.fail FailedToFinalizeRecord



-- ESCAPE HATCH


{-| Decode any well-formed CBOR data item into a `CborItem`.

This is the full CBOR parser. Handles all major types, nested structures,
tags, indefinite-length containers, etc.

If you need the raw `Bytes` for an item, decoding with `item` then
re-encoding with `Cbor.Encode.item` is fast enough in practice
(on par or faster than a dedicated byte-slicing decoder).

-}
item : CborDecoder ctx CborItem
item =
    Item Inner.item


{-| Skip any well-formed CBOR data item without allocating anything.

This is the fastest way to move past a CBOR item. Uses `BD.skipBytes`
throughout, staying entirely in the fast lane.

-}
itemSkip : CborDecoder ctx ()
itemSkip =
    Item Inner.skip


skipFullItem : BD.Decoder ctx DecodeError ()
skipFullItem =
    Inner.skipFull


skipNFullItems : Int -> BD.Decoder ctx DecodeError ()
skipNFullItems =
    Inner.skipNFull


skipIndefiniteElements : BD.Decoder ctx DecodeError ()
skipIndefiniteElements =
    Inner.skipIndefinite


breakOrRead : CborDecoder ctx a -> Int -> BD.Decoder ctx DecodeError (Maybe a)
breakOrRead decoder byte =
    if byte == 0xFF then
        BD.succeed Nothing

    else
        forceRead decoder byte
            |> BD.map Just


forceRead : CborDecoder context value -> Int -> BD.Decoder context DecodeError value
forceRead decoder byte =
    case decoder of
        Item body ->
            body byte

        Pure _ ->
            BD.fail ForbiddenPureInCollection


expectBreak : Int -> BD.Decoder ctx DecodeError ()
expectBreak byte =
    if byte == 0xFF then
        BD.succeed ()

    else
        BD.fail (TooManyElements Nothing)
