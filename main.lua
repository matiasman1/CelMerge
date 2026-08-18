-- CelMerge
-- Frame-axis equivalents of Aseprite's native layer-axis operations:
--   Merge Down  -> Merge Before / Merge After   (one step into the adjacent frame)
--   Flatten     -> Flatten Before / Flatten After (collapse the whole selection into one frame)
-- Only works on whole-frame selections (RangeType.FRAMES), applied uniformly across
-- every leaf layer -- no per-cel/per-layer irregular selections.

local function isMergeableLayer(l) return l.isImage and not l.isTilemap end

local function collectLeafLayers(list, out)
  for _, l in ipairs(list) do
    if l.isGroup then collectLeafLayers(l.layers, out)
    elseif isMergeableLayer(l) then table.insert(out, l) end
  end
  return out
end

local function selectedFrameNumbers()
  local r = app.range
  if r.isEmpty or r.type ~= RangeType.FRAMES then return nil end
  local nums = {}
  for _, f in ipairs(r.frames) do table.insert(nums, f.frameNumber) end
  if #nums == 0 then return nil end
  table.sort(nums)
  return nums
end

-- Composites the given layer's cels across frameNums (ascending) into one image.
-- direction "forward": earliest frame ends up on top (later frames drawn first, as background).
-- direction "backward": latest frame ends up on top (earlier frames drawn first, as background).
-- Returns nil if the layer has no cels among frameNums.
local function compositeForLayer(sprite, layer, frameNums, direction)
  local cels = {}
  for _, fn in ipairs(frameNums) do
    local c = layer:cel(fn)
    if c then table.insert(cels, c) end
  end
  if #cels == 0 then return nil end

  local bounds = cels[1].bounds
  for i = 2, #cels do bounds = bounds:union(cels[i].bounds) end

  local img = Image(bounds.width, bounds.height, sprite.colorMode)
  img:clear()

  local first, last, step
  if direction == "forward" then
    first, last, step = #cels, 1, -1
  else
    first, last, step = 1, #cels, 1
  end
  for i = first, last, step do
    local c = cels[i]
    img:drawImage(c.image,
      Point(c.position.x - bounds.x, c.position.y - bounds.y),
      c.opacity, BlendMode.NORMAL)
  end

  return img, bounds
end

---------------------------------------------------------------------
-- Merge Before / Merge After -- single step into the adjacent frame,
-- eliminating the merged frames (like Merge Down eliminates the source layer)
---------------------------------------------------------------------

local function mergeNeighbor(direction)
  local sprite = app.sprite
  if not sprite then return end
  local selected = selectedFrameNumbers()
  if not selected then return end

  local minF, maxF = selected[1], selected[#selected]
  local destFn, combined, drawDir

  if direction == "after" then
    destFn = maxF + 1
    if destFn > #sprite.frames then return end
    combined = {}
    for _, fn in ipairs(selected) do table.insert(combined, fn) end
    table.insert(combined, destFn)
    drawDir = "forward"
  else
    destFn = minF - 1
    if destFn < 1 then return end
    combined = { destFn }
    for _, fn in ipairs(selected) do table.insert(combined, fn) end
    drawDir = "backward"
  end

  local leaf = {}
  collectLeafLayers(sprite.layers, leaf)

  local title = (direction == "after") and "Merge After" or "Merge Before"
  app.transaction(title, function()
    for _, layer in ipairs(leaf) do
      local img, bounds = compositeForLayer(sprite, layer, combined, drawDir)
      if img then
        if layer:cel(destFn) then sprite:deleteCel(layer, destFn) end
        sprite:newCel(layer, destFn, img, Point(bounds.x, bounds.y))
      end
    end
    for i = #selected, 1, -1 do
      sprite:deleteFrame(selected[i])
    end
  end)
  app.refresh()
end

---------------------------------------------------------------------
-- Flatten Before / Flatten After -- collapse the whole selection into
-- its first/last frame, eliminating the rest (like Flatten eliminates layers)
---------------------------------------------------------------------

local function flattenRange(direction)
  local sprite = app.sprite
  if not sprite then return end
  local selected = selectedFrameNumbers()
  if not selected or #selected < 2 then return end

  local anchor = (direction == "after") and selected[#selected] or selected[1]
  local drawDir = (direction == "after") and "forward" or "backward"

  local leaf = {}
  collectLeafLayers(sprite.layers, leaf)

  local title = (direction == "after") and "Flatten After" or "Flatten Before"
  app.transaction(title, function()
    for _, layer in ipairs(leaf) do
      local img, bounds = compositeForLayer(sprite, layer, selected, drawDir)
      if img then
        if layer:cel(anchor) then sprite:deleteCel(layer, anchor) end
        sprite:newCel(layer, anchor, img, Point(bounds.x, bounds.y))
      end
    end
    for i = #selected, 1, -1 do
      local fn = selected[i]
      if fn ~= anchor then sprite:deleteFrame(fn) end
    end
  end)
  app.refresh()
end

---------------------------------------------------------------------
-- Enabled predicates
---------------------------------------------------------------------

local function mergeBeforeEnabled()
  if not app.sprite then return false end
  local sel = selectedFrameNumbers()
  return sel ~= nil and sel[1] > 1
end

local function mergeAfterEnabled()
  local sprite = app.sprite
  if not sprite then return false end
  local sel = selectedFrameNumbers()
  return sel ~= nil and sel[#sel] < #sprite.frames
end

local function flattenEnabled()
  if not app.sprite then return false end
  local sel = selectedFrameNumbers()
  return sel ~= nil and #sel >= 2
end

---------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------

function init(plugin)
  local specs = {
    { id = "MergeBefore",   title = "Merge Before",   enabled = mergeBeforeEnabled, run = function() mergeNeighbor("before") end },
    { id = "MergeAfter",    title = "Merge After",    enabled = mergeAfterEnabled,  run = function() mergeNeighbor("after") end },
    { id = "FlattenBefore", title = "Flatten Before", enabled = flattenEnabled,     run = function() flattenRange("before") end },
    { id = "FlattenAfter",  title = "Flatten After",  enabled = flattenEnabled,     run = function() flattenRange("after") end },
  }

  for _, s in ipairs(specs) do
    plugin:newCommand{
      id = "CelMerge" .. s.id,
      title = s.title,
      group = "frame_popup_properties",
      onenabled = s.enabled,
      onclick = s.run
    }
  end
end

function exit(plugin) end
