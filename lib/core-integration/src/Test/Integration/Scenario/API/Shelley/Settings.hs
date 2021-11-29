{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Test.Integration.Scenario.API.Shelley.Settings
    ( spec
    ) where

import Cardano.Wallet.Prelude

import Cardano.Wallet.Api.Types
    ( ApiStakePool
    , ApiT (..)
    , DecodeAddress
    , DecodeStakeAddress
    , EncodeAddress (..)
    )
import Cardano.Wallet.Primitive.AddressDerivation
    ( PaymentAddress )
import Cardano.Wallet.Primitive.AddressDerivation.Byron
    ( ByronKey )
import Cardano.Wallet.Primitive.AddressDerivation.Icarus
    ( IcarusKey )
import Cardano.Wallet.Primitive.AddressDerivation.Shelley
    ( ShelleyKey )
import Cardano.Wallet.Primitive.Types
    ( PoolMetadataSource (..), Settings )
import Cardano.Wallet.Primitive.Types.Coin
    ( Coin (..) )
import Test.Hspec
    ( SpecWith, describe, shouldBe, shouldSatisfy )
import Test.Hspec.Extra
    ( it )
import Test.Integration.Framework.DSL
    ( Context (..)
    , Headers (..)
    , Payload (..)
    , eventually
    , eventuallyUsingDelay
    , expectField
    , expectResponseCode
    , request
    , unsafeRequest
    , updateMetadataSource
    , verify
    , verifyMetadataSource
    )

import qualified Cardano.Wallet.Api.Link as Link
import qualified Network.HTTP.Types.Status as HTTP

spec :: forall n.
    ( DecodeAddress n
    , DecodeStakeAddress n
    , EncodeAddress n
    , PaymentAddress n ShelleyKey
    , PaymentAddress n IcarusKey
    , PaymentAddress n ByronKey
    ) => SpecWith Context
spec = describe "SHELLEY_SETTINGS" $ do
    it "SETTINGS_01 - Can put and read settings" $ \ctx -> do
        let uri = "http://smash.it"
        updateMetadataSource ctx uri
        eventually "The settings are applied" $ do
            r2 <- request @(ApiT Settings) ctx Link.getSettings Default Empty
            verify r2
                [ expectResponseCode HTTP.status200
                , expectField (#getApiT . #poolMetadataSource)
                    (`shouldBe` (fromRight (error "no") $ fromText
                        @PoolMetadataSource uri))
                ]

    it "SETTINGS_02 - Changing pool_metadata_source re-syncs metadata" $ \ctx -> do
        let toNone = "none"
            toDirect = "direct"
            getMetadata = fmap (view #metadata) . snd <$> unsafeRequest
                @[ApiStakePool] ctx (Link.listStakePools arbitraryStake) Empty
            delay = 500 * 1000
            timeout = 120

        updateMetadataSource ctx toNone
        verifyMetadataSource ctx FetchNone
        eventuallyUsingDelay delay timeout "1. There is no metadata" $
            getMetadata >>= (`shouldSatisfy` all isNothing)

        updateMetadataSource ctx toDirect
        verifyMetadataSource ctx FetchDirect
        eventuallyUsingDelay delay timeout "2. There is metadata" $
            getMetadata >>= (`shouldSatisfy` all isJust)

        updateMetadataSource ctx toNone
        verifyMetadataSource ctx FetchNone
        eventuallyUsingDelay delay timeout "3. There is no metadata" $
            getMetadata >>= (`shouldSatisfy` all isNothing)

arbitraryStake :: Maybe Coin
arbitraryStake = Just $ ada 10_000
  where ada = Coin . (1000*1000*)
