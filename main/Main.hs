{- © 2019 Serokell <hi@serokell.io>
 - © 2019 Lars Jellema <lars.jellema@gmail.com>
 -
 - SPDX-License-Identifier: MPL-2.0
 -}

{-# LANGUAGE DeriveDataTypeable #-}

module Main where

import Control.Concurrent (Chan, forkIO, newChan, readChan, writeChan)
import Data.Bifunctor (first)
import Data.Either (lefts)
import Data.Text (Text)
import GHC.IO.Encoding (utf8)
import System.Console.CmdArgs
  (Data, Typeable, args, cmdArgs, help, summary, typ, (&=))
import System.Exit (ExitCode(..), exitFailure, exitSuccess)
import System.IO (hPutStr, hSetEncoding, stderr)
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (Handler(..), installHandler, keyboardSignal)

import qualified Data.Text.IO as TextIO (getContents, hPutStr, putStr)

import Nixfmt
import System.IO.Atomic (withOutputFile)
import System.IO.Utf8 (readFileUtf8, withUtf8StdHandles)

type Result = Either String ()

data Nixfmt = Nixfmt
    { files :: [FilePath]
    , width :: Int
    , check :: Bool
    , quiet :: Bool
    } deriving (Show, Data, Typeable)

options :: Nixfmt
options = Nixfmt
    { files = [] &= args &= typ "FILES"
    , width = 80 &= help "Maximum width in characters"
    , check = False &= help "Check whether files are formatted"
    , quiet = False &= help "Do not report errors"
    } &= summary "Format Nix source code"

format' :: Int -> FilePath -> Text -> Either String Text
format' w path = first errorBundlePretty . format w path

data Target = Target (IO Text) FilePath (Text -> IO ())

formatTarget :: Int -> Target -> IO Result
formatTarget w (Target doRead path doWrite)
    = doRead >>= mapM doWrite . format' w path

-- | Return an error if target could not be parsed or was not formatted
-- correctly.
checkTarget :: Int -> Target -> IO Result
checkTarget w (Target doRead path _) = do
    contents <- doRead
    return $ case format' w path contents of
        Left err -> Left err
        Right formatted
            | formatted == contents -> Right ()
            | otherwise             -> Left $ path ++ ":\nnot formatted"

stdioTarget :: Target
stdioTarget = Target TextIO.getContents "<stdin>" TextIO.putStr

fileTarget :: FilePath -> Target
fileTarget path = Target (readFileUtf8 path) path atomicWriteFile
  where
    atomicWriteFile t = withOutputFile path $ \h -> do
      hSetEncoding h utf8
      TextIO.hPutStr h t

toTargets :: Nixfmt -> [Target]
toTargets Nixfmt{ files = [] }    = [stdioTarget]
toTargets Nixfmt{ files = paths } = map fileTarget paths

toOperation :: Nixfmt -> Target -> IO Result
toOperation Nixfmt{ width = w, check = True } = checkTarget w
toOperation Nixfmt{ width = w } = formatTarget w

toWriteError :: Nixfmt -> String -> IO ()
toWriteError Nixfmt{ quiet = False } = hPutStr stderr
toWriteError Nixfmt{ quiet = True } = const $ return ()

toJobs :: Nixfmt -> [IO Result]
toJobs opts = map (toOperation opts) $ toTargets opts

-- TODO: Efficient parallel implementation. This is just a sequential stub.
-- This was originally implemented using parallel-io, but it gave a factor two
-- overhead.
doParallel :: [IO a] -> IO [a]
doParallel = sequence

errorWriter :: (String -> IO ()) -> Chan (Maybe String) -> Chan () -> IO ()
errorWriter doWrite chan done = do
    item <- readChan chan
    case item of
         Nothing  -> return ()
         Just msg -> doWrite msg >> errorWriter doWrite chan done
    writeChan done ()

writeErrorBundle :: Chan (Maybe String) -> Result -> IO Result
writeErrorBundle chan result = do
    case result of
         Right () -> return ()
         Left err -> writeChan chan $ Just err
    return result

-- | Run a list of jobs and write errors to stderr without interleaving them.
runJobs :: (String -> IO ()) -> [IO Result] -> IO [Result]
runJobs writeError jobs = do
    errChan <- newChan
    doneChan <- newChan
    _ <- forkIO $ errorWriter writeError errChan doneChan
    results <- doParallel $ map (>>= writeErrorBundle errChan) jobs
    writeChan errChan Nothing
    _ <- readChan doneChan
    return results

main :: IO ()
main = withUtf8StdHandles $ do
    _ <- installHandler keyboardSignal
            (Catch (exitImmediately $ ExitFailure 2)) Nothing
    opts <- cmdArgs options
    results <- runJobs (toWriteError opts) (toJobs opts)
    case lefts results of
         [] -> exitSuccess
         _  -> exitFailure
