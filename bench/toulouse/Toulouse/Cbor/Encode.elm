module Toulouse.Cbor.Encode exposing
    ( Encoder
    , Step
    , any
    , associativeList
    , beginBytes
    , beginDict
    , beginList
    , beginString
    , bool
    , break
    , bytes
    , dict
    , elem
    , elems
    , encode
    , field
    , fields
    , float
    , float16
    , float32
    , float64
    , indefiniteList
    , int
    , keyValue
    , length
    , list
    , maybe
    , null
    , optionalElem
    , optionalField
    , raw
    , record
    , sequence
    , size
    , string
    , tag
    , tagged
    , tuple
    , undefined
    )

import Bitwise exposing (or, shiftLeftBy)
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Bytes.Floating.Encode as E
import Dict exposing (Dict)
import Toulouse.Cbor exposing (CborItem(..))
import Toulouse.Cbor.Tag exposing (Tag(..))


type Encoder
    = Encoder E.Encoder


encode : Encoder -> Bytes
encode (Encoder e) =
    E.encode e


sequence : List Encoder -> Encoder
sequence =
    List.map (\(Encoder e) -> e) >> E.sequence >> Encoder


maybe : (a -> Encoder) -> Maybe a -> Encoder
maybe encodeA m =
    case m of
        Nothing ->
            null

        Just a ->
            encodeA a


keyValue : (a -> Encoder) -> (b -> Encoder) -> ( a, b ) -> Encoder
keyValue encodeA encodeB ( a, b ) =
    sequence
        [ encodeA a
        , encodeB b
        ]


bool : Bool -> Encoder
bool n =
    Encoder <|
        E.unsignedInt8 <|
            if n then
                0xF5

            else
                0xF4


int : Int -> Encoder
int n =
    Encoder <|
        if n <= -9007199254740992 then
            unsigned 1 9007199254740991

        else if n < 0 then
            unsigned 1 (negate n - 1)

        else
            unsigned 0 n


float : Float -> Encoder
float =
    float64


string : String -> Encoder
string str =
    Encoder <|
        E.sequence
            [ unsigned 3 (E.getStringWidth str)
            , E.string str
            ]


bytes : Bytes -> Encoder
bytes bs =
    Encoder <|
        E.sequence
            [ unsigned 2 (Bytes.width bs)
            , E.bytes bs
            ]


null : Encoder
null =
    Encoder <| E.unsignedInt8 0xF6


undefined : Encoder
undefined =
    Encoder <| E.unsignedInt8 0xF7


float16 : Float -> Encoder
float16 n =
    Encoder <|
        E.sequence
            [ majorType 7 25
            , E.float16 BE n
            ]


float32 : Float -> Encoder
float32 n =
    Encoder <|
        E.sequence
            [ majorType 7 26
            , E.float32 BE n
            ]


float64 : Float -> Encoder
float64 n =
    Encoder <|
        E.sequence
            [ majorType 7 27
            , E.float64 BE n
            ]


list : (a -> Encoder) -> List a -> Encoder
list e xs =
    sequence <|
        Encoder (unsigned 4 (List.length xs))
            :: List.map e xs


indefiniteList : (a -> Encoder) -> List a -> Encoder
indefiniteList fn =
    List.foldr (\x xs -> fn x :: xs) [ break ] >> (::) beginList >> sequence


length : Int -> Encoder
length =
    Encoder << unsigned 4


associativeList : (k -> Encoder) -> (v -> Encoder) -> List ( k, v ) -> Encoder
associativeList k v xs =
    sequence <|
        Encoder (unsigned 5 (List.length xs))
            :: List.map (keyValue k v) xs


dict : (k -> Encoder) -> (v -> Encoder) -> Dict k v -> Encoder
dict k v =
    associativeList k v << Dict.toList


size : Int -> Encoder
size =
    Encoder << unsigned 5


type Step k result
    = Step { steps : List Encoder, encodeKey : k -> Encoder, this : result }


record : (k -> Encoder) -> (Step k record -> Step k record) -> record -> Encoder
record encodeKey step this =
    let
        (Step { steps }) =
            step <|
                Step { steps = [], encodeKey = encodeKey, this = this }
    in
    sequence (size (List.length steps // 2) :: List.reverse steps)


fields : Step k record -> Step k record
fields =
    identity


field : k -> (field -> Encoder) -> (record -> field) -> Step k record -> Step k record
field k encodeValue extract (Step { steps, encodeKey, this }) =
    Step
        { steps = encodeValue (extract this) :: encodeKey k :: steps
        , encodeKey = encodeKey
        , this = this
        }


optionalField : k -> (field -> Encoder) -> (record -> Maybe field) -> Step k record -> Step k record
optionalField k encodeValue extract ((Step { this }) as step) =
    case extract this of
        Nothing ->
            step

        Just a ->
            field k encodeValue (always a) step


tuple : (Step Never tuple -> Step Never tuple) -> tuple -> Encoder
tuple step this =
    let
        (Step { steps }) =
            step <|
                Step { steps = [], encodeKey = never, this = this }
    in
    sequence (length (List.length steps) :: List.reverse steps)


elems : Step Never tuple -> Step Never tuple
elems =
    identity


elem : (elem -> Encoder) -> (tuple -> elem) -> Step Never tuple -> Step Never tuple
elem encodeElem extract (Step { steps, encodeKey, this }) =
    Step
        { steps = encodeElem (extract this) :: steps
        , encodeKey = encodeKey
        , this = this
        }


optionalElem :
    (elem -> Encoder)
    -> (tuple -> Maybe elem)
    -> Step Never tuple
    -> Step Never tuple
optionalElem encodeElem extract ((Step { this }) as step) =
    case extract this of
        Nothing ->
            step

        Just e ->
            elem encodeElem (always e) step


beginBytes : Encoder
beginBytes =
    Encoder <| majorType 2 tBEGIN


beginString : Encoder
beginString =
    Encoder <| majorType 3 tBEGIN


beginList : Encoder
beginList =
    Encoder <| majorType 4 tBEGIN


beginDict : Encoder
beginDict =
    Encoder <| majorType 5 tBEGIN


break : Encoder
break =
    Encoder <| E.unsignedInt8 tBREAK


any : CborItem -> Encoder
any item =
    case item of
        CborInt32 i ->
            int i

        CborInt64 ( msb, lsb ) ->
            Encoder
                (E.sequence
                    (if msb >= 0 then
                        [ majorType 0 27
                        , E.unsignedInt32 BE msb
                        , E.unsignedInt32 BE lsb
                        ]

                     else if lsb >= 1 then
                        [ majorType 1 27
                        , E.unsignedInt32 BE (negate msb)
                        , E.unsignedInt32 BE (lsb - 1)
                        ]

                     else if lsb == 0 then
                        [ majorType 1 27
                        , E.unsignedInt32 BE (negate msb - 1)
                        , E.unsignedInt32 BE 0xFFFFFFFF
                        ]

                     else
                        [ majorType 1 27
                        , E.unsignedInt32 BE -1
                        ]
                    )
                )

        CborBytes bs ->
            bytes bs

        CborString str ->
            string str

        CborList xs ->
            list any xs

        CborMap xs ->
            associativeList any any xs

        CborTag t x ->
            sequence [ tag t, any x ]

        CborBool b ->
            bool b

        CborFloat f ->
            float f

        CborNull ->
            null

        CborUndefined ->
            undefined


raw : Bytes -> Encoder
raw =
    E.bytes >> Encoder


tag : Tag -> Encoder
tag t =
    Encoder <|
        case t of
            StandardDateTime ->
                unsigned 6 0

            EpochDateTime ->
                unsigned 6 1

            PositiveBigNum ->
                unsigned 6 2

            NegativeBigNum ->
                unsigned 6 3

            DecimalFraction ->
                unsigned 6 4

            BigFloat ->
                unsigned 6 5

            Base64UrlConversion ->
                unsigned 6 21

            Base64Conversion ->
                unsigned 6 22

            Base16Conversion ->
                unsigned 6 23

            Cbor ->
                unsigned 6 24

            Uri ->
                unsigned 6 32

            Base64Url ->
                unsigned 6 33

            Base64 ->
                unsigned 6 34

            Regex ->
                unsigned 6 35

            Mime ->
                unsigned 6 36

            IsCbor ->
                unsigned 6 55799

            Unknown i ->
                unsigned 6 i


tagged : Tag -> (a -> Encoder) -> a -> Encoder
tagged t encodeA a =
    sequence [ tag t, encodeA a ]


tBEGIN : Int
tBEGIN =
    31


tBREAK : Int
tBREAK =
    0xFF


majorType : Int -> Int -> E.Encoder
majorType major payload =
    E.unsignedInt8 <| or payload (shiftLeftBy 5 major)


unsigned : Int -> Int -> E.Encoder
unsigned major n =
    if n < 24 then
        majorType major n

    else if n < 256 then
        E.sequence
            [ majorType major 24
            , E.unsignedInt8 n
            ]

    else if n < 65536 then
        E.sequence
            [ majorType major 25
            , E.unsignedInt16 BE n
            ]

    else if n < 4294967296 then
        E.sequence
            [ majorType major 26
            , E.unsignedInt32 BE n
            ]

    else
        E.sequence
            [ majorType major 27
            , E.unsignedInt32 BE (n // 4294967296)
            , E.unsignedInt32 BE n
            ]
