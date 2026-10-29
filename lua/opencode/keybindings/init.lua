-- OpenCode semantic keybindings.
--
-- Maps OpenCode V2 `cli.json` command IDs to buffer-local Neovim actions.
-- Raw terminal keys are never forwarded to a TUI and no global on_key hook is
-- installed.  The first supported command is `session.interrupt`.
--
-- Public API:
--
--   local keybindings = require("opencode.keybindings")
--   local resolved = keybindings.resolve({ cli_config = ..., overrides = ... })
--   keybindings.attach(buffer, {
--     actions = { ["session.interrupt"] = function() ... end },
--     cli_config = ..., overrides = ...,
--   })
--   keybindings.detach(buffer)
--
-- `attach` is buffer-local and idempotent: attaching the same buffer again
-- replaces its old mappings and closes any pending sequence timer.
--
-- Mode policy: `session.interrupt` is registered in Normal mode only.  The
-- first <Esc> in Insert mode is left entirely to Neovim (it exits Insert), and
-- Visual mode is not mapped so a selection is never destroyed by an
-- interrupt.  Only buffers explicitly passed to attach() are touched.

local key = require("opencode.keybindings.key")

local M = {}

M.supported = {
  ["session.interrupt"] = true,
}

M.command_modes = {
  ["session.interrupt"] = { "n" },
}

M.defaults = {
  leader = "ctrl+x",
  ["session.interrupt"] = "escape",
}

local DEFAULT_LEADER_TIMEOUT = 2000
local DEFAULT_SEQUENCE_TIMEOUT = 1000
local MAPPING_DESC_PREFIX = "OpenCode: "
local ALLOWED_MODES = {
  n = true,
  i = true,
  x = true,
  v = true,
  o = true,
  t = true,
}
local CONTROL_OVERRIDE_KEYS = {
  keybinds = true,
  leader = true,
  timeout = true,
  sequence_timeout = true,
  leader_timeout = true,
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  return vim.deepcopy(value)
end

local function add_diagnostic(list, level, code, message, extra)
  local item = {
    level = level,
    code = code,
    message = message,
  }
  if type(extra) == "table" then
    for name, value in pairs(extra) do
      item[name] = value
    end
  end
  list[#list + 1] = item
  return item
end

local function valid_timeout(value)
  return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function is_json_array(value)
  return type(value) == "table" and next(value) ~= nil and vim.islist(value)
end

--- Default global OpenCode CLI configuration path.
--- @return string
function M.default_path()
  local config_dir = vim.env.OPENCODE_CONFIG_DIR
  if type(config_dir) == "string" and config_dir ~= "" then
    return config_dir:gsub("/+$", "") .. "/cli.json"
  end

  local xdg = vim.env.XDG_CONFIG_HOME
  if type(xdg) ~= "string" or xdg == "" then
    local home = vim.env.HOME
    if type(home) ~= "string" or home == "" then
      home = vim.fn.expand("~")
    end
    xdg = home .. "/.config"
  end
  return xdg:gsub("/+$", "") .. "/opencode/cli.json"
end

local function read_cli_config(path, diagnostics)
  path = path or M.default_path()
  local readable = vim.fn.filereadable(path) == 1
  if not readable then
    return {}, { path = path, loaded = false }
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    add_diagnostic(diagnostics, "warn", "cli_config_unreadable",
      ("cannot read OpenCode CLI configuration %s: %s"):format(path, tostring(lines)),
      { path = path })
    return {}, { path = path, loaded = false }
  end

  local text = table.concat(lines, "\n")
  local decoded_ok, decoded = pcall(vim.json.decode, text)
  if not decoded_ok then
    add_diagnostic(diagnostics, "warn", "cli_config_invalid",
      ("cannot parse OpenCode CLI configuration %s: %s"):format(path, tostring(decoded)),
      { path = path })
    return {}, { path = path, loaded = false }
  end
  if type(decoded) ~= "table" or is_json_array(decoded) then
    add_diagnostic(diagnostics, "warn", "cli_config_invalid",
      ("OpenCode CLI configuration %s must contain a JSON object"):format(path),
      { path = path })
    return {}, { path = path, loaded = false }
  end
  return decoded, { path = path, loaded = true }
end

local function override_keybinds(overrides)
  if type(overrides) ~= "table" then
    return nil
  end
  if type(overrides.keybinds) == "table" then
    return overrides.keybinds
  end
  return overrides
end

local function is_control_override_key(name)
  return type(name) == "string" and CONTROL_OVERRIDE_KEYS[name] == true
end

local function is_leader_timing_only(value)
  return type(value) == "table"
    and value.key == nil
    and value.name == nil
    and value.timeout ~= nil
end

local function parse_leader(overrides, cli_keybinds, diagnostics)
  local value = M.defaults.leader
  local source = "default"

  if cli_keybinds ~= nil and rawget(cli_keybinds, "leader") ~= nil then
    value = cli_keybinds.leader
    source = "cli"
  end

  if type(overrides) == "table" then
    local keybinds = override_keybinds(overrides)
    local candidate = nil
    if type(keybinds) == "table" and rawget(keybinds, "leader") ~= nil then
      candidate = keybinds.leader
    elseif rawget(overrides, "leader") ~= nil then
      candidate = overrides.leader
    end
    if candidate ~= nil and not is_leader_timing_only(candidate) then
      value = candidate
      source = "override"
    end
  end

  if value == false or (type(value) == "string" and value:lower() == "none") then
    return nil, nil, source, diagnostics
  end

  local ok, strokes, parse_diagnostics = pcall(key.parse_leader, value, {})
  if not ok then
    add_diagnostic(diagnostics, "warn", "invalid_leader",
      ("cannot parse OpenCode leader %q: %s"):format(tostring(value), tostring(strokes)),
      { source = source })
  elseif parse_diagnostics then
    for _, item in ipairs(parse_diagnostics) do
      item.command = "leader"
      item.source = source
      diagnostics[#diagnostics + 1] = item
    end
  end

  if not ok or not strokes then
    if source ~= "default" then
      local default_ok, default_strokes, default_diagnostics = pcall(key.parse_leader, M.defaults.leader, {})
      if default_ok and default_strokes then
        add_diagnostic(diagnostics, "info", "leader_fallback",
          ("using the default OpenCode leader %q"):format(M.defaults.leader),
          { source = source })
        return default_strokes, key.to_lhs(default_strokes), "default", diagnostics
      end
      if default_diagnostics then
        for _, item in ipairs(default_diagnostics) do
          diagnostics[#diagnostics + 1] = item
        end
      end
    end
    return nil, nil, source, diagnostics
  end

  return strokes, key.to_lhs(strokes), source, diagnostics
end

local function leader_timeout(overrides, cli, diagnostics)
  local value = DEFAULT_LEADER_TIMEOUT
  local source = "default"

  local cli_leader = type(cli.leader) == "table" and cli.leader.timeout or nil
  if cli_leader ~= nil then
    value = cli_leader
    source = "cli"
  elseif cli.leader_timeout ~= nil then
    value = cli.leader_timeout
    source = "cli"
  end

  if type(overrides) == "table" then
    local candidate
    if type(overrides.leader) == "table" and overrides.leader.timeout ~= nil
        and overrides.leader.key == nil and overrides.leader.name == nil
    then
      candidate = overrides.leader.timeout
    elseif overrides.leader_timeout ~= nil then
      candidate = overrides.leader_timeout
    end
    if candidate ~= nil then
      value = candidate
      source = "override"
    end
  end

  if not valid_timeout(value) then
    add_diagnostic(diagnostics, "warn", "invalid_timeout",
      ("OpenCode leader timeout must be a positive integer; using %d"):format(DEFAULT_LEADER_TIMEOUT),
      { source = source })
    return DEFAULT_LEADER_TIMEOUT
  end
  return value
end

local function sequence_timeout(opts, overrides)
  local value = opts.sequence_timeout
  if value == nil then
    value = opts.timeout
  end
  if value == nil and type(overrides) == "table" then
    value = overrides.sequence_timeout
  end
  if value == nil and type(overrides) == "table" then
    value = overrides.timeout
  end
  if value == nil then
    value = vim.o.timeoutlen
  end
  if not valid_timeout(value) then
    return DEFAULT_SEQUENCE_TIMEOUT
  end
  return value
end

local function command_values(cli_keybinds, overrides, diagnostics)
  local values = {}
  local order = {}

  local function put(name, value, source)
    if type(name) ~= "string" or name == "" then
      add_diagnostic(diagnostics, "warn", "invalid_command",
        ("keybind command IDs must be non-empty strings; got %s"):format(type(name)),
        { source = source })
      return
    end
    if name == "leader" then
      return
    end
    if values[name] == nil then
      order[#order + 1] = name
    end
    values[name] = { value = value, source = source }
  end

  for name, value in pairs(M.defaults) do
    if name ~= "leader" then
      put(name, value, "default")
    end
  end

  if type(cli_keybinds) == "table" then
    for name, value in pairs(cli_keybinds) do
      put(name, value, "cli")
    end
  end

  local override_bindings = override_keybinds(overrides)
  if type(override_bindings) == "table" then
    local nested = type(overrides.keybinds) == "table"
    for name, value in pairs(override_bindings) do
      if (nested and name ~= "leader") or (not nested and not is_control_override_key(name)) then
        put(name, value, "override")
      end
    end
  end

  return values, order
end

local function modes_for(command, opts)
  if command == "session.interrupt" then
    return { "n" }
  end
  local configured = type(opts.modes) == "table" and opts.modes[command] or nil
  if type(configured) == "string" then
    configured = { configured }
  end
  if type(configured) ~= "table" then
    configured = M.command_modes[command] or { "n" }
  end
  local modes = {}
  for _, mode in ipairs(configured) do
    if type(mode) == "string" and ALLOWED_MODES[mode] then
      modes[#modes + 1] = mode
    end
  end
  if #modes == 0 then
    modes = { "n" }
  end
  return modes
end

--- Resolve OpenCode CLI keybinds and Neovim overrides.
---
--- @param opts table|nil
---   cli_config: parsed OpenCode cli.json table (skips file reads)
---   cli_path: explicit cli.json path
---   read_cli: false disables reading the global file
---   overrides: flat command -> binding table, or { keybinds = ..., leader = ..., timeout = ... }
---   modes: command -> mode string/list override (session.interrupt is always Normal)
---   sequence_timeout: timeout in ms for repeated-key sequences (default: 'timeoutlen')
--- @return table
function M.resolve(opts)
  opts = opts or {}
  local diagnostics = {}
  local cli
  local source = { path = nil, loaded = false }

  if opts.cli_config ~= nil then
    if type(opts.cli_config) ~= "table" or is_json_array(opts.cli_config) then
      add_diagnostic(diagnostics, "warn", "cli_config_invalid",
        "cli_config must be a JSON object table")
      cli = {}
    else
      cli = opts.cli_config
    end
  elseif opts.read_cli == false then
    cli = {}
  else
    cli, source = read_cli_config(opts.cli_path, diagnostics)
  end

  local cli_keybinds = cli.keybinds
  if cli_keybinds ~= nil and (type(cli_keybinds) ~= "table" or is_json_array(cli_keybinds)) then
    add_diagnostic(diagnostics, "warn", "invalid_keybinds",
      "OpenCode cli.json keybinds must be an object; ignoring it")
    cli_keybinds = nil
  end

  local overrides = opts.overrides
  if overrides ~= nil and type(overrides) ~= "table" then
    add_diagnostic(diagnostics, "warn", "invalid_overrides",
      "Neovim keybinding overrides must be a table; ignoring them")
    overrides = nil
  end

  local leader_strokes, leader_lhs, leader_source, leader_diagnostics =
    parse_leader(overrides, cli_keybinds, diagnostics)
  if type(leader_diagnostics) == "table" then
    for _, item in ipairs(leader_diagnostics) do
      if not item.command then
        item.command = "leader"
      end
    end
  end

  local timeout = leader_timeout(overrides, cli, diagnostics)
  local seq_timeout = sequence_timeout(opts, overrides)
  local values, order = command_values(cli_keybinds, overrides, diagnostics)

  local bindings = {}
  local seen = {}
  local all_commands = {}
  for _, name in ipairs(order) do
    if not seen[name] then
      seen[name] = true
      all_commands[#all_commands + 1] = name
    end
  end

  for _, command in ipairs(all_commands) do
    local entry = values[command]
    local parsed = key.parse_binding(entry.value, { leader_strokes = leader_strokes })
    for _, item in ipairs(parsed.diagnostics) do
      item.command = command
      item.source = entry.source
      diagnostics[#diagnostics + 1] = item
    end

    local supported = M.supported[command] == true
    if not supported and entry.source ~= "default" and not parsed.disabled then
      add_diagnostic(diagnostics, "info", "unsupported_command",
        ("OpenCode command %q is configured but this client has no action for it; its keys are ignored"):format(command),
        { command = command, source = entry.source })
    end

    local keys = {}
    for _, alternative in ipairs(parsed.alternatives) do
      keys[#keys + 1] = alternative.lhs
      if alternative.repeated then
        add_diagnostic(diagnostics, "info", "sequence_timeout",
          ("%s uses %q and waits up to %d ms between keys; a single press is not treated as the action"):format(
            command, alternative.lhs, seq_timeout
          ),
          { command = command, key = alternative.lhs })
      end
    end

    bindings[command] = {
      command = command,
      supported = supported,
      source = entry.source,
      disabled = parsed.disabled == true,
      alternatives = parsed.alternatives,
      keys = keys,
      modes = modes_for(command, opts),
    }
  end

  return {
    leader = leader_lhs,
    leader_strokes = leader_strokes,
    leader_source = leader_source,
    leader_timeout = timeout,
    timeout = timeout,
    sequence_timeout = seq_timeout,
    bindings = bindings,
    diagnostics = diagnostics,
    cli = source,
  }
end

--- Health-style diagnostics for the active configuration.
--- @param opts table|nil
--- @return table[] list of { level = string, message = string, code = string }
function M.health(opts)
  local resolved = M.resolve(opts)
  local results = {}
  for _, item in ipairs(resolved.diagnostics) do
    results[#results + 1] = {
      level = item.level,
      code = item.code,
      message = item.message,
    }
  end
  if #results == 0 then
    results[1] = {
      level = "ok",
      code = "keybindings_ok",
      message = "OpenCode keybindings resolved",
    }
  end
  return results
end

local states = {}
local augroup = nil

local function augroup_id()
  if augroup == nil then
    augroup = vim.api.nvim_create_augroup("OpencodeKeybindings", { clear = false })
  end
  return augroup
end

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function stop_timer(state)
  if state.timer then
    pcall(state.timer.stop, state.timer)
    pcall(state.timer.close, state.timer)
    state.timer = nil
  end
end

local function clear_buffer_autocmds(buf)
  if not valid_buf(buf) then
    return
  end
  pcall(vim.api.nvim_clear_autocmds, { group = augroup_id(), buffer = buf })
end

local function sequence_context(buf)
  local win = vim.api.nvim_get_current_win()
  local ok, position = pcall(vim.api.nvim_win_get_cursor, win)
  local current_buf = vim.api.nvim_win_get_buf(win)
  return {
    buffer = current_buf,
    line = ok and position[1] or nil,
    column = ok and position[2] or nil,
    changenr = vim.fn.changenr(),
    mode = vim.api.nvim_get_mode().mode,
    wanted_buffer = buf,
  }
end

local function same_context(left, right)
  if not left or not right then
    return false
  end
  return left.buffer == right.buffer
    and left.line == right.line
    and left.column == right.column
    and left.changenr == right.changenr
    and left.mode == right.mode
    and left.wanted_buffer == right.wanted_buffer
end

local function arm_sequence_timer(state, entry)
  stop_timer(state)
  local timer = vim.uv.new_timer()
  if not timer then
    state.pending = nil
    return
  end
  state.timer = timer
  timer:start(state.sequence_timeout, 0, vim.schedule_wrap(function()
    if state.timer == timer then
      state.timer = nil
      state.pending = nil
    end
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end))
end

local function repeated_handler(state, entry)
  return function()
    if state.detached or not valid_buf(state.buf) then
      return
    end
    local now = vim.uv.hrtime()
    local pending = state.pending
    local context = sequence_context(state.buf)
    local count
    if pending
        and pending.entry == entry
        and same_context(pending.context, context)
        and (now - pending.time) <= state.sequence_timeout * 1000000
    then
      count = pending.count + 1
    else
      count = 1
    end

    if count >= entry.count then
      state.pending = nil
      stop_timer(state)
      entry.action()
      return
    end

    state.pending = {
      entry = entry,
      count = count,
      time = now,
      context = context,
    }
    arm_sequence_timer(state, entry)
  end
end

local function single_handler(state, entry)
  return function()
    if state.detached or not valid_buf(state.buf) then
      return
    end
    state.pending = nil
    stop_timer(state)
    entry.action()
  end
end

-- Read buffer-local mappings directly from the target buffer instead of
-- calling maparg() in whichever buffer happens to be current.  This never
-- switches windows or buffers.  attach()/detach() reject fast events, and the
-- canonicalization helpers additionally degrade to exact lhs matching there.
local function canonical_lhs(lhs)
  if vim.in_fast_event() then
    return lhs
  end
  local raw_ok, raw = pcall(vim.api.nvim_replace_termcodes, lhs, true, false, true)
  if not raw_ok then
    return lhs
  end
  local text_ok, text = pcall(vim.fn.keytrans, raw)
  if text_ok and type(text) == "string" and text ~= "" then
    return text
  end
  return lhs
end

local function buffer_keymaps(buf, mode)
  if vim.in_fast_event() or not valid_buf(buf) then
    return {}
  end
  local ok, maps = pcall(vim.api.nvim_buf_get_keymap, buf, mode)
  if ok and type(maps) == "table" then
    return maps
  end
  return {}
end

local function find_buffer_mapping(buf, mode, lhs)
  local maps = buffer_keymaps(buf, mode)
  if #maps == 0 then
    return nil
  end

  local raw
  if not vim.in_fast_event() then
    local raw_ok, converted = pcall(vim.api.nvim_replace_termcodes, lhs, true, false, true)
    if raw_ok then
      raw = converted
    end
  end
  local wanted = canonical_lhs(lhs)

  for _, map in ipairs(maps) do
    if type(map.lhsraw) == "string" and raw ~= nil
        and (map.lhsraw == raw or map.lhsrawalt == raw)
    then
      return map
    end
    if type(map.lhs) == "string" and (map.lhs == lhs or canonical_lhs(map.lhs) == wanted) then
      return map
    end
  end
  return nil
end

local function mapping_exists(buf, mode, lhs)
  return find_buffer_mapping(buf, mode, lhs) ~= nil
end

local function entries_for(resolved, opts, diagnostics)
  local actions = type(opts.actions) == "table" and opts.actions or {}
  local entries = {}

  for command, binding in pairs(resolved.bindings) do
    local action = actions[command]
    if type(action) == "function" then
      if not binding.disabled then
        for _, alternative in ipairs(binding.alternatives) do
          for _, mode in ipairs(binding.modes) do
            entries[#entries + 1] = {
              command = command,
              mode = mode,
              action = action,
              lhs = alternative.repeated and alternative.first_lhs or alternative.lhs,
              full_lhs = alternative.lhs,
              count = alternative.count,
              repeated = alternative.repeated == true,
            }
          end
        end
      end
    elseif binding.supported and not binding.disabled then
      add_diagnostic(diagnostics, "info", "no_action",
        ("OpenCode command %q has key bindings but no injected action; skipping"):format(command),
        { command = command })
    end
  end

  -- A single-key mapping would immediately consume a longer sequence that
  -- starts with it.  Prefer the longer sequence and report the conflict.
  local filtered = {}
  for _, entry in ipairs(entries) do
    local shadowed = false
    if entry.count == 1 then
      for _, other in ipairs(entries) do
        if other ~= entry and other.mode == entry.mode and other.full_lhs ~= entry.full_lhs
            and other.full_lhs:sub(1, #entry.full_lhs) == entry.full_lhs
        then
          shadowed = true
          add_diagnostic(diagnostics, "warn", "prefix_conflict",
            ("%q is a prefix of %q; the shorter binding is disabled"):format(entry.full_lhs, other.full_lhs),
            { command = entry.command })
          break
        end
      end
    end
    if not shadowed then
      filtered[#filtered + 1] = entry
    end
  end

  local by_lhs = {}
  local order = {}
  for _, entry in ipairs(filtered) do
    local map_key = entry.mode .. "\0" .. entry.lhs
    local existing = by_lhs[map_key]
    if existing then
      if entry.full_lhs ~= existing.full_lhs then
        add_diagnostic(diagnostics, "warn", "mapping_conflict",
          ("%q and %q both map %q; keeping the longer binding"):format(
            existing.full_lhs, entry.full_lhs, entry.lhs
          ),
          { command = entry.command })
      end
      if entry.count > existing.count then
        by_lhs[map_key] = entry
      end
    else
      by_lhs[map_key] = entry
      order[#order + 1] = map_key
    end
  end

  local result = {}
  for _, map_key in ipairs(order) do
    result[#result + 1] = by_lhs[map_key]
  end
  return result
end

--- Attach semantic keybindings to one buffer.
---
--- @param buf number
--- @param opts table|nil Same resolve() options plus:
---   actions: command -> function
---   modes: command -> mode/list override (interrupt stays Normal)
--- @return table|nil handle, table|nil error
function M.attach(buf, opts)
  opts = opts or {}
  if vim.in_fast_event() then
    return nil, {
      code = "fast_event",
      message = "keybindings.attach must not run in a fast event",
    }
  end
  if not valid_buf(buf) then
    return nil, {
      code = "invalid_buffer",
      message = "keybindings.attach requires a valid buffer number",
    }
  end

  M.detach(buf)

  local resolved
  if type(opts.resolved) == "table" and type(opts.resolved.bindings) == "table" then
    resolved = opts.resolved
  else
    resolved = M.resolve(opts)
  end
  local diagnostics = copy(resolved.diagnostics) or {}
  local state = {
    buf = buf,
    resolved = resolved,
    diagnostics = diagnostics,
    mappings = {},
    pending = nil,
    timer = nil,
    sequence_timeout = resolved.sequence_timeout,
    detached = false,
  }

  local entries = entries_for(resolved, opts, diagnostics)
  for _, entry in ipairs(entries) do
    if mapping_exists(buf, entry.mode, entry.lhs) then
      add_diagnostic(diagnostics, "warn", "mapping_conflict",
        ("buffer-local mapping %q already exists; not replacing it"):format(entry.lhs),
        { command = entry.command, mode = entry.mode })
    else
      local callback
      if entry.repeated then
        callback = repeated_handler(state, entry)
      else
        callback = single_handler(state, entry)
      end
      local ok, err = pcall(vim.keymap.set, entry.mode, entry.lhs, callback, {
        buffer = buf,
        silent = true,
        nowait = entry.count == 1 or entry.repeated,
        noremap = true,
        desc = MAPPING_DESC_PREFIX .. entry.command,
      })
      if ok then
        state.mappings[#state.mappings + 1] = {
          mode = entry.mode,
          lhs = entry.lhs,
          command = entry.command,
          full_lhs = entry.full_lhs,
        }
      else
        add_diagnostic(diagnostics, "warn", "mapping_failed",
          ("cannot map %q in mode %q: %s"):format(entry.lhs, entry.mode, tostring(err)),
          { command = entry.command, mode = entry.mode })
      end
    end
  end

  states[buf] = state

  clear_buffer_autocmds(buf)
  if valid_buf(buf) then
    pcall(vim.api.nvim_create_autocmd, "BufWipeout", {
      group = augroup_id(),
      buffer = buf,
      once = true,
      callback = function()
        M.detach(buf)
      end,
    })
    -- A sequence is only valid while the user stays in the same editing
    -- context.  These buffer-local events reset a pending repeated-key
    -- sequence without installing a global on_key hook.
    pcall(vim.api.nvim_create_autocmd, {
      "ModeChanged",
      "CursorMoved",
      "CursorMovedI",
      "TextChanged",
      "TextChangedI",
      "InsertEnter",
      "CmdlineEnter",
      "BufLeave",
      "WinLeave",
    }, {
      group = augroup_id(),
      buffer = buf,
      callback = function()
        if states[buf] == state and state.pending then
          state.pending = nil
          stop_timer(state)
        end
      end,
    })
  end

  return state
end

--- Remove all mappings and timers owned by this module for one buffer.
--- @param buf number
--- @return boolean detached
function M.detach(buf)
  if vim.in_fast_event() then
    return false
  end
  local state = states[buf]
  if not state then
    return false
  end
  states[buf] = nil
  state.detached = true
  state.pending = nil
  stop_timer(state)

  if valid_buf(buf) then
    for _, mapping in ipairs(state.mappings) do
      local current = find_buffer_mapping(buf, mapping.mode, mapping.lhs)
      local owned = type(current) == "table"
        and current.desc == MAPPING_DESC_PREFIX .. mapping.command
      -- Do not remove a mapping another plugin replaced after attach().
      if owned then
        pcall(vim.keymap.del, mapping.mode, mapping.lhs, { buffer = buf })
      end
    end
  end
  clear_buffer_autocmds(buf)
  state.mappings = {}
  return true
end

--- @param buf number
--- @return boolean
function M.is_attached(buf)
  return states[buf] ~= nil and not states[buf].detached
end

--- Diagnostic/testing view of one attached buffer.
--- @param buf number
--- @return table|nil
function M.get_state(buf)
  local state = states[buf]
  if not state then
    return nil
  end
  local pending = nil
  if state.pending then
    pending = {
      count = state.pending.count,
      time = state.pending.time,
    }
  end
  return {
    buffer = state.buf,
    resolved = state.resolved,
    diagnostics = copy(state.diagnostics),
    mappings = copy(state.mappings),
    pending = pending,
    detached = state.detached,
  }
end

return M
