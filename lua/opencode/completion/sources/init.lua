-- OpenCode completion sources and candidate/submit conversions.
--
-- Public entry point for task 10 assembly:
--
--   local sources = require("opencode.completion.sources")
--   local source = sources.new({
--     client = client,                    -- opencode.client or adapter
--     session = session,                  -- optional, used by :submit()
--     location = function() ... end,      -- project root or { directory = ... }
--     limit = 20,                         -- filesystem find limit (TUI: 20)
--     cache_ttl = 30000,                  -- commands/agents/skills
--     file_cache_ttl = 0,                 -- optional filesystem cache
--   })
--   completion.attach(bufnr, { source = source, context = ... })
--
-- The source implements the 07A contract:
--
--   source:query(request, callback) -> cancel_handle|nil
--
-- `request` is the 07A request.  The project directory is resolved from the
-- source's `location` option first, then from `request.context.location`,
-- `request.context.directory`, `request.context.project_root` or
-- `request.context.root`.  Every API request carries
-- `location = { directory = root }`, and every cache key includes that root.
--
-- Supported candidate kinds: `file`, `command`, `agent`, `skill`.  V2
-- project-reference completion is not implemented; `build_submission()`
-- reports `unsupported_kind` for such candidates instead of degrading to a
-- plain prompt.  `source.invalidate(kind)` and `source.set_client(client)`
-- drop cached service data so configuration/service changes can be reflected.
--
-- Candidate metadata is a plain table and is passed through 07A unchanged.
-- `source:build_submission(candidate, opts)` converts it into the structured
-- session input documented in sources/submit.lua, and `source:submit(...)`
-- routes commands to session.submit/command and plain text to session.prompt.

local api_mod = require("opencode.completion.sources.api")
local cache_mod = require("opencode.completion.sources.cache")
local command_source = require("opencode.completion.sources.command")
local filesystem_source = require("opencode.completion.sources.filesystem")
local agent_source = require("opencode.completion.sources.agent")
local skill_source = require("opencode.completion.sources.skill")
local submit_mod = require("opencode.completion.sources.submit")
local util = require("opencode.completion.sources.util")

local M = {}

local Source = {}
Source.__index = Source

--- @param opts table|nil
--- @return table
function M.new(opts)
  opts = opts or {}
  local api = opts.api or api_mod.new(opts.client, opts)
  local cache = opts.cache or cache_mod.new({
    ttl = opts.cache_ttl,
    file_ttl = opts.file_cache_ttl,
  })
  local common = {
    api = api,
    cache = cache,
    opts = opts,
    client = opts.client,
    location = opts.location or opts.directory or opts.root or opts.project_root,
    limit = opts.limit,
    cache_ttl = opts.cache_ttl,
    file_cache_ttl = opts.file_cache_ttl,
    session = opts.session,
  }
  local source = setmetatable({
    opts = opts,
    api = api,
    cache = cache,
    filesystem = filesystem_source.new(common),
    command = command_source.new(common),
    agent = agent_source.new(common),
    skill = skill_source.new(common),
  }, Source)
  source.query = util.bind(source, Source.query)
  source.location = util.bind(source, Source.location)
  source.invalidate = util.bind(source, Source.invalidate)
  source.set_client = util.bind(source, Source.set_client)
  source.refresh = util.bind(source, Source.refresh)
  source.find = util.bind(source, Source.find)
  source.list = util.bind(source, Source.list)
  source.supports = util.bind(source, Source.supports)
  source.build_submission = util.bind(source, Source.build_submission)
  source.submit = util.bind(source, Source.submit)
  source.submit_text = util.bind(source, Source.submit_text)
  return source
end

--- @param request table
--- @return table|nil location
--- @return table|nil err
function Source:location(request)
  return util.resolve_location(self.opts, request)
end

--- @param request table
--- @param callback function
--- @return function|nil cancel
function Source:_query_mention(request, location, trigger, callback)
  local slots = { skill = {}, agent = {}, file = {} }
  local errors = {}
  local remaining = 3
  local finished = false
  local cancels = {}

  local subrequest = {}
  for key, value in pairs(request) do
    subrequest[key] = value
  end
  subrequest.context = {
    location = location,
    directory = location.directory,
  }

  local function finish(result)
    if finished then
      return
    end
    finished = true
    callback(result)
  end

  local function complete(key, result)
    if finished then
      return
    end
    if type(result) == "table" and result.ok then
      slots[key] = type(result.items) == "table" and result.items or {}
    else
      local err = type(result) == "table" and result.error or nil
      errors[#errors + 1] = {
        kind = key,
        error = util.normalize_error(err, key .. "_source_failed", ("%s completion source failed"):format(key)),
      }
    end
    remaining = remaining - 1
    if remaining > 0 then
      return
    end
    if #errors == 3 then
      finish({ ok = false, error = errors[1].error, errors = errors })
      return
    end
    local items = {}
    -- The TUI groups skills before agents before filesystem matches.
    for _, group in ipairs({ "skill", "agent", "file" }) do
      for _, item in ipairs(slots[group] or {}) do
        items[#items + 1] = item
      end
    end
    local result = {
      ok = true,
      items = items,
      start_col = trigger.start_col,
    }
    if #errors > 0 then
      result.errors = errors
    end
    finish(result)
  end

  local function run(key, source)
    if finished then
      return
    end
    local ok, cancel = pcall(source.query, source, subrequest, function(result)
      complete(key, result)
    end)
    if not ok then
      complete(key, {
        ok = false,
        error = util.error(key .. "_source_failed", tostring(cancel)),
      })
      return
    end
    if type(cancel) == "function" and not finished then
      cancels[#cancels + 1] = cancel
    end
  end

  run("skill", self.skill)
  run("agent", self.agent)
  run("file", self.filesystem)

  if finished then
    return nil
  end
  return function()
    if finished then
      return
    end
    finished = true
    for _, cancel in ipairs(cancels) do
      pcall(cancel)
    end
  end
end

--- 07A source contract.
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
  if not trigger then
    callback({ ok = true, items = {} })
    return nil
  end

  if trigger.type == "command" then
    return self.command:query(request, callback)
  end

  local location, location_err = self:location(request)
  if not location then
    callback({ ok = false, error = location_err })
    return nil
  end
  return self:_query_mention(request, location, trigger, callback)
end

--- Invalidate cached OpenCode data.  `kind` may be "command", "agent",
--- "skill", "file" or nil (all).  Filesystem find/list caches are both
--- cleared by "file".
--- @param kind string|nil
function Source:invalidate(kind)
  if kind == "file" then
    self.cache:invalidate("file_find")
    self.cache:invalidate("file_list")
    return
  end
  self.cache:invalidate(kind)
end

--- Replace the client used for subsequent queries and drop every cached list.
--- @param client table
function Source:set_client(client)
  if type(self.api.set_client) == "function" then
    self.api:set_client(client)
  end
  self.opts.client = client
  self.cache:clear()
end

--- Convenience wrapper for the filesystem find route.
--- @param query string|nil
--- @param opts table|function|nil
--- @param callback function|nil
function Source:find(query, opts, callback)
  return self.filesystem:find(query, opts, callback)
end

--- Convenience wrapper for the filesystem list route.
--- @param path string|nil
--- @param opts table|function|nil
--- @param callback function|nil
function Source:list(path, opts, callback)
  return self.filesystem:list(path, opts, callback)
end

--- Alias for integrations that reload configuration/service data.
function Source:refresh()
  self.cache:clear()
end

--- @param kind string
--- @return boolean
function Source:supports(kind)
  return kind == "file"
    or kind == "directory"
    or kind == "command"
    or kind == "agent"
    or kind == "skill"
end

--- @param candidate table
--- @param opts table|nil
--- @return table|nil input
--- @return table|nil err
function Source:build_submission(candidate, opts)
  return submit_mod.build(candidate, opts)
end

--- Submit a candidate using the session supplied to `sources.new`.
--- @param candidate table
--- @param opts table|nil
--- @param callback function|nil
function Source:submit(candidate, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  return submit_mod.submit(self.opts.session, candidate, opts, callback)
end

--- Submit free-form text using the session supplied to `sources.new`.
--- @param text string
--- @param opts table|nil
--- @param callback function|nil
function Source:submit_text(text, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  return submit_mod.submit_text(self.opts.session, text, opts, callback)
end

M.trigger = util.parse_trigger
M.parse_trigger = util.parse_trigger
M.parse_command = util.parse_command
M.build_submission = submit_mod.build
M.submit = submit_mod.submit
M.submit_text = submit_mod.submit_text
M.known_command = submit_mod.known_command
M.api = api_mod
M.cache = cache_mod

return M
