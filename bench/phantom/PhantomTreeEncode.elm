module PhantomTreeEncode exposing
    ( Encoder
    , encode
    , int, string, bool
    , array, map, list, sequence
    , unsorted, sorted
    , definite, indefinite
    )

{-| Experimental CBOR encoder using phantom extensible records
to track strategy decisions at the type level.

Containers accumulate phantom fields. Resolution functions
(`unsorted`, `definite`, etc.) consume a phantom field and walk
the internal tree, applying the decision to every matching node.

    import PhantomEncode as PE

    PE.array
        [ PE.int 1
        , PE.map [ ( PE.int 0, PE.string "hello" ) ]
        ]
        |> PE.unsorted
        |> PE.definite
        |> PE.encode

A single `unsorted` resolves every map in the subtree.
A single `definite` resolves every array and map length.

-}

import Bitwise
import Bytes
import Bytes.Encode as BE



-- TYPES


{-| An encoder parameterized by a phantom record tracking pending decisions.

  - `Encoder {}` — fully resolved, ready to encode
  - `Encoder { a | length : () }` — at least one node needs a length decision
  - `Encoder { a | sort : () }` — at least one map needs a sort decision
  - `Encoder { a | sort : (), length : () }` — both pending

-}
type Encoder a
    = Encoder Node


{-| Internal tree. The phantom parameter on `Encoder` is not stored here;
it is tracked purely through function signatures.
-}
type Node
    = Leaf BE.Encoder
    | SeqNode (List Node)
    | ArrayNode (Maybe Length) (List Node)
    | MapNode (Maybe SortDecision) (Maybe Length) (List ( Node, Node ))


type Length
    = LDefinite
    | LIndefinite


type SortDecision
    = KeepOrder
    | SortWith (List ( Bytes.Bytes, BE.Encoder ) -> List ( Bytes.Bytes, BE.Encoder ))



-- PRIMITIVES


{-| Encode an integer using the shortest CBOR form.
-}
int : Int -> Encoder a
int n =
    Encoder (Leaf (encodeInt n))


{-| Encode a UTF-8 text string (major type 3).
-}
string : String -> Encoder a
string s =
    Encoder
        (Leaf
            (BE.sequence
                [ encodeHeader 3 (BE.getStringWidth s)
                , BE.string s
                ]
            )
        )


{-| Encode a boolean.
-}
bool : Bool -> Encoder a
bool b =
    Encoder
        (Leaf
            (BE.unsignedInt8
                (if b then
                    0xF5

                 else
                    0xF4
                )
            )
        )



-- CONTAINERS


{-| Encode a CBOR array (major type 4).

Adds a `length` requirement to the phantom record.

-}
array : List (Encoder a) -> Encoder { a | length : () }
array items =
    Encoder (ArrayNode Nothing (List.map unwrapNode items))


{-| Encode a CBOR map (major type 5).

Adds `sort` and `length` requirements to the phantom record.

-}
map : List ( Encoder a, Encoder a ) -> Encoder { a | sort : (), length : () }
map entries =
    Encoder
        (MapNode Nothing
            Nothing
            (List.map (\( Encoder k, Encoder v ) -> ( k, v )) entries)
        )


{-| Encode a list of items using the same element encoder.
-}
list : (item -> Encoder a) -> List item -> Encoder { a | length : () }
list encodeItem items =
    array (List.map encodeItem items)


{-| Concatenate encoders without a CBOR container wrapper (CBOR Sequence).
-}
sequence : List (Encoder a) -> Encoder a
sequence items =
    Encoder (SeqNode (List.map unwrapNode items))



-- SORT RESOLUTION


{-| Preserve insertion order for every map in the subtree.
-}
unsorted : Encoder { a | sort : () } -> Encoder a
unsorted (Encoder node) =
    Encoder (resolveSort KeepOrder node)


{-| Sort map keys for every map in the subtree.

Each key is serialized to `Bytes` once for ordering,
then the encoded key bytes are embedded in the output.

-}
sorted :
    (List ( Bytes.Bytes, BE.Encoder ) -> List ( Bytes.Bytes, BE.Encoder ))
    -> Encoder { a | sort : () }
    -> Encoder a
sorted sortFn (Encoder node) =
    Encoder (resolveSort (SortWith sortFn) node)



-- LENGTH RESOLUTION


{-| Use definite-length encoding for every array and map in the subtree.
-}
definite : Encoder { a | length : () } -> Encoder a
definite (Encoder node) =
    Encoder (resolveLength LDefinite node)


{-| Use indefinite-length encoding for every array and map in the subtree.
-}
indefinite : Encoder { a | length : () } -> Encoder a
indefinite (Encoder node) =
    Encoder (resolveLength LIndefinite node)



-- ENCODING


{-| Encode to CBOR bytes. Only accepts fully-resolved encoders.
-}
encode : Encoder {} -> Bytes.Bytes
encode (Encoder node) =
    BE.encode (nodeToBytes node)



-- INTERNAL: TREE RESOLUTION


unwrapNode : Encoder a -> Node
unwrapNode (Encoder node) =
    node


resolveSort : SortDecision -> Node -> Node
resolveSort decision node =
    case node of
        Leaf be ->
            Leaf be

        SeqNode children ->
            SeqNode (List.map (resolveSort decision) children)

        ArrayNode len children ->
            ArrayNode len (List.map (resolveSort decision) children)

        MapNode Nothing len entries ->
            MapNode (Just decision) len (mapPairs (resolveSort decision) entries)

        MapNode existing len entries ->
            MapNode existing len (mapPairs (resolveSort decision) entries)


resolveLength : Length -> Node -> Node
resolveLength len node =
    case node of
        Leaf be ->
            Leaf be

        SeqNode children ->
            SeqNode (List.map (resolveLength len) children)

        ArrayNode Nothing children ->
            ArrayNode (Just len) (List.map (resolveLength len) children)

        ArrayNode existing children ->
            ArrayNode existing (List.map (resolveLength len) children)

        MapNode sort Nothing entries ->
            MapNode sort (Just len) (mapPairs (resolveLength len) entries)

        MapNode sort existing entries ->
            MapNode sort existing (mapPairs (resolveLength len) entries)


mapPairs : (Node -> Node) -> List ( Node, Node ) -> List ( Node, Node )
mapPairs f pairs =
    List.map (\( a, b ) -> ( f a, f b )) pairs



-- INTERNAL: TREE TO BYTES


nodeToBytes : Node -> BE.Encoder
nodeToBytes node =
    case node of
        Leaf be ->
            be

        SeqNode children ->
            BE.sequence (List.map nodeToBytes children)

        ArrayNode (Just len) children ->
            buildArray len (List.length children) (List.map nodeToBytes children)

        MapNode (Just sort) (Just len) entries ->
            buildMap sort len entries

        _ ->
            -- Unreachable when the phantom type is {}
            BE.sequence []


buildArray : Length -> Int -> List BE.Encoder -> BE.Encoder
buildArray len count items =
    case len of
        LDefinite ->
            BE.sequence (encodeHeader 4 count :: items)

        LIndefinite ->
            BE.sequence
                [ BE.unsignedInt8 0x9F
                , BE.sequence items
                , BE.unsignedInt8 0xFF
                ]


buildMap : SortDecision -> Length -> List ( Node, Node ) -> BE.Encoder
buildMap sort len entries =
    let
        count =
            List.length entries

        flatEntries =
            case sort of
                KeepOrder ->
                    List.map
                        (\( k, v ) -> BE.sequence [ nodeToBytes k, nodeToBytes v ])
                        entries

                SortWith sortFn ->
                    let
                        withBytes =
                            List.map
                                (\( k, v ) ->
                                    let
                                        keyBytes =
                                            BE.encode (nodeToBytes k)
                                    in
                                    ( keyBytes
                                    , BE.sequence [ BE.bytes keyBytes, nodeToBytes v ]
                                    )
                                )
                                entries
                    in
                    List.map Tuple.second (sortFn withBytes)
    in
    case len of
        LDefinite ->
            BE.sequence (encodeHeader 5 count :: flatEntries)

        LIndefinite ->
            BE.sequence
                [ BE.unsignedInt8 0xBF
                , BE.sequence flatEntries
                , BE.unsignedInt8 0xFF
                ]



-- INTERNAL: CBOR PRIMITIVES


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
