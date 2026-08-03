-- The engine's own player-facing text, made overridable.
--
-- Extracted dialogue already had a home: `Data.text`, keyed by pokered's
-- labels, which a mod reaches through `mod.content.text`.  The strings the
-- engine *authors* had none.  Battle messages, item results, menu labels
-- and the link-play screens were literals in Lua, so a translator could
-- reach two thirds of the game and no more (#186, #245).
--
-- Those literals stay where they are, wrapped in `S(...)`, and the English
-- source doubles as the catalog key:
--
--   self:say(S("But, it failed!"))
--   self:say(S("Wild %s\nappeared!", self.enemy.name))
--
-- Keying on the source rather than on an invented id is deliberate.  It
-- keeps the English readable at the point it is used (the alternative
-- scatters a thousand `battle.it_failed` ids that have to be looked up to
-- review a diff), it needs no id registry to stay in sync, and an entry a
-- translation has not covered yet falls through to English instead of
-- rendering a raw id at the player.  The cost is that editing an English
-- string orphans its translations; `tools/modkit.py translation --refresh`
-- reports those as changed keys rather than silently dropping them.
--
-- Same-source-different-meaning is the one case source keys cannot hold on
-- their own ("OFF" as a filter setting vs "OFF" as a toggle, which some
-- languages render differently).  Those sites pass a context:
--
--   S("OFF", "options.musicFilter")   -- key: "options.musicFilter|OFF"
--
-- A mod supplies the catalog through the `strings` registry:
--
--   mod.content.strings:override("But, it failed!", "Echec !")
--
-- With no mod loaded the catalog is empty and `S` is an identity function
-- guarded by one boolean, so a vanilla boot draws byte-identical text.

local Strings = {}

local catalog = nil   -- Data.strings once a mod has put something in it
local builtin = nil   -- src/core/lang/<code>.lua for the chosen language
local missing = {}    -- format-arity complaints, reported once each

-- The language the app's own text is drawn in.  "en" means the sources as
-- written, and costs nothing: `builtin` stays nil and lookup is unchanged.
--
-- Separate from the mod catalog on purpose.  A translation MOD is a player's
-- explicit choice and stays ahead of this in the lookup; this is the app
-- speaking the language of the phone it is running on.
Strings.language = "en"

function Strings.setLanguage(code)
  code = (type(code) == "string" and code ~= "" ) and code or "en"
  if code == Strings.language and (code == "en" or builtin) then return end
  Strings.language = code
  builtin = nil
  if code == "en" then return end
  local ok, table_ = pcall(require, "src.core.lang." .. code)
  if ok and type(table_) == "table" then
    builtin = table_
  else
    require("src.core.Logger").warn(
      "strings: no built-in catalog for language %q", code)
  end
end

-- Called from Game after the mod merge, and again on dev-mode hot reload.
-- Holding the table (not a copy) means a mod that registers late still
-- takes effect without a second load.
function Strings.load(data)
  local t = data and data.strings
  catalog = nil
  if type(t) ~= "table" then return end
  for _ in pairs(t) do
    catalog = t
    return
  end
end

function Strings.active()
  return catalog ~= nil
end

-- The lookup itself.  `context` is optional and only disambiguates sources
-- that collide; the plain key is tried after it, so a translation that does
-- not care about the distinction can supply one entry for both.
function Strings.lookup(source, context)
  -- Order matters: a mod's override beats the built-in translation, because
  -- installing a translation mod is a deliberate act and the built-in one is
  -- a default.  Both are tried context-first, then plain.
  --
  -- Written out rather than looped over { catalog, builtin }: `catalog` is
  -- nil whenever no translation mod is loaded, and ipairs stops dead at the
  -- first nil -- so the built-in table was never reached in the one case it
  -- exists for.
  local function hit(from)
    if not from then return nil end
    if context then
      local c = from[context .. "|" .. source]
      if type(c) == "string" then return c end
    end
    local p = from[source]
    if type(p) == "string" then return p end
    return nil
  end
  return hit(catalog) or hit(builtin) or source
end

-- Count `%`-directives so a translation that drops or adds one is caught
-- here rather than as a mid-battle `string.format` error.
local function specifiers(s)
  local n = 0
  for spec in s:gmatch("%%(.)") do
    if spec ~= "%" then n = n + 1 end
  end
  return n
end

-- S(source)                -> translated source
-- S(source, ...)           -> translated source, string.format'ed
-- S(source, context)       -> context-disambiguated lookup, no formatting
--
-- The two-argument forms are told apart by whether the source carries any
-- format directives: a source with no `%s` cannot be formatting, so a lone
-- string second argument is a context.
function Strings.get(source, ...)
  local argc = select("#", ...)
  if argc == 0 then return Strings.lookup(source) end

  local wants = specifiers(source)
  if wants == 0 and argc == 1 and type((...)) == "string" then
    return Strings.lookup(source, (...))
  end

  local text = Strings.lookup(source)
  -- A translation with the wrong arity would raise inside string.format,
  -- which in a battle means a crash the player cannot escape.  Fall back to
  -- the English source, which is known to match, and say so once.
  if specifiers(text) ~= wants then
    if not missing[source] then
      missing[source] = true
      require("src.core.Logger").warn(
        "strings: translation of %q has %d format directives, source has %d"
        .. " -- using the source", source, specifiers(text), wants)
    end
    text = source
  end
  local ok, out = pcall(string.format, text, ...)
  if not ok then return source end
  return out
end

-- A marker, not a lookup: returns its argument untouched.
--
-- Some templates are declared in a module-level table and formatted much
-- later (BattleState's charge-move lines, for one).  Translating at the
-- declaration would freeze the English, because those tables are built at
-- require time and Strings.load has no catalog yet; the use site therefore
-- calls Strings(template, ...) and looks the source up then.  That works at
-- runtime but leaves the literal invisible to the catalog generator, which
-- only sees what is spelled out at a call site.  Wrapping the declaration in
-- Strings.source puts it back in the harvest while changing nothing at all
-- about when the lookup happens.
function Strings.source(text)
  return text
end

setmetatable(Strings, { __call = function(_, ...) return Strings.get(...) end })

return Strings
