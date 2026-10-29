-- Filesystem completion source.
--
-- Uses the OpenCode V2 filesystem routes through the completion API adapter:
--
--   find_files({ location, query, type?, limit })
--   list_files({ location, path })
--
-- The combined `@` source calls `find` (the TUI does the same).  `list` is
-- exposed for callers that implement directory expansion explicitly.  Entry
-- paths returned by OpenCode are relative to the requested location; they are
-- inserted verbatim so spaces and UTF-8 survive completion.

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
    limit = type(opts.limit) == "number" and math.max(1, math.floor(opts.limit)) or 20,
  }, Source)
  instance.query = util.bind(instance, Source.query)
  instance.find = util.bind(instance, Source.find)
  instance.list = util.bind(instance, Source.list)
  instance.invalidate = util.bind(instance, Source.invalidate)
  instance.load = util.bind(instance, Source.load)
  instance.candidates = util.bind(instance, Source.candidates)
  return instance
end

--- @param request table
--- @return table|nil location
--- @return table|nil err
function Source:_location(request)
  return util.resolve_location(self.opts, request)
end

--- @param kind string
--- @param key string
--- @param ttl number|nil
--- @return table[]|nil
function Source:_cached(kind, key, ttl)
  if not self.cache then
    return nil
  end
  return self.cache:get(kind, key, ttl)
end

--- @param kind string
--- @param key string
--- @param entries table[]
--- @param ttl number|nil
function Source:_store(kind, key, entries, ttl)
  if self.cache then
    self.cache:set(kind, key, entries, ttl)
  end
end

--- Find entries matching a fuzzy filesystem query.
--- @param query string|nil
--- @param opts table|function|nil
--- @param callback fun(err: table|nil, entries: table[]|nil, location: table|nil)
--- @return function|nil cancel
function Source:find(query, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  if type(callback) ~= "function" then
    return nil
  end
  if query ~= nil and type(query) ~= "string" then
    callback(util.error("invalid_argument", "filesystem query must be a string"))
    return nil
  end
  query = query or ""

  local location, location_err = util.resolve_location(
    {
      location = opts.location
        or opts.directory
        or opts.root
        or opts.project_root
        or self.opts.location,
    },
    opts
  )
  if not location then
    callback(location_err)
    return nil
  end

  local limit = opts.limit
  if type(limit) ~= "number" or limit < 1 then
    limit = self.limit
  else
    limit = math.floor(limit)
  end
  local kind
  if opts.type == "file" or opts.type == "directory" then
    kind = opts.type
  end

  local key = table.concat({ location.directory, query, kind or "", tostring(limit) }, "\0")
  local cached = self:_cached("file_find", key, self.opts.file_cache_ttl)
  if cached then
    callback(nil, cached, location)
    return nil
  end

  local finished = false
  local function finish(err, entries, response_location)
    if finished then
      return
    end
    finished = true
    callback(err, entries, response_location or location)
  end

  local params = {
    location = location,
    query = query,
    limit = limit,
  }
  if kind then
    params.type = kind
  end

  local cancel = self.api:call("find_files", params, function(err, raw)
    if err then
      finish(util.normalize_error(err, "file_find_failed"))
      return
    end
    local entries, response_location = util.unwrap_list(raw)
    if not entries then
      finish(util.error("invalid_response", "filesystem find returned no entry list"))
      return
    end
    self:_store("file_find", key, entries, self.opts.file_cache_ttl)
    finish(nil, entries, response_location)
  end)
  if finished then
    return nil
  end
  return cancel
end

--- List direct children of a directory.
--- @param path string|nil
--- @param opts table|function|nil
--- @param callback fun(err: table|nil, entries: table[]|nil, location: table|nil)
--- @return function|nil cancel
function Source:list(path, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  if type(callback) ~= "function" then
    return nil
  end
  if path ~= nil and type(path) ~= "string" then
    callback(util.error("invalid_argument", "filesystem path must be a string"))
    return nil
  end
  path = path or ""

  local location, location_err = util.resolve_location(
    {
      location = opts.location
        or opts.directory
        or opts.root
        or opts.project_root
        or self.opts.location,
    },
    opts
  )
  if not location then
    callback(location_err)
    return nil
  end

  local key = location.directory .. "\0" .. path
  local cached = self:_cached("file_list", key, self.opts.file_cache_ttl)
  if cached then
    callback(nil, cached, location)
    return nil
  end

  local finished = false
  local function finish(err, entries, response_location)
    if finished then
      return
    end
    finished = true
    callback(err, entries, response_location or location)
  end

  local params = { location = location }
  if path ~= "" then
    params.path = path
  end

  local cancel = self.api:call("list_files", params, function(err, raw)
    if err then
      finish(util.normalize_error(err, "file_list_failed"))
      return
    end
    local entries, response_location = util.unwrap_list(raw)
    if not entries then
      finish(util.error("invalid_response", "filesystem list returned no entry list"))
      return
    end
    self:_store("file_list", key, entries, self.opts.file_cache_ttl)
    finish(nil, entries, response_location)
  end)
  if finished then
    return nil
  end
  return cancel
end

--- Convert filesystem entries into 07A candidates.
--- @param entries table[]
--- @param trigger table
--- @param location table
--- @return table[]
function Source:candidates(entries, trigger, location)
  local items = {}
  trigger = trigger or {}
  location = location or {}
  local directory = location.directory or ""

  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" then
      local path = util.entry_path(entry.path)
      if path then
        local is_directory = entry.type == "directory"
        local display_path = util.relative_path(directory, path)
        if display_path == "" then
          display_path = path
        end
        local line_range = (not is_directory) and trigger.line_range or nil
        local name = util.with_line_range(display_path, line_range)
        local mention_name = is_directory and display_path:gsub("/+$", "") or name
        local insertion
        if is_directory then
          insertion = "@" .. mention_name .. "/"
        else
          insertion = "@" .. name .. " "
        end
        local absolute = util.absolute_path(directory, path)
        local metadata = {
          source = "opencode",
          type = is_directory and "directory" or "file",
          kind = "file",
          file_type = is_directory and "directory" or "file",
          path = display_path,
          absolute_path = absolute,
          uri = util.file_uri(absolute),
          name = name,
          is_directory = is_directory,
          line_range = line_range,
          mention_text = "@" .. mention_name,
          start_col = trigger.start_col,
        }
        if not is_directory then
          metadata.attachment = {
            uri = metadata.uri,
            name = name,
          }
        end
        items[#items + 1] = {
          kind = "file",
          text = insertion,
          abbr = insertion:gsub("%s+$", ""),
          menu = is_directory and "directory" or "file",
          info = is_directory and (display_path .. "/") or name,
          metadata = metadata,
        }
      end
    end
  end
  return items
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

  local cancel = self:find(trigger.query, { location = location }, function(err, entries)
    if finished then
      return
    end
    if err then
      finish({ ok = false, error = util.normalize_error(err, "file_find_failed") })
      return
    end
    finish({
      ok = true,
      items = self:candidates(entries, trigger, location),
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

--- Clear cached filesystem results.  Called by the combined source.
--- @param kind string|nil
function Source:invalidate(kind)
  if self.cache then
    if kind == "file" then
      self.cache:invalidate("file_find")
      self.cache:invalidate("file_list")
    else
      self.cache:invalidate(kind)
    end
  end
end

return M
