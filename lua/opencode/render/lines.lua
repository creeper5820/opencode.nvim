-- Convert structured blocks into display lines for the message buffer.
-- This module is pure: it never touches buffers, windows or folds.
--
-- build(roots, opts) returns:
--   lines      = { string }                    -- complete timeline, never ANSI
--   highlights = { {line, start_col, end_col, group} }
--   folds      = { {id, start_line, end_line, default_open} }
--   blocks     = { {id, start_line, end_line, root} }
--
-- opts.max_lines applies an explicit first-screen limit to long text sections.
-- The hidden remainder is always kept in the buffer and is reachable through
-- the generated <fold-id>:rest fold.

local M = {}

local function normalize_newlines(text)
  return (tostring(text):gsub("\r\n", "\n"):gsub("\r", "\n"))
end

local function split_lines(text)
  if text == nil then
    return {}
  end
  text = normalize_newlines(text)
  if text == "" then
    return {}
  end
  local out = {}
  local start = 1
  while true do
    local pos = text:find("\n", start, true)
    if not pos then
      out[#out + 1] = text:sub(start)
      break
    end
    out[#out + 1] = text:sub(start, pos - 1)
    start = pos + 1
    if start > #text then
      out[#out + 1] = ""
      break
    end
  end
  return out
end

local function single_line(value)
  local text = type(value) == "string" and value or tostring(value or "")
  text = normalize_newlines(text)
  text = text:gsub("%s*\n%s*", " ")
  return text
end

local function truncate(text, limit)
  if #text <= limit then
    return text
  end
  return text:sub(1, math.max(0, limit - 3)) .. "..."
end

local function stringify(value)
  if value == nil then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  if type(value) == "number" or type(value) == "boolean" then
    return tostring(value)
  end
  local ok, encoded = pcall(vim.json.encode, value)
  if ok and type(encoded) == "string" then
    return encoded
  end
  local inspected_ok, inspected = pcall(vim.inspect, value)
  if inspected_ok then
    return inspected
  end
  return tostring(value)
end

local function first_value(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil and value ~= "" then
      return value
    end
  end
  return nil
end

local function as_list(value)
  if value == nil then
    return {}
  end
  if type(value) ~= "table" then
    return { value }
  end
  if #value > 0 then
    return value
  end
  if next(value) == nil then
    return {}
  end
  local out = {}
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    out[#out + 1] = value[key]
  end
  return out
end

-- Return an array for a field that normally stores a list, but also accept a
-- single object (for example `files = { path = ..., hunks = ... }`).
local function as_items(value, keys)
  if value == nil then
    return {}
  end
  if type(value) ~= "table" then
    return { value }
  end
  if #value > 0 then
    return value
  end
  if next(value) == nil then
    return {}
  end
  for _, key in ipairs(keys or {}) do
    if value[key] ~= nil then
      return { value }
    end
  end
  return as_list(value)
end

local function add_hl(out, line, start_col, end_col, group)
  out.highlights[#out.highlights + 1] = {
    line = line,
    start_col = start_col,
    end_col = end_col,
    group = group,
  }
end

local function add_section(out, section)
  local lines = split_lines(section.text)
  local indent = section.indent or ""
  local first = #out.lines + 1
  local rest_id = section.rest_fold_id
  if section.fold and section.fold.id then
    rest_id = section.fold.id .. ":rest"
  end

  local shown = #lines
  local hidden = nil
  local max_lines = section.max_lines
  if type(max_lines) == "number" and max_lines > 0 and #lines > max_lines and rest_id then
    shown = max_lines
    hidden = {}
    for index = shown + 1, #lines do
      hidden[#hidden + 1] = lines[index]
    end
  end

  for index = 1, shown do
    out.lines[#out.lines + 1] = indent .. lines[index]
  end

  if hidden then
    local marker = #out.lines + 1
    out.lines[#out.lines + 1] = indent .. "… " .. #hidden .. " more lines (za to expand)"
    add_hl(out, marker, 0, -1, "OpencodeMuted")
    for _, line in ipairs(hidden) do
      out.lines[#out.lines + 1] = indent .. line
    end
    out.folds[#out.folds + 1] = {
      id = rest_id,
      start_line = marker,
      end_line = #out.lines,
      default_open = false,
      kind = "rest",
    }
  end

  local fold_start = first
  if section.fold and section.fold.start_line ~= nil then
    fold_start = section.fold.start_line
  end
  if section.fold and section.fold.id and #out.lines > fold_start then
    out.folds[#out.folds + 1] = {
      id = section.fold.id,
      start_line = fold_start,
      end_line = #out.lines,
      default_open = section.fold.default_open ~= false,
      kind = "section",
    }
  end

  return first, #out.lines
end

local function status_marker(status)
  local value = tostring(status or ""):lower()
  if value:match("permission") or value:match("waiting") or value:match("ask") then
    return "?"
  elseif value:match("stream") or value:match("run") or value:match("pending") or value:match("progress") then
    return "…"
  elseif value:match("fail") or value:match("error") or value:match("interrupt") then
    return "✗"
  elseif value:match("complete") or value:match("success") or value:match("done") then
    return "✓"
  end
  return ""
end

local function with_prefix(text, prefix)
  text = tostring(text or "")
  if text:sub(1, 1) == prefix then
    return text
  end
  return prefix .. text
end

local function diff_line_text(line)
  if type(line) == "string" then
    if line == "" then
      return ""
    end
    local first = line:sub(1, 1)
    if first == "+" or first == "-" or first == " " or first == "\\" then
      return line
    end
    return " " .. line
  end
  if type(line) ~= "table" then
    return tostring(line)
  end
  local text = line.text
  if text == nil then
    text = line.content
  end
  if text == nil then
    text = line.value
  end
  if text == nil then
    text = line.line
  end
  local kind = line.type or line.kind or line.op
  if text == nil and type(line[1]) == "string" then
    kind = line[1]
    text = line[2]
  end
  if text == nil then
    return nil
  end
  text = tostring(text)
  if kind == "add" or kind == "insert" or kind == "addition" or kind == "added" then
    return with_prefix(text, "+")
  elseif kind == "remove" or kind == "delete" or kind == "deletion" or kind == "removed" then
    return with_prefix(text, "-")
  elseif kind == "context" or kind == "normal" or kind == "unchanged" then
    return with_prefix(text, " ")
  end
  local first = text:sub(1, 1)
  if first == "+" or first == "-" or first == " " or first == "\\" then
    return text
  end
  return " " .. text
end

local function append_text(lines, text)
  for _, line in ipairs(split_lines(text)) do
    lines[#lines + 1] = line
  end
end

local function append_hunk(lines, hunk)
  if type(hunk) == "string" then
    append_text(lines, hunk)
    return
  end
  if type(hunk) ~= "table" then
    return
  end

  local header = hunk.header or hunk.title
  if header == nil then
    local old_start = hunk.old_start or hunk.oldStart
    local new_start = hunk.new_start or hunk.newStart
    if old_start ~= nil or new_start ~= nil then
      local old_count = hunk.old_count or hunk.oldCount or hunk.old_lines or 1
      local new_count = hunk.new_count or hunk.newCount or hunk.new_lines or 1
      header = ("@@ -%s,%s +%s,%s @@"):format(
        tostring(old_start or 0),
        tostring(old_count),
        tostring(new_start or 0),
        tostring(new_count)
      )
    end
  end
  if header ~= nil and tostring(header) ~= "" then
    lines[#lines + 1] = single_line(header)
  end

  if hunk.lines == nil and type(hunk.text) == "string" then
    append_text(lines, hunk.text)
    return
  end

  local items = as_items(hunk.lines, { "text", "content", "type", "kind" })
  for _, line in ipairs(items) do
    local text = diff_line_text(line)
    if text ~= nil then
      lines[#lines + 1] = text
    end
  end
end

local function append_file(lines, file, fallback_path)
  if type(file) == "string" then
    append_text(lines, file)
    return
  end
  if type(file) ~= "table" then
    return
  end

  local path = file.path or file.file or file.filename or file.name or fallback_path or "file"
  path = single_line(path)
  if path == "" then
    path = "file"
  end

  local raw = file.diff or file.patch
  if type(raw) ~= "string" and type(file.content) == "string" then
    local value = file.content
    if value:find("\n", 1, true) or value:match("^@@") or value:match("^%-%-%-") then
      raw = value
    end
  end

  if type(raw) == "string" and raw ~= "" then
    local raw_lines = split_lines(raw)
    local first = raw_lines[1] or ""
    if first:match("^@@") then
      lines[#lines + 1] = "diff --git a/" .. path .. " b/" .. path
      lines[#lines + 1] = "--- a/" .. path
      lines[#lines + 1] = "+++ b/" .. path
    elseif not (first:match("^diff %-%-git ") or first:match("^%-%-%- ")) then
      lines[#lines + 1] = "diff --git a/" .. path .. " b/" .. path
    end
    for _, line in ipairs(raw_lines) do
      lines[#lines + 1] = line
    end
    return
  end

  local status = file.status or file.type
  lines[#lines + 1] = "diff --git a/" .. path .. " b/" .. path
  if status == "added" or status == "new" then
    lines[#lines + 1] = "--- /dev/null"
  else
    lines[#lines + 1] = "--- a/" .. path
  end
  if status == "deleted" or status == "removed" then
    lines[#lines + 1] = "+++ /dev/null"
  else
    lines[#lines + 1] = "+++ b/" .. path
  end

  for _, hunk in ipairs(as_items(file.hunks, { "header", "lines", "text" })) do
    append_hunk(lines, hunk)
  end
end

-- Convert the supported diff shapes (raw patch string, 05C
-- {files={{path=...,hunks=...}}}, or a single file object) into text lines.
local function diff_lines(value, default_path)
  local lines = {}
  if value == nil then
    return lines
  end
  if type(value) == "string" then
    append_text(lines, value)
    return lines
  end
  if type(value) ~= "table" then
    append_text(lines, tostring(value))
    return lines
  end

  if value.files ~= nil then
    for _, file in ipairs(as_items(value.files, {
      "path", "file", "filename", "hunks", "diff", "patch",
    })) do
      append_file(lines, file, default_path)
    end
    return lines
  end

  if value.path ~= nil or value.file ~= nil or value.filename ~= nil or value.hunks ~= nil then
    append_file(lines, value, default_path)
    return lines
  end

  if value.diff ~= nil and value.diff ~= value then
    return diff_lines(value.diff, default_path)
  end
  if value.patch ~= nil and value.patch ~= value then
    return diff_lines(value.patch, default_path)
  end
  if value.content ~= nil or value.text ~= nil then
    local raw = value.content
    if raw == nil then
      raw = value.text
    end
    if type(raw) == "string" then
      append_text(lines, raw)
    else
      return diff_lines(raw, default_path)
    end
    return lines
  end

  if #value > 0 then
    local first = value[1]
    if type(first) == "table"
      and (first.path ~= nil or first.file ~= nil or first.hunks ~= nil or first.diff ~= nil) then
      for _, file in ipairs(value) do
        append_file(lines, file, default_path)
      end
    elseif type(first) == "string"
      and (first:match("^diff %-%-git ") or first:match("^%-%-%- ") or first:match("^%+%+%+ ") or first:match("^@@")) then
      for _, line in ipairs(value) do
        lines[#lines + 1] = tostring(line)
      end
    else
      for _, line in ipairs(value) do
        local text = diff_line_text(line)
        if text ~= nil then
          lines[#lines + 1] = text
        end
      end
    end
    return lines
  end

  append_text(lines, stringify(value))
  return lines
end

local function diff_title(block)
  local metadata = block.metadata or {}
  local value = metadata.file or metadata.path or metadata.filename
  if value ~= nil then
    value = single_line(value)
    if value ~= "" then
      return value
    end
  end

  local content = block.content
  if type(content) == "table" then
    local files = as_items(content.files, { "path", "file", "filename", "hunks" })
    local first = files[1]
    if type(first) == "table" then
      local path = first.path or first.file or first.filename
      if path ~= nil then
        path = single_line(path)
        if path ~= "" then
          return path
        end
      end
    end
    local path = content.file or content.path or content.filename
    if path ~= nil then
      path = single_line(path)
      if path ~= "" then
        return path
      end
    end
  end
  return "Diff"
end

local function tool_data(block)
  local metadata = block.metadata or {}
  local part = type(metadata.part) == "table" and metadata.part or {}
  local state = type(part.state) == "table" and part.state or {}
  local content = type(block.content) == "table" and block.content or nil
  return metadata, part, state, content
end

local function tool_name(block, metadata, part)
  local raw = first_value(metadata.tool, metadata.name, part.tool, part.name, block.tool)
  if raw == nil and type(block.content) == "string" then
    raw = block.content
  elseif raw == nil and type(block.content) == "table" then
    raw = first_value(block.content.tool, block.content.name)
  end
  if type(raw) == "table" then
    raw = first_value(raw.name, raw.tool)
  end
  local name = truncate(single_line(raw or "tool"), 60)
  if name == "" then
    name = "tool"
  end
  return name
end

local function tool_input(metadata, part, state, content)
  return first_value(
    metadata.input,
    metadata.arguments,
    part.input,
    part.arguments,
    state.input,
    state.arguments,
    content and (content.input or content.arguments)
  )
end

local function tool_output(metadata, part, state, content)
  return first_value(
    metadata.output,
    metadata.result,
    part.output,
    part.result,
    state.output,
    state.result,
    content and (content.output or content.result)
  )
end

local function tool_diff(metadata, part, state, content)
  local state_metadata = type(state.metadata) == "table" and state.metadata or {}
  return first_value(
    metadata.diff,
    metadata.patch,
    part.diff,
    part.patch,
    state.diff,
    state.patch,
    state_metadata.diff,
    state_metadata.patch,
    content and (content.diff or content.patch)
  )
end

local function error_text(value)
  if value == nil or value == "" then
    return nil
  end
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    local message = first_value(value.message, value.msg, value.error, value.data and value.data.message)
    if message ~= nil then
      return type(message) == "string" and message or stringify(message)
    end
    return stringify(value)
  end
  return tostring(value)
end

local function tool_error(block, metadata, part, state, content)
  local value = first_value(
    metadata.error,
    metadata.message,
    part.error,
    state.error,
    content and content.error
  )
  local text = error_text(value)
  if text == nil and (block.status == "failed" or block.status == "error") then
    text = error_text(metadata.result or metadata.output)
  end
  return text
end

local function tool_summary(block, metadata, part, content, state)
  local summary = first_value(metadata.title, metadata.summary)
  if summary == nil then
    local input = tool_input(metadata, part, state or {}, content)
    if type(input) == "table" then
      summary = first_value(
        input.filePath,
        input.file,
        input.path,
        input.filename,
        input.pattern,
        input.command,
        input.query,
        input.url,
        input.description
      )
      if summary == nil then
        summary = stringify(input)
      end
    elseif input ~= nil then
      summary = stringify(input)
    end
  end
  if summary == nil then
    return ""
  end
  return truncate(single_line(summary), 80)
end

local function apply_diff_highlights(out, first, last, indent)
  local col = #(indent or "")
  for lnum = first, last do
    local line = out.lines[lnum] or ""
    local body = line:sub(col + 1)
    if body:match("^@@") then
      add_hl(out, lnum, col, -1, "OpencodeDiffHunk")
    elseif body:match("^%+%+%+") or body:match("^%-%-%-") or body:match("^diff %-%-git ") or body:match("^index ") then
      add_hl(out, lnum, col, -1, "OpencodeDiffFile")
    elseif body:match("^%+") then
      add_hl(out, lnum, col, -1, "OpencodeDiffAdd")
    elseif body:match("^%-") then
      add_hl(out, lnum, col, -1, "OpencodeDiffDelete")
    elseif body:match("^ ") or body == "" then
      add_hl(out, lnum, col, -1, "OpencodeDiffContext")
    elseif body:match("^\\") then
      add_hl(out, lnum, col, -1, "OpencodeMuted")
    end
  end
end

local function render_diff_section(out, value, opts)
  local lines = diff_lines(value, opts.path)
  if #lines == 0 then
    return false
  end

  local label_line = nil
  if opts.label ~= nil then
    label_line = #out.lines + 1
    out.lines[#out.lines + 1] = opts.label
    add_hl(out, label_line, opts.label_col or 0, -1, "OpencodeSection")
  end

  local fold = opts.fold
  if fold ~= nil and label_line ~= nil then
    fold = {
      id = fold.id,
      default_open = fold.default_open,
      start_line = label_line,
    }
  end

  local first, last = add_section(out, {
    text = table.concat(lines, "\n"),
    indent = opts.indent or "",
    max_lines = opts.max_lines,
    rest_fold_id = opts.rest_fold_id,
    fold = fold,
  })
  apply_diff_highlights(out, first, last, opts.indent or "")
  return true, first, last
end

local function highlight_markdown(out, first, last)
  local in_code = false
  for lnum = first, last do
    local line = out.lines[lnum] or ""
    if line:match("^%s*```") then
      in_code = not in_code
      add_hl(out, lnum, 0, -1, "OpencodeCode")
    elseif in_code then
      add_hl(out, lnum, 0, -1, "OpencodeCode")
    elseif line:match("^%s*#+%s") then
      add_hl(out, lnum, 0, -1, "OpencodeHeading")
    end
  end
end

local function render_user(out, block, opts)
  local header_line = #out.lines + 1
  out.lines[#out.lines + 1] = "▌ User"
  add_hl(out, header_line, 0, -1, "OpencodeUser")

  add_section(out, {
    text = stringify(block.content),
    indent = "  ",
    max_lines = opts.max_lines,
    rest_fold_id = block.id .. ":rest",
  })
  out.lines[#out.lines + 1] = ""
end

local function render_assistant(out, block, opts)
  local first, last = add_section(out, {
    text = stringify(block.content),
    indent = "",
    max_lines = opts.max_lines,
    rest_fold_id = block.id .. ":rest",
  })
  if last >= first then
    highlight_markdown(out, first, last)
  end
  out.lines[#out.lines + 1] = ""
end

local function render_reasoning(out, block, opts)
  local header = "▸ Reasoning"
  if block.status == "streaming" or block.status == "running" then
    header = header .. " …"
  end
  local header_line = #out.lines + 1
  out.lines[#out.lines + 1] = header
  add_hl(out, header_line, 0, -1, "OpencodeReasoning")

  add_section(out, {
    text = stringify(block.content),
    indent = "  ",
    max_lines = opts.max_lines,
    rest_fold_id = block.id .. ":rest",
  })
  out.lines[#out.lines + 1] = ""

  if #out.lines > header_line then
    out.folds[#out.folds + 1] = {
      id = block.id,
      start_line = header_line,
      end_line = #out.lines,
      default_open = false,
      kind = "block",
    }
  end
end

local function render_tool(out, block, opts)
  local metadata, part, state, content = tool_data(block)
  local name = tool_name(block, metadata, part)
  local summary = tool_summary(block, metadata, part, content, state)
  local error_message = tool_error(block, metadata, part, state, content)
  local marker = status_marker(block.status)

  local header = "▼ " .. name
  if summary ~= "" then
    header = header .. "  " .. summary
  end
  if error_message ~= nil and (block.status == "failed" or block.status == "error") then
    header = header .. "  " .. truncate(single_line(error_message), 60)
  end
  if marker ~= "" then
    header = header .. "  " .. marker
  end

  local header_line = #out.lines + 1
  out.lines[#out.lines + 1] = header
  local name_col = #"▼ "
  add_hl(out, header_line, 0, #"▼", "OpencodeFold")
  add_hl(out, header_line, name_col, name_col + #name, "OpencodeToolName")
  if #header > name_col + #name then
    add_hl(out, header_line, name_col + #name, -1, "OpencodeMuted")
  end
  if error_message ~= nil and (block.status == "failed" or block.status == "error") then
    add_hl(out, header_line, 0, -1, "OpencodeError")
  elseif marker == "✗" then
    add_hl(out, header_line, math.max(0, #header - #marker), #header, "OpencodeError")
  elseif marker == "✓" then
    add_hl(out, header_line, math.max(0, #header - #marker), #header, "OpencodeStatus")
  end

  local input = tool_input(metadata, part, state, content)
  local output = tool_output(metadata, part, state, content)
  local diff = tool_diff(metadata, part, state, content)

  if input ~= nil and input ~= "" then
    local label_line = #out.lines + 1
    out.lines[#out.lines + 1] = "  Input"
    add_hl(out, label_line, 2, 7, "OpencodeSection")
    add_section(out, {
      text = stringify(input),
      indent = "    ",
      max_lines = opts.max_lines,
      fold = { id = block.id .. ":input", default_open = false, start_line = label_line },
    })
  end

  if output ~= nil and output ~= "" then
    local label_line = #out.lines + 1
    out.lines[#out.lines + 1] = "  Output"
    add_hl(out, label_line, 2, 8, "OpencodeSection")
    local first, last = add_section(out, {
      text = stringify(output),
      indent = "    ",
      max_lines = opts.max_lines,
      fold = { id = block.id .. ":output", default_open = true, start_line = label_line },
    })
    if block.status == "failed" or block.status == "error" then
      if last >= first then
        for lnum = first, last do
          add_hl(out, lnum, 0, -1, "OpencodeError")
        end
      end
    end
  end

  if diff ~= nil and diff ~= "" then
    render_diff_section(out, diff, {
      label = "  Diff",
      label_col = 2,
      indent = "    ",
      path = metadata.file or metadata.path,
      max_lines = opts.max_lines,
      fold = { id = block.id .. ":diff", default_open = true },
    })
  end

  if error_message ~= nil and error_message ~= "" then
    local error_lines = split_lines(error_message)
    if #error_lines > 0 then
      local error_line = #out.lines + 1
      out.lines[#out.lines + 1] = "  Error: " .. error_lines[1]
      add_hl(out, error_line, 0, -1, "OpencodeError")
      if #error_lines > 1 then
        local rest = {}
        for index = 2, #error_lines do
          rest[#rest + 1] = error_lines[index]
        end
        local first, last = add_section(out, {
          text = table.concat(rest, "\n"),
          indent = "    ",
          max_lines = opts.max_lines,
          fold = { id = block.id .. ":error", default_open = true, start_line = error_line },
        })
        if last >= first then
          for lnum = first, last do
            add_hl(out, lnum, 0, -1, "OpencodeError")
          end
        end
      end
    end
  end

  out.folds[#out.folds + 1] = {
    id = block.id,
    start_line = header_line,
    end_line = #out.lines,
    default_open = true,
    kind = "block",
  }
  out.lines[#out.lines + 1] = ""
end

local function render_diff(out, block, opts)
  local title = diff_title(block)
  local header = title == "Diff" and "▼ Diff" or "▼ Diff " .. title
  local header_line = #out.lines + 1
  out.lines[#out.lines + 1] = header
  add_hl(out, header_line, 0, -1, "OpencodeDiffFile")

  local body = block.content
  if body == nil or body == "" or (type(body) == "table" and next(body) == nil) then
    local metadata = block.metadata or {}
    body = metadata.diff or metadata.patch
  end
  render_diff_section(out, body, {
    indent = "  ",
    path = title ~= "Diff" and title or nil,
    max_lines = opts.max_lines,
    rest_fold_id = block.id .. ":rest",
  })

  out.lines[#out.lines + 1] = ""
  if #out.lines > header_line then
    out.folds[#out.folds + 1] = {
      id = block.id,
      start_line = header_line,
      end_line = #out.lines,
      default_open = true,
      kind = "block",
    }
  end
end

local function render_status(out, block)
  local metadata = block.metadata or {}
  local label = metadata.label or metadata.title or block.content or block.status or "status"
  if type(label) == "table" then
    label = stringify(label)
  end
  label = single_line(label)
  if metadata.kind == "permission" and not label:match("^Permission") then
    label = "Permission: " .. label
  end

  local marker = status_marker(block.status)
  local line = "● " .. label
  if marker ~= "" then
    line = line .. " " .. marker
  end

  local lnum = #out.lines + 1
  out.lines[#out.lines + 1] = line
  add_hl(out, lnum, 0, -1, block.status == "failed" and "OpencodeError" or "OpencodeStatus")
  out.lines[#out.lines + 1] = ""
end

local function render_unknown(out, block, opts)
  local header_line = #out.lines + 1
  out.lines[#out.lines + 1] = "▸ Unknown event"
  add_hl(out, header_line, 0, -1, "OpencodeUnknown")

  local body = block.content
  if body == nil then
    body = ""
  elseif type(body) ~= "string" then
    body = stringify(body)
  end

  local metadata = block.metadata or {}
  if metadata.raw ~= nil or metadata.data ~= nil then
    local detail = stringify({ raw = metadata.raw, data = metadata.data })
    if body ~= "" then
      body = body .. "\n" .. detail
    else
      body = detail
    end
  end

  add_section(out, {
    text = body,
    indent = "  ",
    max_lines = opts.max_lines,
    rest_fold_id = block.id .. ":rest",
  })
  out.lines[#out.lines + 1] = ""

  if #out.lines > header_line then
    out.folds[#out.folds + 1] = {
      id = block.id,
      start_line = header_line,
      end_line = #out.lines,
      default_open = false,
      kind = "block",
    }
  end
end

local function render_block(out, block, opts)
  local block_type = tostring(block.type or "unknown"):lower()
  if block_type == "user" then
    render_user(out, block, opts)
  elseif block_type == "assistant" then
    render_assistant(out, block, opts)
  elseif block_type == "reasoning" then
    render_reasoning(out, block, opts)
  elseif block_type == "tool" then
    render_tool(out, block, opts)
  elseif block_type == "diff" or block_type == "patch" then
    render_diff(out, block, opts)
  elseif block_type == "status" then
    render_status(out, block, opts)
  else
    render_unknown(out, block, opts)
  end
end

function M.build(roots, opts)
  opts = opts or {}
  local out = {
    lines = {},
    highlights = {},
    folds = {},
    blocks = {},
  }
  local seen = {}

  local function build_one(block, root)
    if type(block) ~= "table" or seen[block] then
      return
    end
    seen[block] = true

    local start_line = #out.lines + 1
    render_block(out, block, opts)
    for _, child in ipairs(block.children or {}) do
      if type(child) == "table" then
        build_one(child, false)
      end
    end
    local end_line = #out.lines
    for _, fold in ipairs(out.folds) do
      if fold.id == block.id and fold.end_line < end_line then
        fold.end_line = end_line
      end
    end
    out.blocks[#out.blocks + 1] = {
      id = tostring(block.id),
      start_line = start_line,
      end_line = math.max(start_line, end_line),
      root = root,
    }
  end

  for _, block in ipairs(roots or {}) do
    if type(block) == "table" then
      build_one(block, true)
    end
  end

  local folds = {}
  local fold_ids = {}
  for _, fold in ipairs(out.folds) do
    if fold.end_line > fold.start_line and not fold_ids[fold.id] then
      fold_ids[fold.id] = true
      folds[#folds + 1] = fold
    end
  end
  out.folds = folds
  return out
end

function M.split_lines(text)
  return split_lines(text)
end

function M.diff_lines(value, default_path)
  return diff_lines(value, default_path)
end

return M
