-- Headless tests for the native neovim_diff view.
-- Run through tests/headless/tools/diff/run.sh so XDG directories, shada,
-- temporary files and the working directory are isolated under /tmp/opencode.

local root = assert(vim.env.OPENCODE_DIFF_TEST_ROOT, "OPENCODE_DIFF_TEST_ROOT is required")
local project = assert(vim.env.OPENCODE_DIFF_TEST_PROJECT, "OPENCODE_DIFF_TEST_PROJECT is required")

local function isolated(value)
  return type(value) == "string" and value:sub(1, #"/tmp/opencode/") == "/tmp/opencode/"
end

for _, name in ipairs({
  "HOME",
  "XDG_CONFIG_HOME",
  "XDG_DATA_HOME",
  "XDG_STATE_HOME",
  "XDG_CACHE_HOME",
  "XDG_RUNTIME_DIR",
  "TMPDIR",
}) do
  if not isolated(vim.env[name]) then
    io.stderr:write(
      ("refusing to run diff tests: %s is not isolated under /tmp/opencode; use tests/headless/tools/diff/run.sh\n"):format(name)
    )
    vim.cmd("cquit 2")
  end
end
if not isolated(project) then
  io.stderr:write("refusing to run diff tests: project is not isolated under /tmp/opencode\n")
  vim.cmd("cquit 2")
end

package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local test = require("tests.support.test")
local protocol = require("opencode.tools.protocol")
local diff = require("opencode.tools.diff")

vim.o.showmode = false
vim.o.ruler = false
vim.o.report = 9999
vim.o.more = false
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.undofile = false

local sequence = 0
local WINDOW_OPTIONS = {
  "diff",
  "scrollbind",
  "cursorbind",
  "foldmethod",
  "foldcolumn",
  "foldenable",
  "foldlevel",
  "wrap",
}

local function unique(name)
  sequence = sequence + 1
  return ("%02d-%s"):format(sequence, name)
end

local function make_file(name, lines)
  local path = vim.fs.joinpath(project, name)
  local parent = vim.fs.dirname(path)
  if parent and parent ~= project then
    vim.fn.mkdir(parent, "p")
  end
  local written = vim.fn.writefile(lines, path)
  test.equal(0, written, "write test fixture")
  return path
end

local function edit(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function window_count()
  return #vim.api.nvim_tabpage_list_wins(0)
end

local function reset()
  diff.close()
  pcall(vim.cmd, "silent! only")
  pcall(vim.cmd, "silent! diffoff")
  vim.cmd("silent! enew!")
  vim.bo.modifiable = true
  vim.bo.buftype = ""
  vim.bo.bufhidden = ""
  vim.bo.filetype = ""
  vim.bo.modified = false
  vim.wo.diff = false
  vim.wo.scrollbind = false
  vim.wo.cursorbind = false
  vim.wo.foldmethod = "manual"
  vim.wo.foldcolumn = "0"
  vim.wo.foldenable = true
  vim.wo.wrap = true
end

local function with_diff(fn)
  reset()
  local ok, err = pcall(fn)
  reset()
  if not ok then
    error(err, 0)
  end
end

local function capture_window(win)
  local captured = {}
  for _, name in ipairs(WINDOW_OPTIONS) do
    captured[name] = vim.wo[win][name]
  end
  captured.view = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
  return captured
end

local function assert_window_options(win, expected, label)
  for _, name in ipairs(WINDOW_OPTIONS) do
    test.equal(expected[name], vim.wo[win][name], (label or "window") .. " " .. name .. " restored")
  end
end

local function assert_saved_view(win, saved, label)
  local current = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
  for _, name in ipairs({ "lnum", "col", "curswant", "topline", "topfill", "leftcol", "skipcol" }) do
    test.equal(saved[name], current[name], (label or "window") .. " view." .. name .. " restored")
  end
end

local function assert_protocol_error(err, expected_code)
  test.equal("table", type(err), "error is a table")
  if type(err) ~= "table" then
    return
  end
  test.equal(expected_code, err.code, "error code")
  test.equal("string", type(err.message), "error message is a string")
  test.truthy(type(err.message) == "string" and #err.message > 0, "error message is not empty")
  local normalized = protocol.normalize_error(err)
  test.equal(err.code, normalized.code, "error satisfies 09A normalize_error")
  test.equal(err.message, normalized.message, "error message survives normalize_error")
  test.equal("number", type(protocol.status_for_code(err.code)), "error maps to an HTTP status")
end

local function assert_scratch(proposed_buf, expected_lines, expected_filetype)
  test.truthy(vim.api.nvim_buf_is_valid(proposed_buf), "proposed buffer is valid")
  test.equal("nofile", vim.bo[proposed_buf].buftype, "proposed is a scratch buffer")
  test.equal(false, vim.bo[proposed_buf].buflisted, "proposed is not listed")
  test.equal(false, vim.bo[proposed_buf].swapfile, "proposed has no swap file")
  test.equal(false, vim.bo[proposed_buf].modifiable, "proposed is not modifiable")
  test.equal(true, vim.bo[proposed_buf].readonly, "proposed is readonly")
  test.equal(false, vim.bo[proposed_buf].modified, "proposed is not marked modified")
  test.equal(expected_filetype, vim.bo[proposed_buf].filetype, "proposed filetype")
  test.equal("", vim.api.nvim_buf_get_name(proposed_buf), "proposed has no file name")
  test.deep_equal(expected_lines, buf_lines(proposed_buf), "proposed content")
end

local function open_diff(input, ctx)
  local result, err = diff.handle(input, ctx or { project_root = project })
  test.falsy(err, "diff succeeds: " .. vim.inspect(err))
  test.truthy(result, "diff returns a result")
  return result
end

test.describe("native diff action", function()
  test.it("validates input and uses the 09A error structure", function()
    with_diff(function()
      local before = window_count()

      local result, err = diff.handle(nil, { project_root = project })
      test.falsy(result, "nil input is rejected")
      assert_protocol_error(err, "INVALID_REQUEST")

      result, err = diff.handle({ path = "", proposed = "x" }, { project_root = project })
      test.falsy(result, "empty path is rejected")
      assert_protocol_error(err, "INVALID_REQUEST")

      result, err = diff.handle({ path = "a.lua" }, { project_root = project })
      test.falsy(result, "missing proposed is rejected")
      assert_protocol_error(err, "INVALID_REQUEST")

      result, err = diff.handle({ path = "a.lua", proposed = 1 }, { project_root = project })
      test.falsy(result, "non-string proposed is rejected")
      assert_protocol_error(err, "INVALID_REQUEST")

      result, err = diff.execute({ path = "a.lua", proposed = "x" }, { project_root = 42 })
      test.falsy(result, "invalid project_root is rejected")
      assert_protocol_error(err, "INVALID_REQUEST")

      result, err = diff.handle({ path = "../escape.lua", proposed = "x" }, { project_root = project })
      test.falsy(result, "relative path escape is rejected")
      assert_protocol_error(err, "INVALID_REQUEST")

      result, err = diff.handle({ path = "~/outside.lua", proposed = "x" }, { project_root = project })
      test.falsy(result, "home-relative path is rejected")
      assert_protocol_error(err, "INVALID_REQUEST")

      result, err = diff.handle({ path = "/tmp/outside.lua", proposed = "x" }, { project_root = project })
      test.falsy(result, "absolute path outside project is rejected")
      assert_protocol_error(err, "INVALID_REQUEST")

      result, err = diff.handle({ path = unique("missing.lua"), proposed = "x" }, { project_root = project })
      test.falsy(result, "missing file is rejected")
      assert_protocol_error(err, "NOT_FOUND")

      local directory = unique("a-directory")
      vim.fn.mkdir(vim.fs.joinpath(project, directory), "p")
      result, err = diff.handle({ path = directory, proposed = "x" }, { project_root = project })
      test.falsy(result, "directory target is rejected")
      assert_protocol_error(err, "INVALID_REQUEST")

      test.equal(before, window_count(), "validation errors do not change windows")
      test.falsy(diff.get_view(), "validation errors do not create a view")
    end)
  end)

  test.it("exposes execute and handler factories used by the 09A integration", function()
    with_diff(function()
      local name = unique("api.lua")
      local path = make_file(name, { "api" })
      local original_buf = edit(path)
      local before_windows = window_count()

      test.equal("function", type(diff.execute), "execute is exported")
      test.equal("function", type(diff.handler), "handler factory is exported")
      test.equal("function", type(diff.handle), "handle is exported")
      test.equal("function", type(diff.close), "close is exported")
      test.equal("function", type(diff.is_open), "is_open is exported")
      test.equal("function", type(diff.get_view), "get_view is exported")

      local handler = diff.handler({ project_root = project })
      test.equal("function", type(handler), "handler factory returns a function")
      local result, err = handler({ path = name, proposed = "from handler\n" })
      test.falsy(err, "factory handler succeeds")
      test.truthy(result, "factory handler returns a result")
      local view = diff.get_view()
      test.equal(original_buf, view.original_buf, "factory handler uses the loaded buffer")
      test.deep_equal({ "from handler" }, buf_lines(view.proposed_buf), "factory handler content")
      diff.close()
      test.equal(before_windows, window_count(), "factory handler close restores layout")

      result, err = diff.execute({ path = name, proposed = "from execute" }, { project_root = project })
      test.falsy(err, "execute succeeds")
      test.truthy(result, "execute returns a result")
      view = diff.get_view()
      test.deep_equal({ "from execute" }, buf_lines(view.proposed_buf), "execute content")
      diff.close()
      test.equal(before_windows, window_count(), "execute close restores layout")

      -- ctx.project_root takes precedence over the factory fallback.
      local other_root = vim.fs.joinpath(project, "other-root")
      vim.fn.mkdir(other_root, "p")
      local contextual = diff.handler({ project_root = other_root })
      result, err = contextual({ path = path, proposed = "context root" }, { project_root = project })
      test.falsy(err, "context project_root is used")
      test.truthy(result, "contextual handler returns a result")
      diff.close()
    end)
  end)

  test.it("uses unsaved buffer content, keeps the buffer intact and never writes", function()
    with_diff(function()
      local name = unique("memory.lua")
      local path = make_file(name, { "disk one", "disk two" })
      local original_buf = edit(path)
      vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "memory one", "memory two" })
      vim.bo[original_buf].filetype = "lua"
      local original_ft = vim.bo[original_buf].filetype
      local before_windows = window_count()

      local result = open_diff({
        path = name,
        proposed = "proposal one\nproposal two\n",
      })

      test.equal(path, result.path, "result path is canonical")
      local view = diff.get_view()
      test.truthy(view, "view exists")
      test.truthy(diff.is_open(), "diff is open")
      test.equal(original_buf, view.original_buf, "original buffer reused")
      test.equal(before_windows + 1, window_count(), "one proposed window added")
      test.equal(original_buf, vim.api.nvim_win_get_buf(view.original_win), "original window shows original")
      test.equal(view.proposed_buf, vim.api.nvim_win_get_buf(view.proposed_win), "proposed window shows scratch")
      test.equal(view.proposed_win, vim.api.nvim_get_current_win(), "proposed window focused")

      assert_scratch(view.proposed_buf, { "proposal one", "proposal two" }, "lua")

      test.equal(true, vim.wo[view.original_win].diff, "original diff enabled")
      test.equal(true, vim.wo[view.proposed_win].diff, "proposed diff enabled")
      test.equal(true, vim.wo[view.original_win].scrollbind, "original scrollbind")
      test.equal(true, vim.wo[view.proposed_win].scrollbind, "proposed scrollbind")
      test.equal(true, vim.wo[view.original_win].cursorbind, "original cursorbind")
      test.equal(true, vim.wo[view.proposed_win].cursorbind, "proposed cursorbind")
      test.equal("diff", vim.wo[view.original_win].foldmethod, "original diff folding")
      test.equal("diff", vim.wo[view.proposed_win].foldmethod, "proposed diff folding")

      test.deep_equal({ "memory one", "memory two" }, buf_lines(original_buf), "original buffer content")
      test.equal(true, vim.bo[original_buf].modified, "original modified flag preserved")
      test.equal(original_ft, vim.bo[original_buf].filetype, "original filetype preserved")
      test.deep_equal({ "disk one", "disk two" }, vim.fn.readfile(path), "disk content untouched")

      diff.close()
      test.falsy(diff.is_open(), "close reports closed")
      test.equal(before_windows, window_count(), "close removes the proposed window")
      test.equal(original_buf, vim.api.nvim_get_current_buf(), "focus returns to the original buffer")
      test.deep_equal({ "memory one", "memory two" }, buf_lines(original_buf), "content survives close")
      test.equal(true, vim.bo[original_buf].modified, "modified flag survives close")
      test.equal(original_ft, vim.bo[original_buf].filetype, "filetype survives close")
      test.falsy(vim.api.nvim_buf_is_valid(view.proposed_buf), "proposed scratch buffer is wiped")
      test.deep_equal({ "disk one", "disk two" }, vim.fn.readfile(path), "close never writes")
      test.equal(true, diff.close(), "close is idempotent")
    end)
  end)

  test.it("keeps an already loaded buffer even when the disk changed underneath", function()
    with_diff(function()
      local name = unique("stale.lua")
      local path = make_file(name, { "version one" })
      local original_buf = edit(path)
      vim.fn.writefile({ "version two" }, path)
      test.equal(false, vim.bo[original_buf].modified, "loaded buffer starts unmodified")
      local before_windows = window_count()

      open_diff({ path = name, proposed = "proposed\n" })
      local view = diff.get_view()
      test.truthy(view, "view exists")
      test.deep_equal({ "version one" }, buf_lines(original_buf), "buffer content is the diff base")
      test.equal(false, vim.bo[original_buf].modified, "unmodified state is kept")
      test.equal(vim.bo[original_buf].filetype, vim.bo[view.proposed_buf].filetype, "loaded filetype preserved")
      test.deep_equal({ "version two" }, vim.fn.readfile(path), "disk is not reloaded into the buffer")

      diff.close()
      test.deep_equal({ "version one" }, buf_lines(original_buf), "buffer survives close")
      test.deep_equal({ "version two" }, vim.fn.readfile(path), "disk is never written")
      test.equal(before_windows, window_count(), "layout restored")
    end)
  end)

  test.it("restores diff, scrollbind, cursorbind, folds and the window view", function()
    with_diff(function()
      local name = unique("restore.lua")
      local lines = {}
      for i = 1, 200 do
        lines[i] = "line " .. i
      end
      local path = make_file(name, lines)
      local original_buf = edit(path)
      local original_win = vim.api.nvim_get_current_win()

      vim.wo[original_win].diff = false
      vim.wo[original_win].scrollbind = false
      vim.wo[original_win].cursorbind = false
      vim.wo[original_win].foldmethod = "marker"
      vim.wo[original_win].foldcolumn = "3"
      vim.wo[original_win].foldenable = false
      vim.wo[original_win].foldlevel = 2
      vim.wo[original_win].wrap = false
      vim.api.nvim_win_set_cursor(original_win, { 120, 2 })
      vim.cmd("normal! zt")
      local saved = capture_window(original_win)
      local before_windows = window_count()

      open_diff({ path = path, proposed = "replacement\n" })
      local view = diff.get_view()
      test.equal(true, vim.wo[view.original_win].diff, "diff enabled while open")
      test.equal("diff", vim.wo[view.original_win].foldmethod, "diff folding while open")

      vim.api.nvim_win_call(view.original_win, function()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd("normal! zt")
      end)

      diff.close()
      test.equal(before_windows, window_count(), "layout restored")
      test.equal(original_win, vim.api.nvim_get_current_win(), "focus restored")
      assert_window_options(original_win, saved, "original")
      assert_saved_view(original_win, saved.view, "original")
      test.equal(original_buf, vim.api.nvim_win_get_buf(original_win), "original window kept its buffer")
    end)
  end)

  test.it("restores a pre-existing diff window state", function()
    with_diff(function()
      local name = unique("pre-diff.lua")
      local path = make_file(name, { "alpha", "beta", "gamma" })
      local original_buf = edit(path)
      local original_win = vim.api.nvim_get_current_win()

      vim.cmd("diffthis")
      vim.wo[original_win].foldlevel = 1
      test.equal(true, vim.wo[original_win].diff, "test starts in diff mode")
      local saved = capture_window(original_win)
      local before_windows = window_count()

      open_diff({ path = name, proposed = "alpha\nbeta\ndelta\n" })
      diff.close()

      test.equal(before_windows, window_count(), "layout restored")
      test.equal(original_buf, vim.api.nvim_get_current_buf(), "original buffer focused")
      assert_window_options(original_win, saved, "pre-existing diff")
      assert_saved_view(original_win, saved.view, "pre-existing diff")
    end)
  end)

  test.it("leaves an existing diff group intact", function()
    with_diff(function()
      local a_name = unique("group-a.lua")
      local b_name = unique("group-b.lua")
      local a_path = make_file(a_name, { "alpha" })
      local b_path = make_file(b_name, { "beta" })
      local a_buf = edit(a_path)
      local a_win = vim.api.nvim_get_current_win()
      vim.cmd("vsplit " .. vim.fn.fnameescape(b_path))
      local b_win = vim.api.nvim_get_current_win()
      local b_buf = vim.api.nvim_get_current_buf()
      vim.cmd("diffthis")
      vim.api.nvim_set_current_win(a_win)
      vim.cmd("diffthis")
      local saved = capture_window(a_win)
      test.equal(2, window_count(), "two diff windows before action")

      open_diff({ path = a_name, proposed = "alpha changed\n" })
      test.equal(3, window_count(), "native diff adds one window")
      diff.close()

      test.equal(2, window_count(), "existing diff group layout restored")
      test.equal(a_buf, vim.api.nvim_win_get_buf(a_win), "original window keeps its buffer")
      test.equal(b_buf, vim.api.nvim_win_get_buf(b_win), "other diff window keeps its buffer")
      test.equal(true, vim.wo[b_win].diff, "other diff window stays in diff mode")
      assert_window_options(a_win, saved, "existing diff group")
      assert_saved_view(a_win, saved.view, "existing diff group")
    end)
  end)

  test.it("repeated diff closes the previous view without leaking windows or buffers", function()
    with_diff(function()
      local name = unique("repeat.lua")
      local path = make_file(name, { "disk" })
      local original_buf = edit(path)
      vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "unsaved" })
      local before_windows = window_count()

      open_diff({ path = name, proposed = "first" })
      local first = diff.get_view()
      test.truthy(first, "first view exists")
      test.equal(before_windows + 1, window_count(), "first view adds one window")

      open_diff({ path = name, proposed = "" })
      local second = diff.get_view()
      test.truthy(second, "second view exists")
      test.equal(before_windows + 1, window_count(), "repeated diff reuses the window count")
      test.equal(first.original_win, second.original_win, "original window reused")
      test.equal(first.original_buf, second.original_buf, "original buffer reused")
      test.truthy(first.proposed_buf ~= second.proposed_buf, "new proposed scratch buffer")
      test.falsy(vim.api.nvim_buf_is_valid(first.proposed_buf), "old proposed buffer wiped")
      test.truthy(first.proposed_win ~= second.proposed_win, "new proposed window")
      test.falsy(vim.api.nvim_win_is_valid(first.proposed_win), "old proposed window closed")
      test.deep_equal({ "" }, buf_lines(second.proposed_buf), "new proposed content")
      test.deep_equal({ "unsaved" }, buf_lines(original_buf), "original content untouched")
      test.equal(true, vim.bo[original_buf].modified, "original modified flag untouched")

      local other_name = unique("repeat-other.lua")
      make_file(other_name, { "other disk" })
      open_diff({ path = other_name, proposed = "other proposed\n" })
      local third = diff.get_view()
      test.truthy(third, "third view exists")
      test.equal(true, third.created_original, "different target opens its own original window")
      test.equal(before_windows + 2, window_count(), "different target replaces the old view")
      test.falsy(vim.api.nvim_buf_is_valid(second.proposed_buf), "second proposed buffer wiped")
      test.falsy(vim.api.nvim_win_is_valid(second.proposed_win), "second proposed window closed")
      test.truthy(vim.api.nvim_win_is_valid(second.original_win), "the first target window remains")
      test.deep_equal({ "unsaved" }, buf_lines(original_buf), "original content survives target switch")

      diff.close()
      test.equal(before_windows, window_count(), "all extra windows closed")
      test.falsy(vim.api.nvim_buf_is_valid(third.proposed_buf), "last proposed buffer wiped")
    end)
  end)

  test.it("cleans up when the user closes the proposed side", function()
    with_diff(function()
      local name = unique("manual-proposed.lua")
      local path = make_file(name, { "one", "two" })
      local original_buf = edit(path)
      local original_win = vim.api.nvim_get_current_win()
      vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "edited" })
      vim.wo[original_win].foldmethod = "marker"
      vim.wo[original_win].foldcolumn = "1"
      vim.wo[original_win].foldenable = false
      local saved = capture_window(original_win)
      local before_windows = window_count()

      open_diff({ path = name, proposed = "changed" })
      local view = diff.get_view()
      local proposed_buf = view.proposed_buf
      vim.api.nvim_win_close(view.proposed_win, true)

      test.truthy(
        vim.wait(1000, function()
          return diff.get_view() == nil
        end, 10),
        "manual close triggers cleanup"
      )
      test.falsy(diff.is_open(), "view reports closed")
      test.equal(before_windows, window_count(), "layout restored")
      test.equal(original_win, vim.api.nvim_get_current_win(), "original window focused")
      assert_window_options(original_win, saved, "manual close")
      assert_saved_view(original_win, saved.view, "manual close")
      test.deep_equal({ "edited" }, buf_lines(original_buf), "original content untouched")
      test.equal(true, vim.bo[original_buf].modified, "original modified flag untouched")
      test.falsy(vim.api.nvim_buf_is_valid(proposed_buf), "proposed buffer wiped")
      test.equal(true, diff.close(), "close remains safe after cleanup")
    end)
  end)

  test.it("close restores immediately after one side is closed manually", function()
    with_diff(function()
      local name = unique("manual-close.lua")
      local path = make_file(name, { "one", "two" })
      local original_buf = edit(path)
      local original_win = vim.api.nvim_get_current_win()
      vim.wo[original_win].foldmethod = "marker"
      vim.wo[original_win].foldcolumn = "4"
      vim.wo[original_win].foldenable = false
      local saved = capture_window(original_win)
      local before_windows = window_count()

      open_diff({ path = name, proposed = "changed\n" })
      local view = diff.get_view()
      local proposed_buf = view.proposed_buf
      vim.api.nvim_win_close(view.proposed_win, true)

      test.equal(true, diff.close(), "close works before the scheduled cleanup runs")
      test.falsy(diff.get_view(), "view cleared immediately")
      test.equal(before_windows, window_count(), "layout restored immediately")
      assert_window_options(original_win, saved, "immediate close")
      assert_saved_view(original_win, saved.view, "immediate close")
      test.falsy(vim.api.nvim_buf_is_valid(proposed_buf), "proposed buffer wiped")
      test.equal(original_buf, vim.api.nvim_get_current_buf(), "original buffer focused")
    end)
  end)

  test.it("cleans up when the user closes the original side", function()
    with_diff(function()
      local name = unique("manual-original.lua")
      local path = make_file(name, { "one", "two" })
      edit(path)
      local original_win = vim.api.nvim_get_current_win()
      vim.cmd("vnew")
      local other_win = vim.api.nvim_get_current_win()
      test.truthy(other_win ~= original_win, "second window created")
      local before_windows = window_count()

      open_diff({ path = name, proposed = "changed" })
      local view = diff.get_view()
      local proposed_buf = view.proposed_buf
      test.equal(before_windows + 1, window_count(), "diff opened")

      vim.api.nvim_win_close(original_win, true)
      test.truthy(
        vim.wait(1000, function()
          return diff.get_view() == nil
        end, 10),
        "closing the original side triggers cleanup"
      )
      test.falsy(diff.is_open(), "view reports closed")
      test.truthy(vim.api.nvim_win_is_valid(other_win), "unrelated window survives")
      test.falsy(vim.api.nvim_buf_is_valid(proposed_buf), "proposed buffer wiped")
      test.equal(true, diff.close(), "close remains safe after cleanup")
    end)
  end)

  test.it("restores the original buffer when the closed side was the last other window", function()
    with_diff(function()
      local name = unique("last-window.lua")
      local path = make_file(name, { "one", "two" })
      local original_buf = edit(path)
      local original_win = vim.api.nvim_get_current_win()
      vim.wo[original_win].foldmethod = "marker"
      vim.wo[original_win].foldcolumn = "2"
      vim.wo[original_win].foldenable = false
      vim.wo[original_win].wrap = false
      local saved = capture_window(original_win)
      test.equal(1, window_count(), "one window before diff")

      open_diff({ path = name, proposed = "changed\n" })
      local view = diff.get_view()
      local proposed_buf = view.proposed_buf
      test.equal(2, window_count(), "diff opened in two windows")

      vim.api.nvim_win_close(view.original_win, true)
      test.truthy(
        vim.wait(1000, function()
          return diff.get_view() == nil
        end, 10),
        "closing the original side triggers cleanup"
      )
      test.falsy(diff.is_open(), "view reports closed")
      test.equal(1, window_count(), "a usable window remains")
      test.equal(original_buf, vim.api.nvim_get_current_buf(), "the remaining window shows the original")
      local remaining = vim.api.nvim_get_current_win()
      assert_window_options(remaining, saved, "remaining window")
      assert_saved_view(remaining, saved.view, "remaining window")
      test.falsy(vim.api.nvim_buf_is_valid(proposed_buf), "proposed buffer wiped")
      test.deep_equal({ "one", "two" }, buf_lines(original_buf), "original content kept")
      test.equal(true, diff.close(), "close remains safe after cleanup")
    end)
  end)

  test.it("loads a not-yet-loaded target and restores created windows", function()
    with_diff(function()
      local name = unique("with space.lua")
      local path = make_file(name, { "disk line 1", "disk line 2" })
      local before_windows = window_count()
      test.equal(-1, vim.fn.bufnr(path), "target starts unloaded")

      local result = open_diff({ path = name, proposed = "new line\n" })
      local view = diff.get_view()
      test.truthy(view, "view exists")
      test.equal(true, view.created_original, "original window was created")
      test.equal(before_windows + 2, window_count(), "original and proposed windows added")
      test.equal(false, vim.bo[view.original_buf].modified, "loaded original is unmodified")
      test.deep_equal({ "disk line 1", "disk line 2" }, buf_lines(view.original_buf), "disk content loaded")
      assert_scratch(view.proposed_buf, { "new line" }, "lua")
      test.deep_equal({ "disk line 1", "disk line 2" }, vim.fn.readfile(path), "disk content untouched")

      diff.close()
      test.equal(before_windows, window_count(), "created original window removed")
      test.falsy(vim.api.nvim_buf_is_valid(view.proposed_buf), "proposed buffer wiped")
      test.deep_equal({ "disk line 1", "disk line 2" }, vim.fn.readfile(path), "close never writes")
    end)
  end)

  test.it("works when called from a fast libuv context", function()
    with_diff(function()
      local name = unique("async.lua")
      local path = make_file(name, { "old" })
      local original_buf = edit(path)
      local before_windows = window_count()

      local called = false
      local result
      local err
      local timer = assert(vim.uv.new_timer())
      timer:start(0, 0, function()
        timer:stop()
        timer:close()
        diff.handle({ path = path, proposed = "async new\n" }, {
          project_root = project,
          respond = function(responded_result, responded_err)
            result = responded_result
            err = responded_err
            called = true
          end,
        })
      end)

      test.truthy(vim.wait(2000, function()
        return called
      end, 10), "scheduled handler responds")
      test.falsy(err, "async handler succeeds")
      test.truthy(result, "async handler returns a result")
      test.truthy(diff.is_open(), "async diff is open")
      local view = diff.get_view()
      test.equal(original_buf, view.original_buf, "async diff uses the loaded buffer")
      test.equal(before_windows + 1, window_count(), "async diff opens one window")
      assert_scratch(view.proposed_buf, { "async new" }, "lua")

      diff.close()
      test.equal(before_windows, window_count(), "async diff closes")
    end)
  end)
end)

local ok = test.finish()
if not ok then
  vim.cmd("cquit 1")
end
vim.cmd("qall!")
