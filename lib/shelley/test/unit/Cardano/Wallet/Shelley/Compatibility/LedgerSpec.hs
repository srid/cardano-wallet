{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Wallet.Shelley.Compatibility.LedgerSpec
    ( spec
    ) where

import Cardano.Wallet.Prelude

import Cardano.Wallet.Primitive.Types
    ( MinimumUTxOValue (..) )
import Cardano.Wallet.Primitive.Types.Coin
    ( Coin (..) )
import Cardano.Wallet.Primitive.Types.TokenBundle
    ( Flat (..), TokenBundle )
import Cardano.Wallet.Primitive.Types.TokenBundle.Gen
    ( genTokenBundleSmallRange, shrinkTokenBundleSmallRange )
import Cardano.Wallet.Primitive.Types.TokenPolicy
    ( TokenName, TokenPolicyId )
import Cardano.Wallet.Primitive.Types.TokenPolicy.Gen
    ( genTokenNameLargeRange, genTokenPolicyIdLargeRange )
import Cardano.Wallet.Primitive.Types.TokenQuantity
    ( TokenQuantity (..) )
import Cardano.Wallet.Primitive.Types.TokenQuantity.Gen
    ( genTokenQuantityFullRange, shrinkTokenQuantityFullRange )
import Cardano.Wallet.Primitive.Types.Tx
    ( txOutMaxCoin
    , txOutMaxTokenQuantity
    , txOutMinCoin
    , txOutMinTokenQuantity
    )
import Cardano.Wallet.Primitive.Types.Tx.Gen
    ( genTxOutCoin, genTxOutTokenBundle, shrinkTxOutCoin )
import Cardano.Wallet.Shelley.Compatibility.Ledger
    ( Convert (..), computeMinimumAdaQuantityInternal )
import Data.Typeable
    ( typeRep )
import Test.Hspec
    ( Spec, describe, it, parallel )
import Test.Hspec.Core.QuickCheck
    ( modifyMaxSuccess )
import Test.QuickCheck
    ( Arbitrary (..)
    , Blind (..)
    , Positive (..)
    , Property
    , checkCoverage
    , conjoin
    , counterexample
    , cover
    , genericShrink
    , oneof
    , property
    , withMaxSuccess
    , (=/=)
    , (===)
    )

import qualified Cardano.Wallet.Primitive.Types.Coin as Coin
import qualified Cardano.Wallet.Primitive.Types.TokenBundle as TokenBundle
import qualified Data.Set as Set

spec :: Spec
spec = describe "Cardano.Wallet.Shelley.Compatibility.LedgerSpec" $

    modifyMaxSuccess (const 1000) $ do

    parallel $ describe "Roundtrip conversions" $ do

        ledgerRoundtrip $ Proxy @Coin
        ledgerRoundtrip $ Proxy @TokenBundle
        ledgerRoundtrip $ Proxy @TokenName
        ledgerRoundtrip $ Proxy @TokenPolicyId
        ledgerRoundtrip $ Proxy @TokenQuantity

    parallel $ describe "Properties for computeMinimumAdaQuantity" $ do

        it "prop_computeMinimumAdaQuantity_forCoin" $
            property prop_computeMinimumAdaQuantity_forCoin
        it "prop_computeMinimumAdaQuantity_agnosticToAdaQuantity" $
            property prop_computeMinimumAdaQuantity_agnosticToAdaQuantity
        it "prop_computeMinimumAdaQuantity_agnosticToAssetQuantities" $
            property prop_computeMinimumAdaQuantity_agnosticToAssetQuantities

    parallel $ describe "Unit tests for computeMinimumAdaQuantity" $ do

        it "unit_computeMinimumAdaQuantity_emptyBundle" $
            property unit_computeMinimumAdaQuantity_emptyBundle
        it "unit_computeMinimumAdaQuantity_fixedSizeBundle_8" $
            property unit_computeMinimumAdaQuantity_fixedSizeBundle_8
        it "unit_computeMinimumAdaQuantity_fixedSizeBundle_64" $
            property unit_computeMinimumAdaQuantity_fixedSizeBundle_64
        it "unit_computeMinimumAdaQuantity_fixedSizeBundle_256" $
            property unit_computeMinimumAdaQuantity_fixedSizeBundle_256

--------------------------------------------------------------------------------
-- Properties
--------------------------------------------------------------------------------

prop_computeMinimumAdaQuantity_forCoin
    :: MinimumUTxOValue
    -> Coin
    -> Property
prop_computeMinimumAdaQuantity_forCoin minParam c =
    computeMinimumAdaQuantityInternal
        minParam
        (TokenBundle.fromCoin c)
        === expectedMinimumAdaQuantity
  where
    expectedMinimumAdaQuantity = case minParam of
        MinimumUTxOValue c' -> c'
        MinimumUTxOValueCostPerWord (Coin x) -> Coin $ x * 29

prop_computeMinimumAdaQuantity_agnosticToAdaQuantity
    :: Blind TokenBundle
    -> MinimumUTxOValue
    -> Property
prop_computeMinimumAdaQuantity_agnosticToAdaQuantity
    (Blind bundle) minParam =
        counterexample counterexampleText $ conjoin
            [ compute bundle === compute bundleWithCoinMinimized
            , compute bundle === compute bundleWithCoinMaximized
            , bundleWithCoinMinimized =/= bundleWithCoinMaximized
            ]
  where
    bundleWithCoinMinimized = TokenBundle.setCoin bundle txOutMinCoin
    bundleWithCoinMaximized = TokenBundle.setCoin bundle txOutMaxCoin
    compute = computeMinimumAdaQuantityInternal minParam
    counterexampleText = unlines
        [ "bundle:"
        , pretty (Flat bundle)
        , "bundle minimized:"
        , pretty (Flat bundleWithCoinMinimized)
        , "bundle maximized:"
        , pretty (Flat bundleWithCoinMaximized)
        ]

prop_computeMinimumAdaQuantity_agnosticToAssetQuantities
    :: Blind TokenBundle
    -> MinimumUTxOValue
    -> Property
prop_computeMinimumAdaQuantity_agnosticToAssetQuantities
    (Blind bundle) minVal =
        checkCoverage $
        cover 40 (assetCount >= 1)
            "Token bundle has at least 1 non-ada asset" $
        cover 20 (assetCount >= 2)
            "Token bundle has at least 2 non-ada assets" $
        cover 10 (assetCount >= 4)
            "Token bundle has at least 4 non-ada assets" $
        counterexample counterexampleText $ conjoin
            [ compute bundle === compute bundleMinimized
            , compute bundle === compute bundleMaximized
            , assetCount === assetCountMinimized
            , assetCount === assetCountMaximized
            , if assetCount == 0
                then bundleMinimized === bundleMaximized
                else bundleMinimized =/= bundleMaximized
            ]
  where
    assetCount = Set.size $ TokenBundle.getAssets bundle
    assetCountMinimized = Set.size $ TokenBundle.getAssets bundleMinimized
    assetCountMaximized = Set.size $ TokenBundle.getAssets bundleMaximized
    bundleMinimized = bundle `setAllQuantitiesTo` txOutMinTokenQuantity
    bundleMaximized = bundle `setAllQuantitiesTo` txOutMaxTokenQuantity
    compute = computeMinimumAdaQuantityInternal minVal
    setAllQuantitiesTo = flip (adjustAllQuantities . const)
    counterexampleText = unlines
        [ "bundle:"
        , pretty (Flat bundle)
        , "bundle minimized:"
        , pretty (Flat bundleMinimized)
        , "bundle maximized:"
        , pretty (Flat bundleMaximized)
        ]

--------------------------------------------------------------------------------
-- Unit tests
--------------------------------------------------------------------------------

-- | Creates a test to compute the minimum ada quantity for a token bundle with
--   a fixed number of assets, where the expected result is a constant.
--
-- Policy identifiers, asset names, token quantities are all allowed to vary.
--
unit_computeMinimumAdaQuantity_fixedSizeBundle
    :: TokenBundle
    -- ^ Fixed size bundle
    -> Coin
    -- ^ Expected minimum ada quantity
    -> Property
unit_computeMinimumAdaQuantity_fixedSizeBundle bundle expectation =
    withMaxSuccess 100 $
    computeMinimumAdaQuantityInternal (MinimumUTxOValue protocolMinimum) bundle === expectation
  where
    protocolMinimum = Coin 1_000_000

unit_computeMinimumAdaQuantity_emptyBundle :: Property
unit_computeMinimumAdaQuantity_emptyBundle =
    unit_computeMinimumAdaQuantity_fixedSizeBundle mempty $
        Coin 1000000

unit_computeMinimumAdaQuantity_fixedSizeBundle_8
    :: Blind (FixedSize8 TokenBundle) -> Property
unit_computeMinimumAdaQuantity_fixedSizeBundle_8 (Blind (FixedSize8 b)) =
    unit_computeMinimumAdaQuantity_fixedSizeBundle b $
        Coin 3888885

unit_computeMinimumAdaQuantity_fixedSizeBundle_64
    :: Blind (FixedSize64 TokenBundle) -> Property
unit_computeMinimumAdaQuantity_fixedSizeBundle_64 (Blind (FixedSize64 b)) =
    unit_computeMinimumAdaQuantity_fixedSizeBundle b $
        Coin 22555533

unit_computeMinimumAdaQuantity_fixedSizeBundle_256
    :: Blind (FixedSize256 TokenBundle) -> Property
unit_computeMinimumAdaQuantity_fixedSizeBundle_256 (Blind (FixedSize256 b)) =
    unit_computeMinimumAdaQuantity_fixedSizeBundle b $
        Coin 86555469

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

adjustAllQuantities
    :: (TokenQuantity -> TokenQuantity) -> TokenBundle -> TokenBundle
adjustAllQuantities adjust b = uncurry TokenBundle.fromFlatList $ second
    (fmap (fmap adjust))
    (TokenBundle.toFlatList b)

ledgerRoundtrip
    :: forall w l. (Arbitrary w, Eq w, Show w, Typeable w, Convert w l)
    => Proxy w
    -> Spec
ledgerRoundtrip proxy = it title $
    property $ \a -> toWallet (toLedger @w a) === a
  where
    title = mconcat
        [ "Can perform roundtrip conversion for values of type '"
        , show (typeRep proxy)
        , "'"
        ]

--------------------------------------------------------------------------------
-- Adaptors
--------------------------------------------------------------------------------

newtype FixedSize8 a = FixedSize8 { unFixedSize8 :: a }
    deriving (Eq, Show)

newtype FixedSize64 a = FixedSize64 { unFixedSize64 :: a }
    deriving (Eq, Show)

newtype FixedSize256 a = FixedSize256 { unFixedSize256 :: a }
    deriving (Eq, Show)

--------------------------------------------------------------------------------
-- Arbitraries
--------------------------------------------------------------------------------

instance Arbitrary Coin where
    -- This instance is used to test roundtrip conversions, so it's important
    -- that we generate coins across the full range available.
    arbitrary = genTxOutCoin
    shrink = shrinkTxOutCoin

instance Arbitrary MinimumUTxOValue where
    arbitrary = oneof
        [ MinimumUTxOValue . Coin.fromWord64 . (* 1_000_000) <$> genSmallWord
        , MinimumUTxOValueCostPerWord . Coin.fromWord64 <$> genSmallWord
        ]
      where
      genSmallWord = fromIntegral @Int @Word64 . getPositive <$> arbitrary
    shrink = genericShrink

instance Arbitrary TokenBundle where
    arbitrary = genTokenBundleSmallRange
    shrink = shrinkTokenBundleSmallRange

instance Arbitrary (FixedSize8 TokenBundle) where
    arbitrary = FixedSize8 <$> genTxOutTokenBundle 8
    -- No shrinking

instance Arbitrary (FixedSize64 TokenBundle) where
    arbitrary = FixedSize64 <$> genTxOutTokenBundle 64
    -- No shrinking

instance Arbitrary (FixedSize256 TokenBundle) where
    arbitrary = FixedSize256 <$> genTxOutTokenBundle 256
    -- No shrinking

instance Arbitrary TokenName where
    arbitrary = genTokenNameLargeRange
    -- No shrinking

instance Arbitrary TokenPolicyId where
    arbitrary = genTokenPolicyIdLargeRange
    -- No shrinking

instance Arbitrary TokenQuantity where
    arbitrary = genTokenQuantityFullRange
    shrink = shrinkTokenQuantityFullRange
