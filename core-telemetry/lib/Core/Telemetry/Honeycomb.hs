{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}

{- |
A backend exporter that sends telemetry in the form of traces of your
application's behaviour, or event data—accompanied either way by [conceivably
very wide] additional metadata—to the Honeycomb observability service.

When specifying the 'honeycombExporter' you have to specify certain
command-line options and environment variables to enable it:

@
\$ export HONEYCOMB_TEAM="62e3626a2cc34475adef4d799eca0407"
\$ burger-service --telemetry=honeycomb --dataset=prod-restaurant-001
@

/Notice/

This library is Open Source but the Honeycomb service is /not/. Honeycomb
offers a free tier which is quite suitable for individual use and small local
applications. You can also look at "Core.Telemetry.Other" if you instead want
to forward to a generic OpenTelemetry provider. There's also
"Core.Telemetry.Console" which simply dumps telemetry to console.
-}
module Core.Telemetry.Honeycomb (
    Dataset,
    honeycombExporter,
) where

import Core.Data.Structures (Map, fromMap, insertKeyValue, intoMap, lookupKeyValue)
import Core.Encoding.Json
import Core.Program.Arguments
import Core.Program.Context
import Core.Program.Logging
import Core.System.Base (stdout)
import Core.System.External (TimeStamp (unTimeStamp), getCurrentTimeNanoseconds)
import Core.Text.Bytes
import Core.Text.Colour
import Core.Text.Rope
import Core.Text.Utilities
import Data.ByteString (ByteString)
import qualified Data.ByteString as B (ByteString)
import qualified Data.ByteString.Char8 as C (append, null, putStrLn)
import qualified Data.ByteString.Lazy as L (ByteString)
import Data.Fixed
import qualified Data.List as List
import Network.Http.Client
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO.Streams (InputStream)
import qualified System.Posix.Process as Posix (exitImmediately)

{- |
Indicate which \"dataset\" spans and events will be posted into
-}
type Dataset = Rope

type ApiKey = Rope

{- |
Configure your application to send telemetry in the form of spans and traces
to the Honeycomb observability service.

@
    context <- 'Core.Program.Execute.configure' ...
    context' <- 'Core.Telemetry.Observability.initializeTelemetry' ['honeycombExporter'] context
    'Core.Program.Execute.executeWith' context' ...
@
-}
honeycombExporter :: Exporter
honeycombExporter =
    Exporter
        { codenameFrom = "honeycomb"
        , setupConfigFrom = setupHoneycombConfig
        , setupActionFrom = setupHoneycombAction
        }

-- so this is annoying: we're _under_ (and indeed, before) the Program monad
-- and in the guts of the library. So all the work we've done to provide
-- sensible access to environment variables etc isn't available here and we
-- have to replicate a bunch of stuff we've done elsewhere.

setupHoneycombConfig :: Config -> Config
setupHoneycombConfig config0 =
    let config1 =
            appendOption
                ( Variable
                    "HONEYCOMB_TEAM"
                    "The API key used to permit writes to Honeycomb."
                )
                config0

        config2 =
            appendOption
                ( Option
                    "dataset"
                    Nothing
                    (Value "DATASET")
                    "The name of the dataset within your Honeycomb account that this program's telemetry will be written to."
                )
                config1
     in config2

setupHoneycombAction :: Context τ -> IO Forwarder
setupHoneycombAction context = do
    let params = commandLineFrom context
        pairs = environmentValuesFrom params
        possibleTeam = lookupKeyValue "HONEYCOMB_TEAM" pairs

    apikey <- case possibleTeam of
        Nothing -> do
            putStrLn "error: Need to supply an API key in the HONEYCOMB_TEAM environment variable."
            Posix.exitImmediately (ExitFailure 99)
            undefined
        Just param -> case param of
            Empty -> do
                putStrLn "error: Need to actually supply a value in HONEYCOMB_TEAM environment variable."
                Posix.exitImmediately (ExitFailure 99)
                undefined
            Value value -> pure (intoRope value)

    let options = parameterValuesFrom params
        possibleDataset = lookupKeyValue "dataset" options

    dataset <- case possibleDataset of
        Nothing -> do
            putStrLn "error: Need to specify the dataset that metrics will be written to via --dataset."
            Posix.exitImmediately (ExitFailure 99)
            undefined
        Just param -> case param of
            Empty -> do
                putStrLn "error: Need to actually supply a value to the --dataset option."
                Posix.exitImmediately (ExitFailure 99)
                undefined
            Value "" -> do
                putStrLn "error: Need to actually supply a value to the --dataset option."
                Posix.exitImmediately (ExitFailure 99)
                undefined
            Value value -> pure (intoRope value)

    pure
        Forwarder
            { telemetryHandlerFrom = process apikey dataset
            }

-- use partually applied
process :: ApiKey -> Dataset -> [Datum] -> IO ()
process apikey dataset datums = do
    let json = JsonArray (fmap convertDatumToJson datums)
    postEventToHoneycombAPI apikey dataset json

-- implements the spec described at <https://docs.honeycomb.io/getting-data-in/tracing/send-trace-data/>
convertDatumToJson :: Datum -> JsonValue
convertDatumToJson datum =
    let spani = spanIdentifierFrom datum
        trace = traceIdentifierFrom datum
        parent = parentIdentifierFrom datum
        meta0 = attachedMetadataFrom datum

        meta1 = insertKeyValue "name" (JsonString (spanNameFrom datum)) meta0

        meta2 = case spani of
            Nothing -> case trace of
                Nothing -> meta1
                Just _ -> insertKeyValue "meta.annotation_type" (JsonString "span_event") meta1
            Just value -> insertKeyValue "trace.span_id" (JsonString (unSpan value)) meta1

        meta3 = case parent of
            Nothing -> meta2
            Just value -> insertKeyValue "trace.parent_id" (JsonString (unSpan value)) meta2

        meta4 = case trace of
            Nothing -> meta3
            Just value -> insertKeyValue "trace.trace_id" (JsonString (unTrace value)) meta3

        meta5 = case serviceNameFrom datum of
            Nothing -> meta4
            Just service -> insertKeyValue "service_name" (JsonString service) meta4

        meta6 = case durationFrom datum of
            Nothing -> meta5
            Just duration ->
                insertKeyValue
                    "duration_ms"
                    (JsonNumber (fromRational (toRational duration / 1e6)))
                    meta5

        -- start = show (fromRational (toRational (spanTimeFrom datum) / 1e9) :: Fixed E9)
        -- meta7 = insertKeyValue "timestamp" (JsonString (intoRope (show (spanTimeFrom datum)))) meta6
        time = intoRope (show (spanTimeFrom datum))
        point =
            JsonObject
                ( intoMap
                    [ (JsonKey "time", JsonString time)
                    , (JsonKey "data", JsonObject meta6)
                    ]
                )
     in point

postEventToHoneycombAPI :: ApiKey -> Dataset -> JsonValue -> IO ()
postEventToHoneycombAPI apikey dataset json = do
    ctx <- baselineContextSSL
    c <- openConnectionSSL ctx "api.honeycomb.io" 443

    let q = buildRequest1 $ do
            http POST (C.append "/1/batch/" (fromRope dataset))
            setContentType "application/json"
            setHeader "X-Honeycomb-Team" (fromRope (apikey))

    sendRequest c q (simpleBody (fromBytes (encodeToUTF8 json)))
    receiveResponse c handler
  where
    {-
    Response to Batch API looks like:

    [{"status":202}]

    -}
    handler :: Response -> InputStream ByteString -> IO ()
    handler p i = do
        let code = getStatusCode p
        case code of
            200 -> do
                body <- simpleHandler p i
                let responses = decodeFromUTF8 (intoBytes body)
                case responses of
                    Just (JsonArray pairs) -> mapM_ f pairs
                      where
                        f pair = case pair of
                            JsonObject kvs -> case lookupKeyValue "status" kvs of
                                Just (JsonNumber 202) -> pure ()
                                _ -> do
                                    putStrLn "No status returned;"
                                    C.putStrLn body
                            _ -> putStrLn "internal: wtf?"
                    _ -> do
                        putStrLn "internal: Unexpected response from Honeycomb"
                        C.putStrLn body
            _ -> do
                putStrLn "internal: Failed to post to Honeycomb"
                debugHandler p i