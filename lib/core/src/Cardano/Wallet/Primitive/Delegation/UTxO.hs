module Cardano.Wallet.Primitive.Delegation.UTxO
    ( stakeKeyCoinDistr
    ) where

import Cardano.Wallet.Prelude

import Cardano.Wallet.Primitive.Types.Address
    ( Address (..) )
import Cardano.Wallet.Primitive.Types.Coin
    ( Coin )
import Cardano.Wallet.Primitive.Types.RewardAccount
    ( RewardAccount (..) )
import Cardano.Wallet.Primitive.Types.Tx
    ( TxOut (..) )
import Cardano.Wallet.Primitive.Types.UTxO
    ( UTxO (..) )
import Data.Map
    ( Map )

import qualified Cardano.Wallet.Primitive.Types.TokenBundle as TokenBundle
import qualified Data.Map as Map

-- | Calculate how much `Coin` exists on each `Maybe RewardAccount` in the
-- `UTxO` given a way to extract `Maybe RewardAccount` from an `Address`.
--
-- This is intended to be used with `rewardAccountFromAddress`, which exists
-- elsewhere because of the cardano-wallet-core / cardano-wallet split.
stakeKeyCoinDistr
    :: (Address -> Maybe RewardAccount)
    -> UTxO
    -> Map (Maybe RewardAccount) Coin
stakeKeyCoinDistr stakeRef =
    Map.fromListWith (<>) . map classifyOut . Map.elems . unUTxO
  where
    classifyOut :: TxOut -> (Maybe RewardAccount, Coin)
    classifyOut (TxOut addr b) = (stakeRef addr, TokenBundle.getCoin b)
