-- OpenCode agent completion source.
--
-- The V2 TUI exposes non-hidden, non-primary agents in the `@` completion
-- list and inserts `@<agent-id> `.  The structured prompt attachment is
-- `{ name = "<agent-id>", mention = { start, end, text } }`; the conversion
-- helper in sources/submit.lua builds that object from candidate metadata.

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

--- @param agent table
--- @return boolean
function M.available(agent)
  if type(agent) ~= "table" then
    return false
  end
  if agent.hidden == true then
    return false
  end
  if agent.mode == "primary" then
    return false
  end
  return type(agent.id) == "string" and agent.id ~= ""
end

--- Load agents for a location.
--- @param location table
--- @param callback fun(err: table|nil, agents: table[]|nil, location: table|nil)
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
    local cached = self.cache:get("agent", resolved.directory, self.ttl)
    if cached then
      callback(nil, cached, resolved)
      return nil
    end
  end

  local finished = false
  local function finish(err, agents, response_location)
    if finished then
      return
    end
    finished = true
    callback(err, agents, response_location or resolved)
  end

  local cancel = self.api:call("list_agents", { location = resolved }, function(err, raw)
    if err then
      finish(util.normalize_error(err, "agent_list_failed"))
      return
    end
    local list, response_location = util.unwrap_list(raw)
    if not list then
      finish(util.error("invalid_response", "agent list returned no list"))
      return
    end
    local agents = {}
    for _, value in ipairs(list) do
      if M.available(value) then
        agents[#agents + 1] = {
          id = value.id,
          name = type(value.name) == "string" and value.name or value.id,
          description = type(value.description) == "string" and value.description or nil,
          mode = value.mode,
          hidden = false,
          model = value.model,
          color = value.color,
          steps = value.steps,
        }
      end
    end
    if self.cache then
      self.cache:set("agent", resolved.directory, agents, self.ttl)
    end
    finish(nil, agents, response_location)
  end)
  if finished then
    return nil
  end
  return cancel
end

--- @param agents table[]
--- @param trigger table
--- @return table[]
function Source:candidates(agents, trigger)
  trigger = trigger or {}
  local query = trigger.raw_query
  if type(query) ~= "string" then
    query = trigger.query
  end
  local items = {}
  for _, agent in ipairs(agents or {}) do
    local id = agent.id
    if type(id) == "string" and id ~= "" then
      local metadata = {
        source = "opencode",
        type = "agent",
        kind = "agent",
        id = id,
        name = agent.name,
        description = agent.description,
        mode = agent.mode,
        hidden = false,
        model = agent.model,
        color = agent.color,
        steps = agent.steps,
        mention_text = "@" .. id,
        start_col = trigger.start_col,
        attachment = { name = id },
      }
      items[#items + 1] = {
        kind = "agent",
        name = id,
        text = "@" .. id .. " ",
        abbr = "@" .. id,
        menu = "agent",
        info = agent.description,
        metadata = metadata,
      }
    end
  end
  if query == nil or query == "" then
    return items
  end
  return util.rank(query, items, function(item)
    return item.name
  end)
end

--- 07A source contract.  Only `@` mentions are handled here.
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
  if not trigger or trigger.type ~= "mention" then
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

  local cancel = self:load(location, function(err, agents)
    if finished then
      return
    end
    if err then
      finish({ ok = false, error = util.normalize_error(err, "agent_list_failed") })
      return
    end
    finish({
      ok = true,
      items = self:candidates(agents, trigger),
      start_col = trigger.start_col,
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
