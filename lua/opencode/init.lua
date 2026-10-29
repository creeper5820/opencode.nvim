-- Public facade for the embedded official OpenCode TUI.
--
-- The plugin is a terminal host, not a chat client.  `opencode` draws the
-- session, composer and viewport; this module owns the process lifecycle,
-- buffer-local input routing, logical focus/region state, and selection
-- actions.  There is no HTTP client, session store, block renderer, completion
-- source or dual-buffer chat UI.

local config = require("opencode.config")
local focus_module = require("opencode.focus")
local router_module = require("opencode.router")
local terminal_module = require("opencode.terminal")
local keybindings = require("opencode.keybindings")
local primitives = require("opencode.primitives")
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

local function resolve_keybindings(cfg)
  if cfg.keybindings.enabled == false then
    return {
      bindings = {},
      diagnostics = {
        { level = "info", code = "keybindings_disabled", message = "OpenCode keybindings are disabled" },
      },
      leader = nil,
      leader_timeout = nil,
      sequence_timeout = 0,
      cli = { path = cfg.keybindings.cli_path, loaded = false },
    }
  end
  local opts = {
    read_cli = cfg.keybindings.read_cli,
    overrides = cfg.keybindings.overrides,
    sequence_timeout = cfg.keybindings.sequence_timeout,
  }
  if cfg.keybindings.cli_path ~= nil then
    opts.cli_path = cfg.keybindings.cli_path
  end
  return keybindings.resolve(opts)
end

local function apply_focus_mode(rt)
  if not rt.terminal:is_open() then
    return
  end
  if rt.focus:get() == "composer" then
    if rt.config.window.start_insert ~= false then
      pcall(vim.cmd, "startinsert")
    end
  else
    pcall(vim.cmd, "stopinsert")
  end
end

local function ensure_router(rt)
  if not rt.terminal:is_running() then
    return
  end
  local buf = rt.terminal.state.buf
  if not valid_buf(buf) then
    return
  end
  if rt.router.attached and rt.router.buf == buf then
    return
  end
  local ok, err = rt.router:attach(buf)
  if not ok then
    rt.input_error = { code = "router_attach_failed", message = err }
  else
    rt.input_error = nil
  end
end

local function new_runtime(cfg)
  local focus = focus_module.new({ initial = cfg.focus.initial })
  local rt = {
    config = cfg,
    focus = focus,
    keybindings = resolve_keybindings(cfg),
    mappings = {},
  }

  rt.terminal = terminal_module.new({
    config = cfg,
    notify = notify,
    on_exit = function(code)
      if runtime ~= rt then
        return
      end
      rt.router:detach()
      rt.last_exit = code
    end,
  })

  rt.router = router_module.new({
    focus = focus,
    channel = function()
      return rt.terminal:channel()
    end,
    keybindings = rt.keybindings,
    config = cfg,
    notify = notify,
    on_focus = function(region)
      if runtime ~= rt then
        return
      end
      if region == "composer" then
        if cfg.window.start_insert ~= false then
          pcall(vim.cmd, "startinsert")
        end
      else
        pcall(vim.cmd, "stopinsert")
      end
    end,
  })
  return rt
end

-- ---------------------------------------------------------------------------
-- Keymaps / commands / autocmds
-- ---------------------------------------------------------------------------

local function uninstall_keymaps(rt)
  for _, mapping in ipairs(rt.mappings or {}) do
    local current = vim.fn.maparg(mapping.lhs, mapping.mode, false, true)
    if type(current) == "table" and current.desc == mapping.desc then
      pcall(vim.keymap.del, mapping.mode, mapping.lhs)
    end
  end
  rt.mappings = {}
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
    elseif sub == "focus-input" then
      M.focus_input()
    elseif sub == "focus-session" then
      M.focus_session()
    elseif sub == "focus-next" then
      M.focus_next()
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
      return { "toggle", "open", "close", "stop", "restart", "continue", "session", "new", "focus-input", "focus-session", "focus-next", "submit", "health" }
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
  command("OpenCodeFocusInput", function()
    M.focus_input()
  end, { desc = "Focus the OpenCode composer region" })
  command("OpenCodeFocusSession", function()
    M.focus_session()
  end, { desc = "Focus the OpenCode session region" })
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
    "OpenCodeFocusInput",
    "OpenCodeFocusSession",
    "OpenCodeHealth",
  }
end

local function install_autocmds(rt)
  local group = vim.api.nvim_create_augroup("OpencodeNvimIntegration", { clear = true })
  rt.augroup = group
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      if runtime ~= rt then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win == rt.terminal.state.win then
        rt.focus:leave()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if runtime ~= rt then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win == rt.terminal.state.win then
        rt.focus:enter()
        ensure_router(rt)
        apply_focus_mode(rt)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if runtime ~= rt then
        return
      end
      rt.router:detach()
      rt.terminal:stop({ timeout = 1000 })
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Runtime lifecycle
-- ---------------------------------------------------------------------------

local function teardown_runtime()
  local rt = runtime
  runtime = nil
  if not rt then
    return
  end
  pcall(selection._reset)
  if rt.router then
    pcall(rt.router.detach, rt.router)
  end
  if rt.terminal then
    pcall(rt.terminal.stop, rt.terminal)
  end
  uninstall_keymaps(rt)
  if rt.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, rt.augroup)
  end
end

--- Configure the plugin.  Safe to call repeatedly; the previous terminal
--- process, buffer-local mappings and autocmds are replaced.
--- @param opts table|nil
--- @return table resolved configuration
function M.setup(opts)
  local was_open = runtime ~= nil and runtime.terminal:is_open()
  teardown_runtime()
  resolved = config.resolve(opts)
  local rt = new_runtime(resolved)
  runtime = rt

  selection.setup({
    channel = function()
      return rt.terminal:channel()
    end,
    focus_input = function()
      M.focus_input({ open = false })
    end,
    open = function()
      M.open()
    end,
    notify = notify,
  })

  install_keymaps(rt)
  install_commands(rt)
  install_autocmds(rt)

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
  ensure_router(rt)
  if opts and opts.focus == false then
    return true
  end
  rt.focus:enter()
  apply_focus_mode(rt)
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
    runtime.router:detach()
    runtime.terminal:stop()
  end
  return true
end

--- Restart with optional new per-open flags.
function M.restart(opts)
  local rt = ensure_runtime()
  rt.router:detach()
  rt.terminal:stop()
  return M.open(opts)
end

local function focus_region(region, opts)
  opts = opts or {}
  local rt = ensure_runtime()
  if not rt.terminal:is_running() then
    local ok = M.open(opts)
    if not ok then
      return false
    end
  elseif not rt.terminal:is_open() then
    local ok, err = rt.terminal:focus()
    if not ok then
      notify("OpenCode: " .. error_message(err), vim.log.levels.ERROR)
      return false
    end
  end
  local ok, err = rt.focus:set(region, "explicit")
  if not ok then
    notify("OpenCode: " .. error_message(err), vim.log.levels.ERROR)
    return false
  end
  local focused, focus_error = rt.terminal:focus()
  if not focused then
    notify("OpenCode: " .. error_message(focus_error), vim.log.levels.ERROR)
    return false
  end
  ensure_router(rt)
  if region == "composer" then
    if opts.insert ~= false and rt.config.window.start_insert ~= false then
      pcall(vim.cmd, "startinsert")
    end
  else
    pcall(vim.cmd, "stopinsert")
  end
  return true
end

--- Explicitly focus the logical composer region.
--- @param opts table|nil { insert = boolean }
function M.focus_input(opts)
  return focus_region("composer", opts)
end

--- Explicitly focus the logical session region.
function M.focus_session(opts)
  return focus_region("session", opts)
end

--- Switch logical regions without inspecting cursor movement or screen rows.
function M.focus_next()
  local rt = ensure_runtime()
  local region = rt.focus:toggle()
  if region == "composer" then
    return M.focus_input({ open = false })
  end
  return M.focus_session({ open = false })
end

--- @return "composer"|"session"|nil
function M.get_focus()
  if runtime == nil then
    return nil
  end
  return runtime.focus:get()
end

--- @return table|nil
function M.get_focus_state()
  if runtime == nil then
    return nil
  end
  return runtime.focus:state()
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

--- Execute a public composer/session primitive.  Count is forwarded to the
--- TUI input operation, and the logical focus region never changes.
--- @param name string
--- @param count number|nil
--- @return boolean ok
--- @return string|nil error
function M.primitive(name, count)
  local rt = ensure_runtime()
  return primitives.apply(name, count, {
    channel = rt.terminal:channel(),
    focus = rt.focus,
    keybindings = rt.keybindings,
  })
end

--- Install a user Normal-mode keymap that invokes a public primitive.  Counts
--- typed before the key are forwarded via vim.v.count1.
--- @param lhs string
--- @param name string
--- @param opts table|nil { count = boolean, desc = string }
function M.map_primitive(lhs, name, opts)
  local rt = ensure_runtime()
  if not rt.terminal:is_running() then
    local ok = M.open()
    if not ok then
      return false, "cannot open OpenCode terminal"
    end
  end
  ensure_router(rt)
  return rt.router:map_primitive(lhs, name, opts)
end

function M.unmap_primitive(lhs)
  local rt = ensure_runtime()
  return rt.router:unmap(lhs)
end

--- Re-read the effective cli.json and rebuild buffer-local native shortcuts.
function M.reload()
  local rt = ensure_runtime()
  rt.router:detach()
  rt.keybindings = resolve_keybindings(rt.config)
  rt.router.keybindings = rt.keybindings
  ensure_router(rt)
  return rt.keybindings
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
    focus = rt.focus:state(),
    keybindings = {
      leader = rt.keybindings.leader,
      leader_timeout = rt.keybindings.leader_timeout,
      cli = copy(rt.keybindings.cli),
      diagnostics = copy(rt.keybindings.diagnostics),
    },
    router = rt.router:get_state(),
    input_error = copy(rt.input_error),
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

M.primitives = primitives

return M
