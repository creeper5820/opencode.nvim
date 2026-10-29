-- Terminal input router.
--
-- Insert mode is not mapped at all: the official TUI receives every key except
-- Neovim's own <Esc> transition to Normal.  Normal mode gets buffer-local
-- mappings only:
--
--   * effective OpenCode cli.json bindings (alternatives, full leader
--     sequences and modifier combinations), forwarded as PTY bytes;
--   * composer/session editing primitives;
--   * the optional logical focus key;
--   * a passthrough for otherwise unbound printable/special keys.
--
-- There is no global on_key hook and no attempt to inspect or redraw TUI rows.

local primitives = require("opencode.primitives")

local M = {}

local UP = "\27[A"
local DOWN = "\27[B"
local RIGHT = "\27[C"
local LEFT = "\27[D"
local HOME = "\27[H"
local END = "\27[F"
local PAGE_UP = "\27[5~"
local PAGE_DOWN = "\27[6~"

local RAW_KEYS = {
  ["<C-d>"] = "\4",
  ["<C-u>"] = "\21",
  ["<C-f>"] = "\6",
  ["<C-b>"] = "\2",
  ["<C-r>"] = "\18",
  ["<CR>"] = "\r",
  ["<PageUp>"] = PAGE_UP,
  ["<PageDown>"] = PAGE_DOWN,
  ["<Home>"] = HOME,
  ["<End>"] = END,
}

local function raw_bytes(lhs)
  return RAW_KEYS[lhs] or lhs
end

local RESERVED = {
  i = true,
  a = true,
  I = true,
  A = true,
  [":"] = true,
  ["/"] = true,
  ["g"] = true,
}

local SPECIAL_PASSTHROUGH = {
  { "<CR>", "\r" },
  { "<BS>", "\127" },
  { "<Del>", "\27[3~" },
  { "<Insert>", "\27[2~" },
  { "<Up>", UP },
  { "<Down>", DOWN },
  { "<Left>", LEFT },
  { "<Right>", RIGHT },
  { "<Home>", HOME },
  { "<End>", END },
  { "<PageUp>", PAGE_UP },
  { "<PageDown>", PAGE_DOWN },
  { "<Tab>", "\t" },
  { "<S-Tab>", "\27[Z" },
  { "<Esc>", "\27" },
  { "<C-[>", "\27" },
  { "<Space>", " " },
}

local Router = {}
Router.__index = Router

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  return vim.deepcopy(value)
end

local function add(entries, seen, entry)
  if not entry.lhs or entry.lhs == "" or seen[entry.lhs] then
    return false
  end
  seen[entry.lhs] = true
  entries[#entries + 1] = entry
  return true
end

local function prune_prefixes(entries)
  local result = {}
  for _, entry in ipairs(entries) do
    local shadowed = false
    for _, other in ipairs(entries) do
      if other ~= entry
        and other.lhs ~= entry.lhs
        and #other.lhs > #entry.lhs
        and other.lhs:sub(1, #entry.lhs) == entry.lhs
      then
        shadowed = true
        break
      end
    end
    if not shadowed then
      result[#result + 1] = entry
    end
  end
  return result
end

--- Build the deterministic buffer-local mapping plan.
--- @param resolved table keybindings.resolve() result
--- @param opts table|nil { keymaps, input, focus_next }
--- @return table[] entries
function M.plan(resolved, opts)
  opts = opts or {}
  local input = opts.input or {}
  local keymaps = opts.keymaps or {}
  local entries = {}
  local seen = {}
  local seen_binding = {}

  local bindings = {}
  for _, binding in pairs(resolved.bindings or {}) do
    if type(binding) == "table" and not seen_binding[binding] then
      seen_binding[binding] = true
      bindings[#bindings + 1] = binding
    end
  end
  table.sort(bindings, function(left, right)
    return tostring(left.command) < tostring(right.command)
  end)

  for _, binding in ipairs(bindings) do
    if not binding.disabled then
      for _, alternative in ipairs(binding.alternatives or {}) do
        if alternative.bytes and alternative.lhs then
          add(entries, seen, {
            mode = "n",
            lhs = alternative.lhs,
            kind = "feed",
            bytes = alternative.bytes,
            command = binding.command,
            count = alternative.count,
            multi = (alternative.count or 1) > 1,
            desc = "OpenCode: " .. tostring(binding.command),
          })
        end
      end
    end
  end

  if input.primitives ~= false then
    add(entries, seen, {
      mode = "n",
      lhs = "d",
      kind = "operator",
      operator = "delete",
      raw = "d",
      multi = false,
      desc = "OpenCode: Vim delete operator",
    })
    add(entries, seen, {
      mode = "n",
      lhs = "c",
      kind = "operator",
      operator = "change",
      raw = "c",
      multi = false,
      desc = "OpenCode: Vim change operator",
    })
    for _, item in ipairs(primitives.keys) do
      local lhs, name = item[1], item[2]
      local kind = "primitive"
      if lhs == "C" then
        kind = "primitive_insert"
      end
      local definition = primitives.get(name)
      add(entries, seen, {
        mode = "n",
        lhs = lhs,
        kind = kind,
        primitive = name,
        fallback_bytes = definition and not definition.session and raw_bytes(lhs) or nil,
        multi = lhs == "gg",
        desc = "OpenCode: " .. name,
      })
    end
  end

  local focus_key = keymaps.focus_next
  if focus_key ~= false and focus_key ~= nil and focus_key ~= "" then
    add(entries, seen, {
      mode = "n",
      lhs = focus_key,
      kind = "focus",
      multi = false,
      desc = "OpenCode: switch logical focus",
    })
  end

  if input.passthrough ~= false then
    for byte = 32, 126 do
      local char = string.char(byte)
      if not RESERVED[char] then
        add(entries, seen, {
          mode = "n",
          lhs = char,
          kind = "passthrough",
          bytes = char,
          multi = false,
          desc = "OpenCode: pass through " .. char,
        })
      end
    end
    for _, item in ipairs(SPECIAL_PASSTHROUGH) do
      add(entries, seen, {
        mode = "n",
        lhs = item[1],
        kind = "passthrough",
        bytes = item[2],
        multi = false,
        desc = "OpenCode: pass through " .. item[1],
      })
    end
  end

  return prune_prefixes(entries)
end

--- Create a router bound to one terminal buffer.
--- @param opts table { focus, channel, keybindings, config, notify, on_focus }
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    focus = opts.focus,
    channel_source = opts.channel,
    keybindings = opts.keybindings or { bindings = {} },
    config = opts.config or {},
    notify = opts.notify,
    on_focus = opts.on_focus,
    buf = nil,
    entries = {},
    by_lhs = {},
    installed = {},
    custom = {},
    attached = false,
  }, Router)
end

function Router:_notify(message, level)
  if type(self.notify) == "function" then
    pcall(self.notify, message, level or vim.log.levels.WARN)
  end
end

function Router:channel()
  local source = self.channel_source
  if type(source) == "function" then
    local ok, channel = pcall(source)
    if ok then
      return channel
    end
    return nil
  end
  return source
end

function Router:_context()
  return {
    channel = self:channel(),
    focus = self.focus,
    keybindings = self.keybindings,
  }
end

function Router:_send(bytes)
  local channel = self:channel()
  if not channel or type(channel.send) ~= "function" then
    return false, "OpenCode terminal is not running"
  end
  return channel:send(bytes)
end

--- Execute one plan entry.  Exposed for tests and for user-facing keymaps.
--- @param entry table
--- @param count number|nil
--- @return boolean ok
--- @return string|nil error
function Router:execute(entry, count)
  if type(entry) ~= "table" then
    return false, "invalid mapping entry"
  end
  count = count or 1
  if entry.kind == "feed" then
    return self:_send(entry.bytes)
  elseif entry.kind == "passthrough" then
    return self:_send(entry.bytes:rep(count))
  elseif entry.kind == "primitive" or entry.kind == "primitive_insert" then
    local focus = self.focus
    if focus and type(focus.get) == "function" then
      local ok_focus, region = pcall(focus.get, focus)
      if ok_focus and region == "session" and entry.fallback_bytes then
        return self:_send(entry.fallback_bytes:rep(count))
      end
    end
    local ok, err = primitives.apply(entry.primitive, count, self:_context())
    if ok and entry.kind == "primitive_insert" then
      pcall(vim.cmd, "startinsert")
    end
    return ok, err
  elseif entry.kind == "operator" then
    local focus = self.focus
    if focus and type(focus.get) == "function" then
      local ok_focus, region = pcall(focus.get, focus)
      if ok_focus and region == "session" then
        return self:_send(entry.raw:rep(count))
      end
    end
    local key = vim.fn.getcharstr()
    if key == nil or key == "" or key == "\27" then
      return false
    end
    return primitives.operator(entry.operator, key, count, self:_context())
  elseif entry.kind == "focus" then
    if not self.focus or type(self.focus.toggle) ~= "function" then
      return false, "logical focus is not available"
    end
    local ok, region = pcall(self.focus.toggle, self.focus)
    if not ok then
      return false, tostring(region)
    end
    if type(self.on_focus) == "function" then
      pcall(self.on_focus, region)
    end
    return true
  end
  return false, ("unknown mapping kind %q"):format(tostring(entry.kind))
end

--- Execute the mapping for an lhs without involving Neovim's key processing.
--- Useful for tests and for plugins that want to reuse the router.
--- @param lhs string
--- @param count number|nil
--- @return boolean ok
--- @return string|nil error
function Router:press(lhs, count)
  local entry = self.by_lhs[lhs] or self.custom[lhs] and self.custom[lhs].entry
  if not entry then
    return false, ("no OpenCode mapping for %q"):format(tostring(lhs))
  end
  return self:execute(entry, count)
end

local function install_mapping(router, entry, opts)
  opts = opts or {}
  local count = opts.count ~= false
  local callback
  if entry.kind == "operator" then
    callback = function()
      local ok, err = router:execute(entry, vim.v.count1)
      if not ok and err then
        router:_notify("OpenCode: " .. tostring(err))
      end
    end
  elseif count then
    callback = function()
      local ok, err = router:execute(entry, vim.v.count1)
      if not ok and err and entry.kind ~= "passthrough" then
        router:_notify("OpenCode: " .. tostring(err))
      end
    end
  else
    callback = function()
      local ok, err = router:execute(entry, 1)
      if not ok and err then
        router:_notify("OpenCode: " .. tostring(err))
      end
    end
  end

  local ok, err = pcall(vim.keymap.set, entry.mode or "n", entry.lhs, callback, {
    buffer = router.buf,
    silent = true,
    nowait = entry.multi ~= true,
    noremap = true,
    desc = entry.desc or "OpenCode",
  })
  if not ok then
    return false, tostring(err)
  end
  router.installed[#router.installed + 1] = {
    mode = entry.mode or "n",
    lhs = entry.lhs,
    desc = entry.desc or "OpenCode",
  }
  return true
end

--- Attach the plan to the terminal buffer.  Idempotent.
--- @param buf number
--- @return boolean ok
--- @return string|nil error
function Router:attach(buf)
  if not valid_buf(buf) then
    return false, "invalid OpenCode terminal buffer"
  end
  if self.attached and self.buf == buf then
    return true
  end
  self:detach()
  self.buf = buf
  self.entries = M.plan(self.keybindings, {
    keymaps = self.config.keymaps or {},
    input = self.config.input or {},
  })
  self.by_lhs = {}
  for _, entry in ipairs(self.entries) do
    self.by_lhs[entry.lhs] = entry
    local ok, err = install_mapping(self, entry)
    if not ok then
      return false, ("cannot install %q: %s"):format(entry.lhs, err)
    end
  end
  self.attached = true
  return true
end

local function canonical_lhs(lhs)
  local ok, raw = pcall(vim.api.nvim_replace_termcodes, lhs, true, false, true)
  if not ok then
    return lhs
  end
  local text_ok, text = pcall(vim.fn.keytrans, raw)
  if text_ok and type(text) == "string" and text ~= "" then
    return text
  end
  return lhs
end

local function owned_mapping(buf, mapping)
  local ok, maps = pcall(vim.api.nvim_buf_get_keymap, buf, mapping.mode)
  if not ok or type(maps) ~= "table" then
    return false
  end
  local wanted = canonical_lhs(mapping.lhs)
  for _, map in ipairs(maps) do
    if type(map.lhs) == "string"
      and (map.lhs == mapping.lhs or canonical_lhs(map.lhs) == wanted)
      and map.desc == mapping.desc
    then
      return true
    end
  end
  return false
end

--- Remove every mapping owned by this router for its buffer.
function Router:detach()
  local buf = self.buf
  if valid_buf(buf) then
    for _, mapping in ipairs(self.installed) do
      if owned_mapping(buf, mapping) then
        pcall(vim.keymap.del, mapping.mode, mapping.lhs, { buffer = buf })
      end
    end
    for _, custom in pairs(self.custom) do
      if owned_mapping(buf, custom) then
        pcall(vim.keymap.del, custom.mode, custom.lhs, { buffer = buf })
      end
    end
  end
  self.installed = {}
  self.custom = {}
  self.entries = {}
  self.by_lhs = {}
  self.buf = nil
  self.attached = false
end

--- Install a user-defined Normal-mode primitive mapping in the terminal buffer.
--- @param lhs string
--- @param name string
--- @param opts table|nil { count = boolean, desc = string }
--- @return boolean ok
--- @return string|nil error
function Router:map_primitive(lhs, name, opts)
  opts = opts or {}
  if not valid_buf(self.buf) then
    return false, "OpenCode terminal buffer is not attached"
  end
  if type(lhs) ~= "string" or lhs == "" then
    return false, "lhs must be a non-empty string"
  end
  if not primitives.get(name) then
    return false, ("unknown primitive %q"):format(tostring(name))
  end
  if self.by_lhs[lhs] or self.custom[lhs] then
    return false, ("mapping %q already exists"):format(lhs)
  end
  local desc = opts.desc or ("OpenCode: " .. name)
  local mapping = {
    mode = "n",
    lhs = lhs,
    desc = desc,
    entry = {
      mode = "n",
      lhs = lhs,
      kind = "primitive",
      primitive = name,
      desc = desc,
    },
  }
  local count = opts.count ~= false
  local ok, err = pcall(vim.keymap.set, "n", lhs, function()
    local ok_run, run_error = self:execute(mapping.entry, count and vim.v.count1 or 1)
    if not ok_run and run_error then
      self:_notify("OpenCode: " .. tostring(run_error))
    end
  end, {
    buffer = self.buf,
    silent = true,
    nowait = true,
    noremap = true,
    desc = desc,
  })
  if not ok then
    return false, tostring(err)
  end
  self.custom[lhs] = mapping
  return true
end

--- @param lhs string
--- @return boolean removed
function Router:unmap(lhs)
  local mapping = self.custom[lhs]
  if not mapping then
    return false
  end
  if valid_buf(self.buf) and owned_mapping(self.buf, mapping) then
    pcall(vim.keymap.del, mapping.mode, mapping.lhs, { buffer = self.buf })
  end
  self.custom[lhs] = nil
  return true
end

--- @return table
function Router:get_state()
  return {
    attached = self.attached,
    buffer = self.buf,
    mappings = copy(self.entries),
    custom = copy(self.custom),
    focus = self.focus and type(self.focus.state) == "function" and copy(self.focus:state()) or nil,
  }
end

M.Router = Router

return M
