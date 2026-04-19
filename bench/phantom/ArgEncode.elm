module ArgEncode exposing
    ( Encoder
    , encode
    , int, string, bool
    , Length(..), Sort(..)
    , array, map, list, sequence
    )

{-| CBOR encoder where containers take strategy arguments directly.

No phantom types — decisions are made at construction time.

    import ArgEncode as AE

    -- Primitives
    AE.encode (AE.int 42)

    -- Arrays take a Length argument
    AE.array AE.Definite [ AE.int 1, AE.int 2 ]
        |> AE.encode

    -- Maps take Sort and Length arguments
    AE.map AE.Unsorted AE.Definite [ ( AE.int 0, AE.string "hello" ) ]
        |> AE.encode

-}

import Bitwise
import Bytes
import Bytes.Encode as BE



-- TYPES


{-| A fully-resolved encoder, ready to encode.
-}
type Encoder
    = Encoder BE.Encoder


{-| Length encoding strategy for arrays and maps.
-}
type Length
    = Definite
    | Indefinite


{-| Sort strategy for map keys.
-}
type Sort comparable
    = Unsorted
    | Sorted (Bytes.Bytes -> comparable)



-- PRIMITIVES


{-| Encode an integer using the shortest CBOR form.
-}
int : Int -> Encoder
int n =
    Encoder (encodeInt n)


{-| Encode a UTF-8 text string (major type 3).
-}
string : String -> Encoder
string s =
    Encoder
        (BE.sequence
            [ encodeHeader 3 (BE.getStringWidth s)
            , BE.string s
            ]
        )


{-| Encode a boolean.
-}
bool : Bool -> Encoder
bool b =
    Encoder
        (BE.unsignedInt8
            (if b then
                0xF5

             else
                0xF4
            )
        )



-- CONTAINERS


{-| Encode a CBOR array (major type 4).
-}
array : Length -> List Encoder -> Encoder
array len items =
    let
        inner =
            List.map unwrap items
    in
    case len of
        Definite ->
            Encoder (BE.sequence (encodeHeader 4 (List.length inner) :: inner))

        Indefinite ->
            Encoder
                (BE.sequence
                    [ BE.unsignedInt8 0x9F
                    , BE.sequence inner
                    , BE.unsignedInt8 0xFF
                    ]
                )


{-| Encode a CBOR map (major type 5).
-}
map : Sort comparable -> Length -> List ( Encoder, Encoder ) -> Encoder
map sort len entries =
    let
        count =
            List.length entries

        flatEntries =
            case sort of
                Unsorted ->
                    List.map
                        (\( Encoder k, Encoder v ) -> BE.sequence [ k, v ])
                        entries

                Sorted toComparable ->
                    let
                        withComparable =
                            List.map
                                (\( Encoder k, Encoder v ) ->
                                    let
                                        keyBytes =
                                            BE.encode k
                                    in
                                    ( toComparable keyBytes, BE.sequence [ BE.bytes keyBytes, v ] )
                                )
                                entries
                    in
                    List.sortBy Tuple.first withComparable
                        |> List.map Tuple.second
    in
    case len of
        Definite ->
            Encoder (BE.sequence (encodeHeader 5 count :: flatEntries))

        Indefinite ->
            Encoder
                (BE.sequence
                    [ BE.unsignedInt8 0xBF
                    , BE.sequence flatEntries
                    , BE.unsignedInt8 0xFF
                    ]
                )


{-| Encode a list of items using the same element encoder.
-}
list : Length -> (item -> Encoder) -> List item -> Encoder
list len encodeItem items =
    array len (List.map encodeItem items)


{-| Concatenate encoders without a CBOR container wrapper.
-}
sequence : List Encoder -> Encoder
sequence items =
    Encoder (BE.sequence (List.map unwrap items))



-- ENCODING


{-| Encode to CBOR bytes.
-}
encode : Encoder -> Bytes.Bytes
encode (Encoder be) =
    BE.encode be



-- INTERNAL


unwrap : Encoder -> BE.Encoder
unwrap (Encoder be) =
    be


encodeInt : Int -> BE.Encoder
encodeInt n =
    if n >= 0 then
        encodeHeader 0 n

    else
        encodeHeader 1 (-1 - n)


encodeHeader : Int -> Int -> BE.Encoder
encodeHeader majorType argument =
    let
        mt =
            Bitwise.shiftLeftBy 5 majorType
    in
    if argument <= 23 then
        BE.unsignedInt8 (mt + argument)

    else if argument <= 0xFF then
        BE.unsignedInt16 Bytes.BE
            (Bitwise.or (Bitwise.shiftLeftBy 8 (mt + 24)) argument)

    else if argument <= 0xFFFF then
        BE.sequence
            [ BE.unsignedInt8 (mt + 25)
            , BE.unsignedInt16 Bytes.BE argument
            ]

    else if argument <= 0xFFFFFFFF then
        BE.sequence
            [ BE.unsignedInt8 (mt + 26)
            , BE.unsignedInt32 Bytes.BE argument
            ]

    else
        let
            hi =
                argument // 0x0000000100000000

            lo =
                argument - hi * 0x0000000100000000
        in
        BE.sequence
            [ BE.unsignedInt8 (mt + 27)
            , BE.unsignedInt32 Bytes.BE hi
            , BE.unsignedInt32 Bytes.BE lo
            ]
