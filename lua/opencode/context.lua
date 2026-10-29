-- Visual selection context extraction and Markdown formatting.
--
-- This module is deliberately pure with respect to plugin state: it reads one
-- buffer through the Neovim API, never re-reads the file from disk, and never
-- talks to the network, session controller or UI.  Both selection actions use
-- exactly these functions so their context can never drift apart.
--
-- Public interface:
--
--   local ctx = context.from_selection(bufnr, {
--     mode = "v" | "V" | "\22" | "charwise" | "linewise" | "blockwise",
--     start = { row = 1, col = 1 },   -- anchor, 1-based, byte columns
--     ["end"] = { row = 1, col = 4 }, -- cursor, 1-based, byte columns
--     exclusive = false,
--   })
--   local text = context.format(ctx)
--   local selection = context.current_selection()
--
-- Positions may also be supplied as getpos()-style lists ({buf, lnum, col,
-- off}), as separate start_row/start_col/end_row/end_col fields, or with
-- `columns = "char"` to make `col` a 1-based character index.  `byte_col` and
-- `char_col` on an individual position always win over `col`.

local M = {}

local MODES = {
  v = "charwise",
  char = "charwise",
  charwise = "charwise",
  character = "charwise",
  V = "linewise",
  line = "linewise",
  linewise = "linewise",
  ["\22"] = "blockwise",
  ["\026"] = "blockwise",
  block = "blockwise",
  blockwise = "blockwise",
  ["<c-v>"] = "blockwise",
  ["ctrl-v"] = "blockwise",
  ["visual-block"] = "blockwise",
}

local function clamp(value, minimum, maximum)
  if value < minimum then
    return minimum
  end
  if value > maximum then
    return maximum
  end
  return value
end

local function normalize_mode(mode)
  if mode == nil or mode == "" then
    return "charwise"
  end
  if type(mode) ~= "string" then
    return nil
  end
  local exact = MODES[mode]
  if exact then
    return exact
  end
  return MODES[mode:lower()]
end

-- Length in bytes of the UTF-8 sequence starting at 1-based byte index col.
-- Invalid leading bytes are treated as one byte so arbitrary buffer contents
-- still produce deterministic output.
local function utf8_length(line, col)
  local byte = line:byte(col)
  if byte == nil then
    return 0
  end
  if byte < 0x80 then
    return 1
  elseif byte < 0xC0 then
    return 1
  elseif byte < 0xE0 then
    return 2
  elseif byte < 0xF0 then
    return 3
  elseif byte < 0xF8 then
    return 4
  end
  return 1
end

local function byte_col_from_char(line, char_col)
  if char_col == nil or char_col <= 1 then
    return 1
  end
  local byte = vim.fn.byteidx(line, char_col - 1)
  if type(byte) ~= "number" or byte < 0 then
    return #line + 1
  end
  return byte + 1
end

local function char_col_from_byte(line, byte_col)
  local byte0 = clamp((byte_col or 1) - 1, 0, #line)
  local index = vim.fn.charidx(line, byte0)
  if type(index) ~= "number" or index < 0 then
    return vim.fn.strchars(line) + 1
  end
  return index + 1
end

-- Turn one accepted position spelling into { row, col, units }.
local function position_from(value, default_units)
  if type(value) == "number" then
    return { row = value, col = 1, units = default_units or "byte" }
  end
  if type(value) ~= "table" then
    return nil
  end

  local row = value.row or value.line or value.lnum or value.start_row or value.start_line
  local col = value.col or value.column
  local units = value.units or value.columns or default_units or "byte"

  if value[1] ~= nil and type(value[1]) == "number" then
    if value[3] ~= nil then
      -- getpos()/getcurpos() list: { bufnr, lnum, col, off }.
      row = row or value[2]
      col = value[3]
      units = "byte"
    else
      -- Plain pair: { row, col }.
      row = row or value[1]
      col = col or value[2]
    end
  end

  local byte_col = value.byte_col or value.bytecol
  local char_col = value.char_col or value.charcol or value.character_col
  if byte_col ~= nil then
    col = byte_col
    units = "byte"
  elseif char_col ~= nil then
    col = char_col
    units = "char"
  end

  row = tonumber(row)
  col = tonumber(col)
  if row == nil then
    return nil
  end
  if col == nil then
    col = 1
  end

  return {
    row = row,
    col = col,
    units = units,
  }
end

local function positions_from(selection)
  if type(selection) ~= "table" then
    return nil, nil
  end

  local anchor = selection.start or selection.anchor or selection.from or selection.begin
  local cursor = selection["end"] or selection.stop or selection.finish or selection.to or selection.cursor

  if anchor == nil and type(selection[1]) == "table" then
    anchor = selection[1]
    cursor = cursor or selection[2]
  end

  if anchor == nil
    and (selection.start_row ~= nil or selection.start_line ~= nil or selection.line1 ~= nil)
  then
    anchor = {
      row = selection.start_row or selection.start_line or selection.line1,
      col = selection.start_col or selection.col1 or selection.start_column or 1,
      char_col = selection.start_char or selection.char1,
      byte_col = selection.start_byte or selection.byte1,
    }
    cursor = {
      row = selection.end_row or selection.end_line or selection.line2 or anchor.row,
      col = selection.end_col or selection.col2 or selection.end_column or anchor.col or 1,
      char_col = selection.end_char or selection.char2,
      byte_col = selection.end_byte or selection.byte2,
    }
  end

  if anchor == nil and (selection.row ~= nil or selection.line ~= nil or selection.lnum ~= nil) then
    anchor = selection
  end
  if anchor == nil then
    return nil, nil
  end
  if cursor == nil then
    cursor = anchor
  end
  return anchor, cursor
end

local function selection_mode(selection)
  return normalize_mode(selection.mode or selection.visual_mode or selection.visualmode)
end

local function selection_exclusive(selection)
  if selection.exclusive ~= nil then
    return selection.exclusive == true
  end
  local value = selection.selection or selection.selectmode
  if value ~= nil then
    return value == "exclusive"
  end
  return vim.o.selection == "exclusive"
end

local function resolve_buffer(buffer, selection)
  if buffer == nil or buffer == 0 then
    buffer = selection and (selection.buffer or selection.bufnr or selection.buf)
  end
  if buffer == nil or buffer == 0 then
    buffer = vim.api.nvim_get_current_buf()
  end
  if type(buffer) ~= "number" or not vim.api.nvim_buf_is_valid(buffer) then
    return nil, "selection buffer is not valid"
  end
  return buffer
end

local function relative_path(buffer)
  local name = vim.api.nvim_buf_get_name(buffer)
  if name == nil or name == "" then
    return "[No Name]", ""
  end
  local path = vim.fn.fnamemodify(name, ":.")
  if path == nil or path == "" then
    path = name
  end
  -- A newline in a buffer name would split the inline code span in two.
  path = path:gsub("[\r\n]", " ")
  return path, name
end

local function order_positions(anchor, cursor)
  if anchor.row < cursor.row or (anchor.row == cursor.row and anchor.col <= cursor.col) then
    return anchor, cursor
  end
  return cursor, anchor
end

local function position_info(line, position)
  return {
    row = position.row,
    col = position.col,
    byte_col = position.col,
    char_col = char_col_from_byte(line, position.col),
  }
end

local function linewise_text(buf, first, last)
  if last.row < first.row then
    return ""
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, first.row - 1, last.row, false)
  if not ok then
    return nil, tostring(lines)
  end
  return table.concat(lines, "\n")
end

local function charwise_text(buf, lines, first, last, exclusive)
  local start_line = lines[first.row]
  local start_col = math.min(first.col - 1, #start_line)
  local end_col

  local same = first.row == last.row and first.col == last.col
  if exclusive and not same then
    end_col = math.min(last.col - 1, #(lines[last.row] or ""))
  else
    local end_line = lines[last.row] or ""
    local end_byte = math.min(last.col, #end_line + 1)
    if end_byte > #end_line then
      end_col = #end_line
    else
      end_col = end_byte - 1 + math.max(utf8_length(end_line, end_byte), 1)
    end
  end

  if last.row < first.row or (last.row == first.row and end_col < start_col) then
    return ""
  end

  local ok, chunks = pcall(
    vim.api.nvim_buf_get_text,
    buf,
    first.row - 1,
    start_col,
    last.row - 1,
    end_col,
    {}
  )
  if not ok then
    return nil, tostring(chunks)
  end
  return table.concat(chunks or {}, "\n")
end

-- Character-indexed rectangular slices.  Used when the caller explicitly
-- says its columns are character columns.
local function block_text_chars(lines, first, last, exclusive)
  local start_char = math.min(first.char_col, last.char_col)
  local end_char = math.max(first.char_col, last.char_col)
  local single = start_char == end_char
  local out = {}
  for row = first.row, last.row do
    local line = lines[row] or ""
    local start_byte = byte_col_from_char(line, start_char) - 1
    local end_start = byte_col_from_char(line, end_char) - 1
    local end_byte
    if exclusive and not single then
      end_byte = math.min(#line, end_start)
    elseif end_start >= #line then
      end_byte = #line
    else
      end_byte = math.min(#line, end_start + math.max(utf8_length(line, end_start + 1), 1))
    end
    if start_byte >= #line then
      out[#out + 1] = ""
    else
      out[#out + 1] = line:sub(start_byte + 1, end_byte)
    end
  end
  return table.concat(out, "\n")
end

local function block_text_bytes(lines, first, last, exclusive)
  local start_col = math.min(first.col, last.col)
  local end_col = math.max(first.col, last.col)
  local single = first.char_col == last.char_col
  local out = {}
  for row = first.row, last.row do
    local line = lines[row] or ""
    local start_byte = math.min(math.max(start_col - 1, 0), #line)
    local end_start = math.min(math.max(end_col - 1, 0), #line)
    local end_byte
    if exclusive and not single then
      end_byte = end_start
    elseif end_start >= #line then
      end_byte = #line
    else
      end_byte = math.min(#line, end_start + math.max(utf8_length(line, end_start + 1), 1))
    end
    if start_byte >= #line then
      out[#out + 1] = ""
    else
      out[#out + 1] = line:sub(start_byte + 1, end_byte)
    end
  end
  return table.concat(out, "\n")
end

-- True Visual block selections are rectangular in screen cells, not bytes or
-- characters.  Use the window's virtual-column conversion when the buffer is
-- displayed; otherwise fall back to byte columns (identical for ASCII).
local function block_text_screen(buf, lines, first, last, exclusive)
  local win = vim.fn.win_findbuf(buf)[1]
  if not win or vim.fn.exists("*virtcol2col") == 0 then
    return block_text_bytes(lines, first, last, exclusive)
  end

  local function vcol_range(row, col)
    local line = lines[row] or ""
    if line == "" then
      return 1, 1
    end
    local ok, value = pcall(vim.fn.virtcol, { row, clamp(col, 1, #line) }, 1, win)
    if not ok or type(value) ~= "table" or type(value[1]) ~= "number" or type(value[2]) ~= "number" then
      return nil
    end
    return value[1], value[2]
  end

  local first_first, first_last = vcol_range(first.row, first.col)
  local last_first, last_last = vcol_range(last.row, last.col)
  if first_first == nil or last_first == nil then
    return block_text_bytes(lines, first, last, exclusive)
  end

  local start_vcol = math.min(first_first, last_first)
  local end_vcol = math.max(first_last, last_last)
  -- 'selection'=exclusive still keeps a one-character-wide block.  Use the
  -- character columns, not screen cells, so a wide character counted as two
  -- cells is not mistaken for a two-character block.
  local single = first.char_col == last.char_col
  local out = {}

  for row = first.row, last.row do
    local line = lines[row] or ""
    if line == "" then
      out[#out + 1] = ""
    else
      local _, line_last = vcol_range(row, #line)
      if line_last ~= nil and line_last < start_vcol then
        out[#out + 1] = ""
      else
        local ok_start, start_byte = pcall(vim.fn.virtcol2col, win, row, start_vcol)
        local ok_end, end_start = pcall(vim.fn.virtcol2col, win, row, end_vcol)
        if not ok_start or not ok_end then
          return block_text_bytes(lines, first, last, exclusive)
        end
        -- virtcol2col() returns a 1-based byte column; convert it to the
        -- 0-based byte offsets used by string.sub()/nvim_buf_get_text().
        start_byte = math.max((start_byte or 0) - 1, 0)
        end_start = math.max((end_start or 0) - 1, 0)
        if start_byte >= #line then
          out[#out + 1] = ""
        else
          local end_byte
          if exclusive and not single then
            end_byte = math.min(#line, end_start)
          elseif end_start >= #line then
            end_byte = #line
          else
            end_byte = math.min(#line, end_start + math.max(utf8_length(line, end_start + 1), 1))
          end
          if end_byte < start_byte + 1 then
            out[#out + 1] = ""
          else
            out[#out + 1] = line:sub(start_byte + 1, end_byte)
          end
        end
      end
    end
  end

  return table.concat(out, "\n")
end

local function block_text(buf, lines, first, last, exclusive, char_columns)
  if char_columns then
    return block_text_chars(lines, first, last, exclusive)
  end
  return block_text_screen(buf, lines, first, last, exclusive)
end

local function fence_for(text)
  local length = 3
  for run in tostring(text or ""):gmatch("`+") do
    if #run + 1 > length then
      length = #run + 1
    end
  end
  return string.rep("`", length)
end

local function inline_code(text)
  text = tostring(text or ""):gsub("[\r\n]", " ")
  local length = 0
  for run in text:gmatch("`+") do
    if #run > length then
      length = #run
    end
  end
  local delimiter = string.rep("`", length + 1)
  if text:sub(1, 1) == "`" or text:sub(-1) == "`" or text:find("^%s") or text:find("%s$") then
    return delimiter .. " " .. text .. " " .. delimiter
  end
  return delimiter .. text .. delimiter
end

local function safe_filetype(filetype)
  if type(filetype) ~= "string" or filetype == "" then
    return nil
  end
  local value = filetype:match("^[%w_+.-]+")
  if value == nil or value == "" then
    return nil
  end
  return value
end

--- Capture the active Visual selection as a plain selection table.
--
-- The returned table has fresh values only; it does not alias marks or cursor
-- state.  When called outside Visual mode the most recent '< and '> marks are
-- used, provided they belong to the current buffer.
--- @return table|nil
function M.current_selection()
  local visual_mode = vim.fn.mode()
  local in_visual = visual_mode == "v" or visual_mode == "V" or visual_mode == "\22"
  local buffer, start_pos, end_pos

  if in_visual then
    local anchor = vim.fn.getpos("v")
    local cursor = vim.fn.getpos(".")
    if anchor[2] == 0 then
      return nil
    end
    buffer = anchor[1]
    if buffer == nil or buffer == 0 then
      buffer = vim.api.nvim_get_current_buf()
    end
    start_pos = { row = anchor[2], col = anchor[3], units = "byte" }
    end_pos = { row = cursor[2], col = cursor[3], units = "byte" }
  else
    local anchor = vim.fn.getpos("'<")
    local cursor = vim.fn.getpos("'>")
    if anchor[2] == 0 or cursor[2] == 0 then
      return nil
    end
    buffer = anchor[1]
    if buffer == nil or buffer == 0 then
      buffer = vim.api.nvim_get_current_buf()
    end
    if buffer ~= vim.api.nvim_get_current_buf() then
      return nil
    end
    start_pos = { row = anchor[2], col = anchor[3], units = "byte" }
    end_pos = { row = cursor[2], col = cursor[3], units = "byte" }
    visual_mode = vim.fn.visualmode()
    if visual_mode == "" then
      visual_mode = "v"
    end
  end

  return {
    buffer = buffer,
    mode = visual_mode,
    start = start_pos,
    ["end"] = end_pos,
    exclusive = vim.o.selection == "exclusive",
    selection = vim.o.selection,
  }
end

--- Extract a selection from a buffer without touching disk or plugin state.
--- @param buffer integer|nil Buffer handle; defaults to the selection buffer.
--- @param selection table|nil Selection description; defaults to current Visual selection.
--- @return table|nil context
--- @return string|nil error
function M.from_selection(buffer, selection)
  if type(buffer) == "table" and selection == nil then
    selection = buffer
    buffer = nil
  end
  if selection == nil then
    selection = M.current_selection()
    if selection == nil then
      return nil, "no Visual selection is available"
    end
  end
  if type(selection) ~= "table" then
    return nil, "selection must be a table"
  end

  local resolved, buffer_error = resolve_buffer(buffer, selection)
  if not resolved then
    return nil, buffer_error
  end
  buffer = resolved

  local mode = selection_mode(selection)
  if mode == nil then
    return nil, "unsupported selection mode: " .. tostring(selection.mode)
  end

  local anchor, cursor = positions_from(selection)
  if anchor == nil or cursor == nil then
    return nil, "selection must include start and end positions"
  end

  local default_units = selection.columns or selection.col_units or "byte"
  local start_raw = position_from(anchor, default_units)
  local end_raw = position_from(cursor, default_units)
  if start_raw == nil or end_raw == nil then
    return nil, "selection positions must include a row"
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buffer, 0, -1, false)
  if not ok then
    return nil, "cannot read selection buffer: " .. tostring(lines)
  end
  if #lines == 0 then
    lines = { "" }
  end

  local function resolve_position(raw, label)
    if raw.row < 1 or raw.row > #lines then
      return nil, ("selection %s row %d is outside the buffer"):format(label, raw.row)
    end
    local line = lines[raw.row]
    local col = raw.col
    if raw.units == "char" then
      col = byte_col_from_char(line, col)
    end
    if col < 1 then
      col = 1
    end
    return {
      row = raw.row,
      col = col,
      char_col = char_col_from_byte(line, col),
    }
  end

  local start_pos, start_error = resolve_position(start_raw, "start")
  if not start_pos then
    return nil, start_error
  end
  local end_pos, end_error = resolve_position(end_raw, "end")
  if not end_pos then
    return nil, end_error
  end

  local first, last = order_positions(start_pos, end_pos)
  local exclusive = selection_exclusive(selection)

  local text
  if mode == "linewise" then
    first.col = 1
    first.char_col = 1
    last.col = math.max(#(lines[last.row] or ""), 1)
    last.char_col = char_col_from_byte(lines[last.row] or "", last.col)
    text, start_error = linewise_text(buffer, first, last)
    if text == nil then
      return nil, start_error
    end
  elseif mode == "blockwise" then
    local char_columns = default_units == "char"
      or start_raw.units == "char"
      or end_raw.units == "char"
    text = block_text(buffer, lines, first, last, exclusive, char_columns)
  else
    text, start_error = charwise_text(buffer, lines, first, last, exclusive)
    if text == nil then
      return nil, start_error
    end
  end

  local path, name = relative_path(buffer)
  local filetype = vim.bo[buffer].filetype
  if filetype == "" then
    filetype = nil
  end

  return {
    buffer = buffer,
    mode = mode,
    anchor = position_info(lines[start_pos.row] or "", start_pos),
    cursor = position_info(lines[end_pos.row] or "", end_pos),
    start = position_info(lines[first.row] or "", first),
    ["end"] = position_info(lines[last.row] or "", last),
    start_row = first.row,
    end_row = last.row,
    start_line = first.row,
    end_line = last.row,
    start_col = first.col,
    end_col = last.col,
    start_char = first.char_col,
    end_char = last.char_col,
    text = text,
    content = text,
    path = path,
    name = name,
    filetype = filetype,
    language = filetype or "",
    exclusive = exclusive,
  }
end

--- Format one extracted context as Markdown.  The location uses inline code
--- with a delimiter longer than any backtick run in the path; the code fence
--- is likewise one backtick longer than any run in the selected text.
--- @param selection_context table
--- @return string|nil text
--- @return string|nil error
function M.format(selection_context)
  if type(selection_context) ~= "table" then
    return nil, "selection context must be a table"
  end
  local path = selection_context.path
  if type(path) ~= "string" or path == "" then
    return nil, "selection context has no path"
  end
  local start_line = tonumber(selection_context.start_line)
  local end_line = tonumber(selection_context.end_line)
  if not start_line or not end_line then
    return nil, "selection context has no line range"
  end
  if end_line < start_line then
    start_line, end_line = end_line, start_line
  end

  local code = selection_context.text
  if type(code) ~= "string" then
    code = ""
  end

  local location
  if start_line == end_line then
    location = ("%s:%d"):format(path, start_line)
  else
    location = ("%s:%d-%d"):format(path, start_line, end_line)
  end

  local fence = fence_for(code)
  local language = safe_filetype(selection_context.filetype or selection_context.language)
  local opening = fence .. (language or "")
  local body
  if code == "" or code:sub(-1) == "\n" then
    body = opening .. "\n" .. code .. fence
  else
    body = opening .. "\n" .. code .. "\n" .. fence
  end

  return inline_code(location) .. "\n\n" .. body
end

--- Helpers kept public for regression tests and for other Markdown producers.
function M.safe_fence(text)
  return fence_for(text)
end

function M.inline_code(text)
  return inline_code(text)
end

return M
