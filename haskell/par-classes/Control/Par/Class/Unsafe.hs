{-# LANGUAGE CPP               #-}
{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE KindSignatures    #-}
{-# LANGUAGE PolyKinds         #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE TypeOperators     #-}
{-# LANGUAGE Unsafe            #-}

#if __GLASGOW_HASKELL__ >= 800
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE UndecidableInstances   #-}
-- Unfortunately, GHC's custom type errors produce a lot of false positives
-- for the redundant constraint checker
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
#endif

-- {-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies #-}

-- | Unsafe operations that end users should NOT import.
--
--   This is here only for other trusted implementation components.

module Control.Par.Class.Unsafe
  ( ParMonad(..)

#if __GLASGOW_HASKELL__ >= 800
  , IdempotentParMonad(..)
  , ParThreadSafe(..)
  , UnsafeInstance
#else
  , IdempotentParMonad
  , ParThreadSafe
  , SecretSuperClass
#endif
  )
where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif

import Control.Par.EffectSigs

import Unsafe.Coerce          (unsafeCoerce)
import Data.Constraint
import Control.Monad.IO.Class

#if __GLASGOW_HASKELL__ >= 800
import Data.Proxy (Proxy(..))
import GHC.TypeLits (ErrorMessage(..), TypeError)
#endif

-- | The essence of a Par monad is that its control flow is a binary tree of forked
-- threads.
--
-- Note, this class also serves a secondary purpose similar: providing an
-- implementation-internal way to lift IO into tho Par monad.  However, this is a
-- different use case than either `MonadIO` or `ParThreadSafe`.  Unlike the latter,
-- ALL Par monads should be a member of this class.  Unlike the former, the user
-- should not be able to access the `internalLiftIO` operation of this class from
-- @Safe@ code.
class ParMonad (p :: EffectSig -> * -> * -> *)
  where
  -- Public interface:
  ----------------------------------------

  pbind :: p e s a -> (a -> p e s b) -> p e s b
  preturn :: a -> p e s a

  -- | Forks a computation to happen in parallel.
  fork :: p e s () -> p e s ()

  -- | (Internal! Not exposed to the end user.) Unsafely cast effect signatures.
  internalCastEffects :: p e1 s a -> p e2 s a
  internalCastEffects = unsafeCoerce

  -- | Effect subtyping.  Lift an RO computation to be a potentially RW one.
  liftReadOnly :: p (SetReadOnly e) s a -> p e s a
  liftReadOnly = unsafeCoerce

  -- Private methods:
  ----------------------------------------

  -- | (Internal!  Not exposed to the end user.)  Lift an IO operation.  This should
  -- only be used by other infrastructure-level components, e.g. the implementation
  -- of monad transformers or LVars.
  internalLiftIO :: IO a -> p e s a

  -- | An associated type to allow (trusted) LVar implementations to use
  -- the monad as an IO Monad.
#if __GLASGOW_HASKELL__ >= 800
  type UnsafeParIO p = (r :: * -> *) | r -> p
#else
  type UnsafeParIO p :: * -> *
#endif

  unsafeParMonadIO :: p e s a -> UnsafeParIO p a
  parMonadIODict :: Dict (MonadIO (UnsafeParIO p))

-- If we use this design for ParMonad, we suffer these orphan instances:
-- (We cannot include Monad as a super-class of ParMonad, because it would
--  have to universally quantify over 'e' and 's', which is not allowed.)
instance ParMonad p => Monad (p e s) where
  (>>=) = pbind
  return = preturn

instance ParMonad p => Functor (p e s) where
  fmap f p = pbind p (return . f)

instance ParMonad p => Applicative (p e s) where
  pure = preturn
  f <*> x = pbind f (\f' -> pbind x (return . f'))


--------------------------------------------------------------------------------
-- Trusted classes, ParMonad

-- | This type class denotes the property that:
--
-- > (m >> m) == m
--
-- For all actions `m` in the monad.  For example, any concrete Par
-- monad which implements *only* `ParFuture` and/or `ParIVar`, would
-- retain this property.  Conversely, any `NonIdemParIVar` monad would
-- violate the property.
--
-- Users cannot create instances of this class in Safe code.
class ( ParMonad p
#if __GLASGOW_HASKELL__ < 800
      , SecretSuperClass p
#endif
      ) => IdempotentParMonad p where
#if __GLASGOW_HASKELL__ >= 800
  idempotentParMonad :: proxy p
  default idempotentParMonad :: UnsafeInstance IdempotentParMonad => Proxy p
  idempotentParMonad = Proxy
#endif

-- | The class of Par monads in which all monadic actions are threadsafe and do not
-- care which thread they execute on.  Thus, it is ok to inject additional parallelism.
--
-- Specifically, instances of ParThreadSafe must satisfy the law:
--
-- > (do m1; m2) == (do fork m1; m2)
--
-- Users cannot create instances of this class in Safe code.
class ( ParMonad p
#if __GLASGOW_HASKELL__ < 800
      , SecretSuperClass p
#endif
      ) => ParThreadSafe (p :: EffectSig -> * -> * -> *) where
#if __GLASGOW_HASKELL__ >= 800
  parThreadSafe :: proxy p
  default parThreadSafe :: UnsafeInstance ParMonad => Proxy p
  parThreadSafe = Proxy
#endif

#if __GLASGOW_HASKELL__ >= 800
class UnsafeInstance (clsName :: k)
instance TypeError ('Text "Illegal " ':<>: 'ShowType clsName ':<>: 'Text " instance"
              ':$$: 'Text "Refer to the documentation for an explanation")
    => UnsafeInstance clsName
#else
-- | This empty class is ONLY present to prevent users from instancing
-- classes which they should not be allowed to instance within the
-- SafeHaskell-supporting subset of parallel programming
-- functionality.
class SecretSuperClass (p :: EffectSig -> * -> * -> *) where
#endif
