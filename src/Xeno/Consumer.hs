{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE UndecidableInstances #-}

module Xeno.Consumer where

import           Control.Monad.Cont
import           Control.Monad.Except
import           Data.ByteString
import           Data.Coerce
import           Data.Function
import           Debug.Trace
import           Streaming
import qualified Streaming.Prelude as S
import           Xeno.Streaming


type Transitions m r
  =  (ByteString -> Handler m r)
  -> (ByteString -> ByteString -> Handler m r)
  -> (ByteString -> Handler m r)
  -> (ByteString -> Handler m r)
  -> (ByteString -> Handler m r)
  -> (ByteString -> Handler m r)
  -> SealedTransitions m r

type SealedTransitions m r = SaxEvent -> Handler m r

type Handler m r
  = Maybe TagState        -- stack head
  -> Cont r (Input -> r)  -- result update
  -> m (Maybe TagState, (Cont r (r -> r)))

data Input = TextVal ByteString | AttrVal ByteString ByteString | End
  deriving (Show, Eq)

data TagState
  = Open ByteString
  | EndOfOpen ByteString
  deriving (Show, Eq, Ord)

data PushdownAutomaton = PushdownAutomaton
  { paCurrentState :: Maybe SaxEvent
  , paStack        :: [TagState]
  , paAcceptState  :: SaxEvent
  }

instance Show PushdownAutomaton where
  show (PushdownAutomaton c s a) =
    "PushdownAutomaton { paCurrentState = " ++ show c
    ++ ", paStack = " ++ show s
    ++ ", paAcceptState = " ++ show a ++ " }"
    -- ++ ", paResult = " ++ show r ++ " }"

data Hello = Hello { unHello :: ByteString }
  deriving (Show)

safeHead :: [a] -> Maybe (a, [a])
safeHead [] = Nothing
safeHead (a:as) = Just (a, as)

eval
  :: (MonadError ParserException m)
  => PushdownAutomaton
  -> SealedTransitions m r
  -> Cont r (Input -> r)
  -> Stream (Of SaxEvent) m ()
  -> m (Cont r (Input -> r))
eval pa@(PushdownAutomaton _ stack acceptState) transition cont s = do
  -- traceM ("automaton: " ++ show pa)
  res <- S.next s
  case res of
    Left _               -> throwError $ ParserError $ show pa
    Right (newState, s') -> do
      let
        (mHead, stack') = case safeHead stack of
          Just (h, st) -> (Just h, st)
          Nothing      -> (Nothing, stack)
      if newState == acceptState && Prelude.null stack'
      then pure cont
      else do
        (upd, k') <- transition newState mHead cont
        -- traceM ("transitioned to: " ++ show (upd, r))
        pa' <- case upd of
          Just nv -> do
            pure $ pa
              { paCurrentState = Just newState
              , paStack = nv : stack' }
          Nothing -> pure $ pa
            { paCurrentState = Just newState }
            -- , paResult = r }
        eval pa' transition ((.) <$> k' <*> cont) s'

parseHello
  :: forall m
  . MonadError ParserException m
  => ByteString
  -> m Hello
parseHello str = do
  let
    stream' :: Stream (Of SaxEvent) m ()
    stream'     = stream str
    automaton   = PushdownAutomaton Nothing [] acceptState
    acceptState = CloseTag "greeting"
    transition :: SealedTransitions m Hello
    transition  = emptyTransitions
      & addOpenK (TextVal "greeting") Nothing (\_ -> pure)
      & addEndK (TextVal "greeting") Nothing (\_ -> pure)
      & addTextK (Just (EndOfOpen "greeting"))
        (\tv@(TextVal t) k -> pure $ do
          hello <- k
          pure $ \_ -> hello tv
        )
      & addCloseK "greeting" Nothing (\_ -> pure)
      & sealTransitions
  r <- eval automaton transition (pure $ \(TextVal t) -> Hello t) stream'
  pure (runCont r (\f -> f End))

helloXml :: ByteString
helloXml = "<?xml version=\"1.1\"?>\n<foo><greeting>Hello, world!</greeting></foo>"

emptyTransitions :: Transitions m r
emptyTransitions = \openK attrK endK textK closeK cdataK event ms r ->
  case event of
    OpenTag s -> openK s ms r
    Attr n s -> attrK n s ms r
    EndOfOpenTag s -> endK s ms r
    Text s -> textK s ms r
    CloseTag s -> closeK s ms r
    CDATA s -> cdataK s ms r

addOpenK
  :: forall m r
  . Applicative m
  => Input
  -> Maybe TagState
  -> (Input -> Cont r (Input -> r) -> m (Cont r (Input -> r)))
  -> Transitions m r
  -> Transitions m r
addOpenK tagH@(TextVal tag) mt k tran = \o a e t c d ->
  let
    openK
      :: ByteString
      -> Maybe TagState
      -> Cont r (Input -> r)
      -> m (Maybe TagState, (Cont r (r -> r)))
    openK tagInspect mt' = if tagInspect == tag && checkStackHead mt mt'
      then \k' -> pure $ (Just (Open tag), do
                         _
                         )
      else _
  in tran openK a e t c d

sealTransitions
  :: Applicative m
  => Transitions m r
  -> SealedTransitions m r
sealTransitions t = _

checkStackHead :: Maybe TagState -> Maybe TagState -> Bool
checkStackHead x = \y -> case x of
  Nothing -> True
  Just x' -> case y of
    Nothing -> False
    Just y' -> y' == x'

pure2 :: Applicative m => a -> m (Maybe TagState, (Cont r (Input -> r)))
pure2 _ = _

pure3 :: Applicative m => a -> b -> m (Maybe TagState, (Cont r (Input -> r)))
pure3 _ _ = _

pure4 :: Applicative m => a -> b -> c -> m (Maybe TagState, (Cont r (Input -> r)))
pure4 _ _ _ = _

-- addAttrK
--   :: forall m r
--   . Applicative m
--   => ByteString
--   -> Maybe TagState
--   -> (ByteString -> ByteString -> r -> m r)
--   -> Transitions m r
--   -> Transitions m r
-- addAttrK attrH mt k tran = \o a e t c d ->
--   let
--     attrK :: ByteString -> ByteString -> Maybe TagState -> r -> m (Maybe TagState, r)
--     attrK attrInspect attrVal mt' = if attrInspect == attrH && checkStackHead mt mt'
--       then fmap (Nothing,) . k attrH
--       else a attrH mt
--   in tran o attrK e t c d

addEndK
  :: forall m r
  . Applicative m
  => Input
  -> Maybe TagState
  -> (Input -> Cont r (Input -> r) -> m (Cont r (Input -> r)))
  -> Transitions m r
  -> Transitions m r
addEndK (TextVal tagH) mt k tran = \o a e t c d ->
  let
    endK tagInspect mt' = if tagInspect == tagH && checkStackHead mt mt'
      then fmap (Just $ EndOfOpen tagH,) . k tagH
      else e tagH mt
  in tran o a endK t c d

addTextK
  :: forall m r
  . Applicative m
  => Maybe TagState
  -> (Input -> Cont r (Input -> r) -> m (Cont r (Input -> r)))
  -> Transitions m r
  -> Transitions m r
addTextK mt k tran = \o a e t c d ->
  let
    textK text mt' = if checkStackHead mt mt'
      then fmap (Nothing,) . k text
      else t text mt
  in tran o a e textK c d

addCloseK
  :: forall m r
  . Applicative m
  => ByteString
  -> Maybe TagState
  -> (Input -> Cont r (Input -> r) -> m (Cont r (Input -> r)))
  -> Transitions m r
  -> Transitions m r
addCloseK tagH mt k tran = \o a e t c d ->
  let
    closeK tagInspect mt' = if tagInspect == tagH && checkStackHead mt mt'
      then fmap (Nothing,) . k tagH
      else c tagH mt
  in tran o a e t closeK d

addCDATAK
  :: forall m r
  . Applicative m
  => ByteString
  -> Maybe TagState
  -> (Input -> Cont r (Input -> r) -> m (Cont r (Input -> r)))
  -> Transitions m r
  -> Transitions m r
addCDATAK cdata mt k tran = \o a e t c d ->
  let
    cdataK _ mt' = if checkStackHead mt mt'
      then fmap (Nothing,) . k cdata
      else d cdata mt
  in tran o a e t c cdataK
