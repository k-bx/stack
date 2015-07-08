{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Stack.Types.Image where

import Control.Applicative
import Data.Aeson.Extended
import Data.Monoid
import Data.Map (Map)
import Data.Text (Text)

-- | Image options. Currently only Docker image options.
data ImageOpts = ImageOpts
    { imgDocker :: !(Maybe ImageDockerOpts)
      -- ^ Maybe a section for docker image settings.
    } deriving (Show)

data ImageDockerOpts = ImageDockerOpts
    { imgDockerBase :: !(Maybe String)
      -- ^ Maybe have a docker base image name. (Although we will not
      -- be able to create any Docker images without this.)
    , imgDockerEntrypoints :: !(Maybe [String])
      -- ^ Maybe have a specific ENTRYPOINT list that will be used to
      -- create images.
    , imgDockerAdd :: !(Map FilePath FilePath)
      -- ^ Maybe have some static project content to include in a
      -- specific directory in all the images.
    } deriving (Show)

data ImageOptsMonoid = ImageOptsMonoid
    { imgMonoidExists :: !(Maybe Bool)
    , imgMonoidDocker :: !(Maybe ImageDockerOptsMonoid)
    } deriving (Show)

data ImageDockerOptsMonoid = ImageDockerOptsMonoid
    { imgDockerMonoidExists :: !(Maybe Bool)
    , imgDockerMonoidBase :: !(Maybe String)
    , imgDockerMonoidEntrypoints :: !(Maybe [String])
    , imgDockerMonoidAdd :: !(Maybe (Map String FilePath))
    } deriving (Show)

instance FromJSON ImageOptsMonoid where
    parseJSON = withObject
            "ImageOptsMonoid"
            (\o ->
                  do imgMonoidExists <-
                         pure (Just True)
                     imgMonoidDocker <- o .:? imgDockerArgName
                     return
                         ImageOptsMonoid
                         { ..
                         })

instance Monoid ImageOptsMonoid where
    mempty = ImageOptsMonoid
        { imgMonoidExists = Just False
        , imgMonoidDocker = Nothing
        }
    mappend l r = ImageOptsMonoid
        { imgMonoidExists = imgMonoidExists l <|> imgMonoidExists r
        , imgMonoidDocker = imgMonoidDocker l <|> imgMonoidDocker r
        }

instance FromJSON ImageDockerOptsMonoid where
    parseJSON = withObject
            "ImageDockerOptsMonoid"
            (\o ->
                  do imgDockerMonoidExists <-
                         pure (Just True)
                     imgDockerMonoidBase <- o .:? imgDockerBaseArgName
                     imgDockerMonoidEntrypoints <- o .:?
                                                   imgDockerEntrypointsArgName
                     imgDockerMonoidAdd <- o .:? imgDockerAddArgName
                     return
                         ImageDockerOptsMonoid
                         { ..
                         })

instance Monoid ImageDockerOptsMonoid where
    mempty = ImageDockerOptsMonoid
        { imgDockerMonoidExists = Just False
        , imgDockerMonoidBase = Nothing
        , imgDockerMonoidEntrypoints = Nothing
        , imgDockerMonoidAdd = Nothing
        }
    mappend l r = ImageDockerOptsMonoid
        { imgDockerMonoidExists = imgDockerMonoidExists l <|> imgDockerMonoidExists
                                                                  r
        , imgDockerMonoidBase = imgDockerMonoidBase l <|> imgDockerMonoidBase r
        , imgDockerMonoidEntrypoints = imgDockerMonoidEntrypoints l <|> imgDockerMonoidEntrypoints
                                                                            r
        , imgDockerMonoidAdd = imgDockerMonoidAdd l <|> imgDockerMonoidAdd r
        }

imgArgName :: Text
imgArgName = "image"

imgDockerArgName :: Text
imgDockerArgName = "docker"

imgDockerBaseArgName :: Text
imgDockerBaseArgName = "base"

imgDockerAddArgName :: Text
imgDockerAddArgName = "add"

imgDockerEntrypointsArgName :: Text
imgDockerEntrypointsArgName = "entrypoints"
