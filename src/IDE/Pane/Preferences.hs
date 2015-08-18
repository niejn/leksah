{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Pane.Preferences
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
--
-- | Module for saving, restoring and editing preferences
--
---------------------------------------------------------------------------------


module IDE.Pane.Preferences (
    IDEPrefs(..)
,   PrefsState
,   readPrefs
,   writePrefs
,   defaultPrefs
,   prefsDescription
,   getPrefs
) where

import Graphics.UI.Gtk
       (buttonBoxSetLayout, boxSetSpacing, widgetDestroy, dialogRun,
        windowWindowPosition, dialogAddButton, messageDialogNew,
        labelSetMarkup, labelNew, widgetSetSensitive, cellText,
        widgetModifyFont, on, buttonActivated, boxPackEnd, boxPackStart,
        buttonNewFromStock, hButtonBoxNew, vBoxNew, castToWidget, VBox,
        ShadowType(..), Packing(..), fontDescriptionFromString, AttrOp(..),
        FileChooserAction(..), Color(..), ResponseId(..))
import qualified Text.PrettyPrint.HughesPJ as PP
import Distribution.Package
import Data.IORef
import Data.Typeable

import Control.Event
import Graphics.UI.Editor.Basics
import IDE.Core.State
import Graphics.UI.Editor.Simple
import Graphics.UI.Editor.Composite
import Graphics.UI.Editor.Parameters
import Graphics.UI.Editor.MakeEditor hiding (parameters)
import Graphics.UI.Editor.DescriptionPP
import Text.PrinterParser hiding (fieldParser,parameters)
import IDE.TextEditor
import IDE.Pane.SourceBuffer
import IDE.Pane.Log
import IDE.Pane.Info (setInfoStyle)
import IDE.Utils.FileUtils
import IDE.Utils.GUIUtils
import IDE.Debug
    (debugSetPrintBindResult,
     debugSetBreakOnError,
     debugSetBreakOnException,
     debugSetPrintEvldWithShow)
import Graphics.UI.Gtk.SourceView
       (sourceStyleSchemeManagerAppendSearchPath,
        sourceStyleSchemeManagerGetSchemeIds, sourceStyleSchemeManagerNew)
import System.Time (getClockTime)
import qualified IDE.StrippedPrefs as SP
import Control.Exception(SomeException,catch)
import Prelude hiding(catch)
import Data.List (isSuffixOf, sortBy)
import Data.Maybe (mapMaybe, catMaybes, fromMaybe, isJust)
import Graphics.UI.Gtk.Windows.MessageDialog
       (ButtonsType(..), MessageType(..))
import System.Glib.Attributes (set)
import Graphics.UI.Gtk.General.Enums
       (ButtonBoxStyle(..), WindowPosition(..))
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad (void, when)
import System.FilePath ((</>))
import Data.Text (Text)
import qualified Data.Text as T (isSuffixOf, unpack, pack, null)
import Data.Monoid ((<>))
import Control.Applicative ((<$>))
import Distribution.Text (display, simpleParse)
import IDE.Pane.Files (refreshFiles)
import Data.Foldable (forM_)

-- ---------------------------------------------------------------------
-- This needs to be incremented, when the preferences format changes
--
prefsVersion :: Int
prefsVersion = 3


-- | Represents the Preferences pane
data IDEPrefs               =   IDEPrefs {
    prefsBox                ::   VBox
} deriving Typeable


-- | The additional state used when recovering the pane
data PrefsState             =   PrefsState
    deriving(Eq,Ord,Read,Show,Typeable)


instance Pane IDEPrefs IDEM
    where
    primPaneName _  =   __ "Prefs"
    getAddedIndex _ =   0
    getTopWidget    =   castToWidget . prefsBox
    paneId b        =   "*Prefs"


instance RecoverablePane IDEPrefs PrefsState IDEM where
    saveState p     =   return Nothing
    recoverState pp st  =  return Nothing
    builder pp nb windows = do
        initialPrefs <- readIDE prefs
        configDir <- liftIO getConfigDir
        lastAppliedPrefsRef <- liftIO $ newIORef initialPrefs
        packageInfos <- liftIO getInstalledPackageIds
        let flatPrefsDesc = flattenFieldDescriptionPP (prefsDescription configDir packageInfos)
        reifyIDE $  \ ideR -> do
            vb      <-  vBoxNew False 0
            bb      <-  hButtonBoxNew
            boxSetSpacing bb 6
            buttonBoxSetLayout bb ButtonboxSpread
            preview   <-  buttonNewFromStock "Preview"
            restore <-  buttonNewFromStock "Restore"
            closeB  <-  buttonNewFromStock "gtk-cancel"
            save    <-  buttonNewFromStock "gtk-save"
            widgetSetSensitive save False
            boxPackStart bb preview PackNatural 0
            boxPackStart bb restore PackNatural 0
            boxPackEnd bb closeB PackNatural 0
            boxPackEnd bb save PackNatural 0
            (widget,injb,ext,notifier) <-  buildEditor
                                (extractFieldDescription $ prefsDescription configDir packageInfos) initialPrefs
            boxPackStart vb widget PackGrow 0
            label   <-  labelNew (Nothing :: Maybe Text)
            boxPackStart vb label PackNatural 0
            boxPackEnd vb bb PackNatural 5
            let prefsPane = IDEPrefs vb

            let applyPrefs newPrefs = do
                    lastAppliedPrefs    <- readIORef lastAppliedPrefsRef
                    reflectIDE (modifyIDE_ (\ide -> ide{prefs = newPrefs})) ideR
                    mapM_ (\f -> reflectIDE (applicator f newPrefs lastAppliedPrefs) ideR) flatPrefsDesc
                    writeIORef lastAppliedPrefsRef newPrefs

            on preview buttonActivated $ do
                mbNewPrefs <- extract initialPrefs [ext]
                forM_ mbNewPrefs applyPrefs

            on restore buttonActivated $ do
                applyPrefs initialPrefs

                -- update the UI
                injb initialPrefs
                markLabel nb (getTopWidget prefsPane) False
                widgetSetSensitive save False


            on save buttonActivated $ do
                mbNewPrefs <- extract initialPrefs [ext]
                case mbNewPrefs of
                    Nothing -> return ()
                    Just newPrefs -> do
                        applyPrefs newPrefs

                        -- save preferences to disk
                        fp   <- getConfigFilePathForSave standardPreferencesFilename
                        writePrefs fp newPrefs
                        fp2  <-  getConfigFilePathForSave strippedPreferencesFilename
                        SP.writeStrippedPrefs fp2
                            SP.Prefs {SP.sourceDirectories = sourceDirectories newPrefs,
                                       SP.unpackDirectory   = unpackDirectory newPrefs,
                                       SP.retrieveURL       = retrieveURL newPrefs,
                                       SP.retrieveStrategy  = retrieveStrategy newPrefs,
                                       SP.serverPort        = serverPort newPrefs,
                                       SP.endWithLastConn   = endWithLastConn newPrefs}

                        -- close the UI
                        reflectIDE (void (closePane prefsPane)) ideR

            on closeB buttonActivated $ do
                mbP <- extract initialPrefs [ext]
                let hasChanged = case mbP of
                                        Nothing -> False
                                        Just p -> p{prefsFormat = 0, prefsSaveTime = ""} /=
                                                  initialPrefs{prefsFormat = 0, prefsSaveTime = ""}
                if not hasChanged
                    then reflectIDE (void (closePane prefsPane)) ideR
                    else do
                        md <- messageDialogNew (Just windows) []
                            MessageQuestion
                            ButtonsYesNo
                            (__ "Unsaved changes. Close anyway?")
                        set md [ windowWindowPosition := WinPosCenterOnParent ]
                        resp <- dialogRun md
                        widgetDestroy md
                        case resp of
                            ResponseYes -> do
                                applyPrefs initialPrefs
                                reflectIDE (void (closePane prefsPane)) ideR
                            _  ->   return ()
            registerEvent notifier FocusIn (\e -> do
                reflectIDE (makeActive prefsPane) ideR
                return (e{gtkReturn=False}))
            registerEvent notifier MayHaveChanged (\ e -> do
                mbP <- extract initialPrefs [ext]
                let hasChanged = case mbP of
                                        Nothing -> False
                                        Just p -> p{prefsFormat = 0, prefsSaveTime = ""} /=
                                                  initialPrefs{prefsFormat = 0, prefsSaveTime = ""}
                when (isJust mbP) $ labelSetMarkup label ("" :: Text)
                markLabel nb (getTopWidget prefsPane) hasChanged
                widgetSetSensitive save hasChanged
                return (e{gtkReturn=False}))
            registerEvent notifier ValidationError (\e -> do
                labelSetMarkup label $ "<span foreground=\"red\" size=\"x-large\">The following fields have invalid values: "
                    <> eventText e <> "</span>"
                return e)
            return (Just prefsPane,[])


-- | Get the Preferences pane
getPrefs :: Maybe PanePath -> IDEM IDEPrefs
getPrefs Nothing    = forceGetPane (Right "*Prefs")
getPrefs (Just pp)  = forceGetPane (Left pp)



-- ------------------------------------------------------------
-- * Dialog definition
-- ------------------------------------------------------------

-- | Description of the preference options
prefsDescription :: FilePath -> [PackageIdentifier] -> FieldDescriptionPP Prefs IDEM
prefsDescription configDir packages = NFDPP [
    (__ "Editor", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName (__ "Version number of preferences file format")
                $ paraSynopsis <<<- ParaSynopsis (__ "Integer")
                    $ paraShowLabel <<<- ParaShowLabel False $ emptyParams)
            (PP.text . show)
            intParser
            prefsFormat
            (\ b a -> a{prefsFormat = b})
            (noEditor 0)
            (\b -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Time of last storage")
                $ paraShowLabel <<<- ParaShowLabel False $ emptyParams)
            (PP.text . show)
            stringParser
            prefsSaveTime
            (\ b a -> a{prefsSaveTime = b})
            (noEditor "")
            (\b -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Show line numbers")
                $ paraSynopsis <<<- ParaSynopsis (__ "(True/False)")
                    $ emptyParams)
            (PP.text . show)
            boolParser
            showLineNumbers
            (\ b a -> a{showLineNumbers = b})
            boolEditor
            (\b -> do
                buffers <- allBuffers
                mapM_ (\(IDEBuffer {sourceView = sv}) -> setShowLineNumbers sv b) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "TextView Font") $ emptyParams)
            (\a -> PP.text (case a of Nothing -> show ""; Just s -> show s))
            (do str <- stringParser
                return (if T.null str then Nothing else Just str))
            textviewFont
            (\ b a -> a{textviewFont = b})
            fontEditor
            (\mbs -> do
                buffers <- allBuffers
                mapM_ (\(IDEBuffer {sourceView = sv}) -> setFont sv mbs) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Right margin")
                $ paraSynopsis <<<- ParaSynopsis (__ "Size or 0 for no right margin")
                    $ paraShadow <<<- ParaShadow ShadowIn $ emptyParams)
            (PP.text . show)
            readParser
            rightMargin
            (\b a -> a{rightMargin = b})
            (disableEditor (intEditor (1.0, 200.0, 5.0), paraName <<<- ParaName (__ "Position")
                    $ emptyParams)
                    True (__ "Show it ?"))
            (\b -> do
                buffers <- allBuffers
                mapM_ (\(IDEBuffer {sourceView = sv}) -> setRightMargin sv
                                (case b of
                                    (True,v) -> Just v
                                    (False,_) -> Nothing)) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Tab width") $ emptyParams)
            (PP.text . show)
            intParser
            tabWidth
            (\b a -> a{tabWidth = b})
            (intEditor (1.0, 20.0, 1.0))
            (\i -> do
                buffers <- allBuffers
                mapM_ (\(IDEBuffer {sourceView = sv}) -> setIndentWidth sv i) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Wrap lines") $ emptyParams)
            (PP.text . show)
            boolParser
            wrapLines
            (\b a -> a{wrapLines = b})
            boolEditor
            (\b -> do
                buffers <- allBuffers
                mapM_ (\(IDEBuffer {sourceView = sv}) -> setWrapMode sv b) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Use standard line ends even on windows") $ emptyParams)
            (PP.text . show)
            boolParser
            forceLineEnds
            (\b a -> a{forceLineEnds = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Remove trailing blanks when saving a file") $ emptyParams)
            (PP.text . show)
            boolParser
            removeTBlanks
            (\b a -> a{removeTBlanks = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Source candy")
                $ paraSynopsis <<<- ParaSynopsis
                    (__ "Empty for do not use or the name of a candy file in a config dir")
                    $ paraShadow <<<- ParaShadow ShadowIn $ emptyParams)
            (PP.text . show)
            readParser
            sourceCandy (\b a -> a{sourceCandy = b})
            (disableEditor (textEditor (not . T.null) True,
                paraName <<<- ParaName (__ "Candy specification")
                                    $ emptyParams)
                    True (__ "Use it ?"))
            (\cs -> case cs of
                        (False,_) -> do
                            setCandyState False
                            editCandy
                        (True,name) -> do
                            setCandyState True
                            editCandy)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Editor Style") $ emptyParams)
            (\a -> PP.text (case a of (False,_) -> show ""; (True, s) -> show s))
            (do str <- stringParser
                return (if T.null str then (False, __ "classic") else (True,str)))
            sourceStyle
            (\b a -> a{sourceStyle = b})
            styleEditor
            (\mbs -> do
                setInfoStyle
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Found Text Background") $ emptyParams)
            (PP.text . show)
            colorParser
            foundBackgroundLight
            (\ b a -> a{foundBackgroundLight = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Selection Match Text Background") $ emptyParams)
            (PP.text . show)
            colorParser
            matchBackgroundLight
            (\ b a -> a{matchBackgroundLight = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Execution Context Text Background") $ emptyParams)
            (PP.text . show)
            colorParser
            contextBackgroundLight
            (\ b a -> a{contextBackgroundLight = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Breakpoint Text Background") $ emptyParams)
            (PP.text . show)
            colorParser
            breakpointBackgroundLight
            (\ b a -> a{breakpointBackgroundLight = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Lint Text Background") $ emptyParams)
            (PP.text . show)
            colorParser
            lintBackgroundLight
            (\ b a -> a{lintBackgroundLight = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Found Text Dark Background") $ emptyParams)
            (PP.text . show)
            colorParser
            foundBackgroundDark
            (\ b a -> a{foundBackgroundDark = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Selection Match Text Dark Background") $ emptyParams)
            (PP.text . show)
            colorParser
            matchBackgroundDark
            (\ b a -> a{matchBackgroundDark = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Execution Context Text Dark Background") $ emptyParams)
            (PP.text . show)
            colorParser
            contextBackgroundDark
            (\ b a -> a{contextBackgroundDark = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Breakpoint Text Dark Background") $ emptyParams)
            (PP.text . show)
            colorParser
            breakpointBackgroundDark
            (\ b a -> a{breakpointBackgroundDark = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Lint Text Dark Background") $ emptyParams)
            (PP.text . show)
            colorParser
            lintBackgroundDark
            (\ b a -> a{lintBackgroundDark = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                mapM_ updateStyle' buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Automatically load modified files modified outside of Leksah") $ emptyParams)
            (PP.text . show)
            boolParser
            autoLoad
            (\b a -> a{autoLoad = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Text Editor") $ emptyParams)
            (PP.text . show)
            stringParser
            textEditorType
            (\b a -> a{textEditorType = b})
            (comboSelectionEditor ["GtkSourceView", "Yi", "CodeMirror"] id)
            (\i -> return ())
    ]),
    (__ "GUI Options", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName (__ "LogView Font") $ emptyParams)
            (\a -> PP.text (case a of Nothing -> show ""; Just s -> show s))
            (do str <- stringParser
                return (if T.null str then Nothing else Just str))
            logviewFont
            (\ b a -> a{logviewFont = b})
            fontEditor
            (\mbs -> do
                log <- getLog
                fdesc <- liftIO $fontDescriptionFromString (fromMaybe "" mbs)
                liftIO $widgetModifyFont (castToWidget $ logLaunchTextView log) (Just fdesc))
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Window default size")
                $ paraSynopsis <<<- ParaSynopsis
                    (__ "Default size of the main ide window specified as pair (int,int)")
                    $ paraShadow <<<- ParaShadow ShadowIn $ emptyParams)
            (PP.text.show)
            (pairParser intParser)
            defaultSize (\(c,d) a -> a{defaultSize = (c,d)})
            (pairEditor (intEditor (0.0, 3000.0, 25.0),
                            paraName <<<- ParaName "X" $ emptyParams)
                        (intEditor (0.0, 3000.0, 25.0),
                            paraName <<<- ParaName "Y" $ emptyParams))
            (\a -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Show hidden files in file tree") $ emptyParams)
            (PP.text . show)
            boolParser
            showHiddenFiles
            (\b a -> a {showHiddenFiles = b})
            boolEditor
            (const refreshFiles)
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Use ctrl Tab for Notebook flipper") $ emptyParams)
            (PP.text . show)
            boolParser
            useCtrlTabFlipping
            (\b a -> a{useCtrlTabFlipping = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Complete only on Hotkey") $ emptyParams)
            (PP.text . show)
            boolParser
            completeRestricted
            (\b a -> a{completeRestricted = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Name of the keymap")
                $ paraSynopsis <<<- ParaSynopsis
                    (__ "The name of a keymap file in a config dir")
                    $ paraDirection <<<- ParaDirection Horizontal $ emptyParams)
            (PP.text . T.unpack)
            identifier
            keymapName
            (\b a -> a{keymapName = b})
            (textEditor (not . T.null) True)
            (\ a -> return ())
    ]),
    (__ "Initial Pane positions", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName
                (__ "Categories for panes")
                $ paraShadow <<<- ParaShadow ShadowIn
                     $ paraDirection <<<- ParaDirection Vertical
                        $ paraMinSize <<<- ParaMinSize (-1,130)
                            $ emptyParams)
            (PP.text . show)
            readParser
            categoryForPane
            (\b a -> a{categoryForPane = b})
            (multisetEditor
                (ColumnDescr True [(__ "Pane Id", \ (n, _) -> [cellText := n])
                                   ,(__ "Pane Category", \ (_, v) -> [cellText := v])])
                (pairEditor
                    (textEditor (not . T.null) True, emptyParams)
                    (textEditor (not . T.null) True, emptyParams), emptyParams)
                (Just (sortBy (\(a,_) (a2,_) -> compare a a2)))
                (Just (\(a,_) (a2,_) -> a == a2)))
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName
                (__ "Pane path for category")
                $ paraShadow <<<- ParaShadow ShadowIn
                     $ paraDirection <<<- ParaDirection Vertical
                        $ paraMinSize <<<- ParaMinSize (-1,130)
                            $ emptyParams)
            (PP.text . show)
            readParser
            pathForCategory
            (\b a -> a{pathForCategory = b})
            (multisetEditor
                (ColumnDescr True [(__ "Pane category", \ (n, _) -> [cellText := n])
                                   ,(__ "Pane path", \ (_, v) -> [cellText := T.pack $ show v])])
                (pairEditor (textEditor (not . T.null) True, emptyParams)
                    (genericEditor, emptyParams),
                  emptyParams)
                (Just (sortBy (\(a,_) (a2,_) -> compare a a2)))
                (Just (\(a,_) (a2,_) -> a == a2)))
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Default pane path") $ emptyParams)
            (PP.text . show)
            readParser
            defaultPath
            (\b a -> a{defaultPath = b})
            genericEditor
            (\i -> return ())
    ]),
    (__ "Metadata", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName
                (__ "Paths under which haskell sources for packages may be found")
                        $ paraMinSize <<<- ParaMinSize (-1,100)
                            $ emptyParams)
            (PP.text . show)
            readParser
            sourceDirectories
            (\b a -> a{sourceDirectories = b})
            (filesEditor Nothing FileChooserActionSelectFolder (__ "Select folder"))
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Unpack source for cabal packages to") $ emptyParams)
            (PP.text . show)
            readParser
            unpackDirectory
            (\b a -> a{unpackDirectory = b})
            (maybeEditor (stringEditor (const True) True,emptyParams) True "")
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "URL from which to download prebuilt metadata") $ emptyParams)
            (PP.text . show)
            stringParser
            retrieveURL
            (\b a -> a{retrieveURL = b})
            (textEditor (const True) True)
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Strategy for downloading prebuilt metadata") $ emptyParams)
            (PP.text . show)
            readParser
            retrieveStrategy
            (\b a -> a{retrieveStrategy = b})
            (enumEditor [__ "Try to download and then build locally if that fails",
                         __ "Try to build locally and then download if that fails",
                         __ "Never download (just try to build locally)"])
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Update metadata at startup") $ emptyParams)
            (PP.text . show)
            boolParser
            collectAtStart
            (\b a -> a{collectAtStart = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Port number for leksah to comunicate with leksah-server") $ emptyParams)
            (PP.text . show)
            intParser
            serverPort
            (\b a -> a{serverPort = b})
            (intEditor (1.0, 65535.0, 1.0))
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "IP address for leksah to comunicate with leksah-server") $ emptyParams)
            (PP.text . show)
            stringParser
            serverIP
            (\b a -> a{serverIP = b})
            (textEditor (not . T.null) True)
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "Stop the leksah-server process when leksah disconnects") $ emptyParams)
            (PP.text . show)
            boolParser
            endWithLastConn
            (\b a -> a{endWithLastConn = b})
            boolEditor
            (\i -> return ())
    ]),
    (__ "Blacklist", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName
                (__ "Packages which are excluded from the modules pane")
                        $ paraMinSize <<<- ParaMinSize (-1,200)
                            $ emptyParams)
            (PP.text . show . map display)
            (fmap (mapMaybe simpleParse) readParser)
            packageBlacklist
            (\b a -> a{packageBlacklist = b})
            (dependenciesEditor packages)
            (\i -> return ())
    ]),
    (__ "Build", VFDPP emptyParams [
         mkFieldPP
            (paraName <<<- ParaName (__ "Automatically save all files before building") $ emptyParams)
            (PP.text . show)
            boolParser
            saveAllBeforeBuild
            (\b a -> a{saveAllBeforeBuild = b})
            boolEditor
            (\i -> return ())
         , mkFieldPP
            (paraName <<<- ParaName (__ "Select first warning if built without errors") $ emptyParams)
            (PP.text . show)
            boolParser
            jumpToWarnings
            (\b a -> a{jumpToWarnings = b})
            boolEditor
            (\i -> return ())
         , mkFieldPP
            (paraName <<<- ParaName (__ "Background build") $ emptyParams)
            (PP.text . show)
            boolParser
            backgroundBuild
            (\b a -> a{backgroundBuild = b})
            boolEditor
            (\i -> return ())
         , mkFieldPP
            (paraName <<<- ParaName (__ "Run unit tests when building") $ emptyParams)
            (PP.text . show)
            boolParser
            runUnitTests
            (\b a -> a{runUnitTests = b})
            boolEditor
            (\i -> return ())
         , mkFieldPP
            (paraName <<<- ParaName (__ "Make mode") $ emptyParams)
            (PP.text . show)
            boolParser
            makeMode
            (\b a -> a{makeMode = b})
            (boolEditor2 (__ "Single mode"))
            (\i -> return ())

         , mkFieldPP
            (paraName <<<- ParaName (__ "Single build without linking") $ emptyParams)
            (PP.text . show)
            boolParser
            singleBuildWithoutLinking
            (\b a -> a{singleBuildWithoutLinking = b})
            boolEditor
            (\i -> return ())
         , mkFieldPP
            (paraName <<<- ParaName (__ "Don't install last package") $ emptyParams)
            (PP.text . show)
            boolParser
            dontInstallLast
            (\b a -> a{dontInstallLast = b})
            boolEditor
            (\i -> return ())

        , mkFieldPP
            (paraName <<<- ParaName (__ "Use vado to run commands on the remote machine") $ emptyParams)
            (PP.text . show)
            boolParser
            useVado
            (\b a -> a{useVado = b})
            boolEditor
            (\i -> return ())

        , mkFieldPP
            (paraName <<<- ParaName (__ "Use cabal-dev") $ emptyParams)
            (PP.text . show)
            boolParser
            useCabalDev
            (\b a -> a{useCabalDev = b})
            boolEditor
            (\i -> return ())
    ]),
    (__ "Debug", VFDPP emptyParams [
           mkFieldPP
            (paraName <<<- ParaName (__ "Enable usage of Show instances in :print") $ emptyParams)
            (PP.text . show)
            boolParser
            printEvldWithShow
            (\b a -> a{printEvldWithShow = b})
            boolEditor
            debugSetPrintEvldWithShow
         , mkFieldPP
            (paraName <<<- ParaName (__ "Break on any exception thrown") $ emptyParams)
            (PP.text . show)
            boolParser
            breakOnException
            (\b a -> a{breakOnException = b})
            boolEditor
            debugSetBreakOnException
         , mkFieldPP
            (paraName <<<- ParaName (__ "Break on uncaught exceptions and errors") $ emptyParams)
            (PP.text . show)
            boolParser
            breakOnError
            (\b a -> a{breakOnError = b})
            boolEditor
            debugSetBreakOnError
         , mkFieldPP
            (paraName <<<- ParaName (__ "Turn on printing of binding results in GHCi") $ emptyParams)
            (PP.text . show)
            boolParser
            printBindResult
            (\b a -> a{printBindResult = b})
            boolEditor
            debugSetPrintBindResult
    ]),
    (__ "Help", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName (__ "Browser") $ emptyParams)
            (PP.text . show)
            stringParser
            browser
            (\b a -> a{browser = b})
            (textEditor (not . T.null) True)
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName (__ "URL for searching documentation") $
                paraSynopsis <<<- ParaSynopsis
                    ("e.g https://www.haskell.org/hoogle/?q= or " <>
                        "Hayoo: http://hayoo.fh-wedel.de/?query=")
                        $ emptyParams)
            (PP.text . show)
            stringParser
            docuSearchURL
            (\b a -> a{docuSearchURL = b})
            (textEditor (not . T.null) True)
            (\i -> return ())
    ])]

-- | Editor for enabling a different syntax stylesheet
styleEditor :: Editor (Bool, Text)
styleEditor p n = do
    styleManager <- sourceStyleSchemeManagerNew
    dataDir <- getDataDir
    sourceStyleSchemeManagerAppendSearchPath styleManager $ dataDir </> "data/styles"
    ids          <- sourceStyleSchemeManagerGetSchemeIds styleManager
    let notDarkIds = filter (not . T.isSuffixOf "-dark") ids
    disableEditor (comboSelectionEditor notDarkIds id, p) True (__ "Select a special style?") p n


-- | The default preferences
defaultPrefs = Prefs {
        prefsFormat         =   prefsVersion
    ,   prefsSaveTime       =   ""
    ,   showLineNumbers     =   True
    ,   rightMargin         =   (True,100)
    ,   tabWidth            =   4
    ,   wrapLines           =   False
    ,   sourceCandy         =   (False,"candy")
    ,   keymapName          =   "keymap"
    ,   forceLineEnds       =   True
    ,   removeTBlanks       =   True
    ,   textviewFont        =   Nothing
    ,   sourceStyle         =   (True,"leksah")
    ,   foundBackgroundLight      = Color 65535 65535 32768
    ,   matchBackgroundLight      = Color 42064 55923 28520
    ,   contextBackgroundLight    = Color 65535 46529 46529
    ,   breakpointBackgroundLight = Color 64879 51921 28114
    ,   lintBackgroundLight       = Color 60000 65535 60000
    ,   foundBackgroundDark       = Color 30364 29149     0
    ,   matchBackgroundDark       = Color 18021 29927  6384
    ,   contextBackgroundDark     = Color 20000 16000 16000
    ,   breakpointBackgroundDark  = Color 15000  5000  5000
    ,   lintBackgroundDark        = Color     0 15000     0
    ,   textEditorType      =   "GtkSourceView"
    ,   autoLoad            =   False
    ,   logviewFont         =   Nothing
    ,   defaultSize         =   (1024,800)
    ,   browser             =   "firefox"
    ,   sourceDirectories   =   []
    ,   packageBlacklist    =   []
    ,   pathForCategory     =   [   ("EditorCategory",[SplitP LeftP])
                                ,   ("LogCategory",[SplitP RightP, SplitP BottomP])
                                ,   ("ToolCategory",[SplitP RightP, SplitP TopP])
                                ]
    ,   defaultPath         =   [SplitP LeftP]
    ,   categoryForPane     =   [   ("*ClassHierarchy","ToolCategory")
                                ,   ("*Breakpoints","LogCategory")
                                ,   ("*Browser","ToolCategory")
                                ,   ("*Debug","ToolCategory")
                                ,   ("*Errors","ToolCategory")
                                ,   ("*Files","ToolCategory")
                                ,   ("*Flags","ToolCategory")
                                ,   ("*Grep","ToolCategory")
                                ,   ("*HLint","ToolCategory")
                                ,   ("*Doc","ToolCategory")
                                ,   ("*Info","LogCategory")
                                ,   ("*Log","LogCategory")
                                ,   ("*Inspect","LogCategory")
                                ,   ("*Modules","ToolCategory")
                                ,   ("*Out","ToolCategory")
                                ,   ("*Package","EditorCategory")
                                ,   ("*Prefs","EditorCategory")
                                ,   ("*Search","ToolCategory")
                                ,   ("*Trace","LogCategory")
                                ,   ("*Variables","LogCategory")
                                ,   ("*Workspace","LogCategory")]
    ,   collectAtStart      =   True
    ,   unpackDirectory     =   Just ("~" </> configDirName </> "packageSources")
    ,   retrieveURL         =   "http://www.leksah.org"
    ,   retrieveStrategy    =   SP.RetrieveThenBuild
    ,   useCtrlTabFlipping  =   True
    ,   docuSearchURL       =   "https://www.haskell.org/hoogle/?q="
    ,   completeRestricted  =   False
    ,   saveAllBeforeBuild  =   True
    ,   jumpToWarnings      =   True
    ,   useVado             =   False
    ,   useCabalDev         =   False
    ,   backgroundBuild     =   True
    ,   runUnitTests        =   False
    ,   makeMode            =   True
    ,   singleBuildWithoutLinking  = False
    ,   dontInstallLast     =   False
    ,   printEvldWithShow   =   True
    ,   breakOnException    =   True
    ,   breakOnError        =   True
    ,   printBindResult     =   False
    ,   serverPort          =   11111
    ,   serverIP            =   "127.0.0.1"
    ,   endWithLastConn     =   True
    ,   showHiddenFiles     =   False
    }

-- ------------------------------------------------------------
-- * Parsing
-- ------------------------------------------------------------

-- | Read the preference file
readPrefs :: FilePath -> IO Prefs
readPrefs fn = catch (do
    configDir <- getConfigDir
    readFields fn (flattenFieldDescriptionPPToS (prefsDescription configDir [])) defaultPrefs)
        (\ (e :: SomeException) -> do
            sysMessage Normal (T.pack $ show e)
            return defaultPrefs)
-- ------------------------------------------------------------
-- * Printing
-- ------------------------------------------------------------

-- | Write the preference file
writePrefs :: FilePath -> Prefs -> IO ()
writePrefs fpath prefs = do
    timeNow         <- liftIO getClockTime
    configDir <- getConfigDir
    let newPrefs    =   prefs {prefsSaveTime = T.pack $ show timeNow, prefsFormat = prefsVersion}
    writeFields fpath newPrefs (flattenFieldDescriptionPPToS (prefsDescription configDir []))


