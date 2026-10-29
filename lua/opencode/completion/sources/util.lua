-- Shared helpers for the OpenCode completion sources.
--
-- This module is pure Lua except for Neovim path helpers.  It never touches
-- buffers, windows, the pum or network state.

local M = {}

local uv = vim.uv or vim.loop

--- @param code string
--- @param message string
--- @param extra table|nil
--- @return table
function M.error(code, message, extra)
  local err = { code = code, message = message }
  for key, value in pairs(extra or {}) do
    err[key] = value
  end
  return err
end

--- Normalize an arbitrary error into the client/session error shape.
--- @param err any
--- @param fallback_code string|nil
--- @param fallback_message string|nil
--- @return table|nil
function M.normalize_error(err, fallback_code, fallback_message)
  if err == nil then
    return nil
  end
  local fallback = fallback_code or "source_error"
  if type(err) == "table" then
    local out = {}
    for key, value in pairs(err) do
      out[key] = value
    end
    if type(out.code) ~= "string" or out.code == "" then
      out.code = fallback
    end
    if type(out.message) ~= "string" or out.message == "" then
      if type(out.error) == "string" and out.error ~= "" then
        out.message = out.error
      elseif fallback_message ~= nil then
        out.message = fallback_message
      else
        out.message = ("%s failed"):format(out.code)
      end
    end
    return out
  end
  return M.error(fallback, fallback_message or tostring(err))
end

--- @param value any
--- @return boolean
function M.is_list(value)
  if type(value) ~= "table" then
    return false
  end
  if type(vim.islist) == "function" then
    return vim.islist(value)
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end
  return count == #value
end

--- Monotonic-ish milliseconds for cache TTL checks.
--- @return number
function M.now()
  if uv and type(uv.now) == "function" then
    return uv.now()
  end
  return os.time() * 1000
end

--- @param value any
--- @return string|nil
local function directory_value(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    if type(value.directory) == "string" then
      return value.directory
    end
    if type(value.root) == "string" then
      return value.root
    end
    if type(value.project_root) == "string" then
      return value.project_root
    end
    if type(value.location) == "table" then
      return directory_value(value.location)
    end
  end
  return nil
end

--- Normalize a project location to an absolute directory without a trailing
--- separator.  Returns nil when the value cannot be used.
--- @param value string|table|nil
--- @return string|nil
function M.directory(value)
  local raw = directory_value(value)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local normalized
  if type(vim.fs) == "table" and type(vim.fs.normalize) == "function" then
    normalized = vim.fs.normalize(raw)
  else
    normalized = raw
  end
  if type(vim.fn) == "table" and type(vim.fn.fnamemodify) == "function" then
    -- Make a relative project root absolute against the current process cwd.
    local ok, absolute = pcall(vim.fn.fnamemodify, normalized, ":p")
    if ok and type(absolute) == "string" and absolute ~= "" then
      normalized = absolute
    end
  end
  if normalized ~= "/" then
    normalized = normalized:gsub("[/\\]+$", "")
  end
  if normalized == "" then
    normalized = "/"
  end
  return normalized
end

--- @param value string|table|nil
--- @return table|nil location
--- @return table|nil err
function M.location(value)
  local directory = M.directory(value)
  if not directory then
    return nil, M.error("missing_location", "a project directory is required for completion queries")
  end
  return { directory = directory }
end

--- Resolve the location for a request.  An explicit source option wins over
--- the opaque completion context, so a source attached to a buffer cannot
--- accidentally switch projects when that buffer is moved.
--- @param opts table
--- @param request table|nil
--- @return table|nil location
--- @return table|nil err
function M.resolve_location(opts, request)
  opts = opts or {}
  local configured = opts.location or opts.directory or opts.root or opts.project_root
  if type(configured) == "function" then
    local ok, value = pcall(configured, request)
    if not ok then
      return nil, M.error("invalid_location", "location callback failed: " .. tostring(value))
    end
    configured = value
  end
  if configured ~= nil then
    return M.location(configured)
  end

  local context = type(request) == "table" and request.context or nil
  if type(context) == "table" then
    local candidate = context.location or context.directory or context.project_root or context.root
    if candidate ~= nil then
      return M.location(candidate)
    end
  end
  return nil, M.error("missing_location", "a project directory is required for completion queries")
end

--- Join a location and an entry path.  Absolute entry paths are returned
--- unchanged.
--- @param directory string
--- @param path string
--- @return string
function M.absolute_path(directory, path)
  if type(path) ~= "string" or path == "" then
    return directory
  end
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
    return path
  end
  return (directory:gsub("[/\\]+$", "") .. "/" .. path:gsub("^%./+", ""))
end

--- Return `path` relative to `directory` when it is inside it, otherwise the
--- original path.  Both arguments are expected to be normalized paths.
--- @param directory string
--- @param path string
--- @return string
function M.relative_path(directory, path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  local normalized = path:gsub("\\", "/")
  local root = directory:gsub("\\", "/"):gsub("/+$", "")
  if normalized == root then
    return "."
  end
  if normalized:sub(1, #root + 1) == root .. "/" then
    return normalized:sub(#root + 2)
  end
  return normalized
end

--- Clean a path returned by the filesystem endpoint for insertion.
--- @param path any
--- @return string|nil
function M.entry_path(path)
  if type(path) ~= "string" then
    return nil
  end
  local value = path:gsub("\\", "/")
  value = value:gsub("^%./+", "")
  if value == "" or value == "." then
    return nil
  end
  return value
end

--- Percent-encode a filesystem path as a file:// URI.
--- @param path string
--- @return string
function M.file_uri(path)
  local value = tostring(path):gsub("\\", "/")
  if value:sub(1, 1) ~= "/" then
    value = "/" .. value
  end
  value = value:gsub("[^%w%-%._~/]", function(char)
    return ("%%%02X"):format(char:byte())
  end)
  return "file://" .. value
end

--- Split the TUI line-range suffix (`#12` / `#12-14`) from a mention query.
--- Invalid suffixes are still stripped, matching OpenCode V2 TUI behaviour.
--- @param value string
--- @return string base
--- @return table|nil range
function M.split_line_range(value)
  local text = type(value) == "string" and value or ""
  local hash = text:match("^.*()#")
  if not hash then
    return text, nil
  end
  local base = text:sub(1, hash - 1)
  local suffix = text:sub(hash + 1)
  local first, last = suffix:match("^(%d+)%-(%d*)$")
  if not first then
    first = suffix:match("^(%d+)$")
    if not first then
      return base, nil
    end
    local start_line = tonumber(first)
    return base, { start = start_line, ["end"] = nil, startLine = start_line, endLine = nil }
  end
  local start_line = tonumber(first)
  local end_line = last ~= "" and tonumber(last) or nil
  if end_line ~= nil and end_line <= start_line then
    end_line = nil
  end
  return base, { start = start_line, ["end"] = end_line, startLine = start_line, endLine = end_line }
end

--- Format a path with the TUI's `#start[-end]` suffix.
--- @param path string
--- @param range table|nil
--- @return string
function M.with_line_range(path, range)
  if type(range) ~= "table" then
    return path
  end
  local start_line = range.start or range.startLine
  local end_line = range["end"] or range.endLine
  if type(start_line) ~= "number" then
    return path
  end
  if type(end_line) == "number" and end_line > start_line then
    return ("%s#%d-%d"):format(path, start_line, end_line)
  end
  return ("%s#%d"):format(path, start_line)
end

--- Parse an OpenCode command exactly like the V2 TUI (`/name arguments`).
--- Only a leading slash is considered; the name ends at the first space,
--- tab or newline.  Returns nil for non-command text.
--- @param text string|nil
--- @return string|nil name
--- @return string|nil arguments
function M.parse_command(text)
  if type(text) ~= "string" or text:sub(1, 1) ~= "/" then
    return nil
  end
  local rest = text:sub(2)
  local separator = rest:find("[ \t\n]")
  if not separator then
    return rest, ""
  end
  return rest:sub(1, separator - 1), rest:sub(separator + 1)
end

--- Parse an autocomplete trigger from the text before the cursor.
---
--- The V2 TUI only opens command completion at the very start of the prompt
--- (index 0), rejects a second slash in the command token, and rejects
--- whitespace in either the command or mention token.  A mention must begin at
--- the start of the prompt or after whitespace.
---
--- @param before_cursor string
--- @param lnum integer|nil 1-based cursor line
--- @return table|nil trigger
function M.parse_trigger(before_cursor, lnum)
  if type(before_cursor) ~= "string" then
    return nil
  end

  if before_cursor:sub(1, 1) == "/" and (lnum == nil or lnum == 1) then
    local rest = before_cursor:sub(2)
    if not rest:find("%s") and not rest:find("/", 1, true) then
      return {
        type = "command",
        trigger = "/",
        start_col = 0,
        token = rest,
        query = rest,
        raw_query = rest,
      }
    end
  end

  local at = before_cursor:match("^.*()@")
  if at then
    local before = at > 1 and before_cursor:sub(at - 1, at - 1) or nil
    local token = before_cursor:sub(at + 1)
    if (before == nil or before:match("%s")) and not token:find("%s") then
      local base, range = M.split_line_range(token)
      return {
        type = "mention",
        trigger = "@",
        start_col = at - 1,
        token = token,
        query = base,
        raw_query = token,
        line_range = range,
      }
    end
  end

  return nil
end

--- Return a fuzzy match score (higher is better), or nil when `query` does not
--- appear as either a prefix, substring or subsequence of any value.
--- @param query string
--- @param ... string|nil
--- @return number|nil
function M.fuzzy_score(query, ...)
  if type(query) ~= "string" or query == "" then
    return 0
  end
  local needle = query:lower()
  local best
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" and value ~= "" then
      local haystack = value:lower()
      local score
      if haystack == needle then
        score = 1000 - #haystack
      elseif haystack:sub(1, #needle) == needle then
        score = 900 - (#haystack - #needle)
      else
        local position = haystack:find(needle, 1, true)
        if position then
          score = 700 - position - (#haystack - #needle) / 100
        else
          local cursor = 1
          local gaps = 0
          local last = nil
          for index = 1, #haystack do
            if haystack:sub(index, index) == needle:sub(cursor, cursor) then
              if last ~= nil then
                gaps = gaps + (index - last - 1)
              end
              last = index
              cursor = cursor + 1
              if cursor > #needle then
                break
              end
            end
          end
          if cursor > #needle then
            score = 500 - gaps - (#haystack - #needle) / 100
          end
        end
      end
      if score ~= nil and (best == nil or score > best) then
        best = score
      end
    end
  end
  return best
end

--- Sort candidates by fuzzy score in descending order.  Candidates without a
--- score are dropped.  Stable for equal scores.
--- @param query string
--- @param candidates table[]
--- @param keys function(candidate):string|string[]
--- @return table[]
function M.rank(query, candidates, keys)
  local ranked = {}
  for _, candidate in ipairs(candidates) do
    local values = keys(candidate)
    if type(values) ~= "table" then
      values = { values }
    end
    local score = M.fuzzy_score(query, unpack(values))
    if score ~= nil then
      ranked[#ranked + 1] = { candidate = candidate, score = score }
    end
  end
  table.sort(ranked, function(left, right)
    if left.score == right.score then
      return left.candidate.name < right.candidate.name
    end
    return left.score > right.score
  end)
  local result = {}
  for _, entry in ipairs(ranked) do
    result[#result + 1] = entry.candidate
  end
  return result
end

--- Unwrap the `{ location, data }` envelope used by OpenCode V2 list routes.
--- Also accepts a bare list and a few harmless envelope aliases.
--- @param value any
--- @return table[]|nil list
--- @return table|nil location
function M.unwrap_list(value)
  if type(value) ~= "table" then
    return nil, nil
  end
  local location = value.location
  local current = value
  for _ = 1, 4 do
    if type(current) ~= "table" then
      return nil, location
    end
    if M.is_list(current) then
      return current, location
    end
    if type(current.location) == "table" then
      location = current.location
    end
    if current.data ~= nil then
      current = current.data
    elseif current.items ~= nil then
      current = current.items
    elseif current.entries ~= nil then
      current = current.entries
    else
      return nil, location
    end
  end
  if M.is_list(current) then
    return current, location
  end
  return nil, location
end

--- Normalize a returned cancel handle to a function.
--- @param handle any
--- @return function|nil
function M.normalize_cancel(handle)
  if type(handle) == "function" then
    return handle
  end
  if type(handle) == "table" then
    local cancel = handle.cancel or handle.abort or handle.stop
    if type(cancel) == "function" then
      return function()
        return cancel(handle)
      end
    end
  end
  return nil
end

--- Bind a table method so both `object.method(args...)` and
--- `object:method(args...)` work without changing the method body.
--- @param instance table
--- @param method function
--- @return function
function M.bind(instance, method)
  return function(...)
    if select("#", ...) > 0 and select(1, ...) == instance then
      return method(instance, select(2, ...))
    end
    return method(instance, ...)
  end
end

--- @param value any
--- @return boolean
function M.truthy(value)
  return value ~= nil and value ~= false
end

return M
