-- OpenCode V2 endpoint definitions.
--
-- This module is pure: it only turns already-validated arguments into the
-- method, path, query and body needed by opencode.client. It never performs
-- I/O, keeps no state and does not touch Neovim buffers or windows.

local M = {}

---Percent-encode one value for use as a path segment or query key/value.
---Only RFC 3986 unreserved characters are kept literal. Existing percent
---escapes are encoded again so a literal session ID is never reinterpreted.
---@param value string|number
---@return string
local function percent_encode(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(char)
    return ("%%%02X"):format(char:byte())
  end))
end

M.percent_encode = percent_encode

---Build a deterministic application/x-www-form-urlencoded query string.
---Array values are joined with commas (used by the event type filter).
---@param params table<string, string|number|boolean|string[]|nil>
---@return string
local function query_string(params)
  local keys = {}
  for key, value in pairs(params) do
    if value ~= nil then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)

  local parts = {}
  for _, key in ipairs(keys) do
    local value = params[key]
    if type(value) == "table" then
      value = table.concat(value, ",")
    end
    parts[#parts + 1] = percent_encode(key) .. "=" .. percent_encode(value)
  end
  return table.concat(parts, "&")
end

M.query_string = query_string

---@param session_id string
---@return string
local function session_path(session_id)
  return "/api/session/" .. percent_encode(session_id)
end

---@return table
function M.info()
  return { method = "GET", path = "/api/info" }
end

---@param filters table
---@return table
function M.list_sessions(filters)
  return {
    method = "GET",
    path = "/api/session",
    query = query_string(filters),
  }
end

---@param payload table
---@return table
function M.create_session(payload)
  return { method = "POST", path = "/api/session", body = payload }
end

---@param session_id string
---@param filters table
---@return table
function M.list_messages(session_id, filters)
  return {
    method = "GET",
    path = session_path(session_id) .. "/message",
    query = query_string(filters),
  }
end

---@param session_id string
---@param payload table
---@return table
function M.prompt(session_id, payload)
  return {
    method = "POST",
    path = session_path(session_id) .. "/prompt",
    body = payload,
  }
end

---@param session_id string
---@param payload table
---@return table
function M.command(session_id, payload)
  return {
    method = "POST",
    path = session_path(session_id) .. "/command",
    body = payload,
  }
end

---Build the deep-object location query used by the V2 query routes.
---@param location table
---@param extra table|nil
---@return string
local function location_query(location, extra)
  local query = {
    ["location[directory]"] = location.directory,
  }
  for key, value in pairs(extra or {}) do
    query[key] = value
  end
  return query_string(query)
end

---@param location table
---@param filters table
---@return table
function M.find_files(location, filters)
  return {
    method = "GET",
    path = "/api/fs/find",
    query = location_query(location, filters),
  }
end

---@param location table
---@param filters table
---@return table
function M.list_files(location, filters)
  return {
    method = "GET",
    path = "/api/fs/list",
    query = location_query(location, filters),
  }
end

---@param location table
---@return table
function M.list_commands(location)
  return {
    method = "GET",
    path = "/api/command",
    query = location_query(location),
  }
end

---@param location table
---@return table
function M.list_agents(location)
  return {
    method = "GET",
    path = "/api/agent",
    query = location_query(location),
  }
end

---@param location table
---@return table
function M.list_skills(location)
  return {
    method = "GET",
    path = "/api/skill",
    query = location_query(location),
  }
end

---@param session_id string
---@param filters table
---@return table
function M.interrupt(session_id, filters)
  return {
    method = "POST",
    path = session_path(session_id) .. "/interrupt",
    query = query_string(filters),
  }
end

---@param filters table
---@return table
function M.stream_events(filters)
  return {
    method = "GET",
    path = "/api/event",
    query = query_string(filters),
  }
end

return M
