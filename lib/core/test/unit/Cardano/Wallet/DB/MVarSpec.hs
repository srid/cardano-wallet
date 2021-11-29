{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Wallet.DB.MVarSpec
    ( spec
    ) where

import Cardano.Wallet.Prelude

import Cardano.Wallet.DB.Properties
    ( properties )
import Cardano.Wallet.DummyTarget.Primitive.Types
    ( dummyTimeInterpreter )
import Cardano.Wallet.Primitive.AddressDerivation
    ( NetworkDiscriminant (..) )
import Cardano.Wallet.Primitive.AddressDerivation.Shelley
    ( ShelleyKey )
import Cardano.Wallet.Primitive.AddressDiscovery
    ( IsOurs (..) )
import Cardano.Wallet.Primitive.AddressDiscovery.Sequential
    ( SeqState (..) )
import Cardano.Wallet.Primitive.Types.Address
    ( Address )
import Test.Hspec
    ( Spec, before, describe )
import Test.QuickCheck
    ( Arbitrary (..) )
import Test.Utils.Platform
    ( pendingOnMacOS )

import qualified Cardano.Wallet.DB.MVar as MVar

spec :: Spec
spec =
    before (pendingOnMacOS "#2472: timeouts in hydra mac builds")
    $ before (MVar.newDBLayer @IO @(SeqState 'Mainnet ShelleyKey) ti)
    $ describe "MVar" properties
  where
    ti = dummyTimeInterpreter

newtype DummyStateMVar = DummyStateMVar Int
    deriving (Show, Eq)

instance Arbitrary DummyStateMVar where
    shrink _ = []
    arbitrary = DummyStateMVar <$> arbitrary

deriving instance NFData DummyStateMVar

instance IsOurs DummyStateMVar Address where
    isOurs _ num = (Nothing, num)
