{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Copyright: © 2018-2019 IOHK
-- License: MIT
--
-- Dummy implementation of the database-layer, using MVar. This may be good for
-- state-machine testing in order to compare it with an implementation on a real
-- data store.

module Cardano.Wallet.DB.MVar
    ( newDBLayer
    ) where

import Prelude

import Cardano.Wallet.DB
    ( DBLayer (..)
    , ErrNoSuchWallet (..)
    , ErrWalletAlreadyExists (..)
    , PrimaryKey (..)
    )
import Cardano.Wallet.Primitive.Model
    ( Wallet )
import Cardano.Wallet.Primitive.Types
    ( Hash, Tx, TxMeta, WalletId, WalletMetadata )
import Control.Arrow
    ( right )
import Control.Concurrent.MVar
    ( MVar, modifyMVar, newMVar, readMVar )
import Control.DeepSeq
    ( deepseq )
import Control.Monad.Trans.Except
    ( ExceptT (..) )
import Data.Map.Strict
    ( Map )

import qualified Data.Map.Strict as Map

data Database s = Database
    { wallet :: Wallet s
    , metadata :: WalletMetadata
    , txHistory :: Map (Hash "Tx") (Tx, TxMeta)
    }

-- | Instantiate a new in-memory "database" layer that simply stores data in
-- a local MVar. Data vanishes if the software is shut down.
newDBLayer :: forall s. IO (DBLayer IO s)
newDBLayer = do
    db <- newMVar (mempty :: Map (PrimaryKey WalletId) (Database s))
    return $ DBLayer
        {-----------------------------------------------------------------------
                                      Wallets
        -----------------------------------------------------------------------}

        { createWallet = \key@(PrimaryKey wid) cp meta -> ExceptT $ do
            let alter = \case
                    Nothing ->
                        Right $ Database cp meta mempty
                    Just _ ->
                        Left (ErrWalletAlreadyExists wid)
            cp `deepseq` meta `deepseq` alterMVar db alter key

        , listWallets =
            Map.keys <$> readMVar db

        {-----------------------------------------------------------------------
                                    Checkpoints
        -----------------------------------------------------------------------}

        , putCheckpoint = \key@(PrimaryKey wid) cp -> ExceptT $ do
            let alter = \case
                    Nothing ->
                        Left (ErrNoSuchWallet wid)
                    Just (Database _ meta history) ->
                        Right $ Database cp meta history
            cp `deepseq` alterMVar db alter key

        , readCheckpoint = \key ->
            fmap wallet . Map.lookup key <$> readMVar db

        {-----------------------------------------------------------------------
                                   Wallet Metadata
        -----------------------------------------------------------------------}

        , putWalletMeta = \key@(PrimaryKey wid) meta -> ExceptT $ do
            let alter = \case
                    Nothing ->
                        Left (ErrNoSuchWallet wid)
                    Just (Database cp _ history) ->
                        Right $ Database cp meta history
            meta `deepseq` alterMVar db alter key

        , readWalletMeta = \key -> do
            fmap metadata . Map.lookup key <$> readMVar db

        {-----------------------------------------------------------------------
                                     Tx History
        -----------------------------------------------------------------------}

        , putTxHistory = \key@(PrimaryKey wid) txs' -> ExceptT $ do
            let alter = \case
                    Nothing ->
                        Left (ErrNoSuchWallet wid)
                    Just (Database cp meta txs) ->
                        Right $ Database cp meta (txs <> txs')
            txs' `deepseq` alterMVar db alter key

        , readTxHistory = \key ->
            maybe mempty txHistory . Map.lookup key <$> readMVar db
        }


-- | Modify the content of an MVar holding a map with a given alteration
-- function. The map is only modified if the 'Right' branch of the alteration
-- function yields something. See also:
--
-- [Data.Map.Strict#alterF](https://hackage.haskell.org/package/containers-0.6.0.1/docs/Data-Map-Strict.html#v:alterF)
alterMVar
    :: Ord k
    => MVar (Map k v) -- MVar holding our mock database
    -> (Maybe v -> Either err v) -- An alteration function
    -> k -- Key to alter
    -> IO (Either err ())
alterMVar db alter key =
    modifyMVar db (\m -> bubble m $ Map.alterF ((right Just) . alter) key m)
  where
    -- | Re-wrap an error into an MVar result so that it will bubble up
    bubble :: Monad m => a -> Either err a -> m (a, Either err ())
    bubble a = \case
        Left err -> return (a, Left err)
        Right a' -> return (a', Right ())

