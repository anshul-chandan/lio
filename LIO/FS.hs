{-# OPTIONS_GHC -XDeriveDataTypeable #-}

{- |This module manages a file store in which a label is associated
    with every file and directory.  The file store is grouped into
    directories by label.  Files are stored under names like:

    > LabelHash/OpaqueName

    where LabelHash is a SHA-224 hash of the label, and OpaqueName is
    either a regular file (containing contents) or a directory
    populated exclusively by symbolic links pointing back into
    LabelHash directories.  Each LabelHash directory also has a file
    called

    > LabelHash/LABEL

    which actually contains the label of all the files in that directory.

    There is also a symbolic link @root@, pointing to the root
    directory.  For efficiency, @LabelHash@ actually consists of
    multiple directories.
 -}

module LIO.FS where

import LIO.Armor
import LIO.TCB
import LIO.TmpFile

import Prelude hiding (catch)

import Control.Exception
import Control.Monad
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as LC
import Data.Typeable
import System.Directory
import System.FilePath
import System.IO
import System.IO.Error hiding (catch, try)
import System.FilePath
import System.Posix.Directory hiding (removeDirectory)
import System.Posix.Files
import System.Posix.IO

import Data.Digest.Pure.SHA
import qualified System.IO.Cautious as CIO

--
-- Utility functions
--

strictReadFile   :: FilePath -> IO LC.ByteString
strictReadFile f = withFile f ReadMode readit
    where readit h = do
            size <- hFileSize h
            LC.hGet h $ fromInteger size

catchIO     :: IO a -> IO a -> IO a
catchIO a h = catch a ((const :: a -> IOException -> a) h)

ignore :: IO () -> IO ()
ignore m = catch m ((\e -> return ()) :: SomeException -> IO ())

--
-- Exceptions thrown by this module
--

data FSErr
    = FSCorruptLabel FilePath   -- ^File Containing Label is Corrupt
      deriving (Show, Typeable)
instance Exception FSErr

--
-- LDir functions
--

-- |File name in which labels are stored in 'LDir's.
labelFile :: FilePath
labelFile = "LABEL"

-- |Type containing the pathname of a @LabelHash@ directory (which
-- must contain a file named 'labelFile').
newtype LDir = LDir FilePath


-- |Hash a label down to the directory storing all 'Node's with that
-- label.
lDirOfLabel   :: (Label l) => l -> LDir
lDirOfLabel l =
    case armor32 $ bytestringDigest $ sha224 $ LC.pack $ show l of
      c1:c2:c3:rest -> LDir ((c1:[]) </> (c2:[]) </> (c3:[]) </> rest)

-- |Takes an LDir and returns the label stored in 'labelFile' in that
-- directory.  May throw 'FSCorruptLabel'.
labelOfLDir          :: (Label l) => LDir -> IO l
labelOfLDir (LDir p) = do
  s <- strictReadFile target `catch` diagnose
  parseit s
    where
      target = (p </> labelFile)
      parseit s = case reads $ LC.unpack s of
                    (l, "\n"):_ -> return l
                    _ -> throwIO $ FSCorruptLabel target
      diagnose e | isDoesNotExistError e = do
                         exists <- doesDirectoryExist p
                         if exists
                           then throwIO $ FSCorruptLabel target
                           else throwIO e
                 | otherwise             = throwIO e

-- |Gets the LDir for a particular label.  Creates it if it does not
-- exist.  May throw 'FSCorruptLabel'.
getLDir   :: Label l => l -> IO LDir
getLDir l = try (labelOfLDir ldir) >>= handle
    where
      ldir@(LDir dir) = lDirOfLabel l
      handle (Right l')
          | l' == l   = return ldir
          | otherwise = dumplabel >> throwIO (FSCorruptLabel dir)
      handle (Left e) =
          case fromException e of
            Just e' | isDoesNotExistError e' -> makedir
            _                                -> dumplabel >> throwIO e
      makelabel path = CIO.writeFile path $ shows l "\n"
      makedir = do
        let tdir = dir ++ newNodeExt
        createDirectoryIfMissing True tdir
        makelabel $ tdir </> labelFile
        rename tdir dir
        return ldir
      dumplabel = ignore $ makelabel $ dir </> (labelFile ++ ".correct")

--
-- Node functions
--

-- |The @Node@ type represents filenames of the form
-- @LabelHash\/OpaqueName@.  These names must always point to regular
-- files or directories (not symbolic links).  There must always exist
-- a file @LabalHash\/.label@ specifying the label of a @Node@.
newtype Node = Node FilePath

-- |When a @Node@ is first created, it has a file name with a \'~\'
-- character at the end.  This is so that in the case of a crash, a
-- node that was not linked to can be easily recognized and deleted.
-- The @NewNode@ type wrapper represents a node that is not yet linked
-- to.
newtype NewNode = NewNode Node

newNodeExt :: String
newNodeExt = "~"

-- | Create new Node in the appropriate directory for a given label.
-- The node gets created with an extra ~ appended.
mkNode     :: (Label l) => l
           -- ^Label for the new node
           -> (FilePath -> String -> IO (a, FilePath))
           -- ^Either 'mkTmpDir' or 'mkTmpFile' with curried 'IOMode'
           -> IO (a, NewNode)
           -- ^Returns file handle or () and destination path
mkNode l f = do
  (LDir d) <- getLDir l
  (a, p) <- f d newNodeExt
  let p' = init p
  exists <- catchIO (getFileStatus p' >> return True) (return False)
  if not exists
    then return (a, NewNode $ Node p')
    else do
      hPutStrLn stderr $ "mkNode: file " ++ p' ++ " already exists." -- XXX
      removeFile p `catchIO` (removeDirectory p `catchIO` return ())
      mkNode l f

-- |Wrapper around mkNode to create a directory.
mkNodeDir   :: (Label l) => l -> IO NewNode
mkNodeDir l = liftM snd (mkNode l mkTmpDir)

-- |Wrapper around mkNode to create a regular file.
mkNodeReg     :: (Label l) => l -> IOMode -> IO (Handle, NewNode)
mkNodeReg l m = mkNode l (mkTmpFile m)

-- | Used when creating a symbolic link named @src@ that points to
-- @dst@.  If both @src@ and @dst@ are relative to the current working
-- directory and in subdirectories, then the contents of the symbolic
-- link cannot just be @dst@, instead it is @makeRelativeTo dst src@.
makeRelativeTo          :: FilePath -- ^Destination of symbolic link
                        -> FilePath -- ^Name of symbolic link
                        -> FilePath -- ^Returns contents to put in symbolic link
makeRelativeTo dest src =
    doit (splitDirectories dest) (init $ splitDirectories src)
    where
      doit [] []                      = "."
      doit (d1:ds) (s1:ss) | d1 == s1 = doit ds ss
      doit d s = joinPath (replicate (length s) "../" ++ d)

-- |Assign a 'Name' to a 'NewNode', turning it into a 'Node'.
linkNode                                   :: NewNode -> Name -> IO Node
linkNode (NewNode (Node path)) (Name name) = do
  createSymbolicLink (path `makeRelativeTo` name) name
  rename (path ++ newNodeExt) path `onException` removeLink path
  return $ Node path


-- |The @Name@ type represents user-chosen (non-opaque) filenames of
-- symbolic links, either @\"root\"@ or pathnames of the form
-- @LabelHash\/OpaqueName\/filename@.  Intermediary components of the
-- file name must not be symbolic links.
newtype Name = Name FilePath

