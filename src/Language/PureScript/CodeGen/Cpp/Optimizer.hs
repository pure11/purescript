-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.CodeGen.Cpp.Optimizer
-- Copyright   :  (c) 2013-15 Phil Freeman, Andy Arvanitis, and other contributors
-- License     :  MIT
--
-- Maintainer  :  Andy Arvanitis
-- Stability   :  experimental
-- Portability :
--
-- |
-- This module optimizes code in the simplified-C++11 intermediate representation.
--
-- The following optimizations are supported:
--
--  * Collapsing nested blocks
--
--  * Tail call elimination
--
--  * Inlining of (>>=) and ret for the Eff monad
--
--  * Removal of unnecessary thunks
--
--  * Eta conversion
--
--  * Inlining variables
--
--  * Inline Prelude.($), Prelude.(#), Prelude.(++), Prelude.(!!)
--
--  * Inlining primitive C++11 operators
--
-----------------------------------------------------------------------------

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}

module Language.PureScript.CodeGen.Cpp.Optimizer (
    optimize
) where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative (Applicative)
#endif
import Control.Monad.Reader (MonadReader, ask, asks)
import Control.Monad.Supply.Class (MonadSupply)

import Language.PureScript.CodeGen.Cpp.AST
import Language.PureScript.Options
import qualified Language.PureScript.Constants as C

import Language.PureScript.CodeGen.Cpp.Optimizer.Blocks
import Language.PureScript.CodeGen.Cpp.Optimizer.Common
import Language.PureScript.CodeGen.Cpp.Optimizer.Inliner
import Language.PureScript.CodeGen.Cpp.Optimizer.MagicDo
import Language.PureScript.CodeGen.Cpp.Optimizer.TCO
import Language.PureScript.CodeGen.Cpp.Optimizer.Unused

-- |
-- Apply a series of optimizer passes to simplified C++11 code
--
optimize :: (Monad m, MonadReader Options m, Applicative m, MonadSupply m) => Cpp -> m Cpp
optimize cpp = do
  noOpt <- asks optionsNoOptimizations
  if noOpt then return cpp else optimize' cpp

optimize' :: (Monad m, MonadReader Options m, Applicative m, MonadSupply m) => Cpp -> m Cpp
optimize' cpp = do
  opts <- ask
  untilFixedPoint (inlineFnComposition . applyAll
    [ collapseNestedBlocks
    , collapseNestedIfs
    , tco opts
    , magicDo opts
    , removeCodeAfterReturnStatements
    , removeUnusedArg
    , removeUndefinedApp
    , unThunk
    , etaConvert
    , evaluateIifes
    , inlineVariables
    , inlineValues
    , inlineOperator (C.prelude, (C.$)) $ \f x -> CppApp f [x]
    , inlineOperator (C.prelude, (C.#)) $ \x f -> CppApp f [x]
    , inlineOperator (C.dataArrayUnsafe, C.unsafeIndex) $ flip CppIndexer
    , inlineCommonOperators ]) cpp

untilFixedPoint :: (Monad m, Eq a) => (a -> m a) -> a -> m a
untilFixedPoint f = go
  where
  go a = do
   a' <- f a
   if a' == a then return a' else go a'