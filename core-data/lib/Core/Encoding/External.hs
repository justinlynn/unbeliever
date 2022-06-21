{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_HADDOCK prune #-}

{- |
Quite frequently you will find yourself needing to convert between a rich
semantic Haskell data type and a textual representation of that type which we
call the /external/ representation of a value.

Note that /externalizing/ is not quite the same as /serializing/. If you have
more complex (ie rich types or nested) data structures then a simple text
string will probably not be sufficient to convey sufficient information to
represent it accurately. Serializing is focused on both performance encoding
and decoding, and efficiency of the representation when transmitted over the
wire. Of course, the obvious benefits of efficiency didn't stop the entire
computer industry from near universal adoption of JSON as an interchange
format, so there is, perhaps, no hope for us.

You can, however, regain some of your sanity by ensuring that the individual
fields of a larger structure are safe, and that's where the externalizing
machinery in this module comes in.

If you have read this far and think we are describing 'Show' or @toString@ you
are correct, but at the level of primative and simple types we are providing
the ability to marshall them to a clean UTF-8 representation and to unmarshall
them back into Haskell values again. This external representation of the value
is authoriative and is meant to be re-readable even in the face of changing
implemetations on the program side.
-}
module Core.Encoding.External (
    -- * Conversions
    Externalize (formatExternal, parseExternal),
) where

import Core.Data.Clock
import Core.Text.Rope
import Data.ByteString.Builder qualified as Builder
import Data.Int (Int32, Int64)
import Data.Scientific (FPFormat (Exponent), Scientific, formatScientific)
import Data.UUID qualified as Uuid (UUID, fromText, toText)
import Text.Read (readMaybe)

{- |
Convert between the internal Haskell representation of a data type and an
external, textual form suitable for visualization, onward transmission, or
archival storage.

It is expected that a valid instance of 'Externalize' allows you to round-trip
through it:

>>> formatExternal (42 :: Int))
"42"

>>> fromJust (parseExternal "42") :: Int
42

with the usual caveat about needing to ensure you've given enough information
to the type-checker to know which instance you're asking for.

There is a general implementatation that goes though 'Show' and 'Read' via
'String' but if you know you have a direct way to render or parse a type into
a sequence of characters then you can offer an instance of 'Externalize' which
does so more efficiently.

@since 0.3.4
-}
class Externalize a where
    -- | Convert a value into an authoritative, stable textual representation
    -- for use externally.
    formatExternal :: a -> Rope

    -- | Attempt to read an external textual representation into a Haskell value.
    parseExternal :: Rope -> Maybe a

--
-- We use this general instance here rather than as a super class constraint
-- for Externalize so as to allow us to have things that can be externalized
-- without necessarily needing those two instances. Most things have Show, but
-- not everything, as many many types haven't bothered with Read.
--

instance {-# OVERLAPPABLE #-} (Read a, Show a) => Externalize a where
    formatExternal = intoRope . show
    parseExternal = readMaybe . fromRope

--
-- These weren't really necessary, but they're worth it as an example of
-- avoiding Show & Read
--

instance Externalize Int where
    formatExternal = intoRope . Builder.toLazyByteString . Builder.intDec
    parseExternal = readMaybe . fromRope

instance Externalize Int32 where
    formatExternal = intoRope . Builder.toLazyByteString . Builder.int32Dec
    parseExternal = readMaybe . fromRope

instance Externalize Int64 where
    formatExternal = intoRope . Builder.toLazyByteString . Builder.int64Dec
    parseExternal = readMaybe . fromRope

--
-- More than anything, THIS was the example that motivated creating this
-- module.
--

{- |
UUIDs are formatted as per RFC 4122:

@
\"6937e157-d041-4919-8690-4d6c12b7e0e3\"
@
-}
instance Externalize Uuid.UUID where
    formatExternal = intoRope . Uuid.toText
    parseExternal = Uuid.fromText . fromRope

--
-- This is a placeholder to remind that if we ever improve the machinery in
-- Core.Data.Clock to not use **hourglass** (which uses String) we could quite
-- likely get a better implementation here.
--

{- |
Timestamps are formatted as per ISO 8601:

@
\"2022-06-20T14:51:23.544826062Z\"
@
-}
instance Externalize Time where
    formatExternal = intoRope . show
    parseExternal = readMaybe . fromRope

{- |
Numbers are converted to scientific notation:

@
\"2.99792458e8\"
@
-}
instance Externalize Scientific where
    formatExternal = intoRope . formatScientific Exponent Nothing
    parseExternal = readMaybe . fromRope
