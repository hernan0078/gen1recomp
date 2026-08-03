-- This mod's own menu text, in English or Spanish.
--
-- Scope on purpose: the ROWS THIS MOD ADDS and nothing else. The game's own
-- dialogue, item names and battle messages come out of the ROM and out of
-- the engine's Strings catalog, neither of which is ours to translate here
-- -- and a half-Spanish menu over an English game is worse than an English
-- one, so this stays to the settings a player opens to configure the 3D
-- mode.
--
-- HOW IT SWITCHES. The tables always hold English; translation happens once,
-- in the rows hook, on the way to the menu. The engine rebuilds those rows
-- whenever a setting is stepped, so both halves of a row answer in the
-- language current at the moment they are read.
--
-- WHICH LANGUAGE IT STARTS IN. The phone's, if it has an opinion -- see
-- deviceLanguage below. Once the player picks one by hand that choice is
-- persisted and wins, because someone who set the row deliberately means it.
--
-- NO ACCENTS, AND NO TILDE EITHER. The font has no glyph for N-tilde or any
-- accented vowel -- the sole exception in the whole charmap is the small
-- e-acute of POKéMON -- and it has no `~` to stand in for one either, which
-- rendered "ESPA~OL" as "ESPA OL" with a hole in it. So the Spanish here is
-- written in plain A-Z: ESPANOL, DISENO. A font limitation, not a spelling
-- preference; adding the glyphs to the atlas would fix it properly.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Lang = {}

Lang.code = "en"

-- English source -> Spanish. Keys are the English strings exactly as the
-- rows carry them, so a label that changes upstream simply stops matching
-- and falls through to English rather than showing something stale.
Lang.ES = {
  -- row labels
  ["3D WORLD"]      = "MUNDO 3D",
  ["MINIATURE"]     = "MINIATURA",
  ["SMOOTHING"]     = "SUAVIZADO",
  ["BLOCK EDGES"]   = "BORDES",
  ["ROUND WORLD"]   = "MUNDO CURVO",
  ["3D BATTLES"]    = "COMBATES 3D",
  ["BACK SPRITES"]  = "DE ESPALDAS",
  ["DAYTIME"]       = "HORA DEL DIA",
  ["WATER"]         = "AGUA",
  ["SMOOTH TURN"]   = "GIRO SUAVE",
  ["TUNE PANEL"]    = "PANEL DE CONTROL",
  ["LOOK STICK"]    = "PALANCA",
  ["LOOK SPEED"]    = "VELOCIDAD",
  ["INVERT Y"]      = "INVERTIR Y",
  ["LANGUAGE"]      = "IDIOMA",

  -- shared values
  ["OFF"]           = "NO",
  ["ON"]            = "SI",
  ["LIGHT"]         = "SUAVE",
  ["MEDIUM"]        = "MEDIO",
  ["STRONG"]        = "FUERTE",
  ["SLOW"]          = "LENTA",
  ["NORMAL"]        = "NORMAL",
  ["FAST"]          = "RAPIDA",
  ["FULL"]          = "TOTAL",
  ["SKY"]           = "CIELO",

  -- the camera rungs
  ["FULL 3D"]       = "3D TOTAL",
  ["SLIGHT"]        = "LEVE",
  ["TILTED"]        = "INCLINADO",
  ["STEEP"]         = "EMPINADO",
  ["TABLE TOP"]     = "CENITAL",
  ["1ST PERSON"]    = "1A PERSONA",

  -- the language row's own values, which never translate
  ["ENGLISH"]       = "ENGLISH",
  ["ESPANOL"]       = "ESPANOL",

  -- ------- the engine's own settings
  --
  -- Everything the OPTIONS menu shows that is a SETTING rather than part of
  -- the game: the player is configuring an app, and an app that speaks
  -- Spanish should not switch to English halfway down its own menu. What
  -- comes out of the ROM -- names, dialogue, items, places -- is deliberately
  -- untouched, because that text is the cartridge's, not ours.
  ["BATTLE ANIMATION"] = "ANIMACIONES",
  ["BATTLE LAYOUT"]    = "DISENO COMBATE",
  ["BATTLE STYLE"]     = "ESTILO COMBATE",
  ["COLORS"]           = "COLORES",
  ["CONTROLS"]         = "CONTROLES",
  ["GAME SPEED"]       = "VELOCIDAD JUEGO",
  ["MAX FPS"]          = "FPS MAXIMO",
  ["MUSIC FILTER"]     = "FILTRO MUSICA",
  ["MUSIC VOL"]        = "VOL MUSICA",
  ["PIKACHU VOL"]      = "VOL PIKACHU",
  ["RULESET"]          = "REGLAS",
  ["SFX VOL"]          = "VOL SONIDO",
  ["TEXT SPEED"]       = "VEL TEXTO",
  ["TILT"]             = "INCLINACION",
  ["TOUCH PAD"]        = "CONTROL TACTIL",
  ["VIDEO MODE"]       = "MODO VIDEO",
  ["VOID FILL"]        = "RELLENO VACIO",
  ["MODS"]             = "MODS",
  ["ZOOM"]             = "ZOOM",

  -- engine values
  ["FIT"]              = "AJUSTE",
  ["NEAR"]             = "CERCA",
  ["WIDE"]             = "LEJOS",
  ["SET"]              = "FIJO",
  ["SHIFT"]            = "CAMBIO",
  ["CANCEL"]           = "CANCELAR",

  -- the day/night ladder
  ["SYNC"]             = "SINCRO",
  ["DAY"]              = "DIA",
  ["NIGHT"]            = "NOCHE",
  ["DUSK"]             = "ATARDECER",
  ["DAWN"]             = "AMANECER",
  ["CYCLE"]            = "CICLO",
}

-- NOTE. There is deliberately no "rewrite the label tables" step here.
--
-- The first version had one, and it fought the display-time translation in
-- the rows hook: the tables ended up holding Spanish, so switching back to
-- English left every label Spanish (Lang.t has no key for "MUNDO 3D") while
-- the values, which are read through functions, correctly turned English
-- again. A menu half in each language.
--
-- So the tables always hold English and translation happens once, where the
-- rows are handed to the menu. Switching languages then cannot leave
-- anything behind, because nothing was ever changed to begin with.

function Lang.t(s)
  if Lang.code ~= "es" or type(s) ~= "string" then return s end
  local hit = Lang.ES[s]
  if hit then return hit end
  -- Rungs that carry a number are BUILT, not written: the zoom ladder reads
  -- "NEAR 1", "WIDE 2" and so on for as many steps as the screen allows, so
  -- there is no fixed string to key on. Translate the word and keep the
  -- number. Anything that is not this exact shape falls through untouched.
  local word, n = s:match("^(%u+) (%d+)$")
  if word and Lang.ES[word] then return Lang.ES[word] .. " " .. n end
  return s
end

-- What the phone is set to, as "en" / "es", or nil when there is no opinion
-- to be had (desktop, Android, an iOS build without the bridge).
--
-- love.system.getPreferredLanguage is this fork's own addition -- LOVE ships
-- no locale API -- so it is probed rather than assumed, and anything that is
-- not clearly Spanish is left alone. A phone set to Portuguese should not get
-- a Spanish menu just because the two are neighbours.
function Lang.deviceLanguage()
  local ok, code = pcall(function()
    return love.system and love.system.getPreferredLanguage
       and love.system.getPreferredLanguage()
  end)
  if not ok or type(code) ~= "string" or code == "" then return nil end
  code = code:lower()
  -- "es", "es-ES", "es-419" all mean Spanish; match the tag, not a substring,
  -- or "aes" and "test" would qualify
  if code == "es" or code:match("^es[-_]") then return "es" end
  return "en"
end

function Lang.set(code)
  Lang.code = (code == "es") and "es" or "en"
end

return Lang
