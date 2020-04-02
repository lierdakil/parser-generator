{-# LANGUAGE TupleSections, FlexibleContexts #-}
module Lexer (makeDFA, writeLexer, Lang(..)) where

import qualified Data.Map as M
import qualified Data.Set as S
import Control.Monad.State
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.List
import Data.Maybe
import Control.Arrow
import RegexParse
import RegexLex (alexMonadScan, runAlex, Token(..))
import Grammar (Symbol(..))
import FA
import MonadTypes

newState :: State Int Int
newState = state $ \s -> (s+1, s+1)

nonAcc :: M.Map (Maybe (NonEmpty CharPattern)) [Int]
       -> (StateAttr, M.Map (Maybe (NonEmpty CharPattern)) [Int])
nonAcc = (,) S.empty

regex1ToNFASt :: RegexPatternSingle -> State Int NFA
regex1ToNFASt (PGroup ch) = do
  startSt <- get
  endSt <- newState
  return $ IM.singleton startSt (nonAcc $ M.singleton (Just ch) [endSt])
regex1ToNFASt (PMaybe pat) = do
  startSt <- get
  patNfa <- regexToNFASt pat
  endSt <- get
  return $ IM.insertWith mapUnion startSt (nonAcc $ M.singleton Nothing [endSt]) patNfa
regex1ToNFASt (PKleene pat) = do
  startSt <- get
  loopStartSt <- newState
  patNfa <- regexToNFASt pat
  loopEndSt <- get
  endSt <- newState
  return $ IM.insertWith mapUnion startSt (nonAcc $ M.singleton Nothing [endSt, loopStartSt])
         $ IM.insertWith mapUnion loopEndSt (nonAcc $ M.singleton Nothing [loopStartSt, endSt])
           patNfa
regex1ToNFASt (PPositive pat) = do
  startSt <- get
  patNfa <- regexToNFASt pat
  endSt <- get
  return $ IM.insertWith mapUnion endSt (nonAcc $ M.singleton Nothing [startSt]) patNfa
regex1ToNFASt (PAlternative pats) = altNFA True $ map regexToNFASt pats

altNFA :: Bool -> [State Int NFA] -> State Int NFA
altNFA mkEndNode mnfas = do
  startSt <- get
  nfas <- forM mnfas $ \mnfa -> do
    start <- newState
    nfa <- mnfa
    end <- get
    return ((start, end), nfa)
  endSt <- if mkEndNode then Just <$> newState else return Nothing
  let starts = map (fst . fst) nfas
      ends = map (snd . fst) nfas
      nfas' = map snd nfas
      endsmap = case endSt of
        Just x -> (IM.fromList (map (, nonAcc $ M.singleton Nothing [x]) ends) :)
        Nothing -> id
  return $ IM.insertWith mapUnion startSt (nonAcc $ M.singleton Nothing starts)
         $ IM.unionsWith mapUnion (endsmap nfas')

mapUnion :: Ord k =>
            (StateAttr, M.Map k [a2])
            -> (StateAttr, M.Map k [a2])
            -> (StateAttr, M.Map k [a2])
mapUnion (a, x) (b, y) = (a <> b, M.unionWith (++) x y)

regexToNFASt :: RegexPattern -> State Int NFA
regexToNFASt = foldr
  (\p -> (IM.unionWith mapUnion <$> regex1ToNFASt p <*>))
  (return IM.empty)

regexToNFA :: (Maybe String, Action) -> RegexPattern -> State Int NFA
regexToNFA (name, action) pat = do
  res1 <- regexToNFASt pat
  lastSt <- get
  return $ IM.insertWith mapUnion lastSt (S.singleton (name, action), M.empty) res1

build1NFA :: RegexDef -> State Int NFA
build1NFA (RegexDef mbname pat mbact) = regexToNFA (mbname, mbact) pat
-- build1DFA = fmap (simplifyDFA . nfaToDFA . regexToNFA . regex) . scan

buildNFA :: [RegexDef] -> State Int NFA
buildNFA [x] = build1NFA x
buildNFA xs = altNFA False $ map build1NFA xs

scanLine :: String -> Either String [Token]
scanLine s = runAlex s go
  where
  go = do
    tok <- alexMonadScan
    (tok :) <$> if tok /= TEOF
                then go
                else return []

data Lang = CPP

makeDFA :: Monad m => [String] -> MyMonadT m ([(FilePath, String)], DFA)
makeDFA input = do
  defs <- liftEither . left lines $ mapM (fmap regex . scanLine) input
  let nfa = evalState (buildNFA defs) 0
      dfa = simplifyDFA . nfaToDFA $ nfa
      debug = [("nfa.gv", nfaToGraphviz nfa), ("dfa.gv", dfaToGraphviz dfa)]
  return (debug, dfa)

writeLexer :: Monad m => DFA -> Lang -> MyMonadT m ([Symbol], [(FilePath, String)])
writeLexer dfa CPP = do
  accSt <- catMaybes <$> mapM (\(f, (s, _)) -> fmap (f,) <$> isSingle f s) stList
  let accStS = IS.fromList $ map fst accSt
      checkAccepting st
        | st `IS.member` accStS
        = "lastAccChIx = curChIx; accSt = "<>show st <>";"
        | otherwise = ""
      tokNames = nub $ mapMaybe (fst . snd) accSt
      returnResult = concat (foldr ((:) . returnResult1) [] accSt)
      terminals = TermEof : map Term tokNames
      tokReflect = intercalate "," . map (\x -> '"':x <> "\"") $ "%eof":tokNames
      checkState (curSt, (_, charTrans)) = "state_" <> show curSt <> ":"
        <> checkAccepting curSt
        <> "if(curChIx == endIx) goto end;"
        <> "curCh = *curChIx; ++curChIx;"
        <> intercalate " else " (foldr ((:) . checkChars) [] charTrans)
        <> "goto end;"
      transTable = concatMap checkState stList
  return $ (,) terminals [
      ( "tokenType.h"
      , "#ifndef TOKEN_TYPE_H\n#define TOKEN_TYPE_H\n"
        <> "enum class TokenType : std::size_t { eof, "
        <> intercalate "," (map ("Tok_"<>) tokNames)
        <> "};"
        <> "\n#endif\n"
      )
    , ("lexer.h", "\
\#ifndef LEXER_H\n\
\#define LEXER_H\n\
\#include <string>\n\
\#include \"tokenType.h\"\n\
\const std::string to_string(TokenType tt);\n\
\#if __has_include(\"token.h\")\n\
\#include \"token.h\"\n\
\#else\n\
\struct Token{TokenType type; std::string text;};\
\Token mkToken(TokenType type, const std::string_view &text = \"\");\n\
\#endif\n\
\class Lexer {\
  \const std::string _input;\
  \const std::string_view input;\
  \std::string::const_iterator curChIx;\
  \std::string::const_iterator endIx;\
  \const bool debug;\
\public:\
  \Lexer(const std::string &input, bool debug);\
  \Token getNextToken();\
\};\n\
\#endif\n")
    , ("lexer.cpp", "\
\#include \"lexer.h\"\n\
\#include <stdexcept>\n\
\#include <iostream>\n\
\const std::string to_string(TokenType tt){\
\static constexpr const char *names[] = {" <> tokReflect <> " };\
\return names[static_cast<std::size_t>(tt)];\
\}\n\
\#if __has_include(\"token.h\")\n\
\#else\n\
\Token mkToken(TokenType type, const std::string_view &text) {\
  \return Token{type, std::string(text)};\
\}\n\
\#endif\n\
\Lexer::Lexer(const std::string &input, bool debug=false) \
\: _input(input), input(_input), curChIx(input.cbegin()), endIx(input.cend()), debug(debug) {}\
\Token Lexer::getNextToken() {\
  \start:\
  \auto lastAccChIx = curChIx;\
  \auto startChIx = curChIx;\
  \char curCh;\
  \int accSt = -1;\
  \"<> transTable <> "\
  \end:\
  \auto lastReadChIx = curChIx;\
  \curChIx = lastAccChIx;\
  \std::string_view text(&*startChIx, std::distance(startChIx, curChIx));\
  \switch(accSt){\
  \" <> returnResult <> "\
  \}\
  \if (curChIx == endIx) { \
  \if (debug) std::cerr << \"Got EOF while lexing \\\"\" << text << \"\\\"\" << std::endl; \
  \return mkToken(TokenType::eof); }\
  \throw std::runtime_error(\"Unexpected input: \" + std::string(startChIx, lastReadChIx));\
\}\
\")
    ]
  where
  returnResult1 (st, (Just name, act))
    = "case "<> show st <>":\
      \if (debug) std::cerr << \"Lexed token " <> name <> ": \\\"\" << text << \"\\\"\" << std::endl; \
      \return mkToken(TokenType::Tok_" <> name <> mkAct act <>");"
  returnResult1 (st, (Nothing, _))
    = "case "<> show st <>":\
      \if (debug) std::cerr << \"Skipping state " <> show st <> ": \\\"\" << text << \"\\\"\" << std::endl; \
      \goto start;"
  mkAct NoAction = ""
  mkAct (Action act) = "," <> act
  isSingle f xs
    | S.null xs = return Nothing
    | S.size xs == 1 = return $ Just (S.findMin xs)
    | otherwise = do
        tell ["Lexer: Multiple actions/tokens match the same state " <> show f <> ": " <> show xs <> ". Choosing the first option."]
        return (Just $ S.findMin xs)
  checkChars (charGroup, newSt) = "if(" <> charCond charGroup <> ") goto state_" <> show newSt <> ";"
  charCond = intercalate "||" . map charCond1 . NE.toList
  charCond1 (CChar c) = "curCh == " <> show c
  charCond1 (CRange c1 c2) = "(curCh >= " <> show c1 <> " && curCh <= " <> show c2 <> ")"
  charCond1 CAny = "true"
  stList = map (second (second M.toList)) $ IM.toList dfa
