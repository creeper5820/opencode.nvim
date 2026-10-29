-- OpenCode skill completion source.
--
-- The V2 TUI inserts `@<skill-id> ` and sends the structured attachment
-- `{ id = "<skill-id>", mention = { start, end, text } }`.  Skill content is
-- not copied into candidates; only the fields needed by completion and submit
-- are retained.

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

--- Load skills for a location.
--- @param location table
--- @param callback fun(err: table|nil, skills: table[]|nil, location: table|nil)
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
    local cached = self.cache:get("skill", resolved.directory, self.ttl)
    if cached then
      callback(nil, cached, resolved)
      return nil
    end
  end

  local finished = false
  local function finish(err, skills, response_location)
    if finished then
      return
    end
    finished = true
    callback(err, skills, response_location or resolved)
  end

  local cancel = self.api:call("list_skills", { location = resolved }, function(err, raw)
    if err then
      finish(util.normalize_error(err, "skill_list_failed"))
      return
    end
    local list, response_location = util.unwrap_list(raw)
    if not list then
      finish(util.error("invalid_response", "skill list returned no list"))
      return
    end
    local skills = {}
    for _, value in ipairs(list) do
      if type(value) == "table" and type(value.id) == "string" and value.id ~= "" then
        skills[#skills + 1] = {
          id = value.id,
          name = type(value.name) == "string" and value.name or value.id,
          description = type(value.description) == "string" and value.description or nil,
          autoinvoke = value.autoinvoke,
          path = type(value.path) == "string" and value.path or nil,
        }
      end
    end
    if self.cache then
      self.cache:set("skill", resolved.directory, skills, self.ttl)
    end
    finish(nil, skills, response_location)
  end)
  if finished then
    return nil
  end
  return cancel
end

--- @param skills table[]
--- @param trigger table
--- @return table[]
function Source:candidates(skills, trigger)
  trigger = trigger or {}
  local query = trigger.raw_query
  if type(query) ~= "string" then
    query = trigger.query
  end
  local items = {}
  for _, skill in ipairs(skills or {}) do
    local id = skill.id
    if type(id) == "string" and id ~= "" then
      local metadata = {
        source = "opencode",
        type = "skill",
        kind = "skill",
        id = id,
        name = skill.name,
        description = skill.description,
        autoinvoke = skill.autoinvoke,
        path = skill.path,
        mention_text = "@" .. id,
        start_col = trigger.start_col,
        attachment = { id = id },
      }
      items[#items + 1] = {
        kind = "skill",
        name = id,
        text = "@" .. id .. " ",
        abbr = "@" .. id,
        menu = "skill",
        info = skill.description,
        metadata = metadata,
      }
    end
  end
  if query == nil or query == "" then
    return items
  end
  return util.rank(query, items, function(item)
    return { item.name, item.description }
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

  local cancel = self:load(location, function(err, skills)
    if finished then
      return
    end
    if err then
      finish({ ok = false, error = util.normalize_error(err, "skill_list_failed") })
      return
    end
    finish({
      ok = true,
      items = self:candidates(skills, trigger),
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
