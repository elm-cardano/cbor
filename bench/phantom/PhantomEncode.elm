module PhantomEncode exposing
    ( Encoder
    , array
    , bool
    , definite
    , encode
    , indefinite
    , int
    , list
    , map
    , sequence
    , sorted
    , string
    , unsorted
    )

{-| Experimental CBOR encoder using phantom extensible records
to track strategy decisions at the type level.

Each container adds phantom fields that must be consumed by
resolution functions before `encode` accepts the result.

    import PhantomEncode as PE

    -- Primitives encode directly
    PE.encode (PE.int 42)

    -- Arrays need a length decision
    PE.array [ PE.int 1, PE.int 2 ]
        |> PE.definite
        |> PE.encode

    -- Maps need sort + length decisions (either order)
    PE.map [ ( PE.int 0, PE.string "hello" ) ]
        |> PE.unsorted
        |> PE.definite
        |> PE.encode

Inner containers must be resolved before nesting:

    PE.map
        [ ( PE.int 0
          , PE.array [ PE.int 1, PE.int 2 ] |> PE.definite
          )
        ]
        |> PE.unsorted
        |> PE.definite
        |> PE.encode

-}

import Bitwise
import Bytes
import Bytes.Encode as BE



-- TYPES


{-| An encoder parameterized by a phantom record tracking pending decisions.

  - `Encoder {}` — fully resolved, ready to encode
  - `Encoder { a | length : () }` — needs a length-mode decision
  - `Encoder { a | sort : () }` — needs a sort decision
  - `Encoder { a | sort : (), length : () }` — needs both

-}
type Encoder a
    = Resolved BE.Encoder
    | ArrayNeedsLength (List BE.Encoder)
    | MapNeedsBoth (List ( BE.Encoder, BE.Encoder ))
    | MapNeedsSort Length (List ( BE.Encoder, BE.Encoder ))
    | MapNeedsLength Int (List BE.Encoder)


type Length
    = LDefinite
    | LIndefinite



-- PRIMITIVES


{-| Encode an integer using the shortest CBOR form.
-}
int : Int -> Encoder {}
int n =
    Resolved (encodeInt n)


{-| Encode a UTF-8 text string (major type 3).
-}
string : String -> Encoder {}
string s =
    Resolved
        (BE.sequence
            [ encodeHeader 3 (BE.getStringWidth s)
            , BE.string s
            ]
        )


{-| Encode a boolean.
-}
bool : Bool -> Encoder {}
bool b =
    Resolved
        (BE.unsignedInt8
            (if b then
                0xF5

             else
                0xF4
            )
        )



-- CONTAINERS


{-| Encode a CBOR array (major type 4).

Adds a `length` field to the phantom record.
Resolve with `definite` or `indefinite`.

-}
array : List (Encoder {}) -> Encoder { length : () }
array items =
    ArrayNeedsLength (List.map unwrap items)


{-| Encode a CBOR map (major type 5).

Adds `sort` and `length` fields to the phantom record.
Resolve sort with `unsorted` or `sorted`,
and length with `definite` or `indefinite`, in either order.

-}
map : List ( Encoder {}, Encoder {} ) -> Encoder { sort : (), length : () }
map entries =
    MapNeedsBoth
        (List.map (\( k, v ) -> ( unwrap k, unwrap v )) entries)


{-| Encode a list of items using the same element encoder.
-}
list : (item -> Encoder {}) -> List item -> Encoder { length : () }
list encodeItem items =
    array (List.map encodeItem items)


{-| Concatenate encoders without a CBOR container wrapper.
-}
sequence : List (Encoder {}) -> Encoder {}
sequence items =
    Resolved (BE.sequence (List.map unwrap items))



-- SORT RESOLUTION


{-| Preserve insertion order. No key serialization cost.
-}
unsorted : Encoder { a | sort : () } -> Encoder a
unsorted enc =
    case enc of
        MapNeedsBoth entries ->
            MapNeedsLength (List.length entries)
                (flattenEntries entries)

        MapNeedsSort length entries ->
            Resolved (finalizeMap length (List.length entries) (flattenEntries entries))

        _ ->
            coerce enc


{-| Sort map keys using a comparison function on serialized key bytes.

Each key is serialized to `Bytes` once for ordering, then the
encoded key bytes are embedded directly in the output.

-}
sorted :
    (List ( Bytes.Bytes, BE.Encoder ) -> List ( Bytes.Bytes, BE.Encoder ))
    -> Encoder { a | sort : () }
    -> Encoder a
sorted sortFn enc =
    case enc of
        MapNeedsBoth entries ->
            let
                ( count, flat ) =
                    sortAndFlatten sortFn entries
            in
            MapNeedsLength count flat

        MapNeedsSort length entries ->
            let
                ( count, flat ) =
                    sortAndFlatten sortFn entries
            in
            Resolved (finalizeMap length count flat)

        _ ->
            coerce enc



-- LENGTH RESOLUTION


{-| Use definite-length encoding (header includes item/entry count).
-}
definite : Encoder { a | length : () } -> Encoder a
definite enc =
    case enc of
        ArrayNeedsLength items ->
            Resolved
                (BE.sequence (encodeHeader 4 (List.length items) :: items))

        MapNeedsLength count entries ->
            Resolved
                (BE.sequence (encodeHeader 5 count :: entries))

        MapNeedsBoth entries ->
            MapNeedsSort LDefinite entries

        _ ->
            coerce enc


{-| Use indefinite-length encoding (start marker + items + break byte).
-}
indefinite : Encoder { a | length : () } -> Encoder a
indefinite enc =
    case enc of
        ArrayNeedsLength items ->
            Resolved
                (BE.sequence
                    [ BE.unsignedInt8 0x9F
                    , BE.sequence items
                    , BE.unsignedInt8 0xFF
                    ]
                )

        MapNeedsLength _ entries ->
            Resolved
                (BE.sequence
                    [ BE.unsignedInt8 0xBF
                    , BE.sequence entries
                    , BE.unsignedInt8 0xFF
                    ]
                )

        MapNeedsBoth entries ->
            MapNeedsSort LIndefinite entries

        _ ->
            coerce enc



-- ENCODING


{-| Encode to CBOR bytes. Only accepts fully-resolved encoders.
-}
encode : Encoder {} -> Bytes.Bytes
encode enc =
    BE.encode (unwrap enc)



-- INTERNAL


{-| Extract the inner BE.Encoder. Safe when called on Resolved values.
-}
unwrap : Encoder a -> BE.Encoder
unwrap enc =
    case enc of
        Resolved be ->
            be

        _ ->
            BE.sequence []


{-| Re-tag a phantom parameter. Safe because the phantom is erased at runtime.
Private: never exposed, so it cannot bypass the public API constraints.
-}
coerce : Encoder a -> Encoder b
coerce enc =
    case enc of
        Resolved be ->
            Resolved be

        ArrayNeedsLength items ->
            ArrayNeedsLength items

        MapNeedsBoth entries ->
            MapNeedsBoth entries

        MapNeedsSort l entries ->
            MapNeedsSort l entries

        MapNeedsLength c entries ->
            MapNeedsLength c entries


flattenEntries : List ( BE.Encoder, BE.Encoder ) -> List BE.Encoder
flattenEntries entries =
    List.map (\( k, v ) -> BE.sequence [ k, v ]) entries


sortAndFlatten :
    (List ( Bytes.Bytes, BE.Encoder ) -> List ( Bytes.Bytes, BE.Encoder ))
    -> List ( BE.Encoder, BE.Encoder )
    -> ( Int, List BE.Encoder )
sortAndFlatten sortFn entries =
    let
        withBytes =
            List.map
                (\( keyBE, valBE ) ->
                    let
                        keyBytes =
                            BE.encode keyBE
                    in
                    ( keyBytes, BE.sequence [ BE.bytes keyBytes, valBE ] )
                )
                entries
    in
    ( List.length entries, List.map Tuple.second (sortFn withBytes) )


finalizeMap : Length -> Int -> List BE.Encoder -> BE.Encoder
finalizeMap length count entries =
    case length of
        LDefinite ->
            BE.sequence (encodeHeader 5 count :: entries)

        LIndefinite ->
            BE.sequence
                [ BE.unsignedInt8 0xBF
                , BE.sequence entries
                , BE.unsignedInt8 0xFF
                ]


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
