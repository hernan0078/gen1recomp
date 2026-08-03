-- The built-in language catalogs (src/core/lang/<code>.lua).
--
-- Regression cover for a bug that shipped three times before being caught by
-- eye: lookup walked { catalog, builtin } with ipairs, and `catalog` is nil
-- whenever no translation mod is loaded -- which is the ordinary case, and
-- the only case the built-in table exists for. ipairs stopped at the nil, so
-- the language was correctly selected and then never consulted.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Strings = require("src.core.Strings")

-- English is the sources as written, and costs nothing.
Strings.setLanguage("en")
T.eq(Strings.language, "en", "defaults to English")
T.eq(Strings("SAVE FILES"), "SAVE FILES", "English returns the source")

-- Spanish, with NO mod catalog loaded -- the case that was broken.
Strings.setLanguage("es")
T.eq(Strings.language, "es", "language switches")
T.eq(Strings("SAVE FILES"), "PARTIDAS",
     "a built-in translation is used when no mod catalog exists")
T.eq(Strings("GOOD TO GO"), "TODO LISTO",
     "launcher text translates too, not just the options rows")

-- A source with no entry falls through rather than blanking.
T.eq(Strings("a string nobody has translated"),
     "a string nobody has translated",
     "an untranslated source falls through to English")

-- Format directives have to survive, or string.format blows up mid-screen.
T.eq(Strings("%d mods listed", 4), "4 mods listados",
     "format arguments still apply after translation")

-- Switching back is exact: nothing was rewritten in place, so there is
-- nothing to restore incorrectly.
Strings.setLanguage("en")
T.eq(Strings("SAVE FILES"), "SAVE FILES", "switching back is clean")

-- An unknown language is not fatal: it warns and leaves the sources alone.
Strings.setLanguage("qq")
T.eq(Strings("SAVE FILES"), "SAVE FILES",
     "an unknown language falls back to the sources")
Strings.setLanguage("en")

T.finish("strings_language")
