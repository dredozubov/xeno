{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

module Xeno.Consumer where


import           Control.Monad.Except
import           Data.ByteString
import           Data.Semigroup
import           Data.Sequence
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
  { openK      :: Seq (Transition ByteString)
  , attrK      :: Seq (Transition (ByteString, ByteString))
  , endOfOpenK :: Seq (Transition ByteString)
  , textK      :: Seq (Transition ByteString)
  , closeK     :: Seq (Transition ByteString)
  , cdataK     :: Seq (Transition ByteString)
  }

instance Semigroup Transitions where
  Transitions o1 a1 e1 t1 c1 d1 <> Transitions o2 a2 e2 t2 c2 d2
    = Transitions (o1 >< o2) (a1 >< a2) (e1 >< e2) (t1 >< t2) (c1 >< c2) (d1 >< d2)

transit :: Transitions -> Maybe TagState -> [TagState] -> SaxEvent -> [TagState]
transit t mt st event = case event of
  OpenTag s -> applyTransitions s mt st (openK t)
  Attr n s -> applyTransitions (n,s) mt st (attrK t)
  EndOfOpenTag s -> applyTransitions s mt st (endOfOpenK t)
  Text s -> applyTransitions s mt st (textK t)
  CloseTag s -> applyTransitions s mt st (closeK t)
  CDATA s -> applyTransitions s mt st (cdataK t)

applyTransitions
  :: Eq i
  => i
  -> Maybe TagState
  -> [TagState]
  -> Seq (Transition i)
  -> [TagState]
applyTransitions i mHead ts (viewl -> se) = case se of
  EmptyL                                     -> ts
  (Transition iPattern sh su :< transitions) ->
    if iPattern == i && case sh of
      Nothing -> True
      Just pat -> case mHead of
        Just tagState -> tagState == pat
        Nothing       -> False
    then case su i of
      Just updVal -> updVal : ts
      Nothing     -> ts
    else applyTransitions i mHead ts transitions

data TagState
  = Open ByteString
  | EndOfOpen ByteString
  deriving (Show, Eq, Ord)

data Automaton m = Automaton
  { paStack        :: [TagState]
  , paStream       :: Stream (Of SaxEvent) m ()
  }

instance Show (Automaton m) where
  show (Automaton st _) =
    "Automaton { "
    ++ ", paStack = " ++ show st

data World = World ByteString
  deriving (Show)

data Hello = Hello { hHello :: ByteString, hWorld :: World }
  deriving (Show)

safeHead :: [a] -> (Maybe a, [a])
safeHead l@[] = (Nothing, l)
safeHead (a:as) = (Just a, as)

data Result m r
  = Partial (Input -> (Result m r)) (Stream (Of SaxEvent) m ()) [TagState]
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
    => Transitions
    -> SaxEvent       -- accept state
    -> Stream (Of SaxEvent) m ()
    -> [TagState]     -- stack
    -> (a -> Result m r)
    -> Result m r
  }

instance Functor (SaxParser m) where
  fmap f (SaxParser p) =
    SaxParser $ \tr as s st ir -> p tr as s st (\a -> ir (f a))

instance Applicative (SaxParser m) where
  pure a = SaxParser $ \_ _ _ _ k -> k $ a
  SaxParser f <*> SaxParser x = SaxParser $ \tr as s st k ->
    x tr as s st $ \a -> f tr as s st $ \ab -> k $ ab a

instance Monad (SaxParser m) where
  SaxParser p >>= k = SaxParser $ \tr as s st ir ->
    p tr as s st $ \a -> runSaxParser (k a) tr as s st $ \b -> ir b

parse
  :: (MonadError ParserException m)
  => Transitions
  -> SaxEvent
  -> Stream (Of SaxEvent) m ()
  -> [TagState]
  -> SaxParser m a
  -> m (Result m a)
parse transitions acceptState s stack (SaxParser p) = do
  -- traceM ("automaton: " ++ show pa)
  res <- S.next s
  case res of
    Left _            -> throwError $ ParserError $ show (stack, acceptState)
    Right (event, s') -> do
      let (mHead, stack') = safeHead stack
      if event == acceptState && Prelude.null stack'
      then pure $ p transitions acceptState s' stack' Done
      else do
        let stack'' = transit transitions mHead stack' event
        parse transitions acceptState s' stack'' (SaxParser p)

-- openTag :: ByteString -> SaxParser m a
-- openTag tag = SaxParser $ \tr as s st' k -> case

-- withTag :: ByteString -> SaxParser m a -> SaxParser m a
-- withTag tag (SaxParser s) = SaxParser $ \a -> do
--   _
--   s a
--   _

-- helloParser
--   :: forall m
--   . MonadError ParserException m
--   => ByteString
--   -> SaxParser m Hello
-- helloParser = do
--   withTag "hello" $ do
--     Hello <$> tagText

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
