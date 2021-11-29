{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Copyright: © 2018-2020 IOHK
-- License: Apache-2.0
--
-- HTTP-client(s) for fetching stake pool metadata from remote servers (directly
-- from pool operators, or from smash).

module Cardano.Pool.Metadata
    (

    -- * Fetch
      fetchFromRemote
    , StakePoolMetadataFetchLog (..)
    , fetchDelistedPools
    , healthCheck
    , isHealthyStatus
    , toHealthCheckSMASH
    , HealthStatusSMASH (..)

    -- * Construct URLs
    , UrlBuilder
    , identityUrlBuilder
    , registryUrlBuilder

    -- * re-exports
    , Manager
    , newManager
    , defaultManagerSettings

    -- * Types
    , SMASHPoolId (..)
    ) where

import Cardano.Wallet.Prelude

import Cardano.Wallet.Api.Types
    ( HealthCheckSMASH (..), HealthStatusSMASH (..), defaultRecordTypeOptions )
import Cardano.Wallet.Logging
    ( HasPrivacyAnnotation (..), HasSeverityAnnotation (..), Severity (..) )
import Cardano.Wallet.Primitive.AddressDerivation
    ( hex )
import Cardano.Wallet.Primitive.Types
    ( PoolId (..)
    , StakePoolMetadata (..)
    , StakePoolMetadataHash (..)
    , StakePoolMetadataUrl (..)
    , decodePoolIdBech32
    )
import Control.Monad.Trans.Except
    ( ExceptT (..), except, runExceptT, throwE, withExceptT )
import Crypto.Hash.Utils
    ( blake2b256 )
import Data.Aeson
    ( FromJSON
    , ToJSON
    , eitherDecodeStrict
    , fieldLabelModifier
    , genericParseJSON
    , genericToJSON
    , parseJSON
    , toJSON
    )
import Data.ByteArray.Encoding
    ( Base (..), convertToBase )
import Data.ByteString
    ( ByteString )
import Data.List
    ( intercalate )
import Data.Text.Class
    ( TextDecodingError (..) )
import Network.HTTP.Client
    ( HttpException (..)
    , Manager
    , ManagerSettings
    , brConsume
    , brReadSome
    , managerResponseTimeout
    , requestFromURI
    , responseBody
    , responseStatus
    , responseTimeoutMicro
    , withResponse
    )
import Network.HTTP.Types.Status
    ( status200, status404 )
import Network.URI
    ( URI (..), parseURI )
import UnliftIO.Exception
    ( IOException, handle )

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.HTTP.Client.TLS as HTTPS

-- | Build the SMASH metadata fetch endpoint for a single pool. Does not
-- contain leading '/'.
metadaFetchEp :: PoolId -> StakePoolMetadataHash -> String
metadaFetchEp pid (StakePoolMetadataHash bytes)
    = intercalate "/" (["api", "v1", "metadata"] ++ [pidStr, hashStr])
  where
    hashStr = T.unpack $ T.decodeUtf8 $ convertToBase Base16 bytes
    pidStr  = T.unpack $ toText pid

-- TODO: use SMASH servant types
healthCheckEP :: String
healthCheckEP = T.unpack $ T.intercalate "/" ["api", "v1", "status"]

delistedEP :: String
delistedEP = T.unpack $ T.intercalate "/" ["api", "v1", "delisted"]

-- | TODO: import SMASH types
newtype SMASHPoolId = SMASHPoolId
    { poolId :: T.Text
    } deriving stock (Eq, Show, Ord)
      deriving (Generic)

instance FromJSON SMASHPoolId where
    parseJSON = genericParseJSON defaultRecordTypeOptions
        { fieldLabelModifier = id }

instance ToJSON SMASHPoolId where
    toJSON = genericToJSON defaultRecordTypeOptions
        { fieldLabelModifier = id }

toPoolId :: SMASHPoolId -> Either TextDecodingError PoolId
toPoolId (SMASHPoolId pid) =
    either (\_ -> decodePoolIdBech32 pid) Right (fromText @PoolId pid)

-- | Some default settings, overriding some of the library's default with
-- stricter values.
defaultManagerSettings :: ManagerSettings
defaultManagerSettings =
    HTTPS.tlsManagerSettings
        { managerResponseTimeout = responseTimeoutMicro tenSeconds }
  where
    tenSeconds = 10_000_000 -- in μs

-- | Create a connection manager that supports TLS connections.
newManager :: MonadIO m => ManagerSettings -> m Manager
newManager = HTTPS.newTlsManagerWith

-- | A type-alias to ease signatures
type UrlBuilder
    =  PoolId
    -> StakePoolMetadataUrl
    -> StakePoolMetadataHash
    -> Either HttpException URI

-- | Simply return a pool metadata url, unchanged
identityUrlBuilder
    :: UrlBuilder
identityUrlBuilder _ (StakePoolMetadataUrl url) _ =
    maybe (Left e) Right $ parseURI (T.unpack url)
  where
    e = InvalidUrlException (T.unpack url) "Invalid URL"

-- | Build a URL from a metadata hash compatible with an aggregation registry
registryUrlBuilder
    :: URI
    -> UrlBuilder
registryUrlBuilder baseUrl pid _ hash =
    Right $ baseUrl
        { uriPath = "/" <> metadaFetchEp pid hash
        }

-- | A smash GET request that reads the result at once into memory.
smashRequest
    :: Tracer IO StakePoolMetadataFetchLog
    -> URI
    -> Manager
    -> ExceptT String IO ByteString
smashRequest tr uri manager = getPayload
  where
    getPayload :: ExceptT String IO ByteString
    getPayload = do
        req <- withExceptT show $ except $ requestFromURI uri
        liftIO $ traceWith tr $ MsgFetchSMASH uri
        ExceptT
            $ handle fromIOException
            $ handle fromHttpException
            $ withResponse req manager handleResponseStatus

    handleResponseStatus response = case responseStatus response of
        s | s == status200 -> do
            let body = responseBody response
            Right . BS.concat <$> brConsume body
        s ->
            pure $ Left $ mconcat
                [ "The server replied with something unexpected: "
                , show s
                ]

    fromHttpException :: Monad m => HttpException -> m (Either String a)
    fromHttpException = return . Left . ("HTTP exception: " <>) . show

-- | Gets the health status from the SMASH server. Returns
-- @Nothing@ if the server is unreachable.
healthCheck
    :: Tracer IO StakePoolMetadataFetchLog
    -> URI
    -> Manager
    -> IO (Maybe HealthStatusSMASH)
healthCheck tr uri manager = runExceptTLog $ do
    pl <- smashRequest tr
        (uri { uriPath = "/" <> healthCheckEP , uriQuery = "", uriFragment = "" })
        manager
    except . eitherDecodeStrict @HealthStatusSMASH $ pl
  where
    runExceptTLog
        :: ExceptT String IO HealthStatusSMASH
        -> IO (Maybe HealthStatusSMASH)
    runExceptTLog action = runExceptT action >>= \case
        Left msg ->
            Nothing <$ traceWith tr (MsgFetchHealthCheckFailure msg)
        Right health -> do
            traceWith tr (MsgFetchHealthCheckSuccess health)
            pure $ Just health

-- | Convert the result of @healthCheck@, which represents the
-- server response to our own @HealthCheckSMASH@ type, which is a
-- superset of it.
toHealthCheckSMASH :: Maybe HealthStatusSMASH -> HealthCheckSMASH
toHealthCheckSMASH = \case
    (Just health)
        | isHealthyStatus health -> Available
        | otherwise -> Unavailable
    _ -> Unreachable

isHealthyStatus :: HealthStatusSMASH -> Bool
isHealthyStatus (HealthStatusSMASH {..}) = T.toLower status == "ok"

fetchDelistedPools
    :: Tracer IO StakePoolMetadataFetchLog
    -> URI
    -> Manager
    -> IO (Maybe [PoolId])
fetchDelistedPools tr uri manager = runExceptTLog $ do
    pl <- smashRequest tr
        (uri { uriPath = "/" <> delistedEP , uriQuery = "", uriFragment = "" })
        manager
    smashPids <- except $ eitherDecodeStrict @[SMASHPoolId] pl
    forM smashPids $ except . first getTextDecodingError . toPoolId
  where
    runExceptTLog
        :: ExceptT String IO [PoolId]
        -> IO (Maybe [PoolId])
    runExceptTLog action = runExceptT action >>= \case
        Left msg ->
            Nothing <$ traceWith tr (MsgFetchDelistedPoolsFailure msg)

        Right meta ->
            Just meta <$ traceWith tr (MsgFetchDelistedPoolsSuccess meta)

-- TODO: refactor/simplify this
fetchFromRemote
    :: Tracer IO StakePoolMetadataFetchLog
    -> [UrlBuilder]
    -> Manager
    -> PoolId
    -> StakePoolMetadataUrl
    -> StakePoolMetadataHash
    -> IO (Maybe StakePoolMetadata)
fetchFromRemote tr builders manager pid url hash = runExceptTLog $ do
    chunk <- getChunk `fromFirst` builders
    when (BS.length chunk > 512) $ throwE
        "Metadata exceeds max length of 512 bytes"
    when (blake2b256 chunk /= coerce hash) $ throwE $ mconcat
        [ "Metadata hash mismatch. Saw: "
        , B8.unpack $ hex $ blake2b256 chunk
        , ", but expected: "
        , B8.unpack $ hex $ coerce @_ @ByteString hash
        ]
    except $ eitherDecodeStrict chunk
  where
    runExceptTLog
        :: ExceptT String IO StakePoolMetadata
        -> IO (Maybe StakePoolMetadata)
    runExceptTLog action = runExceptT action >>= \case
        Left msg ->
            Nothing <$ traceWith tr (MsgFetchPoolMetadataFailure hash msg)

        Right meta ->
            Just meta <$ traceWith tr (MsgFetchPoolMetadataSuccess hash meta)

    -- Try each builder in order, but only if the previous builder led to an
    -- IO exception. Other exceptions like HTTP exceptions are treated as
    -- 'normal' responses from the an aggregation server and do not cause a
    -- retry.
    fromFirst _ [] =
        throwE "Metadata server(s) didn't reply in a timely manner."
    fromFirst action (builder:rest) = do
        uri <- withExceptT show $ except $ builder pid url hash
        action uri >>= \case
            Nothing -> do
                liftIO $ traceWith tr $ MsgFetchPoolMetadataFallback uri (null rest)
                fromFirst action rest
            Just chunk ->
                pure chunk

    getChunk :: URI -> ExceptT String IO (Maybe ByteString)
    getChunk uri = do
        req <- withExceptT show $ except $ requestFromURI uri
        liftIO $ traceWith tr $ MsgFetchPoolMetadata hash uri
        ExceptT
            $ handle fromIOException
            $ handle fromHttpException
            $ withResponse req manager $ \res -> do
            -- NOTE
            -- Metadata are _supposed to_ be made of:
            --
            -- - A name (at most 50 UTF-8 bytes)
            -- - An optional description (at most 255 UTF-8 bytes)
            -- - A ticker (between 3 and 5 UTF-8 bytes)
            --
            -- So, the total, including a pretty JSON encoding with newlines ought
            -- to be less than or equal to 512 bytes. For security reasons, we only
            -- download the first 513 bytes and check the length at the
            -- call-site.
            case responseStatus res of
                s | s == status200 -> do
                    let body = responseBody res
                    Right . Just . BL.toStrict <$> brReadSome body 513

                s | s == status404 -> do
                    pure $ Left "There's no known metadata for this pool."

                s -> do
                    pure $ Left $ mconcat
                        [ "The server replied with something unexpected: "
                        , show s
                        ]

    fromHttpException :: Monad m => HttpException -> m (Either String (Maybe a))
    fromHttpException = const (return $ Right Nothing)

fromIOException :: Monad m => IOException -> m (Either String a)
fromIOException = return . Left . ("IO exception: " <>) . show

data StakePoolMetadataFetchLog
    = MsgFetchPoolMetadata StakePoolMetadataHash URI
    | MsgFetchPoolMetadataSuccess StakePoolMetadataHash StakePoolMetadata
    | MsgFetchPoolMetadataFailure StakePoolMetadataHash String
    | MsgFetchPoolMetadataFallback URI Bool
    | MsgFetchSMASH URI
    | MsgFetchDelistedPoolsFailure String
    | MsgFetchDelistedPoolsSuccess [PoolId]
    | MsgFetchHealthCheckFailure String
    | MsgFetchHealthCheckSuccess HealthStatusSMASH
    deriving (Show, Eq)

instance HasPrivacyAnnotation StakePoolMetadataFetchLog
instance HasSeverityAnnotation StakePoolMetadataFetchLog where
    getSeverityAnnotation = \case
        MsgFetchPoolMetadata{} -> Info
        MsgFetchPoolMetadataSuccess{} -> Info
        MsgFetchPoolMetadataFailure{} -> Warning
        MsgFetchPoolMetadataFallback{} -> Warning
        MsgFetchSMASH{} -> Debug
        MsgFetchDelistedPoolsFailure{} -> Warning
        MsgFetchDelistedPoolsSuccess{} -> Info
        MsgFetchHealthCheckFailure{} -> Warning
        MsgFetchHealthCheckSuccess{} -> Info

instance ToText StakePoolMetadataFetchLog where
    toText = \case
        MsgFetchPoolMetadata hash uri -> mconcat
            [ "Fetching metadata with hash ", pretty hash
            , " from ", T.pack (show uri)
            ]
        MsgFetchPoolMetadataSuccess hash meta -> mconcat
            [ "Successfully fetched metadata with hash ", pretty hash
            , ": ", T.pack (show meta)
            ]
        MsgFetchPoolMetadataFailure hash msg -> mconcat
            [ "Failed to fetch metadata with hash ", pretty hash, ": ", T.pack msg
            ]
        MsgFetchPoolMetadataFallback uri noMoreUrls -> mconcat
            [ "Couldn't reach server at ", T.pack (show uri), "."
            , if noMoreUrls
                then ""
                else " Falling back using a different strategy."
            ]
        MsgFetchSMASH uri -> mconcat
            [ "Making a SMASH request to ", T.pack (show uri)
            ]
        MsgFetchDelistedPoolsSuccess poolIds -> mconcat
            [ "Successfully fetched delisted "
            , T.pack (show . length $ poolIds)
            , " pools."
            ]
        MsgFetchDelistedPoolsFailure err -> mconcat
            [ "Failed to fetch delisted pools: ", T.pack err
            ]
        MsgFetchHealthCheckSuccess health -> mconcat
            [ "Successfully checked health "
            , T.pack (show health)
            ]
        MsgFetchHealthCheckFailure err -> mconcat
            [ "Failed to check health: ", T.pack err
            ]
