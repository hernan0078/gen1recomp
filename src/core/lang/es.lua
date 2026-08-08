-- Spanish for the app's own text.
--
-- Keyed by the English source exactly as written at the call site, which is
-- how src/core/Strings.lua looks everything up.  Anything absent falls
-- through to English, so a partial catalog is a partial translation rather
-- than a broken screen.
--
-- SCOPE. The app: the launcher, the options menu, the mod browser. NOT the
-- game -- names, dialogue, items and places come out of the player's
-- cartridge, and a Spanish menu over an English adventure is the honest
-- result of importing an English ROM. A player who wants the adventure in
-- Spanish imports a Spanish ROM, or installs a translation mod.
--
-- NO ACCENTS. The launcher draws in the GB font, which has no glyph for
-- n-tilde or any accented vowel -- the whole charmap's sole exception is the
-- small e-acute of POKéMON. Anything else renders as a blank, so this is
-- written in plain A-Z. It is a font limitation, not a spelling preference;
-- shipping glyphs for them would fix it properly and is worth doing.

return {
  -- ------- launcher: the game card
  ["ROM"]                  = "ROM",
  ["GOOD TO GO"]           = "TODO LISTO",
  ["ROM REQUIRED"]         = "FALTA LA ROM",
  ["Verified."]            = "Verificada.",
  ["Import ROM"]           = "Importar ROM",
  ["Re-import ROM"]        = "Reimportar ROM",
  ["Import a ROM to play"] = "Importa una ROM para jugar",
  ["ROM imported"]         = "ROM importada",
  ["That ROM could not be imported."] = "No se pudo importar esa ROM.",
  ["Or drop the .gb/.gbc file here."] = "O suelta aqui el archivo .gb/.gbc.",

  -- ------- launcher: saves
  ["SAVE FILES"]           = "PARTIDAS",
  ["Import save"]          = "Importar",
  ["Export save"]          = "Exportar",
  ["SAVE SLOT"]            = "RANURA",
  ["NEW GAME"]             = "NUEVA PARTIDA",
  ["empty slot"]           = "ranura vacia",
  ["Delete"]               = "Borrar",
  ["Sure?"]                = "Seguro?",
  ["Name save slot"]       = "Nombrar ranura",
  ["Choose a .sav save file"] = "Elige un archivo .sav",

  -- The game names as a player says them: masculine, because they follow
  -- "Pokemon" -- Pokemon Rojo, not the feminine Edicion Roja.
  ["Red"]                  = "Rojo",
  ["Blue"]                 = "Azul",
  ["Yellow"]               = "Amarillo",
  ["Play %s"]              = "Jugar PKMN %s",
  ["LOADED"]               = "CARGADA",
  ["Edit"]                 = "Editar",
  ["Import or export a .sav with the system file picker."] =
    "Importa o exporta un .sav con el selector del sistema.",

  -- ------- mods
  ["Mods"]                 = "Mods",
  ["Import mod .zip"]      = "Importar .zip",
  ["Or copy a mod .zip via USB."] = "O copia un .zip de mod por USB.",
  ["Ready"]                = "Listo",
  ["Check for updates"]    = "Buscar novedades",
  ["Versions"]             = "Versiones",

  -- the chase camera
  ["3RD PERSON"]           = "3A PERSONA",
  ["DISTANCE"]             = "DISTANCIA",
  ["CAM HEIGHT"]           = "ALTURA CAM",

  -- ------- launcher: chrome
  ["Touch Controls"]       = "Controles",
  ["RED"]                  = "ROJO",
  ["BLUE"]                 = "AZUL",
  ["YELLOW"]               = "AMARILLO",
  ["An update is available"] = "Hay una actualizacion",
  ["Open folder"]          = "Abrir carpeta",

  -- ------- mod browser
  ["MODS"]                 = "MODS",
  ["FIND MODS"]            = "BUSCAR MODS",
  ["Search mods"]          = "Buscar mods",
  ["Add a mod index"]      = "Anadir un indice",
  ["Index removed"]        = "Indice eliminado",
  ["No mod index added"]   = "Sin indice anadido",
  ["This index lists no mods yet."] = "Este indice aun no lista mods.",
  ["No mods match that search."] = "Ningun mod coincide.",
  ["No mods installed - drop a mod .zip here to add one."] =
    "No hay mods - suelta un .zip aqui para anadir uno.",
  ["Or drop a mod .zip onto the window."] =
    "O suelta un .zip de mod en la ventana.",
  ["Choose a mod .zip"]    = "Elige un .zip de mod",
  ["Mods here are listed, not reviewed - read the source and trust the author."] =
    "Los mods se listan, no se revisan - lee el codigo y confia en el autor.",
  ["Paste the index URL, or its owner/repo."] =
    "Pega la URL del indice, o su owner/repo.",
  ["Add an index to browse mods. An index is a published list; paste its URL or its owner/repo."] =
    "Anade un indice para explorar mods. Un indice es una lista publicada; "
    .. "pega su URL o su owner/repo.",
  ["%d INSTALLED"]         = "%d INSTALADOS",
  ["%d mods listed"]       = "%d mods listados",
  ["%d of %d enabled"]     = "%d de %d activos",
  ["%d of %d mods"]        = "%d de %d mods",
  ["Refreshed - %d mods listed"] = "Actualizado - %d mods listados",
  ["Downloading %s..."]    = "Descargando %s...",
  ["Added %s"]             = "Anadido %s",
  ["Installed %s %s"]      = "Instalado %s %s",

  -- ------- keyboard hints
  ["Enter to add - Esc to cancel"] = "Enter anade - Esc cancela",
  ["Enter to save - Esc to cancel - empty clears"] =
    "Enter guarda - Esc cancela - vacio borra",

  -- ------- options rows
  ["TEXT SPEED"]           = "VEL TEXTO",
  ["BATTLE ANIMATION"]     = "ANIMACIONES",
  ["BATTLE STYLE"]         = "ESTILO COMBATE",
  ["BATTLE LAYOUT"]        = "DISENO COMBATE",
  ["COLORS"]               = "COLORES",
  ["CONTROLS"]             = "CONTROLES",
  ["GAME SPEED"]           = "VELOCIDAD",
  ["MAX FPS"]              = "FPS MAXIMO",
  ["MUSIC FILTER"]         = "FILTRO MUSICA",
  ["MUSIC VOL"]            = "VOL MUSICA",
  ["PIKACHU VOL"]          = "VOL PIKACHU",
  ["SFX VOL"]              = "VOL SONIDO",
  ["RULESET"]              = "REGLAS",
  ["TILT"]                 = "INCLINACION",
  ["TOUCH PAD"]            = "CONTROL TACTIL",
  ["AUTO HIDE PAD"]        = "OCULTAR AUTO",
  ["VIDEO MODE"]           = "MODO VIDEO",
  ["VOID FILL"]            = "RELLENO VACIO",
  ["ZOOM"]                 = "ZOOM",
  ["GBC FX"]               = "GBC FX",
  ["LANGUAGE"]             = "IDIOMA",

  -- ------- shared values
  ["ON"]                   = "SI",
  ["OFF"]                  = "NO",
  ["SET"]                  = "FIJO",
  ["SHIFT"]                = "CAMBIO",
  ["OG"]                   = "OG",
  ["WIDE"]                 = "ANCHO",
  ["SURE? AGAIN"]          = "SEGURO? OTRA VEZ",
  ["%d of 3 ready"]        = "%d de 3 listos",
  ["%d badges - %s - %d caught"] = "%d medallas - %s - %d capturados",
  -- the OPTIONS exit row, appended after the mod rows hook (see OptionsMenu)
  ["CANCEL"]               = "CANCELAR",
  -- importing a Pokemon Stadium cartridge from the launcher
  ["Import Stadium ROM"]   = "Importar ROM de Stadium",
  ["Stadium ROM imported - the models build when you start the game."]
    = "ROM de Stadium importada - los modelos se crean al empezar la partida.",
  ["Could not open the file picker."]
    = "No se pudo abrir el selector de archivos.",
}
