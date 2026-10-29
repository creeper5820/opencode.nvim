-- Editor action for the `neovim_open` tool.
--
-- Handler contract (see lua/opencode/tools/server.lua):
--   handler(input, ctx) -> result, err
--   -- or: ctx.respond(result, err) later (used when called from a libuv
--   -- callback by the 09A tool server)
--
-- Input: { path = string, line = integer?, column = integer? }
--   * Relative paths resolve from the project root.
--   * Absolute paths are accepted only when they stay inside the project.
--   * line and column are 1-based; column is a byte column, matching
--     nvim_win_set_cursor. line defaults to 1 and column defaults to 1.
--
-- Window policy: reuse the current window when it already shows the target;
-- otherwise focus the first non-floating window (current tab first, then other
-- tabs) that shows it; otherwise replace the current non-floating window's
-- buffer. A file is never written or reloaded into an existing buffer.

local protocol = require("opencode.tools.protocol")

local uv = vim.uv or vim.loop

local M = {}

M.DEFAULT_LINE = 1
M.DEFAULT_COLUMN = 1

local function fail(code, message, details)
  return nil, protocol.error(code, message, details)
end

local function is_integer(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
end

local function valid_path_text(path)
  return type(path) == "string"
    and path ~= ""
    and not path:find("\0", 1, true)
    and not path:find("[\r\n]")
end

--- Canonical absolute path with symlinks resolved when the path exists.
local function canonicalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local expanded = vim.fn.fnamemodify(path, ":p")
  local real = uv.fs_realpath(expanded)
  local normalized = vim.fs.normalize(real or expanded)
  if #normalized > 1 then
    normalized = normalized:gsub("/+$", "")
  end
  return normalized
end

local function is_within(root, path)
  if path == root then
    return true
  end
  if root == "/" then
    return path:sub(1, 1) == "/"
  end
  return path:sub(1, #root + 1) == root .. "/"
end

local function relative_path(root, path)
  if path == root then
    return "."
  end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

local function resolve_root(value)
  if type(value) ~= "string" or value == "" then
    return nil, "project root is unavailable"
  end
  local root = canonicalize(value)
  if not root then
    return nil, "project root is unavailable"
  end
  local stat = uv.fs_stat(root)
  if stat and stat.type ~= "directory" then
    return nil, "project root is not a directory"
  end
  return root
end

local function resolve_target(input, root)
  local raw = input.path
  if not valid_path_text(raw) then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "path must be a non-empty string")
  end
  if raw:sub(1, 1) == "~" then
    return fail(
      protocol.ERROR_CODES.INVALID_REQUEST,
      "path must be relative to the project root or absolute"
    )
  end

  local target
  if raw:sub(1, 1) == "/" then
    target = raw
  else
    target = root .. "/" .. raw
  end
  target = vim.fs.normalize(target)
  if #target > 1 then
    target = target:gsub("/+$", "")
  end
  if not is_within(root, target) then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "path escapes the project root", {
      path = raw,
    })
  end

  -- Resolve symlinks so a link inside the project cannot point outside it.
  local real = uv.fs_realpath(target)
  if real then
    real = vim.fs.normalize(real)
    if #real > 1 then
      real = real:gsub("/+$", "")
    end
    if not is_within(root, real) then
      return fail(protocol.ERROR_CODES.INVALID_REQUEST, "path escapes the project root", {
        path = raw,
      })
    end
    target = real
  end

  local stat = uv.fs_stat(target)
  if not stat then
    return fail(protocol.ERROR_CODES.NOT_FOUND, "file does not exist", { path = raw })
  end
  if stat.type ~= "file" then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "path is not a regular file", {
      path = raw,
    })
  end
  return target
end

local function buffer_matches(bufnr, target)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return false
  end
  return canonicalize(name) == target
end

local function find_buffer(target)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if buffer_matches(bufnr, target) then
      return bufnr
    end
  end
  return nil
end

--- Reuse or create a buffer for `target`. Returns bufnr, reused or nil, err.
local function load_buffer(target)
  local bufnr = find_buffer(target)
  local reused = bufnr ~= nil
  if not bufnr then
    local ok, created = pcall(vim.fn.bufadd, target)
    if not ok or type(created) ~= "number" or created <= 0 then
      return fail(protocol.ERROR_CODES.ACTION_FAILED, "cannot create a buffer for the file", {
        path = target,
      })
    end
    bufnr = created
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    local loaded = pcall(vim.fn.bufload, bufnr)
    if not loaded then
      if not reused then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
      return fail(protocol.ERROR_CODES.ACTION_FAILED, "cannot load the file into a buffer", {
        path = target,
      })
    end
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    if not reused then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    return fail(protocol.ERROR_CODES.ACTION_FAILED, "cannot load the file into a buffer", {
      path = target,
    })
  end

  if not vim.bo[bufnr].buflisted then
    vim.bo[bufnr].buflisted = true
  end
  return bufnr, reused
end

local function is_floating(win)
  local ok, config = pcall(vim.api.nvim_win_get_config, win)
  return ok and config.relative ~= ""
end

local function window_shows(win, bufnr)
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr
end

local function normal_windows(wins)
  local result = {}
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and not is_floating(win) then
      result[#result + 1] = win
    end
  end
  return result
end

--- Deterministic target window selection. See the module comment.
local function choose_window(bufnr)
  local current = vim.api.nvim_get_current_win()
  if window_shows(current, bufnr) then
    return current
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local candidates = normal_windows(vim.api.nvim_tabpage_list_wins(current_tab))
  for _, win in ipairs(candidates) do
    if window_shows(win, bufnr) then
      return win
    end
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= current_tab then
      for _, win in ipairs(normal_windows(vim.api.nvim_tabpage_list_wins(tab))) do
        if window_shows(win, bufnr) then
          return win
        end
      end
    end
  end

  if not is_floating(current) then
    return current
  end
  if candidates[1] then
    return candidates[1]
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local win = normal_windows(vim.api.nvim_tabpage_list_wins(tab))[1]
    if win then
      return win
    end
  end
  return current
end

local function show_in_window(win, bufnr)
  local win_tab = vim.api.nvim_win_get_tabpage(win)
  if win_tab ~= vim.api.nvim_get_current_tabpage() then
    local switched = pcall(vim.api.nvim_set_current_tabpage, win_tab)
    if not switched then
      return fail(protocol.ERROR_CODES.ACTION_FAILED, "cannot switch to the target tab", {
        window = win,
      })
    end
  end

  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    local shown, show_err = pcall(vim.api.nvim_win_set_buf, win, bufnr)
    if not shown then
      return fail(protocol.ERROR_CODES.ACTION_FAILED, "cannot show the file in a window", {
        window = win,
        reason = tostring(show_err),
      })
    end
  end

  local focused = pcall(vim.api.nvim_set_current_win, win)
  if not focused then
    return fail(protocol.ERROR_CODES.ACTION_FAILED, "cannot focus the target window", {
      window = win,
    })
  end
  return true
end

--- Validate and normalize the optional 1-based position.
local function resolve_position(input, bufnr)
  local line = input.line
  if line == nil then
    line = M.DEFAULT_LINE
  end
  local column = input.column
  if column == nil then
    column = M.DEFAULT_COLUMN
  end
  if not is_integer(line) or line < 1 then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "line must be a positive integer", {
      line = type(line) == "number" and line or vim.NIL,
    })
  end
  if not is_integer(column) or column < 1 then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "column must be a positive integer", {
      column = type(column) == "number" and column or vim.NIL,
    })
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line > line_count then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "line is outside the file", {
      line = line,
      line_count = line_count,
    })
  end
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  if column > #text + 1 then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "column is outside the line", {
      column = column,
      line = line,
      line_length = #text,
    })
  end
  return { line = line, column = column, col = column - 1 }
end

local function set_cursor(win, line, col)
  local moved, move_err = pcall(vim.api.nvim_win_set_cursor, win, { line, col })
  if not moved then
    return fail(protocol.ERROR_CODES.ACTION_FAILED, "cannot set the cursor position", {
      line = line,
      column = col + 1,
      reason = tostring(move_err),
    })
  end
  return true
end

--- Run the action synchronously. Must be called on the main loop.
-- Returns a JSON-serializable result table or nil, protocol error.
function M.execute(input, opts)
  opts = opts or {}
  if type(input) ~= "table" or vim.islist(input) then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, "input must be an object")
  end

  local root, root_err = resolve_root(opts.project_root or vim.fn.getcwd())
  if not root then
    return fail(protocol.ERROR_CODES.INVALID_REQUEST, root_err)
  end

  local target, target_err = resolve_target(input, root)
  if not target then
    return nil, target_err
  end

  local bufnr, reused = load_buffer(target)
  if not bufnr then
    return nil, reused
  end

  local position, position_err = resolve_position(input, bufnr)
  if not position then
    return nil, position_err
  end

  local win = choose_window(bufnr)
  local shown, show_err = show_in_window(win, bufnr)
  if not shown then
    return nil, show_err
  end
  local moved, move_err = set_cursor(win, position.line, position.col)
  if not moved then
    return nil, move_err
  end

  local display = relative_path(root, target)
  local suffix = ""
  if input.line ~= nil or input.column ~= nil then
    suffix = ":" .. tostring(position.line) .. ":" .. tostring(position.column)
  end
  return {
    opened = true,
    reused = reused == true,
    path = display,
    line = position.line,
    column = position.column,
    buffer = bufnr,
    window = win,
    message = "Opened " .. display .. suffix .. " in Neovim.",
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
-- `opts.project_root` is only a fallback; `ctx.project_root` from the tool
-- server takes precedence.
function M.handler(opts)
  opts = opts or {}
  return function(input, ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local root = ctx.project_root or opts.project_root
    return dispatch(function()
      return M.execute(input, { project_root = root })
    end, ctx)
  end
end

local default_handler

--- Default handler for direct use: `handlers = { open = require(...).handle }`.
function M.handle(input, ctx)
  if not default_handler then
    default_handler = M.handler()
  end
  return default_handler(input, ctx)
end

return M
