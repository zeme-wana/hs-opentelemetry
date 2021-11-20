{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
module OpenTelemetry.Internal.Trace.Types where

import Control.Concurrent.Async (Async)
import Control.Exception (SomeException)
import Data.Bits
import Data.IORef (IORef)
import Data.Word (Word8)
import Data.Text (Text)
import Data.Hashable (Hashable)
import Data.Vector (Vector)
import OpenTelemetry.Context.Types
import OpenTelemetry.Resource
import OpenTelemetry.Internal.Trace.Id
import OpenTelemetry.Trace.IdGenerator
import OpenTelemetry.Trace.TraceState
import System.Clock (TimeSpec)
import Data.HashMap.Strict (HashMap)
import GHC.Generics
import Data.String ( IsString(..) )

data ExportResult
  = Success
  | Failure (Maybe SomeException)

data InstrumentationLibrary = InstrumentationLibrary
  { libraryName :: {-# UNPACK #-} !Text
  , libraryVersion :: {-# UNPACK #-} !Text
  } deriving (Ord, Eq, Generic, Show)

instance Hashable InstrumentationLibrary
instance IsString InstrumentationLibrary where
  fromString str = InstrumentationLibrary (fromString str) ""

data SpanExporter = SpanExporter
  { spanExporterExport :: HashMap InstrumentationLibrary (Vector ImmutableSpan) -> IO ExportResult
  , spanExporterShutdown :: IO ()
  }

data ShutdownResult = ShutdownSuccess | ShutdownFailure | ShutdownTimeout

data SpanProcessor = SpanProcessor
  { spanProcessorOnStart :: IORef ImmutableSpan -> Context -> IO ()
  , spanProcessorOnEnd :: IORef ImmutableSpan -> IO ()
  , spanProcessorShutdown :: IO (Async ShutdownResult)
  , spanProcessorForceFlush :: IO ()
  }

{- | 
Tracers can be accessed with a TracerProvider.
-}
data TracerProvider = forall s. TracerProvider 
  { tracerProviderProcessors :: Vector SpanProcessor
  , tracerProviderIdGenerator :: IdGenerator
  , tracerProviderSampler :: Sampler
  , tracerProviderResources :: Resource s
  -- ^ TODO schema support
  }

-- | The @Tracer@ is responsible for creating @Span@s.
data Tracer = Tracer
  { tracerName :: {-# UNPACK #-} !InstrumentationLibrary
  , tracerProvider :: !TracerProvider
  }

type Time = TimeSpec
type Timestamp = TimeSpec
type Duration = TimeSpec

{- |
A @Span@ may be linked to zero or more other @Spans@ (defined by @SpanContext@) that are causally related. 
@Link@s can point to Spans inside a single Trace or across different Traces. @Link@s can be used to represent 
batched operations where a @Span@ was initiated by multiple initiating Spans, each representing a single incoming 
item being processed in the batch.

Another example of using a Link is to declare the relationship between the originating and following trace. 
This can be used when a Trace enters trusted boundaries of a service and service policy requires the generation 
of a new Trace rather than trusting the incoming Trace context. The new linked Trace may also represent a long 
running asynchronous data processing operation that was initiated by one of many fast incoming requests.

When using the scatter/gather (also called fork/join) pattern, the root operation starts multiple downstream 
processing operations and all of them are aggregated back in a single Span. 
This last Span is linked to many operations it aggregates. 
All of them are the Spans from the same Trace. And similar to the Parent field of a Span. 
It is recommended, however, to not set parent of the Span in this scenario as semantically the parent field 
represents a single parent scenario, in many cases the parent Span fully encloses the child Span. 
This is not the case in scatter/gather and batch scenarios.
-}
data Link = Link
  { linkContext :: SpanContext
  -- ^ @SpanContext@ of the @Span@ to link to.
  , linkAttributes :: [(Text, Attribute)]
  -- ^ Zero or more Attributes further describing the link.
  }
  deriving (Show)

data CreateSpanArguments = CreateSpanArguments
  { startingKind :: SpanKind
  , startingAttributes :: [(Text, Attribute)]
  , startingLinks :: [Link]
  , startingTimestamp :: Maybe Timestamp
  }

data FlushResult = FlushTimeout | FlushSuccess | FlushError
  deriving (Show)

{- |
@SpanKind@ describes the relationship between the @Span@, its parents, and its children in a Trace. @SpanKind@ describes two independent properties that benefit tracing systems during analysis.

The first property described by @SpanKind@ reflects whether the @Span@ is a remote child or parent. @Span@s with a remote parent are interesting because they are sources of external load. Spans with a remote child are interesting because they reflect a non-local system dependency.

The second property described by @SpanKind@ reflects whether a child @Span@ represents a synchronous call. When a child span is synchronous, the parent is expected to wait for it to complete under ordinary circumstances. It can be useful for tracing systems to know this property, since synchronous @Span@s may contribute to the overall trace latency. Asynchronous scenarios can be remote or local.

In order for @SpanKind@ to be meaningful, callers SHOULD arrange that a single @Span@ does not serve more than one purpose. For example, a server-side span SHOULD NOT be used directly as the parent of another remote span. As a simple guideline, instrumentation should create a new @Span@ prior to extracting and serializing the @SpanContext@ for a remote call.
-}
data SpanKind 
  = Server
  -- ^ Indicates that the span covers server-side handling of a synchronous RPC or other remote request. 
  -- This span is the child of a remote @Client@ span that was expected to wait for a response.
  | Client 
  -- ^ Indicates that the span describes a synchronous request to some remote service. 
  -- This span is the parent of a remote @Server@ span and waits for its response.
  | Producer 
  -- ^ Indicates that the span describes the parent of an asynchronous request. 
  -- This parent span is expected to end before the corresponding child @Producer@ span, 
  -- possibly even before the child span starts. In messaging scenarios with batching, 
  -- tracing individual messages requires a new @Producer@ span per message to be created.
  | Consumer 
  -- ^ Indicates that the span describes the child of an asynchronous @Producer@ request. 
  | Internal
  -- ^  Default value. Indicates that the span represents an internal operation within an application, 
  -- as opposed to an operations with remote parents or children.
  deriving (Show)

data SpanStatus 
  = Unset
  -- ^ The default status.
  | Error Text 
  -- ^ The operation contains an error. The text field may be empty, or else provide a description of the error.
  | Ok
  -- ^ The operation has been validated by an Application developer or Operator to have completed successfully.
  deriving (Show, Eq, Ord)

data ImmutableSpan = ImmutableSpan
  { spanName :: Text
  , spanParent :: Maybe Span
  , spanContext :: SpanContext
  , spanKind :: SpanKind
  , spanStart :: Timestamp
  , spanEnd :: Maybe Timestamp
  , spanAttributes :: [(Text, Attribute)]
  -- ^ TODO, this should probably be a DList
  -- | TODO Links SHOULD preserve the order in which they're set
  , spanLinks :: [Link]
  , spanEvents :: [Event]
  , spanStatus :: SpanStatus
  , spanTracer :: Tracer
  -- ^ Creator of the span
  }

data Span 
  = Span (IORef ImmutableSpan)
  | FrozenSpan SpanContext
  | Dropped SpanContext

newtype TraceFlags = TraceFlags Word8
  deriving (Show, Eq, Ord)

defaultTraceFlags :: TraceFlags
defaultTraceFlags = TraceFlags 0

isSampled :: TraceFlags -> Bool
isSampled (TraceFlags flags) = flags `testBit` 0

setSampled :: TraceFlags -> TraceFlags
setSampled (TraceFlags flags) = TraceFlags (flags `setBit` 0)

unsetSampled :: TraceFlags -> TraceFlags
unsetSampled (TraceFlags flags) = TraceFlags (flags `clearBit` 0)

traceFlagsValue :: TraceFlags -> Word8
traceFlagsValue (TraceFlags flags) = flags

traceFlagsFromWord8 :: Word8 -> TraceFlags
traceFlagsFromWord8 = TraceFlags

-- | A `SpanContext` represents the portion of a `Span` which must be serialized and
-- propagated along side of a distributed context. `SpanContext`s are immutable.

-- The OpenTelemetry `SpanContext` representation conforms to the [W3C TraceContext
-- specification](https://www.w3.org/TR/trace-context/). It contains two
-- identifiers - a `TraceId` and a `SpanId` - along with a set of common
-- `TraceFlags` and system-specific `TraceState` values.

-- `TraceId` A valid trace identifier is a 16-byte array with at least one
-- non-zero byte.

-- `SpanId` A valid span identifier is an 8-byte array with at least one non-zero
-- byte.

-- `TraceFlags` contain details about the trace. Unlike TraceState values,
-- TraceFlags are present in all traces. The current version of the specification
-- only supports a single flag called [sampled](https://www.w3.org/TR/trace-context/#sampled-flag).

-- `TraceState` carries vendor-specific trace identification data, represented as a list
-- of key-value pairs. TraceState allows multiple tracing
-- systems to participate in the same trace. It is fully described in the [W3C Trace Context
-- specification](https://www.w3.org/TR/trace-context/#tracestate-header).

-- The API MUST implement methods to create a `SpanContext`. These methods SHOULD be the only way to
-- create a `SpanContext`. This functionality MUST be fully implemented in the API, and SHOULD NOT be
-- overridable.
data SpanContext = SpanContext
  { traceFlags :: TraceFlags
  , isRemote :: Bool
  , traceId :: TraceId
  , spanId :: SpanId
  , traceState :: TraceState -- TODO have to move TraceState impl from W3CTraceContext to here
  -- list of up to 32, remove rightmost if exceeded
  -- see w3c trace-context spec
  } deriving (Show, Eq)

newtype NonRecordingSpan = NonRecordingSpan SpanContext

data NewEvent = NewEvent
  { newEventName :: Text
  , newEventAttributes :: [(Text, Attribute)]
  , newEventTimestamp :: Maybe Timestamp
  }

data Event = Event
  { eventName :: Text
  , eventAttributes :: [(Text, Attribute)]
  , eventTimestamp :: Timestamp
  }
  deriving (Show)

class ToEvent a where
  toEvent :: a -> Event

data SamplingResult
  = Drop 
  -- ^ isRecording == false. Span will not be recorded and all events and attributes will be dropped.
  | RecordOnly 
  -- ^ isRecording == true, but Sampled flag MUST NOT be set.
  | RecordAndSample
  -- ^ isRecording == true, AND Sampled flag MUST be set.
  deriving (Show, Eq)

-- | Interface that allows users to create custom samplers which will return a sampling SamplingResult based on information that 
-- is typically available just before the Span was created.
data Sampler = Sampler
  { getDescription :: Text
  -- ^ Returns the sampler name or short description with the configuration. This may be displayed on debug pages or in the logs.
  , shouldSample :: Context -> TraceId -> Text -> CreateSpanArguments -> IO (SamplingResult, [(Text, Attribute)], TraceState)
  }