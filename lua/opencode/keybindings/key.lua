-- OpenCode key syntax -> Neovim lhs conversion.
--
-- OpenCode V2 accepts a string (comma-separated alternatives), an array of
-- alternatives, an object with a `key` field, or a key object
-- (`{ name = "x", ctrl = true }`).  This module intentionally implements a
-- small, explicit subset:
--
--   * modifiers: ctrl/control, shift, meta/alt/option, super
--   * named keys and single printable characters
--   * comma-separated alternatives
--   * space-separated or concatenated multi-key sequences
--   * `<leader>` expansion supplied by the caller
--   * Neovim-style `<...>` tokens in overrides (e.g. `<Esc>`, `<C-x>`)
--
-- Anything else is reported as a non-blocking diagnostic.  There is no
-- guessing: an unsupported key is skipped, never translated to a random key.

local M = {}

local MODIFIER_NAMES = {
  ctrl = "ctrl",
  control = "ctrl",
  shift = "shift",
  meta = "meta",
  alt = "meta",
  option = "meta",
  super = "super",
  hyper = "hyper",
}

-- Names accepted in both OpenCode and ordinary Neovim mapping syntax.
local SPECIAL_NAMES = {
  escape = "escape",
  esc = "escape",
  ["return"] = "return",
  enter = "return",
  cr = "return",
  tab = "tab",
  backspace = "backspace",
  bs = "backspace",
  delete = "delete",
  del = "delete",
  insert = "insert",
  ins = "insert",
  space = "space",
  up = "up",
  down = "down",
  left = "left",
  right = "right",
  home = "home",
  ["end"] = "end",
  pageup = "pageup",
  pgup = "pageup",
  pagedown = "pagedown",
  pgdown = "pagedown",
  lt = "<",
  bar = "|",
  bslash = "\\",
  comma = ",",
  plus = "+",
}

local SPECIAL_NAMES_ORDERED = {}
for name in pairs(SPECIAL_NAMES) do
  SPECIAL_NAMES_ORDERED[#SPECIAL_NAMES_ORDERED + 1] = name
end
table.sort(SPECIAL_NAMES_ORDERED, function(left, right)
  if #left == #right then
    return left < right
  end
  return #left > #right
end)

local NEOVIM_SPECIAL = {
  escape = "escape",
  esc = "escape",
  cr = "return",
  ["return"] = "return",
  enter = "return",
  tab = "tab",
  bs = "backspace",
  backspace = "backspace",
  del = "delete",
  delete = "delete",
  insert = "insert",
  ins = "insert",
  space = "space",
  up = "up",
  down = "down",
  left = "left",
  right = "right",
  home = "home",
  ["end"] = "end",
  pageup = "pageup",
  pgup = "pageup",
  pagedown = "pagedown",
  pgdown = "pagedown",
  lt = "<",
  bar = "|",
  bslash = "\\",
  comma = ",",
  plus = "+",
}

local STROKE_FIELDS = { "name", "ctrl", "shift", "meta", "super", "hyper" }

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lower(value)
  return value:lower()
end

local function fkey(name)
  local number = name:match("^f(%d+)$")
  if not number then
    return nil
  end
  local value = tonumber(number)
  if value and value >= 1 and value <= 24 then
    return "f" .. value
  end
  return nil
end

--- Normalize one key name, or return nil when it is not a supported name.
--- @param name string
--- @return string|nil
function M.normalize_name(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local lowered = lower(name)
  local special = SPECIAL_NAMES[lowered]
  if special then
    return special
  end
  local number = fkey(lowered)
  if number then
    return number
  end
  if vim.fn.strchars(name) == 1 then
    return name
  end
  return nil
end

local function is_modifier(name)
  return MODIFIER_NAMES[lower(name)]
end

local function named_at(input, index)
  if index > #input then
    return nil
  end
  local first = input:sub(index, index)
  if first == "f" or first == "F" then
    local digits = input:sub(index + 1):match("^(%d+)")
    if digits then
      local number = tonumber(digits)
      if number and number >= 1 and number <= 24 then
        return "f" .. number, 1 + #digits
      end
      -- A full f-number that is out of range is malformed, not a sequence.
      if #digits > 0 then
        return nil, nil, ("function key F%s is outside F1-F24"):format(digits)
      end
    end
  end

  local rest = input:sub(index)
  local lowered = lower(rest)
  for _, name in ipairs(SPECIAL_NAMES_ORDERED) do
    if lowered:sub(1, #name) == name then
      return SPECIAL_NAMES[name], #name
    end
  end
  return nil
end

local function single_char_at(input, index)
  local byte = input:byte(index)
  if not byte then
    return nil
  end
  if byte >= 128 then
    return nil, "non-ASCII key is not supported"
  end
  return input:sub(index, index), 1
end

local function new_stroke(name, flags)
  flags = flags or {}
  return {
    name = name,
    ctrl = flags.ctrl == true,
    shift = flags.shift == true,
    meta = flags.meta == true,
    super = flags.super == true,
    hyper = flags.hyper == true,
  }
end

local function parse_neovim_token(content)
  local lowered = lower(content)
  local special = NEOVIM_SPECIAL[lowered]
  if special then
    return new_stroke(special)
  end
  local function_key = fkey(lowered)
  if function_key then
    return new_stroke(function_key)
  end

  -- <C-S-x>, <M-F2>, <D-x> and the common single-letter aliases.
  local rest = content
  local flags = {}
  while true do
    local modifier, tail = rest:match("^([CcSsMmAaDdTt])%-(.+)$")
    if not modifier then
      break
    end
    local key = lower(modifier)
    if key == "c" then
      flags.ctrl = true
    elseif key == "s" then
      flags.shift = true
    elseif key == "d" then
      flags.super = true
    else
      flags.meta = true
    end
    rest = tail
  end

  local name = M.normalize_name(rest)
  if not name then
    return nil, ("unsupported key token <%s>"):format(content)
  end
  return new_stroke(name, flags)
end

local function parse_token(content, leader_strokes)
  if lower(content) == "leader" then
    if not leader_strokes or #leader_strokes == 0 then
      return nil, "<leader> is used but no leader key is configured"
    end
    local strokes = {}
    for _, stroke in ipairs(leader_strokes) do
      strokes[#strokes + 1] = vim.deepcopy(stroke)
    end
    return strokes
  end
  local stroke, err = parse_neovim_token(content)
  if not stroke then
    return nil, err
  end
  return { stroke }
end

local function parse_word(word, leader_strokes)
  local strokes = {}
  local index = 1
  while index <= #word do
    local char = word:sub(index, index)
    if char == "<" then
      local close = word:find(">", index + 1, true)
      if not close then
        -- A lone '<' is a literal key; it cannot start a token.
        strokes[#strokes + 1] = new_stroke("<")
        index = index + 1
      else
        local token = word:sub(index + 1, close - 1)
        local parts, err = parse_token(token, leader_strokes)
        if not parts then
          return nil, err
        end
        vim.list_extend(strokes, parts)
        index = close + 1
      end
    else
      local flags = {}
      local consumed = false
      while true do
        local modifier, rest = word:sub(index):match("^(%a+)%+(.*)$")
        if not modifier then
          break
        end
        local normalized = is_modifier(modifier)
        if not normalized then
          break
        end
        flags[normalized] = true
        index = index + #modifier + 1
        consumed = true
        if index > #word then
          return nil, "modifier has no key name"
        end
      end

      local name, length, err = named_at(word, index)
      if not name then
        if err then
          return nil, err
        end
        local char_error
        name, length, char_error = single_char_at(word, index)
        if not name then
          return nil, char_error or "empty key"
        end
      end
      strokes[#strokes + 1] = new_stroke(name, flags)
      index = index + length
      consumed = consumed or length > 0
      if not consumed then
        return nil, "empty key"
      end
    end
  end
  return strokes
end

local function same_stroke(left, right)
  for _, field in ipairs(STROKE_FIELDS) do
    if left[field] ~= right[field] then
      return false
    end
  end
  return true
end

M.same_stroke = same_stroke

local function all_same(strokes)
  if #strokes <= 1 then
    return false
  end
  for index = 2, #strokes do
    if not same_stroke(strokes[1], strokes[index]) then
      return false
    end
  end
  return true
end

--- Convert one stroke to the Neovim key notation used in a mapping lhs.
--- @param stroke table
--- @return string|nil lhs, string|nil error
function M.stroke_to_lhs(stroke)
  if stroke.hyper then
    return nil, "the hyper modifier is not supported by Neovim mappings"
  end

  local name = stroke.name
  local base
  if name == "<" then
    base = "<lt>"
  elseif name == "|" then
    base = "<Bar>"
  elseif name == "\\" then
    base = "<Bslash>"
  elseif name == "," then
    base = "<Comma>"
  elseif name == "+" then
    base = "<Plus>"
  elseif name == "space" then
    base = "<Space>"
  elseif name == "return" then
    base = "<CR>"
  elseif name == "escape" then
    base = "<Esc>"
  elseif name == "tab" then
    base = "<Tab>"
  elseif name == "backspace" then
    base = "<BS>"
  elseif name == "delete" then
    base = "<Del>"
  elseif name == "insert" then
    base = "<Insert>"
  elseif name == "up" then
    base = "<Up>"
  elseif name == "down" then
    base = "<Down>"
  elseif name == "left" then
    base = "<Left>"
  elseif name == "right" then
    base = "<Right>"
  elseif name == "home" then
    base = "<Home>"
  elseif name == "end" then
    base = "<End>"
  elseif name == "pageup" then
    base = "<PageUp>"
  elseif name == "pagedown" then
    base = "<PageDown>"
  else
    local function_key = fkey(name)
    if function_key then
      base = "<F" .. function_key:sub(2) .. ">"
    elseif vim.fn.strchars(name) == 1 then
      base = name
    else
      return nil, ("unsupported key name %q"):format(tostring(name))
    end
  end

  local modifiers = {}
  if stroke.ctrl then
    modifiers[#modifiers + 1] = "C"
  end
  if stroke.shift then
    modifiers[#modifiers + 1] = "S"
  end
  if stroke.meta then
    modifiers[#modifiers + 1] = "M"
  end
  if stroke.super then
    modifiers[#modifiers + 1] = "D"
  end

  -- A shifted printable letter is just its uppercase character on a normal
  -- terminal.  Keeping <S-a> would make Neovim normalize it to "A" anyway.
  if stroke.shift and #modifiers == 1 and vim.fn.strchars(name) == 1 and name:match("%a") then
    return name:upper()
  end

  if #modifiers == 0 then
    return base
  end

  local inner = base:match("^<(.*)>$")
  if not inner then
    inner = base
  end
  return "<" .. table.concat(modifiers, "-") .. "-" .. inner .. ">"
end

--- Convert a stroke sequence to a complete Neovim mapping lhs.
--- @param strokes table[]
--- @return string|nil lhs, string|nil error
function M.to_lhs(strokes)
  local parts = {}
  for _, stroke in ipairs(strokes) do
    local lhs, err = M.stroke_to_lhs(stroke)
    if not lhs then
      return nil, err
    end
    parts[#parts + 1] = lhs
  end
  return table.concat(parts)
end

local function key_object_stroke(value)
  if type(value.name) ~= "string" then
    return nil, "key object requires a string name"
  end
  local name = M.normalize_name(value.name)
  if not name then
    return nil, ("unsupported key name %q"):format(value.name)
  end
  local flags = {}
  for _, field in ipairs({ "ctrl", "control", "shift", "meta", "alt", "super", "hyper" }) do
    if value[field] ~= nil and type(value[field]) ~= "boolean" then
      return nil, ("key object field %q must be a boolean"):format(field)
    end
  end
  flags.ctrl = value.ctrl == true or value.control == true
  flags.shift = value.shift == true
  flags.meta = value.meta == true or value.alt == true
  flags.super = value.super == true
  flags.hyper = value.hyper == true
  return new_stroke(name, flags)
end

local function parse_sequence(value, leader_strokes)
  if type(value) ~= "string" then
    return nil, "key must be a string"
  end
  value = trim(value)
  if value == "" then
    return nil, "key must not be empty"
  end

  local words = {}
  for word in value:gmatch("%S+") do
    words[#words + 1] = word
  end
  if #words == 0 then
    return nil, "key must not be empty"
  end

  local strokes = {}
  for _, word in ipairs(words) do
    local parts, err = parse_word(word, leader_strokes)
    if not parts then
      return nil, err
    end
    vim.list_extend(strokes, parts)
  end
  if #strokes == 0 then
    return nil, "key sequence is empty"
  end
  return strokes
end

local function make_alternative(strokes)
  local lhs, err = M.to_lhs(strokes)
  if not lhs then
    return nil, err
  end
  return {
    lhs = lhs,
    first_lhs = nil, -- filled below
    strokes = strokes,
    count = #strokes,
    repeated = all_same(strokes),
  }
end

local function finish_alternative(alternative)
  local first, err = M.stroke_to_lhs(alternative.strokes[1])
  if not first then
    return nil, err
  end
  alternative.first_lhs = first
  return alternative
end

local function parse_item(item, leader_strokes)
  if type(item) == "string" then
    local strokes, err = parse_sequence(item, leader_strokes)
    if not strokes then
      return nil, err
    end
    return make_alternative(strokes)
  end
  if type(item) ~= "table" then
    return nil, "binding item must be a string or object"
  end

  local key = item.key
  if key == nil and item.name ~= nil then
    key = item
  end
  if key == nil then
    return nil, "binding object requires a key"
  end
  if item.event ~= nil and item.event ~= "press" then
    return nil, ("release event %q is not supported in Neovim mappings"):format(tostring(item.event))
  end

  if type(key) == "table" then
    local stroke, err = key_object_stroke(key)
    if not stroke then
      return nil, err
    end
    return make_alternative({ stroke })
  end
  if type(key) ~= "string" then
    return nil, "binding object key must be a string or key object"
  end
  local strokes, err = parse_sequence(key, leader_strokes)
  if not strokes then
    return nil, err
  end
  return make_alternative(strokes)
end

local function split_alternatives(value)
  -- A lone comma is a literal comma key.  Otherwise commas separate
  -- alternatives, matching OpenCode V2's binding syntax.
  if value == "," then
    return { "," }
  end
  local parts = {}
  for part in (value .. ","):gmatch("([^,]*),") do
    part = trim(part)
    if part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return parts
end

--- Parse one OpenCode binding value.
---
--- @param value any
--- @param opts table|nil { leader_strokes = table[] }
--- @return table result { disabled = boolean|nil, alternatives = table[], diagnostics = table[] }
function M.parse_binding(value, opts)
  opts = opts or {}
  local leader_strokes = opts.leader_strokes
  local diagnostics = {}
  local alternatives = {}
  local seen = {}

  local function add(alternative)
    local finished, err = finish_alternative(alternative)
    if not finished then
      diagnostics[#diagnostics + 1] = {
        level = "warn",
        code = "unsupported_key",
        key = alternative.lhs,
        message = ("cannot convert %q to a Neovim key: %s"):format(alternative.lhs, err),
      }
      return
    end
    if seen[finished.lhs] then
      return
    end
    seen[finished.lhs] = true
    alternatives[#alternatives + 1] = finished
  end

  if value == false or (type(value) == "string" and lower(trim(value)) == "none") then
    return { disabled = true, alternatives = {}, diagnostics = diagnostics }
  end

  if type(value) == "string" then
    local parts = split_alternatives(value)
    if #parts == 0 then
      diagnostics[#diagnostics + 1] = {
        level = "warn",
        code = "invalid_binding",
        key = value,
        message = "key binding is empty",
      }
      return { alternatives = {}, diagnostics = diagnostics }
    end
    for _, part in ipairs(parts) do
      local strokes, err = parse_sequence(part, leader_strokes)
      if not strokes then
        diagnostics[#diagnostics + 1] = {
          level = "warn",
          code = "unsupported_key",
          key = part,
          message = ("cannot convert %q: %s"):format(part, err),
        }
      else
        local alternative, alt_err = make_alternative(strokes)
        if not alternative then
          diagnostics[#diagnostics + 1] = {
            level = "warn",
            code = "unsupported_key",
            key = part,
            message = ("cannot convert %q: %s"):format(part, alt_err),
          }
        else
          add(alternative)
        end
      end
    end
    return { alternatives = alternatives, diagnostics = diagnostics }
  end

  if type(value) ~= "table" then
    diagnostics[#diagnostics + 1] = {
      level = "warn",
      code = "invalid_binding",
      message = ("key binding must be a string, array, object, false or \"none\"; got %s"):format(type(value)),
    }
    return { alternatives = {}, diagnostics = diagnostics }
  end

  local items
  if vim.islist(value) then
    items = value
  else
    items = { value }
  end
  if #items == 0 then
    return { disabled = true, alternatives = {}, diagnostics = diagnostics }
  end

  for _, item in ipairs(items) do
    if type(item) == "string" then
      local parts = split_alternatives(item)
      for _, part in ipairs(parts) do
        local strokes, err = parse_sequence(part, leader_strokes)
        if not strokes then
          diagnostics[#diagnostics + 1] = {
            level = "warn",
            code = "unsupported_key",
            key = part,
            message = ("cannot convert %q: %s"):format(part, err),
          }
        else
          local alternative, alt_err = make_alternative(strokes)
          if not alternative then
            diagnostics[#diagnostics + 1] = {
              level = "warn",
              code = "unsupported_key",
              key = part,
              message = ("cannot convert %q: %s"):format(part, alt_err),
            }
          else
            add(alternative)
          end
        end
      end
    else
      local alternative, err = parse_item(item, leader_strokes)
      if not alternative then
        diagnostics[#diagnostics + 1] = {
          level = "warn",
          code = "invalid_binding",
          message = tostring(err),
        }
      else
        add(alternative)
      end
    end
  end

  return { alternatives = alternatives, diagnostics = diagnostics }
end

--- Parse a leader binding value.  The first alternative is used as the
--- leader; all of its strokes are retained so `<leader>` can expand to a
--- multi-stroke prefix.
--- @param value any
--- @param opts table|nil
--- @return table|nil strokes, table diagnostics
function M.parse_leader(value, opts)
  local result = M.parse_binding(value, opts)
  if result.disabled then
    return nil, result.diagnostics
  end
  if #result.alternatives == 0 then
    return nil, result.diagnostics
  end
  return vim.deepcopy(result.alternatives[1].strokes), result.diagnostics
end

return M
