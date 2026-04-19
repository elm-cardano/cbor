module PhantomTreeTest exposing (allBytes)

{-| Compile-time verification of the tree-based phantom encoder.

Each `good_*` compiles. Uncomment any `bad_*` to see the expected error.

-}

import Bytes exposing (Bytes)
import PhantomEncode as PE


allBytes : List Bytes
allBytes =
    [ good_primitives
    , good_array
    , good_map
    , good_array_indefinite
    , good_sequence
    , good_list
    , good_map_length_first
    , good_nested_array_in_array
    , good_nested_map_in_array
    , good_nested_map_in_map
    , good_deeply_nested
    , good_list_of_maps
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


good_map : Bytes
good_map =
    PE.map [ ( PE.int 0, PE.string "hello" ), ( PE.int 1, PE.bool True ) ]
        |> PE.unsorted
        |> PE.definite
        |> PE.encode


good_array_indefinite : Bytes
good_array_indefinite =
    PE.array [ PE.int 1 ]
        |> PE.indefinite
        |> PE.encode


good_sequence : Bytes
good_sequence =
    PE.sequence [ PE.int 1, PE.string "hello", PE.bool True ]
        |> PE.encode


good_list : Bytes
good_list =
    PE.list PE.int [ 1, 2, 3, 4, 5 ]
        |> PE.definite
        |> PE.encode


good_map_length_first : Bytes
good_map_length_first =
    PE.map [ ( PE.int 0, PE.string "hello" ) ]
        |> PE.definite
        |> PE.unsorted
        |> PE.encode


{-| Nested arrays: one `definite` resolves both.
-}
good_nested_array_in_array : Bytes
good_nested_array_in_array =
    PE.array
        [ PE.int 1
        , PE.array [ PE.int 2, PE.int 3 ]
        ]
        |> PE.definite
        |> PE.encode


{-| Map inside array: `unsorted` + `definite` resolves the whole tree.
-}
good_nested_map_in_array : Bytes
good_nested_map_in_array =
    PE.array
        [ PE.int 1
        , PE.map [ ( PE.int 0, PE.string "hello" ) ]
        ]
        |> PE.unsorted
        |> PE.definite
        |> PE.encode


{-| Nested maps: one `unsorted` + one `definite` resolves all.
-}
good_nested_map_in_map : Bytes
good_nested_map_in_map =
    PE.map
        [ ( PE.int 0
          , PE.map [ ( PE.int 1, PE.int 2 ) ]
          )
        ]
        |> PE.unsorted
        |> PE.definite
        |> PE.encode


{-| Three levels of nesting.
-}
good_deeply_nested : Bytes
good_deeply_nested =
    PE.array
        [ PE.map
            [ ( PE.int 0
              , PE.array
                    [ PE.int 1
                    , PE.map [ ( PE.int 2, PE.int 3 ) ]
                    ]
              )
            ]
        , PE.int 99
        ]
        |> PE.unsorted
        |> PE.definite
        |> PE.encode


{-| List of maps: `unsorted` + `definite` resolve all maps and the outer array.
-}
good_list_of_maps : Bytes
good_list_of_maps =
    PE.list (\n -> PE.map [ ( PE.int n, PE.string "val" ) ]) [ 1, 2, 3 ]
        |> PE.unsorted
        |> PE.definite
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
-- bad_nested_no_sort =
--     PE.array [ PE.map [ ( PE.int 0, PE.int 1 ) ] ]
--         |> PE.definite
--         |> PE.encode
--     -- Error: sort still pending
