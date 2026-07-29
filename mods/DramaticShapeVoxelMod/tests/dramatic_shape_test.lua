-- Dramatic Shape Voxel Mod's own SDK suite: the mod loads clean, both
-- render pipelines land in the "render_pipelines" registry with the shape
-- the engine dispatches on, and the whole thing stays inert on a machine
-- that cannot run the 3D pass (which is exactly what the headless harness
-- is).

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Pipelines = require("src.render.Pipelines")

local Data = T.fixtures.load()
-- DS_MOD_PATH lets the suite run against a copy of the mod. The game holds
-- an open handle on the live directory while it is running, and on Windows
-- that is enough to make the headless loader's directory probe fail, so a
-- run alongside a live session points at a copy instead.
local MOD_PATH = os.getenv("DS_MOD_PATH") or "mods/DramaticShapeVoxelMod"
local run = T.sdk.loadMod(MOD_PATH, { data = Data })

T.eq(#run.errors, 0,
  "DRAMATIC_SHAPE loads clean: " .. table.concat(run.errors, "; "))

-- Game:load does this after the merge; the SDK harness merges into a
-- fixture dataset instead, so point the dispatcher at that one.
Pipelines.install(Data)

-- ------- the records reached the registry

local defs = Data.render_pipelines
T.check(type(defs) == "table", "the merge created the render_pipelines namespace")
T.check(type(defs.voxel) == "table", "the voxel pipeline is registered")
T.check(type(defs.tiltshift) == "table", "the tiltshift pipeline is registered")

T.eq(defs.voxel.label, "VOXEL", "voxel carries its options-row label")
T.eq(defs.tiltshift.label, "T-SHIFT", "tiltshift carries its options-row label")
T.eq(defs.voxel.hotkey, "3", "voxel claims hotkey 3")
T.eq(defs.tiltshift.hotkey, "6", "tiltshift claims hotkey 6")
T.check(type(defs.voxel.drawWorld) == "function",
  "voxel is a world pipeline (drawWorld)")
T.check(type(defs.tiltshift.worldPresent) == "function",
  "tiltshift is a world post-process (worldPresent)")
T.check(defs.tiltshift.drawWorld == nil,
  "tiltshift does not claim the world pass")

-- provenance: a callback that throws at play time must be attributable to
-- this mod, not reported as an engine fault
T.eq(defs._owners and defs._owners.voxel, "DRAMATIC_SHAPE",
  "the merge stamped the pipeline's owning mod")

-- ------- the ladders the engine drives

T.eq(#defs.voxel.levels, 6, "voxel exposes a six-rung ladder")
T.eq(defs.voxel.levels[1], "OFF", "rung 0 is OFF")
T.eq(defs.voxel.levels[2], "FULL",
  "FULL is the first rung after OFF -- the order those two get used in")
T.eq(defs.voxel.levels[6], "75", "the top rung is the 75-degree camera")
T.eq(Pipelines.maxLevel("voxel"), 5, "the engine reads the ladder height")
T.eq(Pipelines.levelLabel("voxel", 3), "35", "the engine reads the rung labels")

-- ------- gating: inert until switched on, and inert without a GPU

T.eq(Pipelines.level("voxel"), 0, "the mode starts switched off")
T.eq(Pipelines.worldPipeline(), nil,
  "nothing owns the world pass while every pipeline is off")

Pipelines.setLevel("voxel", 2)
T.eq(Pipelines.level("voxel"), 2, "the engine can set the mode's level")
-- the headless love stub has no depth canvas, so `available` says no and
-- the engine keeps the vanilla 2D path -- the property that makes the mod
-- safe to ship enabled
T.eq(Pipelines.worldPipeline(), nil,
  "an unavailable pipeline never takes the world pass")

-- one world pipeline at a time, and never alongside the engine's tilt
local Tilt = require("src.render.Tilt")
Tilt.setLevel(3)
Pipelines.setLevel("voxel", 1)
T.eq(Tilt.level, 0, "switching a world pipeline on switches TILT off")

-- a post-process is not a world pipeline, so it composes with tilt
Tilt.setLevel(2)
Pipelines.setLevel("tiltshift", 3)
T.eq(Tilt.level, 2, "a worldPresent pipeline leaves TILT alone")

-- ------- persistence round-trip

local opts = { tilt = 0, pipelines = {} }
Pipelines.syncOptions(opts)
T.eq(opts.pipelines.voxel, 1, "the level is written back to save.options")
T.eq(opts.pipelines.tiltshift, 3, "every pipeline's level is written back")

Pipelines.reset()
T.eq(Pipelines.level("voxel"), 0, "reset clears the live levels")
Pipelines.applyOptions(opts)
T.eq(Pipelines.level("voxel"), 1, "a restored save restores the mode")
T.eq(Pipelines.level("tiltshift"), 3, "a restored save restores the blur")

-- ------- the options rows the menu splices in

local rows = Pipelines.rows({ save = { options = opts } })
T.eq(#rows, 2, "each pipeline contributes exactly one options row")
local byLabel = {}
for _, row in ipairs(rows) do byLabel[row.label] = row end
T.check(byLabel.VOXEL ~= nil, "the VOXEL row is offered")
T.check(byLabel["T-SHIFT"] ~= nil, "the T-SHIFT row is offered")
T.eq(byLabel.VOXEL.value(), "FULL", "the row renders the current rung's label")

-- ------- this mod's own settings
--
-- None of them is a pipeline -- two parameterise the voxel pass rather than
-- owning one, and the third decides what a BATTLE is drawn over, which is
-- not a stage the registry has -- so they reach the same menu through the
-- ui.options.rows hook, and store themselves where the mod manager's
-- settings page looks.

local Runtime = require("src.mods.Runtime")
local VoxelState = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelState")

-- ------- FULL is a preset that owns the other rows
--
-- While it is selected the settings it drives come OFF the menu -- including
-- T-SHIFT, which is a pipeline row the engine spliced in. A row that no
-- longer decides anything is worse than no row.
Pipelines.setLevel("voxel", VoxelState.FULL_LEVEL)
local fullRows = Runtime.call("ui.options.rows", function(_, r) return r end,
                              { data = Data },
                              { { id = "tilt" }, { id = "pipeline:voxel" },
                                { id = "pipeline:tiltshift" } })
local fullIds = {}
for _, row in ipairs(fullRows) do fullIds[row.id] = true end
T.check(fullIds["pipeline:voxel"], "FULL keeps the VOXEL row it lives on")
T.check(not fullIds["pipeline:tiltshift"],
  "FULL takes T-SHIFT off the menu -- it owns the blur")
T.check(not fullIds["DRAMATIC_SHAPE:grid"], "and V-GRID")
T.check(not fullIds["DRAMATIC_SHAPE:curve"], "and V-CURVE")
T.check(not fullIds["DRAMATIC_SHAPE:battles"], "and 3D-BTL")

-- ------- and off FULL, the rows come back, grouped with the mode
--
-- The engine splices a pipeline row in beside TILT and lands a mod's own
-- additions at the END of the list, which would leave this mode's four rows
-- in two places with unrelated rows between them.
Pipelines.setLevel("voxel", 2)
local grouped = Runtime.call("ui.options.rows", function(_, r) return r end,
                             { data = Data },
                             { { id = "tilt" }, { id = "pipeline:voxel" },
                               { id = "pipeline:tiltshift" },
                               { id = "void_fill" } })
local order = {}
for i, row in ipairs(grouped) do order[row.id] = i end
T.check(order["pipeline:tiltshift"] < order["DRAMATIC_SHAPE:grid"],
  "the mode's settings follow its pipeline rows")
T.eq(order["DRAMATIC_SHAPE:battles"] - order["pipeline:tiltshift"], 3,
  "and sit in one unbroken block, not scattered to the end of the list")
T.check(order["void_fill"] > order["DRAMATIC_SHAPE:battles"],
  "with the engine's own later rows still after them")

-- ------- the open menu notices when FULL is stepped onto or off
--
-- OptionsMenu reads its row list every frame but builds it once, so without
-- a rebuild the rows FULL owns stay on screen until the menu is reopened --
-- and stepping OFF FULL never brings them back.
local OptionsMenu = require("src.ui.OptionsMenu")
local pressed = {}
local menuGame = {
  data = Data,
  save = { options = { pipelines = {}, modOptions = {} } },
  mods = { modOptions = {} },
  input = { wasPressed = function(_, k) return pressed[k] or false end },
  stack = { pop = function() end },
  writeOptions = function() end,
}

Pipelines.setLevel("voxel", 2)
local menu = OptionsMenu.new(menuGame)
local function rowIndex(m, id)
  for i, row in ipairs(m.rows) do if row.id == id then return i end end
end
T.check(rowIndex(menu, "DRAMATIC_SHAPE:grid"),
  "off FULL the menu opens with the mode's settings on it")

-- step the VOXEL row from 15 down to FULL, the way the player would
menu.index = rowIndex(menu, "pipeline:voxel")
pressed = { left = true }
menu:update(0)
pressed = {}
T.eq(Pipelines.level("voxel"), 1, "the step landed on FULL")
T.check(not rowIndex(menu, "DRAMATIC_SHAPE:grid"),
  "and the rows FULL owns left the OPEN menu at once")
T.check(not rowIndex(menu, "pipeline:tiltshift"), "T-SHIFT with them")
T.check(menu.index <= #menu.rows + 1, "the cursor stayed in range")

-- and back off it again
menu.index = rowIndex(menu, "pipeline:voxel")
pressed = { right = true }
menu:update(0)
pressed = {}
T.eq(Pipelines.level("voxel"), 2, "the step left FULL")
T.check(rowIndex(menu, "DRAMATIC_SHAPE:grid"),
  "and the rows came straight back without reopening the menu")
T.check(rowIndex(menu, "pipeline:tiltshift"), "T-SHIFT too")

-- level 2 is the "15" rung: any rung that is not FULL, so the settings the
-- preset owns are back on the menu
Pipelines.setLevel("voxel", 2)
local hookedRows = Runtime.call("ui.options.rows", function(_, r) return r end,
                               { data = Data }, { { id = "text_speed" } })
T.eq(#hookedRows, 4, "the options hook added a row per setting")
local grid, curve, battles = hookedRows[2], hookedRows[3], hookedRows[4]
T.eq(grid.label, "V-GRID", "the grid row carries its label")
T.eq(grid.value(), "OFF", "the grid starts off")
T.eq(curve.label, "V-CURVE", "the curve row carries its label")
T.eq(curve.value(), "OFF", "the curve starts off")
T.eq(battles.label, "3D-BTL", "the overworld-battle row carries its label")
T.eq(battles.value(), "ON",
  "overworld battles are on by default -- the mode's headline is the world "
  .. "in 3D, and a battle is where the player spends half the game")

-- stepping writes through to the one place both rows read
local settingGame = { save = { options = {} }, mods = { modOptions = {} } }
grid.step(settingGame)
T.eq(grid.value(), "ON", "stepping the row toggles the grid")
T.eq(settingGame.save.options.modOptions.DRAMATIC_SHAPE.grid, true,
  "the toggle lands in options.modOptions, where the mod manager reads it")
T.eq(settingGame.mods.modOptions.DRAMATIC_SHAPE.grid, true,
  "and in the loader's live copy, which mod.options:get reads")
grid.step(settingGame)
T.eq(grid.value(), "OFF", "stepping again toggles it back")

-- the curve is a four-rung ladder rather than a toggle, and wraps
curve.step(settingGame, 1)
T.eq(curve.value(), "1", "stepping the curve climbs its ladder")
T.eq(settingGame.save.options.modOptions.DRAMATIC_SHAPE.curve, 1,
  "the curve level persists alongside the grid, not over it")
T.eq(settingGame.save.options.modOptions.DRAMATIC_SHAPE.grid, false,
  "and the grid it shares a bucket with is untouched")
curve.step(settingGame, 1)
curve.step(settingGame, 1)
T.eq(curve.value(), "3", "the ladder reaches its top rung")
curve.step(settingGame, 1)
T.eq(curve.value(), "OFF", "and wraps back to OFF")
curve.step(settingGame, -1)
T.eq(curve.value(), "3", "stepping down from OFF wraps to the top")
curve.step(settingGame, 1)

-- the strength scales with the view height, so a rung looks the same at
-- every zoom -- and is exactly zero when the setting is off
local WorldCurve = run.loader.exports.DRAMATIC_SHAPE.lib.require("WorldCurve")
T.eq(WorldCurve.k(154), 0, "an OFF curve bends nothing")
curve.step(settingGame, 1)
T.check(math.abs(WorldCurve.k(154) - WorldCurve.AMOUNTS[2] / 154) < 1e-9,
  "rung 1's coefficient is its amount over the view height")
T.check(WorldCurve.AMOUNTS[2] < WorldCurve.AMOUNTS[3]
        and WorldCurve.AMOUNTS[3] < WorldCurve.AMOUNTS[4],
  "the ladder climbs")
T.check(math.abs(WorldCurve.k(308) * 2 - WorldCurve.k(154)) < 1e-9,
  "halving the zoom halves the coefficient, so the bend looks the same")
-- the CPU copy Voxel3D.project uses must agree with the shader's quadratic
local k = WorldCurve.k(154)
T.eq(WorldCurve.drop(k, 100, 100, 100, 100), 0,
  "nothing drops at the focus, so the ground underfoot stays flat")
T.check(math.abs(WorldCurve.drop(k, 0, 0, 3, 4) - 25 * k) < 1e-9,
  "the drop is the squared distance times the coefficient")
T.check(WorldCurve.drop(k, 0, 0, 20, 0) > 4 * WorldCurve.drop(k, 0, 0, 10, 0)
        - 1e-9,
  "and accelerates, so the far edge rolls away faster than the near one")
curve.step(settingGame, 1)
curve.step(settingGame, 1)
curve.step(settingGame, 1)
T.eq(curve.value(), "OFF", "the curve is left off for the rows below")

-- ------- the animated terrain atlas survives an engine without its seams
--
-- Regression: cycling palette modes with voxel mode on eventually killed
-- the pass outright --
--
--   render pipeline voxel failed: lib/TerrainAtlas.lua:192: attempt to
--   call field 'atlasImageData' (a nil value) -- disabled for this session
--
-- TerrainAtlas reads three OPTIONAL engine seams (README, "engine
-- internals"); this build ships only defaultAnimatedTiles, so animFrame and
-- atlasImageData are both absent. animFrame was already read guarded and
-- degrades to a frozen clock. atlasImageData was called straight, and only
-- on the branch where staticAtlas did NOT bake its own pixels -- which is
-- exactly what a palette change flips. Every mode whose world palette is
-- absent (pal() -> nil), plus RED++ (whose per-map bake sets gbcAtlas) and
-- any trueColor tileset, hands `baked = false` down to newEntry. So the
-- first map with animated water or flowers entered under one of those modes
-- took the whole pipeline down for the session.
--
-- The harness has no love.image at all, which is why the checks above never
-- reached this branch. Stand up just enough of one to walk it.

local TerrainAtlas = run.loader.exports.DRAMATIC_SHAPE.lib.require("TerrainAtlas")
local TileRenderer = require("src.render.TileRenderer")

local realImage, realNewImage = love.image, love.graphics.newImage

local function fakePixels(w, h)
  local d = { w = w or 128, h = h or 48 }
  function d:getDimensions() return self.w, self.h end
  function d:getPixel() return 0.5, 0.5, 0.5, 1 end
  function d:setPixel() end
  function d:paste() end
  return d
end

love.image = { newImageData = function(a, b)
  if type(a) == "number" then return fakePixels(a, b) end
  return fakePixels()          -- the "decoded from a path" overload
end }
-- animate() only uploads when the animation step actually turns over, so
-- counting replacePixels is how the suite sees the step move from outside.
-- builds counts entries made, and uploadFails forces the upload to throw.
local patches, builds, uploadFails = 0, 0, false
love.graphics.newImage = function()
  builds = builds + 1
  return { setFilter = function() end,
           replacePixels = function()
             if uploadFails then error("transient upload failure", 0) end
             patches = patches + 1
           end }
end

-- a tileset whose water tile rotates, i.e. one specsFor will accept
local function animatedMap(id, renderer)
  return {
    id = id,
    tileset = {
      -- a label, never opened: love.image is stubbed above
      image = "assets/tilesets/overworld.png",
      tilesPerRow = 16,
      animatedTiles = { { tile = 0x14, kind = "hshift",
                          offsets = { 0, 1, 2, 3 }, period = 20 } },
    },
    renderer = renderer,
  }
end

-- stands in for the atlas texture: what the engine hands over as
-- renderer.image, and what animate() patches through replacePixels
local base = { replacePixels = function() end,
               getDimensions = function() return 128, 48 end }

T.eq(TileRenderer.atlasImageData, nil,
  "this engine build does not carry the atlasImageData seam (the premise)")

-- 1. the crash itself: no bake of our own, and no engine seam to ask
TerrainAtlas.invalidate()
local plain = animatedMap("PLAIN", { image = base })
local ok, err = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(ok, "an unbaked atlas does not take the pipeline down: " .. tostring(err))

-- 2. and it is a real recovery, not a shrug: the pixels behind an atlas the
--    engine never replaced are the tileset art, so the animation still runs
TerrainAtlas.invalidate()
local okArt, artImg = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(okArt and artImg ~= nil,
  "unbaked terrain still animates, from the tileset art the atlas was built from")

-- 3. RED++ bakes per map and keeps no ImageData, so those pixels come back
--    off the texture. Where the driver will not read a canvas back -- which
--    is this harness, whose stub canvas has no newImageData -- the fallback
--    is to decline rather than patch grey art into a coloured atlas.
TerrainAtlas.invalidate()
local gbc = animatedMap("GBC", { image = base, gbcAtlas = true })
local okGbc, gbcImg = pcall(TerrainAtlas.animate, gbc, nil, base, false)
T.check(okGbc, "a RED++ atlas does not take the pipeline down either")
T.eq(gbcImg, nil, "and declines rather than patching raw art into a baked atlas")

-- 3b. give the harness a canvas it CAN read back and the same map animates,
--     with the pass's own render target put back afterwards -- this runs
--     mid-frame, so unbinding instead of restoring would cost the frame.
TerrainAtlas.invalidate()
local passCanvas = { name = "the pipeline's own target" }
love.graphics.setCanvas(passCanvas)
local realNewCanvas = love.graphics.newCanvas
love.graphics.newCanvas = function(w, h)
  return { w = w, h = h, setFilter = function() end,
           release = function() end,
           newImageData = function() return fakePixels(w, h) end }
end
local okRead, readImg = pcall(TerrainAtlas.animate, gbc, nil, base, false)
T.check(okRead and readImg ~= nil,
  "a RED++ atlas animates from a texture readback when the driver allows it")
T.eq(love.graphics.getCanvas(), passCanvas,
  "and the readback puts the pass's render target back")
love.graphics.newCanvas = realNewCanvas
love.graphics.setCanvas()

-- 3c. RED++ WITH the renderer's data in hand: the atlas is rebuilt on the
--     CPU from the raw art and the map's palette groups, so water animates
--     under RED++ without asking the driver for anything. This is the case
--     that was actually broken on hardware -- RED++ is the only mode where
--     staticAtlas declines to bake, so it was the only mode whose animated
--     tiles depended on a readback, and it stood still.
TerrainAtlas.invalidate()
local realNewCanvas2 = love.graphics.newCanvas
love.graphics.newCanvas = function() error("driver refuses canvas readback", 0) end
local redppMap = animatedMap("REDPP",
  { image = base, gbcAtlas = true, data = Data })
redppMap.id = "PALLET_TOWN"          -- a map the palette groups know about
redppMap.tileset.id = "OVERWORLD"
local PaletteFX = require("src.render.PaletteFX")
local modeWas = PaletteFX.mode
PaletteFX.mode = "redpp"
local okRedpp, redppImg = pcall(TerrainAtlas.animate, redppMap, nil, base, false)
T.check(okRedpp and redppImg ~= nil,
  "RED++ animates from a CPU rebuild, with no readback available at all")
PaletteFX.mode = modeWas
love.graphics.newCanvas = realNewCanvas2

-- 3d. A failure that might not repeat must not cost the animation for the
--     rest of the session. It used to: the key was condemned on the first
--     miss and nothing rebuilt it, so water stopped and stayed stopped.
TerrainAtlas.invalidate()
uploadFails = true
T.eq(TerrainAtlas.animate(plain, nil, base, false), nil,
  "a patch that throws declines the frame")
uploadFails = false
local okRetry, retryImg = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(okRetry and retryImg ~= nil,
  "and the next frame rebuilds, rather than staying dead until a hot reload")

-- but a key that keeps failing is given up on, not rebuilt every frame
TerrainAtlas.invalidate()
uploadFails = true
for _ = 1, 6 do TerrainAtlas.animate(plain, nil, base, false) end
local settledBuilds = builds
for _ = 1, 6 do TerrainAtlas.animate(plain, nil, base, false) end
T.eq(builds, settledBuilds,
  "a key that fails repeatedly is condemned rather than rebuilt forever")
uploadFails = false
TerrainAtlas.invalidate()

-- 4. the reported path end to end: cycle every palette mode over a map with
--    animated tiles. PaletteFX.pal returns nil for a mode with no world
--    palette, which is the `colors = nil` that flips staticAtlas to no-bake.
local PaletteFX = require("src.render.PaletteFX")
local sgb = { { 1, 1, 1 }, { 0.6, 0.6, 0.6 }, { 0.3, 0.3, 0.3 }, { 0, 0, 0 } }
for _, mode in ipairs(PaletteFX.MODES) do
  for _, colors in ipairs({ sgb, false }) do   -- false stands in for nil
    TerrainAtlas.invalidate()
    local okMode = pcall(TerrainAtlas.forMap, animatedMap("M_" .. mode, { image = base }),
                         colors or nil)
    T.check(okMode, "palette mode " .. mode .. " survives a terrain atlas build"
                    .. (colors and " (with a world palette)" or " (with none)"))
  end
end

-- 5. forward compatible: a build that DOES carry the seam is preferred over
--    reading the art back off disk, and one that throws is still survivable
TerrainAtlas.invalidate()
local asked = false
TileRenderer.atlasImageData = function() asked = true; return fakePixels() end
local okSeam, seamImg = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(okSeam and seamImg ~= nil,
  "an engine that provides the seam still animates")
T.check(asked, "and the engine's own accessor is what was asked")

TerrainAtlas.invalidate()
TileRenderer.atlasImageData = function() error("seam is angry") end
local okThrow = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(okThrow, "a seam that throws costs the animation, not the pipeline")

TileRenderer.atlasImageData = nil

-- ------- the tile clock, the other half of the same seam problem
--
-- animFrame is the engine's 60Hz tile-animation counter and this build does
-- not export it either. It was read guarded, so it never crashed -- it just
-- answered 0 forever, which pinned every animated tile at step 0: water and
-- flowers stood still in voxel mode and nowhere else. It is a plain local in
-- TileRenderer, but an upvalue of the exported tick(), so the mod reads the
-- real counter rather than inventing one. That distinction is the point: the
-- flat tile layer draws from this same number, so a mode switch mid-cycle
-- continues the animation instead of restarting it.

local clock = TerrainAtlas._animFrame
T.check(type(clock) == "function", "the atlas exposes its clock for the suite")

T.eq(TileRenderer.animFrame, nil,
  "this engine build does not carry the animFrame seam either (the premise)")

local before = clock()
for _ = 1, 7 do TileRenderer.tick(nil) end
T.eq(clock() - before, 7, "the clock follows the engine's tick, rather than sitting at 0")
TileRenderer.tick(1 / 60)
T.eq(clock() - before, 8, "and a 60Hz frame of wall time advances it exactly one step")

-- End to end, and observed from OUTSIDE the clock: animate() re-uploads the
-- atlas only when the step turns over, so walking a full cycle has to
-- produce one upload per step. This is what a frozen clock silently
-- prevented -- it uploads once and then agrees with itself forever, which
-- is why reading the counter back here would prove nothing.
local spec = plain.tileset.animatedTiles[1]
TerrainAtlas.invalidate()
patches = 0
TerrainAtlas.animate(plain, nil, base, false)   -- builds, uploads step 0
local built = patches
for _ = 1, #spec.offsets do
  for _ = 1, spec.period do TileRenderer.tick(nil) end
  TerrainAtlas.animate(plain, nil, base, false)
end
T.eq(patches - built, #spec.offsets,
  "walking a full cycle re-patches the atlas once per step, rather than freezing at step 0")

-- repeat calls inside one step must NOT re-upload: animate() runs once per
-- map in the neighbourhood every frame, and repatching ~130 pixels each
-- time is the cost the step check exists to avoid
local settled = patches
for _ = 1, 5 do TerrainAtlas.animate(plain, nil, base, false) end
T.eq(patches, settled, "and holds still between steps rather than repatching every call")

-- and the same two guarantees the pixel seam gets: prefer the real thing,
-- survive a broken one
TileRenderer.animFrame = function() return 4242 end
T.eq(clock(), 4242, "an engine that exports the clock is preferred over the upvalue")
TileRenderer.animFrame = function() error("clock is angry") end
local okClock, clockVal = pcall(clock)
T.check(okClock and type(clockVal) == "number",
  "a clock that throws falls back to a working one rather than propagating")
TileRenderer.animFrame = nil

-- ------- the flower's slot carries an animated SILHOUETTE, not a tile
--
-- The flower tile stands in voxel mode as a billboard one voxel deep
-- (Structures.buildFlowers), cut to the drawing's darkest tones. Meshes
-- are static, so the geometry spans the union of every frame's dark
-- pixels and the animation lives in the atlas: patch() keys everything
-- lighter to alpha 0, the shader discards it, and the silhouette trims
-- itself frame by frame. Two halves to pin down: the CLASS is derived
-- (any frames-animated tile resolves `flower` with no profile entry),
-- and the PATCH writes alpha where the frame is not dark.

local TileShape = run.loader.exports.DRAMATIC_SHAPE.lib.require("TileShape")

local flowerSet = {
  id = "T_FLOWER_PIN", image = "assets/tilesets/stub.png",
  tilesPerRow = 16, imageWidth = 128, imageHeight = 48,
  animatedTiles = { { tile = 0x03, kind = "frames", period = 20,
                      images = { "stub_flowerframe.png" },
                      sequence = { 1 } } },
}
local flowerShapes = TileShape.forMap({ tileset = flowerSet })
T.eq(flowerShapes[0x03].class, "flower",
  "a frames-animated tile is pinned `flower` with no profile entry, like grass")
T.check(flowerShapes[0x03].flat,
  "the flower cell still counts as flat ground for its neighbours")
T.eq(flowerShapes[0x03].h, 0,
  "and carries no height, so a build with no pixel access degrades to the flat tile")
T.check(flowerShapes[0x03].authored,
  "the pin is authored-strength: cell walkability cannot re-file it as plain ground")

-- the patch, observed through a recording atlas copy: a crafted frame
-- whose dark pixels form a diamond ring around one light pixel -- the
-- billboard must keep the ring AND the pale pixel it encloses, and key
-- the reachable background (light or transparent) to alpha
local slotPx = {}
local sectionNewImageData = love.image.newImageData
do
  local crafted = fakePixels()
  local ring = { ["1,0"] = true, ["0,1"] = true,
                 ["2,1"] = true, ["1,2"] = true }
  local frame = fakePixels()
  function frame:getPixel(x, y)
    if ring[x .. "," .. y] then return 0.3, 0.3, 0.3, 1 end -- dark outline
    if x == 7 and y == 0 then return 0.9, 0.9, 0.9, 0 end   -- transparent
    return 1, 1, 1, 1                       -- light: petal inside at (1,1),
  end                                       -- background everywhere else
  love.image.newImageData = function(a, b)
    if type(a) == "number" then
      local d = fakePixels(a, b)
      function d:setPixel(x, y, r, g, b2, al)
        slotPx[x .. "," .. y] = { r, g, b2, al }
      end
      return d
    end
    if tostring(a):find("flowerframe") then return frame end
    return crafted
  end
end

TerrainAtlas.invalidate()
local fmap = {
  id = "T_FLOWER_PATCH_MAP",
  tileset = {
    id = "T_FLOWER_PATCH", image = "assets/tilesets/stub2.png",
    tilesPerRow = 16, imageWidth = 128, imageHeight = 48,
    animatedTiles = { { tile = 0x03, kind = "frames", period = 20,
                        images = { "stub_flowerframe.png" },
                        sequence = { 1 } } },
  },
  renderer = { image = base },
}
local okFlower, flowerImg = pcall(TerrainAtlas.animate, fmap, nil, base, false)
T.check(okFlower and flowerImg ~= nil,
  "a flower map animates: " .. tostring(flowerImg))

local fdx = (0x03 % 16) * 8
local function slotAlpha(x, y)
  local p = slotPx[(fdx + x) .. "," .. y]
  return p and p[4]
end
T.eq(slotAlpha(1, 0), 1,
  "a dark frame pixel lands opaque -- it is the standing cutout")
T.eq(slotAlpha(1, 1), 1,
  "and so does the pale pixel the outline encloses -- the petal's inside "
  .. "rides the billboard, not just its outline")
T.eq(slotAlpha(5, 5), 0,
  "a background pixel is keyed to alpha, so the billboard's shader discards it")
T.eq(slotAlpha(7, 0), 0,
  "a transparent frame pixel stays clear rather than painting black")

love.image.newImageData = sectionNewImageData

TerrainAtlas.invalidate()
love.image, love.graphics.newImage = realImage, realNewImage

-- ------- a palette switch must not drop the geometry
--
-- Regression: toggling palettes in voxel mode flashed the flat 2D world for
-- a moment on every switch.
--
-- PaletteFX.setMode reloads the live map to rebuild its atlas, passing
-- reason "colors", and this mod dropped the map's terrain mesh on any
-- map.reloaded at all. Mesh builds are asynchronous, so the frames between
-- the drop and the first rebuilt mesh have no terrain -- and a voxel
-- drawWorld with no terrain returns nil, which IS the engine's 2D
-- fallback. The geometry was never stale to begin with: the mesher reads
-- block layout and tile ids, and the palette lives in the texture.
--
-- Every OTHER reload still has to drop it, so this pins the distinction
-- rather than just the fix.

local ChunkMesher = run.loader.exports.DRAMATIC_SHAPE.lib.require("ChunkMesher")
local Runtime = require("src.mods.Runtime")

local realInvalidate = ChunkMesher.invalidate
local realRefresh = ChunkMesher.refresh
local dropped, refreshed = {}, {}
ChunkMesher.invalidate = function(id) dropped[#dropped + 1] = id or "<every map>" end
ChunkMesher.refresh = function(id) refreshed[#refreshed + 1] = id or "<every map>" end

Runtime.emit("map.reloaded", { mapId = "PALLET_TOWN", reason = "colors" })
T.eq(#dropped, 0,
  "a palette switch keeps the terrain mesh, so the diorama stays on screen")

Runtime.emit("map.reloaded", { mapId = "PALLET_TOWN", reason = "invalidate" })
T.eq(#dropped, 1, "a reload for any other reason still drops the stale mesh")
T.eq(dropped[1], "PALLET_TOWN", "and drops exactly the map that reloaded")

-- the reason field is the engine's, not ours: a payload without one is a
-- real reload and must still invalidate
Runtime.emit("map.reloaded", { mapId = "VIRIDIAN_CITY" })
T.eq(#dropped, 2, "a reload with no stated reason is treated as a real one")

-- a block edit (Cut, a door stamp, the tree regrowing on re-entry) is a
-- REFRESH, not a drop: the stale mesh keeps drawing while the rebuild
-- cooks, so the scene never blinks down to the flat 2D path
Runtime.emit("world.block_replaced", { mapId = "PALLET_TOWN" })
T.eq(#dropped, 2, "a replaced block does not drop the mesh outright")
T.eq(#refreshed, 1, "it refreshes the mesh in place instead")
T.eq(refreshed[1], "PALLET_TOWN", "and refreshes exactly the edited map")

-- ------- and the edits the engine does NOT announce
--
-- Cut swaps its tree block, the regrowth restores it on re-entry, and the
-- card-key doors are stamped on floor load -- all writing the block layer
-- directly, none of them emitting world.block_replaced. The mod wraps
-- Map:setBlock rather than asking the engine to announce each one (an
-- earlier cut changed the engine, which is the wrong place: it edits the
-- game for one mod, and every future block write has to remember).
--
-- These run through a REAL Map, so they also pin that the wrap survives
-- whatever the engine does to that method.

local Map = require("src.world.Map")
local function fakeMap(id)
  return setmetatable({
    id = id,
    def = { width = 2, height = 2, blocks = { 1, 1, 1, 1 }, borderBlock = 0 },
  }, Map)
end

local m = fakeMap("ROUTE_2")
refreshed = {}

m:setBlock(0, 0, 9)
T.eq(#refreshed, 1, "a direct setBlock refreshes the mesh -- this is Cut's path")
T.eq(refreshed[1], "ROUTE_2", "and names the map that was edited")
T.eq(m:blockAt(0, 0), 9, "and the block really changed")

-- the regrowth rewrites every block it recorded, changed or not; a write
-- that changes nothing must not throw the mesh away
m:setBlock(0, 0, 9)
T.eq(#refreshed, 1, "rewriting a block with the value it already held is not an edit")

-- setBlock silently ignores an out-of-bounds write, so there is nothing
-- to rebuild for one
m:setBlock(99, 99, 3)
T.eq(#refreshed, 1, "an out-of-bounds write refreshes nothing")

ChunkMesher.invalidate = realInvalidate
ChunkMesher.refresh = realRefresh

-- ------- the non-colour palette modes must not come through as SGB
--
-- Regression: GRAY, INVERTED and CLASSIC all rendered as the SGB palette in
-- voxel mode -- grey and inverted came out blue.
--
-- The engine's paletteFor hands back a map's RAW SGB zone palette. The flat
-- path then runs it through PaletteFX.effectiveColors on the way to the
-- shade-remap shader, and THAT is where the non-colour modes happen: OG and
-- OG INV swap in the DMG greys, CLASSIC swaps in the green set, GBC INV
-- permutes the zone's own shades. This pass bakes colour into the atlas
-- ahead of the draw instead of shading at blit time, so it never reached
-- that call and every mode drew the raw zone palette.
--
-- Asserted against what each mode should PAINT, not against the engine
-- function, so this stays a claim about the picture rather than a
-- restatement of the implementation.

local VoxelScene = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelScene")
local modeColors = VoxelScene._modeColors
T.check(type(modeColors) == "function", "the scene exposes its palette resolve")

-- a recognisable stand-in for a map's SGB zone palette: strongly blue, so
-- "came through as SGB" is visible in the values themselves
local sgbBlue = { { 248, 248, 248 }, { 96, 152, 232 },
                  { 40, 80, 176 }, { 8, 24, 64 } }
local function paletteForBlue() return sgbBlue end
local function under(mode, fn)
  local prev = PaletteFX.mode
  PaletteFX.mode = mode
  local ok, err = pcall(fn)
  PaletteFX.mode = prev
  if not ok then error(err, 0) end
end

local function sameColors(a, b)
  if not (a and b) then return false end
  for i = 1, 4 do
    for ch = 1, 3 do
      if a[i][ch] ~= b[i][ch] then return false end
    end
  end
  return true
end

under("gbc", function()
  T.check(sameColors(modeColors(paletteForBlue), sgbBlue),
    "GBC is a colour mode, so the zone palette passes through untouched")
end)

under("og", function()
  local c = modeColors(paletteForBlue)
  T.check(sameColors(c, PaletteFX.GRAYS),
    "GRAY paints the DMG greys, not the map's SGB blue")
  T.check(not sameColors(c, sgbBlue), "and is not the SGB palette in disguise")
end)

under("og_inv", function()
  local c = modeColors(paletteForBlue)
  T.check(sameColors(c, PaletteFX.permute(PaletteFX.GRAYS,
                                          { [0] = 3, [1] = 2, [2] = 1, [3] = 0 })),
    "GRAY INV paints the greys with the shade ramp reversed")
  T.eq(c[1][1], PaletteFX.GRAYS[4][1],
    "so the lightest shade becomes the darkest -- an actual inversion")
end)

under("classic", function()
  T.check(sameColors(modeColors(paletteForBlue), PaletteFX.CLASSIC),
    "CLASSIC paints the green DMG set")
end)

under("gbc_inv", function()
  local c = modeColors(paletteForBlue)
  T.check(not sameColors(c, sgbBlue), "GBC INV does not pass the zone palette through")
  for i = 1, 4 do
    T.check(sameColors({ c[i], c[i], c[i], c[i] },
                       { sgbBlue[5 - i], sgbBlue[5 - i], sgbBlue[5 - i], sgbBlue[5 - i] }),
      "GBC INV reverses the zone's own shades, keeping its colours (shade " .. i .. ")")
  end
end)

-- a map with no palette at all stays uncoloured rather than inventing one,
-- which is what the flat path does when it has nothing to send the shader
T.eq(modeColors(function() return nil end), nil,
  "a map with no world palette bakes no colour, as on the flat path")
T.eq(modeColors(nil), nil, "and a pipeline given no paletteFor at all is safe")

-- ------- the hotkeys this mod claims
--
--   3  VOXEL    cycle the camera ladder
--   5  V-GRID   toggle the wireframe
--   6  T-SHIFT  cycle the blur ladder
--   7  V-CURVE  cycle the horizon bend
--   8  3D-BTL   toggle overworld battles
--
-- Only 6 reaches the pipeline registry the documented way. Game:keypressed
-- answers the engine's own display keys first and returns -- 3 is TILT and
-- 5 is GBC FX -- expressly so a pipeline cannot shadow one, and 7 and 8
-- belong to settings that own no pass and so have no registry to claim
-- from. The mod therefore wraps Game:keypressed, and these pin what that
-- wrapper is allowed to take.

local Game = require("src.core.Game")
Pipelines.reset()
Pipelines.setLevel("voxel", 0)
Pipelines.setLevel("tiltshift", 0)

-- a free-roam game: Zoom.gateOK wants the top screen to BE the overworld,
-- not transitioning and not running a script
local keyGame
local overworld = { transitioning = false }
keyGame = {
  overworld = overworld,
  stack = { top = function() return overworld end },
  save = { options = { modOptions = {} } },
  mods = { modOptions = {} },
  writeOptions = function() end,
}

local VoxelGrid = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelGrid")
local Curve = run.loader.exports.DRAMATIC_SHAPE.lib.require("WorldCurve")

-- ------- 3 walks the ANGLE rungs and steps over FULL
--
-- The key is a display-mode cycler: it should change the camera and nothing
-- else. FULL reaches in and rewrites four other settings, so landing on it
-- mid-walk would silently turn the blur to maximum and flatten the horizon
-- with nothing on screen saying a keypress had done it.
Pipelines.setLevel("voxel", 0)
local walk = {}
for _ = 1, 6 do
  Game.keypressed(keyGame, "3")
  walk[#walk + 1] = Pipelines.levelLabel("voxel")
end
T.eq(table.concat(walk, ","), "15,35,50,75,OFF,15",
  "3 walks OFF -> 15 -> 35 -> 50 -> 75 and wraps, never touching FULL")

-- FULL is 35 degrees, so a press from it goes ON to 50 rather than back to
-- the rung that shows the same camera -- the key never appears to do nothing.
-- Matched by angle, so this follows FULL if it is ever retuned.
T.eq(VoxelState.ANGLES_DEG[VoxelState.FULL_LEVEL + 1], 35,
  "FULL is the 35-degree camera")
Pipelines.setLevel("voxel", VoxelState.FULL_LEVEL)
Game.keypressed(keyGame, "3")
T.eq(Pipelines.levelLabel("voxel"), "50",
  "a press from FULL goes to 50, since FULL already IS the 35 camera")

Pipelines.setLevel("voxel", 0)
Game.keypressed(keyGame, "3")
T.eq(Pipelines.level("voxel"), 2, "3 cycles the voxel camera ladder")
Game.keypressed(keyGame, "3")
T.eq(Pipelines.level("voxel"), 3, "and keeps climbing it")

Game.keypressed(keyGame, "6")
T.eq(Pipelines.level("tiltshift"), 1, "6 cycles the tilt-shift blur")

Game.keypressed(keyGame, "5")
T.eq(VoxelGrid.setting:get(), true, "5 toggles V-GRID on")
Game.keypressed(keyGame, "5")
T.eq(VoxelGrid.setting:get(), false, "and off again")

local curveBefore = Curve.setting:get()
Game.keypressed(keyGame, "7")
T.neq(Curve.setting:get(), curveBefore, "7 cycles V-CURVE")

local Battles = run.loader.exports.DRAMATIC_SHAPE.lib.require("OverworldBattle")
T.eq(Battles.setting:get(), true, "3D-BTL starts on")
Game.keypressed(keyGame, "8")
T.eq(Battles.setting:get(), false, "8 toggles overworld battles off")
Game.keypressed(keyGame, "8")
T.eq(Battles.setting:get(), true, "and back on")

-- 3 also clears the two engine modes it displaced. Without this a player
-- who left TILT or GBC FX on before enabling the mod has no key left to
-- turn them off with, and both fight the diorama -- TILT is the flat fake
-- of what this mode does for real, GBC FX a present pass over the top.
local GBCFX = require("src.render.GBCFX")
Tilt.setLevel(2)
GBCFX.setLevel(3)
keyGame.save.options.tilt = 2
keyGame.save.options.gbcfx = 3

Game.keypressed(keyGame, "3")
T.eq(keyGame.save.options.tilt, 0, "3 turns TILT off in the save")
T.eq(Tilt.level, 0, "and on the live renderer")
T.eq(keyGame.save.options.gbcfx, 0, "3 turns GBC FX off in the save")
T.eq(GBCFX.level, 0, "and on the live renderer")

-- Every press, not just the one that switches the mode on. This is the
-- half the registry does NOT cover: its tilt exclusion fires when a world
-- pipeline takes the pass, so a press that switches voxel ON would clear
-- TILT with or without us. Park the ladder on its top rung and turn both
-- back on, so the single press under test is the one that wraps to OFF --
-- where nothing else is going to clear them.
-- 5 is the "75" rung, the last one the key walks before it wraps to OFF
Pipelines.setLevel("voxel", 5)
Tilt.setLevel(3)
GBCFX.setLevel(4)
keyGame.save.options.tilt = 3
keyGame.save.options.gbcfx = 4

Game.keypressed(keyGame, "3")
T.eq(Pipelines.level("voxel"), 0, "the press wraps the ladder back to OFF")
T.eq(keyGame.save.options.tilt, 0, "the press that wraps to OFF still clears TILT")
T.eq(Tilt.level, 0, "with the renderer agreeing")
T.eq(keyGame.save.options.gbcfx, 0, "and still clears GBC FX")
T.eq(GBCFX.level, 0, "with the renderer agreeing there too")

-- but 6 must not: T-SHIFT is a post-process that composes with TILT, and
-- the registry deliberately leaves it alone
Tilt.setLevel(2)
keyGame.save.options.tilt = 2
Game.keypressed(keyGame, "6")
T.eq(keyGame.save.options.tilt, 2, "6 leaves TILT alone -- the blur composes with it")
Tilt.setLevel(0)
keyGame.save.options.tilt = 0

-- the engine's own keys the mod did NOT claim must still reach it: 4 is
-- ZOOM, and taking it would be a bug rather than a feature
local zoomKeyReached = false
local realZoomGate = require("src.render.Zoom").gateOK
require("src.render.Zoom").gateOK = function() zoomKeyReached = true; return false end
Game.keypressed(keyGame, "4")
require("src.render.Zoom").gateOK = realZoomGate
T.check(zoomKeyReached, "a key this mod does not claim still reaches the engine")

-- A screen with its own key handler owns the keyboard: typing a nickname
-- must not cycle a render mode behind the text box.
local gridBefore = VoxelGrid.setting:get()
local voxelBefore = Pipelines.level("voxel")
local typed = {}
local menu = { onKeyPressed = function(_, k) typed[#typed + 1] = k end }
keyGame.stack.top = function() return menu end
for _, k in ipairs({ "3", "5", "6", "7" }) do Game.keypressed(keyGame, k) end
T.eq(#typed, 4, "every claimed key goes to a screen that handles keys itself")
T.eq(VoxelGrid.setting:get(), gridBefore, "V-GRID is untouched while a screen has focus")
T.eq(Pipelines.level("voxel"), voxelBefore, "and so is the voxel ladder")

-- and the free-roam gate the engine applies to its own display keys applies
-- to the settings too: no flipping the wireframe mid-cutscene
keyGame.stack.top = function() return overworld end
overworld.transitioning = true
local midWarp = VoxelGrid.setting:get()
Game.keypressed(keyGame, "5")
T.eq(VoxelGrid.setting:get(), midWarp, "V-GRID refuses mid-transition, as the mode does")
overworld.transitioning = false

-- ------- the sky at the top rung
--
-- At 75 degrees the camera is pitched far enough over that the horizon is
-- in frame, so the void behind the diorama becomes a sky rather than the
-- black plate it reads as at every rung below. Outdoors only: a house or a
-- cave is a room with a ceiling, and the void past its walls is the
-- outside of a box, not open air.

local Voxel = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelState")
local skyFor = VoxelScene._skyFor
local skyStrength = VoxelScene._skyStrength
T.check(type(skyFor) == "function", "the scene exposes its sky resolve")

local outside = { def = { id = "PALLET_TOWN", tileset = "OVERWORLD" } }
local inside = { def = { id = "REDS_HOUSE_1F", tileset = "HOUSE" } }
local TOP = math.rad(Voxel.ANGLES_DEG[Voxel.MAX_LEVEL + 1])

-- the ladder, by angle: only the top rung paints anything
for level = 0, Voxel.MAX_LEVEL do
  Voxel.angle = math.rad(Voxel.ANGLES_DEG[level + 1])
  local sky = skyFor(outside)
  if level == Voxel.MAX_LEVEL then
    T.check(sky ~= nil, "the 75-degree rung paints a sky outdoors")
    T.eq(sky[4], 1, "and paints it at full strength")
  else
    T.eq(sky, nil, "rung " .. level .. " leaves the void alone")
  end
end

-- indoors, never -- at any rung, including the top one
for level = 0, Voxel.MAX_LEVEL do
  Voxel.angle = math.rad(Voxel.ANGLES_DEG[level + 1])
  T.eq(skyFor(inside), nil, "an interior has no sky at rung " .. level)
end
Voxel.angle = TOP
T.eq(skyFor(inside), nil, "not even at 75 degrees, where outdoors would")

-- a map record with nothing to ask is not a crash
T.eq(skyFor(nil), nil, "no map, no sky")
T.eq(skyFor({}), nil, "a map with no def is not an outdoor map")

-- it fades in with the camera tween rather than popping on the keypress
T.eq(skyStrength(math.rad(50)), 0, "the rung below the top is still skyless")
T.eq(skyStrength(TOP), 1, "the top rung is full sky")
local mid = skyStrength(math.rad(62.5))
T.check(mid > 0 and mid < 1, "and the tween between them is partial")
T.check(skyStrength(math.rad(70)) > skyStrength(math.rad(60)),
  "strengthening as the camera pitches over")
T.eq(skyStrength(math.rad(15)), 0, "a shallow pitch paints nothing at all")

-- the colour answers to the display mode, exactly as the terrain does: a
-- hardcoded blue would sit wrong in the modes that are not colour modes
Voxel.angle = TOP
local function skyRGB(mode)
  local prev = PaletteFX.mode
  PaletteFX.mode = mode
  local c = skyFor(outside)
  PaletteFX.mode = prev
  return c
end

local blue = skyRGB("gbc")
T.check(blue[3] > blue[1], "in a colour mode the sky is blue -- more blue than red")

local grey = skyRGB("og")
T.check(math.abs(grey[1] - grey[2]) < 1e-6 and math.abs(grey[2] - grey[3]) < 1e-6,
  "GRAY paints a grey sky, not a blue one")

local green = skyRGB("classic")
T.check(green[2] > green[1] and green[2] > green[3],
  "CLASSIC paints a green sky, matching its green world")

T.check(skyRGB("gbc_inv")[3] ~= blue[3],
  "GBC INV does not paint the same sky as GBC")

Voxel.angle = 0

-- ------- overworld battles: where the fight is staged
--
-- The arena search is pure map arithmetic, so it is driven here against
-- hand-drawn maps rather than a fixture: the shape it looks for, the order
-- it relaxes in, and what it refuses are all things a picture can state
-- exactly.
--
-- The stub answers the small surface BattleArena asks a Map for. `rows` are
-- strings, one per cell row, "." open and anything else solid; "w" is water
-- (open to a surfer only) and "d" a warp tile.

local BattleArena = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleArena")

local function stubMap(rows)
  local at = function(cx, cy)
    local row = rows[cy + 1]
    return row and row:sub(cx + 1, cx + 1) or "#"
  end
  return {
    widthCells = #rows[1],
    heightCells = #rows,
    inBounds = function(_, cx, cy)
      return cx >= 0 and cy >= 0 and cx < #rows[1] and cy < #rows
    end,
    warpAtCell = function() return nil end,
    isWarpTileCell = function(_, cx, cy) return at(cx, cy) == "d" end,
    isWalkableCell = function(_, cx, cy) return at(cx, cy) == "." end,
    isWaterCell = function(_, cx, cy) return at(cx, cy) == "w" end,
    isGrassCell = function(_, cx, cy) return at(cx, cy) == "g" end,
  }
end

-- a field with room for the wide arena on its right-hand side only
local field = stubMap({
  "##########",
  "#....#####",
  "#....#####",
  "#....#####",
  "#....#####",
  "#....#####",
  "#....#####",
  "##########",
})

local arena = BattleArena.find(field, 2, 3, false)
T.check(arena ~= nil, "a field with a 3x6 clearing has an arena")
T.eq(arena.shape, "wide", "and it is the wide shape, not the fallback")
T.eq(arena.w, 3, "the wide arena is three cells across")
T.eq(arena.h, 6, "and six deep")

-- the two mons stand three cells apart down the middle column, which is
-- what the picture in BattleArena says and what the camera is built around
T.eq(arena.enemyCell[1], arena.playerCell[1],
  "both mons stand in the arena's middle column")
T.eq(arena.playerCell[2] - arena.enemyCell[2], 3,
  "with three cells of ground between them")
T.check(arena.enemyCell[2] < arena.playerCell[2],
  "the enemy is the NORTH one -- the far end from a camera parked south")

-- every cell of the shape is open, apron included: that one-cell margin is
-- the difference between a staged shot and a fight in a doorway
for cy = arena.y, arena.y + arena.h - 1 do
  for cx = arena.x, arena.x + arena.w - 1 do
    T.check(field:isWalkableCell(cx, cy),
      ("arena cell (%d,%d) is open ground"):format(cx, cy))
  end
end

-- world-pixel centres, which is the unit everything downstream works in
T.eq(arena.player[1], arena.playerCell[1] * 16 + 8,
  "the player's mark is the centre of its cell in world pixels")
T.eq(arena.mid[2], (arena.enemy[2] + arena.player[2]) / 2,
  "and the midpoint is halfway between the two")

-- nearest, not first found: two clearings, and the one under the player wins.
-- Wide enough that the battle camera -- which stands a few cells east and
-- south of whatever it is aimed at -- is over real ground for BOTH of them,
-- so this measures proximity rather than the clearance preference below.
local twin = stubMap({
  "########################",
  "#.##########.###########",
  "#.##########.###########",
  "#.##########.###########",
  "#.##########.###########",
  "########################",
  "########################",
  "########################",
  "########################",
  "########################",
})
local near = BattleArena.find(twin, 12, 3, false)
T.eq(near.shape, "narrow", "no 3x6 anywhere, so the search relaxes")
T.eq(near.x, 12, "and takes the corridor the player is standing in")
T.eq(BattleArena.find(twin, 1, 3, false).x, 1,
  "the same map from the other side picks the other one")

-- the wide shape wins even when a narrow one is closer: it is the shot this
-- mode is framed for, so proximity does not get to overrule it
local both = stubMap({
  "#.#########",
  "#.####...##",
  "#.####...##",
  "#.####...##",
  "######...##",
  "######...##",
  "######...##",
})
T.eq(BattleArena.find(both, 1, 1, false).shape, "wide",
  "a wide arena across the map beats a narrow one underfoot")

-- water is ground for a surfer and nothing at all for anyone else
local sea = stubMap({
  "wwwwww",
  "wwwwww",
  "wwwwww",
  "wwwwww",
  "wwwwww",
  "wwwwww",
})
T.eq(BattleArena.find(sea, 2, 2, false), nil,
  "open water is not open ground to someone walking")
T.check(BattleArena.find(sea, 2, 2, true) ~= nil,
  "but it is to a surfer, who is standing on it")

-- tall grass is walkable and is still not a stage: it is knee-high geometry
-- standing between a nearly-level camera and the mon behind it
local meadow = stubMap({
  "########",
  "#ggg..g#",
  "#ggg..g#",
  "#ggg..g#",
  "#ggg..g#",
  "#ggg..g#",
  "#ggg..g#",
  "########",
})
local mown = BattleArena.find(meadow, 2, 3, false)
T.check(mown ~= nil, "a meadow with a bare strip still has an arena")
for cy = mown.y, mown.y + mown.h - 1 do
  for cx = mown.x, mown.x + mown.w - 1 do
    T.check(not meadow:isGrassCell(cx, cy),
      ("no cell of the arena is tall grass (%d,%d)"):format(cx, cy))
  end
end
T.eq(BattleArena.find(stubMap({
  "#####", "#ggg#", "#ggg#", "#ggg#", "#ggg#", "#ggg#", "#ggg#", "#####",
}), 2, 3, false), nil,
  "a map that is nothing but grass has nowhere to stand a fight")

-- a doormat is walkable and is still not a stage
local hall = stubMap({
  "######",
  "#..d.#",
  "#....#",
  "#....#",
  "#....#",
  "######",
})
local halled = BattleArena.find(hall, 2, 3, false)
T.check(halled == nil or halled.shape == "narrow",
  "a warp tile is excluded, so the room's only 3x6 does not qualify")

T.eq(BattleArena.find(stubMap({ "###", "###" }), 1, 1, false), nil,
  "a map with no room at all yields no arena, and the battle draws plainly")

-- an authored refusal is honoured over the search: a map looked at and found
-- to have nowhere a fight reads has to be able to say so, or the fallback
-- goes and finds one of the spots that were already rejected by eye
local roomy = stubMap({
  "#####", "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", "#####",
})
roomy.id = "TEST_REFUSED"
T.check(BattleArena.find(roomy, 2, 3, false) ~= nil,
  "a roomy map finds an arena by search when nothing is authored")
BattleArena.setOverride("TEST_REFUSED", false)
T.eq(BattleArena.find(roomy, 2, 3, false), nil,
  "an authored false refuses the map outright, search and all")
BattleArena.setOverride("TEST_REFUSED", nil)
T.check(BattleArena.find(roomy, 2, 3, false) ~= nil,
  "and dropping the refusal restores the search")

-- ------- overworld battles: the over-the-shoulder framing
--
-- The claim the whole shot rests on. The two pics are PINNED to their cells,
-- so the rig has to put those two patches of ground exactly where the GB's
-- own battle screen puts its two pics -- the player's low and left at
-- (40, 96), the enemy's high and right at (124, 56). Reprojected through the
-- real camera rather than asserted about the constants, so the day someone
-- retunes the rig this either still lands or says so.

local BattleCam = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleCam")
local BattleScene = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleScene")
local Voxel3Dcam = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")

-- where a world point lands in the 160x144 frame, or nil behind the camera
local function project(cam, point, w, h, fov)
  local saved = cam.fov
  if fov then cam.fov = fov end
  Voxel3Dcam.camera = cam
  local m = Voxel3Dcam.viewProjection(0, 0, w or 160, h or 144)
  Voxel3Dcam.camera = nil
  cam.fov = saved
  local x = m[1] * point[1] + m[2] * 0 + m[3] * point[2] + m[4]
  local y = m[5] * point[1] + m[6] * 0 + m[7] * point[2] + m[8]
  local cw = m[13] * point[1] + m[14] * 0 + m[15] * point[2] + m[16]
  if cw <= 1e-6 then return nil end
  return (x / cw * 0.5 + 0.5) * (w or 160), (y / cw * 0.5 + 0.5) * (h or 144)
end

BattleCam.reset()
local shot = BattleArena.find(field, 2, 3, false)
local rig, pitch = BattleCam.rig(shot, 0)

local px, py = project(rig, shot.player)
local ex, ey = project(rig, shot.enemy)
T.check(px ~= nil and ex ~= nil, "both marks are in front of the camera")
T.check(math.abs(px - 26) < 1 and math.abs(py - 96) < 1,
  ("the player's cell projects onto its pic's feet at (26, 96): got "
   .. "(%.2f, %.2f)"):format(px, py))
T.check(math.abs(ex - 124) < 1 and math.abs(ey - 56) < 1,
  ("the enemy's cell projects onto its pic's feet at (124, 56): got "
   .. "(%.2f, %.2f)"):format(ex, ey))
T.check(px < ex, "which puts the player's mon LEFT of the enemy's")
T.check(py > ey, "and lower in the frame -- nearer the camera")

-- low and long: the eye is near the floor looking almost along it, which is
-- what a 56-pixel sprite standing on a 16-pixel tile costs
T.check(pitch > math.rad(60) and pitch < math.rad(85),
  "the rig watches the arena from near ground level")

-- ------- a mon covers its own square
--
-- The pics are drawn at INTEGER scales -- 56 pixels for a front pic at 1x, 64
-- for a back pic at 2x -- so the only way a mon can stand in one overworld
-- square is for the camera to make that square that big. This is the pair of
-- equations the default rig was solved against alongside the two anchors, and
-- it is the one that sets how far away the camera has to be.
local function span(cam, point)
  local a = project(cam, { point[1] - 8, point[2] })
  local b = project(cam, { point[1] + 8, point[2] })
  return math.abs(b - a)
end

T.check(math.abs(span(rig, shot.player) - 64) < 4,
  ("the player's square is a back pic wide (64px at 2x): got %.2f")
  :format(span(rig, shot.player)))
T.check(math.abs(span(rig, shot.enemy) - 56) < 4,
  ("the enemy's square is a front pic wide (56px at 1x): got %.2f")
  :format(span(rig, shot.enemy)))

-- ------- the close rig, for rooms the default cannot stand back from
--
-- Five blocks is further than a gym is wide, so on one the default eye lands
-- outside the map and the border ring crosses the near mon. An arena asks for
-- the short rig by name, and the two things that have to hold are that it
-- really is close enough to sit in a room, and that it frames the SAME shot
-- -- both marks still on their anchors -- so swapping rigs changes the lens
-- and nothing about the composition.
local function eyeDistance(cam)
  local dx = cam.eye[1] - cam.focus[1]
  local dy = cam.eye[2] - cam.focus[2]
  local dz = cam.eye[3] - cam.focus[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

T.check(eyeDistance(rig) > 120,
  "the default long lens stands well back -- that is what sizes the mons")

BattleCam.reset()
local snug = { mid = shot.mid, cam = "wide" }
local closeRig = BattleCam.rig(snug, 0)
local cd = eyeDistance(closeRig)
T.check(cd < 80,
  ("the wide lens is within five cells, so it fits inside a gym: got %.1f")
  :format(cd))
T.check(cd < eyeDistance(rig), "and is nearer than the default")

local cpx, cpy = project(closeRig, shot.player)
local cex, cey = project(closeRig, shot.enemy)
T.check(math.abs(cpx - 26) < 1 and math.abs(cpy - 96) < 1,
  ("the wide lens lands the player's mark on the same anchor: (%.2f, %.2f)")
  :format(cpx, cpy))
T.check(math.abs(cex - 124) < 1 and math.abs(cey - 56) < 1,
  ("and the enemy's too: (%.2f, %.2f)"):format(cex, cey))
T.check(span(closeRig, shot.player) < span(rig, shot.player),
  "the mons render smaller on it, which is what it trades for fitting")

-- an arena picks its rig by name, and anything unnamed gets the default
T.eq(BattleCam.rigFor({ cam = "wide" }), BattleCam.RIGS.wide,
  "an arena that asks for the wide lens gets it")
T.eq(BattleCam.rigFor({}), BattleCam.RIGS.tele, "and one that asks for nothing")
T.eq(BattleCam.rigFor({ cam = "nonsense" }), BattleCam.RIGS.tele,
  "as does one that asks for a rig that does not exist")

-- ------- the pins survive the window
--
-- The scene renders at the WINDOW's resolution, not the GB's, so the rig's
-- field of view is widened by the ratio the window bears to the letterbox.
-- What that has to buy is exactness: the letterbox sub-rectangle of the
-- widened render must be the framing the rig asked for, or the pics come
-- unpinned from the ground by however much it is out.

for _, win in ipairs({ { 1920, 1080, 7 }, { 640, 576, 4 }, { 1280, 1024, 7 },
                       { 800, 720, 5 } }) do
  local pw, ph, s = win[1], win[2], win[3]
  local lx = math.floor((pw - 160 * s) / 2)
  local ly = math.floor((ph - 144 * s) / 2)
  local wide = BattleScene.letterboxFov(rig.fov, ph, s)
  T.check(wide >= rig.fov - 1e-9,
    "a window taller than the letterbox needs a wider lens, never a tighter one")
  local wx, wy = project(rig, shot.player, pw, ph, wide)
  local gx, gy = (wx - lx) / s, (wy - ly) / s
  T.check(math.abs(gx - px) < 0.01 and math.abs(gy - py) < 0.01,
    ("%dx%d at scale %d reproduces the GB framing exactly: (%.3f, %.3f) vs "
     .. "(%.3f, %.3f)"):format(pw, ph, s, gx, gy, px, py))
end

-- ------- the drift
--
-- With the pics pinned, the drift is not decoration on a backdrop -- it
-- moves the mons themselves, and the whole reason it reads as depth is that
-- it moves the near one and the far one by DIFFERENT amounts. A backdrop
-- that merely slid would move them by the same one.
BattleCam.update(BattleCam.PAN_PERIOD / 4)
local rig2 = BattleCam.rig(shot, 0)
local px2 = project(rig2, shot.player)
local ex2 = project(rig2, shot.enemy)
T.check(math.abs(px2 - px) > 0.5, "the drift moves the near mark")
T.check((px2 - px) * (ex2 - ex) < 0,
  "and the far one the OTHER WAY -- parallax about a point between them")
T.check(math.abs(px2 - px) < 8 and math.abs(ex2 - ex) < 8,
  "neither is flung across the frame: the mons drift, they do not travel")

-- very slow: a quarter of the cycle is several seconds, and what it moves in
-- one FRAME has to be imperceptible
BattleCam.reset()
BattleCam.update(1 / 60)
local slow = BattleCam.rig(shot, 0)
local sx = project(slow, shot.player)
T.check(math.abs(sx - px) < 0.2,
  "one frame of drift moves a mon by a fifth of a pixel")

-- a placed camera declines the world curve outright: the bend exists to
-- drop the horizon away from a walking player, and here it would tip the
-- arena floor out from under the two mons pinned to it
T.eq(rig.curve, 0, "the battle camera switches the world curve off")

-- ------- the hit flash belongs to the mons, not the screen
--
-- The engine draws it as a full-screen white rectangle, which is a flash on
-- a white battle field and a whiteout of the map, the HUD and the text box
-- over a world. It is dropped on the way past and put back on the two cards.
local Battles = run.loader.exports.DRAMATIC_SHAPE.lib.require("OverworldBattle")
T.eq(Battles.flashing(nil), false, "no battle, no flash")
T.eq(Battles.flashing({ fx = {}, frame = 0 }), false,
  "a battle with no flash counter is not flashing")
T.eq(Battles.flashing({ fx = { flash = 0 }, frame = 0 }), false,
  "nor one whose counter has run out")
T.eq(Battles.flashing({ fx = { flash = 16 }, frame = 0 }), true,
  "a live counter flashes on the frames the engine would")
T.eq(Battles.flashing({ fx = { flash = 16 }, frame = 2 }), false,
  "and is dark on the others, which is what makes it flicker")
T.eq(Battles.flashing({ fx = { flash = 16 }, frame = 5 }), true,
  "on a four-frame cycle")

-- ------- the wireframe is forced on in a battle
--
-- A fight is a staged shot rather than the world being walked through, so it
-- always wears the seams. The player's own V-GRID row must not be touched by
-- that -- an override, not a write, or switching the mode off mid-battle
-- would quietly rewrite a setting they chose.
local Grid = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelGrid")
Grid.override = nil
local rowWas = Grid.setting:get()
T.eq(Grid.enabled(), rowWas and true or false,
  "with no override the wireframe follows the row")
Grid.override = true
T.eq(Grid.enabled(), true, "an override forces it on")
T.eq(Grid.setting:get(), rowWas, "and leaves the player's row alone")
Grid.override = false
T.eq(Grid.enabled(), false, "an override can force it off too")
Grid.override = nil
T.eq(Grid.enabled(), rowWas and true or false,
  "and clearing it hands the answer back to the row")

-- ------- the depth of field is measured off the two marks
--
-- The slab held sharp is the one the mons are standing in, so the band has
-- to be derived from where they landed rather than from a constant -- and it
-- has to hold BOTH, which a band narrower than the gap between them would
-- not.
local BattleDOF = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleDOF")
local focusY, band, range = BattleDOF.bandFor(96, 56, 144)
T.check(math.abs(focusY - 76 / 144) < 1e-9,
  "the band centres between the two marks")
T.check(focusY - band < 56 / 144 and focusY + band > 96 / 144,
  "and is wide enough that both of them are inside it")
T.check(range > 0, "with a ramp out of it, so the band edge has no seam")
local wide = select(2, BattleDOF.bandFor(120, 30, 144))
T.check(wide > band, "marks further apart hold a deeper slab in focus")

Pipelines.reset()
run.release()

T.finish("DRAMATIC_SHAPE")
