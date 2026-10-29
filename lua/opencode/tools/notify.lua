-- Editor action for the `neovim_notify` tool.
--
-- Handler contract (see lua/opencode/tools/server.lua):
--   handler(input, ctx) -> result, err
--   -- or: ctx.respond(result, err) later (used when called from a libuv
--   -- callback by the 09A tool server)
--
-- Input: { message = string, level = "info"|"warn"|"error"? }
-- Messages must be non-empty and at most MAX_MESSAGE_BYTES bytes. The level
-- defaults to "info". The result never contains the request token or the
-- original message text.

local protocol = require("opencode.tools.protocol")

local M = {}

M.DEFAULT_LEVEL = "info"
M.MAX_MESSAGE_BYTES = 4096

local LEVELS = {
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

local function fail(code, message, details)
  return nil, protocol.error(code, message, details)
end

local function normalize_level(value)
  if value == nil then
    return M.DEFAULT_LEVEL
  end
  if type(value) == "string" and LEVELS[value] then
    return value
  end
  return nil
end

--- Run the action synchronously. Must be called on the main loop.
-- Returns a JSON-serializable result table or nil, protocol error.
function M.execute(input, opts)
  opts = opts or {}
  if type(input) ~= "table" or vim.islist(input) then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "input must be an object")
  end

  local message = input.message
  if type(message) ~= "string" or message:match("^%s*$") then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "message must be a non-empty string")
  end
  local max_bytes = opts.max_message_bytes or M.MAX_MESSAGE_BYTES
  if type(max_bytes) ~= "number" or max_bytes < 1 or max_bytes % 1 ~= 0 then
    max_bytes = M.MAX_MESSAGE_BYTES
  end
  if #message > max_bytes then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "message is too large", {
      max_bytes = max_bytes,
      actual_bytes = #message,
    })
  end

  local level = normalize_level(input.level)
  if not level then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "level must be info, warn or error")
  end

  local notify = opts.notify or vim.notify
  if type(notify) ~= "function" then
    return fail(protocol.ERROR_CODES.INTERNAL_ERROR, "notification API is unavailable")
  end
  local ok, notify_err = pcall(notify, message, LEVELS[level])
  if not ok then
    return fail(protocol.ERROR_CODES.ACTION_FAILED, "cannot show the notification", {
      reason = tostring(notify_err),
    })
  end

  return {
    notified = true,
    level = level,
    message = "Sent a " .. level .. " notification to Neovim.",
  }
end

local function dispatch(execute, ctx)
  local respond = type(ctx.respond) == "function" and ctx.respond or nil
  local function run()
    local ok, result, err = pcall(execute)
    if not ok then
      return fail(protocol.ERROR_CODES.INTERNAL_ERROR, "action failed")
    end
    return result, err
  end

  if vim.in_fast_event() then
    vim.schedule(function()
      local result, err = run()
      if respond then
        respond(result, err)
      end
    end)
    return nil, nil
  end

  local result, err = run()
  if respond then
    return respond(result, err)
  end
  return result, err
end

--- Create a 09A-compatible handler.
-- `opts.notify` can replace vim.notify; `opts.max_message_bytes` changes the
-- message size limit (tests and embedding only).
function M.handler(opts)
  opts = opts or {}
  return function(input, ctx)
    ctx = type(ctx) == "table" and ctx or {}
    return dispatch(function()
      return M.execute(input, {
        notify = opts.notify,
        max_message_bytes = opts.max_message_bytes,
      })
    end, ctx)
  end
end

local default_handler

--- Default handler for direct use: `handlers = { notify = require(...).handle }`.
function M.handle(input, ctx)
  if not default_handler then
    default_handler = M.handler()
  end
  return default_handler(input, ctx)
end

return M
