module Lifx.Lan.Util
    ( putFloat32le,
      getFloat32le,
      putInt16le,
      getInt16le,
      padByteString,
      bounds,
      bitBool,
      extract ) where

import Control.Applicative ( (<$>) )
import Control.Monad ( when )
import Data.Binary ( Put, Get )
import Data.Binary.Put ( putWord32le, putWord16le )
import Data.Binary.Get ( getWord32le, getWord16le )
import Data.Bits ( Bits((.&.), bit, shiftR, zeroBits) )
import qualified Data.ByteString.Lazy as L
    ( ByteString, append, length, take, replicate )
import Data.Int ( Int16, Int64 )
import Data.ReinterpretCast ( wordToFloat, floatToWord )

bounds :: (Integral a, Bits a, Show a) => String -> Int -> a -> Put
bounds name n val =
  when (val >= limit) $ fail (name ++ ": " ++ show val ++ " >= " ++ show limit)
  where limit = bit n

bitBool :: Bits a => Int -> Bool -> a
bitBool _ False = zeroBits
bitBool n True = bit n

extract :: (Integral a, Bits a, Integral b) => a -> Int -> Int -> b
extract x n w = fromIntegral field
  where field = (x `shiftR` n) .&. mask
        mask = (bit w) - 1

putFloat32le :: Float -> Put
putFloat32le f = putWord32le $ floatToWord f

getFloat32le :: Get Float
getFloat32le = wordToFloat <$> getWord32le

putInt16le :: Int16 -> Put
putInt16le i = putWord16le $ fromIntegral i

getInt16le :: Get Int16
getInt16le = fromIntegral <$> getWord16le

padByteString :: Int64 -> L.ByteString -> L.ByteString
padByteString goal bs = f (l `compare` goal)
  where l = L.length bs
        f LT = bs `L.append` pad
        f EQ = bs
        f GT = L.take goal bs
        pad = L.replicate (goal - l) 0