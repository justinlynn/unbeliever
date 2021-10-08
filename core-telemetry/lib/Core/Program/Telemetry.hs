{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
For spans to be connected together by an observability tool they need to be
part of a /trace/.
-}
module Core.Program.Telemetry (
    MetricValue,
    Telemetry (metric),
    service,
    Exporter,
    initializeTelemetry,
    honeycomb,
    beginTrace,
    usingTrace,
    encloseSpan,
    telemetry,
    sendEvent,
) where

import Control.Concurrent.MVar (newMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (writeTQueue)
import Core.Data.Structures (Map, insertKeyValue)
import Core.Encoding.Json
import Core.Program.Context
import Core.System.Base (liftIO)
import Core.System.External (TimeStamp (unTimeStamp), getCurrentTimeNanoseconds)
import Core.Text.Rope
import qualified Data.ByteString as B (ByteString)
import qualified Data.ByteString.Lazy as L (ByteString)
import Data.Char (chr)
import Data.Int (Int32, Int64)
import qualified Data.List as List (foldl')
import Data.Scientific (Scientific)
import qualified Data.Text as T (Text)
import qualified Data.Text.Lazy as U (Text)
import System.Random (newStdGen, randomRs)

{- |
A telemetry value that can be sent over the wire. This is a wrapper around
Json values of type string, number, or boolean.
-}

-- a bit specific to Honeycomb's very limited data model, but what else is
-- there?
data MetricValue = MetricValue JsonKey JsonValue

{- |
Record the name of the service that this span and its children are a part of.
This will end up as the @service_name@ parameter when exported.
-}

-- This field name appears to be very Honeycomb specific, but looking around
-- Open Telemmtry it was just a property floating around and regardless of
-- what it gets called it needs to get sent.
service :: Rope -> MetricValue
service v = MetricValue "service_name" (JsonString v)

class Telemetry σ where
    metric :: Rope -> σ -> MetricValue

instance Telemetry Int where
    metric k v = MetricValue (JsonKey k) (JsonNumber (fromIntegral v))

instance Telemetry Int32 where
    metric k v = MetricValue (JsonKey k) (JsonNumber (fromIntegral v))

instance Telemetry Int64 where
    metric k v = MetricValue (JsonKey k) (JsonNumber (fromIntegral v))

instance Telemetry Integer where
    metric k v = MetricValue (JsonKey k) (JsonNumber (fromInteger v))

-- HELP is this the efficient way to get to a Scientific?
instance Telemetry Float where
    metric k v = MetricValue (JsonKey k) (JsonNumber (fromRational (toRational v)))

-- HELP is this the efficient way to get to a Scientific?
instance Telemetry Double where
    metric k v = MetricValue (JsonKey k) (JsonNumber (fromRational (toRational v)))

instance Telemetry Scientific where
    metric k v = MetricValue (JsonKey k) (JsonNumber v)

instance Telemetry Rope where
    metric k v = MetricValue (JsonKey k) (JsonString v)

instance Telemetry String where
    metric k v = MetricValue (JsonKey k) (JsonString (intoRope v))

{- |
The usual warning about assuming the @ByteString@ is ASCII or UTF-8 applies
here. Don't use this to send binary mush.
-}
instance Telemetry B.ByteString where
    metric k v = MetricValue (JsonKey k) (JsonString (intoRope v))

{- |
The usual warning about assuming the @ByteString@ is ASCII or UTF-8 applies
here. Don't use this to send binary mush.
-}
instance Telemetry L.ByteString where
    metric k v = MetricValue (JsonKey k) (JsonString (intoRope v))

instance Telemetry T.Text where
    metric k v = MetricValue (JsonKey k) (JsonString (intoRope v))

instance Telemetry U.Text where
    metric k v = MetricValue (JsonKey k) (JsonString (intoRope v))

instance Telemetry Bool where
    metric k v = MetricValue (JsonKey k) (JsonBool v)

initializeTelemetry :: Exporter -> Context τ -> IO (Context τ)
initializeTelemetry exporter context =
    pure
        ( context
            { telemetryExporterFrom = exporter
            }
        )

honeycomb :: Rope -> Exporter
honeycomb = undefined

encloseSpan :: Rope -> Program z a -> Program z a
encloseSpan label action = do
    context <- getContext

    liftIO $ do
        let datum = currentDatumFrom context

        -- prepare new span
        unique <- randomIdentifier
        start <- getCurrentTimeNanoseconds

        -- slightly tricky: we need to pull the Map out of this datum, and
        -- create a new MVar to wrap it to pass in to new one.
        let v = attachedMetadata datum
        meta <- readMVar v
        v' <- newMVar meta

        let datum' =
                datum
                    { datumIdentifierFrom = unique
                    , datumNameFrom = label
                    , datumTimeFrom = start
                    , parentSpanFrom = Just (datumIdentifierFrom datum)
                    , attachedMetadata = v'
                    }

        let context' =
                context
                    { currentDatumFrom = datum'
                    }

        -- execute nested program
        result <- subProgram context' action

        finish <- getCurrentTimeNanoseconds
        let datum2 =
                datum'
                    { datumDuration = Just (unTimeStamp finish - unTimeStamp start)
                    }

        let telem = telemetryChannelFrom context

        atomically $ do
            writeTQueue telem datum2

        pure result

represent :: Int -> Char
represent x
    | x < 10 = chr (48 + x)
    | x < 36 = chr (65 + x - 10)
    | x < 62 = chr (97 + x - 36)
    | otherwise = '@'

-- TODO replace this with something that gets a UUID
randomIdentifier :: IO Rope
randomIdentifier = do
    gen <- newStdGen
    let result = packRope . fmap represent . take 16 . randomRs (0, 61) $ gen
    pure result

{- |
Start a new trace. A random identifier will be generated.
-}
beginTrace :: Program τ α -> Program τ α
beginTrace action = do
    traceId <- liftIO randomIdentifier
    usingTrace traceId Nothing action

{- |
Begin a new trace, but using a trace identifier provided externally. This is
the most common case. Internal services that are play a part of a larger
request will inherit a job identifier, sequence number, or other externally
supplied unique code. Even an internet facing web service might have a
correlation ID provided by the outside load balancers.

If you are continuting an existing trace within the execution path of another,
larger, enclosing service then you need to specify what the parent span's
identifier is in the second argument.
-}
usingTrace :: Rope -> Maybe Rope -> Program τ α -> Program τ α
usingTrace traceId possibleParentId action = do
    context <- getContext

    liftIO $ do
        -- prepare new span
        let trace =
                Trace
                    { traceIdentifierFrom = traceId
                    }

        let datum =
                emptyDatum
                    { parentTraceFrom = Just trace
                    , parentSpanFrom = possibleParentId
                    }

        let context' =
                context
                    { currentDatumFrom = datum
                    }

        -- execute nested program
        subProgram context' action

telemetry :: [MetricValue] -> Program τ ()
telemetry values = do
    -- get the map out
    context <- getContext
    let datum = currentDatumFrom context
    let v = attachedMetadata datum
    meta <- liftIO (readMVar v)

    -- update the map
    let meta' = List.foldl' f meta values

    -- replace the map back into the span
    liftIO (putMVar v meta')
  where
    f :: Map JsonKey JsonValue -> MetricValue -> Map JsonKey JsonValue
    f acc (MetricValue k v) = insertKeyValue k v acc

sendEvent :: Rope -> [MetricValue] -> Program τ ()
sendEvent label = undefined
