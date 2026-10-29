-- Composer editing primitives.
--
-- The OpenCode TUI owns the real prompt editor.  In terminal Normal mode this
-- module translates a small, explicit set of Vim-like motions/deletions into
-- the TUI's own input commands (resolved from the effective cli.json), then
-- sends them over the terminal channel.  It never redraws the prompt and never
-- changes the logical focus region.

local keybindings = require("opencode.keybindings")

local M = {}

local UP = "\27[A"
local DOWN = "\27[B"
local RIGHT = "\27[C"
local LEFT = "\27[D"
local HOME = "\27[H"
local END = "\27[F"
local PAGE_UP = "\27[5~"
local PAGE_DOWN = "\27[6~"
local CTRL_RIGHT = "\27[1;5C"
local CTRL_LEFT = "\27[1;5D"
local ALT_F = "\27f"
local ALT_B = "\27b"
local ALT_D = "\27d"

-- Each definition may use a different native OpenCode command per region and
-- a literal terminal fallback when that command is disabled in cli.json.
local DEFINITIONS = {
  char_left = {
    description = "Move one character left",
    composer = { command = "input_move_left", fallback = LEFT },
    session = { fallback = LEFT },
  },
  char_right = {
    description = "Move one character right",
    composer = { command = "input_move_right", fallback = RIGHT },
    session = { fallback = RIGHT },
  },
  line_up = {
    description = "Move one line up",
    composer = { command = "input_move_up", fallback = UP },
    session = { command = "messages_line_up", fallback = UP },
  },
  line_down = {
    description = "Move one line down",
    composer = { command = "input_move_down", fallback = DOWN },
    session = { command = "messages_line_down", fallback = DOWN },
  },
  word_forward = {
    description = "Move to the next word",
    composer = { command = "input_word_forward", fallback = CTRL_RIGHT },
    session = { fallback = PAGE_DOWN },
  },
  word_backward = {
    description = "Move to the previous word",
    composer = { command = "input_word_backward", fallback = CTRL_LEFT },
    session = { fallback = PAGE_UP },
  },
  word_end = {
    description = "Move to the end of the word",
    composer = { command = "input_word_forward", fallback = ALT_F },
    session = { fallback = PAGE_DOWN },
  },
  line_start = {
    description = "Move to the start of the line",
    composer = { command = "input_line_home", fallback = HOME },
    session = { command = "messages_first", fallback = HOME },
  },
  line_end = {
    description = "Move to the end of the line",
    composer = { command = "input_line_end", fallback = END },
    session = { command = "messages_last", fallback = END },
  },
  buffer_start = {
    description = "Move to the first line/message",
    composer = { command = "input_buffer_home", fallback = HOME },
    session = { command = "messages_first", fallback = HOME },
  },
  buffer_end = {
    description = "Move to the last line/message",
    composer = { command = "input_buffer_end", fallback = END },
    session = { command = "messages_last", fallback = END },
  },
  page_up = {
    description = "Page up within the current region",
    composer = { fallback = PAGE_UP },
    session = { command = "messages_page_up", fallback = PAGE_UP },
  },
  page_down = {
    description = "Page down within the current region",
    composer = { fallback = PAGE_DOWN },
    session = { command = "messages_page_down", fallback = PAGE_DOWN },
  },
  half_page_up = {
    description = "Half-page up within the current region",
    composer = { fallback = PAGE_UP },
    session = { command = "messages_half_page_up", fallback = PAGE_UP },
  },
  half_page_down = {
    description = "Half-page down within the current region",
    composer = { fallback = PAGE_DOWN },
    session = { command = "messages_half_page_down", fallback = PAGE_DOWN },
  },
  first = {
    description = "Jump to the first message/line",
    composer = { command = "input_buffer_home", fallback = HOME },
    session = { command = "messages_first", fallback = HOME },
  },
  last = {
    description = "Jump to the last message/line",
    composer = { command = "input_buffer_end", fallback = END },
    session = { command = "messages_last", fallback = END },
  },
  delete_char = {
    description = "Delete the character under the cursor",
    composer = { command = "input_delete", fallback = "\27[3~" },
  },
  delete_char_backward = {
    description = "Delete the character before the cursor",
    composer = { command = "input_backspace", fallback = "\127" },
  },
  delete_line = {
    description = "Delete the current composer line",
    composer = { command = "input_delete_line", fallback = "\21" },
  },
  delete_word_forward = {
    description = "Delete the next word",
    composer = { command = "input_delete_word_forward", fallback = ALT_D },
  },
  delete_word_backward = {
    description = "Delete the previous word",
    composer = { command = "input_delete_word_backward", fallback = "\23" },
  },
  delete_to_line_end = {
    description = "Delete to the end of the line",
    composer = { command = "input_delete_to_line_end", fallback = "\11" },
  },
  delete_to_line_start = {
    description = "Delete to the start of the line",
    composer = { command = "input_delete_to_line_start", fallback = "\21" },
  },
  newline = {
    description = "Insert a newline in the composer",
    composer = { command = "input_newline", fallback = "\10" },
  },
  submit = {
    description = "Submit the composer",
    composer = { command = "input_submit", fallback = "\r" },
  },
  clear = {
    description = "Clear the composer",
    composer = { command = "input_clear", fallback = "\3" },
  },
  history_previous = {
    description = "Previous composer history",
    composer = { command = "history_previous", fallback = UP },
  },
  history_next = {
    description = "Next composer history",
    composer = { command = "history_next", fallback = DOWN },
  },
  undo = {
    description = "Undo composer edit",
    composer = { command = "input_undo", fallback = "\31" },
  },
  redo = {
    description = "Redo composer edit",
    composer = { command = "input_redo", fallback = "\27." },
  },
}

M.definitions = DEFINITIONS

--- Normal-mode keys handled by primitives when they are not already bound by
--- an effective OpenCode keybinding.  `d` and `c` are operators handled by the
--- router because they read one following motion key.
M.keys = {
  { "h", "char_left" },
  { "l", "char_right" },
  { "k", "line_up" },
  { "j", "line_down" },
  { "w", "word_forward" },
  { "b", "word_backward" },
  { "e", "word_end" },
  { "0", "line_start" },
  { "^", "line_start" },
  { "$", "line_end" },
  { "gg", "buffer_start" },
  { "G", "buffer_end" },
  { "<C-d>", "half_page_down" },
  { "<C-u>", "half_page_up" },
  { "<C-f>", "page_down" },
  { "<C-b>", "page_up" },
  { "<PageDown>", "page_down" },
  { "<PageUp>", "page_up" },
  { "<Home>", "first" },
  { "<End>", "last" },
  { "x", "delete_char" },
  { "X", "delete_char_backward" },
  { "D", "delete_to_line_end" },
  { "C", "delete_to_line_end" },
  { "u", "undo" },
  { "<C-r>", "redo" },
  { "<CR>", "submit" },
  { "o", "newline" },
}

local function valid_count(count)
  if count == nil then
    return 1
  end
  if type(count) ~= "number" or count < 1 then
    return nil
  end
  return math.floor(count)
end

local function command_bytes(ctx, command)
  if not command or type(ctx.keybindings) ~= "table" then
    return nil
  end
  local binding = ctx.keybindings.bindings[command]
  if type(binding) ~= "table" or binding.disabled then
    return nil
  end
  local alternative = binding.alternatives and binding.alternatives[1]
  if not alternative then
    return nil
  end
  return keybindings.alternative_bytes(alternative)
end

local function region_of(ctx)
  if ctx.focus and type(ctx.focus.get) == "function" then
    local ok, region = pcall(ctx.focus.get, ctx.focus)
    if ok and (region == "composer" or region == "session") then
      return region
    end
  end
  return ctx.region or "composer"
end

local function bytes_for(name, ctx)
  local definition = DEFINITIONS[name]
  if not definition then
    return nil, ("unknown primitive %q"):format(tostring(name))
  end
  local region = region_of(ctx)
  local spec = definition[region]
  if not spec then
    return nil, ("primitive %q is not available in the %s region"):format(name, region)
  end
  local bytes = command_bytes(ctx, spec.command)
  if bytes then
    return bytes, region
  end
  if spec.fallback then
    return spec.fallback, region
  end
  return nil, ("primitive %q has no terminal input for the %s region"):format(name, region)
end

--- Apply one named primitive.  Count is forwarded by repeating the native
--- TUI input operation; the logical focus region is never changed.
--- @param name string
--- @param count number|nil
--- @param ctx table { channel, focus, keybindings }
--- @return boolean ok
--- @return string|nil error
function M.apply(name, count, ctx)
  ctx = ctx or {}
  count = valid_count(count)
  if count == nil then
    return false, "primitive count must be a positive integer"
  end
  local bytes, region_or_error = bytes_for(name, ctx)
  if not bytes then
    return false, region_or_error
  end
  local channel = ctx.channel
  if not channel or type(channel.send) ~= "function" then
    return false, "terminal input channel is not available"
  end
  if type(channel.is_alive) == "function" then
    local ok, alive = pcall(channel.is_alive, channel)
    if not ok or not alive then
      return false, "OpenCode terminal is not running"
    end
  end
  for _ = 1, count do
    local ok, err = channel:send(bytes)
    if not ok then
      return false, tostring(err or "cannot send terminal input")
    end
  end
  return true
end

--- Delete/change operator motions.  The router reads the motion key (Vim's
--- `d{motion}` shape) and delegates here; tests can call this directly.
--- @param operator "delete"|"change"
--- @param motion string
--- @param count number|nil
--- @param ctx table
--- @return boolean ok
--- @return string|nil error
function M.operator(operator, motion, count, ctx)
  ctx = ctx or {}
  count = valid_count(count)
  if count == nil then
    return false, "operator count must be a positive integer"
  end
  local primitive
  if motion == operator:sub(1, 1) then
    primitive = "delete_line"
  elseif motion == "w" or motion == "W" or motion == "e" or motion == "E" then
    primitive = "delete_word_forward"
  elseif motion == "b" or motion == "B" then
    primitive = "delete_word_backward"
  elseif motion == "$" then
    primitive = "delete_to_line_end"
  elseif motion == "0" or motion == "^" then
    primitive = "delete_to_line_start"
  elseif motion == "h" then
    primitive = "delete_char_backward"
  elseif motion == "l" or motion == " " then
    primitive = "delete_char"
  elseif motion == "j" or motion == "k" then
    primitive = "delete_line"
  end
  if not primitive then
    return false, ("unsupported %s motion %q"):format(operator, tostring(motion))
  end
  local ok, err = M.apply(primitive, count, ctx)
  if not ok then
    return false, err
  end
  if operator == "change" then
    -- Entering Insert is a Neovim mode switch, not a focus heuristic.  It
    -- lets the user continue typing in the official TUI composer.
    pcall(vim.cmd, "startinsert")
  end
  return true
end

--- @param region string|nil
--- @return string[]
function M.names(region)
  local result = {}
  for name, definition in pairs(DEFINITIONS) do
    if region == nil or definition[region] ~= nil then
      result[#result + 1] = name
    end
  end
  table.sort(result)
  return result
end

--- @param name string
--- @return table|nil
function M.get(name)
  local definition = DEFINITIONS[name]
  if not definition then
    return nil
  end
  local result = {}
  for key, value in pairs(definition) do
    result[key] = value
  end
  return result
end

return M
