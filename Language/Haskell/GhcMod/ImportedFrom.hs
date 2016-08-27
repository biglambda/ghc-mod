-- Copyright (C) 2013-2016 Carlo Hamalainen <carlo ÄT carlo-hamalainen DOT net>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

{-# LANGUAGE CPP, FlexibleContexts, Rank2Types, ScopedTypeVariables, ViewPatterns #-}

module Language.Haskell.GhcMod.ImportedFrom (importedFrom) where

import Control.Applicative
import Control.Exception
import Control.Monad
import Control.Monad.Trans.Maybe
import Data.Char (isAlpha, isDigit)
import Data.IORef
import Data.List
import Data.List.Split
import Data.Maybe
import Exception (ghandle)
import FastString
import GHC
import HscTypes
import Language.Haskell.GhcMod
import Language.Haskell.GhcMod.DynFlags
import Language.Haskell.GhcMod.Error
import Language.Haskell.GhcMod.FileMapping
import Language.Haskell.GhcMod.Gap
import Language.Haskell.GhcMod.GhcPkg
import Language.Haskell.GhcMod.Logging
import Language.Haskell.GhcMod.Monad
import Language.Haskell.GhcMod.Output
import Language.Haskell.GhcMod.PkgDoc
import Language.Haskell.GhcMod.SrcUtils (listifySpans)
import Outputable (showSDoc, showSDocForUser, ppr)
import System.Directory
import System.FilePath
import Text.ParserCombinators.ReadP ((+++))
import Text.Show.Pretty

import qualified Data.Map as M
import qualified Data.Set as Set
import qualified Documentation.Haddock as Haddock
import qualified GhcMonad
import qualified Safe
import qualified SrcLoc
import qualified Text.ParserCombinators.ReadP as RP

type QualifiedName = String -- ^ A qualified name, e.g. @Foo.bar@.

data NiceImportDecl
    -- | Information about an import of a Haskell module. Convenience type
    -- for the bits of a 'GHC.ImportDecl' that we need.
    = NiceImportDecl
        { modName           :: String
        , modQualifier      :: Maybe String
        , modIsImplicit     :: Bool
        , modHiding         :: [String]
        , modImportedAs     :: Maybe String
        , modSpecifically   :: [String]
        } deriving (Show, Eq)


-- trace' :: Show x => String -> x -> b -> b
-- trace' m x = trace (m ++ ">>> " ++ show x)

-- trace'' :: Outputable x => String -> x -> b -> b
-- trace'' m x = trace (m ++ ">>> " ++ showSDoc tdflags (ppr x))

parsePackageAndQualName :: RP.ReadP (String, String)
parsePackageAndQualName =
    RP.choice [parsePackageAndQualNameWithHash, parsePackageAndQualNameNoHash]
  where
    -- Package with no hash (seems to be for internal packages?)
    -- base-4.8.2.0:Data.Foldable.length
    parsePackageAndQualNameNoHash =
        (,) <$> parsePackageName <*> parsePackageFinalQualName
    parsePackageName = RP.get `RP.manyTill` RP.char ':'
    parsePackageFinalQualName = RP.many1 RP.get

-- Parse the package name "containers-0.5.6.2" from a string like
-- "containers-0.5.6.2@conta_2C3ZI8RgPO2LBMidXKTvIU:Data.Map.Base.fromList"
parsePackageAndQualNameWithHash :: RP.ReadP (String, String)
parsePackageAndQualNameWithHash = do
    (,) <$> parsePackageName <* parsePackageHash <*> parsePackageFinalQualName
  where
    parsePackageName = RP.get `RP.manyTill` RP.char '@'
    parsePackageHash = RP.get `RP.manyTill` RP.char ':'
    parsePackageFinalQualName = RP.many1 RP.get

runRP :: Show t => RP.ReadP t -> String -> Either String t
runRP rp s =
    case RP.readP_to_S rp s of
      [(m, "")] -> Right m
      err       -> Left $ "runRP: no unique match: " ++ show err

-- | Convenience function for converting an 'GHC.ImportDecl' to a
-- 'NiceImportDecl'.
--
-- Example:
--
-- > -- Hiding.hs
-- > module Hiding where
-- > import Data.List hiding (map)
-- > import System.Environment (getArgs)
-- > import qualified Safe
--
-- then:
--
-- >>> map toImportDecl <$> getTextualImports "tests/data/data/Hiding.hs" "Hiding" >>= print
-- [ NiceImportDecl { modName = "Prelude"
--                  , modQualifier = Nothing
--                  , modIsImplicit = True
--                  , modHiding = []
--                  , modImportedAs = Nothing
--                  , modSpecifically = []
--                  }
-- , NiceImportDecl {modName = "Safe"
--                  , modQualifier = Nothing
--                  , modIsImplicit = False
--                  , modHiding = []
--                  , modImportedAs = Nothing
--                  , modSpecifically = []
--                  }
-- , NiceImportDecl { modName = "System.Environment"
--                  , modQualifier = Nothing
--                  , modIsImplicit = False
--                  , modHiding = []
--                  , modImportedAs = Nothing
--                  , modSpecifically = ["getArgs"]
--                  }
-- , NiceImportDecl { modName = "Data.List"
--                  , modQualifier = Nothing
--                  , modIsImplicit = False
--                  , modHiding = ["map"]
--                  , modImportedAs = Nothing
--                  , modSpecifically = []
--                  }
-- ]
toImportDecl :: GHC.DynFlags
             -> SrcLoc.Located (GHC.ImportDecl GHC.RdrName)
             -> NiceImportDecl
toImportDecl dflags idecl =
    NiceImportDecl
      { modName           = name
      , modQualifier      = qualifier
      , modIsImplicit     = isImplicit
      , modHiding         = hiding
      , modImportedAs     = importedAs
      , modSpecifically   = specifically
      }
  where
    idecl'       = SrcLoc.unLoc idecl
    name         = showSDoc dflags (ppr $ GHC.ideclName idecl')
    isImplicit   = GHC.ideclImplicit idecl'
    qualifier    = unpackFS <$> ghc_sl_fs <$> GHC.ideclPkgQual idecl'
    hiding       = (catMaybes . parseHiding . ghcIdeclHiding) idecl'
    importedAs   = (showSDoc dflags . ppr) <$> ideclAs idecl'
    specifically = (parseSpecifically . ghcIdeclHiding) idecl'

    grabNames :: GHC.Located [GHC.LIE GHC.RdrName] -> [String]
    grabNames loc = map (showSDoc dflags . ppr) names
      where names :: [RdrName]
            names = map (ieName . SrcLoc.unLoc) $ SrcLoc.unLoc loc
            -- FIXME We are throwing away location info by using unLoc each time?
            -- Trace these things to see what we are losing.

    parseHiding :: Maybe (Bool, Located [LIE RdrName]) -> [Maybe String]
    parseHiding Nothing = [Nothing]

    -- If we do
    --
    --     import System.Environment ( getArgs )
    --
    -- then we get ["getArgs"] here, but we don't really need it...
    parseHiding (Just (False, _)) = []

    -- Actually hid names, e.g.
    --
    --     import Data.List hiding (map)
    parseHiding (Just (True, h))  = map Just $ grabNames h

    parseSpecifically :: Maybe (Bool, Located [LIE RdrName]) -> [String]
    parseSpecifically (Just (False, h)) = grabNames h
    parseSpecifically _                 = []

-- | Returns True if the 'Symbol' matches the end of the 'QualifiedName'.
--
-- Example:
--
-- >>> postfixMatch "bar" "Foo.bar"
-- True
-- >>> postfixMatch "bar" "Foo.baz"
-- False
-- >>> postfixMatch "bar" "bar"
-- True
postfixMatch :: String -> QualifiedName -> Bool
postfixMatch originalSymbol qName = endTerm `isSuffixOf` qName
  where
    endTerm = Safe.lastNote ("postfixMatch: got: " ++ originalSymbol) $
      splitOn "." originalSymbol

-- | Get the module part of a qualified name.
--
-- Example:
--
-- >>> moduleOfQualifiedName "Foo.bar"
-- Just "Foo"
-- >>> moduleOfQualifiedName "Foo"
-- Nothing
moduleOfQualifiedName :: QualifiedName -> Maybe String
moduleOfQualifiedName qn =
    if null bits
      then Nothing
      else Just $ intercalate "." bits
  where
    bits = reverse $ drop 1 $ reverse $ splitOn "." qn
{-# WARNING moduleOfQualifiedName "TODO: unsafe 'drop 1'" #-}


-- | Find the possible qualified names for the symbol at line/col in the given
-- Haskell file and module. Returns a fully qualified name thatincludes the
-- package, hash, and name, e.g.
--
-- "containers-0.5.6.2@conta_2C3ZI8RgPO2LBMidXKTvIU:Data.Map.Base.fromList".
qualifiedNameAt
    :: forall m. (GhcMonad m, MonadIO m, GmOut m, GmLog m)
    => String -> Int -> Int -> String -> [String] -> m [String]
qualifiedNameAt targetModuleName lineNr colNr symbol importList = do
        dflags <- GHC.getSessionDynFlags

        let imports_with_target_module = targetModuleName : importList
            imports_fallback = importList
            ctx imports = map (IIDecl . simpleImportDecl . mkModuleName) imports

            handler :: SomeException -> m ()
            handler err = do
               gmLog GmException "qualifiedNameAt" $
                             text "setContext failed, trying to continue anyway." $+$
                             text (show err)
               setContext $ ctx imports_fallback

        setContext (ctx imports_with_target_module) `gcatch` handler

        modSummary <- getModSummary $ mkModuleName targetModuleName :: m ModSummary
        p <- parseModule modSummary                                 :: m ParsedModule
        t <- typecheckModule p                                      :: m TypecheckedModule

        let TypecheckedModule { tm_typechecked_source = tcs } = t
            bs = listifySpans tcs (lineNr, colNr) :: [LHsBind Id]
            es = listifySpans tcs (lineNr, colNr) :: [LHsExpr Id]
            ps = listifySpans tcs (lineNr, colNr) :: [LPat Id]

        let bs' = map (showSDocForUser dflags ghcQualify . ppr) bs
            es' = map (showSDocForUser dflags ghcQualify . ppr) es
            ps' = map (showSDocForUser dflags ghcQualify . ppr) ps

        gmLog GmDebug "qualifiedNameAt" $ strDoc $ "symbol: " ++ symbol
        gmLog GmDebug "qualifiedNameAt" $ strDoc $ "line, col: " ++ show (lineNr, colNr)

        let stuff = map dropParens $ concatMap words $ bs' ++ es' ++ ps'
        gmLog GmDebug "qualifiedNameAt" $ strDoc $ "stuff: " ++ show stuff

        return $ filter (postfixMatch symbol) stuff

  where
    -- GHC8 starts showing things inside parens? Why? e.g. "(base-4.9.0.0:GHC.Num.+)"
    dropParens :: String -> String
    dropParens = dropWhileEnd (== ')') . dropWhile (== '(')

splitPackageName :: String -> String
splitPackageName p
    = case splitOn "@" p of
            [p0, _] -> p0
            _       -> p

ghcPkgHaddockUrl
    :: forall m. (GmLog m, GmOut m, MonadIO m)
    => FilePath
    -> (FilePath -> [String] -> String -> IO String)
    -> [GhcPkgDb]
    -> String
    -> m (Maybe String)
ghcPkgHaddockUrl ghcPkg readProc pkgDbStack p = do
    gmLog GmDebug "ghcPkgHaddockUrl" $ strDoc p

    let p' = splitPackageName p

    hout <- liftIO $ readProc ghcPkg (toDocDirOpts p' pkgDbStack) ""
    return $ Safe.lastMay $ words $ reverse $ dropWhile (== '\n') $ reverse hout
  where
    -- This fails unless we have --global and --user, unlike
    -- pkgDoc elsewhere in ghc-mod.
    toDocDirOpts pkg dbs = ["field", pkg, "haddock-html", "--global", "--user"] ++ ghcPkgDbStackOpts dbs

ghcPkgHaddockInterface
    :: forall (m :: * -> *).  MonadIO m
    => FilePath
    -> (FilePath -> [String] -> String -> IO String)
    -> [GhcPkgDb]
    -> String
    -> m (Maybe String)
ghcPkgHaddockInterface ghcPkg readProc pkgDbStack p = do
    hout <- liftIO $ readProc ghcPkg (toHaskellInterfaces p pkgDbStack) ""
    return $ Safe.lastMay $ words $ reverse . dropWhile (== '\n') . reverse $ hout
  where
    toHaskellInterfaces pkg dbs = ["field", pkg, "haddock-interfaces", "--global", "--user"] ++ ghcPkgDbStackOpts dbs

getVisibleExports
    :: forall m. (GhcMonad m, MonadIO m, GmOut m, GmLog m)
    => (String -> m (Maybe String))
    -> String
    -> m (Maybe (M.Map String [String]))
getVisibleExports getHaddockInterfaces p = do
    gmLog GmDebug "getVisibleExports" $ strDoc p

    let p' = splitPackageName p

    haddockInterfaceFile <- getHaddockInterfaces p'
    case haddockInterfaceFile of
            Just hi -> getVisibleExports' hi
            Nothing -> return Nothing

  where
    getVisibleExports' :: FilePath -> m (Maybe (M.Map String [String]))
    getVisibleExports' ifile = do
        iface <- Haddock.readInterfaceFile nameCacheFromGhc ifile

        dflags <- GHC.getSessionDynFlags

        case iface of
            Left _          -> throw $ GMEMissingHaddockInterface ifile
            Right iface'    -> return $ Just $ M.fromList
                                    [ (mname,  names)
                                    | ii <- Haddock.ifInstalledIfaces iface'
                                    , let mname = showSDoc dflags $ ppr $ Haddock.instMod ii
                                          names = map (showSDoc dflags . ppr) $ Haddock.instVisibleExports ii
                                    ]

    ------------------------------------------------------------------------------------------------------------------------
    -- Copied from http://hackage.haskell.org/package/haddock-api-2.16.1/docs/src/Haddock-InterfaceFile.html#nameCacheFromGhc
    -- but for a general monad m instead of the specific monad Ghc.
    ------------------------------------------------------------------------------------------------------------------------
    nameCacheFromGhc :: Haddock.NameCacheAccessor m
    nameCacheFromGhc = ( read_from_session , write_to_session )
      where
        read_from_session = do
           ref <- GhcMonad.withSession (return . hsc_NC)
           liftIO $ readIORef ref
        write_to_session nc' = do
           ref <- GhcMonad.withSession (return . hsc_NC)
           liftIO $ writeIORef ref nc'

getModuleExports
    :: forall m. (GhcMonad m, GmOut m, GmLog m, IOish m)
    => FilePath
    -> (FilePath -> [String] -> String -> IO String)
    -> [GhcPkgDb]
    -> NiceImportDecl
    -> m (Maybe ([String], String))
getModuleExports ghcPkg readProc pkgDbStack m = do
    let
        handler :: SomeException -> m (Maybe a)
        handler e = do
          let modDoc = doubleQuotes $ text $ modName m
          gmLog GmDebug "getModuleExports" $
            (text "Failed to find module" <> modDoc) <+>:
            text (show e)
          return Nothing

    minfo <- (findModule (mkModuleName $ modName m) Nothing >>= getModuleInfo)
               `gcatch` handler

    p <- pkgFindModule ghcPkg readProc pkgDbStack (modName m)

    dflags <- GHC.getSessionDynFlags

    return $ case (minfo, p) of
        (Nothing,      _) -> Nothing
        (_,           "") -> Nothing
        (Just minfo',  _) -> Just (map (showSDocForUser dflags ghcQualify . ppr) $ modInfoExports minfo', p)

-- * e.g. e.g. "base-4.8.2.0:Data.Foldable.length"
type FullyQualifiedName = String

-- * e.g. "Data.List"
type StrModuleName      = String


data MySymbol = MySymbolSysQualified  String
              -- ^ e.g. "base-4.8.2.0:Data.Foldable.length"
              | MySymbolUserQualified String
                -- ^ e.g. "DL.length" with an import earlier like "import
                -- qualified Data.List as DL"
              deriving Show

data ModuleExports = ModuleExports
    { mName            :: StrModuleName
    -- ^ e.g. @"Data.List"@
    , mPackageName     :: String
    -- ^ e.g. @"snap-0.14.0.6"@
    , mInfo            :: NiceImportDecl
    -- ^ Our parse of the module import, with info like "hiding (map)".
    , qualifiedExports :: [FullyQualifiedName]
    -- ^ e.g.
    -- @
    --        [ "base-4.8.2.0:GHC.Base.++"
    --        , "base-4.8.2.0:GHC.List.filter"
    --        , "base-4.8.2.0:GHC.List.zip"
    --        , ...
    --        ]
    -- @
    } deriving Show

-- User qualified the symbol, so we can filter out anything that doesn't have a
-- matching 'modImportedAs'.
refineAs :: MySymbol -> [ModuleExports] -> [ModuleExports]
refineAs (MySymbolUserQualified userQualSym) exports = filter f exports
  where
    f ModuleExports { mInfo = NiceImportDecl { modImportedAs = modAs } } =
        modAs == moduleOfQualifiedName userQualSym

-- User didn't qualify the symbol, so we have the full system qualified thing,
-- so do nothing here.
refineAs (MySymbolSysQualified _) exports = exports

refineRemoveHiding :: [ModuleExports] -> [ModuleExports]
refineRemoveHiding exports =
    map (\e -> e { qualifiedExports = removeHiding e }) exports
  where
    removeHiding export = filter (`notElem` hiding') thisExports
       where hiding = modHiding $ mInfo export :: [String]
             -- ^ Things that this module hides.
             hiding' = map (qualifyName thisExports) hiding  :: [String]
             -- ^ Qualified version of hiding.
             thisExports = qualifiedExports export
             -- ^ Things that this module exports.

    nub' = Set.toList . Set.fromList

    qualifyName :: [QualifiedName] -> String -> QualifiedName
    qualifyName qualifiedNames name
        = case nub' (filter (postfixMatch' name) qualifiedNames) of
            [match]     -> match
            m           -> fail $ "ImportedFrom: could not qualify "
                                  ++ name ++ " from these exports: "
                                  ++ show qualifiedNames ++ "\n    matches: "
                                  ++ show m

    postfixMatch' n qn
        | n == qn   = True
        | otherwise = case runRP (f $ reverse n) (reverse qn) of
                         Left _   -> False
                         Right () -> True
      where
        f n = void $
               RP.string n
            >> RP.char '.'
            >> RP.manyTill nameThenDot (nameThenEnd +++ nameThenEnd')


        -- Valid chars in a haskell module name:
        -- https://www.haskell.org/onlinereport/syntax-iso.html
        modChar c = isAlpha c || isDigit c || (c == '\'')

        nameThenEnd = void $
            RP.many1 (RP.satisfy modChar) >> RP.eof

        nameThenEnd' = void $
                        RP.many1 (RP.satisfy modChar)
                     >> RP.char ':'
                     >> RP.manyTill RP.get RP.eof
                     >> RP.eof

        nameThenDot = void $
                      RP.many1 (RP.satisfy modChar)
                   >> RP.char '.'

refineExportsIt :: MySymbol -> [ModuleExports] -> [ModuleExports]
refineExportsIt mysymbol exports =
    map (\e -> e { qualifiedExports = f symbol e }) exports
  where
    -- Deal with these?
    symbol = case mysymbol of
                MySymbolSysQualified  s -> s
                MySymbolUserQualified s -> s

    f sym export = filter (postfixMatch sym) thisExports
       where
         -- * Things that this module exports.
         thisExports = qualifiedExports export


-- On an internal symbol (e.g. Show), refineExportsIt erronously filters out
-- everything.  For example mnsymbol = "base-4.9.0.0:GHC.Show.C:Show" and the
-- matching name "base-4.9.0.0:GHC.Show.Show" from the Prelude. The problem
-- seems to be the module name GHC.Show.C, probably referring to an internal C
-- library.
--
-- To get around this, refineExportsItFallbackInternal uses a less strict
-- matching rule. If the 'stage3' results are empty we fall back to this
-- refiner.
refineExportsItFallbackInternal :: MySymbol -> [ModuleExports] -> [ModuleExports]
refineExportsItFallbackInternal mysymbol exports
    = case splitOn ":" symbol of
        [p, _, x]   -> map (\e -> e { qualifiedExports = f p x e }) exports
        _           -> exports
  where
    -- Deal with these?
    symbol = case mysymbol of
                MySymbolSysQualified  s -> s
                MySymbolUserQualified s -> s

    -- Check if package name matches and postfix symbol matches (roughly).
    f p sym export =
        filter
          (\z -> p `isPrefixOf` z && postfixMatch sym z)
          (qualifiedExports export)

refineLeadingDot :: MySymbol -> [ModuleExports] -> [ModuleExports]
refineLeadingDot (MySymbolUserQualified _)   exports = exports
refineLeadingDot (MySymbolSysQualified symb) exports =
    map (\e -> e { qualifiedExports = f leadingDot e }) exports
  where
    -- We use leadingDot only when we have an 'MySymbolSysQualified symb' so
    -- the 'last' will be ok. Sample value of 'symb' in this case is
    -- "base-4.8.2.0:Data.Foldable.length".
    leadingDot :: String
    leadingDot =
        '.' : Safe.lastNote ("leadingDot: got: " ++ symb) (splitOn "." symb)

    -- f symbol export = filter (symbol ==) thisExports
    f symbol export = filter (symbol `isSuffixOf`) thisExports
       where thisExports = qualifiedExports export

refineVisibleExports
    :: forall m. (GmGhc m, MonadError GhcModError m, GmOut m, GmLog m, GmEnv m)
    => (String -> m (Maybe String))
    -> [ModuleExports]
    -> m [ModuleExports]
refineVisibleExports getHaddockInterfaces exports = mapM f exports
  where
    f :: ModuleExports -> m ModuleExports
    f mexports = do
        let pname          = mPackageName     mexports -- e.g. "base-4.8.2.0"
            thisModuleName = mName            mexports -- e.g. "Prelude"
            qexports       = qualifiedExports mexports -- e.g. ["base-4.8.2.0:GHC.Base.Just", ...]
        visibleExportsMap <- liftMaybe
                                (GMEString "ImportedFrom: visible exports map is Nothing")
                                (getVisibleExports getHaddockInterfaces pname)

        gmLog GmDebug "refineVisibleExports" $ foldr (\d e -> (d <> comma) <+> e) mempty
              [ text "Package name" <+>: text pname
              , text "Module" <+>: text thisModuleName
              ]
        gmVomit "refine:visible-exports-map" (text "visibleExportsMap") (ppShow visibleExportsMap)

        let thisModVisibleExports0 = M.lookup thisModuleName                   visibleExportsMap
            thisModVisibleExports1 = M.lookup (pname ++ ":" ++ thisModuleName) visibleExportsMap

        -- On earlier versions of GHC, our qexports list will not be fully qualified, so it will
        -- look like ["base:GHC.Base.Just", ...] instead of ["base-4.8.2.0:GHC.Base.Just", ...].
        -- So if thisModVisibleExports0 is Nothing, fall back to searching on a shorter pname.
        thisModVisibleExports <- case thisModVisibleExports0 `mplus` thisModVisibleExports1 of
                                        Just ve -> return ve
                                        Nothing -> let pname' = ((Safe.headNote ("pname: " ++ pname) $ splitOn "-" pname) ++ ":" ++ thisModuleName) in
                                                        liftMaybe
                                                            (GMENoVisibleExports thisModuleName pname')
                                                            (return $ M.lookup pname' visibleExportsMap)

        let qexports' = filter (hasPostfixMatch thisModVisibleExports) qexports

        gmVomit "visible-exports-map" mempty (ppShow (qexports \\ qexports', qexports'))

        return $ mexports { qualifiedExports = qexports' }

    -- hasPostfixMatch "base-4.8.2.0:GHC.Base.Just" ["Just", "True", ...] -> True
    hasPostfixMatch :: [String] -> String -> Bool
    hasPostfixMatch xs s = Safe.lastNote ("hasPostfixMatch: got: " ++ s) (splitOn "." s) `elem` xs

-- | The last thing with a single export must be the match? Iffy.
getLastMatch :: [ModuleExports] -> Maybe ModuleExports
getLastMatch exports = Safe.lastMay $ filter f exports
  where
    f me = length (qualifiedExports me) == 1

-- | Try to look up the Haddock URL for a symbol.
guessHaddockUrl
    :: forall m.
       (GmGhc m, MonadError GhcModError m, GmOut m, GmLog m, GmEnv m)
    => ModSummary
    -> FilePath
    -> String
    -> String
    -> Int
    -> Int
    -> FilePath
    -> (FilePath -> [String] -> String -> IO String)
    -> [GhcPkgDb]
    -> m String
guessHaddockUrl modSum targetFile targetModule symbol lineNr colNr ghcPkg readProc pkgDbStack = do
    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "targetFile: "   ++ targetFile
    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "targetModule: " ++ targetModule
    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "symbol: "       ++ show symbol
    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "line nr: "      ++ show lineNr
    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "col nr: "       ++ show colNr

    dflags <- GHC.getSessionDynFlags

    let textualImports = ghc_ms_textual_imps modSum
        importDecls0 = map (toImportDecl dflags) textualImports

    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "haskellModuleNames0: " ++ show importDecls0

    -- If symbol is something like DM.lookup, then restrict importDecls0 to the
    -- one that has modImportedAs == Just "DM".
    let importDecls1 = filterMatchingQualifiedImport symbol importDecls0

    -- If that filter left us with nothing, revert back to the original list.
    let importDecls2 = if null importDecls1
                                then importDecls0
                                else importDecls1

    qnames <- filter (not . (' ' `elem`)) <$> qualifiedNameAt targetModule lineNr colNr symbol (map modName importDecls2) :: m [String]
    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "qnames: " ++ show qnames

    let symbolToUse :: String
        symbolToUse = case qnames of
                        (qq:_) -> qq -- We got a qualified name, with qualified printing. Qualified!
                        []     -> fail $ "ImportedFrom: qnames is empty."

    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "symbolToUse: " ++ symbolToUse

    -- Sometimes we have to load an extra module (using setContext) otherwise
    -- we can't look up the global reader environment without causing a GHC panic.
    -- For example 'Int' comes from GHC.Types, which is picked up here via the
    -- full qualified name.
    let parsedPackagesAndQualNames = map (runRP parsePackageAndQualName) qnames

        mkNiceDecl x = [ NiceImportDecl
                          { modName         = x
                          , modQualifier    = Nothing
                          , modIsImplicit   = False
                          , modHiding       = []
                          , modImportedAs   = Nothing
                          , modSpecifically = []
                          }
                       ]

        extraImportDecls :: [NiceImportDecl]
        extraImportDecls = case Safe.headMay parsedPackagesAndQualNames of
            Just (Right (_, moduleOfQualifiedName -> Just x)) -> mkNiceDecl x
            _                                                 -> []

        importDecls3 = importDecls2 ++ extraImportDecls

    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "parsedPackagesAndQualNames: " ++ show parsedPackagesAndQualNames
    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "extraImportDecls: " ++ show extraImportDecls

    exports0 <- mapM (getModuleExports ghcPkg readProc pkgDbStack) importDecls3 :: m [Maybe ([String], String)]

    -- Sometimes the modules in extraImportDecls might be hidden or weird ones like GHC.Base that we can't
    -- load, so filter out the successfully loaded ones.
    let successes :: [(NiceImportDecl, Maybe ([String], String))]
        successes = filter (isJust . snd) (zip importDecls3 exports0)

        toMaybe :: (NiceImportDecl, Maybe ([FullyQualifiedName], String))
                -> Maybe (NiceImportDecl, ([FullyQualifiedName], String))
        toMaybe (h, Just x)  = Just (h, x)
        toMaybe (_, Nothing) = Nothing

        successes' :: [(NiceImportDecl, ([String], String))]
        successes' = mapMaybe toMaybe successes

        mkExports (m, (e, p)) = ModuleExports
                                  { mName             = modName m
                                  , mPackageName      = p
                                  , mInfo             = m
                                  , qualifiedExports  = e
                                  }

        stage0 = map mkExports successes'

    -- Get all "as" imports.
    let asImports :: [String]
        asImports = mapMaybe (modImportedAs . mInfo) stage0

        mySymbol = case moduleOfQualifiedName symbol of
                    Nothing     -> MySymbolSysQualified symbolToUse
                    Just x      -> if x `elem` asImports
                                        then MySymbolUserQualified symbol
                                        else MySymbolSysQualified symbolToUse

    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "mySymbol: " ++ show mySymbol

    let pprModuleExports :: ModuleExports -> String
        pprModuleExports me = "(" ++ mName me ++ ", " ++ show (mInfo me) ++ ", " ++ unwords (map show $ qualifiedExports me) ++ ")"

        showDebugStage stageNr stage = forM_ stage $ \x -> gmLog GmDebug "guessHaddockUrl" $ strDoc $ stageNr ++ " " ++ pprModuleExports x

    showDebugStage "stage0" stage0

    let stage1 = refineAs mySymbol stage0
    showDebugStage "stage1" stage1

    let stage2 = refineRemoveHiding stage1
    showDebugStage "stage2" stage2

    let stage3 = refineExportsIt mySymbol stage2
    showDebugStage "stage3" stage3

    let stage4 = if all (null . qualifiedExports) stage3
                    then refineExportsItFallbackInternal mySymbol stage2
                    else refineLeadingDot mySymbol stage3
    showDebugStage "stage4" stage4

    stage5 <- refineVisibleExports (ghcPkgHaddockInterface ghcPkg readProc pkgDbStack) stage4
    showDebugStage "stage5" stage5

    let lastMatch  = Safe.headMay $ catMaybes [getLastMatch stage5, getLastMatch stage4]

    gmLog GmDebug "guessHaddockUrl" $ strDoc $ show $ "lastMatch: " ++ show lastMatch

    let lastMatchModule :: String
        lastMatchModule = case mName <$> lastMatch of
                            Just modn   -> modn
                            _           -> fail $ "ImportedFrom: no nice match in lastMatch for module: " ++ show lastMatch

        lastMatchPackageName :: String
        lastMatchPackageName = case mPackageName <$> lastMatch of
                                Just p -> p
                                _      -> fail $ "ImportedFrom: no nice match in lastMatch for package name: " ++ show lastMatch

    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "lastMatchModule:      " ++ lastMatchModule
    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "lastMatchPackageName: " ++ lastMatchPackageName

    haddock <- liftMaybe
                    (GMEString $ "ImportedFrom: ghcPkgHaddockUrl failed to find path to HTML file.")
                    (ghcPkgHaddockUrl ghcPkg readProc pkgDbStack lastMatchPackageName)

    gmLog GmDebug "guessHaddockUrl" $ strDoc $ "haddock:             " ++ show haddock

    let mySymbol' = case mySymbol of
                            MySymbolSysQualified  s -> s
                            MySymbolUserQualified s -> s

    let f = haddock </> (moduleNameToHtmlFile lastMatchModule)

    e <- liftIO $ doesFileExist f

    return $
        if e then mySymbol' ++ " " ++ lastMatchModule ++ " file://" ++ f
             else mySymbol' ++ " " ++ lastMatchModule ++ " " ++ toHackageUrl f lastMatchPackageName lastMatchModule

  where
    -- Convert a module name string, e.g. @Data.List@ to @Data-List.html@.
    moduleNameToHtmlFile :: String -> String
    moduleNameToHtmlFile m = map f m ++ ".html"
      where
        f :: Char -> Char
        f '.' = '-'
        f c   = c

    toHackageUrl :: FilePath -> String -> String -> String
    toHackageUrl filepath package modulename = "https://hackage.haskell.org/package/" ++ package ++ "/" ++ "docs/" ++ modulename''
        where filepath'    = map repl filepath
              modulename'  = Safe.headNote "modulename1" $ splitOn "." $ Safe.headNote "modulename2" $ splitOn "-" modulename
              modulename'' = drop (fromJust $ substringP modulename' filepath') filepath'

              -- On Windows we get backslashes in the file path; convert
              -- to forward slashes for the URL.
              repl :: Char -> Char
              repl '\\' = '/'
              repl c    = c

              -- Adapted from http://www.haskell.org/pipermail/haskell-cafe/2010-June/078702.html
              substringP :: String -> String -> Maybe Int
              substringP _ []  = Nothing
              substringP sub str = if sub `isPrefixOf` str
                                    then Just 0
                                    else fmap (+1) $ substringP sub (Safe.tailNote ("substringP: " ++ str) str)

    filterMatchingQualifiedImport :: String -> [NiceImportDecl] -> [NiceImportDecl]
    filterMatchingQualifiedImport symbol hmodules
        = case moduleOfQualifiedName symbol of
            Nothing        -> []
            asBit@(Just _) -> filter (\z -> asBit == modImportedAs z) hmodules

-- | Look up Haddock docs for a symbol.
importedFrom
    :: forall m. IOish m
    => FilePath     -- ^ A target file.
    -> Int          -- ^ Line number.
    -> Int          -- ^ Column number.
    -> Expression   -- ^ Expression (symbol)
    -> GhcModT m String
importedFrom file lineNr colNr (Expression symbol) = do
    ghcPkg     <- getGhcPkgProgram
    readProc   <- gmReadProcess
    pkgDbStack <- getPackageDbStack

    ghandle handler $
      runGmlT' [Left file] deferErrors $
            withInteractiveContext $ importedFrom' ghcPkg readProc pkgDbStack
  where
    handler (SomeException ex) = do
      gmLog GmException "imported-from" $ showDoc ex
      return $ "imported-from exception: " ++ show ex

    importedFrom'
        :: FilePath
        -> (FilePath -> [String] -> String -> IO String)
        -> [GhcPkgDb]
        -> GmlT m String
    importedFrom' ghcPkg readProc pkgDbStack = do
        crdl   <- cradle
        modSum <- fileModSummaryWithMapping (cradleCurrentDir crdl </> file)
        let modstr = moduleNameString $ ms_mod_name modSum :: String

        x <- guessHaddockUrl modSum file modstr symbol lineNr colNr ghcPkg readProc pkgDbStack
        return $ x ++ "\n"