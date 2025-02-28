{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE QuasiQuotes #-}

module Main where

import Options.Applicative hiding (empty)
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Text.Hex as H
import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString.Builder as BS
import qualified Data.Vector as V
import qualified Data.ByteString.Base64.Lazy as Base64
import Control.Monad.Trans
import Control.Monad.Trans.State
import Codec.CBOR.Term
import Codec.CBOR.Read
import Data.Proxy
import Data.Bifunctor
import Data.Word
import Control.Monad.Random.Lazy
import Data.Time.Clock.POSIX
import Text.Printf
import Text.Regex.TDFA ((=~~))

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.Ingredients
import Test.Tasty.Ingredients.Basic
import Test.Tasty.Ingredients.Rerun
import Test.Tasty.Runners.AntXML
import Test.Tasty.Options
import Test.Tasty.Runners.Html

import GHC.TypeLits (KnownSymbol, symbolVal)
import Data.Row (empty, (.==), (.+), type (.!), (.!), Label, AllUniqueLabels, Var)
import Codec.Candid (Principal(..))
import qualified Codec.Candid as Candid
import qualified Data.Row.Variants as V

import IC.Types
import IC.Ref
import IC.Management
import IC.Hash
import IC.Crypto
import IC.Id.Forms hiding (Blob)
import IC.HTTP.GenR
import IC.HTTP.RequestId
import IC.Certificate hiding (Delegation)
import IC.Certificate.CBOR
import IC.Certificate.Validate
import IC.HashTree hiding (Blob, Hash, Label)
import IC.HashTree.CBOR

import Prometheus hiding (Timestamp)

-- We cannot do
-- type IIInterface m = [Candid.candidFile|../src/internet_identity/internet_identity.did|]
-- just yet, because haskell-candid doesn’t like init arguments to service, so
-- for now we have to copy it
type IIInterface m = [Candid.candid|
type UserNumber = nat64;
type PublicKey = blob;
type CredentialId = blob;
type DeviceAlias = text;
type DeviceKey = PublicKey;
type UserKey = PublicKey;
type SessionKey = PublicKey;
type FrontendHostname = text;
type Timestamp = nat64;
type Purpose = variant {
    recovery;
    authentication;
};
type KeyType = variant {
    unknown;
    platform;
    cross_platform;
    seed_phrase;
};

type DeviceData = record {
  pubkey : DeviceKey;
  alias : text;
  credential_id : opt CredentialId;
  purpose : Purpose;
  key_type : KeyType;
};

type RegisterResponse = variant {
  registered: record { user_number: UserNumber; };
  canister_full;
};

type Delegation = record {
  pubkey: SessionKey;
  expiration: Timestamp;
  targets: opt vec principal;
};
type SignedDelegation = record {
  delegation: Delegation;
  signature: blob;
};
type GetDelegationResponse = variant {
  signed_delegation: SignedDelegation;
  no_such_delegation;
};

type InternetIdentityStats = record {
  users_registered: nat64;
  assigned_user_number_range: record { nat64; nat64; };
};

type ProofOfWork = record {
  timestamp : Timestamp;
  nonce : nat64;
};

type HeaderField = record { text; text; };

type HttpRequest = record {
  method: text;
  url: text;
  headers: vec HeaderField;
  body: blob;
};

type HttpResponse = record {
  status_code: nat16;
  headers: vec HeaderField;
  body: blob;
  streaming_strategy: opt StreamingStrategy;
};

type StreamingCallbackHttpResponse = record {
  body: blob;
  token: opt Token;
};

type Token = record {};

type StreamingStrategy = variant {
  Callback: record {
    callback: func (Token) -> (StreamingCallbackHttpResponse) query;
    token: Token;
  };
};
service : {
  register : (DeviceData, ProofOfWork) -> (RegisterResponse);
  add : (UserNumber, DeviceData) -> ();
  remove : (UserNumber, DeviceKey) -> ();
  lookup : (UserNumber) -> (vec DeviceData) query;
  get_principal : (UserNumber, FrontendHostname) -> (principal) query;
  stats : () -> (InternetIdentityStats) query;

  prepare_delegation : (UserNumber, FrontendHostname, SessionKey, opt nat64) -> (UserKey, Timestamp);
  get_delegation: (UserNumber, FrontendHostname, SessionKey, Timestamp) -> (GetDelegationResponse) query;

  http_request: (request: HttpRequest) -> (HttpResponse) query;
}
  |]

-- Names for some of these types. Unfortunately requires copying

type DeviceData = [Candid.candidType|
record {
  pubkey : blob;
  alias : text;
  credential_id : opt blob;
  purpose: variant {
    recovery;
    authentication;
  };
  key_type: variant {
    unknown;
    platform;
    cross_platform;
    seed_phrase;
  };
}
  |]

type RegisterResponse = [Candid.candidType|
variant {
  registered: record { user_number: nat64; };
  canister_full;
}
  |]


type SignedDelegation = [Candid.candidType|
record {
  delegation:
    record {
      pubkey: blob;
      expiration: nat64;
      targets: opt vec principal;
    };
  signature: blob;
}
  |]

type Delegation = [Candid.candidType|
  record {
    pubkey: blob;
    expiration: nat64;
    targets: opt vec principal;
  }
  |]


type InitCandid = [Candid.candidType|
  record {
    assigned_user_number_range : record { nat64; nat64; };
  }
  |]

type ProofOfWork = [Candid.candidType|record {
  timestamp : nat64;
  nonce : nat64;
}|]

type HttpRequest = [Candid.candidType|record {
  method : text;
  url : text;
  headers : vec record { text; text; };
  body : blob;
}|]

type HttpResponse = [Candid.candidType|record {
  status_code : nat16;
  headers : vec record { text; text; };
  body : blob;
  streaming_strategy : opt variant { Callback: record { token: record {}; callback: func (record {}) -> (record { body: blob; token: record {}; }) query; }; };
}|]

mkPOW :: Word64 -> Word64 -> ProofOfWork
mkPOW t n = #timestamp .== t .+ #nonce .== n

httpGet :: String -> HttpRequest
httpGet url = #method .== T.pack "GET"
  .+ #url .== T.pack url
  .+ #headers .== V.empty
  .+ #body .== ""

type Hash = Blob

delegationHash :: Delegation -> Hash
delegationHash d = requestId $ rec $
  [ "pubkey" =: GBlob (d .! #pubkey)
  , "expiration" =: GNat (fromIntegral (d .! #expiration))
  ] ++
  [ "targets" =: GList [ GBlob b | Candid.Principal b <- V.toList ts ]
  | Just ts <- pure $ d .! #targets
  ]


type M = StateT IC IO

dummyUserId :: CanisterId
dummyUserId = EntityId $ BS.pack [0xCA, 0xFF, 0xEE]

controllerId :: CanisterId
controllerId = EntityId "I am the controller"

shorten :: Int -> String -> String
shorten n s = a ++ (if null b then "" else "…")
  where (a,b) = splitAt n s


submitAndRun :: CallRequest -> M CallResponse
submitAndRun r = do
    rid <- lift mkRequestId
    submitRequest rid r
    runToCompletion
    r <- gets (snd . (M.! rid) . requests)
    case r of
      CallResponse r -> return r
      _ -> lift $ assertFailure $ "submitRequest: request status is still " <> show r

submitQuery :: QueryRequest -> M CallResponse
submitQuery r = do
    t <- getTimestamp
    QueryResponse r <- handleQuery t r
    return r

getTimestamp :: M Timestamp
getTimestamp = lift $ do
    t <- getPOSIXTime
    return $ Timestamp $ round (t * 1000_000_000)

mkRequestId :: IO RequestID
mkRequestId = BS.toLazyByteString . BS.word64BE <$> randomIO

setCanisterTimeTo :: Blob -> Timestamp -> M ()
setCanisterTimeTo cid new_time =
 modify $
  \ic -> ic { canisters = M.adjust (\cs -> cs { time = new_time }) (EntityId cid) (canisters ic) }


callManagement :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (ICManagement IO .! s) =>
  Candid.CandidArg a =>
  Candid.CandidArg b =>
  EntityId -> Label s -> a -> M b
callManagement user_id l x = do
  r <- submitAndRun $
    CallRequest (EntityId mempty) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected (_code, msg) -> lift $ assertFailure $ "Management call got rejected:\n" <> msg
    Replied b -> case Candid.decode b of
      Left err -> lift $ assertFailure err
      Right y -> return y

queryII :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  Candid.CandidArg b =>
  BS.ByteString -> EntityId -> Label s -> a -> M b
queryII cid user_id l x = do
  r <- submitQuery $ QueryRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected (_code, msg) -> lift $ assertFailure $ "II query got rejected:\n" <> msg
    Replied b -> case Candid.decode b of
      Left err -> lift $ assertFailure err
      Right y -> return y

queryIIReject :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  BS.ByteString -> EntityId -> Label s -> a -> M ()
queryIIReject cid user_id l x = do
  r <- submitQuery $ QueryRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected _ -> return ()
    Replied _ -> lift $ assertFailure "queryIIReject: Unexpected reply"

callII :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  Candid.CandidArg b =>
  BS.ByteString -> EntityId -> Label s -> a -> M b
callII cid user_id l x = do
  r <- submitAndRun $ CallRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected (_code, msg) -> lift $ assertFailure $ "II call got rejected:\n" <> msg
    Replied b -> case Candid.decode b of
      Left err -> lift $ assertFailure err
      Right y -> return y

callIIReject :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  BS.ByteString -> EntityId -> Label s -> a -> M ()
callIIReject cid user_id l x = do
  r <- submitAndRun $
    CallRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected _ -> return ()
    Replied _ -> lift $ assertFailure "callIIReject: Unexpected reply"


-- Some common devices
webauthSK :: SecretKey
webauthSK = createSecretKeyWebAuthn "foobar"
webauthPK :: PublicKey
webauthPK = toPublicKey webauthSK
webauthID :: EntityId
webauthID = EntityId $ mkSelfAuthenticatingId webauthPK
device1 :: DeviceData
device1 = empty
    .+ #alias .== "device1"
    .+ #pubkey .== webauthPK
    .+ #credential_id .== Nothing
    .+ #purpose .== enum #authentication
    .+ #key_type .== enum #cross_platform

webauth2SK :: SecretKey
webauth2SK = createSecretKeyWebAuthn "foobar2"
webauth2PK = toPublicKey webauth2SK
webauth2PK :: PublicKey
webauth2ID :: EntityId
webauth2ID = EntityId $ mkSelfAuthenticatingId webauth2PK
device2 :: DeviceData
device2 = empty
    .+ #alias .== "device2"
    .+ #pubkey .== webauth2PK
    .+ #credential_id .== Just "foobar"
    .+ #purpose .== enum #authentication
    .+ #key_type .== enum #platform

-- Various proof of work values
invalidPOW :: ProofOfWork
invalidPOW = mkPOW 0 0

-- Hardcoded solutions for the POW puzzle
powNonceAt :: Blob -> Word64 -> Word64
powNonceAt "\NUL\EOT\NUL\NUL\NUL\NUL\NUL\NUL\SOH" 0 = 57583
powNonceAt "\NUL\EOT\NUL\NUL\NUL\NUL\NUL\NUL\SOH" 1 = 40219
powNonceAt "\NUL\EOT\NUL\NUL\NUL\NUL\NUL\NUL\SOH" 1200000000000 = 104906
powNonceAt cid ts = error $ printf
    "No proof of work on record. Please run\nnpx ts-node pow.ts %s %d\nand add to this table as\npowNonceAt %s %d = <paste number here>"
    (asHex cid) ts
    (show cid) ts

powAt ::  Blob -> Word64 -> ProofOfWork
powAt cid ts = mkPOW ts (powNonceAt cid ts)

lookupIs :: Blob -> Word64 -> [DeviceData] -> M ()
lookupIs cid user_number ds = do
  r <- queryII cid dummyUserId #lookup user_number
  liftIO $ r @?= V.fromList ds

addTS :: (a, b, c, d) -> e -> (a, b, c, e)
addTS (a,b,c, _) ts = (a,b,c,ts)

getAndValidate :: HasCallStack => Blob -> Blob -> Blob -> EntityId -> (Word64, T.Text, Blob, Maybe Word64) -> Word64 -> M ()
getAndValidate cid sessionPK userPK webauthID delegationArgs ts = do
  sd <- queryII cid webauthID #get_delegation (addTS delegationArgs ts) >>= \case
    V.IsJust (V.Label :: Label "signed_delegation") sd -> return sd
    V.IsJust (V.Label :: Label "no_such_delegation") () ->
        liftIO $ assertFailure "Got unexpected no_such_delegation"
    _ -> error "unreachable"
  let delegation = sd .! #delegation
  let sig = sd .! #signature
  lift $ delegation .! #pubkey @?= sessionPK

  root_key <- gets $ toPublicKey . secretRootKey
  case verify root_key "ic-request-auth-delegation" userPK (delegationHash delegation) sig of
    Left err -> liftIO $ assertFailure $ T.unpack err
    Right () -> return ()

getButNotThere :: HasCallStack => Blob -> EntityId -> (Word64, T.Text, Blob, Maybe Word64) -> Word64 -> M ()
getButNotThere cid webauthID delegationArgs ts = do
  queryII cid webauthID #get_delegation (addTS delegationArgs ts) >>= \case
    V.IsJust (V.Label :: Label "signed_delegation") _ ->
        liftIO $ assertFailure "Unexpected delegation"
    V.IsJust (V.Label :: Label "no_such_delegation") () -> return ()
    _ -> error "unreachable"

assertStats :: HasCallStack => Blob -> Word64 -> M()
assertStats cid expUsers = do
  s <- queryII cid dummyUserId #stats ()
  lift $ s .! #users_registered @?= expUsers

assertVariant :: (HasCallStack, KnownSymbol l, V.Forall r Show) => Label l -> V.Var r -> M ()
assertVariant label var = case V.view label var of
  Just _ -> return ()
  Nothing -> liftIO $ assertFailure $ printf "expected variant %s, got: %s" (show label) (show var)

mustGetUserNumber :: HasCallStack => RegisterResponse -> M Word64
mustGetUserNumber response = case V.view #registered response of
  Just r -> return (r .! #user_number)
  Nothing -> liftIO $ assertFailure $ "expected to get 'registered' response, got " ++ show response

mustParseMetrics :: HasCallStack => HttpResponse -> M MetricsRepository
mustParseMetrics resp =
  case parseMetricsFromText bodyText of
    Left err -> liftIO $ assertFailure $ printf "failed to parse metrics from text, error: %s, input: %s" err bodyText
    Right metrics -> return metrics
  where
    bodyText = T.decodeUtf8 $ BS.toStrict $ resp .! #body

assertMetric :: HasCallStack => MetricsRepository -> MetricName -> MetricValue -> M ()
assertMetric repo name expectedValue =
  case lookupMetric repo name of
    Left err ->
      liftIO $ assertFailure $ printf "failed to lookup metric %s: %s, repository: %s" name err (show repo)
    Right (actualValue, _) ->
      if expectedValue /= actualValue
      then liftIO $ assertFailure $ printf "the value of metric %s expected to be %f but actually was %f" name expectedValue actualValue
      else return ()

validateHttpResponse :: HasCallStack => Blob -> String -> HttpResponse -> M ()
validateHttpResponse cid asset resp = do
  h <- case [ v | ("IC-Certificate", v) <- V.toList (resp .! #headers)] of
    [] -> lift $ assertFailure "IC-Certificate header not found"
    [h] -> return $ BS.fromStrict $ T.encodeUtf8  h
    _ -> lift $ assertFailure "IC-Certificate header duplicated???"
  case h =~~ ("^certificate=:([^:]*):, tree=:([^:]*):$" :: BS.ByteString) :: Maybe (BS.ByteString, BS.ByteString, BS.ByteString, [BS.ByteString]) of
    Just (_, _, _, [cert64, tree64]) -> do
      certBlob <- assertRightS $ Base64.decode cert64
      cert <- assertRightT $ decodeCert certBlob
      root_key <- gets $ toPublicKey . secretRootKey
      assertRightT $ validateCertificate root_key cert
      -- TODO: validateCertificate should probablay check wellFormed too
      assertRightS $ wellFormed (cert_tree cert)

      treeBlob <- assertRightS $ Base64.decode tree64
      tree <- assertRightT $ decodeTree treeBlob
      assertRightS $ wellFormed tree

      liftIO $ lookupPath (cert_tree cert) ["canister", cid, "certified_data"]
          @?= Found (reconstruct tree)
      let uri = BS.fromStrict (T.encodeUtf8 (T.pack asset))

      case resp .! #status_code of
        200 -> liftIO $ lookupPath tree ["http_assets", uri] @?= Found (sha256 (resp .! #body))
        404 -> liftIO $ lookupPath tree ["http_assets", uri] @?= Absent
        c -> liftIO $ assertFailure $ "Unexpected status code " <> show c

    _ -> lift $ assertFailure $ "Could not parse header: " <> show h

assertRightS :: MonadIO m  => Either String a -> m a
assertRightS (Left e) = liftIO $ assertFailure e
assertRightS (Right x) = pure x

assertRightT :: MonadIO m  => Either T.Text a -> m a
assertRightT (Left e) = liftIO $ assertFailure (T.unpack e)
assertRightT (Right x) = pure x

decodeTree :: BS.ByteString -> Either T.Text HashTree
decodeTree s =
    first (\(DeserialiseFailure _ s) -> "CBOR decoding failure: " <> T.pack s)
        (deserialiseFromBytes decodeTerm s)
    >>= begin
  where
    begin (leftOver, _)
      | not (BS.null leftOver) = Left $ "Left-over bytes: " <> T.pack (shorten 20 (show leftOver))
    begin (_, TTagged 55799 t) = parseHashTree t
    begin _ = Left "Expected CBOR request to begin with tag 55799"




tests :: FilePath -> TestTree
tests wasm_file = testGroup "Tests" $ upgradeGroups $
  [ withoutUpgrade $ iiTest "installs" $ \ _cid ->
    return ()
  , withoutUpgrade $ iiTest "installs and upgrade" $ \ cid ->
    doUpgrade cid
  , withoutUpgrade $ iiTest "register with wrong user fails" $ \cid -> do
    callIIReject cid dummyUserId #register (device1, invalidPOW)
  , withoutUpgrade $ iiTest "register with bad pow fails" $ \cid -> do
    callIIReject cid dummyUserId #register (device1, invalidPOW)
  , withoutUpgrade $ iiTest "register with future pow fails" $ \cid -> do
    callIIReject cid dummyUserId #register (device1, powAt cid (20*60*1000_000_000))
  , withoutUpgrade $ iiTest "register with past pow fails" $ \cid -> do
    setCanisterTimeTo cid (20*60*1000_000_000)
    callIIReject cid dummyUserId #register (device1, powAt cid 1)
  , withoutUpgrade $ iiTest "register with repeated pow fails" $ \cid -> do
    _ <- callII cid webauthID #register (device1, powAt cid 1)
    callIIReject cid dummyUserId #register (device1, powAt cid 1)
  , withoutUpgrade $ iiTest "get delegation without authorization" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    let sessionSK = createSecretKeyEd25519 "hohoho"
    let sessionPK = toPublicKey sessionSK
    let delegationArgs = (user_number, "front.end.com", sessionPK, Nothing)
    (_, ts) <- callII cid webauthID #prepare_delegation delegationArgs
    queryIIReject cid dummyUserId #get_delegation (addTS delegationArgs ts)

  , withUpgrade $ \should_upgrade -> iiTest "lookup on fresh" $ \cid -> do
    assertStats cid 0
    when should_upgrade $ doUpgrade cid
    assertStats cid 0
    lookupIs cid 123 []

  , withUpgrade $ \should_upgrade -> iiTest "register and lookup" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    assertStats cid 1
    when should_upgrade $ doUpgrade cid
    assertStats cid 1
    lookupIs cid user_number [device1]

  , withUpgrade $ \should_upgrade -> iiTest "register and lookup (with credential id)" $ \cid -> do
    user_number <- callII cid webauth2ID #register (device2, powAt cid 0) >>= mustGetUserNumber
    when should_upgrade $ doUpgrade cid
    lookupIs cid user_number [device2]

  , withUpgrade $ \should_upgrade -> iiTest "register add lookup" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    when should_upgrade $ doUpgrade cid
    callII cid webauthID #add (user_number, device2)
    when should_upgrade $ doUpgrade cid
    lookupIs cid user_number [device1, device2]

  , withUpgrade $ \should_upgrade -> iiTest "register and add with wrong user" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    when should_upgrade $ doUpgrade cid
    callIIReject cid webauth2ID #add (user_number, device2)
    lookupIs cid user_number [device1]

  , withUpgrade $ \should_upgrade -> iiTest "register and get principal with wrong user" $ \cid -> do
    queryIIReject cid webauth2ID #get_principal (10000, "front.end.com")
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    when should_upgrade $ doUpgrade cid
    queryIIReject cid webauth2ID #get_principal (user_number, "front.end.com")

  , withUpgrade $ \should_upgrade -> iiTest "get delegation and validate" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber

    let sessionSK = createSecretKeyEd25519 "hohoho"
    let sessionPK = toPublicKey sessionSK
    let delegationArgs = (user_number, "front.end.com", sessionPK, Nothing)
    -- prepare delegation
    (userPK, ts) <- callII cid webauthID #prepare_delegation delegationArgs
    ts <- if should_upgrade
      then do
        doUpgrade cid
        -- after upgrade, no signature is available
        V.IsJust (V.Label :: Label "no_such_delegation") ()
          <- queryII cid webauthID #get_delegation (addTS delegationArgs ts)
        -- so request it again
        (userPK', ts') <- callII cid webauthID #prepare_delegation delegationArgs
        lift $ userPK' @?= userPK
        return ts'
      else return ts

    V.IsJust (V.Label :: Label "signed_delegation") sd
      <- queryII cid webauthID #get_delegation (addTS delegationArgs ts)
    let delegation = sd .! #delegation
    let sig = sd .! #signature
    lift $ delegation .! #pubkey @?= sessionPK

    root_key <- gets $ toPublicKey . secretRootKey
    case verify root_key "ic-request-auth-delegation" userPK (delegationHash delegation) sig of
      Left err -> liftIO $ assertFailure $ T.unpack err
      Right () -> return ()

  , withUpgrade $ \should_upgrade -> iiTest "get delegation with wrong user" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    when should_upgrade $ do
      doUpgrade cid

    let sessionSK = createSecretKeyEd25519 "hohoho"
    let sessionPK = toPublicKey sessionSK
    let delegationArgs = (user_number, "front.end.com", sessionPK, Nothing)
    callIIReject cid webauth2ID #prepare_delegation delegationArgs

  , withUpgrade $ \should_upgrade -> iiTest "get multiple delegations and validate" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber

    let sessionSK = createSecretKeyEd25519 "hohoho"
    let sessionPK = toPublicKey sessionSK
    let delegationArgs = (user_number, "front.end.com", sessionPK, Nothing)
    -- request a few delegations
    (userPK, ts1) <- callII cid webauthID #prepare_delegation delegationArgs
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts1

    (userPK, ts2) <- callII cid webauthID #prepare_delegation delegationArgs
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts1
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts2

    when should_upgrade $ do
      doUpgrade cid

    (userPK, ts3) <- callII cid webauthID #prepare_delegation delegationArgs
    unless should_upgrade $ getAndValidate cid sessionPK userPK webauthID delegationArgs ts1
    unless should_upgrade $ getAndValidate cid sessionPK userPK webauthID delegationArgs ts2
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts3

    (userPK, ts4) <- callII cid webauthID #prepare_delegation delegationArgs
    unless should_upgrade $ getAndValidate cid sessionPK userPK webauthID delegationArgs ts1
    unless should_upgrade $ getAndValidate cid sessionPK userPK webauthID delegationArgs ts2
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts3
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts4

  , withoutUpgrade $ iiTest "get multiple delegations and expire" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber

    let sessionSK = createSecretKeyEd25519 "hohoho"
    let sessionPK = toPublicKey sessionSK
    let delegationArgs = (user_number, "front.end.com", sessionPK, Nothing)
    -- request a few delegations
    (userPK, ts1) <- callII cid webauthID #prepare_delegation delegationArgs
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts1

    setCanisterTimeTo cid (30*1000_000_000)
    (userPK, ts2) <- callII cid webauthID #prepare_delegation delegationArgs
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts1
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts2

    setCanisterTimeTo cid (70*1000_000_000)
    (userPK, ts3) <- callII cid webauthID #prepare_delegation delegationArgs
    getButNotThere cid webauthID delegationArgs ts1
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts2
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts3

    setCanisterTimeTo cid (120*1000_000_000)
    (userPK, ts4) <- callII cid webauthID #prepare_delegation delegationArgs
    getButNotThere cid webauthID delegationArgs ts1
    getButNotThere cid webauthID delegationArgs ts2
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts3
    getAndValidate cid sessionPK userPK webauthID delegationArgs ts4

  , withUpgrade $ \should_upgrade -> iiTest "user identities differ" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber

    let sessionSK = createSecretKeyEd25519 "hohoho"
    let sessionPK = toPublicKey sessionSK
    let delegationArgs1 = (user_number, "front.end.com", sessionPK, Nothing)
    (user1PK, _exp) <- callII cid webauthID #prepare_delegation delegationArgs1
    Principal user1Principal <- queryII cid webauthID #get_principal (user_number, "front.end.com")
    lift $ user1Principal @?= mkSelfAuthenticatingId user1PK

    when should_upgrade $ do
      doUpgrade cid

    let delegationArgs2 = (user_number, "other-front.end.com", sessionPK, Nothing)
    (user2PK, _exp) <- callII cid webauthID #prepare_delegation delegationArgs2
    Principal user2Principal <- queryII cid webauthID #get_principal (user_number, "other-front.end.com")
    lift $ user2Principal @?= mkSelfAuthenticatingId user2PK

    when (user1PK == user2PK) $
      lift $ assertFailure "User identities coincide for different frontends"

  , withUpgrade $ \should_upgrade -> iiTest "remove()" $ \cid -> do
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    lookupIs cid user_number [device1]
    callII cid webauthID #add (user_number, device2)
    lookupIs cid user_number [device1, device2]
    -- NB: removing device that is signing this:
    callII cid webauthID #remove (user_number, webauthPK)
    lookupIs cid user_number [device2]
    when should_upgrade $ doUpgrade cid
    lookupIs cid user_number [device2]
    callII cid webauth2ID #remove (user_number, webauth2PK)
    when should_upgrade $ doUpgrade cid
    lookupIs cid user_number []
    user_number2 <- callII cid webauthID #register (device1, powAt cid 1) >>= mustGetUserNumber
    when should_upgrade $ doUpgrade cid
    when (user_number == user_number2) $
      lift $ assertFailure "ID number re-used"

  , withUpgrade $ \should_upgrade -> iiTestWithInit "init range" (100, 103) $ \cid -> do
    s <- queryII cid dummyUserId #stats ()
    lift $ s .! #assigned_user_number_range @?= (100, 103)

    assertStats cid 0
    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    liftIO $ user_number @?= 100
    assertStats cid 1
    user_number <- callII cid webauthID #register (device1, powAt cid 1) >>= mustGetUserNumber
    liftIO $ user_number @?= 101
    assertStats cid 2

    when should_upgrade $ doUpgrade cid
    s <- queryII cid dummyUserId #stats ()
    lift $ s .! #assigned_user_number_range @?= (100, 103)

    user_number <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    liftIO $ user_number @?= 102
    assertStats cid 3
    callIIReject cid webauthID #register (device1, powAt cid 0)
    assertStats cid 3

  , withoutUpgrade $ iiTestWithInit "empty init range" (100, 100) $ \cid -> do
    s <- queryII cid dummyUserId #stats ()
    lift $ s .! #assigned_user_number_range @?= (100, 100)
    response <- callII cid webauthID #register (device1, powAt cid 0)
    assertVariant #canister_full response

  , withUpgrade $ \should_upgrade -> iiTest "metrics endpoint" $ \cid -> do
    _ <- callII cid webauth2ID #register (device2, powAt cid 1) >>= mustGetUserNumber
    metrics <- callII cid webauth2ID #http_request (httpGet "/metrics") >>= mustParseMetrics

    assertMetric metrics "internet_identity_user_count" 1.0
    assertMetric metrics "internet_identity_signature_count" 0.0

    when should_upgrade $ doUpgrade cid

    userNumber <- callII cid webauthID #register (device1, powAt cid 0) >>= mustGetUserNumber
    let sessionSK = createSecretKeyEd25519 "hohoho"
    let sessionPK = toPublicKey sessionSK
    let delegationArgs = (userNumber, "front.end.com", sessionPK, Nothing)
    _ <- callII cid webauthID #prepare_delegation delegationArgs

    metrics <- callII cid webauthID #http_request (httpGet "/metrics") >>= mustParseMetrics

    assertMetric metrics "internet_identity_user_count" 2.0
    assertMetric metrics "internet_identity_signature_count" 1.0

  , withUpgrade $ \should_upgrade -> testGroup "HTTP Assets"
    [ iiTest asset $ \cid -> do
      when should_upgrade $ doUpgrade cid
      r <- queryII cid dummyUserId #http_request (httpGet asset)
      validateHttpResponse cid asset r
    | asset <- words "/ /index.html /index.js /glitch-loop.webp /favicon.ico /does-not-exist"
    ]

  , withUpgrade $ \should_upgrade -> testCase "upgrade from stable memory backup" $ withIC $ do
    -- See test-stable-memory-rdmx6-jaaaa-aaaaa-aaadq-cai.md for providence
    t <- getTimestamp
    -- Need a fixed id for this to work
    let cid = fromPrincipal "rdmx6-jaaaa-aaaaa-aaadq-cai"
    createEmptyCanister (EntityId cid) (S.singleton controllerId) t
    -- Load a backup. This backup is taking from the messaging subnet installation
    -- on 2021-04-29
    stable_memory <- lift $ BS.readFile "test-stable-memory-rdmx6-jaaaa-aaaaa-aaadq-cai.bin"
    -- Upload a dummy module that populates the stable memory
    upload_wasm <- lift $ BS.readFile "stable-memory-setter.wasm"
    callManagement controllerId #install_code $ empty
      .+ #mode .== enum #install
      .+ #canister_id .== Candid.Principal cid
      .+ #wasm_module .== upload_wasm
      .+ #arg .== stable_memory
    doUpgrade cid

    when should_upgrade $ doUpgrade cid
    s <- queryII cid dummyUserId #stats ()
    lift $ s .! #users_registered @?= 31
    -- The actual value in the dump is 8B, but it's way too large
    -- and should be auto-corrected on upgrade
    lift $ s .! #assigned_user_number_range @?= (10_000, 1897436)
    lookupIs cid 9_999 []
    lookupIs cid 10_000 [#alias .== "Desktop" .+ #credential_id .== Just "c\184\175\179\134\221u}\250[\169U\v\202f\147g\ETBvo9[\175\173\144R\163\132\237\196F\177\DC2(\188\185\203hI\128\187Z\129'\v1\212\185V\ETB\135)m@ M1\233l\ESC8kI\132" .+ #pubkey .== "0^0\f\ACK\n+\ACK\SOH\EOT\SOH\131\184C\SOH\SOH\ETXN\NUL\165\SOH\STX\ETX& \SOH!X \238o!-\ESC\148\252\192\DC4\240P\176\135\240j\211AW\255S\193\153\129\227\151hB\177dK\n\FS\"X \rk\197\238\a{\210\&0\v<\134\223\135\170_\223\144\210V\208\DC3\RS\251\228D$3\r\232\176\EOTq" .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown ]
    lookupIs cid 10_002 [#alias .== "andrew-mbp" .+ #credential_id .== Just "\SOH\191#%\217u\247\178L-K\182\254\249J.m\187\179_I\ACK\137\244`\163o\SI\150qz\197Hz\214\&8\153\239\213\159\208\RS\243\138\171\138\"\139\173\170\ESC\148\205\129\149ri\\Dn,7\151\146\175\DEL" .+ #pubkey .== "0^0\f\ACK\n+\ACK\SOH\EOT\SOH\131\184C\SOH\SOH\ETXN\NUL\165\SOH\STX\ETX& \SOH!X rMm*\229BDe\SOH4\228u\170\206\216\216-ER\v\166r\217\137,\141\227M*@\230\243\"X \225\248\159\191\242\224Z>\241\163\\\GS\155\178\222\139^\136V\253q\v\SUBSJ\bA\131\\\183\147\170" .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown,#alias .== "andrew phone chrome" .+ #credential_id .== Just ",\235x\NUL\a\140`~\148\248\233C/\177\205\158\ETX0\129\167" .+ #pubkey .== "0^0\f\ACK\n+\ACK\SOH\EOT\SOH\131\184C\SOH\SOH\ETXN\NUL\165\SOH\STX\ETX& \SOH!X \140\169\203@\ETX\CAN\ETB,\177\153\179\223/|`\US\STX\252r\190s(.\188\136\171\SI\181V*\174@\"X \245<\174AbV\225\234\ENQ\146\247\129\245\ACK\200\205\217\250g\219\179)\197\252\164i\172kXh\180\205" .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown]
    lookupIs cid 10_029 [#alias .== "Pixel" .+ #credential_id .== Just "\SOH\146\238\160b\223\132\205\231b\239\243F\170\163\167\251D\241\170\EM\216\136\174@r\149\183|LuKu[+{\144\217\ETBL\f\244\GS>\179\146\143\RS\179\DLE\227\179\164\188\NULDQy\223\SI\132\183\248\177\219" .+ #pubkey .== "0^0\f\ACK\n+\ACK\SOH\EOT\SOH\131\184C\SOH\SOH\ETXN\NUL\165\SOH\STX\ETX& \SOH!X \200B>\DEL\GS\248\220\145\245\153\221\&6\131\243uAQCAd>\145k\nw\233\&5\218\SUB~_\244\"X O]7\167=n\ESC\SUB\198\235\208\215s\158\191Gz\143\136\237i\146\203\&6\182\196\129\239\238\SOH\180b" .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown]
    -- This user record has been created manullay with dfx and our test
    -- webauthPK has been added, so that we can actually log into this now
    let dfxPK =  "0*0\ENQ\ACK\ETX+ep\ETX!\NUL\241\186;\128\206$\243\130\250\&2\253\a#<\235\142\&0]W\218\254j\211\209\192\SO@\DC3\NAKi&1"
    lookupIs cid 10_030 [#alias .== "dfx" .+ #credential_id .== Nothing .+ #pubkey .== dfxPK .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown,#alias .== "testkey" .+ #credential_id .== Nothing .+ #pubkey .== webauthPK .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown]
    callII cid webauthID #remove (10_030, dfxPK)
    lookupIs cid 10_030 [#alias .== "testkey" .+ #credential_id .== Nothing .+ #pubkey .== webauthPK .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown]
    let delegationArgs = (10_030, "example.com", "dummykey", Nothing)
    (userPK,_) <- callII cid webauthID #prepare_delegation delegationArgs
    -- Check that we get the same user key; this proves that the salt was
    -- recovered from the backup
    lift $ userPK @?= "0<0\x0c\&\x06\&\x0a\&+\x06\&\x01\&\x04\&\x01\&\x83\&\xb8\&C\x01\&\x02\&\x03\&,\x00\&\x0a\&\x00\&\x00\&\x00\&\x00\&\x00\&\x00\&\x00\&\x07\&\x01\&\x01\&:\x89\&&\x91\&M\xd1\&\xc8\&6\xec\&g\xba\&f\xac\&d%\xc2\&\x1d\&\xff\&\xd3\&\xca\&\x5c\&Yh\x85\&_\x87\&x\x0a\&\x1e\&\xc5\&y\x85\&"
  ]


  where
    withIC act = do
      ic <- initialIC
      evalStateT act ic

    iiTestWithInit name (l, u) act = testCase name $ withIC $ do
      wasm <- lift $ BS.readFile wasm_file
      r <- callManagement controllerId #create_canister (#settings .== Nothing)
      let Candid.Principal cid = r .! #canister_id
      callManagement controllerId #install_code $ empty
        .+ #mode .== enum #install
        .+ #canister_id .== Candid.Principal cid
        .+ #wasm_module .== wasm
        .+ #arg .== Candid.encode (Just (#assigned_user_number_range .== (l :: Word64, u :: Word64)))
      act cid

    iiTest name act = testCase name $ withIC $ do
      wasm <- lift $ BS.readFile wasm_file
      r <- callManagement controllerId #create_canister (#settings .== Nothing)
      let Candid.Principal cid = r .! #canister_id
      callManagement controllerId #install_code $ empty
        .+ #mode .== V.IsJust #install ()
        .+ #canister_id .== Candid.Principal cid
        .+ #wasm_module .== wasm
        .+ #arg .== Candid.encode (Nothing :: Maybe InitCandid) -- default value
      act cid

    withUpgrade act = ([act False], [act True])
    withoutUpgrade act = ([act], [])

    upgradeGroups :: [([TestTree], [TestTree])] -> [TestTree]
    upgradeGroups ts =
      [ testGroup "without upgrade" (concat without)
      , testGroup "with upgrade" (concat with)
      ]
      where (without, with) = unzip ts

    doUpgrade cid = do
      wasm <- liftIO $ BS.readFile wasm_file
      callManagement controllerId #install_code $ empty
        .+ #mode .== V.IsJust #upgrade ()
        .+ #canister_id .== Candid.Principal cid
        .+ #wasm_module .== wasm
        .+ #arg .== Candid.encode ()


asHex :: Blob -> String
asHex = T.unpack . H.encodeHex . BS.toStrict

fromPrincipal :: T.Text -> Blob
fromPrincipal s = cid
  where Right (Candid.Principal cid) = Candid.parsePrincipal s

enum :: (AllUniqueLabels r, KnownSymbol l, (r .! l) ~ ()) => Label l -> Var r
enum l = V.IsJust l ()

-- Configuration: The Wasm file to test
newtype WasmOption = WasmOption String

instance IsOption WasmOption where
  defaultValue = WasmOption "../target/wasm32-unknown-unknown/release/internet_identity.wasm"
  parseValue = Just . WasmOption
  optionName = return "wasm"
  optionHelp = return "webassembly module of the identity provider"
  optionCLParser = mkOptionCLParser (metavar "WASM")


wasmOption :: OptionDescription
wasmOption = Option (Proxy :: Proxy WasmOption)

main :: IO ()
main = defaultMainWithIngredients ingredients $ askOption $ \(WasmOption wasm) -> tests wasm
  where
    ingredients =
      [ rerunningTests
        [ listingTests
        , includingOptions [wasmOption]
        , antXMLRunner `composeReporters` htmlRunner `composeReporters` consoleTestReporter
        ]
      ]
