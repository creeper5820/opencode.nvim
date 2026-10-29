-- Small TTL cache used by completion sources.
--
-- Cache entries are always scoped by a caller-supplied key that includes the
-- project location, so two attached projects never share results.  The cache
-- itself performs no I/O and can be invalidated by kind or completely when the
-- OpenCode service/configuration changes.

local util = require("opencode.completion.sources.util")

local M = {}

local Cache = {}
Cache.__index = Cache

--- @param opts table|nil
--- @return table
function M.new(opts)
  opts = opts or {}
  local ttl = opts.ttl
  if type(ttl) ~= "number" then
    ttl = 30000
  end
  local file_ttl = opts.file_ttl
  if type(file_ttl) ~= "number" then
    file_ttl = 0
  end
  return setmetatable({
    entries = {},
    ttl = math.max(0, ttl),
    file_ttl = math.max(0, file_ttl),
  }, Cache)
end

--- @param kind string
--- @param key string
--- @return string
local function bucket_key(kind, key)
  return kind .. "\0" .. key
end

--- @param kind string
--- @param ttl number|nil
--- @return number
function Cache:ttl_for(kind, ttl)
  if type(ttl) == "number" then
    return math.max(0, ttl)
  end
  if kind == "file_find" or kind == "file_list" then
    return self.file_ttl
  end
  return self.ttl
end

--- @param kind string
--- @param key string
--- @param ttl number|nil
--- @return any|nil
function Cache:get(kind, key, ttl)
  local bucket = bucket_key(kind, key)
  local entry = self.entries[bucket]
  if entry == nil then
    return nil
  end
  local lifetime = type(ttl) == "number" and math.max(0, ttl) or entry.ttl
  if lifetime <= 0 then
    return nil
  end
  if util.now() - entry.at > lifetime then
    self.entries[bucket] = nil
    return nil
  end
  return entry.value
end

--- @param kind string
--- @param key string
--- @param value any
--- @param ttl number|nil
function Cache:set(kind, key, value, ttl)
  local lifetime = self:ttl_for(kind, ttl)
  if lifetime <= 0 then
    return
  end
  self.entries[bucket_key(kind, key)] = {
    at = util.now(),
    ttl = lifetime,
    value = value,
  }
end

--- Invalidate one kind, or every kind when `kind` is nil.
--- @param kind string|nil
function Cache:invalidate(kind)
  if kind == nil then
    self.entries = {}
    return
  end
  local prefix = kind .. "\0"
  for key in pairs(self.entries) do
    if key:sub(1, #prefix) == prefix then
      self.entries[key] = nil
    end
  end
end

function Cache:clear()
  self.entries = {}
end

--- @return integer
function Cache:size()
  local count = 0
  for _ in pairs(self.entries) do
    count = count + 1
  end
  return count
end

M.Cache = Cache

return M
