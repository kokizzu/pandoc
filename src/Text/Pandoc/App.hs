{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE ScopedTypeVariables #-}
{- |
   Module      : Text.Pandoc.App
   Copyright   : Copyright (C) 2006-2021 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley@edu>
   Stability   : alpha
   Portability : portable

Does a pandoc conversion based on command-line options.
-}
module Text.Pandoc.App (
            convertWithOpts
          , Opt(..)
          , LineEnding(..)
          , Filter(..)
          , defaultOpts
          , parseOptions
          , parseOptionsFromArgs
          , options
          , applyFilters
          ) where
import qualified Control.Exception as E
import Control.Monad ( (>=>), when )
import Control.Monad.Trans ( MonadIO(..) )
import Control.Monad.Except (throwError)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import Data.Char (toLower)
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import qualified Data.Text.Encoding.Error as TSE
import Network.URI (URI (..), parseURI)
import System.Directory (doesDirectoryExist)
import System.Exit (exitSuccess)
import System.FilePath ( takeBaseName, takeExtension )
import System.IO (nativeNewline, stdout)
import qualified System.IO as IO (Newline (..))
import Text.Pandoc
import Text.Pandoc.Builder (setMeta)
import Text.Pandoc.MIME (getCharset)
import Text.Pandoc.App.FormatHeuristics (formatFromFilePaths)
import Text.Pandoc.App.Opt (Opt (..), LineEnding (..), defaultOpts,
                            IpynbOutput (..))
import Text.Pandoc.App.CommandLineOptions (parseOptions, parseOptionsFromArgs,
                                           options)
import Text.Pandoc.App.OutputSettings (OutputSettings (..), optToOutputSettings)
import Text.Collate.Lang (Lang (..), parseLang)
import Text.Pandoc.Filter (Filter (JSONFilter, LuaFilter), applyFilters)
import Text.Pandoc.PDF (makePDF)
import Text.Pandoc.SelfContained (makeSelfContained)
import Text.Pandoc.Shared (eastAsianLineBreakFilter, stripEmptyParagraphs,
         headerShift, isURI, tabFilter, uriPathToPath, filterIpynbOutput,
         defaultUserDataDir, tshow)
import Text.Pandoc.Writers.Shared (lookupMetaString)
import Text.Pandoc.Readers.Markdown (yamlToMeta)
import qualified Text.Pandoc.UTF8 as UTF8
#ifndef _WINDOWS
import System.Posix.IO (stdOutput)
import System.Posix.Terminal (queryTerminal)
#endif

convertWithOpts :: Opt -> IO ()
convertWithOpts opts = do
  datadir <- case optDataDir opts of
                  Nothing   -> do
                    d <- defaultUserDataDir
                    exists <- doesDirectoryExist d
                    return $ if exists
                                then Just d
                                else Nothing
                  Just _    -> return $ optDataDir opts

  let outputFile = fromMaybe "-" (optOutputFile opts)
  let filters = optFilters opts
  let verbosity = optVerbosity opts

  when (optDumpArgs opts) $
    do UTF8.hPutStrLn stdout (T.pack outputFile)
       mapM_ (UTF8.hPutStrLn stdout . T.pack)
             (fromMaybe ["-"] $ optInputFiles opts)
       exitSuccess

  let sources = case optInputFiles opts of
                     Just xs | not (optIgnoreArgs opts) -> xs
                     _ -> ["-"]

  let runIO' :: PandocIO a -> IO a
      runIO' f = do
        (res, reports) <- runIOorExplode $ do
                             setTrace (optTrace opts)
                             setVerbosity verbosity
                             x <- f
                             rs <- getLog
                             return (x, rs)
        case optLogFile opts of
             Nothing      -> return ()
             Just logfile -> BL.writeFile logfile (encodeLogMessages reports)
        let isWarning msg = messageVerbosity msg == WARNING
        when (optFailIfWarnings opts && any isWarning reports) $
            E.throwIO PandocFailOnWarningError
        return res

  let eol = case optEol opts of
                 CRLF   -> IO.CRLF
                 LF     -> IO.LF
                 Native -> nativeNewline
#ifdef _WINDOWS
  let istty = True
#else
  istty <- liftIO $ queryTerminal stdOutput
#endif

  runIO' $ do
    setUserDataDir datadir
    setResourcePath (optResourcePath opts)

    setInputFiles (fromMaybe ["-"] (optInputFiles opts))
    setOutputFile (optOutputFile opts)

    -- assign reader and writer based on options and filenames
    readerName <- case optFrom opts of
                       Just f  -> return f
                       Nothing -> case formatFromFilePaths sources of
                           Just f' -> return f'
                           Nothing | sources == ["-"] -> return "markdown"
                                   | any (isURI . T.pack) sources -> return "html"
                                   | otherwise -> do
                             report $ CouldNotDeduceFormat
                                 (map (T.pack . takeExtension) sources) "markdown"
                             return "markdown"

    let readerNameBase = T.takeWhile (\c -> c /= '+' && c /= '-') readerName
    let pdfOutput = map toLower (takeExtension outputFile) == ".pdf"

    when (pdfOutput && readerNameBase == "latex") $
      case optInputFiles opts of
        Just (inputFile:_) -> report $ UnusualConversion $ T.pack $
          "to convert a .tex file to PDF, you get better results by using pdflatex "
            <> "(or lualatex or xelatex) directly, try `pdflatex " <> inputFile
            <> "` instead of `pandoc " <> inputFile <> " -o " <> outputFile <> "`."
        _ -> return ()

    (reader :: Reader PandocIO, readerExts) <- getReader readerName

    let convertTabs = tabFilter (if optPreserveTabs opts ||
                                      readerNameBase == "t2t" ||
                                      readerNameBase == "man"
                                    then 0
                                    else optTabStop opts)


    let readSources :: [FilePath] -> PandocIO Text
        readSources srcs = convertTabs . T.intercalate (T.pack "\n") <$>
                              mapM readSource srcs


    outputSettings <- optToOutputSettings opts
    let format = outputFormat outputSettings
    let writer = outputWriter outputSettings
    let writerName = outputWriterName outputSettings
    let writerNameBase = T.takeWhile (\c -> c /= '+' && c /= '-') writerName
    let writerOptions = outputWriterOptions outputSettings

    let bibOutput = writerNameBase == "bibtex" ||
                    writerNameBase == "biblatex" ||
                    writerNameBase == "csljson"

    let standalone = optStandalone opts ||
                     not (isTextFormat format) ||
                     pdfOutput ||
                     bibOutput

    -- We don't want to send output to the terminal if the user
    -- does 'pandoc -t docx input.txt'; though we allow them to
    -- force this with '-o -'.  On posix systems, we detect
    -- when stdout is being piped and allow output to stdout
    -- in that case, but on Windows we can't.
    when ((pdfOutput || not (isTextFormat format)) &&
             istty && isNothing ( optOutputFile opts)) $
      throwError $ PandocAppError $
              "Cannot write " <> format <> " output to terminal.\n" <>
              "Specify an output file using the -o option, or " <>
              "use '-o -' to force output to stdout."


    abbrevs <- Set.fromList . filter (not . T.null) . T.lines . UTF8.toText <$>
               case optAbbreviations opts of
                    Nothing -> readDataFile "abbreviations"
                    Just f  -> readFileStrict f

    case lookupMetaString "lang" (optMetadata opts) of
           ""      -> setTranslations $ Lang "en" Nothing (Just "US") [] [] []
           l       -> case parseLang l of
                           Left _   -> report $ InvalidLang l
                           Right l' -> setTranslations l'

    let readerOpts = def{
            readerStandalone = standalone
          , readerColumns = optColumns opts
          , readerTabStop = optTabStop opts
          , readerIndentedCodeClasses = optIndentedCodeClasses opts
          , readerDefaultImageExtension =
             optDefaultImageExtension opts
          , readerTrackChanges = optTrackChanges opts
          , readerAbbreviations = abbrevs
          , readerExtensions = readerExts
          , readerStripComments = optStripComments opts
          }

    metadataFromFile <-
      case optMetadataFiles opts of
        []    -> return mempty
        paths -> mconcat <$>
           mapM (\path -> do raw <- readFileLazy path
                             yamlToMeta readerOpts (Just path) raw) paths

    let transforms = (case optShiftHeadingLevelBy opts of
                          0             -> id
                          x             -> (headerShift x :)) .
                     (if optStripEmptyParagraphs opts
                         then (stripEmptyParagraphs :)
                         else id) .
                     (if extensionEnabled Ext_east_asian_line_breaks
                            readerExts &&
                         not (extensionEnabled Ext_east_asian_line_breaks
                              (writerExtensions writerOptions) &&
                              writerWrapText writerOptions == WrapPreserve)
                         then (eastAsianLineBreakFilter :)
                         else id) .
                     (case optIpynbOutput opts of
                       _ | readerNameBase /= "ipynb" -> id
                       IpynbOutputAll  -> id
                       IpynbOutputNone -> (filterIpynbOutput Nothing :)
                       IpynbOutputBest -> (filterIpynbOutput (Just $
                                     if htmlFormat format
                                        then Format "html"
                                        else
                                          case format of
                                            "latex"  -> Format "latex"
                                            "beamer" -> Format "latex"
                                            _        -> Format format) :))
                     $ []

    let sourceToDoc :: [FilePath] -> PandocIO Pandoc
        sourceToDoc sources' =
           case reader of
                TextReader r
                  | optFileScope opts || readerNameBase == "json" ->
                      mconcat <$> mapM (readSource >=> r readerOpts) sources'
                  | otherwise ->
                      readSources sources' >>= r readerOpts
                ByteStringReader r ->
                  mconcat <$> mapM (readFile' >=> r readerOpts) sources'


    when (readerNameBase == "markdown_github" ||
          writerNameBase == "markdown_github") $
      report $ Deprecated "markdown_github" "Use gfm instead."

    mapM_ (uncurry setRequestHeader) (optRequestHeaders opts)

    setNoCheckCertificate (optNoCheckCertificate opts)

    let isPandocCiteproc (JSONFilter f) = takeBaseName f == "pandoc-citeproc"
        isPandocCiteproc _              = False

    when (any isPandocCiteproc filters) $
      report $ Deprecated "pandoc-citeproc filter"
               "Use --citeproc instead."

    let cslMetadata =
          maybe id (setMeta "csl") (optCSL opts) .
          (case optBibliography opts of
             [] -> id
             xs -> setMeta "bibliography" xs) .
          maybe id (setMeta "citation-abbreviations")
                         (optCitationAbbreviations opts) $ mempty

    doc <- sourceToDoc sources >>=
              (   (if isJust (optExtractMedia opts)
                      then fillMediaBag
                      else return)
              >=> return . adjustMetadata (metadataFromFile <>)
              >=> return . adjustMetadata (<> optMetadata opts)
              >=> return . adjustMetadata (<> cslMetadata)
              >=> applyTransforms transforms
              >=> applyFilters readerOpts filters [T.unpack format]
              >=> maybe return extractMedia (optExtractMedia opts)
              )

    case writer of
      ByteStringWriter f -> f writerOptions doc >>= writeFnBinary outputFile
      TextWriter f -> case outputPdfProgram outputSettings of
        Just pdfProg -> do
                res <- makePDF pdfProg (optPdfEngineOpts opts) f
                        writerOptions doc
                case res of
                     Right pdf -> writeFnBinary outputFile pdf
                     Left err' -> throwError $ PandocPDFError $
                                     TL.toStrict (TE.decodeUtf8With TE.lenientDecode err')

        Nothing -> do
                let ensureNl t
                      | standalone = t
                      | T.null t || T.last t /= '\n' = t <> T.singleton '\n'
                      | otherwise = t
                output <- ensureNl <$> f writerOptions doc
                writerFn eol outputFile =<<
                  if optSelfContained opts && htmlFormat format
                     then makeSelfContained output
                     else return output

type Transform = Pandoc -> Pandoc

htmlFormat :: Text -> Bool
htmlFormat = (`elem` ["html","html4","html5","s5","slidy",
                      "slideous","dzslides","revealjs"])

isTextFormat :: Text -> Bool
isTextFormat s = s `notElem` ["odt","docx","epub2","epub3","epub","pptx"]

adjustMetadata :: (Meta -> Meta) -> Pandoc -> Pandoc
adjustMetadata f (Pandoc meta bs) = Pandoc (f meta) bs

-- Transformations of a Pandoc document post-parsing:

applyTransforms :: Monad m => [Transform] -> Pandoc -> m Pandoc
applyTransforms transforms d = return $ foldr ($) d transforms

readSource :: FilePath -> PandocIO Text
readSource src = case parseURI src of
                      Just u | uriScheme u `elem` ["http:","https:"] ->
                                 readURI src
                             | uriScheme u == "file:" -> liftIO $
                                 readTextFile (uriPathToPath $ T.pack $ uriPath u)
                      _       -> liftIO $ readTextFile src
  where readTextFile :: FilePath -> IO Text
        readTextFile fp = do
          bs <- if src == "-"
                   then BS.getContents
                   else BS.readFile fp
          E.catch (return $! UTF8.toText bs)
             (\e -> E.throwIO $ case e of
                         TSE.DecodeError _ (Just w) ->
                           case BS.elemIndex w bs of
                             Just offset ->
                                  PandocUTF8DecodingError (T.pack fp) offset w
                             _ -> PandocUTF8DecodingError (T.pack fp) 0 w
                         _ -> PandocAppError (tshow e))

readURI :: FilePath -> PandocIO Text
readURI src = do
  (bs, mt) <- openURL (T.pack src)
  case mt >>= getCharset of
    Just "UTF-8"      -> return $ UTF8.toText bs
    Just "ISO-8859-1" -> return $ T.pack $ B8.unpack bs
    Just charset      -> throwError $ PandocUnsupportedCharsetError charset
    Nothing           -> liftIO $ -- try first as UTF-8, then as latin1
                          E.catch (return $! UTF8.toText bs)
                                  (\case
                                      TSE.DecodeError{} ->
                                        return $ T.pack $ B8.unpack bs
                                      e -> E.throwIO e)

readFile' :: MonadIO m => FilePath -> m BL.ByteString
readFile' "-" = liftIO BL.getContents
readFile' f   = liftIO $ BL.readFile f

writeFnBinary :: MonadIO m => FilePath -> BL.ByteString -> m ()
writeFnBinary "-" = liftIO . BL.putStr
writeFnBinary f   = liftIO . BL.writeFile (UTF8.encodePath f)

writerFn :: MonadIO m => IO.Newline -> FilePath -> Text -> m ()
writerFn eol "-" = liftIO . UTF8.putStrWith eol
writerFn eol f   = liftIO . UTF8.writeFileWith eol f
