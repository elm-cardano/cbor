module PhantomTest exposing (allBytes)

{-| Compile-time verification of phantom type constraints.

Each `good_*` compiles. Uncomment any `bad_*` to see the expected error.

-}

import Bytes exposing (Bytes)
import PhantomEncode as PE


allBytes : List Bytes
allBytes =
    [ good_primitives
    , good_array
    , good_map_unsorted
    , good_map_sorted
    , good_array_indefinite
    , good_nested
    , good_deeply_nested
    , good_list
    , good_sequence
    , good_map_length_first
    ]



-- GOOD: these all compile


good_primitives : Bytes
good_primitives =
    PE.encode (PE.int 42)


good_array : Bytes
good_array =
    PE.array [ PE.int 1, PE.int 2, PE.int 3 ]
        |> PE.definite
        |> PE.encode


good_map_unsorted : Bytes
good_map_unsorted =
    PE.map [ ( PE.int 0, PE.string "hello" ), ( PE.int 1, PE.bool True ) ]
        |> PE.unsorted
        |> PE.definite
        |> PE.encode


good_map_sorted : Bytes
good_map_sorted =
    PE.map [ ( PE.int 1, PE.string "b" ), ( PE.int 0, PE.string "a" ) ]
        |> PE.sorted identity
        |> PE.definite
        |> PE.encode


good_array_indefinite : Bytes
good_array_indefinite =
    PE.array [ PE.int 1 ]
        |> PE.indefinite
        |> PE.encode


good_nested : Bytes
good_nested =
    PE.map
        [ ( PE.int 0
          , PE.array [ PE.int 1, PE.int 2 ] |> PE.definite
          )
        , ( PE.int 1
          , PE.map [ ( PE.string "x", PE.int 3 ) ]
                |> PE.unsorted
                |> PE.definite
          )
        ]
        |> PE.unsorted
        |> PE.definite
        |> PE.encode


good_deeply_nested : Bytes
good_deeply_nested =
    PE.array
        [ PE.map
            [ ( PE.int 0
              , PE.array [ PE.int 1 ] |> PE.definite
              )
            ]
            |> PE.unsorted
            |> PE.definite
        , PE.int 99
        ]
        |> PE.definite
        |> PE.encode


good_list : Bytes
good_list =
    PE.list PE.int [ 1, 2, 3, 4, 5 ]
        |> PE.definite
        |> PE.encode


good_sequence : Bytes
good_sequence =
    PE.sequence [ PE.int 1, PE.string "hello", PE.bool True ]
        |> PE.encode


good_map_length_first : Bytes
good_map_length_first =
    PE.map [ ( PE.int 0, PE.string "hello" ) ]
        |> PE.definite
        |> PE.unsorted
        |> PE.encode



-- BAD: uncomment any of these to see compile errors
--
-- bad_array_no_length =
--     PE.array [ PE.int 1 ]
--         |> PE.encode
--     -- Error: Encoder { length : () } vs Encoder {}
--
-- bad_map_no_sort =
--     PE.map [ ( PE.int 0, PE.string "hello" ) ]
--         |> PE.definite
--         |> PE.encode
--     -- Error: Encoder { sort : () } vs Encoder {}
--
-- bad_map_no_length =
--     PE.map [ ( PE.int 0, PE.string "hello" ) ]
--         |> PE.unsorted
--         |> PE.encode
--     -- Error: Encoder { length : () } vs Encoder {}
--
-- bad_nested_unresolved =
--     PE.map
--         [ ( PE.int 0
--           , PE.map [ ( PE.int 1, PE.int 2 ) ]
--           )
--         ]
--         |> PE.unsorted
--         |> PE.definite
--         |> PE.encode
--     -- Error: Encoder { sort : (), length : () } vs Encoder {}
