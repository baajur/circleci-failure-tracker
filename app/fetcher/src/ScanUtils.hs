{-# LANGUAGE OverloadedStrings #-}

module ScanUtils where

import           Data.Maybe                (Maybe)
import qualified Data.Text                 as T
import           Data.Text.Encoding        (encodeUtf8)
import qualified Data.Text.Internal.Search as Search
import qualified Safe
import           System.FilePath
import           Text.Regex.Base
import           Text.Regex.PCRE           ((=~~))

import qualified Builds
import qualified DbHelpers
import qualified ScanPatterns
import           SillyMonoids              ()


apply_single_pattern ::
     (Int, T.Text)
  -> ScanPatterns.DbPattern
  -> Maybe ScanPatterns.ScanMatch
apply_single_pattern (line_number, line) db_pattern =
  match_partial <$> match_span
  where
    pattern_obj = DbHelpers.record db_pattern

    match_span = case ScanPatterns.expression pattern_obj of
      ScanPatterns.RegularExpression regex_text _ -> do
        (match_offset, match_length) <- ((T.unpack line) =~~ (encodeUtf8 regex_text) :: Maybe (MatchOffset, MatchLength))
        return $ ScanPatterns.NewMatchSpan match_offset (match_offset + match_length)
      ScanPatterns.LiteralExpression literal_text -> do
        first_index <- Safe.headMay (Search.indices literal_text line)
        return $ ScanPatterns.NewMatchSpan first_index (first_index + T.length literal_text)

    match_partial x = ScanPatterns.NewScanMatch db_pattern $
      ScanPatterns.NewMatchDetails
        line
        line_number
        x


gen_log_path :: FilePath -> Builds.BuildNumber -> FilePath
gen_log_path cache_dir (Builds.NewBuildNumber build_num) =
  cache_dir </> filename_stem <.> "log"
  where
    filename_stem = show build_num
