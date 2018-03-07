{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}

module Xeno.Consumer where

import           Control.Monad.Cont
import           Control.Monad.Except
import           Data.ByteString
import           Data.Function
import           Debug.Trace
import           Streaming
import qualified Streaming.Prelude as S
import           Xeno.Streaming

-- data Input = TextVal ByteString | AttVal ByteString ByteString | End
--   deriving (Show, Eq)

-- data Transition m r = Transition
--   { tInput :: Input
--   , tStackHead :: Maybe TagState
--   , tStateUpdate :: Input -> m (Maybe TagState, r)
--   } deriving (Functor)

-- data Transitions m r = Transitions
--   { openK      :: [Transition m r]
--   , attrK      :: [Transition m r]
--   , endOfOpenK :: [Transition m r]
--   , textK      :: [Transition m r]
--   , closeK     :: [Transition m r]
--   , cdataK     :: [Transition m r]
--   } deriving (Functor)

-- data TagState
--   = Open ByteString
--   | EndOfOpen ByteString
--   deriving (Show, Eq, Ord)

-- data PushdownAutomaton m r = PushdownAutomaton
--   { paStack        :: [TagState]
--   , paTransitions  :: Transitions m r
--   , paAcceptState  :: SaxEvent
--   }

instance Monad m => Functor (PushdownAutomaton m) where
  fmap :: forall a b. (a -> b) -> PushdownAutomaton m a -> PushdownAutomaton m b
  fmap f (PushdownAutomaton s t a) = PushdownAutomaton s (f <$> t) a

instance Show (PushdownAutomaton m r) where
  show (PushdownAutomaton s _ a) =
    "PushdownAutomaton { "
    ++ ", paStack = " ++ show s
    ++ ", paAcceptState = " ++ show a

data World = World ByteString
  deriving (Show)

data Hello = Hello { hHello :: ByteString, hWorld :: World }
  deriving (Show)

safeHead :: [a] -> Maybe (a, [a])
safeHead [] = Nothing
safeHead (a:as) = Just (a, as)

data Result m r
  = Partial (Input -> (Result m r))
--     -- ^ Supply this continuation with more input so that the parser
--     -- can resume.  To indicate that no more input is available, pass
--     -- an empty string to the continuation.
--     --
--     -- __Note__: if you get a 'Partial' result, do not call its
--     -- continuation more than once.
  | Done (Stream (Of SaxEvent) m ()) r
--     -- ^ The parse succeeded.  The @i@ parameter is the input that had
--     -- not yet been consumed (if any) when the parse succeeded.
  deriving (Functor)

-- newtype Parser i a = Parser {
--       runParser :: forall r.
--                    State i -> Pos -> More
--                 -> Failure i (State i)   r
--                 -> Success i (State i) a r
--                 -> IResult i r
--     }

-- type Failure i t   r = t -> Pos -> More -> [String] -> String
--                        -> IResult i r
-- type Success i t a r = t -> Pos -> More -> a -> IResult i r

newtype SaxParser m a = SaxParser
  { runSaxParser
    :: forall r. (MonadError ParserException m)
    => Stream (Of SaxEvent) m ()
    -> (Stream (Of SaxEvent) m () -> a -> Result m r)
    -> Result m r
  }

instance Functor (SaxParser m) where
  fmap f (SaxParser p) = SaxParser $ \s ir -> do
    let ir' _ a = ir s (f a)
    p s (\_ a -> ir s (f a))

instance Applicative (SaxParser m) where
  pure a = SaxParser $ \s k -> k s a
  SaxParser f <*> SaxParser x = SaxParser $ \s k ->
    x s $ \_ a -> f s (\_ ab -> k s (ab a))

instance Monad (SaxParser m) where
  SaxParser p >>= k = SaxParser $ \s ir ->
    p s $ \_ a -> runSaxParser (k a) s $ \_ b -> ir s b

-- eval
--   :: (MonadError ParserException m, Show r)
--   => PushdownAutomaton m r
--   -> Stream (Of SaxEvent) m ()
--   -> Cont r (Input -> r)
--   -> m r
-- eval pa@(PushdownAutomaton stack transition acceptState) s k = do
--   -- traceM ("automaton: " ++ show pa)
--   res <- S.next s
--   case res of
--     Left _               -> throwError $ ParserError $ show pa
--     Right (newState, s') -> do
--       let
--         (mHead, stack') = case safeHead stack of
--           Just (h, st) -> (Just h, st)
--           Nothing      -> (Nothing, stack)
--       if newState == acceptState && Prelude.null stack'
--       then pure (runCont k $ \c -> c End)
--       else do
--         (upd, r) <- transition newState mHead k
--         -- traceM ("transitioned to: " ++ show (upd, r))
--         pa' <- pure $ case upd of
--           Just nv -> pa { paStack = nv : stack' }
--           Nothing -> pa
--         eval pa' s' (pure $ \End -> runCont r id)

-- parseHello
--   :: forall m
--   . MonadError ParserException m
--   => ByteString
--   -> m Hello
-- parseHello str = eval automaton transition $ stream'
--   where
--     stream' :: Stream (Of SaxEvent) m ()
--     stream' = stream str
--     automaton :: PushdownAutomaton (Hello Maybe)
--     automaton = PushdownAutomaton Nothing [] acceptState (Hello Nothing)
--     acceptState = CloseTag "greeting"
--     transition :: SealedTransitions m (Hello Maybe)
--     transition = emptyTransitions
--       & addOpenK "hello" Nothing (const pure)
--       & addEndK "hello" Nothing (const pure)
--       & addTextK (Just (EndOfOpen "hello")) _
--       & addCloseK "hello" Nothing (const pure)
--       & sealTransitions

helloXml :: ByteString
helloXml = "<?xml version=\"1.1\"?><foo><hello><inner>Hello,</inner><world> world!</world></hello></foo>"

emptyTransitions :: Transitions m r
emptyTransitions = \openK attrK endK textK closeK cdataK event ms r ->
  case event of
    OpenTag s -> openK s ms r
    Attr n s -> attrK n s ms r
    EndOfOpenTag s -> endK s ms r
    Text s -> textK s ms r
    CloseTag s -> closeK s ms r
    CDATA s -> cdataK s ms r

checkStackHead :: Maybe TagState -> Maybe TagState -> Bool
checkStackHead x = \y -> case x of
  Nothing -> True
  Just x' -> case y of
    Nothing -> False
    Just y' -> y' == x'
