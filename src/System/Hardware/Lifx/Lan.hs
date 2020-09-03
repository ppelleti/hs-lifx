{-|
Module      : System.Hardware.Lifx.Lan
Description : Implementation of Connection for LIFX Lan Protocol
Copyright   : © Patrick Pelletier, 2016
License     : BSD3
Maintainer  : code@funwithsoftware.org
Stability   : experimental
Portability : GHC

This module implements a 'Connection' for controlling LIFX bulbs
via the LIFX Lan Protocol.
-}

{-# LANGUAGE OverloadedStrings #-}

module System.Hardware.Lifx.Lan
    ( LanSettings(..)
    , LanConnection
    , defaultLanSettings
    , openLanConnection
    , getLan
    , clBulb
    , lcLan
    , lcLights
    ) where

import System.Hardware.Lifx
import System.Hardware.Lifx.Connection
import System.Hardware.Lifx.Lan.LowLevel hiding (setLabel)
import System.Hardware.Lifx.Lan.LowLevel.Internal (untilKilled)

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Data.Hourglass
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Word
import System.IO
import System.Mem.Weak
import Time.System

import Data.Function

-- | Parameters which can be passed to 'openLanConnection'.
data LanSettings =
  LanSettings
  { -- | 'IO' action which returns name of network interface to use,
    -- such as @en1@ or @eth0@.  The default action is to look in
    -- @~\/.config\/hs-lifx\/config.json@.  If @interface@ is not specified
    -- in the config file, the default is 'Nothing', which lets the
    -- operating system choose the interface.
    lsIfName      :: IO (Maybe Interface)
    -- | Function to log a line of text.  This contains
    -- information which might be helpful for troubleshooting.
    -- Default is 'TIO.hPutStrLn' 'stderr'.
  , lsLog         :: T.Text -> IO ()
    -- | Unlike the Cloud API, the LAN Protocol does not have a notion of
    -- scenes built-in.  Therefore, you can provide this function to
    -- implement scenes for the LAN Protocol.  It should simply return a
    -- list of all the scenes.  Default is to return an empty list.
  , lsListScenes  :: IO [Scene]
    -- | Specifies timeouts and how aggressively to retry when messages
    -- time out.  Default is 'defaultRetryParams'.
  , lsRetryParams :: RetryParams
    -- | How frequently to poll the network for new devices.
    -- Default is 1.5 seconds.
  , lsDiscoveryPollInterval :: FracSeconds
    -- | If a bulb is not seen for this amount of time, it is marked Offline.
    -- Default is 5 seconds.
  , lsOfflineInterval :: FracSeconds
    -- | Port that LIFX bulbs are listening on.  Default is @56700@, which
    -- is the correct value for LIFX bulbs.  The only reason to change this
    -- is if you want to mock the bulbs for testing.
  , lsPort        :: !Word16
  }

-- | Returns of 'LanSettings' with default settings.
defaultLanSettings :: LanSettings
defaultLanSettings =
  LanSettings
  { lsIfName      = return Nothing
  , lsLog         = TIO.hPutStrLn stderr
  , lsPort        = 56700
  , lsListScenes  = return []
  , lsRetryParams = defaultRetryParams
  , lsDiscoveryPollInterval = 1.5
  , lsOfflineInterval = 5
  }

data CachedThing a = NotCached | Cached DateTime a deriving (Show, Eq, Ord)

data CachedLight =
  CachedLight
  { clBulb     :: Bulb
  , clLocation :: CachedThing LocationId
  , clGroup    :: CachedThing GroupId
  , clLabel    :: CachedThing Label
  , clFirstSeen :: DateTime
  } deriving (Show, Eq, Ord)

data CachedLabel =
  CachedLabel
  { claLabel     :: Label
  , claUpdatedAt :: !Word64
  } deriving (Show, Eq, Ord)

-- | Opaque type which implements 'Connection' and represents a connection
-- to all LIFX devices on a LAN.  It's OK to use a @LanConnection@ from
-- multiple threads at once.
data LanConnection =
  LanConnection
  { lcLan       :: Lan
  , lcSettings  :: LanSettings
  , lcLights    :: TVar (M.Map DeviceId   CachedLight)
  , lcGroups    :: TVar (M.Map GroupId    CachedLabel)
  , lcLocations :: TVar (M.Map LocationId CachedLabel)
  , _lcThread    :: Weak ThreadId
  }

instance Show LanConnection where
  show LanConnection { lcLan = lan } = show lan

instance Eq LanConnection where
  x1 == x2 = x1 == x2

instance Ord LanConnection where
  compare = compare `on` lcLan

tvEmptyMap :: IO (TVar (M.Map a b))
tvEmptyMap = newTVarIO M.empty

-- | Create a new 'LanConnection', based on 'LanSettings'.
openLanConnection :: LanSettings -> IO LanConnection
openLanConnection ls = do
  iface <- lsIfName ls
  lan <- openLan' iface (Just $ lsPort ls) (Just $ lsLog ls)
  m1 <- tvEmptyMap
  m2 <- tvEmptyMap
  m3 <- tvEmptyMap
  tmv <- newEmptyTMVarIO
  thr <- forkFinally (discoveryThread tmv) (\_ -> closeLan lan)
  wthr <- mkWeakThreadId thr
  atomically $ do
    let lc = LanConnection lan ls m1 m2 m3 wthr
    putTMVar tmv lc
    return lc

-- | Returns the underlying low-level 'Lan' that this 'LanConnection' uses.
-- This is useful if you want to break out of the high-level abstraction
-- provided by 'LanConnection' and do something low-level.
getLan :: LanConnection -> Lan
getLan = lcLan


data MessageNeeded = NeedGetLight   | NeedGetGroup    | NeedGetLocation
                   | NeedGetVersion | NeedGetHostInfo | NeedGetInfo
                   | NeedGetHostFirmware
                   deriving (Show, Read, Eq, Ord, Bounded, Enum)

dtOfCt :: CachedThing a -> Maybe DateTime
dtOfCt NotCached = Nothing
dtOfCt (Cached dt _ ) = Just dt

microsPerSecond :: FracSeconds
microsPerSecond = 1e6
-- discoveryTime = 1.5
fastDiscoveryTime :: FracSeconds
fastDiscoveryTime = 0.25

discoveryThread :: TMVar LanConnection -> IO ()
discoveryThread tmv = do
  lc <- atomically $ takeTMVar tmv
  let discoveryTime = lsDiscoveryPollInterval $ lcSettings lc
  forM_ ([1..3] :: [Int]) $ \_ -> do
    db lc
    td $ min discoveryTime fastDiscoveryTime
  untilKilled (lsLog $ lcSettings lc) "discovery" $ do
    db lc
    td discoveryTime
  where
    db lc = discoverBulbs (lcLan lc) $ discoveryCb lc
    td secs = threadDelay $ floor $ microsPerSecond * secs

data Query = QueryLocation | QueryGroup | QueryLabel deriving (Show, Eq, Ord)

discoveryCb :: LanConnection -> Bulb -> IO ()
discoveryCb lc bulb = do
  now <- dateCurrent
  queries <- atomically $ do
    lites <- readTVar (lcLights lc)
    case deviceId bulb `M.lookup` lites of
     Nothing -> do
       let lite = CachedLight bulb NotCached NotCached NotCached now
       writeTVar (lcLights lc) $ M.insert (deviceId bulb) lite lites
       return [ QueryLocation , QueryGroup , QueryLabel ] -- update all three
     (Just lite) -> do
       -- in case bulb changes (same id, new ip)
       when (bulb /= clBulb lite) $
         let lite' = lite { clBulb = bulb }
         in writeTVar (lcLights lc) $ M.insert (deviceId bulb) lite' lites
       let pairs = [ (dtOfCt (clLocation lite), QueryLocation)
                   , (dtOfCt (clGroup    lite), QueryGroup)
                   , (dtOfCt (clLabel    lite), QueryLabel) ]
       return [ snd $ minimum pairs ] -- just update the oldest one
  doQuery queries

  where
    -- FIXME: need to do reliable query?  or just accept lossiness?
    doQuery [] = return ()
    doQuery (QueryLocation:qs) = getLocation bulb $ \slo -> do
      now <- dateCurrent
      atomically $ updateLocation lc dev now slo
      doQuery qs
    doQuery (QueryGroup:qs) = getGroup bulb $ \sg -> do
      now <- dateCurrent
      atomically $ updateGroup lc dev now sg
      doQuery qs
    doQuery (QueryLabel:qs) = getLight bulb $ \sl -> do
      now <- dateCurrent
      atomically $ updateLabel lc dev now sl
      doQuery qs

    dev = deviceId bulb

updateCachedLight :: LanConnection -> DeviceId -> (CachedLight -> CachedLight)
                     -> STM ()
updateCachedLight lc dev f = do
  lites <- readTVar (lcLights lc)
  let lites' = M.adjust f dev lites
  writeTVar (lcLights lc) lites'

updateCachedLabel :: Ord a
                     => TVar (M.Map a CachedLabel)
                     -> a
                     -> Label
                     -> Word64
                     -> STM ()
updateCachedLabel tv k lbl updatedAt = do
  cache <- readTVar tv
  let needUpd =
        case k `M.lookup` cache of
         Nothing -> True
         (Just CachedLabel { claUpdatedAt = upat }) -> upat < updatedAt
      cl = CachedLabel { claLabel = lbl , claUpdatedAt = updatedAt }
  when needUpd $ writeTVar tv $ M.insert k cl cache

updateLocation :: LanConnection -> DeviceId -> DateTime -> StateLocation
                  -> STM ()
updateLocation lc dev now slo = do
  let lid = sloLocation slo
  updateCachedLight lc dev $ \cl -> cl { clLocation = Cached now lid }
  updateCachedLabel (lcLocations lc) lid (sloLabel slo) (sloUpdatedAt slo)

updateGroup :: LanConnection -> DeviceId -> DateTime -> StateGroup
               -> STM ()
updateGroup lc dev now sg = do
  let gid = sgGroup sg
  updateCachedLight lc dev $ \cl -> cl { clGroup = Cached now gid }
  updateCachedLabel (lcGroups lc) gid (sgLabel sg) (sgUpdatedAt sg)

updateLabel :: LanConnection -> DeviceId -> DateTime -> StateLight
               -> STM ()
updateLabel lc dev now sl =
  updateCachedLight lc dev $ \cl -> cl { clLabel = Cached now (slLabel sl) }
