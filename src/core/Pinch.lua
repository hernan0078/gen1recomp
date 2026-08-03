-- Pinch to zoom, for the touch builds.
--
-- ZOOM is a menu row, and a menu row is the wrong instrument for it: you
-- judge a zoom level by looking at the screen, and the menu is covering the
-- screen. On a phone there is no wheel and no hotkey either, so the row was
-- the ONLY way to reach it. This is the gesture everyone already knows.
--
-- WHAT IT DRIVES. The engine's own Zoom offset -- the same integer the ZOOM
-- row steps and the same one persisted to options. Not a second, parallel
-- zoom: pinching and then opening the menu shows the row already sitting
-- where the pinch left it, because there is one number.
--
-- WHAT IT AVOIDS. Two fingers that start on the touch overlay are the
-- player working the pad, not pinching -- a thumb on the d-pad and a thumb
-- on A is the ordinary way to hold this game, and it must never zoom. Only a
-- pinch that begins with both fingers on open screen counts.

local Pinch = {}

-- Touches currently down, by id, as { x, y }. Only ever two matter.
local live = {}
local gesture = nil   -- { d0 = starting distance, off0 = starting offset }

-- How much the fingers must spread or close, as a ratio of where they
-- started, to move one rung. 1.18 is roughly a centimetre of travel at
-- phone sizes: small enough to feel direct, large enough that a two-thumb
-- grip that drifts does not creep the zoom.
Pinch.STEP_RATIO = 1.18

local function count()
  local n = 0
  for _ in pairs(live) do n = n + 1 end
  return n
end

local function pair()
  local a, b
  for _, p in pairs(live) do
    if not a then a = p elseif not b then b = p end
  end
  return a, b
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Is this point on the on-screen pad? A pinch that starts there belongs to
-- the pad, not to us.
local function onPad(x, y)
  local ok, hit = pcall(function()
    local TouchControls = require("src.core.TouchControls")
    if not TouchControls:visible() then return nil end
    return TouchControls:hitTest(x, y)
  end)
  return ok and hit ~= nil
end

-- Apply an offset, clamped to what the screen can actually show, and
-- persist it exactly as the ZOOM row does. Clamped rather than wrapped: a
-- menu row wraps because stepping past the end with a button press should
-- come back round, but a pinch that silently jumped from most-zoomed-in to
-- most-zoomed-out would be alarming.
local function setOffset(off)
  local ok = pcall(function()
    local Zoom = require("src.render.Zoom")
    local Renderer = require("src.render.Renderer")
    local Game = require("src.core.Game")
    local lo, hi = Zoom.offsetRange(Renderer:fitScale())
    off = math.max(lo, math.min(hi, off))
    if off == Zoom.offset then return end
    Zoom.offset = off
    local opts = Game and Game.save and Game.save.options
    if opts then opts.zoom = off end
  end)
  return ok
end

local function currentOffset()
  local ok, off = pcall(function()
    return require("src.render.Zoom").offset or 0
  end)
  return (ok and off) or 0
end

function Pinch.pressed(id, x, y)
  live[id] = { x = x, y = y, pad = onPad(x, y) }
  gesture = nil
  if count() == 2 then
    local a, b = pair()
    -- both fingers have to be off the pad, and far enough apart that the
    -- starting distance is a meaningful denominator
    if a and b and not a.pad and not b.pad then
      local d0 = distance(a, b)
      if d0 > 24 then gesture = { d0 = d0, off0 = currentOffset() } end
    end
  end
end

function Pinch.moved(id, x, y)
  local p = live[id]
  if not p then return false end
  p.x, p.y = x, y
  if not gesture or count() ~= 2 then return false end
  local a, b = pair()
  if not (a and b) then return false end
  local ratio = distance(a, b) / gesture.d0
  -- log base STEP_RATIO: each further multiple of the ratio is one more rung,
  -- so a slow spread walks the ladder evenly instead of leaping at the start
  local steps = math.floor(math.log(ratio) / math.log(Pinch.STEP_RATIO) + 0.5)
  if steps ~= 0 then setOffset(gesture.off0 + steps) end
  return true
end

function Pinch.released(id)
  live[id] = nil
  if count() < 2 then gesture = nil end
end

-- A pinch is in progress: the caller should not also treat these touches as
-- taps on the world.
function Pinch.active()
  return gesture ~= nil
end

return Pinch
