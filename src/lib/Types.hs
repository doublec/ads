
{-# LANGUAGE OverloadedStrings #-}

module Types (
  Id, unId, mkId', randomId, HasId(..),
  NodeInfo(..),

  -- * Locations
  HasLocation(..), Location, mkLocation, toLocation,
  unLocation, rightOf,
  LocDistance, unDistance, locDist, absLocDist, scaleDist, locMove,
  
  -- * state aware serialization
  ToStateJSON(..)
  ) where

import Control.Applicative ( pure, (<$>), (<*>) )
import Control.Concurrent.STM
import Control.Monad ( mzero )
import Data.Aeson
import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import Data.Bits ( shiftL )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as HEX
import qualified Data.ByteString.Char8 as BSC
import Data.Ratio ( (%) )
import Data.Text.Encoding ( decodeUtf8, encodeUtf8 )
import System.Random ( RandomGen, random )
import Test.QuickCheck

----------------------------------------------------------------------
-- STM aware serialization
----------------------------------------------------------------------

class ToStateJSON a where
  toStateJSON :: a -> STM Value

instance ToStateJSON a => ToStateJSON [a] where
  toStateJSON xs = toJSON <$> mapM toStateJSON xs

instance ToStateJSON a => ToStateJSON (TVar a) where
  toStateJSON v = readTVar v >>= toStateJSON

----------------------------------------------------------------------
-- Node IDs
----------------------------------------------------------------------

-- |
-- An 256 bit identifier.
newtype Id = Id { unId :: BS.ByteString } deriving ( Eq, Ord )

class HasId a where
  getId :: a -> Id

instance Binary Id where
  put = putByteString . unId
  get = Id <$> getByteString 32
  
instance Show Id where
  show nid = BSC.unpack (HEX.encode $ unId nid)

instance FromJSON Id where
  parseJSON (String s) = pure $ Id $ fst (HEX.decode $ encodeUtf8 s)
  parseJSON _ = mzero

instance ToJSON Id where
  toJSON (Id bs) = toJSON $ decodeUtf8 $ HEX.encode bs

instance HasLocation Id where
  hasLocToInteger = idToInteger
  hasLocMax       = Id $ BS.replicate 32 255

idToInteger :: Id -> Integer
idToInteger (Id bs) = BS.foldl' (\i bb -> (i `shiftL` 8) + fromIntegral bb) 0 bs

mkId' :: BS.ByteString -> Id
mkId' bs
  | BS.length bs /= 32 = error "mkId': expected 32 bytes"
  | otherwise = Id bs

randomId :: RandomGen g => g -> (Id, g)
randomId g = let (bs, Just g') = BS.unfoldrN 32 (Just . random) g in (mkId' bs, g')

-------------------------------------------------------------------------------------------
-- Locations
-------------------------------------------------------------------------------------------

class HasLocation a where
  hasLocToInteger :: a -> Integer
  hasLocMax       :: a

newtype Location = Location { unLocation :: Rational } deriving ( Eq, Show )

instance ToJSON Location where
  toJSON (Location l) = toJSON $ (fromRational l :: Double)

instance Arbitrary Location where
  arbitrary = do
    d <- arbitrary
    if d > 0
      then choose (0, d - 1) >>= (\n -> return $ Location (n % d))
      else return $ Location (0 % 1)

mkLocation :: Real a => a -> Location
mkLocation l
  | l < 0 || l >= 1 = error "mkLocation: location must be in [0..1)"
  | otherwise = Location $ toRational l

-- |
-- Determines if the shortes path on the circle goes to the right.
rightOf :: Location -> Location -> Bool
rightOf (Location l1) (Location l2)
  | l1 < l2   = l2 - l1 >= (1 % 2) 
  | otherwise = l1 - l2 <  (1 % 2)

toLocation :: HasLocation a => a -> Location
toLocation x = Location $ (hasLocToInteger x) % (1 + (hasLocToInteger $ hasLocMax `asTypeOf` x))

locMove :: Location -> LocDistance -> Location
locMove (Location l) (LocDistance d)
  | l' >= 1   = Location $ l' - 1
  | l' < 0    = Location $ l' + 1
  | otherwise = Location l'
  where
    l' = l + d

-- |
-- Distance between two locations, always in [-0.5, 0.5].
newtype LocDistance = LocDistance { unDistance :: Rational } deriving ( Eq, Ord )

instance Show LocDistance where
  show (LocDistance d) = show (fromRational d :: Float)

instance Arbitrary LocDistance where
  arbitrary = locDist <$> arbitrary <*> arbitrary

absLocDist :: Location -> Location -> LocDistance
absLocDist (Location l1) (Location l2) = LocDistance $ (min d (1 - d)) where
  d = if l1 > l2 then l1 - l2 else l2 - l1

locDist :: Location -> Location -> LocDistance
locDist ll1@(Location l1) ll2@(Location l2) = LocDistance $ f * (min d (1 - d)) where
  d = if l1 > l2 then l1 - l2 else l2 - l1
  f = if ll1 `rightOf` ll2 then 1 else (-1)

scaleDist :: LocDistance -> Rational -> LocDistance
scaleDist (LocDistance d) f
  | f > 1     = error "scaleDist: factor > 1"
  | otherwise = LocDistance $ d * f

----------------------------------------------------------------------
-- Node Info
----------------------------------------------------------------------

-- |
-- The node information which can be exchanged between peers.
data NodeInfo a = NodeInfo
                  { nodeId        :: Id -- ^ the globally unique node ID of 256 bits
                  , nodeAddresses :: [a]
                  } deriving ( Eq, Show )

instance Binary a => Binary (NodeInfo a) where
  put ni = put (nodeId ni) >> put (nodeAddresses ni)
  get = NodeInfo <$> get <*> get
  
instance FromJSON a => FromJSON (NodeInfo a) where
  parseJSON (Object v) = NodeInfo
                         <$> v .: "id"
                         <*> v .: "addresses"
  parseJSON _ = mzero

instance ToJSON a => ToJSON (NodeInfo a) where
  toJSON ni = object
              [ "id"        .= nodeId ni
              , "addresses" .= nodeAddresses ni
              ]
