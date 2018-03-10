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
import           Debug.Trace
import           Streaming hiding ((<>))
import qualified Streaming.Prelude as S
import           Xeno.Streaming


data Input = TextVal ByteString | AttVal ByteString ByteString | End
  deriving (Show, Eq)

data StackAction a
  = Push a
  | NoOp
  deriving (Show, Functor, Eq)

transit
  :: Maybe TagState -- ^ head of the current stack
  -> Maybe TagState -- ^ search pattern
  -> StackAction TagState
  -> [TagState]
  -> [TagState]
transit mt sh sa st =
  if case mt of
    Nothing -> True
    Just tp -> case sh of
      Nothing -> False
      Just h  -> tp == h
  then case sa of
    NoOp -> st
    Push ns -> ns : st
  else st

data TagState
  = Open ByteString
  | EndOfOpen ByteString
  deriving (Show, Eq, Ord)

data Exactly a
  = Exactly a
  | Any
  deriving (Functor, Show)

compareExactly :: Eq a => Exactly a -> Exactly a -> Bool
compareExactly Any         _           = True
compareExactly _           Any         = True
compareExactly (Exactly a) (Exactly b) = a == b

type SaxStream = Stream (Of SaxEvent) (Either ParserException) ()

data World = World ByteString
  deriving (Show)

data Hello = Hello { hHello :: ByteString, hWorld :: World }
  deriving (Show)

safeHead :: [a] -> (Maybe a, [a])
safeHead l@[]   = (Nothing, l)
safeHead (a:as) = (Just a, as)

data Result r
  = Partial (Input -> (Result r)) (Exactly SaxEvent) SaxStream [TagState]
  -- ^ Supply this continuation with more input so that the parser
  -- can resume.  To indicate that no more input is available, pass
  -- an empty string to the continuation.
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
    .  Exactly SaxEvent
    -> [TagState]
    -> SaxStream
    -> (Exactly SaxEvent -> [TagState] -> SaxStream -> a -> Result r)
    -> Result r
  }

instance Functor SaxParser where
  fmap f (SaxParser p) =
    SaxParser $ \as st s k -> p as st s (\_ _ _ a -> k as st s (f a))

instance Applicative SaxParser where
  pure a = SaxParser $ \as st s k -> k as st s a
  (<*>) = apm
  f *> k = f >>= const k
  k <* f = k >>= \a -> f >> pure a

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

instance MonadFail SaxParser where
  fail s = SaxParser $ \_ _ _ _ -> Fail s

parseSax :: SaxParser a -> Exactly SaxEvent -> SaxStream -> Result a
parseSax (SaxParser p) as s = p as [] s (\_ _ _ a -> Done a)

-- skipUntil :: SaxParser a -> SaxParser a
-- skipUntil (SaxParser p) = SaxParser $ \as st s k ->
--   Partial _ _ _ _

skip :: SaxParser ()
skip = SaxParser $ \as st s k ->
  case S.next s of
    Right (Right (event, s')) -> trace ("skip event: " ++ show event)
      $ k as st s' ()
    _                         -> Fail "skip: stream exhausted"

openTag :: ByteString -> SaxParser ()
openTag tag = SaxParser $ \as st s k ->
  case S.next s of
   Right (Right (event, s')) ->
     trace ("openTag event: " ++ show event) $
     trace ("openTag acceptedState: " ++ show as) $
     trace ("openTag stack: " ++ show st) $
     case event of
       OpenTag tagN ->
         let (mHead, poppedStack) = safeHead st
         in if Exactly event `compareExactly` as && Prelude.null poppedStack
         then trace "openTag event: finalize" $ k (Exactly $ EndOfOpenTag tag) poppedStack s' ()
         else
           let
             newStack =
               if tagN == tag
               then transit mHead Nothing (Push $ Open tag) poppedStack
               else poppedStack
           in trace "openTag: recursive parse" $ k (Exactly $ EndOfOpenTag tag) newStack s' ()
       _            -> Partial (\_ -> k as st s' ()) as s' st
   _                         -> Fail $ "openTag " ++ show tag ++ ": stream exhausted"

endOfOpenTag :: ByteString -> SaxParser ()
endOfOpenTag tag = SaxParser $ \as st s k ->
  case S.next s of
   Right (Right (event, s')) ->
     trace ("endOfOpenTag " ++ show tag ++ " event: " ++ show event) $
     trace ("endOfOpenTag " ++ show tag ++ " acceptedState: " ++ show as) $
     trace ("endOfOpenTag " ++ show tag ++ " stack: " ++ show st) $
     case event of
       EndOfOpenTag tagN ->
         let
           (mHead, poppedStack) = safeHead st
           newStack             = if tagN == tag
             then transit mHead (Just $ Open tag) (Push $ EndOfOpen tag) poppedStack
             else poppedStack
         in trace "endOfOpenTag: recursive parse" $
           k (Exactly $ CloseTag tag) newStack s' ()
       _            -> Partial (\_ -> k (Exactly $ CloseTag tag) st s' ()) (Exactly $ CloseTag tag) s' st
   _                         -> Fail $ "endOfOpenTag " ++ show tag ++ ": stream exhausted"

text :: SaxParser ByteString
text = SaxParser $ \as st s k -> case S.next s of
  Right (Right (event, s')) ->
    trace ("text event: " ++ show event) $
    trace ("text acceptedState: " ++ show as) $
    trace ("text stack: " ++ show st) $
    case event of
      Text textVal -> trace "text: recursive parse" $ k as st s' textVal
      _            -> Fail "expected text value"
  _                         -> Fail $ "text stream exhausted"

closeTag :: ByteString -> SaxParser ()
closeTag tag = SaxParser $ \as st s k ->
  case S.next s of
   Right (Right (event, s')) ->
     trace ("closeTag event: " ++ show event) $
     trace ("closeTag acceptedState: " ++ show as) $
     trace ("closeTag stack: " ++ show st) $
     case event of
       CloseTag tagN ->
         let (mHead, poppedStack) = safeHead st
         in if Exactly event `compareExactly` as && Prelude.null poppedStack
         then trace "closeTag: finalizing" $ k Any poppedStack s' ()
         else
           let
             newStack =
               if tagN == tag
               then transit mHead (Just $ EndOfOpen tag) NoOp poppedStack
               else poppedStack
           in trace "closeTag: recursive parse" $ k Any newStack s' ()
       _            -> Partial (\_ -> k as st s' ()) as s' st
   _                         -> Fail $ "closeTag " ++ show tag ++ ": stream exhausted"

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

helloXml :: ByteString
helloXml = "<?xml version=\"1.1\"?><foo><hello><inner>Hello,</inner><world> world!</world></hello></foo>"
