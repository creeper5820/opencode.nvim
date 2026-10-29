-- Effective OpenCode CLI keybindings.
--
-- The embedded TUI receives keys directly, so this module no longer maps
-- command IDs to Lua actions.  It resolves cli.json (defaults + user file +
-- Neovim overrides) into complete key sequences and encodes them as PTY input
-- bytes.  The router installs those sequences as buffer-local Normal-mode
-- mappings in the OpenCode terminal buffer; Insert mode is never mapped.

local key = require("opencode.keybindings.key")
local encoder = require("opencode.keybindings.encode")
local defaults = require("opencode.keybindings.defaults")

local M = {}

M.defaults = defaults
M.native_defaults = defaults

local DEFAULT_LEADER_TIMEOUT = 2000
local DEFAULT_SEQUENCE_TIMEOUT = 1000
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

local function canonical(name)
  return tostring(name):gsub("%.", "_")
end

local function alias_for(name)
  if type(name) ~= "string" or not name:find("_", 1, true) then
    return nil
  end
  return (name:gsub("_", "."))
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

local function parse_leader(overrides, cli_keybinds, cli, diagnostics)
  local value = defaults.leader
  local source = "default"

  if type(cli_keybinds) == "table" and rawget(cli_keybinds, "leader") ~= nil then
    value = cli_keybinds.leader
    source = "cli"
  elseif type(cli.leader) == "string"
    or (type(cli.leader) == "table" and not is_leader_timing_only(cli.leader))
  then
    value = cli.leader
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
      local default_ok, default_strokes, default_diagnostics = pcall(key.parse_leader, defaults.leader, {})
      if default_ok and default_strokes then
        add_diagnostic(diagnostics, "info", "leader_fallback",
          ("using the default OpenCode leader %q"):format(defaults.leader),
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
  local value = defaults.leader_timeout or DEFAULT_LEADER_TIMEOUT
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

local function sorted_keys(table_value)
  local names = {}
  for name in pairs(table_value or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function command_values(cli_keybinds, overrides, diagnostics)
  local values = {}
  local order = {}
  local originals = {}

  local function put(name, value, source, original)
    if type(name) ~= "string" or name == "" then
      add_diagnostic(diagnostics, "warn", "invalid_command",
        ("keybind command IDs must be non-empty strings; got %s"):format(type(name)),
        { source = source })
      return
    end
    local normalized = canonical(name)
    if normalized == "leader" or normalized == "leader_timeout" then
      return
    end
    if values[normalized] == nil then
      order[#order + 1] = normalized
    end
    values[normalized] = { value = value, source = source, original = original or normalized }
    originals[normalized] = original or normalized
  end

  for _, name in ipairs(sorted_keys(defaults)) do
    if name ~= "leader" and name ~= "leader_timeout" then
      put(name, defaults[name], "default", name)
    end
  end

  if type(cli_keybinds) == "table" then
    for _, name in ipairs(sorted_keys(cli_keybinds)) do
      put(name, cli_keybinds[name], "cli", name)
    end
  end

  local override_bindings = override_keybinds(overrides)
  if type(override_bindings) == "table" then
    local nested = type(overrides.keybinds) == "table"
    for _, name in ipairs(sorted_keys(override_bindings)) do
      if (nested and name ~= "leader") or (not nested and not is_control_override_key(name)) then
        put(name, override_bindings[name], "override", name)
      end
    end
  end

  return values, order, originals
end

--- Resolve OpenCode CLI keybinds and Neovim overrides.
---
--- @param opts table|nil
---   cli_config: parsed OpenCode cli.json table (skips file reads)
---   cli_path: explicit cli.json path
---   read_cli: false disables reading the global file
---   overrides: flat command -> binding table, or { keybinds = ..., leader = ..., timeout = ... }
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

  local cli_keybinds = cli.keybinds or cli.keybindings
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
    parse_leader(overrides, cli_keybinds, cli, diagnostics)
  if type(leader_diagnostics) == "table" then
    for _, item in ipairs(leader_diagnostics) do
      if not item.command then
        item.command = "leader"
      end
    end
  end

  local timeout = leader_timeout(overrides, cli, diagnostics)
  local seq_timeout = sequence_timeout(opts, overrides)
  local values, order, originals = command_values(cli_keybinds, overrides, diagnostics)

  local bindings = {}
  for _, name in ipairs(order) do
    local entry = values[name]
    local parsed = key.parse_binding(entry.value, { leader_strokes = leader_strokes })
    for _, item in ipairs(parsed.diagnostics) do
      item.command = entry.original
      item.source = entry.source
      diagnostics[#diagnostics + 1] = item
    end

    local keys = {}
    local alternatives = {}
    for _, alternative in ipairs(parsed.alternatives) do
      local bytes, lhs, encode_error = encoder.sequence(alternative.strokes)
      if bytes then
        alternative.bytes = bytes
        alternative.lhs = lhs
        keys[#keys + 1] = lhs
        alternatives[#alternatives + 1] = alternative
        if alternative.repeated then
          add_diagnostic(diagnostics, "info", "sequence_timeout",
            ("%s uses %q and waits up to %d ms between keys"):format(
              entry.original, lhs, seq_timeout
            ),
            { command = entry.original, key = lhs })
        end
      elseif entry.source ~= "default" then
        -- Native defaults that cannot be represented in a terminal are simply
        -- unavailable; only user-provided bindings produce a diagnostic.
        add_diagnostic(diagnostics, "warn", "unsupported_key",
          ("cannot encode %s as terminal input: %s"):format(
            alternative.lhs or entry.original, tostring(encode_error)
          ),
          { command = entry.original, key = alternative.lhs })
      end
    end

    local binding = {
      command = entry.original,
      supported = true,
      forwarded = true,
      source = entry.source,
      disabled = parsed.disabled == true,
      alternatives = alternatives,
      keys = keys,
      modes = { "n" },
    }

    bindings[entry.original] = binding
    if name ~= entry.original then
      bindings[name] = binding
    end
    local alias = alias_for(entry.original)
    if alias and bindings[alias] == nil then
      bindings[alias] = binding
    end
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

--- Encode one resolved alternative as terminal bytes.
--- @param alternative table
--- @return string|nil bytes
function M.alternative_bytes(alternative)
  if type(alternative) ~= "table" then
    return nil
  end
  if alternative.bytes then
    return alternative.bytes
  end
  local bytes = encoder.sequence(alternative.strokes)
  return bytes
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

M.canonical = canonical

return M
