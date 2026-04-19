module Toulouse.Cbor.Decode exposing
    ( Decoder
    , Step
    , andThen
    , any
    , associativeList
    , beginBytes
    , beginDict
    , beginList
    , beginString
    , bigint
    , bool
    , break
    , bytes
    , decode
    , dict
    , elem
    , elems
    , fail
    , field
    , fields
    , float
    , fold
    , ignore
    , ignoreThen
    , int
    , keep
    , length
    , list
    , map
    , map2
    , map3
    , map4
    , map5
    , maybe
    , oneOf
    , optionalElem
    , optionalField
    , raw
    , record
    , size
    , string
    , succeed
    , tag
    , tagged
    , thenIgnore
    , traverse
    , tuple
    )

import Bitwise exposing (and, shiftLeftBy, shiftRightBy)
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode
import Bytes.Encode as E
import Bytes.Floating.Decode as D
import Dict exposing (Dict)
import Toulouse.Bytes.Decode.Branchable as D
import Toulouse.Cbor exposing (CborItem(..), Sign(..))
import Toulouse.Cbor.Encode as CE
import Toulouse.Cbor.Tag exposing (Tag(..))
import Tuple


type Decoder a
    = Decoder (D.Decoder Int) (Int -> D.Decoder a)


decode : Decoder a -> Bytes -> Maybe a
decode d =
    D.decode (runDecoder d)


maybe : Decoder a -> Decoder (Maybe a)
maybe (Decoder consumeNext processNext) =
    Decoder consumeNext <|
        \a ->
            if a == 0xF6 || a == 0xF7 then
                D.succeed Nothing

            else
                D.map Just (processNext a)


bool : Decoder Bool
bool =
    consumeNextMajor 7 <|
        \a ->
            if a == 20 then
                D.succeed False

            else if a == 21 then
                D.succeed True

            else
                D.fail


int : Decoder Int
int =
    Decoder D.unsignedInt8
        (\a ->
            if shiftRightBy 5 a == 0 then
                unsigned a

            else if shiftRightBy 5 a == 1 then
                D.map (\x -> negate x - 1) (unsigned (and a 31))

            else
                D.fail
        )


int64 : Int -> D.Decoder ( Int, Int )
int64 major =
    D.map2 Tuple.pair (D.unsignedInt32 BE) (D.unsignedInt32 BE)
        |> D.map
            (\( msb, lsb ) ->
                if major == 0 then
                    ( msb, lsb )

                else if lsb == 0xFFFFFFFF then
                    ( negate (msb + 1), 0 )

                else
                    ( negate msb, lsb + 1 )
            )


bigint : Decoder ( Sign, Bytes )
bigint =
    let
        positive =
            D.map (\n -> ( Positive, n ))

        negative =
            D.map (\n -> ( Negative, n ))

        increment : Bytes -> D.Decoder Bytes
        increment bs =
            let
                width =
                    Bytes.width bs
            in
            bs
                |> D.decode
                    (D.loop ( width, [] )
                        (\( sz, xs ) ->
                            if sz > 0 then
                                D.unsignedInt8 |> D.map (\x -> Bytes.Decode.Loop ( sz - 1, x :: xs ))

                            else
                                D.succeed (Bytes.Decode.Done xs)
                        )
                    )
                |> Maybe.map
                    (List.foldl
                        (\x ( done, ys ) ->
                            if done then
                                ( done
                                , E.unsignedInt8 x :: ys
                                )

                            else if x >= 255 then
                                ( done
                                , E.unsignedInt8 0 :: ys
                                )

                            else
                                ( True
                                , E.unsignedInt8 (x + 1) :: ys
                                )
                        )
                        ( False, [] )
                        >> (\( done, xs ) ->
                                if done then
                                    xs

                                else
                                    case width of
                                        2 ->
                                            E.unsignedInt8 0 :: E.unsignedInt8 1 :: xs

                                        4 ->
                                            E.unsignedInt8 0 :: E.unsignedInt8 0 :: E.unsignedInt8 0 :: E.unsignedInt8 1 :: xs

                                        _ ->
                                            E.unsignedInt8 1 :: xs
                           )
                        >> E.sequence
                        >> E.encode
                        >> D.succeed
                    )
                |> Maybe.withDefault D.fail
    in
    Decoder D.unsignedInt8
        (\a ->
            case shiftRightBy 5 a of
                0 ->
                    payloadForMajor 0 a
                        |> D.andThen unsignedBytes
                        |> positive

                1 ->
                    payloadForMajor 1 a
                        |> D.andThen unsignedBytes
                        |> D.andThen increment
                        |> negative

                6 ->
                    let
                        (Decoder _ processTag) =
                            tag
                    in
                    processTag a
                        |> D.andThen
                            (\t ->
                                case t of
                                    PositiveBigNum ->
                                        runDecoder bytes |> positive

                                    NegativeBigNum ->
                                        runDecoder bytes
                                            |> D.andThen increment
                                            |> negative

                                    _ ->
                                        D.fail
                            )

                _ ->
                    D.fail
        )


float : Decoder Float
float =
    consumeNextMajor 7 <|
        \a ->
            if a == 25 then
                D.fromDecoder (D.float16 BE) 2

            else if a == 26 then
                D.float32 BE

            else if a == 27 then
                D.float64 BE

            else
                D.fail


string : Decoder String
string =
    chunks 3 D.string String.concat


bytes : Decoder Bytes
bytes =
    chunks 2 D.bytes (List.map E.bytes >> E.sequence >> E.encode)


chunks :
    Int
    -> (Int -> D.Decoder str)
    -> (List str -> str)
    -> Decoder str
chunks majorType_ chunk mappend =
    let
        indef es =
            D.unsignedInt8
                |> D.andThen
                    (\a ->
                        if a == tBREAK then
                            es
                                |> List.reverse
                                |> mappend
                                |> Bytes.Decode.Done
                                |> D.succeed

                        else
                            payloadForMajor majorType_ a
                                |> D.andThen unsigned
                                |> D.andThen chunk
                                |> D.map (\e -> Bytes.Decode.Loop (e :: es))
                    )
    in
    consumeNextMajor majorType_ <|
        \a ->
            if a == tBEGIN then
                D.loop [] indef

            else
                unsigned a |> D.andThen chunk


list : Decoder a -> Decoder (List a)
list (Decoder consumeNext processNext) =
    foldable 4 consumeNext processNext


length : Decoder Int
length =
    definiteLength 4


dict : Decoder comparable -> Decoder a -> Decoder (Dict comparable a)
dict key value =
    map Dict.fromList <| associativeList key value


size : Decoder Int
size =
    definiteLength 5


associativeList : Decoder k -> Decoder v -> Decoder (List ( k, v ))
associativeList (Decoder consumeNextKey processNextKey) value =
    foldable 5
        consumeNextKey
        (\key ->
            D.map2
                Tuple.pair
                (processNextKey key)
                (runDecoder value)
        )


fold :
    Decoder k
    -> (k -> Decoder (state -> state))
    -> state
    -> Decoder state
fold (Decoder consumeNextKey processNextKey) stepDecoder initialState =
    let
        indef : state -> D.Decoder (Bytes.Decode.Step state state)
        indef state =
            consumeNextKey
                |> D.andThen
                    (\a ->
                        if a == tBREAK then
                            D.succeed (Bytes.Decode.Done state)

                        else
                            processNextKey a
                                |> D.andThen (\k -> runDecoder <| stepDecoder k)
                                |> D.map (\f -> Bytes.Decode.Loop (f state))
                    )

        def : ( Int, state ) -> D.Decoder (Bytes.Decode.Step ( Int, state ) state)
        def ( n, state ) =
            if n <= 0 then
                D.succeed (Bytes.Decode.Done state)

            else
                consumeNextKey
                    |> D.andThen processNextKey
                    |> D.andThen (\k -> runDecoder <| stepDecoder k)
                    |> D.map (\f -> Bytes.Decode.Loop ( n - 1, f state ))
    in
    consumeNextMajor 5 <|
        \a ->
            if a == tBEGIN then
                D.loop initialState indef

            else
                unsigned a
                    |> D.andThen (\n -> D.loop ( n, initialState ) def)


foldable :
    Int
    -> D.Decoder Int
    -> (Int -> D.Decoder a)
    -> Decoder (List a)
foldable majorType_ consumeNext processNext =
    let
        indef es =
            consumeNext
                |> D.andThen
                    (\a ->
                        if a == tBREAK then
                            es
                                |> List.reverse
                                |> Bytes.Decode.Done
                                |> D.succeed

                        else
                            processNext a
                                |> D.map (\e -> Bytes.Decode.Loop (e :: es))
                    )

        def ( n, es ) =
            if n <= 0 then
                es |> List.reverse |> Bytes.Decode.Done |> D.succeed

            else
                consumeNext
                    |> D.andThen processNext
                    |> D.map (\e -> Bytes.Decode.Loop ( n - 1, e :: es ))
    in
    consumeNextMajor majorType_ <|
        \a ->
            if a == tBEGIN then
                D.loop [] indef

            else
                unsigned a |> D.andThen (\n -> D.loop ( n, [] ) def)


definiteLength : Int -> Decoder Int
definiteLength majorType_ =
    consumeNextMajor majorType_ <|
        \a ->
            if a == tBEGIN then
                D.fail

            else
                unsigned a


type Step k result
    = TupleStep (TupleSt k result)
    | RecordStep (RecordSt k result)


type Size
    = Definite Int
    | Indefinite Bool


type alias TupleSt k result =
    { size : Size
    , steps : result
    , decodeKey : Decoder k
    , k : Maybe k
    }


type alias RecordSt k result =
    { steps : result
    , rest : List ( k, Bytes )
    }


withTupleStep :
    (TupleSt k (field -> steps) -> Decoder (TupleSt k steps))
    -> Decoder (Step k (field -> steps))
    -> Decoder (Step k steps)
withTupleStep with st =
    st
        |> andThen
            (\inner ->
                case inner of
                    TupleStep t ->
                        map TupleStep (with t)

                    RecordStep _ ->
                        fail
            )


withRecordStep :
    (RecordSt k (field -> steps) -> Decoder (RecordSt k steps))
    -> Decoder (Step k (field -> steps))
    -> Decoder (Step k steps)
withRecordStep with st =
    st
        |> andThen
            (\inner ->
                case inner of
                    TupleStep _ ->
                        fail

                    RecordStep r ->
                        map RecordStep (with r)
            )


record : Decoder k -> steps -> (Step k steps -> Decoder (Step k record_)) -> Decoder record_
record decodeKey steps decodeNext =
    associativeList decodeKey raw
        |> andThen (\rest -> RecordStep { steps = steps, rest = rest } |> decodeNext)
        |> andThen
            (\result ->
                case result of
                    RecordStep st ->
                        succeed st.steps

                    TupleStep _ ->
                        fail
            )


fields : Step k steps -> Decoder (Step k steps)
fields =
    succeed


field : k -> Decoder field_ -> Decoder (Step k (field_ -> steps)) -> Decoder (Step k steps)
field want decodeField =
    withRecordStep <|
        \st ->
            extract want st.rest
                |> Maybe.andThen
                    (\( bs, rest ) ->
                        decode decodeField bs
                            |> Maybe.map (\v -> succeed { rest = rest, steps = st.steps v })
                    )
                |> Maybe.withDefault fail


optionalField : k -> Decoder field_ -> Decoder (Step k (Maybe field_ -> steps)) -> Decoder (Step k steps)
optionalField want decodeField =
    withRecordStep <|
        \st ->
            case extract want st.rest of
                Just ( bs, rest ) ->
                    decode decodeField bs
                        |> Maybe.map (\v -> succeed { rest = rest, steps = st.steps (Just v) })
                        |> Maybe.withDefault fail

                Nothing ->
                    succeed { rest = st.rest, steps = st.steps Nothing }


tuple : steps -> (Step Never steps -> Decoder (Step Never tuple_)) -> Decoder tuple_
tuple steps decodeTuple =
    consumeNextMajor 4 <|
        \tFirst ->
            if tFirst == tBEGIN then
                TupleStep
                    { k = Nothing
                    , steps = steps
                    , size = Indefinite False
                    , decodeKey = fail
                    }
                    |> decodeTuple
                    |> andThen
                        (\result ->
                            case result of
                                RecordStep _ ->
                                    fail

                                TupleStep st ->
                                    case st.size of
                                        Indefinite True ->
                                            succeed st.steps

                                        _ ->
                                            Decoder D.unsignedInt8 <|
                                                \tLast ->
                                                    if tLast == tBREAK then
                                                        D.succeed st.steps

                                                    else
                                                        D.fail
                        )
                    |> runDecoder

            else
                unsigned tFirst
                    |> D.andThen
                        (\sz ->
                            TupleStep
                                { k = Nothing
                                , steps = steps
                                , size = Definite sz
                                , decodeKey = fail
                                }
                                |> decodeTuple
                                |> runDecoder
                        )
                    |> D.andThen
                        (\result ->
                            case result of
                                RecordStep _ ->
                                    D.fail

                                TupleStep st ->
                                    D.succeed st.steps
                        )


elems : Step Never steps -> Decoder (Step Never steps)
elems =
    succeed


elem : Decoder field_ -> Decoder (Step Never (field_ -> steps)) -> Decoder (Step Never steps)
elem v =
    withTupleStep <| \st -> map (step st Nothing) v


optionalElem : Decoder field_ -> Decoder (Step Never (Maybe field_ -> steps)) -> Decoder (Step Never steps)
optionalElem v =
    withTupleStep <|
        \st ->
            let
                ignoreElem =
                    step st st.k Nothing
            in
            case st.size of
                Indefinite done ->
                    if done then
                        succeed ignoreElem

                    else
                        let
                            (Decoder consumeField processField) =
                                v
                        in
                        Decoder consumeField <|
                            \t ->
                                if t == tBREAK then
                                    D.succeed <| { ignoreElem | size = Indefinite True }

                                else
                                    D.map (step st Nothing << Just) (processField t)

                Definite sz ->
                    if sz <= 0 then
                        succeed ignoreElem

                    else
                        map (step st Nothing << Just) v


step : TupleSt k (field_ -> steps) -> Maybe k -> field_ -> TupleSt k steps
step st k next =
    { k = k
    , steps = st.steps next
    , decodeKey = st.decodeKey
    , size =
        case st.size of
            Indefinite done ->
                Indefinite done

            Definite sz ->
                Definite <|
                    sz
                        - (case k of
                            Nothing ->
                                1

                            Just _ ->
                                0
                          )
    }


tag : Decoder Tag
tag =
    consumeNextMajor 6 <|
        unsigned
            >> D.map
                (\t ->
                    case t of
                        0 ->
                            StandardDateTime

                        1 ->
                            EpochDateTime

                        2 ->
                            PositiveBigNum

                        3 ->
                            NegativeBigNum

                        4 ->
                            DecimalFraction

                        5 ->
                            BigFloat

                        21 ->
                            Base64UrlConversion

                        22 ->
                            Base64Conversion

                        23 ->
                            Base16Conversion

                        24 ->
                            Cbor

                        32 ->
                            Uri

                        33 ->
                            Base64Url

                        34 ->
                            Base64

                        35 ->
                            Regex

                        36 ->
                            Mime

                        55799 ->
                            IsCbor

                        _ ->
                            Unknown t
                )


tagged : Tag -> Decoder a -> Decoder ( Tag, a )
tagged t a =
    tag
        |> andThen
            (\t_ ->
                if t == t_ then
                    map2 Tuple.pair (succeed t) a

                else
                    fail
            )


succeed : a -> Decoder a
succeed a =
    let
        absurd =
            shiftLeftBy 5 28
    in
    Decoder (D.succeed absurd) (always <| D.succeed a)


fail : Decoder a
fail =
    Decoder D.unsignedInt8 (always D.fail)


andThen : (a -> Decoder b) -> Decoder a -> Decoder b
andThen fn (Decoder consumeNext processNext) =
    Decoder
        consumeNext
        (processNext >> D.andThen (fn >> runDecoder))


ignoreThen : Decoder a -> Decoder ignored -> Decoder a
ignoreThen a ignored =
    ignored |> andThen (always a)


thenIgnore : Decoder ignored -> Decoder a -> Decoder a
thenIgnore ignored a =
    a |> andThen (\result -> map (always result) ignored)


map : (a -> value) -> Decoder a -> Decoder value
map fn (Decoder consumeNext processNext) =
    Decoder
        consumeNext
        (processNext >> D.map fn)


map2 : (a -> b -> value) -> Decoder a -> Decoder b -> Decoder value
map2 fn (Decoder consumeNext processNext) b =
    Decoder consumeNext
        (processNext
            >> (\a ->
                    D.map2 fn
                        a
                        (runDecoder b)
               )
        )


map3 :
    (a -> b -> c -> value)
    -> Decoder a
    -> Decoder b
    -> Decoder c
    -> Decoder value
map3 fn (Decoder consumeNext processNext) b c =
    Decoder consumeNext
        (processNext
            >> (\a ->
                    D.map3 fn
                        a
                        (runDecoder b)
                        (runDecoder c)
               )
        )


map4 :
    (a -> b -> c -> d -> value)
    -> Decoder a
    -> Decoder b
    -> Decoder c
    -> Decoder d
    -> Decoder value
map4 fn (Decoder consumeNext processNext) b c d =
    Decoder consumeNext
        (processNext
            >> (\a ->
                    D.map4 fn
                        a
                        (runDecoder b)
                        (runDecoder c)
                        (runDecoder d)
               )
        )


map5 :
    (a -> b -> c -> d -> e -> value)
    -> Decoder a
    -> Decoder b
    -> Decoder c
    -> Decoder d
    -> Decoder e
    -> Decoder value
map5 fn (Decoder consumeNext processNext) b c d e =
    Decoder consumeNext
        (processNext
            >> (\a ->
                    D.map5 fn
                        a
                        (runDecoder b)
                        (runDecoder c)
                        (runDecoder d)
                        (runDecoder e)
               )
        )


traverse : (a -> Decoder b) -> List a -> Decoder (List b)
traverse fn =
    List.foldr
        (\a st ->
            fn a
                |> andThen (\b -> map (\bs -> b :: bs) st)
        )
        (succeed [])


oneOf : List (Decoder a) -> Decoder a
oneOf alternatives =
    let
        absurd =
            shiftLeftBy 5 28
    in
    Decoder (D.oneOf [ D.peek, D.succeed absurd ]) <|
        (alternatives
            |> List.map runDecoder
            |> D.oneOf
            |> always
        )


keep : Decoder a -> Decoder (a -> b) -> Decoder b
keep val fun =
    map2 (<|) fun val


ignore : Decoder ignore -> Decoder keep -> Decoder keep
ignore skipper keeper =
    map2 always keeper skipper


beginBytes : Decoder ()
beginBytes =
    consumeNextMajor 2 <|
        \a ->
            if a == tBEGIN then
                D.succeed ()

            else
                D.fail


beginString : Decoder ()
beginString =
    consumeNextMajor 3 <|
        \a ->
            if a == tBEGIN then
                D.succeed ()

            else
                D.fail


beginList : Decoder ()
beginList =
    consumeNextMajor 4 <|
        \a ->
            if a == tBEGIN then
                D.succeed ()

            else
                D.fail


beginDict : Decoder ()
beginDict =
    consumeNextMajor 5 <|
        \a ->
            if a == tBEGIN then
                D.succeed ()

            else
                D.fail


break : Decoder ()
break =
    Decoder D.unsignedInt8 <|
        \a ->
            if a == tBREAK then
                D.succeed ()

            else
                D.fail


any : Decoder CborItem
any =
    Decoder D.unsignedInt8 <|
        \a ->
            let
                majorType_ =
                    shiftRightBy 5 a

                payload =
                    and a 31

                apply : Decoder a_ -> Int -> D.Decoder a_
                apply (Decoder _ processNext) i =
                    processNext i
            in
            if majorType_ == 0 then
                if payload == 27 then
                    D.map CborInt64 <| int64 majorType_

                else
                    D.map CborInt32 <| apply int a

            else if majorType_ == 1 then
                if payload == 27 then
                    D.map CborInt64 <| int64 majorType_

                else
                    D.map CborInt32 <| apply int a

            else if majorType_ == 2 then
                D.map CborBytes <| apply bytes a

            else if majorType_ == 3 then
                D.map CborString <| apply string a

            else if majorType_ == 4 then
                D.map CborList <| apply (list any) a

            else if majorType_ == 5 then
                D.map CborMap <| apply (associativeList any any) a

            else if majorType_ == 6 then
                D.map2 CborTag (apply tag a) (runDecoder any)

            else if payload == 20 then
                D.succeed <| CborBool False

            else if payload == 21 then
                D.succeed <| CborBool True

            else if payload == 22 then
                D.succeed <| CborNull

            else if payload == 23 then
                D.succeed <| CborUndefined

            else if List.member payload [ 25, 26, 27 ] then
                D.map CborFloat <| apply float a

            else
                D.fail


raw : Decoder Bytes
raw =
    map (CE.any >> CE.encode) any


extract : k -> List ( k, v ) -> Maybe ( v, List ( k, v ) )
extract needle =
    let
        go rest xs =
            case xs of
                [] ->
                    Nothing

                ( k, v ) :: tail ->
                    if needle == k then
                        Just ( v, rest ++ tail )

                    else
                        go (( k, v ) :: rest) tail
    in
    go []


tBEGIN : Int
tBEGIN =
    0x1F


tBREAK : Int
tBREAK =
    0xFF


runDecoder : Decoder a -> D.Decoder a
runDecoder (Decoder consumeNext processNext) =
    consumeNext |> D.andThen processNext


consumeNextMajor : Int -> (Byte -> D.Decoder a) -> Decoder a
consumeNextMajor majorType_ processNext =
    Decoder
        D.unsignedInt8
        (payloadForMajor majorType_ >> D.andThen processNext)


payloadForMajor : Int -> Byte -> D.Decoder Int
payloadForMajor majorType_ byte =
    if shiftRightBy 5 byte == majorType_ then
        D.succeed (and byte 31)

    else
        D.fail


unsigned : Int -> D.Decoder Int
unsigned a =
    if a < 24 then
        D.succeed a

    else if a == 24 then
        D.unsignedInt8

    else if a == 25 then
        D.unsignedInt16 BE

    else if a == 26 then
        D.unsignedInt32 BE

    else if a == 27 then
        D.map2 (+) (unsignedInt53 BE) (D.unsignedInt32 BE)

    else
        D.fail


unsignedBytes : Int -> D.Decoder Bytes
unsignedBytes a =
    if a < 24 then
        D.succeed (E.encode (E.unsignedInt8 a))

    else if a == 24 then
        D.bytes 1

    else if a == 25 then
        D.bytes 2

    else if a == 26 then
        D.bytes 4

    else if a == 27 then
        D.bytes 8

    else
        D.fail


unsignedInt53 : Endianness -> D.Decoder Int
unsignedInt53 e =
    D.unsignedInt32 e
        |> D.andThen
            (\up ->
                if up > 0x001FFFFF then
                    D.fail

                else
                    D.succeed (up * 0x0000000100000000)
            )


type alias Byte =
    Int
