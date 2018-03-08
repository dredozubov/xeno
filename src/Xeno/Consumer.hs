{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE Strict #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Xeno.Consumer where


import           Control.Monad.Cont
import           Control.Monad.Except
import           Control.Monad.State
import           Data.ByteString
import           Data.Function
import           Debug.Trace
import           Streaming
import qualified Streaming.Prelude as S
import           Xeno.Streaming


data Input = TextVal ByteString | AttVal ByteString ByteString | End
  deriving (Show, Eq)

data Transition i = Transition
  { tInput :: i
  , tStackHead :: Maybe TagState
  , tStateUpdate :: i -> Maybe TagState
  }

data Transitions = Transitions
  { openK      :: [Transition ByteString]
  , attrK      :: [Transition (ByteString, ByteString)]
  , endOfOpenK :: [Transition ByteString]
  , textK      :: [Transition ByteString]
  , closeK     :: [Transition ByteString]
  , cdataK     :: [Transition ByteString]
  }

transit :: Automaton m -> SaxEvent -> Automaton m
transit pa@(Automaton st t _ _) event = pa { paStack = st' }
  where
    st' = case event of
      OpenTag s -> applyTransitions (openK t) s st
      Attr n s -> applyTransitions (attrK t) (n,s) st
      EndOfOpenTag s -> applyTransitions (endOfOpenK t) s st
      Text s -> applyTransitions (textK t) s st
      CloseTag s -> applyTransitions (closeK t) s st
      CDATA s -> applyTransitions (cdataK t) s st

applyTransitions
  :: Eq i
  => [Transition i]
  -> i
  -> [TagState]
  -> [TagState]
applyTransitions [ ] i ts = ts
applyTransitions (Transition iPattern sh su : transitions) i ts =
  if iPattern == i && case sh of
    Nothing -> True
    Just pat -> case mHead of
      Just tagState -> tagState == pat
      Nothing  -> False
  then case su i of
    Just updVal -> updVal : ts'
    Nothing     -> ts
  else applyTransitions transitions i ts
  where (mHead, ts') = safeHead ts

data TagState
  = Open ByteString
  | EndOfOpen ByteString
  deriving (Show, Eq, Ord)

data Automaton m = Automaton
  { paStack        :: [TagState]
  , paTransitions  :: Transitions
  , paAcceptState  :: SaxEvent
  , paStream       :: Stream (Of SaxEvent) m ()
  }

instance Show (Automaton m) where
  show (Automaton st _ a _) =
    "Automaton { "
    ++ ", paStack = " ++ show st
    ++ ", paAcceptState = " ++ show a

data World = World ByteString
  deriving (Show)

data Hello = Hello { hHello :: ByteString, hWorld :: World }
  deriving (Show)

safeHead :: [a] -> (Maybe a, [a])
safeHead l@[] = (Nothing, l)
safeHead (a:as) = (Just a, as)

data Result r
  = Partial (Input -> (Result r))
--     -- ^ Supply this continuation with more input so that the parser
--     -- can resume.  To indicate that no more input is available, pass
--     -- an empty string to the continuation.
--     --
--     -- __Note__: if you get a 'Partial' result, do not call its
--     -- continuation more than once.
  | Done r
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
    => (a -> Result r)
    -> State (Automaton m) (Result r)
  }

instance Functor (SaxParser m) where
  fmap f (SaxParser p) = SaxParser $ \ir -> p (\a -> ir (f a))

instance Applicative (SaxParser m) where
  pure a = SaxParser $ \k -> pure . k $ a
  SaxParser f <*> SaxParser x = SaxParser $ \k -> do
    st <- get
    x $ \a -> evalState (f $ \ab -> k $ ab a) st

instance Monad (SaxParser m) where
  SaxParser p >>= k = SaxParser $ \ir -> do
    st <- get
    p $ \a -> evalState (runSaxParser (k a) $ \b -> ir b) st

parse
  :: (MonadError ParserException m)
  => Automaton m
  -> SaxParser m a
  -> m (Result a)
parse pa@(Automaton stack transition acceptState s) (SaxParser p) = do
  -- traceM ("automaton: " ++ show pa)
  res <- S.next s
  case res of
    Left _               -> throwError $ ParserError $ show pa
    Right (event, s') -> do
      let (mHead, stack') = safeHead stack
      if event == acceptState && Prelude.null stack'
      then pure $ evalState (p Done) pa
      else do
        let pa' = transit pa event
        parse pa' $ SaxParser $ \ar -> do
          _


-- parseHello
--   :: forall m
--   . MonadError ParserException m
--   => ByteString
--   -> m Hello
-- parseHello str = eval automaton transition $ stream'
--   where
--     stream' :: Stream (Of SaxEvent) m ()
--     stream' = stream str
--     automaton :: Automaton (Hello Maybe)
--     automaton = Automaton Nothing [] acceptState (Hello Nothing)
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

-- emptyTransitions :: Transitions m r
-- emptyTransitions = \openK attrK endK textK closeK cdataK event ms r ->
--   case event of
--     OpenTag s -> openK s ms r
--     Attr n s -> attrK n s ms r
--     EndOfOpenTag s -> endK s ms r
--     Text s -> textK s ms r
--     CloseTag s -> closeK s ms r
--     CDATA s -> cdataK s ms r

checkStackHead :: Maybe TagState -> Maybe TagState -> Bool
checkStackHead x = \y -> case x of
  Nothing -> True
  Just x' -> case y of
    Nothing -> False
    Just y' -> y' == x'
