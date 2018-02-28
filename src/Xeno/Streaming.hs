{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

module Xeno.Streaming where

import           Control.Exception
import           Control.Monad.State.Strict
import           Control.Spork
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Unsafe as SU
import           Data.Functor.Identity
import           Data.Monoid
import           Data.Word
import           Streaming
import qualified Streaming.Prelude as S
import           Xeno.SAX
import           Xeno.Types


data SaxEvent
  = OpenTag !ByteString
  | Attribute !ByteString !ByteString
  | EndOfOpenTag !ByteString
  | Text !ByteString
  | CloseTag !ByteString
  | CDATA !ByteString
  deriving (Show, Eq)

stream
  :: forall m r
  .  Monad m
  => ByteString
  -> r
  -> Stream (Of SaxEvent) m (Either XenoException r)
stream str r = findLT 0
  where
    endStream = pure (pure r)
    findLT :: Int -> Stream (Of SaxEvent) m (Either XenoException r)
    findLT index =
      case elemIndexFrom openTagChar str index of
        Nothing -> do
          let text = BS.drop index str
          if BS.null text
          then endStream
          else (yields $ Text text :> Right r)
        Just fromLt -> do
          let text = substring str index fromLt
          unless (BS.null text) (S.yield $ Text text)
          checkOpenComment (fromLt + 1)
    -- Find open comment, CDATA or tag name.
    checkOpenComment :: Int -> Stream (Of SaxEvent) m (Either XenoException r)
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
    findCommentEnd :: Int -> Stream (Of SaxEvent) m (Either XenoException r)
    findCommentEnd index =
      case elemIndexFrom commentChar str index of
        Nothing -> throw (XenoParseError "Couldn't find the closing comment dash.")
        Just fromDash ->
          if s_index this 0 == commentChar && s_index this 1 == closeTagChar
            then findLT (fromDash + 2)
            else findCommentEnd (fromDash + 1)
          where this = BS.drop index str
    findCDataEnd :: Int -> Int -> Stream (Of SaxEvent) m (Either XenoException r)
    findCDataEnd cdata_start index =
      case elemIndexFrom closeAngleBracketChar str index of
        Nothing -> throw (XenoParseError "Couldn't find closing angle bracket for CDATA.")
        Just fromCloseAngleBracket ->
          if s_index str (fromCloseAngleBracket + 1) == closeAngleBracketChar
             then do
               cdataF (substring str cdata_start fromCloseAngleBracket)
               findLT (fromCloseAngleBracket + 3) -- Start after ]]>
             else
               -- We only found one ], that means that we need to keep searching.
               findCDataEnd cdata_start (fromCloseAngleBracket + 1)
    findTagName index0 =
      let spaceOrCloseTag = parseName str index
      in if | s_index str index0 == questionChar ->
              case elemIndexFrom closeTagChar str spaceOrCloseTag of
                Nothing -> throw (XenoParseError "Couldn't find the end of the tag.")
                Just fromGt -> do
                  findLT (fromGt + 1)
            | s_index str spaceOrCloseTag == closeTagChar ->
              do let tagname = substring str index spaceOrCloseTag
                 if s_index str index0 == slashChar
                   then closeF tagname
                   else do
                     openF tagname
                     endOpenF tagname
                 findLT (spaceOrCloseTag + 1)
            | otherwise ->
              do let tagname = substring str index spaceOrCloseTag
                 openF tagname
                 result <- findAttributes spaceOrCloseTag
                 endOpenF tagname
                 case result of
                   Right closingTag -> findLT (closingTag + 1)
                   Left closingPair -> do
                     closeF tagname
                     findLT (closingPair + 2)
      where
        index =
          if s_index str index0 == slashChar
            then index0 + 1
            else index0
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
                                            throw (XenoParseError "Couldn't find the matching quote character.")
                                          Just endQuoteIndex -> do
                                            attrF
                                              (substring str index afterAttrName)
                                              (substring
                                                 str
                                                 (quoteIndex + 1)
                                                 (endQuoteIndex))
                                            findAttributes (endQuoteIndex + 1)
                                   else throw (XenoParseError ("Expected ' or \", got: " <> BS.singleton usedChar))
                         else throw (XenoParseError ("Expected =, got: " <> BS.singleton (s_index str afterAttrName) <> " at character index: " <> (BS8.pack . show) afterAttrName))
      where
        index = skipSpaces str index0
{-# INLINE stream #-}
