{-# LANGUAGE TupleSections, TypeApplications, ScopedTypeVariables #-}
module Main (main) where

import Feynman.Core (Primitive(CNOT, T, Tinv), ID)
import Feynman.Frontend
import Feynman.Frontend.DotQC
import Feynman.Optimization.PhaseFold
import Feynman.Optimization.TPar
import Feynman.Verification.SOP

import System.Environment

import Data.List

import Data.Set (Set)
import qualified Data.Set as Set

import Data.Map (Map)
import qualified Data.Map as Map

import Control.Monad
import System.Time
import Control.DeepSeq

import Data.ByteString (ByteString)
import qualified Data.ByteString as B

import Benchmarks

{- Toolkit passes -}

type Pass a = a -> Either String a

trivPass :: Frontend a => Pass a
trivPass = Right

inlinePass :: Frontend a => Pass a
inlinePass = Right . inline

mctPass :: Frontend a => Pass a
mctPass = Right . decomposeMCT

ctPass :: Frontend a => Pass a
ctPass = Right . decomposeAll

phasefoldPass :: Frontend a => Pass a
phasefoldPass = optimize phaseFold

tparPass :: Frontend a => Pass a
tparPass = optimize tpar

cnotminPass :: Frontend a => Pass a
cnotminPass = optimize minCNOT

simplifyPass :: Frontend a => Pass a
simplifyPass = Right . simplify

verifyPass :: Frontend a => a -> Pass a
verifyPass circ =
  let gatelist      = sequentialize circ
      primaryInputs = parameters circ
      go circ' =
        let gatelist' = sequentialize circ'
            result    = validate Set.empty primaryInputs gatelist gatelist'
        in
          case (primaryInputs == parameters circ', result) of
            (False, _)    -> Left $ "Failed to verify: circuits have different inputs"
            (_, Just sop) -> Left $ "Failed to verify: miter circuit maps " ++ show sop
            _             -> Right circ'
  in
    go

{- Main program -}

run :: Frontend a => Pass a -> Bool -> String -> ByteString -> IO ()
run (pass :: Pass a) verify fname src = do
  TOD starts startp <- getClockTime
  TOD ends endp     <- parseAndPass `seq` getClockTime
  case parseAndPass of
    Left err        -> putStrLn $ "ERROR: " ++ err
    Right (circ, circ') -> do
      let time = (fromIntegral $ ends - starts) * 1000 + (fromIntegral $ endp - startp) / 10^9
      let cmt  = commentPrefix @a
      putStrLn $ cmt ++ " Feynman -- quantum circuit toolkit"
      putStrLn $ cmt ++ " Original (" ++ fname ++ "):"
      mapM_ putStrLn . map ((cmt ++ "   ") ++) $ statistics circ
      putStrLn $ cmt ++ " Result (" ++ formatFloatN time 3 ++ "ms):"
      mapM_ putStrLn . map ((cmt ++ "   ") ++) $ statistics circ'
      putStrLn $ show circ'
  where printErr (Left l)  = Left $ show l
        printErr (Right r) = Right r
        parseAndPass = do
          circ  <- printErr $ parse src
          circ' <- pass qc
          seq (length $ sequentialize circ') (return ()) -- Nasty solution to strictifying
          when verify . void $ verifyPass circ circ'
          return (circ, circ')

printHelp :: IO ()
printHelp = mapM_ putStrLn lines
  where lines = [
          "Feynman -- quantum circuit toolkit",
          "Written by Matthew Amy",
          "",
          "Run with feyn [passes] (<circuit>.qc | Small | Med | All)",
          "",
          "Transformation passes:",
          "  -inline\tInline all sub-circuits",
          "  -mctExpand\tExpand all MCT gates using |0>-initialized ancillas",
          "  -toCliffordT\tExpand all gates to Clifford+T gates",
          "",
          "Optimization passes:",
          "  -simplify\tBasic gate-cancellation pass",
          "  -phasefold\tMerges phase gates according to the circuit's phase polynomial",
          "  -tpar\t\tPhase folding + T-parallelization algorithm from [AMM14]",
          "  -cnotmin\tPhase folding + CNOT-minimization algorithm from [AAM17]",
          "  -O2\t\t**Standard strategy** Phase folding + simplify",
          "",
          "Verification passes:",
          "  -verify\tPerform verification algorithm of [A18] after all passes",
          "",
          "E.g. \"feyn -verify -inline -cnotmin -simplify circuit.qc\" will first inline the circuit,",
          "       then optimize CNOTs, followed by a gate cancellation pass and finally verify the result",
          "",
          "WARNING: Using \"-verify\" with \"All\" may crash your computer without first setting",
          "         user-level memory limits. Use with caution"
          ]
          

parseArgs :: Frontend a => Pass a -> Bool -> [String] -> IO ()
parseArgs pass verify []     = printHelp
parseArgs pass verify (x:xs) = case x of
  "-h"           -> printHelp
  "-inline"      -> parseArgs (pass >=> inlinePass) verify xs
  "-mctExpand"   -> parseArgs (pass >=> mctPass) verify xs
  "-toCliffordT" -> parseArgs (pass >=> ctPass) verify xs
  "-simplify"    -> parseArgs (pass >=> simplifyPass) verify xs
  "-phasefold"   -> parseArgs (pass >=> simplifyPass >=> phasefoldPass) verify xs
  "-cnotmin"     -> parseArgs (pass >=> simplifyPass >=> cnotminPass) verify xs
  "-tpar"        -> parseArgs (pass >=> simplifyPass >=> tparPass) verify xs
  "-O2"          -> parseArgs (pass >=> simplifyPass >=> phasefoldPass >=> simplifyPass) verify xs
  "-verify"      -> parseArgs pass True xs
  "VerBench"     -> runBenchmarks cnotminPass (Just equivalenceCheck) benchmarksMedium
  "VerAlg"       -> runVerSuite
  "Small"        -> runBenchmarks pass (if verify then Just equivalenceCheck else Nothing) benchmarksSmall
  "Med"          -> runBenchmarks pass (if verify then Just equivalenceCheck else Nothing) benchmarksMedium
  "All"          -> runBenchmarks pass (if verify then Just equivalenceCheck else Nothing) benchmarksAll
  f | (drop (length f - 3) f) == ".qc" -> B.readFile f >>= (run @ DotQC) pass verify f
  f | otherwise -> putStrLn ("Unrecognized option \"" ++ f ++ "\"") >> printHelp

main :: IO ()
main = getArgs >>= parseArgs trivPass False
