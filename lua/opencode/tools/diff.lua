-- Native side-by-side diff for the neovim_diff tool action.
--
-- The original buffer is the target file's loaded buffer, so unsaved edits are
-- shown as they are in memory. The proposed content is displayed in a
-- read-only scratch buffer; nothing is written to disk.
--
-- Usage:
--   local diff = require("opencode.tools.diff")
--   local result, err = diff.handle({ path = "lua/foo.lua", proposed = "..." }, {
--     project_root = "/repo",
--   })
--   -- or: local handler = diff.handler({ project_root = "/repo" })
--   -- or: local result, err = diff.execute(input, { project_root = "/repo" })
--   diff.close()
--
-- Handler contract matches 09A: return a result table, or nil plus a protocol
-- error. In a fast libuv context the handler schedules the Neovim work and
-- completes asynchronously through ctx.respond.
--
-- Only one native diff view is kept at a time. Opening another target closes
-- and fully restores the previous view first. Closing either side manually
-- triggers a scheduled cleanup; close() performs the cleanup immediately.

local protocol = require("opencode.tools.protocol")

local uv = vim.uv or vim.loop

local M = {}

local MAX_PATH_BYTES = 4096

-- Options changed by `:diffthis` that must be restored on the original window.
-- `:diffoff` alone does not restore them to their previous values, so capture
-- them explicitly before entering diff mode.
local WINDOW_OPTIONS = {
  "diff",
  "scrollbind",
  "cursorbind",
  "foldmethod",
  "foldcolumn",
  "foldenable",
  "foldlevel",
  "wrap",
}

local state = {
  current = nil,
  sequence = 0,
}

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function loaded_buf(buf)
  return valid_buf(buf) and vim.api.nvim_buf_is_loaded(buf)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function canonical_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local resolved = uv.fs_realpath(path)
  if not resolved then
    -- Resolve the parent so a path in a symlinked project still matches the
    -- real path recorded for already loaded buffers.
    local parent = vim.fs.dirname(path)
    local base = vim.fs.basename(path)
    local real_parent = parent and uv.fs_realpath(parent)
    if real_parent and base and base ~= "" then
      resolved = vim.fs.joinpath(real_parent, base)
    end
  end
  if not resolved then
    resolved = vim.fn.fnamemodify(path, ":p")
  end
  resolved = vim.fs.normalize(resolved)
  if #resolved > 1 then
    resolved = resolved:gsub("/+$", "")
  end
  return resolved
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

local function protocol_error(code, message, details)
  return nil, protocol.error(code, message, details)
end

local function validate(input, ctx)
  if type(input) ~= "table" or (vim.islist(input) and next(input) ~= nil) then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "diff input must be an object")
  end

  local path = input.path
  if type(path) ~= "string" or path == "" then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "path must be a non-empty string")
  end
  if #path > MAX_PATH_BYTES then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "path is too long")
  end
  if path:find("\0", 1, true) then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "path must not contain NUL bytes")
  end
  if path:sub(1, 1) == "~" then
    return protocol_error(
      protocol.ERROR_CODES.INVALID_REQUEST,
      "path must be relative to the project root or absolute"
    )
  end

  local proposed = input.proposed
  if type(proposed) ~= "string" then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "proposed must be a string")
  end
  if proposed:find("\0", 1, true) then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "proposed must not contain NUL bytes")
  end

  if ctx ~= nil and type(ctx) ~= "table" then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "context must be an object")
  end
  local supplied_root = ctx and ctx.project_root
  if supplied_root ~= nil and (type(supplied_root) ~= "string" or supplied_root == "") then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "project_root must be a non-empty string")
  end

  local root = canonical_path(supplied_root or vim.fn.getcwd())
  if not root then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "cannot resolve project root")
  end
  local stat = uv.fs_stat(root)
  if not stat or stat.type ~= "directory" then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "project root is not a directory")
  end

  local full
  if path:sub(1, 1) == "/" then
    full = path
  else
    full = vim.fs.joinpath(root, path)
  end
  full = canonical_path(full)
  if not full then
    return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "cannot resolve path", { path = path })
  end
  if not is_within(root, full) then
    return protocol_error(
      protocol.ERROR_CODES.INVALID_REQUEST,
      "path must stay inside the project root",
      { path = path }
    )
  end

  return {
    path = full,
    proposed = proposed,
  }
end

local function find_buffer(path)
  local current = vim.api.nvim_get_current_buf()
  local loaded_match
  local fallback
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if valid_buf(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and canonical_path(name) == path then
        if buf == current then
          return buf
        end
        if loaded_buf(buf) then
          loaded_match = loaded_match or buf
        else
          fallback = fallback or buf
        end
      end
    end
  end
  return loaded_match or fallback
end

--- Return the loaded buffer for `path`, loading it from disk when necessary.
-- An already loaded buffer is always preferred so unsaved edits are kept.
local function ensure_original_buffer(path)
  local buf = find_buffer(path)
  local was_loaded = buf ~= nil and loaded_buf(buf)
  local created = false
  if not buf then
    local stat = uv.fs_stat(path)
    if not stat then
      return protocol_error(protocol.ERROR_CODES.NOT_FOUND, "file does not exist: " .. path)
    end
    if stat.type ~= "file" then
      return protocol_error(protocol.ERROR_CODES.INVALID_REQUEST, "path is not a regular file")
    end
    local ok, added = pcall(vim.fn.bufadd, path)
    if not ok or type(added) ~= "number" or added <= 0 then
      return protocol_error(protocol.ERROR_CODES.ACTION_FAILED, "cannot create buffer for " .. path)
    end
    buf = added
    created = true
  end

  if not loaded_buf(buf) then
    local ok, load_err = pcall(vim.fn.bufload, buf)
    if not ok or not loaded_buf(buf) then
      if created and valid_buf(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      return protocol_error(
        protocol.ERROR_CODES.ACTION_FAILED,
        "cannot load file: " .. tostring(load_err or path)
      )
    end
  end
  if not loaded_buf(buf) then
    if created and valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    return protocol_error(protocol.ERROR_CODES.ACTION_FAILED, "buffer is not loaded: " .. path)
  end
  return {
    buffer = buf,
    was_loaded = was_loaded,
  }
end

local function proposed_filetype(original_buf, path, was_loaded)
  local ok, filetype = pcall(function()
    return vim.bo[original_buf].filetype
  end)
  if ok and type(filetype) == "string" and (filetype ~= "" or was_loaded) then
    return filetype
  end
  local matched_ok, matched = pcall(vim.filetype.match, { filename = path })
  if matched_ok and type(matched) == "string" then
    return matched
  end
  return ""
end

-- Split content the way a file is modeled by Neovim: one trailing newline is
-- line terminator, not an extra empty line.
local function content_lines(text)
  if text == "" then
    return { "" }
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function create_proposed_buffer(proposed, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, err = pcall(function()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buflisted = false
    vim.bo[buf].swapfile = false
    vim.bo[buf].undofile = false
    vim.bo[buf].modeline = false
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines(proposed))
    if filetype ~= "" then
      pcall(function()
        vim.bo[buf].filetype = filetype
      end)
    end
    -- A FileType autocommand may have changed buffer options; the proposed
    -- buffer stays a display-only scratch regardless.
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buflisted = false
    vim.bo[buf].swapfile = false
    vim.bo[buf].undofile = false
    vim.bo[buf].modeline = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.bo[buf].modified = false
  end)
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    error(err)
  end
  return buf
end

local function capture_window_state(win)
  local options = {}
  for _, name in ipairs(WINDOW_OPTIONS) do
    local ok, value = pcall(function()
      return vim.wo[win][name]
    end)
    if ok then
      options[name] = value
    end
  end
  local view_ok, view = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.winsaveview()
  end)
  return {
    options = options,
    view = view_ok and view or nil,
  }
end

local function restore_window_state(win, saved)
  if not valid_win(win) or type(saved) ~= "table" then
    return
  end
  local options = saved.options or {}
  local want_diff = options.diff == true

  pcall(vim.api.nvim_win_call, win, function()
    if vim.wo.diff then
      vim.cmd("diffoff")
    end
    if want_diff then
      vim.cmd("diffthis")
    end
  end)

  for name, value in pairs(options) do
    if name ~= "diff" then
      pcall(function()
        vim.wo[win][name] = value
      end)
    end
  end
  pcall(function()
    vim.wo[win].diff = want_diff
  end)

  if saved.view then
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(saved.view)
    end)
  end
end

local function enable_diff(win)
  vim.api.nvim_win_call(win, function()
    vim.cmd("diffthis")
  end)
  -- Be explicit: users expect folding in the native diff view even if the
  -- current window inherited unusual options. Saved values are restored on
  -- close.
  pcall(function()
    vim.wo[win].diff = true
    vim.wo[win].scrollbind = true
    vim.wo[win].cursorbind = true
    vim.wo[win].foldmethod = "diff"
  end)
end

local function is_floating(win)
  local ok, config = pcall(vim.api.nvim_win_get_config, win)
  return ok and config.relative ~= ""
end

local function find_window_for_buffer(buf)
  local current = vim.api.nvim_get_current_win()
  local fallback
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if valid_win(win) and not is_floating(win) and vim.api.nvim_win_get_buf(win) == buf then
      if win == current then
        return win
      end
      fallback = fallback or win
    end
  end
  return fallback
end

local function close_view(view)
  if not view or view.closing then
    return true
  end
  view.closing = true
  if state.current == view then
    state.current = nil
  end
  if view.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, view.augroup)
    view.augroup = nil
  end

  local current = vim.api.nvim_get_current_win()
  local proposed_win = view.proposed_win
  local original_win = view.original_win
  local original_buf = view.original_buf

  if valid_win(proposed_win) then
    if #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, proposed_win, true)
    end
    if valid_win(proposed_win) then
      -- Closing was not possible (for example this is the last window). Show
      -- the original buffer there and restore the saved window state.
      local target_buf = valid_buf(original_buf) and original_buf or nil
      if not target_buf then
        target_buf = vim.api.nvim_create_buf(true, false)
      end
      local switched = pcall(vim.api.nvim_win_set_buf, proposed_win, target_buf)
      if switched then
        restore_window_state(proposed_win, view.saved)
        proposed_win = nil
      end
    else
      proposed_win = nil
    end
  end
  view.proposed_win = nil
  if valid_buf(view.proposed_buf) then
    pcall(vim.api.nvim_buf_delete, view.proposed_buf, { force = true })
  end
  view.proposed_buf = nil

  if view.created_original then
    if valid_win(original_win) and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, original_win, true)
    end
    -- If closing was not possible (for example it is the last window), keep
    -- the created window usable and out of diff mode.
    if valid_win(original_win) then
      restore_window_state(original_win, view.saved)
    end
  elseif valid_win(original_win) then
    restore_window_state(original_win, view.saved)
  end
  view.original_win = nil

  local current_is_view = not valid_win(current)
    or current == proposed_win
    or (view.created_original and current == original_win)
  if current_is_view then
    local target = view.focus_return
    if not valid_win(target) or target == proposed_win or (view.created_original and target == original_win) then
      target = valid_win(original_win) and original_win or nil
    end
    if valid_win(target) then
      pcall(vim.api.nvim_set_current_win, target)
    end
  end
  return true
end

local function schedule_cleanup(view)
  return function()
    if view.closing then
      return
    end
    vim.schedule(function()
      if view.closing or state.current ~= view then
        return
      end
      close_view(view)
    end)
  end
end

local function install_autocmds(view)
  state.sequence = state.sequence + 1
  local name = ("OpencodeNvimDiff_%d_%d"):format(uv.os_getpid(), state.sequence)
  local group = vim.api.nvim_create_augroup(name, { clear = true })
  view.augroup = group
  local cleanup = schedule_cleanup(view)
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = { tostring(view.original_win), tostring(view.proposed_win) },
    callback = cleanup,
    desc = "OpenCode: restore the diff view when a side is closed",
  })
  for _, buf in ipairs({ view.original_buf, view.proposed_buf }) do
    if valid_buf(buf) then
      vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        buffer = buf,
        callback = cleanup,
        desc = "OpenCode: restore the diff view when a buffer is wiped",
      })
    end
  end
end

local function open_view(req)
  local original, buf_err = ensure_original_buffer(req.path)
  if not original then
    return nil, buf_err
  end
  local original_buf = original.buffer

  local proposed_buf
  local create_ok, create_err = pcall(function()
    proposed_buf = create_proposed_buffer(
      req.proposed,
      proposed_filetype(original_buf, req.path, original.was_loaded)
    )
  end)
  if not create_ok or not valid_buf(proposed_buf) then
    return protocol_error(
      protocol.ERROR_CODES.ACTION_FAILED,
      "cannot create proposed scratch buffer: " .. tostring(create_err)
    )
  end

  -- Keep the previous view intact until a new request has been validated and
  -- its proposed buffer prepared.
  M.close()

  local focus_return = vim.api.nvim_get_current_win()
  local split_origin = focus_return
  if is_floating(split_origin) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if valid_win(win) and not is_floating(win) then
        split_origin = win
        break
      end
    end
  end
  local original_win = find_window_for_buffer(original_buf)
  local created_original = false
  if not original_win then
    local open_ok, win_or_err = pcall(vim.api.nvim_open_win, original_buf, false, {
      split = "right",
      win = split_origin,
    })
    if not open_ok or not valid_win(win_or_err) then
      pcall(vim.api.nvim_buf_delete, proposed_buf, { force = true })
      return protocol_error(
        protocol.ERROR_CODES.ACTION_FAILED,
        "cannot open the original buffer: " .. tostring(win_or_err)
      )
    end
    original_win = win_or_err
    created_original = true
  end

  local view = {
    path = req.path,
    original_buf = original_buf,
    proposed_buf = proposed_buf,
    original_win = original_win,
    proposed_win = nil,
    created_original = created_original,
    focus_return = focus_return,
    saved = capture_window_state(original_win),
    closing = false,
    augroup = nil,
  }
  state.current = view

  local setup_ok, setup_err = pcall(function()
    local proposed_win = vim.api.nvim_open_win(proposed_buf, true, {
      split = "right",
      win = original_win,
    })
    view.proposed_win = proposed_win
    enable_diff(original_win)
    enable_diff(proposed_win)
    install_autocmds(view)
  end)
  if not setup_ok then
    close_view(view)
    return protocol_error(
      protocol.ERROR_CODES.ACTION_FAILED,
      "cannot open the diff view: " .. tostring(setup_err)
    )
  end

  return {
    path = req.path,
    original_buffer = original_buf,
    proposed_buffer = proposed_buf,
    original_window = view.original_win,
    proposed_window = view.proposed_win,
    created_original_window = view.created_original,
    message = "Showed " .. req.path .. " as a diff in Neovim. Nothing was written to disk.",
  }
end

--- Run the action synchronously. Must be called on the main loop.
-- Returns a JSON-serializable result table or nil, protocol error.
function M.execute(input, opts)
  opts = type(opts) == "table" and opts or {}
  local req, err = validate(input, { project_root = opts.project_root })
  if not req then
    return nil, err
  end
  return open_view(req)
end

local function dispatch(input, opts, ctx)
  local respond = type(ctx.respond) == "function" and ctx.respond or nil
  local function run()
    local ok, result, err = pcall(M.execute, input, opts)
    if not ok then
      return protocol_error(
        protocol.ERROR_CODES.INTERNAL_ERROR,
        "diff action failed: " .. tostring(result)
      )
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
-- `opts.project_root` is a fallback; `ctx.project_root` from the tool server
-- takes precedence.
function M.handler(opts)
  opts = type(opts) == "table" and opts or {}
  return function(input, ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local root = ctx.project_root or opts.project_root
    return dispatch(input, { project_root = root }, ctx)
  end
end

local default_handler

--- Default handler for direct use: `handlers = { diff = require(...).handle }`.
function M.handle(input, ctx)
  if not default_handler then
    default_handler = M.handler()
  end
  return default_handler(input, ctx)
end

--- Close the native diff view and restore the original window. Idempotent.
-- Safe when the user has already closed either side.
function M.close()
  if vim.in_fast_event() then
    vim.schedule(M.close)
    return true
  end
  local view = state.current
  if view then
    close_view(view)
  end
  return true
end

function M.is_open()
  local view = state.current
  return view ~= nil
    and not view.closing
    and valid_win(view.original_win)
    and valid_win(view.proposed_win)
end

--- Introspection for tests and integrations. Returns nil when no view exists.
function M.get_view()
  local view = state.current
  if not view then
    return nil
  end
  return {
    path = view.path,
    original_buf = view.original_buf,
    proposed_buf = view.proposed_buf,
    original_win = valid_win(view.original_win) and view.original_win or nil,
    proposed_win = valid_win(view.proposed_win) and view.proposed_win or nil,
    created_original = view.created_original,
  }
end

return M
