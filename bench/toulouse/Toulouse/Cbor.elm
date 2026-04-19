module Toulouse.Cbor exposing (CborItem(..), Sign(..))

import Bytes exposing (Bytes)
import Toulouse.Cbor.Tag exposing (Tag)


type CborItem
    = CborInt32 Int
    | CborInt64 ( Int, Int )
    | CborBytes Bytes
    | CborString String
    | CborList (List CborItem)
    | CborMap (List ( CborItem, CborItem ))
    | CborTag Tag CborItem
    | CborBool Bool
    | CborFloat Float
    | CborNull
    | CborUndefined


type Sign
    = Positive
    | Negative
