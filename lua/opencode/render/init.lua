-- Structured conversation renderer for the read-only message buffer.
-- Renders block trees produced by the block model; never parses SSE or ANSI.
--
-- Public API:
--   renderer.attach({ buffer = buf, window = win, opts = { max_lines = n },
--                     lookup = function(id) return block end })
--   renderer.reset(blocks)          -- list/map/tree, or { blocks = ... }
--   renderer.apply_change(change)   -- { upsert = block|list, removed = ids }
--                                    -- or a 05C { changed = [...], removed = [...] }
--   renderer.open_block(id[, win]) / close_block(id[, win]) / toggle_block(id[, win])
--   renderer.attach_window(win) / detach_window(win) / detach()
--
-- Fold and view state is kept per (window, block id). `lookup` is optional and
-- resolves children stored as string IDs (the 05C snapshot shape).

local lines_mod = require("opencode.render.lines")

local M = {}

local ns_hl = vim.api.nvim_create_namespace("opencode_render_hl")
local ns_anchor = vim.api.nvim_create_namespace("opencode_render_anchor")

local HIGHLIGHTS = {
  OpencodeUser = { link = "Title" },
  OpencodeAssistant = { link = "Normal" },
  OpencodeHeading = { link = "Title" },
  OpencodeReasoning = { link = "Comment" },
  OpencodeToolName = { link = "Function" },
  OpencodeSection = { link = "Special" },
  OpencodeDiffFile = { link = "Directory" },
  OpencodeDiffHunk = { link = "Special" },
  OpencodeDiffAdd = { link = "DiffAdd" },
  OpencodeDiffDelete = { link = "DiffDelete" },
  OpencodeDiffContext = { link = "Comment" },
  OpencodeStatus = { link = "DiagnosticInfo" },
  OpencodeError = { link = "DiagnosticError" },
  OpencodeMuted = { link = "Comment" },
  OpencodeUnknown = { link = "WarningMsg" },
  OpencodeFold = { link = "Folded" },
  OpencodeCode = { link = "String" },
}

local state = {
  attached = false,
  buffer = nil,
  primary_window = nil,
  windows = {},
  window_opts = {},
  augroup = nil,
  blocks = {},
  roots = {},
  order_counter = 0,
  opts = {},
  lookup = nil,
  lines = {},
  layout = {},
  folds = {},
  fold_by_id = {},
  fold_state = {},
  marks = {},
  highlights_ready = false,
}

local function ensure_highlights()
  for name, spec in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, spec))
  end
end

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function buffer_ok()
  return state.attached and valid_buf(state.buffer)
end

local function window_on_buffer(win)
  return valid_win(win) and buffer_ok() and vim.api.nvim_win_get_buf(win) == state.buffer
end

local function clamp(value, low, high)
  return math.max(low, math.min(value, high))
end

local function resolve_lookup(lookup, id)
  if lookup == nil then
    return nil
  end
  if type(lookup) == "function" then
    local ok, value = pcall(lookup, id)
    if ok and type(value) == "table" then
      return value
    end
    return nil
  end
  if type(lookup) == "table" then
    local value = lookup[id]
    if type(value) ~= "table" and type(lookup.find) == "function" then
      local ok, found = pcall(lookup.find, lookup, id)
      if ok then
        value = found
      end
    end
    if type(value) == "table" then
      return value
    end
  end
  return nil
end

local function is_block_like(value)
  if type(value) ~= "table" then
    return false
  end
  return value.id ~= nil or value.type ~= nil
end

local function collect_input(input, lookup, start_order)
  local entries = {}
  local pending_parent = {}
  local resolving = {}
  local order = start_order or 0

  local add
  add = function(block, inline_parent)
    if type(block) ~= "table" then
      return nil
    end

    local raw_id = block.id
    local id
    if raw_id == nil then
      order = order + 1
      id = "__render_block_" .. tostring(order)
    else
      id = tostring(raw_id)
    end

    local entry = entries[id]
    if entry == nil then
      order = order + 1
      entry = {
        id = id,
        message_id = block.message_id,
        parent_id = block.parent_id ~= nil and tostring(block.parent_id) or nil,
        children = {},
        sequence = tonumber(block.sequence) or 0,
        type = block.type or "unknown",
        status = block.status or "completed",
        content = block.content,
        metadata = type(block.metadata) == "table" and block.metadata or {},
        revision = tonumber(block.revision) or 1,
        _order = order,
      }
      entries[id] = entry
    else
      if entry.parent_id == nil and block.parent_id ~= nil then
        entry.parent_id = tostring(block.parent_id)
      end
      if entry.message_id == nil then
        entry.message_id = block.message_id
      end
      if entry.content == nil then
        entry.content = block.content
      end
      if (entry.type == nil or entry.type == "unknown") and block.type ~= nil then
        entry.type = block.type
      end
      if block.status ~= nil then
        entry.status = block.status
      end
      if type(block.metadata) == "table"
        and (entry.metadata == nil or next(entry.metadata) == nil) then
        entry.metadata = block.metadata
      end
      if (entry.sequence == nil or entry.sequence == 0) and tonumber(block.sequence) then
        entry.sequence = tonumber(block.sequence)
      end
      local revision = tonumber(block.revision)
      if revision and revision > (entry.revision or 0) then
        entry.revision = revision
      end
    end

    if inline_parent ~= nil and entry.parent_id == nil then
      entry.parent_id = inline_parent
    end

    if resolving[id] then
      return entry
    end
    resolving[id] = true

    local children = block.children
    if type(children) == "table" then
      if #children > 0 then
        for _, child in ipairs(children) do
          if type(child) == "table" then
            add(child, id)
          elseif type(child) == "string" or type(child) == "number" then
            local child_id = tostring(child)
            if entries[child_id] then
              if entries[child_id].parent_id == nil then
                entries[child_id].parent_id = id
              end
            else
              pending_parent[child_id] = id
            end
          end
        end
      else
        local keys = {}
        for key, child in pairs(children) do
          if type(child) == "table" then
            keys[#keys + 1] = key
          end
        end
        table.sort(keys, function(a, b)
          return tostring(a) < tostring(b)
        end)
        for _, key in ipairs(keys) do
          add(children[key], id)
        end
      end
    end

    resolving[id] = false
    return entry
  end

  local function visit_container(container)
    if type(container) ~= "table" then
      return
    end
    if is_block_like(container) then
      add(container, nil)
      return
    end
    if #container > 0 then
      for _, block in ipairs(container) do
        if type(block) == "table" then
          add(block, nil)
        end
      end
      return
    end
    local keys = {}
    for key, value in pairs(container) do
      if type(value) == "table" then
        keys[#keys + 1] = key
      end
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, key in ipairs(keys) do
      add(container[key], nil)
    end
  end

  if type(input) == "table" then
    if is_block_like(input) then
      add(input, nil)
    elseif input.blocks ~= nil or input.roots ~= nil or input.changed ~= nil then
      if input.blocks ~= nil then
        visit_container(input.blocks)
      end
      if input.changed ~= nil and input.changed ~= input.blocks then
        visit_container(input.changed)
      end
      if input.roots ~= nil and input.roots ~= input.blocks then
        visit_container(input.roots)
      end
    else
      visit_container(input)
    end
  end

  -- Resolve child IDs through lookup only after all inline blocks are known.
  local guard = 0
  while true do
    guard = guard + 1
    local progress = false
    local keys = {}
    for child_id in pairs(pending_parent) do
      keys[#keys + 1] = child_id
    end
    table.sort(keys)
    for _, child_id in ipairs(keys) do
      local entry = entries[child_id]
      if entry ~= nil then
        if entry.parent_id == nil then
          entry.parent_id = pending_parent[child_id]
        end
        pending_parent[child_id] = nil
        progress = true
      elseif lookup ~= nil then
        local resolved = resolve_lookup(lookup, child_id)
        if type(resolved) == "table" then
          add(resolved, pending_parent[child_id])
          pending_parent[child_id] = nil
          progress = true
        end
      end
    end
    if not progress or guard > 1000 then
      break
    end
  end

  for child_id, parent_id in pairs(pending_parent) do
    local entry = entries[child_id]
    if entry ~= nil and entry.parent_id == nil then
      entry.parent_id = parent_id
    end
  end

  return entries, order
end

local function rebuild_relations(entries)
  local ordered = {}
  for _, entry in pairs(entries) do
    ordered[#ordered + 1] = entry
  end
  table.sort(ordered, function(a, b)
    local sa = tonumber(a.sequence) or 0
    local sb = tonumber(b.sequence) or 0
    if sa ~= sb then
      return sa < sb
    end
    local oa = a._order or 0
    local ob = b._order or 0
    if oa ~= ob then
      return oa < ob
    end
    return tostring(a.id) < tostring(b.id)
  end)

  for _, entry in ipairs(ordered) do
    if entry.parent_id ~= nil then
      local parent_id = tostring(entry.parent_id)
      if parent_id == entry.id or entries[parent_id] == nil then
        entry.parent_id = nil
      else
        entry.parent_id = parent_id
      end
    end
  end

  -- Break accidental parent cycles instead of rendering nothing.
  for _, entry in ipairs(ordered) do
    local seen = {}
    local current = entry
    while current ~= nil do
      if seen[current.id] then
        entry.parent_id = nil
        break
      end
      seen[current.id] = true
      if current.parent_id ~= nil then
        current = entries[current.parent_id]
      else
        current = nil
      end
    end
  end

  for _, entry in pairs(entries) do
    entry.children = {}
  end

  local roots = {}
  for _, entry in ipairs(ordered) do
    if entry.parent_id ~= nil and entries[entry.parent_id] ~= nil then
      local parent = entries[entry.parent_id]
      parent.children[#parent.children + 1] = entry.id
    else
      entry.parent_id = nil
      roots[#roots + 1] = entry.id
    end
  end
  return roots
end

local function normalize_input(input, lookup, start_order)
  local entries, order = collect_input(input, lookup, start_order)
  local roots = rebuild_relations(entries)
  return entries, roots, order
end

local function extract_blocks(value, out)
  if type(value) ~= "table" then
    return
  end
  if is_block_like(value) then
    out[#out + 1] = value
    return
  end
  if value.blocks ~= nil or value.changed ~= nil or value.roots ~= nil then
    extract_blocks(value.blocks, out)
    if value.changed ~= value.blocks then
      extract_blocks(value.changed, out)
    end
    if value.roots ~= value.blocks then
      extract_blocks(value.roots, out)
    end
    return
  end
  if #value > 0 then
    for _, block in ipairs(value) do
      if type(block) == "table" then
        out[#out + 1] = block
      end
    end
    return
  end
  local keys = {}
  for key, block in pairs(value) do
    if type(block) == "table" then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    out[#out + 1] = value[key]
  end
end

local function extract_ids(value, out)
  if type(value) == "string" or type(value) == "number" then
    out[#out + 1] = tostring(value)
    return
  end
  if type(value) ~= "table" then
    return
  end
  if value.id ~= nil then
    out[#out + 1] = tostring(value.id)
    return
  end
  if #value > 0 then
    for _, item in ipairs(value) do
      extract_ids(item, out)
    end
    return
  end
  for key in pairs(value) do
    if type(key) == "string" or type(key) == "number" then
      out[#out + 1] = tostring(key)
    end
  end
end

local function tree_blocks()
  local seen = {}
  local function build_entry(id)
    local entry = state.blocks[id]
    if entry == nil or seen[id] then
      return nil
    end
    seen[id] = true
    local block = {
      id = entry.id,
      message_id = entry.message_id,
      parent_id = entry.parent_id,
      sequence = entry.sequence,
      type = entry.type,
      status = entry.status,
      content = entry.content,
      metadata = entry.metadata,
      revision = entry.revision,
      children = {},
    }
    for _, child_id in ipairs(entry.children or {}) do
      local child = build_entry(child_id)
      if child ~= nil then
        block.children[#block.children + 1] = child
      end
    end
    return block
  end

  local roots = {}
  for _, id in ipairs(state.roots) do
    local block = build_entry(id)
    if block ~= nil then
      roots[#roots + 1] = block
    end
  end
  return roots
end

local function layout_at(line)
  local best
  local best_start
  local best_end
  for id, info in pairs(state.layout) do
    if line >= info.start_line and line <= info.end_line then
      if best == nil
        or info.start_line > best_start
        or (info.start_line == best_start and info.end_line < best_end) then
        best = id
        best_start = info.start_line
        best_end = info.end_line
      end
    end
  end
  if best ~= nil then
    return best
  end

  -- A blank separator still belongs visually to the nearest preceding block.
  for id, info in pairs(state.layout) do
    if info.start_line <= line then
      if best == nil
        or info.start_line > best_start
        or (info.start_line == best_start and info.end_line > best_end) then
        best = id
        best_start = info.start_line
        best_end = info.end_line
      end
    end
  end
  if best ~= nil then
    return best
  end

  for id, info in pairs(state.layout) do
    if best == nil
      or info.start_line < best_start
      or (info.start_line == best_start and info.end_line < best_end) then
      best = id
      best_start = info.start_line
      best_end = info.end_line
    end
  end
  return best
end

local function capture_view()
  local views = {}
  if not buffer_ok() then
    return views
  end
  local line_count = vim.api.nvim_buf_line_count(state.buffer)
  for _, win in ipairs(state.windows) do
    if window_on_buffer(win) then
      local view = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview()
      end)
      local last_visible = vim.api.nvim_win_call(win, function()
        return vim.fn.line("w$")
      end)
      local top_block = layout_at(view.topline)
      local cursor_block = layout_at(view.lnum)
      views[win] = {
        view = view,
        at_bottom = last_visible >= line_count,
        top_block = top_block,
        top_offset = top_block and (view.topline - state.layout[top_block].start_line) or 0,
        cursor_block = cursor_block,
        cursor_offset = cursor_block and (view.lnum - state.layout[cursor_block].start_line) or 0,
      }
    end
  end
  return views
end

local function anchor_line(block_id, offset, fallback)
  if block_id ~= nil then
    local mark = state.marks[block_id]
    if mark ~= nil then
      local ok, position = pcall(vim.api.nvim_buf_get_extmark_by_id, state.buffer, ns_anchor, mark, {})
      if ok and position and position[1] ~= nil then
        return position[1] + 1 + (offset or 0)
      end
    end
    local info = state.layout[block_id]
    if info ~= nil then
      return info.start_line + (offset or 0)
    end
  end
  return fallback
end

local function restore_view(views)
  if not buffer_ok() then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(state.buffer)
  for win, saved in pairs(views) do
    if window_on_buffer(win) then
      if saved.at_bottom then
        vim.api.nvim_win_call(win, function()
          pcall(vim.api.nvim_win_set_cursor, 0, { line_count, 0 })
          pcall(vim.cmd, "silent! normal! zb")
        end)
      else
        local top = anchor_line(saved.top_block, saved.top_offset, saved.view.topline)
        local cursor_line = anchor_line(saved.cursor_block, saved.cursor_offset, saved.view.lnum)
        top = clamp(top, 1, line_count)
        cursor_line = clamp(cursor_line, 1, line_count)
        vim.api.nvim_win_call(win, function()
          pcall(vim.fn.winrestview, {
            topline = top,
            lnum = cursor_line,
            col = saved.view.col or 0,
            leftcol = saved.view.leftcol or 0,
            skipcol = saved.view.skipcol or 0,
          })
        end)
      end
    end
  end
end

local function capture_folds()
  if not buffer_ok() then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(state.buffer)
  for _, win in ipairs(state.windows) do
    if window_on_buffer(win) then
      local fold_state = state.fold_state[win]
      if fold_state == nil then
        fold_state = {}
        state.fold_state[win] = fold_state
      end
      for _, fold in ipairs(state.folds) do
        if fold.end_line > fold.start_line then
          local start_line = clamp(fold.start_line, 1, line_count)
          local ok, closed = pcall(vim.api.nvim_win_call, win, function()
            return vim.fn.foldclosed(start_line)
          end)
          if ok then
            if closed == start_line then
              fold_state[fold.id] = false
            elseif closed == -1 then
              fold_state[fold.id] = true
            end
          end
        end
      end
    end
  end
end

local function fold_contains(outer, inner)
  return outer ~= inner
    and outer.start_line <= inner.start_line
    and outer.end_line >= inner.end_line
end

local function apply_folds(win)
  if not window_on_buffer(win) then
    return
  end
  local fold_state = state.fold_state[win]
  if fold_state == nil then
    fold_state = {}
    state.fold_state[win] = fold_state
  end

  vim.api.nvim_win_call(win, function()
    vim.wo.foldmethod = "manual"
    vim.wo.foldenable = true
    vim.wo.foldlevel = 99
    pcall(vim.cmd, "silent! normal! zE")
  end)

  local line_count = vim.api.nvim_buf_line_count(state.buffer)
  local folds = {}
  for _, fold in ipairs(state.folds) do
    if fold.end_line > fold.start_line then
      folds[#folds + 1] = fold
    end
  end
  table.sort(folds, function(a, b)
    -- Manual folds must be created from the inside out. Creating a closed
    -- outer fold first makes later inner folds part of the outer fold and
    -- breaks independent zc/zo handling.
    if a.start_line ~= b.start_line then
      return a.start_line > b.start_line
    end
    if a.end_line ~= b.end_line then
      return a.end_line < b.end_line
    end
    return tostring(a.id) < tostring(b.id)
  end)

  for _, fold in ipairs(folds) do
    local start_line = clamp(fold.start_line, 1, line_count)
    local end_line = clamp(fold.end_line, 1, line_count)
    if end_line > start_line then
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd(("%d,%dfold"):format(start_line, end_line))
      end)
    end
  end

  local open = {}
  for _, fold in ipairs(folds) do
    local value = fold_state[fold.id]
    if value == nil then
      value = fold.default_open ~= false
    end
    fold_state[fold.id] = value
    if value then
      open[#open + 1] = fold
    end
  end
  table.sort(open, function(a, b)
    if a.start_line ~= b.start_line then
      return a.start_line < b.start_line
    end
    return a.end_line > b.end_line
  end)

  local function blocked_by_closed(fold)
    for _, other in ipairs(folds) do
      if fold_contains(other, fold) and fold_state[other.id] == false then
        return true
      end
    end
    return false
  end

  for _, fold in ipairs(open) do
    if not blocked_by_closed(fold) then
      local start_line = clamp(fold.start_line, 1, line_count)
      pcall(vim.api.nvim_win_call, win, function()
        pcall(vim.api.nvim_win_set_cursor, 0, { start_line, 0 })
        pcall(vim.cmd, "silent! normal! zo")
      end)
    end
  end
end

local function remember_window_opts(win)
  if state.window_opts[win] ~= nil or not valid_win(win) then
    return
  end
  state.window_opts[win] = vim.api.nvim_win_call(win, function()
    return {
      foldmethod = vim.wo.foldmethod,
      foldenable = vim.wo.foldenable,
      foldlevel = vim.wo.foldlevel,
    }
  end)
end

local function restore_window_opts(win)
  local opts = state.window_opts[win]
  state.window_opts[win] = nil
  if opts == nil or not valid_win(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd, "silent! normal! zE")
    pcall(function()
      vim.wo.foldmethod = opts.foldmethod
    end)
    pcall(function()
      vim.wo.foldenable = opts.foldenable
    end)
    pcall(function()
      vim.wo.foldlevel = opts.foldlevel
    end)
  end)
end

local function update_layout(build)
  state.layout = {}
  for _, info in ipairs(build.blocks) do
    state.layout[info.id] = {
      start_line = info.start_line,
      end_line = info.end_line,
      root = info.root,
    }
  end
end

local function set_highlights(build, ranges)
  if not buffer_ok() then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(state.buffer)

  local function in_ranges(row)
    if ranges == nil then
      return true
    end
    for _, range in ipairs(ranges) do
      if row >= range.start_row and row < range.end_row then
        return true
      end
    end
    return false
  end

  if ranges == nil then
    vim.api.nvim_buf_clear_namespace(state.buffer, ns_hl, 0, -1)
  else
    for _, range in ipairs(ranges) do
      local start_row = clamp(range.start_row, 0, math.max(0, line_count))
      local end_row = clamp(range.end_row, start_row, math.max(start_row, line_count))
      vim.api.nvim_buf_clear_namespace(state.buffer, ns_hl, start_row, end_row)
    end
  end

  for _, highlight in ipairs(build.highlights) do
    if in_ranges(highlight.line - 1) then
      local lnum = clamp(highlight.line, 1, line_count)
      local text = vim.api.nvim_buf_get_lines(state.buffer, lnum - 1, lnum, false)[1] or ""
      local start_col = clamp(highlight.start_col or 0, 0, #text)
      local end_col = highlight.end_col
      if end_col == nil or end_col < 0 or end_col > #text then
        end_col = #text
      end
      end_col = math.max(start_col, end_col)
      pcall(vim.api.nvim_buf_set_extmark, state.buffer, ns_hl, lnum - 1, start_col, {
        end_col = end_col,
        hl_group = highlight.group,
        priority = 100,
      })
    end
  end
end

local function update_marks(build)
  if not buffer_ok() then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(state.buffer)
  local seen = {}
  for _, info in ipairs(build.blocks) do
    local id = info.id
    seen[id] = true
    local line = clamp(info.start_line - 1, 0, math.max(0, line_count - 1))

    local mark = state.marks[id]
    local position = nil
    if mark ~= nil then
      local ok, value = pcall(vim.api.nvim_buf_get_extmark_by_id, state.buffer, ns_anchor, mark, {})
      if ok then
        position = value
      end
    end

    if position == nil or position[1] ~= line then
      if mark ~= nil then
        pcall(vim.api.nvim_buf_del_extmark, state.buffer, ns_anchor, mark)
        state.marks[id] = nil
      end
      local ok, new_mark = pcall(vim.api.nvim_buf_set_extmark, state.buffer, ns_anchor, line, 0, {
        right_gravity = false,
      })
      if ok then
        state.marks[id] = new_mark
      end
    end
  end

  for id, mark in pairs(state.marks) do
    if not seen[id] then
      pcall(vim.api.nvim_buf_del_extmark, state.buffer, ns_anchor, mark)
      state.marks[id] = nil
    end
  end
end

local function splice_lines(new_lines)
  if not buffer_ok() then
    return
  end
  if #new_lines == 0 then
    new_lines = { "" }
  end

  local old_lines = vim.api.nvim_buf_get_lines(state.buffer, 0, -1, false)
  if #old_lines == 0 then
    old_lines = { "" }
  end

  local old_n = #old_lines
  local new_n = #new_lines
  local prefix = 0
  while prefix < old_n and prefix < new_n and old_lines[prefix + 1] == new_lines[prefix + 1] do
    prefix = prefix + 1
  end
  local suffix = 0
  while suffix < old_n - prefix
    and suffix < new_n - prefix
    and old_lines[old_n - suffix] == new_lines[new_n - suffix] do
    suffix = suffix + 1
  end

  local old_end = old_n - suffix
  local new_end = new_n - suffix
  local edit_range = nil
  if prefix ~= old_end or prefix ~= new_end then
    if new_end > prefix then
      edit_range = { start_row = prefix, end_row = new_end }
    end
    local replacement = {}
    for index = prefix + 1, new_end do
      replacement[#replacement + 1] = new_lines[index]
    end
    if #replacement == 0 and old_n == 0 then
      replacement = { "" }
    end

    local modifiable = vim.api.nvim_get_option_value("modifiable", { buf = state.buffer })
    local readonly = vim.api.nvim_get_option_value("readonly", { buf = state.buffer })
    vim.api.nvim_set_option_value("readonly", false, { buf = state.buffer })
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.buffer })
    local ok, err = pcall(vim.api.nvim_buf_set_lines, state.buffer, prefix, old_end, false, replacement)
    vim.api.nvim_set_option_value("modifiable", modifiable, { buf = state.buffer })
    vim.api.nvim_set_option_value("readonly", readonly, { buf = state.buffer })
    if not ok then
      error(err)
    end
  end

  state.lines = new_lines
  return edit_range
end

local function prune_fold_state()
  local ids = {}
  for _, fold in ipairs(state.folds) do
    ids[fold.id] = true
  end
  for _, fold_state in pairs(state.fold_state) do
    for id in pairs(fold_state) do
      if not ids[id] then
        fold_state[id] = nil
      end
    end
  end
end

local function merged_ranges(ranges)
  if #ranges == 0 then
    return {}
  end
  table.sort(ranges, function(a, b)
    if a.start_row ~= b.start_row then
      return a.start_row < b.start_row
    end
    return a.end_row < b.end_row
  end)
  local merged = {}
  for _, range in ipairs(ranges) do
    local last = merged[#merged]
    if last ~= nil and range.start_row <= last.end_row then
      last.end_row = math.max(last.end_row, range.end_row)
    else
      merged[#merged + 1] = {
        start_row = range.start_row,
        end_row = range.end_row,
      }
    end
  end
  return merged
end

local function highlight_ranges(changed_ids, edit_range)
  local ranges = {}
  for id in pairs(changed_ids or {}) do
    local info = state.layout[id]
    if info ~= nil then
      ranges[#ranges + 1] = {
        start_row = info.start_line - 1,
        end_row = info.end_line,
      }
    end
  end
  if edit_range ~= nil then
    ranges[#ranges + 1] = edit_range
  end
  return merged_ranges(ranges)
end

local function render(force_full, changed_ids)
  if not buffer_ok() then
    return
  end

  local views = capture_view()
  capture_folds()

  local build = lines_mod.build(tree_blocks(), state.opts)
  if #build.lines == 0 then
    build.lines = { "" }
  end

  local edit_range = splice_lines(build.lines)
  state.folds = build.folds
  state.fold_by_id = {}
  for _, fold in ipairs(build.folds) do
    state.fold_by_id[fold.id] = fold
  end
  update_layout(build)

  if force_full or not state.highlights_ready then
    set_highlights(build, nil)
    state.highlights_ready = true
  else
    set_highlights(build, highlight_ranges(changed_ids, edit_range))
  end

  update_marks(build)
  prune_fold_state()

  for _, win in ipairs(state.windows) do
    apply_folds(win)
  end
  restore_view(views)
end

local function remove_entry(id, preserve)
  local entry = state.blocks[id]
  if entry == nil then
    return
  end
  local children = {}
  for _, child_id in ipairs(entry.children or {}) do
    children[#children + 1] = child_id
  end
  state.blocks[id] = nil
  for _, child_id in ipairs(children) do
    if not preserve[child_id] then
      remove_entry(child_id, preserve)
    end
  end
end

local function managed_window(win)
  if not window_on_buffer(win) then
    return false
  end
  for _, managed in ipairs(state.windows) do
    if managed == win then
      return true
    end
  end
  return false
end

local function target_window(explicit)
  if explicit ~= nil and managed_window(explicit) then
    return explicit
  end
  local current = vim.api.nvim_get_current_win()
  if managed_window(current) then
    return current
  end
  if managed_window(state.primary_window) then
    return state.primary_window
  end
  for _, win in ipairs(state.windows) do
    if managed_window(win) then
      return win
    end
  end
  return nil
end

local function fold_ids_for_block(block_id)
  local ids = {}
  if state.fold_by_id[block_id] ~= nil then
    ids[#ids + 1] = block_id
  end
  local prefix = block_id .. ":"
  for id in pairs(state.fold_by_id) do
    if id ~= block_id and id:sub(1, #prefix) == prefix then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

local function ancestor_fold_ids(fold_id)
  local ids = {}
  local current = fold_id
  while true do
    local parent = current:match("^(.*):[^:]+$")
    if parent == nil then
      break
    end
    if state.fold_by_id[parent] ~= nil then
      ids[#ids + 1] = parent
    end
    current = parent
  end
  return ids
end

local function set_fold_state(win, fold_ids, open)
  if win == nil or #fold_ids == 0 then
    return false
  end
  capture_folds()
  local fold_state = state.fold_state[win]
  if fold_state == nil then
    fold_state = {}
    state.fold_state[win] = fold_state
  end
  for _, id in ipairs(fold_ids) do
    if state.fold_by_id[id] ~= nil then
      fold_state[id] = open
    end
  end

  local saved = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
  apply_folds(win)
  vim.api.nvim_win_call(win, function()
    pcall(vim.fn.winrestview, saved)
  end)
  return true
end

function M.attach(opts)
  assert(type(opts) == "table", "renderer.attach requires a table")
  if state.attached then
    M.detach()
  end

  local buffer = opts.buffer
  local window = opts.window or vim.api.nvim_get_current_win()
  assert(valid_buf(buffer), "renderer.attach requires a valid buffer")
  assert(valid_win(window), "renderer.attach requires a valid window")

  ensure_highlights()
  state.attached = true
  state.buffer = buffer
  state.primary_window = window
  state.windows = { window }
  state.window_opts = {}
  state.blocks = {}
  state.roots = {}
  state.order_counter = 0
  if type(opts.opts) == "table" then
    state.opts = opts.opts
  else
    state.opts = {}
  end
  if state.opts.max_lines == nil and opts.max_lines ~= nil then
    state.opts.max_lines = opts.max_lines
  end
  state.lookup = opts.lookup
  state.layout = {}
  state.folds = {}
  state.fold_by_id = {}
  state.fold_state = {}
  state.marks = {}
  state.highlights_ready = false

  pcall(vim.api.nvim_buf_clear_namespace, buffer, ns_hl, 0, -1)
  pcall(vim.api.nvim_buf_clear_namespace, buffer, ns_anchor, 0, -1)

  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
  vim.api.nvim_set_option_value("filetype", "opencode_messages", { buf = buffer })

  if vim.api.nvim_win_get_buf(window) ~= buffer then
    vim.api.nvim_win_set_buf(window, buffer)
  end

  state.lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  if #state.lines == 0 then
    state.lines = { "" }
  end
  remember_window_opts(window)

  state.augroup = vim.api.nvim_create_augroup("OpencodeRender" .. buffer, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed ~= nil then
        M.detach_window(closed)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = state.augroup,
    buffer = buffer,
    callback = function()
      M.detach()
    end,
  })

  if opts.blocks ~= nil then
    M.reset(opts.blocks, opts.lookup)
  end
  return M
end

function M.reset(blocks, lookup)
  assert(state.attached, "renderer.reset requires attach()")
  if lookup == nil and type(blocks) == "table" then
    lookup = blocks.lookup
  end
  if lookup ~= nil then
    state.lookup = lookup
  end
  local entries, roots, order = normalize_input(blocks, state.lookup, 0)
  state.blocks = entries
  state.roots = roots
  state.order_counter = order
  render(true)
  return M
end

function M.apply_change(change)
  assert(state.attached, "renderer.apply_change requires attach()")
  assert(type(change) == "table", "renderer.apply_change requires a table change")

  if change.lookup ~= nil then
    state.lookup = change.lookup
  end

  local kind = change.kind or change.type or change.op
  local reset = kind == "reset"
    or change.reset == true
    or (kind ~= "remove"
      and change.blocks ~= nil
      and change.changed == nil
      and change.upsert == nil
      and change.block == nil)

  if reset then
    local blocks = {}
    extract_blocks(change.blocks, blocks)
    extract_blocks(change.changed, blocks)
    extract_blocks(change.upsert, blocks)
    extract_blocks(change.block, blocks)
    local entries, roots, order = normalize_input(blocks, state.lookup, 0)
    state.blocks = entries
    state.roots = roots
    state.order_counter = order
    render(true)
    return M
  end

  local incoming_list = {}
  local bare_block = change.kind == nil
    and change.op == nil
    and change.id ~= nil
    and change.changed == nil
    and change.upsert == nil
    and change.block == nil
    and change.blocks == nil
    and change.removed == nil
    and change.remove == nil
    and change.type ~= "remove"
    and change.type ~= "reset"
    and change.type ~= "update"
    and change.type ~= "upsert"
  if bare_block then
    incoming_list[1] = change
  else
    extract_blocks(change.changed, incoming_list)
    extract_blocks(change.upsert, incoming_list)
    extract_blocks(change.block, incoming_list)
    if kind == "upsert" then
      extract_blocks(change.blocks, incoming_list)
    end
  end

  local removed = {}
  extract_ids(change.removed, removed)
  extract_ids(change.remove, removed)
  if kind == "remove" then
    extract_ids(change.id, removed)
  end

  if #incoming_list == 0 and #removed == 0 then
    return M
  end

  local incoming, order = collect_input(incoming_list, state.lookup, state.order_counter)
  local preserve = {}
  for id in pairs(incoming) do
    preserve[id] = true
  end

  local removed_set = {}
  for _, id in ipairs(removed) do
    if not removed_set[id] then
      removed_set[id] = true
      if not preserve[id] then
        remove_entry(id, preserve)
      end
    end
  end

  for id, entry in pairs(incoming) do
    local existing = state.blocks[id]
    if existing ~= nil then
      entry._order = existing._order
    end
    state.blocks[id] = entry
  end
  state.order_counter = math.max(state.order_counter, order)
  state.roots = rebuild_relations(state.blocks)

  local changed_ids = {}
  for id in pairs(incoming) do
    changed_ids[id] = true
  end
  for id in pairs(removed_set) do
    changed_ids[id] = true
  end
  render(false, changed_ids)
  return M
end

function M.open_block(block_id, window)
  if not state.attached then
    return false
  end
  local win = target_window(window)
  if win == nil then
    return false
  end
  local id = tostring(block_id)
  local ids = fold_ids_for_block(id)
  if #ids == 0 then
    return false
  end
  local ancestors = ancestor_fold_ids(id)
  for _, ancestor in ipairs(ancestors) do
    ids[#ids + 1] = ancestor
  end
  return set_fold_state(win, ids, true)
end

function M.close_block(block_id, window)
  if not state.attached then
    return false
  end
  local win = target_window(window)
  if win == nil then
    return false
  end
  local ids = fold_ids_for_block(tostring(block_id))
  return set_fold_state(win, ids, false)
end

function M.toggle_block(block_id, window)
  if not state.attached then
    return false
  end
  local win = target_window(window)
  if win == nil then
    return false
  end
  local id = tostring(block_id)
  local ids = fold_ids_for_block(id)
  if #ids == 0 then
    return false
  end

  local target = id
  if state.fold_by_id[target] == nil then
    target = ids[1]
  end
  local fold = state.fold_by_id[target]
  if fold == nil then
    return false
  end

  capture_folds()
  local fold_state = state.fold_state[win]
  if fold_state == nil then
    fold_state = {}
    state.fold_state[win] = fold_state
  end
  local current = fold_state[target]
  if current == nil then
    current = fold.default_open ~= false
  end
  return set_fold_state(win, { target }, not current)
end

-- Attach an additional window sharing the same message buffer.
function M.attach_window(window)
  assert(state.attached, "renderer.attach_window requires attach()")
  assert(valid_win(window), "renderer.attach_window requires a valid window")
  remember_window_opts(window)
  vim.api.nvim_win_set_buf(window, state.buffer)

  for _, existing in ipairs(state.windows) do
    if existing == window then
      return M
    end
  end

  state.windows[#state.windows + 1] = window
  local saved = vim.api.nvim_win_call(window, function()
    return vim.fn.winsaveview()
  end)
  apply_folds(window)
  vim.api.nvim_win_call(window, function()
    pcall(vim.fn.winrestview, saved)
  end)
  return M
end

function M.detach_window(window)
  local found = false
  for index, win in ipairs(state.windows) do
    if win == window then
      table.remove(state.windows, index)
      found = true
      break
    end
  end
  restore_window_opts(window)
  state.fold_state[window] = nil
  if state.primary_window == window then
    state.primary_window = state.windows[1]
  end
  return M
end

function M.detach()
  for _, win in ipairs(state.windows) do
    restore_window_opts(win)
  end
  if state.buffer ~= nil and valid_buf(state.buffer) then
    pcall(vim.api.nvim_buf_clear_namespace, state.buffer, ns_hl, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, state.buffer, ns_anchor, 0, -1)
  end
  if state.augroup ~= nil then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end

  state.attached = false
  state.buffer = nil
  state.primary_window = nil
  state.windows = {}
  state.window_opts = {}
  state.augroup = nil
  state.blocks = {}
  state.roots = {}
  state.order_counter = 0
  state.opts = {}
  state.lookup = nil
  state.lines = {}
  state.layout = {}
  state.folds = {}
  state.fold_by_id = {}
  state.fold_state = {}
  state.marks = {}
  state.highlights_ready = false
  return M
end

-- Introspection helpers used by tests and integration code.
function M.get_layout(block_id)
  local info = state.layout[tostring(block_id)]
  if info == nil then
    return nil
  end
  return {
    start_line = info.start_line,
    end_line = info.end_line,
    root = info.root,
  }
end

function M.get_lines()
  return vim.deepcopy(state.lines)
end

function M.get_fold_state(window, block_id)
  local win = window or target_window()
  if win == nil then
    return nil
  end
  local id = tostring(block_id)
  local fold_state = state.fold_state[win]
  if fold_state == nil then
    return nil
  end
  local stored = fold_state[id]
  local fold = state.fold_by_id[id]
  if fold ~= nil and window_on_buffer(win) then
    local line_count = vim.api.nvim_buf_line_count(state.buffer)
    local start_line = clamp(fold.start_line, 1, line_count)
    local ok, closed = pcall(vim.api.nvim_win_call, win, function()
      return vim.fn.foldclosed(start_line)
    end)
    if ok then
      if closed == start_line then
        return false
      elseif closed == -1 then
        return true
      end
    end
  end
  return stored
end

function M.get_anchor(block_id)
  local id = tostring(block_id)
  local mark = state.marks[id]
  if mark == nil or not buffer_ok() then
    return nil
  end
  local ok, position = pcall(vim.api.nvim_buf_get_extmark_by_id, state.buffer, ns_anchor, mark, {})
  if not ok or not position or position[1] == nil then
    return nil
  end
  return {
    mark = mark,
    line = position[1] + 1,
  }
end

function M.get_folds()
  local folds = {}
  for _, fold in ipairs(state.folds) do
    folds[#folds + 1] = {
      id = fold.id,
      start_line = fold.start_line,
      end_line = fold.end_line,
      default_open = fold.default_open,
    }
  end
  return folds
end

function M.is_attached()
  return state.attached
end

function M.get_buffer()
  return state.buffer
end

return M
