{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE StandaloneDeriving    #-}
module Network.HTTP.Download.Verified
  ( verifiedDownload
  , DownloadRequest(..)
  , drRetriesDefault
  , HashCheck(..)
  , CheckHexDigest(..)
  , LengthCheck
  , VerifiedDownloadException(..)
  ) where

import qualified Data.List as List
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Base64 as B64
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.List as CL
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

import Control.Monad
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Applicative
import Crypto.Hash
import Crypto.Hash.Conduit (sinkHash)
import Data.ByteString (ByteString)
import Data.Conduit
import Data.Conduit.Binary (sourceHandle, sinkHandle)
import Data.Foldable (traverse_,for_)
import Data.Monoid
import Data.String
import Data.Typeable (Typeable)
import Network.HTTP.Client.Conduit
import Network.HTTP.Types.Header (hContentLength, hContentMD5)
import Path
import Prelude -- Fix AMP warning
import System.FilePath((<.>))
import System.Directory
import System.IO

-- | A request together with some checks to perform.
data DownloadRequest = DownloadRequest
    { drRequest :: Request
    , drHashChecks :: [HashCheck]
    , drLengthCheck :: Maybe LengthCheck
    , drRetries :: Int
    }
  deriving Show

-- | Default to retrying thrice.
drRetriesDefault :: Int
drRetriesDefault = 3

data HashCheck = forall a. (Show a, HashAlgorithm a) => HashCheck
  { hashCheckAlgorithm :: a
  , hashCheckHexDigest :: CheckHexDigest
  }
deriving instance Show HashCheck

data CheckHexDigest
  = CheckHexDigestString String
  | CheckHexDigestByteString ByteString
  | CheckHexDigestHeader ByteString
  deriving Show
instance IsString CheckHexDigest where
  fromString = CheckHexDigestString

type LengthCheck = Int

-- | An exception regarding verification of a download.
data VerifiedDownloadException
    = WrongContentLength
          Request
          Int -- expected
          ByteString -- actual (as listed in the header)
    | WrongStreamLength
          Request
          Int -- expected
          Int -- actual
    | WrongDigest
          Request
          String -- algorithm
          CheckHexDigest -- expected
          String -- actual (shown)
    | ZeroTries
          Request
  deriving (Typeable)
instance Show VerifiedDownloadException where
    show (WrongContentLength req expected actual) =
        "Download expectation failure: ContentLength header\n"
        ++ "Expected: " ++ show expected ++ "\n"
        ++ "Actual:   " ++ displayByteString actual ++ "\n"
        ++ "For: " ++ show (getUri req)
    show (WrongStreamLength req expected actual) =
        "Download expectation failure: download size\n"
        ++ "Expected: " ++ show expected ++ "\n"
        ++ "Actual:   " ++ show actual ++ "\n"
        ++ "For: " ++ show (getUri req)
    show (WrongDigest req algo expected actual) =
        "Download expectation failure: content hash (" ++ algo ++  ")\n"
        ++ "Expected: " ++ displayCheckHexDigest expected ++ "\n"
        ++ "Actual:   " ++ actual ++ "\n"
        ++ "For: " ++ show (getUri req)
    show (ZeroTries req) =
        "Download expectation failure:\n"
        ++ "Download was needed but <= 0 retries were requested.\n"
        ++ "For: " ++ show (getUri req)

instance Exception VerifiedDownloadException

-- This exception is always caught and never thrown outside of this module.
data VerifyFileException
    = WrongFileSize
          Int -- expected
          Integer -- actual (as listed by hFileSize)
  deriving (Show, Typeable)
instance Exception VerifyFileException

-- Show a ByteString that is known to be UTF8 encoded.
displayByteString :: ByteString -> String
displayByteString =
    Text.unpack . Text.strip . Text.decodeUtf8

-- Show a CheckHexDigest in human-readable format.
displayCheckHexDigest :: CheckHexDigest -> String
displayCheckHexDigest (CheckHexDigestString s) = s ++ " (String)"
displayCheckHexDigest (CheckHexDigestByteString s) = displayByteString s ++ " (ByteString)"
displayCheckHexDigest (CheckHexDigestHeader h) =
      displayByteString (B64.decodeLenient h) ++ " (Header. unencoded: "
      ++ displayByteString h ++ ")"


-- | Make sure that the hash digest for a finite stream of bytes
-- is as expected.
--
-- Throws WrongDigest (VerifiedDownloadException)
sinkCheckHash :: MonadThrow m
    => Request
    -> HashCheck
    -> Consumer ByteString m ()
sinkCheckHash req HashCheck{..} = do
    digest <- sinkHashUsing hashCheckAlgorithm
    let actualDigestString = show digest
    let actualDigestHexByteString = digestToHexByteString digest

    let passedCheck = case hashCheckHexDigest of
          CheckHexDigestString s -> s == actualDigestString
          CheckHexDigestByteString b -> b == actualDigestHexByteString
          CheckHexDigestHeader b -> B64.decodeLenient b == actualDigestHexByteString
            -- A hack to allow hackage tarballs to download.
            -- They should really base64-encode their md5 header as per rfc2616#sec14.15.
            -- https://github.com/commercialhaskell/stack/issues/240
            || b == actualDigestHexByteString

    when (not passedCheck) $
        throwM $ WrongDigest req (show hashCheckAlgorithm) hashCheckHexDigest actualDigestString

assertLengthSink :: MonadThrow m
    => Request
    -> LengthCheck
    -> ZipSink ByteString m ()
assertLengthSink req expectedStreamLength = ZipSink $ do
  Sum actualStreamLength <- CL.foldMap (Sum . ByteString.length)
  when (actualStreamLength /= expectedStreamLength) $
    throwM $ WrongStreamLength req expectedStreamLength actualStreamLength

-- | A more explicitly type-guided sinkHash.
sinkHashUsing :: (Monad m, HashAlgorithm a) => a -> Consumer ByteString m (Digest a)
sinkHashUsing _ = sinkHash

-- | Turns a list of hash checks into a ZipSink that checks all of them.
hashChecksToZipSink :: MonadThrow m => Request -> [HashCheck] -> ZipSink ByteString m ()
hashChecksToZipSink req = traverse_ (ZipSink . sinkCheckHash req)

-- TODO(DanBurton): use Control.Retry instead.
-- Type inference drives the decision of which exceptions merit a retry.
retry :: (MonadCatch m, Exception e)
  => Int -- ^ The number of times to retry
  -> m a -- ^ Action to retry
  -> m (Either [e] a)
retry n0 action =
    go n0 []
  where
    go n es
      | n <= 0 = return (Left es)
      | otherwise = do
          eRes <- try action
          case eRes of
            Left e -> go (n - 1) (e : es)
            Right a -> return (Right a)


-- | Copied and extended version of Network.HTTP.Download.download.
--
-- Has the following additional features:
-- * Verifies that response content-length header (if present)
--     matches expected length
-- * Limits the download to (close to) the expected # of bytes
-- * Verifies that the expected # bytes were downloaded (not too few)
-- * Verifies md5 if response includes content-md5 header
-- * Verifies the expected hashes
--
-- Throws VerifiedDownloadException.
-- Throws IOExceptions related to file system operations.
-- Throws HttpException.
verifiedDownload :: (MonadReader env m, HasHttpManager env, MonadIO m)
         => DownloadRequest
         -> Path Abs File -- ^ destination
         -> Sink ByteString (ReaderT env IO) () -- ^ custom hook to observe progress
         -> m Bool -- ^ Whether a download was performed
verifiedDownload DownloadRequest{..} destpath progressSink = do
    let req = drRequest
    env <- ask
    liftIO $ whenM' getShouldDownload $ do
        createDirectoryIfMissing True dir
        withBinaryFile fptmp WriteMode $ \h -> do
            eRes <- retry drRetries $
                flip runReaderT env $
                    withResponse req (go h)
            case (eRes :: Either [HttpException] ()) of
                Left [] -> throwM $ ZeroTries req
                Left (e:_) -> throwM e -- just re-throw the latest HttpException
                Right () -> return ()
        renameFile fptmp fp
  where
    whenM' mp m = do
        p <- mp
        if p then m >> return True else return False

    fp = toFilePath destpath
    fptmp = fp <.> "tmp"
    dir = toFilePath $ parent destpath

    getShouldDownload = do
        fileExists <- doesFileExist fp
        if fileExists
            -- only download if file does not match expectations
            then not <$> fileMatchesExpectations
            -- or if it doesn't exist yet
            else return True

    -- precondition: file exists
    -- TODO: add logging
    fileMatchesExpectations =
        (checkExpectations >> return True)
          `catch` \(_ :: VerifyFileException) -> return False
          `catch` \(_ :: VerifiedDownloadException) -> return False

    checkExpectations = bracket (openFile fp ReadMode) hClose $ \h -> do
        for_ drLengthCheck $ checkFileSizeExpectations h
        sourceHandle h $$ getZipSink (hashChecksToZipSink drRequest drHashChecks)

    -- doesn't move the handle
    checkFileSizeExpectations h expectedFileSize = do
        fileSizeInteger <- hFileSize h
        when (fileSizeInteger > toInteger (maxBound :: Int)) $
            throwM $ WrongFileSize expectedFileSize fileSizeInteger
        let fileSize = fromInteger fileSizeInteger
        when (fileSize /= expectedFileSize) $
            throwM $ WrongFileSize expectedFileSize fileSizeInteger

    checkContentLengthHeader headers expectedContentLength = do
        case List.lookup hContentLength headers of
            Just lengthBS -> do
              let lengthStr = displayByteString lengthBS
              when (lengthStr /= show expectedContentLength) $
                throwM $ WrongContentLength drRequest expectedContentLength lengthBS
            _ -> return ()

    go h res = do
        let headers = responseHeaders res
        for_ drLengthCheck $ checkContentLengthHeader headers
        let hashChecks = (case List.lookup hContentMD5 headers of
                Just md5BS ->
                    [ HashCheck
                          { hashCheckAlgorithm = MD5
                          , hashCheckHexDigest = CheckHexDigestHeader md5BS
                          }
                    ]
                Nothing -> []
                ) ++ drHashChecks

        responseBody res
            $= maybe (awaitForever yield) CB.isolate drLengthCheck
            $$ getZipSink
                ( hashChecksToZipSink drRequest hashChecks
                  *> maybe (pure ()) (assertLengthSink drRequest) drLengthCheck
                  *> ZipSink (sinkHandle h)
                  *> ZipSink progressSink)
