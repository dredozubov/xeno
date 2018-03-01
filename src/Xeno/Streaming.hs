{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

module Xeno.Streaming where

import           Control.Monad.Except
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import           Data.Monoid
import           Streaming
import qualified Streaming.Prelude as S
import           Xeno.SAX
import           Xeno.Types


data SaxEvent
  = OpenTag !ByteString
  | Attr !ByteString !ByteString
  | EndOfOpenTag !ByteString
  | Text !ByteString
  | CloseTag !ByteString
  | CDATA !ByteString
  deriving (Show, Eq, Ord)

-- data SaxEventTag
--   = OpenT
--   | AttrT
--   | EndOfOpenT
--   | TextT
--   | CloseT
--   | CDATAT
--   deriving (Show, Eq, Ord)

-- data SaxEventS :: SaxEventTag -> * where
--   OpenSax :: SaxEventS 'OpenT
--   AttrSax :: SaxEventS 'AttrT
--   EndOfOpenSax :: SaxEventS 'EndOfOpenT
--   TextSax :: SaxEventS 'TextT
--   CloseSax :: SaxEventS 'CloseT
--   CDATASax :: SaxEventS 'CDATAT

-- data SaxEvent :: Payload tag -> SaxEvent' tag -> * where


data ParserException
  = ParserError String
  | XenoError XenoException
  deriving Show

streamProcess
  :: forall m r
  .  Monad m
  => ByteString
  -> r
  -> Stream (Of SaxEvent) m r
streamProcess str r = do
  process
    (S.yield . OpenTag)
    (\a b -> S.yield $ Attr a b)
    (S.yield . EndOfOpenTag)
    (S.yield . Text)
    (S.yield . CloseTag)
    (S.yield . CDATA)
    str
  pure r

stream
  :: forall m
  .  MonadError ParserException m
  => ByteString
  -> Stream (Of SaxEvent) m ()
stream str = findLT 0
  where
    findLT :: Int -> Stream (Of SaxEvent) m ()
    findLT index =
      case elemIndexFrom openTagChar str index of
        Nothing -> do
          let text = BS.drop index str
          if BS.null text
          then pure ()
          else (yields $ Text text :> ())
        Just fromLt -> do
          let text = substring str index fromLt
          unless (BS.null text) (S.yield $ Text text)
          checkOpenComment (fromLt + 1)
    -- Find open comment, CDATA or tag name.
    checkOpenComment :: Int -> Stream (Of SaxEvent) m ()
    checkOpenComment index =
      if | s_index this 0 == bangChar -- !
           && s_index this 1 == commentChar -- -
           && s_index this 2 == commentChar -> -- -
           findCommentEnd (index + 3)
         | s_index this 0 == bangChar -- !
           && s_index this 1 == openAngleBracketChar -- [
           && s_index this 2 == 67 -- C
           && s_index this 3 == 68 -- D
           && s_index this 4 == 65 -- A
           && s_index this 5 == 84 -- T
           && s_index this 6 == 65 -- A
           && s_index this 7 == openAngleBracketChar -> -- [
           findCDataEnd (index + 8) (index + 8)
         | otherwise ->
           findTagName index
      where
        this = BS.drop index str
    findCommentEnd :: Int -> Stream (Of SaxEvent) m ()
    findCommentEnd index =
      case elemIndexFrom commentChar str index of
        Nothing -> throwError (XenoError $ XenoParseError "Couldn't find the closing comment dash.")
        Just fromDash ->
          if s_index this 0 == commentChar && s_index this 1 == closeTagChar
            then findLT (fromDash + 2)
            else findCommentEnd (fromDash + 1)
          where this = BS.drop index str
    findCDataEnd :: Int -> Int -> Stream (Of SaxEvent) m ()
    findCDataEnd cdata_start index =
      case elemIndexFrom closeAngleBracketChar str index of
        Nothing -> throwError (XenoError $ XenoParseError "Couldn't find closing angle bracket for CDATA.")
        Just fromCloseAngleBracket ->
          if s_index str (fromCloseAngleBracket + 1) == closeAngleBracketChar
             then do
               S.yield $ CDATA $ substring str cdata_start fromCloseAngleBracket
               findLT (fromCloseAngleBracket + 3) -- Start after ]]>
             else
               -- We only found one ], that means that we need to keep searching.
               findCDataEnd cdata_start (fromCloseAngleBracket + 1)
    findTagName :: Int -> Stream (Of SaxEvent) m ()
    findTagName index0 =
      let spaceOrCloseTag = parseName str index
      in if | s_index str index0 == questionChar ->
              case elemIndexFrom closeTagChar str spaceOrCloseTag of
                Nothing -> throwError (XenoError $ XenoParseError "Couldn't find the end of the tag.")
                Just fromGt -> findLT (fromGt + 1)
            | s_index str spaceOrCloseTag == closeTagChar ->
              do
                let tagname = substring str index spaceOrCloseTag
                if s_index str index0 == slashChar
                then S.yield $ CloseTag tagname
                else do
                  S.yield $ OpenTag tagname
                  S.yield $ EndOfOpenTag tagname
                findLT (spaceOrCloseTag + 1)
            | otherwise ->
              do let tagname = substring str index spaceOrCloseTag
                 S.yield $ OpenTag tagname
                 result <- findAttributes spaceOrCloseTag
                 S.yield $ EndOfOpenTag tagname
                 case result of
                   Right closingTag -> findLT (closingTag + 1)
                   Left closingPair -> do
                     S.yield $ CloseTag tagname
                     findLT (closingPair + 2)
      where
        index = if s_index str index0 == slashChar then index0 + 1 else index0
    findAttributes index0 =
      if s_index str index == slashChar &&
         s_index str (index + 1) == closeTagChar
        then pure (Left index)
        else if s_index str index == closeTagChar
               then pure (Right index)
               else let afterAttrName = parseName str index
                    in if s_index str afterAttrName == equalChar
                         then let quoteIndex = afterAttrName + 1
                                  usedChar = s_index str quoteIndex
                              in if usedChar == quoteChar ||
                                    usedChar == doubleQuoteChar
                                   then case elemIndexFrom
                                               usedChar
                                               str
                                               (quoteIndex + 1) of
                                          Nothing ->
                                            throwError (XenoError $ XenoParseError "Couldn't find the matching quote character.")
                                          Just endQuoteIndex -> do
                                            let
                                              aname = substring str index afterAttrName
                                              aval  = substring str
                                                (quoteIndex + 1)
                                                (endQuoteIndex)
                                            S.yield $ Attr aname aval
                                            findAttributes (endQuoteIndex + 1)
                                   else throwError (XenoError $ XenoParseError ("Expected ' or \", got: " <> BS.singleton usedChar))
                         else throwError (XenoError $ XenoParseError ("Expected =, got: " <> BS.singleton (s_index str afterAttrName) <> " at character index: " <> (BS8.pack . show) afterAttrName))
      where
        index = skipSpaces str index0
{-# INLINE stream #-}
