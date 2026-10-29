-- Logical focus for the embedded OpenCode TUI.
--
-- The TUI is a single terminal buffer, but input routing treats two logical
-- regions: the prompt composer and the session transcript.  This module only
-- records that logical state.  Region changes happen through explicit
-- focus_input()/focus_session(), the configurable focus key, or entering and
-- leaving the real Neovim window.  Cursor movement, row numbers, scrolling and
-- `j`/`k` never change the region.

local M = {}

local REGIONS = {
  composer = true,
  session = true,
}

local Focus = {}
Focus.__index = Focus

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  return vim.deepcopy(value)
end

--- Create an independent logical focus record.
--- @param opts table|nil { initial = "composer"|"session" }
--- @return table
function M.new(opts)
  opts = opts or {}
  local initial = opts.initial or "composer"
  assert(REGIONS[initial], "opencode.focus: initial must be 'composer' or 'session'")
  return setmetatable({
    region = initial,
    saved = initial,
    active = true,
    reason = "initial",
    changes = 0,
  }, Focus)
end

local function valid_region(region)
  return type(region) == "string" and REGIONS[region] == true
end

--- Set the current logical region.
--- @param region "composer"|"session"
--- @param reason string|nil
--- @return boolean ok
--- @return string|nil error
function Focus:set(region, reason)
  if not valid_region(region) then
    return false, ("invalid focus region %q"):format(tostring(region))
  end
  if self.region ~= region then
    self.changes = self.changes + 1
  end
  self.region = region
  self.saved = region
  self.reason = reason or "explicit"
  self.active = true
  return true
end

--- @return "composer"|"session"
function Focus:get()
  return self.region
end

--- @return boolean
function Focus:is_composer()
  return self.region == "composer"
end

--- @return boolean
function Focus:is_session()
  return self.region == "session"
end

--- Switch between the two logical regions without interpreting motion.
--- @return "composer"|"session"
function Focus:toggle()
  local region = self.region == "composer" and "session" or "composer"
  self:set(region, "toggle")
  return region
end

--- Remember the current region when the real window is left.
--- @return string
function Focus:leave()
  self.saved = self.region
  self.active = false
  self.reason = "window_leave"
  return self.saved
end

--- Restore the region remembered before the real window was left.
--- @return "composer"|"session"
function Focus:enter()
  self.region = self.saved
  self.active = true
  self.reason = "window_enter"
  return self.region
end

--- @return table
function Focus:state()
  return {
    region = self.region,
    saved = self.saved,
    active = self.active,
    reason = self.reason,
    changes = self.changes,
  }
end

--- @return table
function Focus:copy()
  return copy(self:state())
end

M.regions = REGIONS
M.valid_region = valid_region

return M
