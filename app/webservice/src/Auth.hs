{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE TypeFamilies              #-}

module Auth (
    getAuthenticatedUser
  , getAuthenticatedUserByToken
  , getBuildStatuses
  , logoutH
  , callbackH
  , githubAuthTokenSessionKey
  ) where


import           Control.Lens               hiding ((<.>))
import           Control.Monad
import           Control.Monad.Error.Class
import           Control.Monad.IO.Class     (liftIO)
import           Control.Monad.Trans.Except (ExceptT (ExceptT), except,
                                             runExceptT)
import           Data.Aeson.Lens            (key, _Array, _Integer, _Integral,
                                             _Value)
import           Data.Aeson.Types           (FromJSON, Value, parseEither,
                                             parseJSON)
import           Data.Bifunctor
import qualified Data.ByteString.Char8      as BSU
import qualified Data.ByteString.Lazy       as LBS
import qualified Data.Either                as Either
import           Data.List                  (intercalate)
import           Data.Maybe
import qualified Data.Text                  as T
import qualified Data.Text.Lazy             as TL
import qualified Data.Vault.Lazy            as Vault
import qualified Data.Vector                as V
import           Network.HTTP.Conduit       hiding (Request)
import qualified Network.OAuth.OAuth2       as OAuth2
import           Network.Wai                (Request, vault)
import           Network.Wai.Session        (Session)
import           Prelude
import           URI.ByteString             (parseURI, strictURIParserOptions)
import           Web.Scotty
import           Web.Scotty.Internal.Types

import qualified AuthConfig
import qualified AuthStages
import qualified DbHelpers
import qualified Github
import           Session
import           SillyMonoids               ()
import qualified StatusEventQuery
import           Types
import           Utils
import qualified Webhooks


perPageCount :: Int
perPageCount = 100


targetOrganization :: T.Text
targetOrganization = "pytorch"


githubAuthTokenSessionKey :: String
githubAuthTokenSessionKey = "github_api_token"


wrap_login_err login_url = AuthStages.AuthFailure . AuthStages.AuthenticationFailure (Just $ AuthStages.LoginUrl login_url)


getAuthenticatedUserByToken ::
     String -- ^ token
  -> AuthConfig.GithubConfig
  -> (AuthStages.Username -> IO (Either a b))
  -> IO (Either (AuthStages.BackendFailure a) b)
getAuthenticatedUserByToken api_token github_config callback = do

  mgr <- newManager tlsManagerSettings
  let wrapped_token = OAuth2.AccessToken $ T.pack api_token
      api_support_data = GitHubApiSupport mgr wrapped_token

  runExceptT $ do
    Types.LoginUser _login_name login_alias <- ExceptT $
      (first $ const (wrap_login_err login_url AuthStages.FailUsernameDetermination)) <$> Auth.fetchUser api_support_data

    let username_text = TL.toStrict login_alias
    is_org_member <- ExceptT $ do
      either_membership <- isOrgMember (AuthConfig.personal_access_token github_config) username_text
      return $ first (wrap_login_err login_url) either_membership

    unless is_org_member $ except $
      Left $ AuthStages.AuthFailure $ AuthStages.AuthenticationFailure (Just $ AuthStages.LoginUrl login_url)
        $ AuthStages.FailOrgMembership (AuthStages.Username username_text) Auth.targetOrganization

    ExceptT $ fmap (first AuthStages.DbFailure) $
      callback $ AuthStages.Username username_text

  where
    login_url = AuthConfig.getLoginUrl github_config


getAuthenticatedUser ::
     Request
  -> Vault.Key (Session IO String String)
  -> AuthConfig.GithubConfig
  -> (AuthStages.Username -> IO (Either a b))
  -> IO (Either (AuthStages.BackendFailure a) b)
getAuthenticatedUser rq session github_config callback = do

  u <- sessionLookup githubAuthTokenSessionKey
  case u of
    Nothing -> return $ Left $ wrap_login_err login_url AuthStages.FailLoginRequired
    Just api_token -> getAuthenticatedUserByToken api_token github_config callback

  where
    Just (sessionLookup, _sessionInsert) = Vault.lookup session $ vault rq
    login_url = AuthConfig.getLoginUrl github_config


redirectToHomeM :: ActionM ()
redirectToHomeM = redirect "/"


errorM :: TL.Text -> ActionM ()
errorM = throwError . ActionError


logoutH :: CacheStore -> ActionM ()
logoutH c = do
  pas <- params
  let idpP = paramValue "idp" pas
  when (null idpP) redirectToHomeM
  let idp = Github.Github
  liftIO (removeKey c (idpLabel idp)) >> redirectToHomeM


callbackH :: CacheStore -> AuthConfig.GithubConfig -> (String -> IO ()) -> ActionT TL.Text IO ()
callbackH c github_config session_insert = do
  pas <- params
  let codeP = paramValue "code" pas
      stateP = paramValue "state" pas
  when (null codeP) $ errorM "callbackH: no code from callback request"
  when (null stateP) $ errorM "callbackH: no state from callback request"

  fetchTokenAndUser c github_config (head codeP) session_insert


fetchTokenAndUser :: CacheStore
                  -> AuthConfig.GithubConfig
                  -> TL.Text           -- ^ code
                  -> (String -> IO ())
                  -> ActionM ()
fetchTokenAndUser c github_config code session_insert = do
  maybeIdpData <- lookIdp c idp

  case maybeIdpData of
    Nothing -> errorM "fetchTokenAndUser: cannot find idp data from cache"
    Just idpData -> do

      result <- liftIO $ tryFetchUser github_config code session_insert

      case result of
        Right luser -> updateIdp c idpData luser >> redirectToHomeM
        Left err    -> errorM $ "fetchTokenAndUser: " `TL.append` err

  where lookIdp c1 idp1 = liftIO $ lookupKey c1 (idpLabel idp1)
        updateIdp c1 oldIdpData luser = liftIO $ insertIDPData c1 (oldIdpData {loginUser = Just luser })
        idp = Github.Github


data GitHubApiSupport = GitHubApiSupport {
    tls_manager  :: Manager
  , access_token :: OAuth2.AccessToken
  }


tryFetchUser ::
     AuthConfig.GithubConfig
  -> TL.Text           -- ^ code
  -> (String -> IO ())
  -> IO (Either TL.Text LoginUser)
tryFetchUser github_config code session_insert = do
  mgr <- newManager tlsManagerSettings
  token <- OAuth2.fetchAccessToken mgr (AuthConfig.githubKey github_config) (OAuth2.ExchangeToken $ TL.toStrict code)

  case token of
    Right at -> do
      let access_token_object = OAuth2.accessToken at
          access_token_string = T.unpack $ OAuth2.atoken access_token_object

      liftIO $ session_insert access_token_string
      fetchUser $ GitHubApiSupport mgr access_token_object

    Left e   -> return $ Left $ TL.pack $ "tryFetchUser: cannot fetch asses token. error detail: " ++ show e


recursePaginated :: FromJSON a =>
     Manager
  -> T.Text
  -> String
  -> T.Text
  -> Int
  -> [a]
  -> IO (Either TL.Text [a])
recursePaginated
    mgr
    token
    uri_prefix
    field_accessor
    page_offset
    old_retrieved_items = do

  putStrLn $ "Querying URL for build statuses: " ++ uri_string

  runExceptT $ do

    uri <- except $ first (const $ "Bad URL: " <> TL.pack uri_string) either_uri

    r <- ExceptT ((fmap (first displayOAuth2Error) $ OAuth2.authGetJSON mgr (OAuth2.AccessToken token) uri) :: IO (Either TL.Text Value))

    let subval = r ^. key field_accessor . _Array

    newly_retrieved_items <- except $ first TL.pack $ mapM (parseEither parseJSON) $ V.toList subval

    let expected_count = r ^. key "total_count" . _Integral
        combined_list = old_retrieved_items ++ newly_retrieved_items

    if length combined_list < expected_count
      then ExceptT $ recursePaginated
        mgr
        token
        uri_prefix
        field_accessor
        (page_offset + 1)
        combined_list
      else return combined_list

  where
    either_uri = parseURI strictURIParserOptions $ BSU.pack uri_string
    uri_string = uri_prefix <> "?per_page=" <> show perPageCount <> "&page=" <> show page_offset


-- | Recursively calls the GitHub API
getCommitsRecurse :: FromJSON a =>
     Manager
  -> T.Text
  -> T.Text  -- ^ starting commit
  -> T.Text  -- ^ last known commit (stopping commit)
  -> [a]
  -> IO (Either TL.Text [a])
getCommitsRecurse
    mgr
    token
    uri_prefix
    old_retrieved_items = do

xxxx
  
  -- TODO
  return []
  where
    either_uri = parseURI strictURIParserOptions $ BSU.pack uri_string

    uri_string = uri_prefix
      <> "?per_page=" <> show perPageCount
      <> "&sha=" <> show perPageCount


getCommits ::
     T.Text -- ^ token
  -> DbHelpers.OwnerAndRepo
  -> T.Text  -- ^ starting commit
  -> T.Text  -- ^ last known commit (stopping commit)
  -> IO (Either TL.Text [StatusEventQuery.GitHubStatusEventGetter])
getCommits
    token
    (DbHelpers.OwnerAndRepo repo_owner repo_name)
    target_sha1
    stopping_sha1 = do

  mgr <- newManager tlsManagerSettings

  either_items <- getCommitsRecurse
    mgr
    token
    uri_prefix
    stopping_sha1

  return either_items
  where
    uri_prefix = intercalate "/" [
        "https://api.github.com/repos"
      , repo_owner
      , repo_name
      , "commits"
      ]


getBuildStatuses ::
     T.Text
  -> DbHelpers.OwnerAndRepo
  -> T.Text
  -> IO (Either TL.Text [StatusEventQuery.GitHubStatusEventGetter])
getBuildStatuses
    token
    (DbHelpers.OwnerAndRepo repo_owner repo_name)
    target_sha1 = do

  mgr <- newManager tlsManagerSettings

  either_items <- recursePaginated
    mgr
    token
    uri_prefix
    "statuses"
    1
    []

  return either_items
  where
    uri_prefix = intercalate "/" [
        "https://api.github.com/repos"
      , repo_owner
      , repo_name
      , "commits"
      , T.unpack target_sha1
      , "status"
      ]


fetchUser :: GitHubApiSupport -> IO (Either TL.Text LoginUser)
fetchUser (GitHubApiSupport mgr token) = do
  re <- do
    r <- OAuth2.authGetJSON mgr token Github.userInfoUri
    return $ second Github.toLoginUser r

  return (first displayOAuth2Error re)


displayOAuth2Error :: OAuth2.OAuth2Error Errors -> TL.Text
displayOAuth2Error = TL.pack . show


-- | The Github API for this returns an empty response, using
-- status codes 204 or 404 to represent success or failure, respectively.
isOrgMemberInner :: OAuth2.OAuth2Result TL.Text LBS.ByteString -> Bool
isOrgMemberInner either_response = case either_response of
  Left (OAuth2.OAuth2Error _either_parsed_err _maybe_description _maybe_uri) -> False
  Right _ -> True


-- | Alternate (user-centric) API endpoint is:
-- https://developer.github.com/v3/orgs/members/#get-your-organization-membership
isOrgMember :: T.Text -> T.Text -> IO (Either AuthStages.AuthenticationFailureStageInfo Bool)
isOrgMember personal_access_token username = do
  mgr <- newManager tlsManagerSettings

  -- Note: This query is currently using a Personal Access Token from a pytorch org member.
  -- TODO This must be converted to an App token.
  let api_support_data = GitHubApiSupport mgr wrapped_token

  case either_membership_query_uri of
    Left x -> return $ Left $ AuthStages.FailMembershipDetermination $ "Bad URL: " <> url_string
    Right membership_query_uri -> do
      either_response <- OAuth2.authGetBS mgr wrapped_token membership_query_uri
      return $ Right $ isOrgMemberInner either_response

  where
    wrapped_token = OAuth2.AccessToken personal_access_token
    url_string = "https://api.github.com/orgs/" <> targetOrganization <> "/members/" <> username
    either_membership_query_uri = parseURI strictURIParserOptions $ BSU.pack $ T.unpack url_string
