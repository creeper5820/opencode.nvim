-- RPC protocol shared by the local Neovim tool server (09A) and the
-- OpenCode TypeScript plugin / action handlers (09B, 09C, 09D).
--
-- Envelope (request):
--   POST /tools/<action>
--   Authorization: Bearer <token>
--   Content-Type: application/json
--
--   {
--     "version": 1,
--     "request_id": "client-generated-id",
--     "action": "open",
--     "input": { ... }
--   }
--
-- Envelope (success):
--   { "version": 1, "ok": true, "request_id": "...", "result": { ... } }
--
-- Envelope (failure):
--   { "version": 1, "ok": false, "request_id": "...",
--     "error": { "code": "INVALID_REQUEST", "message": "...",
--                "details": optional JSON value } }
--
-- GET /health uses the same envelope and returns:
--   { "status": "ok", "instance_id": "...", "project_root": "...",
--     "pid": 123, "version": 1 }
--
-- All routes, including /health, require the bearer token. The token is
-- never echoed in responses or error messages.
--
-- Routes:
--   GET  /health
--   POST /tools/open
--   POST /tools/notify
--   POST /tools/diff
--
-- Error codes and HTTP statuses are defined in ERROR_CODES and STATUS below.
-- Unknown handler error codes map to HTTP 500.

local M = {}

M.VERSION = 1
M.ENVELOPE_VERSION = 1

M.ACTIONS = { "open", "notify", "diff" }

M.ERROR_CODES = {
  INVALID_REQUEST = "INVALID_REQUEST",
  INVALID_JSON = "INVALID_JSON",
  INVALID_HEADER = "INVALID_HEADER",
  UNAUTHORIZED = "UNAUTHORIZED",
  NOT_FOUND = "NOT_FOUND",
  METHOD_NOT_ALLOWED = "METHOD_NOT_ALLOWED",
  PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE",
  HEADERS_TOO_LARGE = "HEADERS_TOO_LARGE",
  SLOW_CONNECTION = "SLOW_CONNECTION",
  TIMEOUT = "TIMEOUT",
  UPSTREAM_ABORTED = "UPSTREAM_ABORTED",
  SERVER_BUSY = "SERVER_BUSY",
  ACTION_FAILED = "ACTION_FAILED",
  INTERNAL_ERROR = "INTERNAL_ERROR",
}

-- HTTP status for each protocol error code.
local STATUS = {
  INVALID_REQUEST = 400,
  INVALID_JSON = 400,
  INVALID_HEADER = 400,
  UNAUTHORIZED = 401,
  NOT_FOUND = 404,
  METHOD_NOT_ALLOWED = 405,
  PAYLOAD_TOO_LARGE = 413,
  HEADERS_TOO_LARGE = 431,
  SLOW_CONNECTION = 408,
  TIMEOUT = 504,
  UPSTREAM_ABORTED = 499,
  SERVER_BUSY = 503,
  ACTION_FAILED = 422,
  INTERNAL_ERROR = 500,
}

function M.status_for_code(code)
  return STATUS[code] or 500
end

function M.error(code, message, details)
  return {
    code = code or M.ERROR_CODES.INTERNAL_ERROR,
    message = message or "internal error",
    details = details,
  }
end

--- Build a success envelope.
function M.ok(result, request_id)
  return {
    version = M.ENVELOPE_VERSION,
    ok = true,
    request_id = request_id,
    result = result == nil and vim.NIL or result,
  }
end

--- Build a failure envelope.
function M.fail(code, message, request_id, details)
  return {
    version = M.ENVELOPE_VERSION,
    ok = false,
    request_id = request_id,
    error = M.error(code, message, details),
  }
end

--- Normalize any handler failure into a protocol error table.
function M.normalize_error(err)
  if type(err) == "table" then
    local code = type(err.code) == "string" and err.code or nil
    local message = type(err.message) == "string" and err.message or nil
    if code then
      return M.error(code, message or code, err.details)
    end
    if message then
      return M.error(M.ERROR_CODES.ACTION_FAILED, message)
    end
  elseif type(err) == "string" and err ~= "" then
    return M.error(M.ERROR_CODES.ACTION_FAILED, err)
  end
  return M.error(M.ERROR_CODES.ACTION_FAILED, "action failed")
end

local function valid_id(value)
  return type(value) == "string" and #value > 0 and #value <= 128
end

--- Validate a decoded request body against the fixed envelope.
-- `expected_action` is the action selected by the route.
-- Returns `request, nil` or `nil, protocol_error`.
function M.parse_request(body, expected_action)
  if type(body) ~= "table" or (vim.islist(body) and next(body) ~= nil) then
    return nil, M.error(M.ERROR_CODES.INVALID_REQUEST, "request body must be a JSON object")
  end
  if body.version ~= M.ENVELOPE_VERSION then
    return nil,
      M.error(
        M.ERROR_CODES.INVALID_REQUEST,
        "unsupported envelope version",
        { expected = M.ENVELOPE_VERSION }
      )
  end
  if not valid_id(body.request_id) then
    return nil, M.error(M.ERROR_CODES.INVALID_REQUEST, "request_id must be a non-empty string")
  end
  if not valid_id(body.action) then
    return nil, M.error(M.ERROR_CODES.INVALID_REQUEST, "action must be a non-empty string")
  end
  if expected_action and body.action ~= expected_action then
    return nil,
      M.error(M.ERROR_CODES.INVALID_REQUEST, "action does not match route", {
        route = expected_action,
      })
  end
  local input = body.input
  if input == nil then
    input = {}
  elseif type(input) ~= "table" or (vim.islist(input) and next(input) ~= nil) then
    return nil, M.error(M.ERROR_CODES.INVALID_REQUEST, "input must be a JSON object")
  end
  return {
    version = body.version,
    request_id = body.request_id,
    action = body.action,
    input = input,
  }
end

--- Constant-time comparison for secrets.
function M.secure_compare(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then
    return false
  end
  if #a ~= #b then
    return false
  end
  -- Neovim ships LuaJIT with the `bit` library. Keep a functional fallback in
  -- case the server is loaded in a stripped-down Lua runtime.
  local bitlib = rawget(_G, "bit")
  if bitlib and bitlib.bxor then
    local diff = 0
    for i = 1, #a do
      diff = bitlib.bor(diff, bitlib.bxor(a:byte(i), b:byte(i)))
    end
    return diff == 0
  end
  local mismatch = false
  for i = 1, #a do
    if a:byte(i) ~= b:byte(i) then
      mismatch = true
    end
  end
  return not mismatch
end

--- Check an Authorization header value. Accepts "Bearer <token>" only.
-- Returns true when the header carries the expected token.
function M.check_bearer(header_value, expected_token)
  if type(header_value) ~= "string" or type(expected_token) ~= "string" then
    return false
  end
  if expected_token == "" then
    return false
  end
  local prefix = "Bearer "
  if #header_value <= #prefix then
    return false
  end
  if header_value:sub(1, #prefix) ~= prefix then
    return false
  end
  return M.secure_compare(header_value:sub(#prefix + 1), expected_token)
end

--- Canonical action name for a request path.
-- Returns action, nil for /tools/<known-action>, nil, nil for unknown path.
function M.action_for_path(path)
  local action = type(path) == "string" and path:match("^/tools/([a-z_]+)$")
  if not action then
    return nil
  end
  for _, known in ipairs(M.ACTIONS) do
    if known == action then
      return action
    end
  end
  return nil
end

return M
