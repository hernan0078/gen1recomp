-- Voxel world mode: assemble and draw one frame of the 3D scene.
--
-- World space is world pixels and shares its origin with the 2D paths, so
-- the terrain mesh needs no transform at all and a connected map just
-- translates by the same (ox, oy) the flat renderer already offsets it by.
--
-- Order is: the sun's shadow pass, then terrain, then characters, then a 2D
-- overlay for the field FX. There is no y-sort anywhere -- the depth buffer
-- resolves occlusion, which is the whole point of the mode. Walk behind a
-- building and the building is simply in front.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")
local ShadowMap = V.require("ShadowMap")
local ChunkMesher = V.require("ChunkMesher")
local SpriteBillboards = V.require("SpriteBillboards")
local TileShape = V.require("TileShape")
local TerrainAtlas = V.require("TerrainAtlas")
local Voxel = V.require("VoxelState")
local PaletteFX = require("src.render.PaletteFX")
local Map = require("src.world.Map")

local VoxelScene = {}

-- What the active display mode actually paints with.
--
-- paletteFor hands back a map's RAW SGB zone palette, and that is not what
-- any of the non-colour modes draw. The flat path runs it through
-- PaletteFX.effectiveColors on the way to the shade-remap shader, and that
-- call IS where GRAY, INVERTED and CLASSIC happen -- OG / OG INV replace
-- the palette with the DMG greys (inverted for the latter), CLASSIC
-- replaces it with the green DMG set, and GBC INV permutes the zone's own
-- shades. GBC and RED++ pass through untouched.
--
-- This pass has no shader to apply that in: colour is baked into the atlas
-- and into the sprite sheets ahead of the draw, so it has to run the same
-- transform itself. Without it every mode that is not already a colour mode
-- comes through wearing the SGB palette -- grey and inverted both rendering
-- as plain SGB blue.
local function modeColors(paletteFor, map)
  local c = paletteFor and paletteFor(map) or nil
  return PaletteFX.effectiveColors(c)
end

VoxelScene._modeColors = modeColors   -- named for the suite

-- ------------------------------------------------------------------ sky --
--
-- At the top rung the camera is pitched far enough over that the horizon
-- comes into frame and a good part of the picture is void -- so the void
-- becomes the sky, and the diorama reads as standing under something
-- rather than floating on a black plate. Below that rung the camera looks
-- down steeply enough that the horizon is off-screen, and painting the
-- void only tints the gaps between meshes, so it stays transparent.
--
-- INDOORS THERE IS NO SKY. A house, a cave or a gym is a room with a
-- ceiling, and the void past its walls is the outside of a box, not open
-- air. Map.isOutdoor is the same test the engine uses for door SFX and the
-- town map, and the same one Structures already asks to decide whether a
-- map rings with trees.
--
-- The colour is a four-shade ramp shaped like a world palette so the
-- display mode can transform it exactly like one: GRAY gets a grey sky,
-- CLASSIC a green one, GBC INV a dark one, and the colour modes the blue.
-- A hardcoded blue would sit wrong in every non-colour mode -- the same
-- mismatch the terrain bake had.
local SKY_SHADES = { { 222, 242, 255 }, { 135, 196, 240 },
                     { 64, 120, 192 }, { 16, 40, 80 } }
local SKY_SHADE = 2       -- the ramp's "sky" proper; 1 is its highlight

-- fade across the approach to the top rung, so the sky arrives with the
-- camera tween instead of popping in on the keypress
local function skyStrength(angleRad)
  local deg = math.deg(angleRad or 0)
  local from = Voxel.ANGLES_DEG[Voxel.MAX_LEVEL] or 50      -- the rung below
  local to = Voxel.ANGLES_DEG[Voxel.MAX_LEVEL + 1] or 75    -- the top rung
  if to <= from then return deg >= to and 1 or 0 end
  local t = (deg - from) / (to - from)
  if t < 0 then return 0 end
  if t > 1 then return 1 end
  return t
end

-- One shade off the sky ramp, transformed by the display mode, as an
-- {r, g, b, a} in 0..1. `shade` picks the rung (SKY_SHADE is the sky
-- proper; 4 is its darkest, which is what an indoor void wants).
function VoxelScene.skyShade(shade, alpha)
  local shades = PaletteFX.effectiveColors(SKY_SHADES) or SKY_SHADES
  local c = shades[shade] or SKY_SHADES[shade] or SKY_SHADES[SKY_SHADE]
  return { c[1] / 255, c[2] / 255, c[3] / 255, alpha or 1 }
end

-- The sky `map` stands under at strength `t`, or nil where there is no sky
-- to paint: indoors, or with the horizon out of frame.
function VoxelScene.skyColor(map, t)
  if not (map and map.def and Map.isOutdoor(map.def)) then return nil end
  if not t or t <= 0 then return nil end
  return VoxelScene.skyShade(SKY_SHADE, t)
end

local function skyFor(map)
  return VoxelScene.skyColor(map, skyStrength(Voxel.angle))
end

VoxelScene._skyFor = skyFor           -- named for the suite
VoxelScene._skyStrength = skyStrength

-- A facing as a yaw about +Y, kept for callers that reason about which way
-- an entity points (the mod exports it). The character cards themselves
-- never yaw -- they face south and lean, like the flat game.
local YAW = {
  down = 0,
  up = math.pi,
  right = math.pi / 2,
  left = -math.pi / 2,
}

-- The ground height a cell stands at, so a character on a ledge stands on
-- top of it rather than sunk into it. Uses the same bottom-left collision
-- tile the engine walks on (Map:cellTile).
local function groundAt(map, cellX, cellY)
  -- Off the map, cellTile border-extends into the map's borderBlock --
  -- which on maps ringed with trees is a RAISED tile. The only entity
  -- ever standing off-map is the player mid seam-step (placed one cell
  -- before the connection entry), and the ground actually rendered
  -- there is the departed neighbour's flat walkway: height 0. Without
  -- this, crossing into such a map hoisted the walker tree-high for
  -- exactly one step -- the "hops like a ledge" seam bug.
  if not map:inBounds(cellX, cellY) then return 0 end
  local shapes = TileShape.forMap(map)
  local s = shapes[map:cellTile(cellX, cellY)]
  if not s then return 0 end
  -- a recessed class (water) still supports whatever stands on it; only
  -- raised ground lifts the model.  Stairs never do: the class height is
  -- the flight's TALL end, but the player enters at floor level and the
  -- warp fires as they step in -- lifting them onto the geometry read as
  -- climbing an invisible block
  if s.art == "stair" then return 0 end
  return s.h > 0 and s.h or 0
end

VoxelScene.YAW = YAW
-- shared with the overworld battle, which stands its mons on map cells and
-- needs the same answer about what height "the floor" is there
VoxelScene.groundAt = groundAt

-- Camera-ward pull distance for billboards (and the grass rows, which
-- must keep their relative depth to feet): just enough that a leaned-back
-- slab clears the wall it leans over. The lean flattens toward top-down,
-- so the needed pull grows exactly as real occlusion stops mattering.
function VoxelScene.pull(a)
  return 6 + math.max(0, 16 * math.cos(a) - 8) / math.max(math.sin(a), 0.2)
end

-- The sheet frame and mirror flag the 2D path would draw for this pose
-- (same tables as SpriteRenderer). Shared by the billboard pass and the
-- shadow pass so a walking character's shadow swings its legs too.
local function frameFor(def, facing, phase, flip)
  local SR = require("src.render.SpriteRenderer")
  local frame, mirror = 0, false
  if (def.frames or 1) > 1 then
    frame = (def.walker and phase == 1) and SR.WALK[facing]
            or SR.STAND[facing]
    mirror = facing == "right"
      or ((facing == "down" or facing == "up") and phase == 1 and flip)
  end
  return frame, mirror
end

-- FALLBACK ONLY (see castShadows below). Draw one entity's drop shadow as
-- a decal: its current sprite frame as a single quad, flattened onto the
-- ground along the sun line (Voxel3D.shadowMatrix). Runs inside
-- beginShadows, which supplies the translucent black; the texture is only
-- consulted for its alpha, so no palette work is needed.
local function drawShadow(sprite, px, py, facing, phase, flip, gh, lift)
  local def = sprite.def
  local frame, mirror = frameFor(def, facing, phase, flip)
  local mesh = SpriteBillboards.shadowQuad(def, frame)
  if not mesh then return end
  Voxel3D.draw(mesh, sprite:resolveImage(),
               Voxel3D.shadowMatrix(px, py, gh, lift, mirror))
end

-- Where a billboard character's card stands: on the middle of its cell at
-- height `y`, pivoted at the feet and tipped back by exactly the camera's
-- pitch. The slab is built centred on its sprite plane (z = 0), so only the
-- x anchor shifts; the relief bulges symmetrically front and back of it.
--
-- Shared by the solid draw and the silhouette below, so the two can never
-- drift apart -- a silhouette standing anywhere but exactly behind the
-- figure would read as a second character.
local function billboardMatrix(px, py, y, mirror)
  local Voxel = V.require("VoxelState")
  local m = Mat4.mul(Mat4.translate(px + 8, y, py + 8),
                     Mat4.rotateX(Voxel.angle - math.pi / 2))
  if mirror then m = Mat4.mul(m, Mat4.scale(-1, 1, 1)) end
  return Mat4.mul(m, Mat4.translate(-8, 0, 0))
end

local function billboardPull()
  local Voxel = V.require("VoxelState")
  return VoxelScene.pull(math.max(Voxel.angle, 0.05))
end

-- Draw one posed entity. Returns true if 3D geometry carried it, false
-- when nothing could be built and the caller should fall back.
-- `colors` is the 4-color world palette the entity stands under in the SGB
-- modes (nil under RED++/trueColor): the 2D path colorizes sprites with a
-- screen-space shader the voxel canvas never runs through, so the model's
-- texture gets the palette baked in instead (TerrainAtlas.forSprite).
-- `lift` raises the figure off the ground plane (ledge hops arc UP in 3D,
-- where the 2D path could only slide the sprite north).
local function drawEntity(sprite, px, py, facing, phase, flip, gh, colors,
                          lift)
  local def = sprite.def
  local tex = sprite:resolveImage()
  if colors and not def.trueColor then
    tex = TerrainAtlas.forSprite(def.image, colors) or tex
  end
  local y = gh + (lift or 0)

  -- pick the very frame the 2D path would draw (same tables). The card
  -- always faces SOUTH -- the direction the 2D game implies -- and only
  -- LEANS BACK, pivoting at its feet, by exactly the camera's pitch, so
  -- at every tilt level the sprite reads face-on like the flat game.
  -- No camera-tracking yaw: every sprite leans in parallel.
  local frame, mirror = frameFor(def, facing, phase, flip)
  local mesh = SpriteBillboards.mesh(def, frame)
  if not mesh then return false end
  -- Camera-ward pull (applied per vertex in the shader, along each
  -- vertex's own eye ray, so it is a PURE depth bias with zero screen
  -- drift): lets the leaned-back head win against the wall it leans
  -- OVER while a character genuinely BEHIND a building is dozens of
  -- pixels deeper and still loses, so real occlusion works.
  -- the same card UNLEANED is what the sun saw (castShadows draws
  -- exactly this mesh), so that is where each vertex asks whether the
  -- light reached it -- see Voxel3D.draw
  Voxel3D.draw(mesh, tex, billboardMatrix(px, py, y, mirror),
               billboardPull(),
               Voxel3D.casterMatrix(px, py, y, mirror))
  return true
end

VoxelScene.drawEntity = drawEntity

-- The player's silhouette, for wherever the scenery is standing in front of
-- them (Voxel3D.beginGhost inverts the depth test around this call).
--
-- The same flat card the solid pass and the sun pass draw. That it has no
-- self-overlap is what makes it safe here: with the depth test inverted, a
-- mesh carrying both front and back faces would read its own back faces as
-- "behind something" and repaint the figure on open ground, occluded or
-- not. One quad cannot do that, and cannot double-blend into a mottled
-- patch either. A silhouette is an outline, so an outline is the right
-- mesh for it.
local function drawGhost(p)
  local def = p.sprite.def
  local frame, mirror = frameFor(def, p.facing, p.phase, p.flip)
  local mesh = SpriteBillboards.shadowQuad(def, frame)
  if not mesh then return end
  local tex = p.sprite:resolveImage()
  if p.colors and not def.trueColor then
    tex = TerrainAtlas.forSprite(def.image, p.colors) or tex
  end
  local y = p.gh + (p.lift or 0)
  Voxel3D.draw(mesh, tex, billboardMatrix(p.px, p.py, y, mirror),
               billboardPull())
end

-- Render the world. `state` is the OverworldState; `vw`/`vh` the world view
-- size in world pixels; `w`/`h` the pixel size of the canvas to render
-- into; `paletteFor(map)` yields a map's 4-color world palette (nil in the
-- color modes whose atlas is already true color). Returns the finished
-- canvas, or nil if the 3D pass could not run (headless, no depth support)
-- so the caller can fall back to 2D.
-- The last live-set key, so eviction only runs when the neighbourhood
-- actually changes (a map crossing), not every frame.
local lastLiveKey = nil

-- Request everything `state`'s frame wants and evict what it no longer
-- does; returns the current map's terrain mesh (or nil while it builds)
-- and the neighbour meshes ready to draw. render() calls this for the
-- frame it is drawing, and the pipeline's update hook calls it EVERY
-- frame -- including the frames a warp's Transition covers, when the
-- world pass is off. That update-side call is what lets a door fade hide
-- the destination's build: the map swaps behind the fade, and waiting
-- for the first visible frame to request meshes would show the flat
-- fallback while the first slices run.
function VoxelScene.prefetch(state)
  local Voxel = V.require("VoxelState")

  -- The live set is the current map plus its rendered neighbours. When
  -- it changes, everything outside it (and the previous set, which
  -- ChunkMesher retains so stepping into a house keeps the town warm)
  -- is evicted -- meshes released, analysis dropped -- so memory stays
  -- bounded by the neighbourhood instead of growing with every area
  -- ever visited.
  local liveKey = state.map.id
  local live = { [state.map.id] = true }
  for _, nb in ipairs(state.neighbors or {}) do
    live[nb.map.id] = true
    liveKey = liveKey .. "|" .. nb.map.id
  end
  if liveKey ~= lastLiveKey then
    lastLiveKey = liveKey
    ChunkMesher.setLive(live)
    -- RED++ bakes one atlas per map, so its animated copy is per map too
    -- and is bounded by the same neighbourhood
    TerrainAtlas.setLive(live)
  end

  -- masks: where connected neighbour BODIES sit, so the border ring is
  -- suppressed under them (see runGeometry)
  local masks = {}
  for _, nb in ipairs(state.neighbors or {}) do
    masks[#masks + 1] = { nb.ox, nb.oy,
                          nb.ox + nb.map.def.width * 32,
                          nb.oy + nb.map.def.height * 32 }
  end

  -- Builds are asynchronous (ChunkMesher.pump runs in the pipeline's
  -- update): request what this frame wants and draw what is ready.
  -- The current map draws its body-only mesh while the full one (the
  -- border ring) is still building -- a seam crossing promotes a
  -- neighbour whose body is already cached, and the ring pops in a few
  -- frames later, mostly hidden behind the map just left. A neighbour
  -- missing its body-only mesh draws its cached FULL mesh instead -- a
  -- crossing demotes the map just left, and it must not vanish from
  -- behind the player while its body variant builds; its ring is
  -- already masked out under this map's body, so the stand-in is safe.
  local terrain = ChunkMesher.request(state.map, false, masks, true)
  if not terrain then
    terrain = ChunkMesher.peek(state.map, true)
  end
  local nbMesh = {}
  for i, nb in ipairs(state.neighbors or {}) do
    nbMesh[i] = ChunkMesher.request(nb.map, true)
                or ChunkMesher.peek(nb.map, false)
  end
  Voxel.ready = terrain ~= nil
  return terrain, nbMesh
end

-- Capture every entity's pose for this frame. pose() advances the hop /
-- surf bob / spinner timers, so it must be called EXACTLY once per entity
-- per frame -- the sun pass and the character pass then read the same
-- answer instead of disagreeing by a tick. Ghost NPCs live on a neighbour
-- map, so their position, ground lookup and palette all belong to that
-- map. pose() returns the VISUAL y (ledge hops arc it, surfing bobs it);
-- the difference from the entity's base y becomes vertical LIFT in 3D, so
-- a hop rises off the ground instead of sliding north.
-- Returns the pose list and, separately, the PLAYER's entry in it (nil
-- during a Fly animation, which draws the player itself and is skipped
-- below). Only that one entry gets the see-through treatment: NPCs and the
-- ghosts standing on a neighbour map are left to honest occlusion, because
-- it is only your own character you cannot afford to lose behind a roof.
local function posesOf(state, spriteColors)
  local colors = spriteColors(state.map)
  local posed = {}
  local me = nil
  for _, g in ipairs(state.ghosts or {}) do
    local sprite, vx, vy, facing, phase, flip = g.npc:pose()
    posed[#posed + 1] = {
      sprite = sprite, px = vx + g.ox, py = g.npc.py + g.oy,
      facing = facing, phase = phase, flip = flip,
      gh = groundAt(g.map or state.map, g.npc.cellX, g.npc.cellY),
      lift = g.npc.py - vy, colors = spriteColors(g.map or state.map),
    }
  end
  for _, e in ipairs(state.entities or {}) do
    if not (state.flyAnim and e == state.player) then
      local sprite, vx, vy, facing, phase, flip = e:pose()
      posed[#posed + 1] = {
        sprite = sprite, px = vx, py = e.py,
        facing = facing, phase = phase, flip = flip,
        gh = groundAt(state.map, e.cellX, e.cellY),
        lift = e.py - vy, colors = colors,
      }
      if e == state.player then me = posed[#posed] end
    end
  end
  return posed, me
end

-- A stamp of everything the sun pass depends on. Nothing in it moving
-- means the shadow map it produced last frame is still exactly right, and
-- redrawing the whole world from the sun would buy nothing -- which is
-- most of a dialog, a menu, or any moment standing still.
local sigBuf = {}
local function shadowSignature(terrain, nbMesh, posed, cx, cy, vw, vh)
  local n = 0
  local function put(v)
    n = n + 1
    sigBuf[n] = v
  end
  -- quarter-pixel camera granularity: the light frustum is snapped to
  -- whole texels anyway, each a third of a world pixel
  put(math.floor(cx * 4))
  put(math.floor(cy * 4))
  -- the view size and the camera PITCH are both what the light frustum is
  -- fitted to (a lower camera sees further north, so the box grows), so a
  -- zoom step, a window resize or a rung change invalidates the map even
  -- standing perfectly still
  put(vw); put(vh)
  put(math.floor((V.require("VoxelState").angle or 0) * 512))
  put(tostring(terrain))
  for i = 1, #nbMesh do put(tostring(nbMesh[i])) end
  for _, p in ipairs(posed) do
    put(p.sprite.def.image)
    put(p.px); put(p.py); put(p.gh); put(p.lift or 0)
    put(p.facing); put(p.phase); put(p.flip and 1 or 0)
  end
  for i = n + 1, #sigBuf do sigBuf[i] = nil end
  return table.concat(sigBuf, ",")
end

-- The sun pass: render the scene once from the light, so the main pass can
-- ask any fragment whether the sun reached it. Every caster the main pass
-- draws goes in -- the terrain mesh, which is where buildings, trees,
-- ledges, signs and every prop live, plus one UPRIGHT card per character
-- (Voxel3D.casterMatrix; the leaning slab is a trick for the camera, not
-- for the sun) -- so shadows land on walls, roofs, ledges and passing NPCs
-- as readily as on the floor.
--
-- Runs BEFORE Voxel3D.beginScene, because canvases do not nest. Grass is
-- left out on purpose: thousands of tufts would cast a speckle no bigger
-- than the pixels it lands on, at the cost of the mesh being drawn twice.
local function castShadows(state, terrain, nbMesh, posed, cx, cy, vw, vh,
                           atlasFor)
  if not ShadowMap.available() then return end
  local sig = shadowSignature(terrain, nbMesh, posed, cx, cy, vw, vh)
  if not ShadowMap.stale(sig) then return end
  if not ShadowMap.begin(cx, cy, vw, vh) then return end

  ShadowMap.draw(terrain, atlasFor(state.map), nil)
  for i, nb in ipairs(state.neighbors or {}) do
    ShadowMap.draw(nbMesh[i], atlasFor(nb.map),
                   Mat4.translate(nb.ox, 0, nb.oy))
  end
  -- flower billboards live outside the terrain mesh (they draw after the
  -- characters, pulled -- see render), but the sun still sees them: a
  -- handful of cutouts per meadow, unlike the grass left out below
  ShadowMap.draw(ChunkMesher.flowers(state.map), atlasFor(state.map), nil)
  for _, nb in ipairs(state.neighbors or {}) do
    ShadowMap.draw(ChunkMesher.flowers(nb.map), atlasFor(nb.map),
                   Mat4.translate(nb.ox, 0, nb.oy))
  end
  for _, p in ipairs(posed) do
    local def = p.sprite.def
    local frame, mirror = frameFor(def, p.facing, p.phase, p.flip)
    local mesh = SpriteBillboards.shadowQuad(def, frame)
    if mesh then
      ShadowMap.draw(mesh, p.sprite:resolveImage(),
                     Voxel3D.casterMatrix(p.px, p.py, p.gh + (p.lift or 0),
                                          mirror))
    end
  end

  ShadowMap.finish(sig)
end

function VoxelScene.render(state, w, h, vw, vh, paletteFor)
  -- With nothing cached at all (the first frame of a fresh toggle),
  -- return nil: the engine keeps the 2D path for the frame and
  -- Voxel.ready holds the camera tween at flat, so the switch waits
  -- invisibly instead of freezing or tilting an empty stage.
  local terrain, nbMesh = VoxelScene.prefetch(state)
  if not terrain then return nil end

  local cam = state.camera
  local cx, cy = cam.x + vw / 2, cam.y + vh / 2

  local function atlasFor(map)
    return TerrainAtlas.forMap(map, modeColors(paletteFor, map))
  end

  -- sprite palettes only exist in the SGB modes; under RED++ the OBP bake
  -- inside sprite:resolveImage() already colors the sheet
  local function spriteColors(map)
    if PaletteFX.usesGbcPack() then return nil end
    return modeColors(paletteFor, map)
  end

  local posed, me = posesOf(state, spriteColors)
  castShadows(state, terrain, nbMesh, posed, cx, cy, vw, vh, atlasFor)

  if not Voxel3D.beginScene(w, h, cx, cy, vw, vh, skyFor(state.map)) then
    return nil
  end

  Voxel3D.draw(terrain, atlasFor(state.map), nil)
  for i, nb in ipairs(state.neighbors or {}) do
    Voxel3D.draw(nbMesh[i], atlasFor(nb.map),
                 Mat4.translate(nb.ox, 0, nb.oy))
  end

  -- Without a shadow map (headless, or a driver that could not make the
  -- canvas) the old flat decals stand in: ground-only, characters only,
  -- but better than a world with nothing under anybody. They go down
  -- first, as decals the characters then stand over -- depth-tested
  -- against the terrain just drawn (a shadow behind a building stays
  -- hidden) but never depth-writing, so the grass pass at the end of the
  -- frame still wins its feet-overdraw fights.
  if not Voxel3D.shadowsActive() then
    Voxel3D.beginShadows()
    for _, p in ipairs(posed) do
      drawShadow(p.sprite, p.px, p.py, p.facing, p.phase, p.flip, p.gh,
                 p.lift)
    end
    Voxel3D.endShadows()
  end

  -- The player's silhouette goes down BEFORE the characters, so the only
  -- thing it can meet in the depth buffer is the WORLD -- terrain, buildings,
  -- trees. Drawn after the solid pass it would meet the player's own card
  -- instead, and every fragment of a figure sits behind the one that just
  -- wrote it, so the silhouette would paint over the player at all times.
  -- Every character then draws on top as usual, which leaves the silhouette
  -- showing in exactly one situation: where the world hides them.
  if me then
    Voxel3D.beginGhost()
    drawGhost(me)
    Voxel3D.endGhost()
  end

  -- characters, normally depth-tested: the camera-ward pull inside
  -- drawEntity resolves the lean-over-the-wall-in-front case, and a
  -- character genuinely behind a building is far deeper and loses the
  -- test, so buildings and trees really occlude.
  for _, p in ipairs(posed) do
    drawEntity(p.sprite, p.px, p.py, p.facing, p.phase, p.flip, p.gh,
               p.colors, p.lift)
  end
  -- tall grass last, pulled camera-ward exactly as far as the characters
  -- were (same per-vertex shader bias, so grass never drifts either):
  -- relative depth between a walker and the tuft row south of their feet
  -- is preserved, so the row still overdraws feet -- the 3D version of
  -- the GB's grass-over-feet trick -- while grass keeps losing to the
  -- buildings it genuinely stands behind (far deeper than the pull).
  local Voxel = V.require("VoxelState")
  local pull = VoxelScene.pull(math.max(Voxel.angle, 0.05))
  Voxel3D.draw(ChunkMesher.grass(state.map), atlasFor(state.map), nil, pull)
  for _, nb in ipairs(state.neighbors or {}) do
    Voxel3D.draw(ChunkMesher.grass(nb.map), atlasFor(nb.map),
                 Mat4.translate(nb.ox, 0, nb.oy), pull)
  end
  -- flower billboards: pulled like the characters and the grass, MINUS
  -- the depth of 8 world pixels along the view (8 sin a -- the camera
  -- looks along (0, -cos a, -sin a), so that is exactly one tile row of
  -- northness). A pure depth handicap with zero screen drift: every
  -- flower is judged as if it stood one tile row further north. The
  -- character card's feet plane sits at its cell's MIDDLE (py + 8), so
  -- a flower on the walker's own cell (z +4 or +12 across the cell)
  -- lands behind the card and the player obscures the patch they stand
  -- ON, while the nearest flower of the cell south (+20) stays in front
  -- and keeps overdrawing their feet.
  local fpull = math.max(0, pull - 8 * math.sin(math.max(Voxel.angle, 0.05)))
  Voxel3D.draw(ChunkMesher.flowers(state.map), atlasFor(state.map), nil,
               fpull)
  for _, nb in ipairs(state.neighbors or {}) do
    Voxel3D.draw(ChunkMesher.flowers(nb.map), atlasFor(nb.map),
                 Mat4.translate(nb.ox, 0, nb.oy), fpull)
  end

  return Voxel3D.endScene()
end

return VoxelScene
