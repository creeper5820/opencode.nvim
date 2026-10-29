-- Public facade for the embedded official OpenCode TUI.
--
-- The plugin is only a terminal host.  OpenCode owns the renderer, composer,
-- dialogs, keybindings, leader handling, Alt keys, selection and viewport.
-- Neovim keeps the terminal window in Terminal mode while it is focused; there
-- is no second input router, logical focus region or Normal-mode translation.

local config = require("opencode.config")
local terminal_module = require("opencode.terminal")
local selection = require("opencode.actions.selection")

local M = {}

local resolved = nil
local runtime = nil

local KEYMAP_DESC = {
  toggle = "OpenCode: toggle TUI",
  send_selection = "OpenCode: send selection to composer",
  question_selection = "OpenCode: ask about selection",
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  return vim.deepcopy(value)
end

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function notify(message, level)
  pcall(vim.notify, message, level or vim.log.levels.INFO)
end

local function error_message(err)
  if type(err) == "table" then
    return type(err.message) == "string" and err.message or tostring(err.code or err)
  end
  return tostring(err)
end

local function terminal_is_current(rt)
  return rt.terminal:is_open()
    and valid_win(rt.terminal.state.win)
    and vim.api.nvim_get_current_win() == rt.terminal.state.win
    and valid_buf(rt.terminal.state.buf)
    and vim.api.nvim_get_current_buf() == rt.terminal.state.buf
end

--- Keep global Terminal-mode mappings from stealing keys from the embedded TUI.
--- Each global Term-mode mapping is shadowed in the OpenCode buffer by a raw
--- byte forward of its own lhs.  This is still plain pass-through: there is no
--- Normal routing, command matching or state machine.
local function install_terminal_passthrough(rt)
  local buf = rt.terminal.state.buf
  if not valid_buf(buf) or rt.passthrough_buf == buf then
    return
  end
  rt.passthrough_buf = buf
  local ok, maps = pcall(vim.api.nvim_get_keymap, "t")
  if not ok or type(maps) ~= "table" then
    return
  end
  for _, map in ipairs(maps) do
    if type(map.lhs) == "string" and map.lhs ~= "" then
      local bytes_ok, bytes = pcall(vim.api.nvim_replace_termcodes, map.lhs, true, false, true)
      if bytes_ok and type(bytes) == "string" and bytes ~= "" then
        pcall(vim.keymap.set, "t", map.lhs, function()
          rt.terminal:send(bytes)
        end, {
          buffer = buf,
          silent = true,
          nowait = true,
          noremap = true,
          desc = "OpenCode: pass through " .. map.lhs,
        })
      end
    end
  end
end

--- Keep the focused OpenCode window in Terminal mode.  The TUI receives every
--- key directly; no Normal-mode operation routing is installed.
local function enter_terminal_mode(rt)
  if not rt or runtime ~= rt or not terminal_is_current(rt) or not rt.terminal:is_running() then
    return false
  end
  if rt.restoring_terminal then
    return true
  end
  rt.restoring_terminal = true
  local ok = pcall(vim.cmd, "startinsert")
  rt.restoring_terminal = false
  return ok
end

local function install_keymap(rt, mode, lhs, callback, desc)
  if lhs == false or lhs == nil or lhs == "" then
    return
  end
  local ok = pcall(vim.keymap.set, mode, lhs, callback, {
    silent = true,
    desc = desc,
  })
  if ok then
    rt.mappings[#rt.mappings + 1] = { mode = mode, lhs = lhs, desc = desc }
  end
end

local function install_keymaps(rt)
  local keymaps = rt.config.keymaps or {}
  install_keymap(rt, "n", keymaps.toggle, function()
    M.toggle()
  end, KEYMAP_DESC.toggle)
  install_keymap(rt, "x", keymaps.send_selection, function()
    selection.send_selection()
  end, KEYMAP_DESC.send_selection)
  install_keymap(rt, "x", keymaps.question_selection, function()
    selection.question_selection()
  end, KEYMAP_DESC.question_selection)
end

local function uninstall_keymaps(rt)
  for _, mapping in ipairs(rt.mappings or {}) do
    local current = vim.fn.maparg(mapping.lhs, mapping.mode, false, true)
    if type(current) == "table" and current.desc == mapping.desc then
      pcall(vim.keymap.del, mapping.mode, mapping.lhs)
    end
  end
  rt.mappings = {}
end

local function install_commands(rt)
  local function command(name, fn, opts)
    opts = opts or {}
    opts.force = true
    pcall(vim.api.nvim_create_user_command, name, fn, opts)
  end
  local function words(value)
    return vim.split(vim.trim(value or ""), "%s+", { trimempty = true })
  end
  command("OpenCode", function(args)
    local parts = words(args.args)
    local sub = parts[1] or "toggle"
    if sub == "toggle" then
      M.toggle()
    elseif sub == "open" then
      M.open({ directory = parts[2] })
    elseif sub == "close" then
      M.close()
    elseif sub == "stop" then
      M.stop()
    elseif sub == "restart" then
      M.restart({ directory = parts[2] })
    elseif sub == "continue" then
      M.open({ directory = parts[2], continue = true })
    elseif sub == "session" then
      if not parts[2] then
        notify("OpenCode: session requires a session id", vim.log.levels.WARN)
      else
        M.open({ directory = parts[3], session = parts[2] })
      end
    elseif sub == "new" then
      M.open({ directory = parts[2], session = false, continue = false })
    elseif sub == "submit" then
      M.submit()
    elseif sub == "health" then
      M.print_health()
    else
      notify("OpenCode: unknown subcommand: " .. sub, vim.log.levels.WARN)
    end
  end, {
    nargs = "*",
    complete = function()
      return { "toggle", "open", "close", "stop", "restart", "continue", "session", "new", "submit", "health" }
    end,
    desc = "OpenCode TUI",
  })
  command("OpenCodeToggle", function()
    M.toggle()
  end, { desc = "Toggle the OpenCode TUI" })
  command("OpenCodeOpen", function(args)
    M.open({ directory = words(args.args)[1] })
  end, { nargs = "?", desc = "Open the OpenCode TUI" })
  command("OpenCodeClose", function()
    M.close()
  end, { desc = "Hide the OpenCode TUI" })
  command("OpenCodeStop", function()
    M.stop()
  end, { desc = "Stop the OpenCode TUI process" })
  command("OpenCodeContinue", function(args)
    M.open({ directory = words(args.args)[1], continue = true })
  end, { nargs = "?", desc = "Open the OpenCode TUI and continue the last session" })
  command("OpenCodeSession", function(args)
    local parts = words(args.args)
    if not parts[1] then
      notify("OpenCode: OpenCodeSession requires a session id", vim.log.levels.WARN)
      return
    end
    M.open({ session = parts[1], directory = parts[2] })
  end, { nargs = "+", desc = "Open the OpenCode TUI for a session id" })
  command("OpenCodeSubmit", function()
    M.submit()
  end, { desc = "Submit the OpenCode composer" })
  command("OpenCodeHealth", function()
    M.print_health()
  end, { desc = "Show OpenCode health information" })
  rt.commands = {
    "OpenCode",
    "OpenCodeToggle",
    "OpenCodeOpen",
    "OpenCodeClose",
    "OpenCodeStop",
    "OpenCodeContinue",
    "OpenCodeSession",
    "OpenCodeSubmit",
    "OpenCodeHealth",
  }
end

local function install_terminal_autocmds(rt)
  local group = vim.api.nvim_create_augroup("OpencodeNvimTerminalMode", { clear = true })
  rt.augroup = group

  local function enforce()
    if runtime ~= rt then
      return
    end
    if terminal_is_current(rt) then
      enter_terminal_mode(rt)
    end
  end

  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = enforce,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      if runtime ~= rt then
        return
      end
      if not terminal_is_current(rt) then
        return
      end
      local mode = vim.api.nvim_get_mode().mode
      if mode ~= "t" then
        vim.schedule(function()
          enforce()
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if runtime ~= rt then
        return
      end
      rt.terminal:stop({ timeout = 1000 })
    end,
  })
end

local function new_runtime(cfg)
  local rt = {
    config = cfg,
    mappings = {},
  }
  rt.terminal = terminal_module.new({
    config = cfg,
    notify = notify,
    on_exit = function(code)
      if runtime ~= rt then
        return
      end
      rt.last_exit = code
    end,
  })
  return rt
end

local function teardown_runtime()
  local rt = runtime
  runtime = nil
  if not rt then
    return
  end
  pcall(selection._reset)
  if rt.terminal then
    pcall(rt.terminal.stop, rt.terminal)
  end
  uninstall_keymaps(rt)
  if rt.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, rt.augroup)
  end
end

--- Configure the plugin.  Safe to call repeatedly; the previous terminal
--- process, keymaps and autocmds are replaced.
--- @param opts table|nil
--- @return table resolved configuration
function M.setup(opts)
  local was_open = runtime ~= nil and runtime.terminal:is_open()
  teardown_runtime()
  resolved = config.resolve(opts)
  local rt = new_runtime(resolved)
  runtime = rt

  local function selection_channel()
    if runtime ~= rt then
      return nil
    end
    if not rt.terminal:is_running() then
      local ok = M.open({ focus = false })
      if not ok then
        return nil
      end
    end
    return rt.terminal:channel()
  end

  selection.setup({
    channel = selection_channel,
    focus_input = function()
      return M.focus()
    end,
    open = function()
      return M.open()
    end,
    notify = notify,
  })

  install_keymaps(rt)
  install_commands(rt)
  install_terminal_autocmds(rt)

  if was_open then
    M.open()
  end
  return resolved
end

--- Return the resolved configuration, using defaults on first use.
--- @return table
function M.get_config()
  if resolved == nil then
    resolved = config.resolve(nil)
  end
  return resolved
end

local function ensure_runtime()
  if runtime == nil then
    M.setup(nil)
  end
  return runtime
end

--- Enter Terminal mode in the OpenCode window if it is currently focused.
--- @return boolean ok
function M.focus()
  local rt = ensure_runtime()
  if not rt.terminal:is_running() then
    local opened, err = M.open()
    if not opened then
      return false, err
    end
  else
    local focused, err = rt.terminal:focus()
    if not focused then
      return false, err
    end
  end
  install_terminal_passthrough(rt)
  enter_terminal_mode(rt)
  return true
end

--- Open (or reveal) the embedded official TUI.
--- @param opts table|nil { directory, session, continue, prompt, args, focus }
--- @return boolean ok
--- @return string|nil error
function M.open(opts)
  local rt = ensure_runtime()
  local ok, err = rt.terminal:open(opts)
  if not ok then
    notify("OpenCode: " .. error_message(err), vim.log.levels.ERROR)
    return false, err
  end
  if opts and opts.focus == false then
    return true
  end
  local focused, focus_error = rt.terminal:focus()
  if not focused then
    notify("OpenCode: " .. error_message(focus_error), vim.log.levels.ERROR)
    return false, focus_error
  end
  install_terminal_passthrough(rt)
  enter_terminal_mode(rt)
  return true
end

--- Hide the TUI window while keeping the OpenCode process alive.
function M.close()
  if runtime then
    runtime.terminal:close()
  end
  return true
end

--- Open or hide the TUI.
function M.toggle(opts)
  local rt = ensure_runtime()
  if rt.terminal:is_open() then
    return M.close()
  end
  return M.open(opts)
end

--- @return boolean
function M.is_open()
  return runtime ~= nil and runtime.terminal:is_open()
end

--- @return boolean
function M.is_running()
  return runtime ~= nil and runtime.terminal:is_running()
end

--- Stop the OpenCode process owned by this plugin.  Keeps commands/keymaps
--- installed; the next open() starts a fresh TUI.
function M.stop()
  if runtime then
    runtime.terminal:stop()
  end
  return true
end

--- Restart with optional new per-open flags.
function M.restart(opts)
  local rt = ensure_runtime()
  rt.terminal:stop()
  return M.open(opts)
end

--- Live terminal channel, or nil when the TUI is not running.
--- @return table|nil
function M.channel()
  if runtime == nil then
    return nil
  end
  return runtime.terminal:channel()
end

--- Send raw PTY bytes.
function M.send(data)
  local rt = ensure_runtime()
  return rt.terminal:send(data)
end

--- Send a key sequence written in Neovim notation.
function M.feed(keys)
  if type(keys) ~= "string" then
    return false, "keys must be a string"
  end
  local ok, bytes = pcall(vim.api.nvim_replace_termcodes, keys, true, false, true)
  if not ok then
    return false, tostring(bytes)
  end
  return M.send(bytes)
end

--- Paste text through the terminal channel (never submits).
function M.paste(text, opts)
  local rt = ensure_runtime()
  return rt.terminal:paste(text, opts)
end

--- Send a separate Enter/Submit event to the TUI composer.
function M.submit()
  local rt = ensure_runtime()
  if not rt.terminal:is_running() then
    notify("OpenCode: terminal is not running", vim.log.levels.WARN)
    return false
  end
  return rt.terminal:submit()
end

function M.send_selection(opts)
  return selection.send_selection(opts)
end

function M.question_selection(opts)
  return selection.question_selection(opts)
end

--- Return a test-friendly snapshot of the assembled runtime.
--- @return table
function M.get_state()
  if runtime == nil then
    return { configured = false, config = resolved }
  end
  local rt = runtime
  return {
    configured = true,
    config = copy(rt.config),
    terminal = rt.terminal:get_state(),
    last_exit = rt.last_exit,
    selection = selection.get_question_state(),
  }
end

--- @return table[] { level, message }
function M.health()
  return require("opencode.health").collect(runtime)
end

--- Print M.health() to the command line.
function M.print_health()
  for _, item in ipairs(M.health()) do
    local line = ("[opencode] %s: %s"):format(item.level, item.message)
    if item.level == "error" then
      vim.api.nvim_err_writeln(line)
    else
      vim.api.nvim_out_write(line .. "\n")
    end
  end
end

--- @return table|nil
function M.get_terminal()
  return runtime and runtime.terminal or nil
end

return M
