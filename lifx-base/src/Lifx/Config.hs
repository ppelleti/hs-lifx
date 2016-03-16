{-# LANGUAGE OverloadedStrings #-}

module Lifx.Config (Config (..), configFile, getConfig) where

import Control.Applicative
import Control.Exception
import Data.Aeson hiding (Result)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Maybe
import qualified Data.Text as T
import System.Directory

import Lifx.Types

data Config =
  Config
  { cfgToken       :: AccessToken
  , cfgInterface   :: Maybe T.Text
  , cfgTestDevices :: [DeviceId]
  } deriving (Eq, Ord, Show, Read)

instance FromJSON Config where
  parseJSON (Object v) = do
    myToken <- fromMaybe defToken <$> v .:? "token"
    myInterface <- v .:? "interface"
    myTestDevices <- fromMaybe [] <$> v .:? "test-devices"
    return $ Config myToken myInterface myTestDevices

fromRight :: Either String a -> a
fromRight = either error id

defToken :: AccessToken
defToken = fromRight $ fromByteString $ B.replicate 32 0

configDir :: IO FilePath
configDir = getXdgDirectory XdgConfig "hs-lifx"

configFile :: IO FilePath
configFile = (++ "/config.json") <$> configDir

sceneFile :: IO FilePath
sceneFile = (++ "/scenes.json") <$> configDir

-- provide an empty config file if none was found
handler :: IOException -> IO B.ByteString
handler _ = return "{}"

getConfig :: IO Config
getConfig = do
  name <- configFile
  bs <- B.readFile name `catch` handler
  let lbs = L.fromStrict bs
  case eitherDecode' lbs of
   Left msg -> throwIO $ CloudJsonError (T.pack msg) lbs
   Right x -> return x
