module Toulouse.Bytes.Decode.Branchable exposing
    ( Decoder
    , andThen
    , bytes
    , decode
    , fail
    , float32
    , float64
    , fromDecoder
    , ignore
    , keep
    , loop
    , map
    , map2
    , map3
    , map4
    , map5
    , oneOf
    , peek
    , repeat
    , signedInt16
    , signedInt32
    , signedInt8
    , skip
    , string
    , succeed
    , unsignedInt16
    , unsignedInt32
    , unsignedInt8
    )

import Bytes exposing (Bytes)
import Bytes.Decode as D exposing (Step)


type Decoder value
    = Decoder (State -> D.Decoder ( State, value ))


type alias State =
    { input : Bytes
    , offset : Int
    }


decode : Decoder value -> Bytes -> Maybe value
decode decoder input =
    runKeepState decoder input
        |> Maybe.map (\( _, value ) -> value)


runKeepState : Decoder value -> Bytes -> Maybe ( State, value )
runKeepState (Decoder decoder) input =
    let
        dec : D.Decoder ( State, value )
        dec =
            decoder { input = input, offset = 0 }
    in
    D.decode dec input


succeed : value -> Decoder value
succeed val =
    fromDecoder (D.succeed val) 0


fail : Decoder value
fail =
    fromDecoder D.fail 0


map : (a -> b) -> Decoder a -> Decoder b
map f (Decoder decoder) =
    Decoder <|
        \state ->
            decoder state
                |> D.map (Tuple.mapSecond f)


map2 : (x -> y -> z) -> Decoder x -> Decoder y -> Decoder z
map2 f decoderX decoderY =
    decoderX |> andThen (\x -> map (\y -> f x y) decoderY)


map3 : (w -> x -> y -> z) -> Decoder w -> Decoder x -> Decoder y -> Decoder z
map3 f decoderW decoderX decoderY =
    map2 f decoderW decoderX
        |> keep decoderY


map4 :
    (v -> w -> x -> y -> z)
    -> Decoder v
    -> Decoder w
    -> Decoder x
    -> Decoder y
    -> Decoder z
map4 f decoderV decoderW decoderX decoderY =
    map3 f decoderV decoderW decoderX
        |> keep decoderY


map5 :
    (u -> v -> w -> x -> y -> z)
    -> Decoder u
    -> Decoder v
    -> Decoder w
    -> Decoder x
    -> Decoder y
    -> Decoder z
map5 f decoderU decoderV decoderW decoderX decoderY =
    map4 f decoderU decoderV decoderW decoderX
        |> keep decoderY


keep : Decoder a -> Decoder (a -> b) -> Decoder b
keep val fun =
    map2 (<|) fun val


ignore : Decoder ignore -> Decoder keep -> Decoder keep
ignore skipper keeper =
    map2 always keeper skipper


skip : Int -> Decoder value -> Decoder value
skip nBytes =
    ignore (bytes nBytes)


andThen : (a -> Decoder b) -> Decoder a -> Decoder b
andThen thenB (Decoder decoderA) =
    Decoder <|
        \state ->
            decoderA state
                |> D.andThen
                    (\( newState, a ) ->
                        let
                            (Decoder decoderB) =
                                thenB a
                        in
                        decoderB newState
                    )


oneOf : List (Decoder value) -> Decoder value
oneOf options =
    Decoder <|
        \state ->
            oneOfHelper (dropBytes state.offset state.input) options state


oneOfHelper : Bytes -> List (Decoder value) -> State -> D.Decoder ( State, value )
oneOfHelper offsetInput options state =
    case options of
        [] ->
            D.fail

        decoder :: otherDecoders ->
            case runKeepState decoder offsetInput of
                Just ( newState, value ) ->
                    D.bytes newState.offset
                        |> D.map (\_ -> ( { input = state.input, offset = state.offset + newState.offset }, value ))

                Nothing ->
                    oneOfHelper offsetInput otherDecoders state


dropBytes : Int -> Bytes -> Bytes
dropBytes offset bs =
    let
        width : Int
        width =
            Bytes.width bs
    in
    D.map2 (\_ x -> x) (D.bytes offset) (D.bytes <| width - offset)
        |> (\d -> D.decode d bs)
        |> Maybe.withDefault bs


repeat : Decoder value -> Int -> Decoder (List value)
repeat p nTimes =
    loop ( nTimes, [] ) (repeatHelp p)


repeatHelp :
    Decoder value
    -> ( Int, List value )
    -> Decoder (Step ( Int, List value ) (List value))
repeatHelp p ( cnt, acc ) =
    if cnt <= 0 then
        succeed (D.Done (List.reverse acc))

    else
        map (\v -> D.Loop ( cnt - 1, v :: acc )) p


loop : state -> (state -> Decoder (Step state a)) -> Decoder a
loop initialState callback =
    Decoder <|
        \initialDecoderState ->
            let
                makeDecoderStep : State -> Step state a -> Step ( state, State ) ( State, a )
                makeDecoderStep decoderState step =
                    case step of
                        D.Loop state ->
                            D.Loop ( state, decoderState )

                        D.Done a ->
                            D.Done ( decoderState, a )

                loopStep : ( state, State ) -> D.Decoder (Step ( state, State ) ( State, a ))
                loopStep ( state, decoderState ) =
                    let
                        (Decoder decoder) =
                            callback state
                    in
                    decoder decoderState
                        |> D.map (\( newDecoderState, step ) -> makeDecoderStep newDecoderState step)
            in
            D.loop ( initialState, initialDecoderState ) loopStep


peek : Decoder Int
peek =
    fromDecoder D.unsignedInt8 0


unsignedInt8 : Decoder Int
unsignedInt8 =
    fromDecoder D.unsignedInt8 1


unsignedInt16 : Bytes.Endianness -> Decoder Int
unsignedInt16 bo =
    fromDecoder (D.unsignedInt16 bo) 2


unsignedInt32 : Bytes.Endianness -> Decoder Int
unsignedInt32 bo =
    fromDecoder (D.unsignedInt32 bo) 4


signedInt8 : Decoder Int
signedInt8 =
    fromDecoder D.signedInt8 1


signedInt16 : Bytes.Endianness -> Decoder Int
signedInt16 bo =
    fromDecoder (D.signedInt16 bo) 2


signedInt32 : Bytes.Endianness -> Decoder Int
signedInt32 bo =
    fromDecoder (D.signedInt32 bo) 4


float32 : Bytes.Endianness -> Decoder Float
float32 bo =
    fromDecoder (D.float32 bo) 4


float64 : Bytes.Endianness -> Decoder Float
float64 bo =
    fromDecoder (D.float64 bo) 8


string : Int -> Decoder String
string byteCount =
    fromDecoder (D.string byteCount) byteCount


bytes : Int -> Decoder Bytes
bytes count =
    fromDecoder (D.bytes count) count


fromDecoder : D.Decoder v -> Int -> Decoder v
fromDecoder decoder byteLength =
    Decoder <|
        \state ->
            D.map
                (\v -> ( { input = state.input, offset = state.offset + byteLength }, v ))
                decoder
