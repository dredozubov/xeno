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


import           Control.Monad.Fail
import           Data.ByteString hiding (empty)
import           Data.Semigroup
import           Data.Sequence
import           Debug.Trace
import           Streaming hiding ((<>))
import qualified Streaming.Prelude as S
import           Xeno.Streaming


data Input = TextVal ByteString | AttVal ByteString ByteString | End
  deriving (Show, Eq)

data Transition i = Transition
  { tInput :: i
  , tStackHead :: Maybe TagState
  , tStateUpdate :: Maybe TagState
  } deriving (Show)

trans
  :: Maybe TagState
  -> Maybe TagState
  -> Maybe TagState
  -> [TagState]
  -> [TagState]
trans mt sh su st =
  if case mt of
    Nothing -> True
    Just tp -> case sh of
      Nothing -> False
      Just h  -> tp == h
  then case su of
    Nothing -> st
    Just ns -> ns : st
  else st

transit1 :: Eq i => i -> Maybe TagState -> Transition i -> [TagState] -> [TagState]
transit1 i mt (Transition ip sh su) st =
  if i == ip && case mt of
    Nothing -> True
    Just tp -> case sh of
      Nothing -> False
      Just h  -> tp == h
  then case su of
    Nothing -> st
    Just ns -> ns : st
  else st

data Transitions = Transitions
  { openK      :: Seq (Transition ByteString)
  , attrK      :: Seq (Transition (ByteString, ByteString))
  , endOfOpenK :: Seq (Transition ByteString)
  , textK      :: Seq (Transition ByteString)
  , closeK     :: Seq (Transition ByteString)
  , cdataK     :: Seq (Transition ByteString)
  } deriving (Show)

emptyTransitions :: Transitions
emptyTransitions = Transitions empty empty empty empty empty empty

addOpenK :: Transition ByteString -> Transitions -> Transitions
addOpenK new tr = tr { openK = new <| openK tr }

addAttrK :: Transition (ByteString, ByteString) -> Transitions -> Transitions
addAttrK new tr = tr { attrK = new <| attrK tr }

addEndOfOpenK :: Transition ByteString -> Transitions -> Transitions
addEndOfOpenK new tr = tr { endOfOpenK = new <| endOfOpenK tr }

addTextK :: Transition ByteString -> Transitions -> Transitions
addTextK new tr = tr { textK = new <| textK tr }

addCloseK :: Transition ByteString -> Transitions -> Transitions
addCloseK new tr = tr { closeK = new <| closeK tr }

addCdataK :: Transition ByteString -> Transitions -> Transitions
addCdataK new tr = tr { cdataK = new <| cdataK tr }

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
    then case su of
      Just updVal -> updVal : ts
      Nothing     -> ts
    else applyTransitions i mHead ts transitions

data TagState
  = Open ByteString
  | EndOfOpen ByteString
  deriving (Show, Eq, Ord)

type SaxStream = Stream (Of SaxEvent) (Either ParserException) ()

data World = World ByteString
  deriving (Show)

data Hello = Hello { hHello :: ByteString, hWorld :: World }
  deriving (Show)

safeHead :: [a] -> (Maybe a, [a])
safeHead l@[] = (Nothing, l)
safeHead (a:as) = (Just a, as)

data Result r
  = Partial (Input -> (Result r)) SaxEvent SaxStream [TagState]
  -- ^ Supply this continuation with more input so that the parser
  -- can resume.  To indicate that no more input is available, pass
  -- an empty string to the continuation.
  --
  -- __Note__: if you get a 'Partial' result, do not call its
  -- continuation more than once.
  | Done r
  -- ^ The parse succeeded.  The @i@ parameter is the input that had
  -- not yet been consumed (if any) when the parse succeeded.
  | Fail String
  -- ^ The parse failed with current message
  deriving (Functor)

instance Show r => Show (Result r) where
  show (Fail s) = "Fail " ++ s
  show (Partial _ as _ st) = "Partial { <...>,"
    ++ "paAcceptedState: " ++ show as
    ++ ", psStack: " ++ show st
    ++ " }"
  show (Done r) = "Done " ++ show r

newtype SaxParser a = SaxParser
  { runSaxParser :: forall r
    .  SaxEvent
    -> [TagState]
    -> SaxStream
    -> (SaxEvent -> [TagState] -> SaxStream -> a -> Result r)
    -> Result r
  }

instance Functor SaxParser where
  fmap f (SaxParser p) =
    SaxParser $ \as st s k -> p as st s (\_ _ _ a -> k as st s (f a))

instance Applicative SaxParser where
  pure a = SaxParser $ \as st s k -> k as st s a
  (<*>) = apm

apm :: SaxParser (a -> b) -> SaxParser a -> SaxParser b
apm pab pa = do
  ab <- pab
  a <- pa
  return $ ab a

instance Monad SaxParser where
  return = pure
  SaxParser p >>= k = SaxParser $ \as st s ir ->
    let f as' st' s' a = runSaxParser (k a) as' st' s' ir
    in p as st s f

-- instance MonadFail SaxParser where
--   fail s = SaxParser $ \_ _ _ _ _ _ -> Fail s

parseSax :: SaxParser a -> SaxEvent -> SaxStream -> Result a
parseSax (SaxParser p) as s = p as [] s (\_ _ _ a -> Done a)

-- eval
--   :: ((Transitions -> Transitions) -> Transitions)
--   -> SaxEvent
--   -> SaxStream
--   -> [TagState]
--   -> SaxParser a
--   -> (Result a)
-- eval kt acceptState s stack (SaxParser p) =
--   case S.next s of
--     Left _                    -> Fail "FIXME: stream exhausted"
--     Right (Right (event, s')) ->
--       let (mHead, stack') = safeHead stack
--       in if event == acceptState && Prelude.null stack'
--       then p kt acceptState s stack' Done
--       else let stack'' = transit (kt id) mHead stack' event
--         -- in parse transitions acceptState s' stack'' (SaxParser p)
--         in p kt acceptState s' stack'' (\i -> _)

-- skipUntil :: SaxParser a -> SaxParser a
-- skipUntil (SaxParser p) = SaxParser $ \as tr st s fk k ->
--   case S.next s of
--    Left _                    -> Fail "FIXME: stream exhausted"
--    Right (Right (event, s')) ->
--      if event == as && Prelude.null poppedStack
--      p as (tr id) st

-- skip :: SaxParser ()
-- skip = SaxParser $ \_ st s k ->
--   case S.next s of
--     Right (Right (event, s')) -> trace ("skip event: " ++ show event)
--       $ Partial (\_ -> k ()) s' st
--     _                         -> Fail "skip: stream exhausted"

openTag :: ByteString -> Maybe TagState -> SaxParser ()
openTag tag mt = SaxParser $ \as st s k ->
  case S.next s of
   Right (Right (event, s')) ->
     trace ("openTag event: " ++ show event) $
     trace ("openTag acceptedState: " ++ show as) $
     trace ("openTag stack: " ++ show st) $
     case event of
       OpenTag tagN ->
         let (mHead, poppedStack) = safeHead st
         in if event == as && Prelude.null poppedStack
         then k ()
         else
           let
             newStack =
               if tagN == tag
               then trans mHead mt (Just $ Open tag) poppedStack
               else poppedStack
           in Partial (\_ -> k ()) s' newStack
       _            -> Partial (\_ -> k ()) s' st
   _                         -> Fail $ "openTag " ++ show tag ++ ": stream exhausted"

-- textVal :: Maybe TagState -> SaxParser ByteString
-- textVal mt = SaxParser $ \as tr s k ->
--   Partial  (\tk -> tk . updt $ tr))
--   where
--     updt = addTextK

-- test :: Result ()
-- test = parse (\k -> k emptyTransitions) (EndOfOpenTag "foo") (stream helloXml) [] (openTag "foo")

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
