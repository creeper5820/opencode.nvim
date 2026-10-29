-- Isolated headless tests for the conversation renderer.
-- Run through run.sh so XDG dirs, shada and cwd are throwaway.

local renderer = require("opencode.render")

local failures = 0
local checks = 0

local function fail(msg)
  failures = failures + 1
  io.stderr:write("FAIL: " .. msg .. "\n")
end

local function ok(value, msg)
  checks = checks + 1
  if not value then
    fail(msg)
  end
  return value
end

local function eq(expected, actual, msg)
  checks = checks + 1
  if not vim.deep_equal(expected, actual) then
    fail(msg .. "\n  expected: " .. vim.inspect(expected) .. "\n  actual:   " .. vim.inspect(actual))
  end
end

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function text(buf)
  return table.concat(buf_lines(buf), "\n")
end

local function contains(haystack, needle, msg)
  return ok(type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil, msg .. " (missing: " .. needle .. ")")
end

local function fresh(opts)
  vim.cmd("silent! only")
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  renderer.attach({ buffer = buf, window = win, opts = opts })
  return buf, win
end

local function cleanup()
  pcall(renderer.detach)
  vim.cmd("silent! only")
end

local function block(id, type, content, extra)
  local value = {
    id = id,
    message_id = "msg-" .. id,
    type = type,
    content = content,
    status = "completed",
    sequence = extra and extra.sequence or 1,
    metadata = extra and extra.metadata or {},
  }
  if extra then
    for k, v in pairs(extra) do
      value[k] = v
    end
  end
  return value
end

local sample_diff = table.concat({
  "--- a/src/example.lua",
  "+++ b/src/example.lua",
  "@@ -10,4 +10,5 @@",
  "   local value = get_value()",
  "-  return value",
  "+  return value or default",
  "+end",
  "@@ -30,2 +31,2 @@",
  " context line",
  "-old line",
  "+new line",
}, "\n")

local function sample_blocks()
  return {
    block("u1", "user", "Please edit the file", { sequence = 1 }),
    block("a1", "assistant", "Sure, working on it.", { sequence = 2 }),
    block("r1", "reasoning", "I should inspect the file first.", { sequence = 3, status = "completed" }),
    block("t1", "tool", {
      input = { filePath = "src/example.lua" },
      output = "patched successfully\nline two of output",
      diff = sample_diff,
    }, {
      sequence = 4,
      metadata = { tool = "edit", input = { filePath = "src/example.lua" } },
      status = "completed",
    }),
    block("s1", "status", "Compaction completed", { sequence = 5 }),
    block("x1", "unknown", { native = "mystery.event", payload = { a = 1 } }, { sequence = 6 }),
  }
end

-- 1. Structured rendering: every supported type produces content.
do
  local buf = fresh()
  renderer.reset(sample_blocks())
  local all = text(buf)
  contains(all, "▌ User", "user header")
  contains(all, "Please edit the file", "user content")
  contains(all, "Sure, working on it.", "assistant content")
  contains(all, "Reasoning", "reasoning header")
  contains(all, "I should inspect the file first.", "reasoning content")
  contains(all, "▼ edit", "tool header")
  contains(all, "src/example.lua", "tool argument summary")
  contains(all, "patched successfully", "tool output inline")
  contains(all, "line two of output", "tool output not truncated")
  contains(all, "--- a/src/example.lua", "diff file header inline")
  contains(all, "+++ b/src/example.lua", "diff new file header inline")
  contains(all, "@@ -10,4 +10,5 @@", "first hunk inline")
  contains(all, "@@ -30,2 +31,2 @@", "second hunk inline")
  contains(all, "   local value = get_value()", "diff context inline")
  contains(all, "  -  return value", "diff deletion inline")
  contains(all, "  +  return value or default", "diff addition inline")
  contains(all, "Compaction completed", "status content")
  contains(all, "Unknown event", "unknown header")
  contains(all, "mystery.event", "unknown raw detail")
  eq(false, vim.api.nvim_get_option_value("modifiable", { buf = buf }), "message buffer is not modifiable")
  eq(1, #vim.api.nvim_list_wins(), "no extra split window created")
  ok(renderer.get_layout("u1") ~= nil, "user block has layout")
  ok(renderer.get_layout("t1") ~= nil, "tool block has layout")
  ok(renderer.get_layout("x1") ~= nil, "unknown block has layout")
  cleanup()
end

-- 2. Diffs are highlighted and stay inside the timeline.
do
  local buf = fresh()
  renderer.reset({ block("d1", "diff", sample_diff, { metadata = { file = "src/example.lua" } }) })
  local all = text(buf)
  contains(all, "▼ Diff src/example.lua", "diff block header")
  contains(all, "@@ -30,2 +31,2 @@", "multi-hunk diff complete")
  local ns = vim.api.nvim_get_namespaces()["opencode_render_hl"]
  ok(ns ~= nil, "highlight namespace exists")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local groups = {}
  for _, mark in ipairs(marks) do
    groups[mark[4].hl_group] = true
  end
  ok(groups["OpencodeDiffAdd"], "diff addition highlight")
  ok(groups["OpencodeDiffDelete"], "diff deletion highlight")
  ok(groups["OpencodeDiffHunk"], "diff hunk highlight")
  ok(groups["OpencodeDiffFile"], "diff file highlight")
  cleanup()
end

-- 3. Fold state is per (window, block).
do
  local buf, win1 = fresh()
  renderer.reset(sample_blocks())
  renderer.open_block("r1")
  vim.cmd("vsplit")
  local win2 = vim.api.nvim_get_current_win()
  ok(win2 ~= win1, "two windows")
  renderer.attach_window(win2)
  renderer.open_block("r1")
  -- win2 is current, close reasoning there.
  eq(true, renderer.close_block("r1"), "close reasoning in current window")
  eq(false, renderer.get_fold_state(win2, "r1"), "win2 reasoning folded")
  eq(true, renderer.get_fold_state(win1, "r1"), "win1 state untouched")
  local closed1 = vim.api.nvim_win_call(win1, function()
    return vim.fn.foldclosed(renderer.get_layout("r1").start_line)
  end)
  eq(-1, closed1, "win1 reasoning still open")
  local closed2 = vim.api.nvim_win_call(win2, function()
    return vim.fn.foldclosed(renderer.get_layout("r1").start_line)
  end)
  eq(renderer.get_layout("r1").start_line, closed2, "win2 reasoning closed")
  -- Open in win2 then toggle in win1 via cursor.
  renderer.open_block("r1")
  eq(true, renderer.get_fold_state(win2, "r1"), "win2 reopened")
  vim.api.nvim_set_current_win(win1)
  eq(true, renderer.toggle_block("r1"), "toggle in win1")
  eq(false, renderer.get_fold_state(win1, "r1"), "win1 folded independently")
  eq(true, renderer.get_fold_state(win2, "r1"), "win2 remains open")
  cleanup()
end

-- 3b. Per-window fold state survives an incremental update.
do
  local buf, win1 = fresh()
  renderer.reset({
    block("r4", "reasoning", "thinking", { sequence = 1 }),
    block("a4", "assistant", "answer", { sequence = 2 }),
  })
  renderer.open_block("r4")
  vim.cmd("vsplit")
  local win2 = vim.api.nvim_get_current_win()
  renderer.attach_window(win2)
  renderer.close_block("r4")
  eq(true, renderer.get_fold_state(win1, "r4"), "win1 reasoning open")
  eq(false, renderer.get_fold_state(win2, "r4"), "win2 reasoning closed")
  renderer.apply_change({ upsert = block("a4", "assistant", "answer changed", { sequence = 2 }) })
  eq(true, renderer.get_fold_state(win1, "r4"), "win1 fold survives update")
  eq(false, renderer.get_fold_state(win2, "r4"), "win2 fold survives update independently")
  cleanup()
end

-- 4. Incremental update keeps user folds and only rewrites affected lines.
do
  local buf = fresh()
  renderer.reset(sample_blocks())
  renderer.close_block("t1")
  local before = buf_lines(buf)
  local tool_layout = renderer.get_layout("t1")
  local user_before = vim.list_slice(before, renderer.get_layout("u1").start_line, renderer.get_layout("u1").end_line)
  renderer.apply_change({
    upsert = { id = "a1", message_id = "msg-a1", type = "assistant", content = "Updated assistant text.", status = "completed", sequence = 2 },
  })
  local after = buf_lines(buf)
  eq(false, renderer.get_fold_state(vim.api.nvim_get_current_win(), "t1"), "tool fold preserved after update")
  local tool_start = renderer.get_layout("t1").start_line
  eq(tool_start, vim.api.nvim_win_call(vim.api.nvim_get_current_win(), function()
    return vim.fn.foldclosed(tool_start)
  end), "tool fold range repaired after line changes")
  eq(user_before, vim.list_slice(after, renderer.get_layout("u1").start_line, renderer.get_layout("u1").end_line), "unrelated user block lines unchanged")
  contains(text(buf), "Updated assistant text.", "updated block rendered")
  ok(renderer.get_layout("t1") ~= nil, "tool still laid out after update")
  -- Growing the folded tool must keep it folded at the repaired range.
  renderer.apply_change({
    upsert = {
      id = "t1",
      message_id = "msg-t1",
      type = "tool",
      sequence = 4,
      status = "completed",
      metadata = { tool = "edit", input = { filePath = "src/example.lua" } },
      content = { input = { filePath = "src/example.lua" }, output = "new output line\nand another", diff = sample_diff },
    },
  })
  eq(false, renderer.get_fold_state(vim.api.nvim_get_current_win(), "t1"), "fold preserved across tool update")
  local new_start = renderer.get_layout("t1").start_line
  eq(new_start, vim.api.nvim_win_call(vim.api.nvim_get_current_win(), function()
    return vim.fn.foldclosed(new_start)
  end), "fold range repaired after tool growth")
  cleanup()
end

-- 5. Streaming updates while browsing up keep the viewed block anchored.
do
  local buf, win = fresh()
  local blocks = {}
  for i = 1, 40 do
    blocks[i] = block("a" .. i, "assistant", "message " .. i .. "\nline two", { sequence = i })
  end
  renderer.reset(blocks)
  -- Put a change above the viewport via an update to the first block.
  vim.api.nvim_win_set_cursor(win, { 30, 0 })
  vim.cmd("normal! zt")
  local top_before = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline
  end)
  local view_block = nil
  for i = 1, 40 do
    local l = renderer.get_layout("a" .. i)
    if l and top_before >= l.start_line and top_before <= l.end_line then
      view_block = "a" .. i
    end
  end
  renderer.apply_change({ upsert = block("a1", "assistant", "message 1\nline two\nadded above line 1\nadded above line 2", { sequence = 1 }) })
  local top_after = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline
  end)
  local layout = renderer.get_layout(view_block)
  ok(layout ~= nil, "viewed block still present")
  ok(top_after >= layout.start_line and top_after <= layout.end_line,
    "top line remains inside viewed block after insert above")
  ok(top_after == top_before + 2, "two inserted lines above shift viewport")
  cleanup()
end

-- 5b. Two windows keep independent view anchors on the same buffer.
do
  local buf, win1 = fresh()
  local blocks = {}
  for i = 1, 50 do
    blocks[i] = block("a" .. i, "assistant", "message " .. i .. "\nbody " .. i, { sequence = i })
  end
  renderer.reset(blocks)
  vim.api.nvim_win_set_cursor(win1, { 8, 0 })
  vim.cmd("normal! zt")
  vim.cmd("vsplit")
  local win2 = vim.api.nvim_get_current_win()
  renderer.attach_window(win2)
  vim.api.nvim_win_set_cursor(win2, { 60, 0 })
  vim.cmd("normal! zt")
  local function top_of(win)
    return vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview().topline
    end)
  end
  local function block_at_top(top)
    for i = 1, 50 do
      local l = renderer.get_layout("a" .. i)
      if l and top >= l.start_line and top <= l.end_line then
        return "a" .. i
      end
    end
  end
  local top1, top2 = top_of(win1), top_of(win2)
  local block1, block2 = block_at_top(top1), block_at_top(top2)
  ok(block1 ~= nil and block2 ~= nil and block1 ~= block2, "windows view different blocks")
  renderer.apply_change({ upsert = block("a1", "assistant", "message 1\nbody 1\nextra 1\nextra 2\nextra 3", { sequence = 1 }) })
  local new_top1, new_top2 = top_of(win1), top_of(win2)
  local l1, l2 = renderer.get_layout(block1), renderer.get_layout(block2)
  ok(l1 and new_top1 >= l1.start_line and new_top1 <= l1.end_line, "win1 anchored to its own block")
  ok(l2 and new_top2 >= l2.start_line and new_top2 <= l2.end_line, "win2 anchored to its own block")
  eq(top1 + 3, new_top1, "win1 shifted by inserted lines")
  eq(top2 + 3, new_top2, "win2 shifted by inserted lines")
  cleanup()
end

-- 6. Auto-scroll at bottom, but not when browsing history.
do
  local buf, win = fresh()
  local blocks = {}
  for i = 1, 30 do
    blocks[i] = block("a" .. i, "assistant", "message " .. i, { sequence = i })
  end
  renderer.reset(blocks)
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  vim.cmd("normal! G")
  local bottom_before = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w$")
  end)
  eq(vim.api.nvim_buf_line_count(buf), bottom_before, "cursor at bottom before update")
  renderer.apply_change({ upsert = block("a30", "assistant", "message 30\nstreamed line one\nstreamed line two", { sequence = 30 }) })
  local bottom_after = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w$")
  end)
  eq(vim.api.nvim_buf_line_count(buf), bottom_after, "bottom-follow after streaming update")
  -- Scroll far up, then stream; the top block must not jump to the bottom.
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  vim.cmd("normal! zt")
  local top_before = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline
  end)
  renderer.apply_change({ upsert = block("a30", "assistant", "message 30\nstreamed line one\nstreamed line two\nstreamed line three", { sequence = 30 }) })
  local top_after = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline
  end)
  eq(top_before, top_after, "streaming does not steal scroll when browsing history")
  cleanup()
end

-- 7. Long content limit is visible and expandable.
do
  local long = {}
  for i = 1, 60 do
    long[i] = "output line " .. i
  end
  local buf = fresh({ max_lines = 10 })
  renderer.reset({ block("t2", "tool", { output = table.concat(long, "\n") }, { metadata = { tool = "bash" } }) })
  local all = text(buf)
  contains(all, "output line 10", "first screen lines shown")
  contains(all, "more lines (za to expand)", "limit marker is explicit")
  ok(all:find("output line 11", 1, true) ~= nil, "hidden content still present in buffer")
  renderer.open_block("t2")
  renderer.open_block("t2:output")
  renderer.open_block("t2:output:rest")
  contains(text(buf), "output line 60", "full content reachable")
  cleanup()
end

-- 8. Reset preserves folds for stable block IDs; detach clears UI state.
do
  local buf = fresh()
  renderer.reset(sample_blocks())
  renderer.close_block("r1")
  renderer.reset(sample_blocks())
  eq(false, renderer.get_fold_state(vim.api.nvim_get_current_win(), "r1"), "fold state survives reset")
  ok(renderer.detach() ~= nil, "detach returns renderer")
  eq(false, renderer.is_attached(), "detached state")
  -- Reattach to the same buffer and reload without duplicating old content.
  renderer.attach({ buffer = buf, window = vim.api.nvim_get_current_win() })
  renderer.reset({ block("only", "assistant", "fresh history", { sequence = 1 }) })
  eq({ "fresh history", "" }, buf_lines(buf), "reattach replaces old history cleanly")
  cleanup()
end

-- 9. Read-only buffer still supports Visual selection and yank.
do
  local buf = fresh()
  renderer.reset(sample_blocks())
  local lnum = renderer.get_layout("u1").start_line
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal! V")
  vim.cmd("normal! y")
  local reg = vim.fn.getreg('"')
  contains(reg, "User", "visual yank works on read-only buffer")
  cleanup()
end

-- 10. Flat block lists with string child IDs resolve into the tree.
do
  local buf = fresh()
  renderer.reset({
    {
      id = "parent",
      type = "tool",
      sequence = 1,
      status = "completed",
      content = "edit",
      metadata = { input = { filePath = "a.lua" } },
      children = { "kid" },
    },
    {
      id = "kid",
      parent_id = "parent",
      type = "diff",
      sequence = 2,
      status = "completed",
      content = "@@ -1 +1 @@\n-old\n+new",
    },
  })
  local all = text(buf)
  contains(all, "▼ edit", "parent tool rendered")
  contains(all, "@@ -1 +1 @@", "string child diff rendered")
  contains(all, "+new", "string child diff body complete")
  ok(renderer.get_layout("kid") ~= nil, "child layout tracked")
  eq(false, renderer.get_layout("kid").root, "child is not a root")
  cleanup()
end

-- 10b. String child IDs resolve through an optional lookup (05C snapshot shape).
do
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local kids = {
    kid = {
      id = "kid",
      parent_id = "parent",
      type = "diff",
      sequence = 0,
      status = "completed",
      content = "@@ -2 +2 @@\n-old\n+new",
    },
  }
  renderer.attach({
    buffer = buf,
    window = win,
    lookup = function(id)
      return kids[id]
    end,
  })
  renderer.reset({
    {
      id = "parent",
      type = "tool",
      sequence = 1,
      status = "completed",
      content = "edit",
      metadata = { output = "done" },
      children = { "kid" },
    },
  })
  local all = text(buf)
  contains(all, "▼ edit", "lookup tool parent rendered")
  contains(all, "@@ -2 +2 @@", "lookup child diff rendered")
  eq(false, renderer.get_layout("kid").root, "lookup child attached to parent")
  cleanup()
end

-- 11. Unknown event detail can be expanded.
do
  local buf = fresh()
  renderer.reset({ block("x2", "unknown", { kind = "new.part", nested = { value = 42 } }) })
  contains(text(buf), "new.part", "unknown raw content shown")
  renderer.open_block("x2")
  contains(text(buf), "42", "unknown detail expanded")
  cleanup()
end

-- 12. The complete public API is present.
do
  for _, name in ipairs({
    "attach", "reset", "apply_change",
    "open_block", "close_block", "toggle_block",
    "attach_window", "detach_window", "detach",
  }) do
    eq("function", type(renderer[name]), name .. " is exported")
  end
end

-- 12b. Common change shapes (bare block, blocks reset, remove id) work.
do
  local buf = fresh()
  renderer.reset({ block("shape_a", "assistant", "one", { sequence = 1 }) })
  renderer.apply_change({
    id = "shape_a",
    type = "assistant",
    content = "two",
    sequence = 1,
    status = "completed",
  })
  contains(text(buf), "two", "bare block change")
  renderer.apply_change({
    type = "update",
    blocks = { block("shape_b", "user", "replacement", { sequence = 1 }) },
  })
  contains(text(buf), "replacement", "blocks snapshot change")
  eq(nil, renderer.get_layout("shape_a"), "old block replaced")
  renderer.apply_change({ type = "remove", id = "shape_b" })
  eq(nil, renderer.get_layout("shape_b"), "remove id change")
  cleanup()
end

-- 13. Incremental updates only touch the changed lines and keep anchor marks.
do
  local buf = fresh()
  local blocks = {}
  for i = 1, 10 do
    blocks[i] = block("a" .. i, "assistant", "message " .. i .. "\nline two", { sequence = i })
  end
  renderer.reset(blocks)

  local anchor_before = renderer.get_anchor("a8")
  ok(anchor_before ~= nil, "a8 anchor exists")
  local old_start = renderer.get_layout("a3").start_line
  local changes = {}
  local recording = true
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, last, new_last)
      if recording then
        changes[#changes + 1] = { first = first, last = last, new_last = new_last }
      end
    end,
  })

  renderer.apply_change({
    upsert = block("a3", "assistant", "message 3\nline two\nadded one\nadded two", { sequence = 3 }),
  })
  recording = false

  eq(1, #changes, "one buffer edit for one block change")
  ok(changes[1].first >= old_start - 1, "edit starts at or after changed block")
  eq(2, changes[1].new_last - changes[1].last, "only the two added lines are written")

  local anchor_after = renderer.get_anchor("a8")
  ok(anchor_after ~= nil, "a8 anchor survives update")
  eq(anchor_before.mark, anchor_after.mark, "same extmark id below insertion")
  eq(anchor_before.line + 2, anchor_after.line, "anchor shifts with inserted lines")
  eq(anchor_after.line, renderer.get_layout("a8").start_line, "anchor matches layout")
  contains(text(buf), "added two", "changed block rendered")
  contains(text(buf), "message 1", "unrelated block intact")
  cleanup()
end

-- 13b. An update elsewhere preserves extmarks owned by unrelated blocks.
do
  local buf = fresh()
  renderer.reset({
    block("u4", "user", "first", { sequence = 1 }),
    block("d4", "diff", sample_diff, { sequence = 2, metadata = { file = "src/example.lua" } }),
  })
  local ns = vim.api.nvim_get_namespaces()["opencode_render_hl"]
  local function highlight_ids()
    local ids = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local group = mark[4] and mark[4].hl_group or ""
      if group:match("^OpencodeDiff") then
        ids[#ids + 1] = mark[1]
      end
    end
    table.sort(ids)
    return ids
  end
  local before = highlight_ids()
  ok(#before > 0, "diff highlights initially present")
  renderer.apply_change({ upsert = block("u4", "user", "first\nsecond", { sequence = 1 }) })
  eq(before, highlight_ids(), "unrelated highlight extmarks keep their ids")
  cleanup()
end

-- 14. Native fold commands work and their state survives incremental updates.
do
  local buf, win = fresh()
  renderer.reset({
    block("r3", "reasoning", "thinking\nmore thinking", { sequence = 1 }),
    block("t3", "tool", { output = "first" }, { sequence = 2, metadata = { tool = "bash" } }),
  })
  eq(false, renderer.get_fold_state(win, "r3"), "reasoning starts folded")
  vim.api.nvim_win_set_cursor(win, { renderer.get_layout("r3").start_line, 0 })
  vim.cmd("normal! za")
  eq(true, renderer.get_fold_state(win, "r3"), "za opens reasoning")
  vim.cmd("normal! zM")
  eq(false, renderer.get_fold_state(win, "r3"), "zM closes all folds")
  vim.cmd("normal! zR")
  eq(true, renderer.get_fold_state(win, "t3"), "zR opens all folds")

  vim.api.nvim_win_set_cursor(win, { renderer.get_layout("t3").start_line, 0 })
  vim.cmd("normal! zc")
  eq(false, renderer.get_fold_state(win, "t3"), "zc closes tool block")
  renderer.apply_change({
    upsert = block("t3", "tool", { output = "first\nsecond" }, { sequence = 2, metadata = { tool = "bash" } }),
  })
  eq(false, renderer.get_fold_state(win, "t3"), "native fold state survives update")
  cleanup()
end

-- 15. Long content can be fully expanded with one open_block call.
do
  local lines = {}
  for i = 1, 20 do
    lines[i] = "assistant line " .. i
  end
  local diff_lines = {}
  for i = 1, 20 do
    diff_lines[i] = "+diff line " .. i
  end
  local buf = fresh({ max_lines = 4 })
  renderer.reset({
    block("longa", "assistant", table.concat(lines, "\n"), { sequence = 1 }),
    block("longd", "diff", table.concat(diff_lines, "\n"), { sequence = 2 }),
  })
  local initial = text(buf)
  contains(initial, "more lines (za to expand)", "limit marker visible")
  contains(initial, "assistant line 20", "assistant remainder retained")
  contains(initial, "+diff line 20", "diff remainder retained")
  eq(true, renderer.open_block("longa"), "open assistant remainder")
  eq(true, renderer.open_block("longd"), "open diff remainder")
  contains(text(buf), "assistant line 20", "assistant full content reachable")
  contains(text(buf), "+diff line 20", "diff full content reachable")
  cleanup()
end

-- 16. Removing a parent removes its rendered children.
do
  local buf = fresh()
  local child = {
    id = "kid3",
    type = "diff",
    sequence = 2,
    status = "completed",
    content = "@@ -1 +1 @@\n-old\n+new",
  }
  renderer.reset({
    {
      id = "parent3",
      type = "tool",
      sequence = 1,
      status = "completed",
      content = "edit",
      metadata = { output = "done" },
      children = { child },
    },
  })
  ok(renderer.get_layout("kid3") ~= nil, "child initially rendered")
  renderer.apply_change({ removed = { "parent3" } })
  eq(nil, renderer.get_layout("parent3"), "parent removed")
  eq(nil, renderer.get_layout("kid3"), "child removed with parent")
  eq(nil, text(buf):find("+new", 1, true), "child content removed")
  cleanup()
end

-- 17. Window fold options are restored on detach.
do
  vim.cmd("silent! only")
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("foldmethod", "indent", { win = win })
  vim.api.nvim_set_option_value("foldenable", false, { win = win })
  vim.api.nvim_set_option_value("foldlevel", 2, { win = win })
  renderer.attach({ buffer = buf, window = win })
  renderer.reset({ block("opt", "reasoning", "body", { sequence = 1 }) })
  eq("manual", vim.api.nvim_get_option_value("foldmethod", { win = win }), "renderer uses manual folds")
  renderer.detach()
  eq("indent", vim.api.nvim_get_option_value("foldmethod", { win = win }), "foldmethod restored")
  eq(false, vim.api.nvim_get_option_value("foldenable", { win = win }), "foldenable restored")
  eq(2, vim.api.nvim_get_option_value("foldlevel", { win = win }), "foldlevel restored")
  cleanup()
end

-- 18. The 05C block model and fixture drive the renderer end to end.
do
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
  local blocks_mod = require("opencode.blocks")
  local fixture = dofile(root .. "/tests/fixtures/conversation/basic.lua")
  local model = blocks_mod.new()
  local reset_change = nil
  model:subscribe(function(change)
    reset_change = change
  end)
  model:apply_batch({ generation = 1, snapshot = fixture.snapshot, events = fixture.events })
  eq("reset", reset_change.kind, "05C emits a reset change")

  vim.cmd("silent! only")
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  renderer.attach({
    buffer = buf,
    window = win,
    lookup = model,
  })
  renderer.apply_change(reset_change)
  local rendered = text(buf)
  contains(rendered, "Please update a.lua", "05C user message")
  contains(rendered, "Working on it. Streaming", "05C assistant delta")
  contains(rendered, "Reasoning", "05C reasoning block")
  contains(rendered, "▼ edit", "05C tool block")
  contains(rendered, "updated", "05C tool output")
  contains(rendered, "@@ -10,4 +10,5 @@", "05C first hunk")
  contains(rendered, "@@ -30,2 +31,2 @@", "05C second hunk")
  contains(rendered, "src/b.lua", "05C second diff file")
  contains(rendered, "Permission: edit", "05C permission status")
  contains(rendered, "retrying (attempt 2)", "05C retry status")
  contains(rendered, "compacting", "05C compaction status")
  contains(rendered, "session.future.thing", "05C unknown event")
  ok(renderer.get_layout("prt_tool") ~= nil, "05C tool layout")
  ok(renderer.get_layout("prt_reasoning") ~= nil, "05C reasoning layout")
  eq(false, renderer.get_layout("prt_tool").root, "05C tool is a child")
  ok(renderer.get_layout("perm_1") ~= nil, "05C permission child layout")

  local update_change = nil
  local unsubscribe = model:subscribe(function(change)
    update_change = change
  end)
  model:apply_event({
    id = "evt_render_delta",
    type = "message.part.delta",
    data = {
      sessionID = "ses_fixture",
      messageID = "msg_assistant",
      partID = "prt_text",
      field = "text",
      delta = " Rendered.",
    },
  })
  unsubscribe()
  renderer.apply_change(update_change)
  contains(text(buf), "Rendered.", "05C incremental change rendered")
  model:destroy()
  cleanup()
end

-- 19. A 05C reset change carries all blocks even without an explicit lookup.
do
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
  local blocks_mod = require("opencode.blocks")
  local fixture = dofile(root .. "/tests/fixtures/conversation/basic.lua")
  local model = blocks_mod.new()
  local reset_change = nil
  model:subscribe(function(change)
    reset_change = change
  end)
  model:apply_batch({ generation = 1, snapshot = fixture.snapshot, events = fixture.events })

  local buf = fresh()
  renderer.apply_change(reset_change)
  local rendered = text(buf)
  contains(rendered, "▼ edit", "reset change tool without lookup")
  contains(rendered, "@@ -10,4 +10,5 @@", "reset change child diff without lookup")
  eq(false, renderer.get_layout("prt_tool").root, "child remains nested without lookup")
  model:destroy()
  cleanup()
end

io.stdout:write(string.format("headless renderer: %d checks, %d failures\n", checks, failures))
local shared_runner = vim.env.NVIM_APPNAME == "opencode-test-runner"
if shared_runner then
  local ok, test = pcall(require, "tests.support.test")
  if ok then
    test.it("renders structured blocks into a real message buffer", function()
      if failures > 0 then
        error(string.format("headless renderer: %d failures", failures))
      end
    end)
  elseif failures > 0 then
    error(string.format("headless renderer: %d failures", failures))
  end
elseif failures > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
