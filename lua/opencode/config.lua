local M = {}

M.defaults = {
  server = {
    url = "http://127.0.0.1:4096",
    headers = {},
  },
  project = {
    root = nil,
  },
  sidebar = {
    width = 48,
    input_height = 8,
  },
  keymaps = {
    toggle = "<leader>oo",
    send_selection = "<leader>os",
    question_selection = "<leader>oq",
    submit = "<C-s>",
  },
  keybindings = {
    enabled = true,
    -- nil uses keybindings.default_path(), i.e. OpenCode's cli.json.
    cli_path = nil,
    read_cli = true,
    overrides = {},
    sequence_timeout = nil,
  },
  completion = {
    enabled = true,
    auto = true,
    minimum_length = 1,
    debounce = 100,
    limit = 20,
    cache_ttl = 30000,
    file_cache_ttl = 0,
  },
  status = {
    enabled = true,
    spinner_interval = 1000,
    submit_hint = nil,
  },
  tools = {
    -- The local tool server is started once the project root is known, but
    -- only when the optional OpenCode companion is expected to call it.
    enabled = true,
    registry_dir = nil,
    instance_id = nil,
  },
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

local function validate_url(url)
  if type(url) ~= "string" or url == "" then
    error("opencode: server.url must be a non-empty string", 0)
  end
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.+)$")
  if not scheme then
    error(("opencode: server.url %q must be an absolute http:// URL"):format(url), 0)
  end
  scheme = scheme:lower()
  if scheme == "https" then
    error("opencode: server.url uses https, which is not supported yet (TLS transport is not implemented)", 0)
  end
  if scheme ~= "http" then
    error(("opencode: server.url scheme %q is not supported; use http://"):format(scheme), 0)
  end
  if url:find("%s") then
    error(("opencode: server.url %q must not contain whitespace"):format(url), 0)
  end
  local authority = rest:match("^([^/?#]+)")
  if not authority or authority == "" then
    error(("opencode: server.url %q is missing a host"):format(url), 0)
  end

  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^%[([^%]]+)%]:(%d+)$")
    if not host then
      host = authority:match("^%[([^%]]+)%]$")
    end
    if not host then
      error(("opencode: server.url %q has an invalid host or port"):format(url), 0)
    end
  else
    host, port = authority:match("^(.-):(%d+)$")
    if not host then
      if authority:find(":", 1, true) then
        error(("opencode: server.url %q has an invalid port"):format(url), 0)
      end
      host = authority
    end
  end
  if host == "" then
    error(("opencode: server.url %q is missing a host"):format(url), 0)
  end
  if port then
    local number = tonumber(port)
    if not number or number < 1 or number > 65535 then
      error(("opencode: server.url %q has an invalid port"):format(url), 0)
    end
  end
end

local function validate_headers(headers)
  if type(headers) ~= "table" then
    error("opencode: server.headers must be a table", 0)
  end
  for name, value in pairs(headers) do
    if type(name) ~= "string" or name == "" then
      error("opencode: server.headers keys must be non-empty strings", 0)
    end
    if name:find("[\r\n]") then
      error(("opencode: server.headers[%q] must not contain CR or LF"):format(name), 0)
    end
    if type(value) ~= "string" then
      error(("opencode: server.headers[%q] must be a string"):format(name), 0)
    end
    if value:find("[\r\n]") then
      error(("opencode: server.headers[%q] must not contain CR or LF"):format(name), 0)
    end
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

local function validate(config)
  if type(config) ~= "table" then
    error("opencode: configuration must be a table", 0)
  end

  if type(config.server) ~= "table" then
    error("opencode: server must be a table", 0)
  end
  validate_url(config.server.url)
  validate_headers(config.server.headers)

  if type(config.project) ~= "table" then
    error("opencode: project must be a table", 0)
  end
  if config.project.root ~= nil and (type(config.project.root) ~= "string" or config.project.root == "") then
    error("opencode: project.root must be nil or a non-empty string", 0)
  end

  if type(config.sidebar) ~= "table" then
    error("opencode: sidebar must be a table", 0)
  end
  validate_dimension("sidebar.width", config.sidebar.width, 1, 1000)
  validate_dimension("sidebar.input_height", config.sidebar.input_height, 1, 1000)

  if type(config.keymaps) ~= "table" then
    error("opencode: keymaps must be a table", 0)
  end
  for name, value in pairs(config.keymaps) do
    if type(name) ~= "string" then
      error("opencode: keymaps keys must be strings", 0)
    end
    if value ~= nil and value ~= false and (type(value) ~= "string" or value == "") then
      error(("opencode: keymaps.%s must be a non-empty string or false"):format(name), 0)
    end
  end

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

  if type(config.completion) ~= "table" then
    error("opencode: completion must be a table", 0)
  end
  for _, name in ipairs({ "enabled", "auto" }) do
    if type(config.completion[name]) ~= "boolean" then
      error(("opencode: completion.%s must be a boolean"):format(name), 0)
    end
  end
  validate_dimension("completion.minimum_length", config.completion.minimum_length, 0, 1000)
  validate_dimension("completion.debounce", config.completion.debounce, 0, 60000)
  validate_dimension("completion.limit", config.completion.limit, 1, 1000)
  validate_dimension("completion.cache_ttl", config.completion.cache_ttl, 0, 86400000)
  validate_dimension("completion.file_cache_ttl", config.completion.file_cache_ttl, 0, 86400000)

  if type(config.status) ~= "table" then
    error("opencode: status must be a table", 0)
  end
  if type(config.status.enabled) ~= "boolean" then
    error("opencode: status.enabled must be a boolean", 0)
  end
  validate_dimension("status.spinner_interval", config.status.spinner_interval, 50, 60000)
  if config.status.submit_hint ~= nil and type(config.status.submit_hint) ~= "string" then
    error("opencode: status.submit_hint must be nil or a string", 0)
  end

  if type(config.tools) ~= "table" then
    error("opencode: tools must be a table", 0)
  end
  if type(config.tools.enabled) ~= "boolean" then
    error("opencode: tools.enabled must be a boolean", 0)
  end
  if config.tools.registry_dir ~= nil
    and (type(config.tools.registry_dir) ~= "string" or config.tools.registry_dir == "")
  then
    error("opencode: tools.registry_dir must be nil or a non-empty string", 0)
  end
  if config.tools.instance_id ~= nil
    and (type(config.tools.instance_id) ~= "string" or config.tools.instance_id == "")
  then
    error("opencode: tools.instance_id must be nil or a non-empty string", 0)
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
  validate(resolved)
  return resolved
end

return M
