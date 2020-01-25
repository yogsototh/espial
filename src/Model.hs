{-# OPTIONS_GHC -fno-warn-unused-imports #-}

module Model where

import qualified ClassyPrelude.Yesod as CP
import qualified Data.Aeson as A
import qualified Data.Attoparsec.Text as P
import qualified Control.Monad.Combinators as PC
import qualified Data.List.NonEmpty as NE
import qualified Data.Time.ISO8601 as TI
import qualified Database.Esqueleto as E
import Database.Esqueleto.Internal.Sql as E
import qualified Data.Time as TI
import ClassyPrelude.Yesod hiding ((||.))
import Control.Monad.Trans.Maybe
import Control.Monad.Writer (tell)
import Data.Char (isSpace)
import Data.Either (fromRight)
import Data.Foldable (foldl, foldl1, sequenceA_)
import Data.List.NonEmpty (NonEmpty(..))
import Database.Esqueleto hiding ((==.))
import Pretty
import System.Directory
import Types
import qualified Data.Map.Strict as MS

import ModelCustom

share [mkPersist sqlSettings, mkDeleteCascade sqlSettings, mkMigrate "migrateSchema"] [persistLowerCase|
User json
  Id Int64
  name Text
  passwordHash BCrypt
  apiToken Text Maybe
  privateDefault Bool
  archiveDefault Bool
  privacyLock Bool
  UniqueUserName name
  deriving Show Eq Typeable Ord

Bookmark json
  Id Int64
  userId UserId
  slug BmSlug default="(lower(hex(randomblob(6))))"
  href Text
  description Text
  extended Text
  time UTCTime
  shared Bool
  toRead Bool
  selected Bool
  archiveHref Text Maybe
  UniqueUserHref userId href
  UniqueUserSlug userId slug
  deriving Show Eq Typeable Ord

BookmarkTag json
  Id Int64
  userId UserId
  tag Text
  bookmarkId BookmarkId
  seq Int
  UniqueUserTagBookmarkId userId tag bookmarkId
  UniqueUserBookmarkIdTagSeq userId bookmarkId tag seq
  deriving Show Eq Typeable Ord

Note json
  Id Int64
  userId UserId
  slug NtSlug default="(lower(hex(randomblob(10))))"
  length Int
  title Text
  text Text
  isMarkdown Bool
  shared Bool default=False
  created UTCTime
  updated UTCTime
  deriving Show Eq Typeable Ord
|]

newtype UTCTimeStr =
  UTCTimeStr { unUTCTimeStr :: UTCTime }
  deriving (Eq, Show, Read, Generic, FromJSON, ToJSON)

instance PathPiece UTCTimeStr where
  toPathPiece (UTCTimeStr u) = pack (TI.formatISO8601Millis u)
  fromPathPiece s = UTCTimeStr <$> TI.parseISO8601 (unpack s)

newtype UserNameP =
  UserNameP { unUserNameP :: Text }
  deriving (Eq, Show, Read)

newtype TagsP =
  TagsP { unTagsP :: [Text] }
  deriving (Eq, Show, Read)

data SharedP
  = SharedAll
  | SharedPublic
  | SharedPrivate
  deriving (Eq, Show, Read)

data FilterP
  = FilterAll
  | FilterUnread
  | FilterUntagged
  | FilterStarred
  | FilterSingle BmSlug
  deriving (Eq, Show, Read)

newtype UnreadOnly =
  UnreadOnly { unUnreadOnly :: Bool }

  deriving (Eq, Show, Read)

type Limit = Int64
type Page = Int64

migrateAll :: Migration
migrateAll = migrateSchema >> migrateIndexes

dumpMigration :: DB ()
dumpMigration = printMigration migrateAll

runMigrations :: DB ()
runMigrations = runMigration migrateAll

toMigration :: [Text] -> Migration
toMigration = lift . tell . fmap (False ,)

migrateIndexes :: Migration
migrateIndexes =
  toMigration
    [ "CREATE INDEX IF NOT EXISTS idx_bookmark_time ON bookmark (user_id, time DESC)"
    , "CREATE INDEX IF NOT EXISTS idx_bookmark_tag_bookmark_id ON bookmark_tag (bookmark_id, id, tag, seq)"
    , "CREATE INDEX IF NOT EXISTS idx_note_user_created ON note (user_id, created DESC)"
    ]

sqlite_group_concat ::
     PersistField a
  => SqlExpr (E.Value a)
  -> SqlExpr (E.Value a)
  -> SqlExpr (E.Value Text)
sqlite_group_concat expr sep = E.unsafeSqlFunction "GROUP_CONCAT" [expr, sep]

authenticatePassword :: Text -> Text -> DB (Maybe (Entity User))
authenticatePassword username password = do
  muser <- getBy (UniqueUserName username)
  case muser of
    Nothing -> return Nothing
    Just dbuser ->
      if validatePasswordHash (userPasswordHash (entityVal dbuser)) password
        then return (Just dbuser)
        else return Nothing

getUserByName :: UserNameP -> DB (Maybe (Entity User))
getUserByName (UserNameP uname) = do
  selectFirst [UserName ==. uname] []

bookmarksQuery
  :: Key User
  -> SharedP
  -> FilterP
  -> [Tag]
  -> Maybe Text
  -> Limit
  -> Page
  -> DB (Int, [Entity Bookmark])
bookmarksQuery userId sharedp filterp tags mquery limit' page =
  (,) -- total count
  <$> fmap (sum . fmap E.unValue)
      (select $
      from $ \b -> do
      _whereClause b
      pure $ E.countRows)
      -- paged data
  <*> (select $
       from $ \b -> do
       _whereClause b
       orderBy [desc (b ^. BookmarkTime)]
       limit limit'
       offset ((page - 1) * limit')
       pure b)
  where
    _whereClause b = do
      where_ $
        foldl (\expr tag ->
                expr &&. (exists $   -- each tag becomes an exists constraint
                          from $ \t ->
                          where_ (t ^. BookmarkTagBookmarkId E.==. b ^. BookmarkId &&.
                                 (t ^. BookmarkTagTag `E.like` val tag))))
          (b ^. BookmarkUserId E.==. val userId)
          tags
      case sharedp of
        SharedAll -> pure ()
        SharedPublic ->  where_ (b ^. BookmarkShared E.==. val True)
        SharedPrivate -> where_ (b ^. BookmarkShared E.==. val False)
      case filterp of
        FilterAll -> pure ()
        FilterUnread -> where_ (b ^. BookmarkToRead E.==. val True)
        FilterStarred -> where_ (b ^. BookmarkSelected E.==. val True)
        FilterSingle slug -> where_ (b ^. BookmarkSlug E.==. val slug)
        FilterUntagged -> where_ $ notExists $ from (\t -> where_ $
                                                     (t ^. BookmarkTagBookmarkId E.==. b ^. BookmarkId))
      -- search
      sequenceA_ (parseSearchQuery (toLikeExpr b) =<< mquery)

    toLikeExpr :: E.SqlExpr (Entity Bookmark) -> Text -> E.SqlExpr (E.Value Bool)
    toLikeExpr b term = fromRight p_allFields (P.parseOnly p_onefield term)
      where
        wild s = (E.%) ++. val s ++. (E.%)
        toLikeB field s = b ^. field `E.like` wild s
        p_allFields =
          (toLikeB BookmarkHref term) ||.
          (toLikeB BookmarkDescription term) ||.
          (toLikeB BookmarkExtended term) ||.
          (exists $ from (\t -> where_ $
             (t ^. BookmarkTagBookmarkId E.==. b ^. BookmarkId) &&.
             (t ^. BookmarkTagTag `E.like` (wild term))))
        p_onefield = p_url <|> p_title <|> p_description <|> p_tags <|> p_after <|> p_before
          where
            p_url = "url:" *> fmap (toLikeB BookmarkHref) P.takeText
            p_title = "title:" *> fmap (toLikeB BookmarkDescription) P.takeText
            p_description = "description:" *> fmap (toLikeB BookmarkExtended) P.takeText
            p_tags = "tags:" *> fmap (\term' -> exists $ from (\t -> where_ $
                                                         (t ^. BookmarkTagBookmarkId E.==. b ^. BookmarkId) &&.
                                                         (t ^. BookmarkTagTag `E.like` wild term'))) P.takeText
            p_after  = "after:"  *> fmap ((b ^. BookmarkTime E.>=.) . val) (parseTimeText =<< P.takeText)
            p_before = "before:" *> fmap ((b ^. BookmarkTime E.<=.) . val) (parseTimeText =<< P.takeText)

parseSearchQuery ::
  (Text -> E.SqlExpr (E.Value Bool))
  -> Text
  -> Maybe (E.SqlQuery ())
parseSearchQuery toExpr =
  fmap where_ . either (const Nothing) Just . P.parseOnly andE
  where
    andE = foldl1 (&&.) <$> P.many1 (P.skipSpace *> orE <|> tokenTermE)
    orE = foldl1 (||.) <$> tokenTermE `P.sepBy1` P.char '|'
    tokenTermE = negE termE <|> termE
      where
        negE p = not_ <$> (P.char '-' *> p)
        termE = toExpr <$> (fieldTerm <|> quotedTerm <|> simpleTerm)
        fieldTerm = concat <$> sequence [simpleTerm, P.string ":", quotedTerm <|> simpleTerm]
        quotedTerm = PC.between (P.char '"') (P.char '"') (P.takeWhile1 (/= '"'))
        simpleTerm = P.takeWhile1 (\c -> not (isSpace c) && c /= ':' && c /= '|')

parseTimeText :: (TI.ParseTime t, Monad m, Alternative m) => Text -> m t
parseTimeText t =
  asum $
  flip (parseTimeM True defaultTimeLocale) (unpack t) <$>
  [ "%-m/%-d/%Y"    , "%-m/%-d/%Y%z"    , "%-m/%-d/%Y%Z"     -- 12/31/2018
  , "%Y-%-m-%-d"    , "%Y-%-m-%-d%z"    , "%Y-%-m-%-d%Z"     -- 2018-12-31
  , "%Y-%-m-%-dT%T" , "%Y-%-m-%-dT%T%z" , "%Y-%-m-%-dT%T%Z"  -- 2018-12-31T06:40:53
  , "%s"                                                     -- 1535932800
  ]

tagsQuery :: [Entity Bookmark] -> DB [Entity BookmarkTag]
tagsQuery bmarks =
  select $
  from $ \t -> do
  where_ (t ^. BookmarkTagBookmarkId `in_` valList (fmap entityKey bmarks))
  orderBy [asc (t ^. BookmarkTagSeq)]
  pure t

withTags :: Key Bookmark -> DB [Entity BookmarkTag]
withTags key = selectList [BookmarkTagBookmarkId ==. key] [Asc BookmarkTagSeq]

-- Note List Query


getNote :: Key User -> NtSlug -> DB (Maybe (Entity Note))
getNote userKey slug =
  selectFirst [NoteUserId ==. userKey, NoteSlug ==. slug] []

getNoteList :: Key User -> Maybe Text -> SharedP -> Limit -> Page -> DB (Int, [Entity Note])
getNoteList key mquery sharedp limit' page =
  (,) -- total count
  <$> fmap (sum . fmap E.unValue)
      (select $
      from $ \b -> do
      _whereClause b
      pure $ E.countRows)
  <*> (select $
       from $ \b -> do
       _whereClause b
       orderBy [desc (b ^. NoteCreated)]
       limit limit'
       offset ((page - 1) * limit')
       pure b)
  where
    _whereClause b = do
      where_ $ (b ^. NoteUserId E.==. val key)
      -- search
      sequenceA_ (parseSearchQuery (toLikeExpr b) =<< mquery)
      case sharedp of
        SharedAll -> pure ()
        SharedPublic ->  where_ (b ^. NoteShared E.==. val True)
        SharedPrivate -> where_ (b ^. NoteShared E.==. val False)

    toLikeExpr :: E.SqlExpr (Entity Note) -> Text -> E.SqlExpr (E.Value Bool)
    toLikeExpr b term = fromRight p_allFields (P.parseOnly p_onefield term)
      where
        wild s = (E.%) ++. val s ++. (E.%)
        toLikeN field s = b ^. field `E.like` wild s
        p_allFields = toLikeN NoteTitle term ||. toLikeN NoteText term
        p_onefield = p_title <|> p_text <|> p_after <|> p_before
          where
            p_title = "title:" *> fmap (toLikeN NoteTitle) P.takeText
            p_text = "description:" *> fmap (toLikeN NoteText) P.takeText
            p_after  = "after:"  *> fmap ((b ^. NoteCreated E.>=.) . val) (parseTimeText =<< P.takeText)
            p_before = "before:" *> fmap ((b ^. NoteCreated E.<=.) . val) (parseTimeText =<< P.takeText)

-- Bookmark Files

mkBookmarkTags :: Key User -> Key Bookmark -> [Tag] -> [BookmarkTag]
mkBookmarkTags userId bookmarkId tags =
  (\(i, tag) -> BookmarkTag userId tag bookmarkId i) <$> zip [1 ..] tags


fileBookmarkToBookmark :: UserId -> FileBookmark -> IO Bookmark
fileBookmarkToBookmark user (FileBookmark {..}) = do
  slug <- mkBmSlug
  pure $
    Bookmark
      user
      slug
      fileBookmarkHref
      fileBookmarkDescription
      fileBookmarkExtended
      fileBookmarkTime
      fileBookmarkShared
      fileBookmarkToRead
      (fromMaybe False fileBookmarkSelected)
      fileBookmarkArchiveHref

bookmarkTofileBookmark :: Bookmark -> Text -> FileBookmark
bookmarkTofileBookmark (Bookmark {..}) tags =
    FileBookmark
      bookmarkHref
      bookmarkDescription
      bookmarkExtended
      bookmarkTime
      bookmarkShared
      bookmarkToRead
      (Just bookmarkSelected)
      bookmarkArchiveHref
      tags


insertFileBookmarks :: Key User -> FilePath -> DB ()
insertFileBookmarks userId bookmarkFile = do
  mfmarks <- liftIO $ readFileBookmarks bookmarkFile
  case mfmarks of
    Left e -> print e
    Right fmarks -> do
      bmarks <- liftIO $ mapM (fileBookmarkToBookmark userId) fmarks
      mbids <- mapM insertUnique bmarks
      void $
        mapM insertUnique $
        concatMap (uncurry (mkBookmarkTags userId)) $
        catMaybes $
        zipWith
          (\mbid tags -> ((, tags) <$> mbid))
          mbids
          (extractTags <$> fmarks)
  where
    extractTags = words . fileBookmarkTags

readFileBookmarks :: MonadIO m => FilePath -> m (Either String [FileBookmark])
readFileBookmarks fpath =
  pure . A.eitherDecode' . fromStrict =<< readFile fpath

exportFileBookmarks :: Key User -> FilePath -> DB ()
exportFileBookmarks user fpath = do
    liftIO . A.encodeFile fpath =<< getFileBookmarks user

getFileBookmarks :: Key User -> DB [FileBookmark]
getFileBookmarks user = do
  marks <- allUserBookmarks user
  pure $ fmap (\(bm, t) -> bookmarkTofileBookmark (entityVal bm) t) marks

-- returns a list of pair of bookmark with tags merged into a string
allUserBookmarks :: Key User -> DB [(Entity Bookmark, Text)]
allUserBookmarks user = do
  bmarks <- bquery
  tags <- tquery
  let tagmap = MS.fromList tags
  pure $ (\bm@(Entity bid _) -> (bm, findWithDefault mempty bid tagmap)) <$> bmarks
  where
    bquery :: DB [Entity Bookmark]
    bquery =
      select $
      from $ \b -> do
        where_ (b ^. BookmarkUserId E.==. val user)
        orderBy [asc (b ^. BookmarkTime)]
        pure b
    tquery :: DB [(Key Bookmark, Text)]
    tquery =
      fmap (\(tid, tags) -> (E.unValue tid, E.unValue tags)) <$>
      (select $
       from $ \t -> do
         where_ (t ^. BookmarkTagUserId E.==. val user)
         E.groupBy (t ^. BookmarkTagBookmarkId)
         let tags = sqlite_group_concat (t ^. BookmarkTagTag) (E.val " ")
         pure (t ^. BookmarkTagBookmarkId, tags))

  
data TagCloudMode
  = TagCloudModeTop Bool Int          -- { mode: "top", value: 200 }
  | TagCloudModeLowerBound Bool Int   -- { mode: "lowerBound", value: 20 }
  | TagCloudModeRelated Bool [Tag]
  | TagCloudModeNone
  deriving (Show, Eq, Read, Generic)

instance FromJSON TagCloudMode where
  parseJSON (Object o) =
    case lookup "mode" o of
      Just (String "top") -> TagCloudModeTop <$> o .: "expanded" <*> o .: "value"
      Just (String "lowerBound") -> TagCloudModeLowerBound <$> o .: "expanded" <*> o .: "value"
      Just (String "related") -> TagCloudModeRelated <$> o .: "expanded" <*> (fmap words (o .: "value"))
      Just (String "none") -> pure TagCloudModeNone
      _ -> fail "bad parse"
  parseJSON _ = fail "bad parse"

instance ToJSON TagCloudMode where
  toJSON (TagCloudModeTop e i) =
    object [ "mode" .= String "top"
           , "value" .= toJSON i
           , "expanded" .= Bool e
           ]
  toJSON (TagCloudModeLowerBound e i) =
    object [ "mode" .= String "lowerBound"
           , "value" .= toJSON i
           , "expanded" .= Bool e
           ]
  toJSON (TagCloudModeRelated e tags) =
    object [ "mode" .= String "related"
           , "value" .= String (unwords tags)
           , "expanded" .= Bool e
           ]
  toJSON TagCloudModeNone =
    object [ "mode" .= String "none"
           , "value" .= Null
           , "expanded" .= Bool False
           ]
    
  
type Tag = Text

tagCountTop :: Key User -> Int -> DB [(Text, Int)]
tagCountTop user top = 
    sortOn (toLower . fst) .
    fmap (\(tname, tcount) -> (E.unValue tname, E.unValue tcount)) <$>
    ( select $
      from $ \t -> do
      where_ (t ^. BookmarkTagUserId E.==. val user)
      E.groupBy (E.lower_ $ t ^. BookmarkTagTag)
      let countRows' = E.countRows
      E.orderBy [E.desc countRows'] 
      E.limit ((fromIntegral . toInteger) top)
      pure $ (t ^. BookmarkTagTag, countRows')
    )

tagCountLowerBound :: Key User -> Int -> DB [(Text, Int)]
tagCountLowerBound user lowerBound = 
    fmap (\(tname, tcount) -> (E.unValue tname, E.unValue tcount)) <$>
    ( select $
      from $ \t -> do
      where_ (t ^. BookmarkTagUserId E.==. val user)
      E.groupBy (E.lower_ $ t ^. BookmarkTagTag)
      let countRows' = E.countRows
      E.orderBy [E.asc (t ^. BookmarkTagTag)]
      E.having (countRows' E.>=. E.val lowerBound)
      pure $ (t ^. BookmarkTagTag, countRows')
    )

-- Notes

fileNoteToNote :: UserId -> FileNote -> IO Note
fileNoteToNote user (FileNote {..} ) = do
  slug <- mkNtSlug
  pure $
    Note
      user
      slug
      fileNoteLength
      fileNoteTitle
      fileNoteText
      False
      False
      fileNoteCreatedAt
      fileNoteUpdatedAt

insertDirFileNotes :: Key User -> FilePath -> DB ()
insertDirFileNotes userId noteDirectory = do
  mfnotes <- liftIO $ readFileNotes noteDirectory
  case mfnotes of
      Left e -> print e
      Right fnotes -> do
        notes <- liftIO $ mapM (fileNoteToNote userId) fnotes
        void $ mapM insertUnique notes
  where
    readFileNotes :: MonadIO m => FilePath -> m (Either String [FileNote])
    readFileNotes fdir = do
      files <- liftIO (listDirectory fdir)
      noteBSS <- mapM (readFile . (fdir </>)) files
      pure (mapM (A.eitherDecode' . fromStrict) noteBSS)

-- AccountSettingsForm
data AccountSettingsForm = AccountSettingsForm
  { _privateDefault :: Bool
  , _archiveDefault :: Bool
  , _privacyLock :: Bool
  } deriving (Show, Eq, Read, Generic)

instance FromJSON AccountSettingsForm where parseJSON = A.genericParseJSON gDefaultFormOptions
instance ToJSON AccountSettingsForm where toJSON = A.genericToJSON gDefaultFormOptions

toAccountSettingsForm :: User -> AccountSettingsForm
toAccountSettingsForm (User {..}) =
  AccountSettingsForm
  { _privateDefault = userPrivateDefault
  , _archiveDefault = userArchiveDefault
  , _privacyLock = userPrivacyLock
  }

updateUserFromAccountSettingsForm :: Key User -> AccountSettingsForm -> DB ()
updateUserFromAccountSettingsForm userId (AccountSettingsForm {..}) = do
  CP.update userId
    [ UserPrivateDefault CP.=. _privateDefault
    , UserArchiveDefault CP.=. _archiveDefault
    , UserPrivacyLock CP.=. _privacyLock
    ]

-- BookmarkForm

data BookmarkForm = BookmarkForm
  { _url :: Text
  , _title :: Maybe Text
  , _description :: Maybe Textarea
  , _tags :: Maybe Text
  , _private :: Maybe Bool
  , _toread :: Maybe Bool
  , _bid :: Maybe Int64
  , _slug :: Maybe BmSlug
  , _selected :: Maybe Bool
  , _time :: Maybe UTCTimeStr
  , _archiveUrl :: Maybe Text
  } deriving (Show, Eq, Read, Generic)

instance FromJSON BookmarkForm where parseJSON = A.genericParseJSON gDefaultFormOptions
instance ToJSON BookmarkForm where toJSON = A.genericToJSON gDefaultFormOptions

gDefaultFormOptions :: A.Options
gDefaultFormOptions = A.defaultOptions { A.fieldLabelModifier = drop 1 }

toBookmarkFormList :: [Entity Bookmark] -> [Entity BookmarkTag] -> [BookmarkForm]
toBookmarkFormList bs as = do
  b <- bs
  let bid = E.entityKey b
  let btags = filter ((==) bid . bookmarkTagBookmarkId . E.entityVal) as
  pure $ _toBookmarkForm (b, btags)

_toBookmarkForm :: (Entity Bookmark, [Entity BookmarkTag]) -> BookmarkForm
_toBookmarkForm (Entity bid Bookmark {..}, tags) =
  BookmarkForm
  { _url = bookmarkHref
  , _title = Just bookmarkDescription
  , _description = Just $ Textarea $ bookmarkExtended
  , _tags = Just $ unwords $ fmap (bookmarkTagTag . entityVal) tags
  , _private = Just $ not bookmarkShared
  , _toread = Just $ bookmarkToRead
  , _bid = Just $ unBookmarkKey $ bid
  , _slug = Just $ bookmarkSlug
  , _selected = Just $ bookmarkSelected
  , _time = Just $ UTCTimeStr $ bookmarkTime
  , _archiveUrl = bookmarkArchiveHref
  }

_toBookmark :: UserId -> BookmarkForm -> IO Bookmark
_toBookmark userId BookmarkForm {..} = do
  time <- liftIO getCurrentTime
  slug <- maybe mkBmSlug pure _slug
  pure $
    Bookmark
      userId
      slug
      _url
      (fromMaybe "" _title)
      (maybe "" unTextarea _description)
      (fromMaybe time (fmap unUTCTimeStr _time))
      (maybe True not _private)
      (fromMaybe False _toread)
      (fromMaybe False _selected)
      _archiveUrl

fetchBookmarkByUrl :: Key User -> Maybe Text -> DB (Maybe (Entity Bookmark, [Entity BookmarkTag]))
fetchBookmarkByUrl userId murl = runMaybeT $ do
  bmark <- MaybeT . getBy . UniqueUserHref userId =<< (MaybeT $ pure murl)
  btags <- lift $ withTags (entityKey bmark)
  pure (bmark, btags)

data UpsertResult = Created | Updated

upsertBookmark :: Key User -> Maybe (Key Bookmark) -> Bookmark -> [Text] -> DB (UpsertResult, Key Bookmark)
upsertBookmark userId mbid bm tags = do
  res <- case mbid of
    Just bid -> do
      get bid >>= \case
        Just prev_bm -> do
          when (userId /= bookmarkUserId prev_bm)
            (fail "unauthorized")
          replaceBookmark bid prev_bm
        _ -> fail "not found"
    Nothing -> do
      getBy (UniqueUserHref (bookmarkUserId bm) (bookmarkHref bm)) >>= \case
        Just (Entity bid prev_bm) -> replaceBookmark bid prev_bm
        _ -> (Created,) <$> insert bm
  insertTags (bookmarkUserId bm) (snd res)
  pure res
  where
    prepareReplace prev_bm = do
      if (bookmarkHref bm /= bookmarkHref prev_bm)
        then bm { bookmarkArchiveHref = Nothing }
        else bm { bookmarkArchiveHref = bookmarkArchiveHref prev_bm }
    replaceBookmark bid prev_bm = do
      replace bid (prepareReplace prev_bm)
      deleteTags bid
      pure (Updated, bid)
    deleteTags bid =
      deleteWhere [BookmarkTagBookmarkId ==. bid]
    insertTags userId' bid' =
      for_ (zip [1 ..] tags) $
      \(i, tag) -> void $ insert $ BookmarkTag userId' tag bid' i

updateBookmarkArchiveUrl :: Key User -> Key Bookmark -> Maybe Text -> DB ()
updateBookmarkArchiveUrl userId bid marchiveUrl = do
  updateWhere
    [BookmarkUserId ==. userId, BookmarkId ==. bid]
    [BookmarkArchiveHref CP.=. marchiveUrl]

upsertNote :: Key User -> Maybe (Key Note) -> Note -> DB (UpsertResult, Key Note)
upsertNote userId mnid note = do
  case mnid of
    Just nid -> do
      get nid >>= \case
        Just note' -> do
          when (userId /= (noteUserId note'))
            (fail "unauthorized")
          replace nid note
          pure (Updated, nid)
        _ -> fail "not found"
    Nothing -> do
      (Created,) <$> insert note

-- * FileBookmarks

data FileBookmark = FileBookmark
  { fileBookmarkHref :: !Text
  , fileBookmarkDescription :: !Text
  , fileBookmarkExtended :: !Text
  , fileBookmarkTime :: !UTCTime
  , fileBookmarkShared :: !Bool
  , fileBookmarkToRead :: !Bool
  , fileBookmarkSelected :: !(Maybe Bool)
  , fileBookmarkArchiveHref :: !(Maybe Text)
  , fileBookmarkTags :: !Text
  } deriving (Show, Eq, Typeable, Ord)

instance FromJSON FileBookmark where
  parseJSON (Object o) =
    FileBookmark <$> o .: "href" <*> o .: "description" <*> o .: "extended" <*>
    o .: "time" <*>
    (boolFromYesNo <$> o .: "shared") <*>
    (boolFromYesNo <$> o .: "toread") <*>
    (o A..:? "selected") <*>
    (o A..:? "archive_url") <*>
    (o .: "tags")
  parseJSON _ = fail "bad parse"

instance ToJSON FileBookmark where
  toJSON (FileBookmark {..}) =
    object
      [ "href" .= toJSON fileBookmarkHref
      , "description" .= toJSON fileBookmarkDescription
      , "extended" .= toJSON fileBookmarkExtended
      , "time" .= toJSON fileBookmarkTime
      , "shared" .= toJSON (boolToYesNo fileBookmarkShared)
      , "toread" .= toJSON (boolToYesNo fileBookmarkToRead)
      , "selected" .= toJSON fileBookmarkSelected
      , "archive_url" .= toJSON fileBookmarkArchiveHref
      , "tags" .= toJSON fileBookmarkTags
      ]

boolFromYesNo :: Text -> Bool
boolFromYesNo "yes" = True
boolFromYesNo _ = False

boolToYesNo :: Bool -> Text
boolToYesNo True = "yes"
boolToYesNo _ = "no"

-- * FileNotes

data FileNote = FileNote
  { fileNoteId :: !Text
  , fileNoteTitle :: !Text
  , fileNoteText :: !Text
  , fileNoteLength :: !Int
  , fileNoteCreatedAt :: !UTCTime
  , fileNoteUpdatedAt :: !UTCTime
  } deriving (Show, Eq, Typeable, Ord)

instance FromJSON FileNote where
  parseJSON (Object o) =
    FileNote <$> o .: "id" <*> o .: "title" <*> o .: "text" <*>
    o .: "length" <*>
    (readFileNoteTime =<< o .: "created_at") <*>
    (readFileNoteTime =<< o .: "updated_at")
  parseJSON _ = fail "bad parse"

instance ToJSON FileNote where
  toJSON (FileNote {..}) =
    object
      [ "id" .= toJSON fileNoteId
      , "title" .= toJSON fileNoteTitle
      , "text" .= toJSON fileNoteText
      , "length" .= toJSON fileNoteLength
      , "created_at" .= toJSON (showFileNoteTime fileNoteCreatedAt)
      , "updated_at" .= toJSON (showFileNoteTime fileNoteUpdatedAt)
      ]

readFileNoteTime
  :: Monad m
  => String -> m UTCTime
readFileNoteTime = parseTimeM True defaultTimeLocale "%F %T"

showFileNoteTime :: UTCTime -> String
showFileNoteTime = formatTime defaultTimeLocale "%F %T"
