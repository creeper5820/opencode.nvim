-- Encode parsed OpenCode/Neovim key strokes as bytes for a terminal PTY.
--
-- Neovim's `nvim_replace_termcodes()` is correct for mapping lhs strings, but
-- it returns internal K_SPECIAL placeholders for keys it cannot map through
-- the terminal (for example <S-Home>).  Sending those placeholders to a PTY is
-- wrong, so this module implements the common xterm/ANSI encodings directly
-- and reports unsupported modifier combinations instead of guessing.

local key = require("opencode.keybindings.key")

local M = {}

local CSI_KEYS = {
  up = { suffix = "A", code = "1" },
  down = { suffix = "B", code = "1" },
  right = { suffix = "C", code = "1" },
  left = { suffix = "D", code = "1" },
  home = { suffix = "H", code = "1" },
  ["end"] = { suffix = "F", code = "1" },
}

local TILDE_KEYS = {
  insert = "2",
  delete = "3",
  pageup = "5",
  pagedown = "6",
  f5 = "15",
  f6 = "17",
  f7 = "18",
  f8 = "19",
  f9 = "20",
  f10 = "21",
  f11 = "23",
  f12 = "24",
}

local F1_F4 = { f1 = "P", f2 = "Q", f3 = "R", f4 = "S" }

local PLAIN = {
  escape = "\27",
  ["return"] = "\r",
  tab = "\t",
  backspace = "\127",
  space = " ",
  ["lt"] = "<",
  ["bar"] = "|",
  ["bslash"] = "\\",
  ["comma"] = ",",
  ["plus"] = "+",
}

local SHIFT_SYMBOLS = {
  ["1"] = "!",
  ["2"] = "@",
  ["3"] = "#",
  ["4"] = "$",
  ["5"] = "%",
  ["6"] = "^",
  ["7"] = "&",
  ["8"] = "*",
  ["9"] = "(",
  ["0"] = ")",
  ["`"] = "~",
  ["-"] = "_",
  ["="] = "+",
  ["["] = "{",
  ["]"] = "}",
  ["\\"] = "|",
  [";"] = ":",
  ["'"] = '"',
  [","] = "<",
  ["."] = ">",
  ["/"] = "?",
}

local CTRL_SYMBOLS = {
  ["@"] = 0,
  ["2"] = 0,
  ["space"] = 0,
  ["["] = 27,
  ["3"] = 27,
  ["\\"] = 28,
  ["4"] = 28,
  ["]"] = 29,
  ["5"] = 29,
  ["^"] = 30,
  ["6"] = 30,
  ["_"] = 31,
  ["7"] = 31,
  ["/"] = 31,
  ["?"] = 127,
}

local function modifier_parameter(stroke)
  local value = 1
  if stroke.shift then
    value = value + 1
  end
  if stroke.meta then
    value = value + 2
  end
  if stroke.ctrl then
    value = value + 4
  end
  return value
end

local function has_modifier(stroke)
  -- Shift is folded into printable characters, but matters for navigation,
  -- function keys and Enter/Tab.
  return stroke.ctrl or stroke.meta or stroke.shift
end

local function ctrl_byte(name)
  if CTRL_SYMBOLS[name] ~= nil then
    return string.char(CTRL_SYMBOLS[name])
  end
  if #name == 1 then
    local byte = name:byte()
    if byte >= 64 and byte <= 95 then
      return string.char(byte - 64)
    end
    if byte >= 97 and byte <= 122 then
      return string.char(byte - 96)
    end
  end
  return nil
end

local function shifted_printable(name)
  if SHIFT_SYMBOLS[name] then
    return SHIFT_SYMBOLS[name]
  end
  if name:match("^%a$") then
    return name:upper()
  end
  return name
end

local function encode_printable(stroke)
  local name = stroke.name
  if stroke.super or stroke.hyper then
    return nil, "super/hyper keys cannot be encoded for a terminal PTY"
  end

  local text = name == "space" and " " or name
  if stroke.shift then
    text = shifted_printable(text)
  end

  if stroke.ctrl and (stroke.shift or stroke.meta) and #name == 1 then
    return ("\27[%d;%du"):format(name:byte(), modifier_parameter(stroke))
  end

  if stroke.ctrl then
    local control = ctrl_byte(name)
    if not control then
      if #name == 1 then
        -- Legacy terminals have no control byte for punctuation.  CSI-u is
        -- the standard modern encoding and is understood by OpenCode's TUI.
        local parameter = modifier_parameter(stroke)
        return ("\27[%d;%du"):format(name:byte(), parameter)
      end
      return nil, ("ctrl+%s cannot be encoded for a terminal PTY"):format(name)
    end
    if stroke.meta then
      return "\27" .. control
    end
    return control
  end
  if stroke.meta then
    return "\27" .. text
  end
  return text
end

local function encode_modified_special(stroke, base)
  local parameter = modifier_parameter(stroke)
  if parameter == 1 then
    return base
  end
  -- CSI-u is the most reliable representation for modified navigation keys
  -- when the outer terminal supports the kitty keyboard protocol.  OpenCode's
  -- TUI accepts both xterm modifier parameters and CSI-u sequences.
  local codepoint = ({
    escape = 27,
    ["return"] = 13,
    tab = 9,
    backspace = 127,
  })[stroke.name]
  if codepoint then
    return ("\27[%d;%du"):format(codepoint, parameter)
  end
  return nil
end

local function encode_special(stroke)
  local name = stroke.name
  if name == "escape" then
    if stroke.ctrl or stroke.meta or stroke.shift then
      return encode_modified_special(stroke, "\27")
    end
    return "\27"
  end
  if name == "return" then
    if stroke.ctrl or stroke.meta or stroke.shift then
      return encode_modified_special(stroke, "\r")
    end
    return "\r"
  end
  if name == "tab" then
    if stroke.ctrl or stroke.meta then
      return encode_modified_special(stroke, "\t")
    end
    if stroke.shift then
      return "\27[Z"
    end
    return "\t"
  end
  if name == "backspace" then
    if stroke.ctrl or stroke.meta then
      return encode_modified_special(stroke, "\127")
    end
    return "\127"
  end
  if name == "space" then
    return encode_printable(stroke)
  end
  if PLAIN[name] then
    if stroke.ctrl or stroke.meta or stroke.shift then
      return encode_modified_special(stroke, PLAIN[name])
    end
    return PLAIN[name]
  end

  if stroke.super or stroke.hyper then
    return nil, "super/hyper keys cannot be encoded for a terminal PTY"
  end

  local csi = CSI_KEYS[name]
  if csi then
    if has_modifier(stroke) then
      return ("\27[%s;%d%s"):format(csi.code, modifier_parameter(stroke), csi.suffix)
    end
    return "\27[" .. csi.suffix
  end

  local tilde = TILDE_KEYS[name]
  if tilde then
    if has_modifier(stroke) then
      return ("\27[%s;%d~"):format(tilde, modifier_parameter(stroke))
    end
    return ("\27[%s~"):format(tilde)
  end

  local f1 = F1_F4[name]
  if f1 then
    if has_modifier(stroke) then
      return ("\27[1;%d%s"):format(modifier_parameter(stroke), f1)
    end
    return "\27O" .. f1
  end

  local f_number = tonumber(name:match("^f(%d+)$") or "")
  if f_number and f_number >= 13 and f_number <= 24 then
    local code = 24 + f_number
    if has_modifier(stroke) then
      return ("\27[%d;%d~"):format(code, modifier_parameter(stroke))
    end
    return ("\27[%d~"):format(code)
  end

  return nil, ("unsupported terminal key %q"):format(name)
end

--- Encode one key stroke as PTY input bytes.
--- @param stroke table
--- @return string|nil bytes, string|nil error
function M.stroke(stroke)
  if type(stroke) ~= "table" or type(stroke.name) ~= "string" then
    return nil, "invalid key stroke"
  end
  if stroke.super or stroke.hyper then
    return nil, "super/hyper keys cannot be encoded for a terminal PTY"
  end
  local special = encode_special(stroke)
  if special ~= nil then
    return special
  end
  if #stroke.name == 1 then
    return encode_printable(stroke)
  end
  -- Multi-character names not recognized as special keys are unsafe to send.
  return nil, ("unsupported terminal key %q"):format(stroke.name)
end

--- Encode a complete stroke sequence and return the Neovim mapping lhs.
--- @param strokes table[]
--- @return string|nil bytes
--- @return string|nil lhs
--- @return string|nil error
function M.sequence(strokes)
  if type(strokes) ~= "table" or #strokes == 0 then
    return nil, nil, "empty key sequence"
  end
  local lhs, lhs_error = key.to_lhs(strokes)
  if not lhs then
    return nil, nil, lhs_error
  end
  local parts = {}
  for _, stroke in ipairs(strokes) do
    local bytes, err = M.stroke(stroke)
    if not bytes then
      return nil, nil, err
    end
    parts[#parts + 1] = bytes
  end
  return table.concat(parts), lhs, nil
end

return M
