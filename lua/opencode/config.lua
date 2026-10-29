local M = {}

M.defaults = {
  -- OpenCode executable. A list is accepted for launchers such as
  -- `{ "bunx", "opencode" }`; the positional project directory is appended.
  cmd = "opencode",
  args = {},
  -- nil uses project.root, then Neovim's current working directory.
  cwd = nil,
  project = {
    root = nil,
  },
  session = {
    -- Start with `opencode --continue`.
    continue = false,
    -- Start or resume a specific session with `opencode --session <id>`.
    id = nil,
    -- Pass `opencode --prompt <text>`; useful for scripted first prompts.
    prompt = nil,
  },
  window = {
    layout = "right", -- right | left | above | below
    size = 80,
    start_insert = true,
  },
  keymaps = {
    toggle = "<leader>oo",
    send_selection = "<leader>os",
    question_selection = "<leader>oq",
    -- Tab is only installed when it does not collide with an OpenCode
    -- keybinding from cli.json. Set to false to disable it entirely.
    focus_next = "<Tab>",
  },
  keybindings = {
    enabled = true,
    -- nil uses $OPENCODE_CONFIG_DIR/cli.json or the XDG config directory.
    cli_path = nil,
    read_cli = true,
    overrides = {},
    sequence_timeout = nil,
  },
  input = {
    -- Composer Vim-like editing primitives (h/l/w/b/x/dd/...).
    primitives = true,
    -- Forward otherwise unbound Normal-mode keys to the TUI.
    passthrough = true,
  },
  paste = {
    -- Send bracketed-paste guards around composer text.
    bracketed = true,
    -- Delay before pasting right after a cold terminal start (ms).
    ready_delay = 150,
    -- Separate paste from submit so multiline text is not submitted early.
    submit_delay = 30,
  },
  focus = {
    initial = "composer", -- composer | session
  },
}

local LAYOUTS = {
  right = true,
  left = true,
  above = true,
  below = true,
}

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end
  return count > 0 and count == #value
end

local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = deepcopy(item)
  end
  return copy
end

--- Merge user options over defaults. Lists replace; maps merge recursively.
local function merge(base, override)
  local result = deepcopy(base)
  if type(override) ~= "table" then
    return result
  end
  for key, value in pairs(override) do
    if type(value) == "table" and type(result[key]) == "table" and not is_list(value) then
      result[key] = merge(result[key], value)
    elseif value ~= nil then
      result[key] = deepcopy(value)
    end
  end
  return result
end

local function validate_string_list(name, value, allow_empty)
  if type(value) ~= "table" then
    error(("opencode: %s must be a list of strings"):format(name), 0)
  end
  local count = 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      error(("opencode: %s must be a list of strings"):format(name), 0)
    end
    if type(item) ~= "string" or item == "" then
      error(("opencode: %s must contain only non-empty strings"):format(name), 0)
    end
    count = count + 1
  end
  if count ~= #value then
    error(("opencode: %s must be a contiguous list of strings"):format(name), 0)
  end
  if not allow_empty and #value == 0 then
    error(("opencode: %s must not be empty"):format(name), 0)
  end
end

local function validate_dimension(name, value, minimum, maximum)
  if type(value) ~= "number" or value ~= math.floor(value) then
    error(("opencode: %s must be an integer"):format(name), 0)
  end
  if value < minimum or value > maximum then
    error(("opencode: %s must be between %d and %d"):format(name, minimum, maximum), 0)
  end
end

local function validate_keymaps(keymaps)
  if type(keymaps) ~= "table" then
    error("opencode: keymaps must be a table", 0)
  end
  for name, value in pairs(keymaps) do
    if type(name) ~= "string" then
      error("opencode: keymaps keys must be strings", 0)
    end
    if value ~= nil and value ~= false and (type(value) ~= "string" or value == "") then
      error(("opencode: keymaps.%s must be a non-empty string or false"):format(name), 0)
    end
  end
end

local function validate_config(config)
  if type(config) ~= "table" then
    error("opencode: configuration must be a table", 0)
  end

  if type(config.cmd) == "string" then
    if config.cmd == "" then
      error("opencode: cmd must be a non-empty string or a list of strings", 0)
    end
  else
    validate_string_list("cmd", config.cmd, false)
  end
  validate_string_list("args", config.args, true)
  if config.cwd ~= nil and (type(config.cwd) ~= "string" or config.cwd == "") then
    error("opencode: cwd must be nil or a non-empty string", 0)
  end

  if type(config.project) ~= "table" then
    error("opencode: project must be a table", 0)
  end
  if config.project.root ~= nil and (type(config.project.root) ~= "string" or config.project.root == "") then
    error("opencode: project.root must be nil or a non-empty string", 0)
  end

  if type(config.session) ~= "table" then
    error("opencode: session must be a table", 0)
  end
  if type(config.session.continue) ~= "boolean" then
    error("opencode: session.continue must be a boolean", 0)
  end
  if config.session.id ~= nil and (type(config.session.id) ~= "string" or config.session.id == "") then
    error("opencode: session.id must be nil or a non-empty string", 0)
  end
  if config.session.prompt ~= nil and type(config.session.prompt) ~= "string" then
    error("opencode: session.prompt must be nil or a string", 0)
  end

  if type(config.window) ~= "table" then
    error("opencode: window must be a table", 0)
  end
  if not LAYOUTS[config.window.layout] then
    error("opencode: window.layout must be one of right, left, above, below", 0)
  end
  validate_dimension("window.size", config.window.size, 1, 1000)
  if type(config.window.start_insert) ~= "boolean" then
    error("opencode: window.start_insert must be a boolean", 0)
  end

  validate_keymaps(config.keymaps)

  if type(config.keybindings) ~= "table" then
    error("opencode: keybindings must be a table", 0)
  end
  for _, name in ipairs({ "enabled", "read_cli" }) do
    if type(config.keybindings[name]) ~= "boolean" then
      error(("opencode: keybindings.%s must be a boolean"):format(name), 0)
    end
  end
  local cli_path = config.keybindings.cli_path
  if cli_path ~= nil and (type(cli_path) ~= "string" or cli_path == "") then
    error("opencode: keybindings.cli_path must be nil or a non-empty string", 0)
  end
  if type(config.keybindings.overrides) ~= "table" then
    error("opencode: keybindings.overrides must be a table", 0)
  end
  local sequence_timeout = config.keybindings.sequence_timeout
  if sequence_timeout ~= nil and (type(sequence_timeout) ~= "number" or sequence_timeout <= 0) then
    error("opencode: keybindings.sequence_timeout must be nil or a positive number", 0)
  end

  if type(config.input) ~= "table" then
    error("opencode: input must be a table", 0)
  end
  for _, name in ipairs({ "primitives", "passthrough" }) do
    if type(config.input[name]) ~= "boolean" then
      error(("opencode: input.%s must be a boolean"):format(name), 0)
    end
  end

  if type(config.paste) ~= "table" then
    error("opencode: paste must be a table", 0)
  end
  if type(config.paste.bracketed) ~= "boolean" then
    error("opencode: paste.bracketed must be a boolean", 0)
  end
  validate_dimension("paste.ready_delay", config.paste.ready_delay, 0, 60000)
  validate_dimension("paste.submit_delay", config.paste.submit_delay, 0, 60000)

  if type(config.focus) ~= "table" then
    error("opencode: focus must be a table", 0)
  end
  if config.focus.initial ~= "composer" and config.focus.initial ~= "session" then
    error("opencode: focus.initial must be 'composer' or 'session'", 0)
  end
end

--- Resolve options against defaults and validate the result.
--- @param opts table|nil
--- @return table
function M.resolve(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("opencode: setup() expects a table or nil", 0)
  end
  local resolved = merge(M.defaults, opts or {})
  validate_config(resolved)
  return resolved
end

return M
