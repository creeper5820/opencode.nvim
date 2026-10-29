-- Helpers for the OpenCode API client unit tests.
local M = {}

---Create a fake transport that records requests and streams.  Completion is
---driven explicitly by the test so cancellation can be observed.
function M.transport()
  local transport = {
    requests = {},
    streams = {},
    request_cancel_count = 0,
    stream_cancel_count = 0,
  }

  function transport.request(opts, callback)
    local entry = {
      opts = opts,
      callback = callback,
      cancelled = false,
      cancel_count = 0,
    }
    transport.requests[#transport.requests + 1] = entry
    if transport.request_start_error then
      return nil, transport.request_start_error
    end
    return function()
      if entry.cancelled then
        return
      end
      entry.cancelled = true
      entry.cancel_count = entry.cancel_count + 1
      transport.request_cancel_count = transport.request_cancel_count + 1
    end
  end

  function transport.stream(opts, handlers)
    local entry = {
      opts = opts,
      handlers = handlers,
      cancelled = false,
      cancel_count = 0,
    }
    transport.streams[#transport.streams + 1] = entry
    if transport.stream_start_error then
      return nil, transport.stream_start_error
    end
    return function()
      if entry.cancelled then
        return
      end
      entry.cancelled = true
      entry.cancel_count = entry.cancel_count + 1
      transport.stream_cancel_count = transport.stream_cancel_count + 1
    end
  end

  local function request(index)
    local entry = transport.requests[index]
    assert(entry, "missing request " .. tostring(index))
    return entry
  end

  local function stream(index)
    local entry = transport.streams[index]
    assert(entry, "missing stream " .. tostring(index))
    return entry
  end

  function transport:respond(index, response)
    local entry = request(index)
    if not entry.cancelled then
      entry.callback(nil, response)
    end
  end

  function transport:fail(index, err)
    local entry = request(index)
    if not entry.cancelled then
      entry.callback(err, nil)
    end
  end

  function transport:complete(index, response)
    transport:respond(index, response)
    transport:respond(index, response)
  end

  function transport:stream_headers(index, response)
    local entry = stream(index)
    if not entry.cancelled then
      entry.handlers.on_headers(response)
    end
  end

  function transport:stream_chunk(index, chunk)
    local entry = stream(index)
    if not entry.cancelled then
      entry.handlers.on_chunk(chunk)
    end
  end

  function transport:stream_done(index, err)
    local entry = stream(index)
    if not entry.cancelled then
      entry.handlers.on_done(err)
    end
  end

  return transport
end

---@param headers table|nil
---@param name string
---@return any
function M.header(headers, name)
  local wanted = name:lower()
  for key, value in pairs(headers or {}) do
    if key:lower() == wanted then
      return value
    end
  end
  return nil
end

---@param value string
---@return string
local function unescape(value)
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---@param url string
---@return string path
---@return table query
function M.split_url(url)
  local path, query = url:match("^https?://[^/]+(/[^?]*)(.*)$")
  if not path then
    path, query = url, ""
  end
  local values = {}
  if query and query ~= "" then
    for pair in query:sub(2):gmatch("[^&]+") do
      local key, value = pair:match("^([^=]*)=?(.*)$")
      values[unescape(key)] = unescape(value)
    end
  end
  return path, values
end

---@param request table
---@return table|nil
function M.body(request)
  if not request.opts.body then
    return nil
  end
  return vim.json.decode(request.opts.body)
end

return M
