-- OpenCode command completion source.
--
-- Commands come from the V2 command route and are inserted as `/name ` only
-- at the start of the prompt, matching the TUI.  Submission uses command
-- semantics (`kind = "command"`), never a plain prompt.

local api_mod = require("opencode.completion.sources.api")
local util = require("opencode.completion.sources.util")

local M = {}

local Source = {}
Source.__index = Source

--- @param opts table
--- @return table
function M.new(opts)
  opts = opts or {}
  local instance = setmetatable({
    api = opts.api or api_mod.new(opts.client),
    cache = opts.cache,
    opts = opts,
    ttl = type(opts.cache_ttl) == "number" and opts.cache_ttl or 30000,
  }, Source)
  instance.query = util.bind(instance, Source.query)
  instance.load = util.bind(instance, Source.load)
  instance.candidates = util.bind(instance, Source.candidates)
  instance.invalidate = util.bind(instance, Source.invalidate)
  return instance
end

--- @param request table
--- @return table|nil location
--- @return table|nil err
function Source:_location(request)
  return util.resolve_location(self.opts, request)
end

--- Load commands for a location.  Completed lists are cached per project.
--- @param location table
--- @param callback fun(err: table|nil, commands: table[]|nil, location: table|nil)
--- @return function|nil cancel
function Source:load(location, callback)
  if type(callback) ~= "function" then
    return nil
  end
  local resolved, location_err = util.location(location)
  if not resolved then
    callback(location_err)
    return nil
  end

  if self.cache then
    local cached = self.cache:get("command", resolved.directory, self.ttl)
    if cached then
      callback(nil, cached, resolved)
      return nil
    end
  end

  local finished = false
  local function finish(err, commands, response_location)
    if finished then
      return
    end
    finished = true
    callback(err, commands, response_location or resolved)
  end

  local cancel = self.api:call("list_commands", { location = resolved }, function(err, raw)
    if err then
      finish(util.normalize_error(err, "command_list_failed"))
      return
    end
    local list, response_location = util.unwrap_list(raw)
    if not list then
      finish(util.error("invalid_response", "command list returned no list"))
      return
    end
    local commands = {}
    for _, value in ipairs(list) do
      if type(value) == "table" and type(value.name) == "string" and value.name ~= "" then
        commands[#commands + 1] = {
          name = value.name,
          description = type(value.description) == "string" and value.description or nil,
        }
      end
    end
    if self.cache then
      self.cache:set("command", resolved.directory, commands, self.ttl)
    end
    finish(nil, commands, response_location)
  end)
  if finished then
    return nil
  end
  return cancel
end

--- @param commands table[]
--- @param trigger table
--- @return table[]
function Source:candidates(commands, trigger)
  trigger = trigger or {}
  local items = {}
  for _, command in ipairs(commands or {}) do
    local name = command.name
    if type(name) == "string" and name ~= "" then
      local metadata = {
        source = "opencode",
        type = "command",
        kind = "command",
        name = name,
        description = command.description,
        command = {
          name = name,
          description = command.description,
        },
        start_col = trigger.start_col,
      }
      items[#items + 1] = {
        kind = "command",
        name = name,
        description = command.description,
        text = "/" .. name .. " ",
        abbr = "/" .. name,
        menu = "command",
        info = command.description,
        metadata = metadata,
      }
    end
  end
  if trigger.query == nil or trigger.query == "" then
    table.sort(items, function(left, right)
      return left.name < right.name
    end)
    return items
  end
  return util.rank(trigger.query, items, function(item)
    return { item.name, item.description }
  end)
end

--- 07A source contract.  Only leading `/` commands are handled here.
--- @param request table
--- @param callback function
--- @return function|nil cancel
function Source:query(request, callback)
  if type(callback) ~= "function" then
    return nil
  end
  request = type(request) == "table" and request or {}
  local before = request.before_cursor
  if type(before) ~= "string" then
    local line = type(request.line) == "string" and request.line or ""
    before = line:sub(1, math.max(0, tonumber(request.col) or #line))
  end
  local trigger = util.parse_trigger(before, request.lnum)
  if not trigger or trigger.type ~= "command" then
    callback({ ok = true, items = {} })
    return nil
  end

  local location, location_err = self:_location(request)
  if not location then
    callback({ ok = false, error = location_err })
    return nil
  end

  local finished = false
  local function finish(result)
    if finished then
      return
    end
    finished = true
    callback(result)
  end

  local cancel = self:load(location, function(err, commands)
    if finished then
      return
    end
    if err then
      finish({ ok = false, error = util.normalize_error(err, "command_list_failed") })
      return
    end
    finish({
      ok = true,
      items = self:candidates(commands, trigger),
      start_col = 0,
    })
  end)

  if finished then
    return nil
  end
  return function()
    if finished then
      return
    end
    finished = true
    if cancel then
      pcall(cancel)
    end
  end
end

--- @param kind string|nil
function Source:invalidate(kind)
  if self.cache then
    self.cache:invalidate(kind)
  end
end

return M
