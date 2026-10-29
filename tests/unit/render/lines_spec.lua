-- Pure line-construction tests for the renderer (no windows/buffers needed).
-- Runs inside an isolated headless Neovim process through run.sh.

local lines_mod = require("opencode.render.lines")

local failures = 0
local checks = 0

local function fail(msg)
  failures = failures + 1
  io.stderr:write("FAIL: " .. msg .. "\n")
end

local function eq(expected, actual, msg)
  checks = checks + 1
  if not vim.deep_equal(expected, actual) then
    fail(msg .. "\n  expected: " .. vim.inspect(expected) .. "\n  actual:   " .. vim.inspect(actual))
  end
end

local function ok(value, msg)
  checks = checks + 1
  if not value then
    fail(msg)
  end
end

local function find_line(lines, needle)
  for i, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

local diff = table.concat({
  "diff --git a/one.lua b/one.lua",
  "--- a/one.lua",
  "+++ b/one.lua",
  "@@ -1,2 +1,3 @@",
  " local x",
  "-return x",
  "+return x or 1",
  "+-- done",
  "diff --git a/two.lua b/two.lua",
  "--- a/two.lua",
  "+++ b/two.lua",
  "@@ -5 +5 @@",
  "-old",
  "+new",
}, "\n")

local blocks = {
  { id = "u", type = "user", content = "hi\nthere", sequence = 1, status = "completed" },
  { id = "a", type = "assistant", content = "answer", sequence = 2, status = "streaming" },
  { id = "r", type = "reasoning", content = "thinking", sequence = 3, status = "completed" },
  {
    id = "t",
    type = "tool",
    sequence = 4,
    status = "completed",
    metadata = { tool = "edit", input = { filePath = "one.lua" } },
    content = { input = { filePath = "one.lua" }, output = "ok", diff = diff },
  },
  { id = "s", type = "status", content = "retrying", sequence = 5, status = "failed" },
  { id = "x", type = "unknown", content = { event = "future.thing" }, sequence = 6, status = "completed" },
}

local build = lines_mod.build(blocks, {})

-- Structure and content completeness.
eq("▌ User", build.lines[1], "user header")
ok(find_line(build.lines, "  hi") ~= nil, "user content indented")
ok(find_line(build.lines, "answer") ~= nil, "assistant content")
ok(find_line(build.lines, "Reasoning") ~= nil, "reasoning header")
ok(find_line(build.lines, "thinking") ~= nil, "reasoning content")
ok(find_line(build.lines, "Input") ~= nil, "tool input label")
ok(find_line(build.lines, "Output") ~= nil, "tool output label")
ok(find_line(build.lines, "ok") ~= nil, "tool output content")
ok(find_line(build.lines, "Diff") ~= nil, "diff section label")
ok(find_line(build.lines, "@@ -1,2 +1,3 @@") ~= nil, "first file hunk")
ok(find_line(build.lines, "@@ -5 +5 @@") ~= nil, "second file hunk")
ok(find_line(build.lines, "return x or 1") ~= nil, "addition content")
ok(find_line(build.lines, "return x") ~= nil, "deletion content")
ok(find_line(build.lines, "retrying") ~= nil, "status content")
ok(find_line(build.lines, "Unknown event") ~= nil, "unknown header")
ok(find_line(build.lines, "future.thing") ~= nil, "unknown raw content")

-- Fold regions: reasoning, tool, nested input/output/diff, unknown.
local folds = {}
for _, fold in ipairs(build.folds) do
  folds[fold.id] = fold
end
ok(folds["r"] ~= nil, "reasoning fold")
eq(false, folds["r"].default_open, "reasoning defaults folded")
ok(folds["t"] ~= nil, "tool block fold")
eq(true, folds["t"].default_open, "tool details inline and expanded by default")
ok(folds["t:input"] ~= nil, "tool input fold")
ok(folds["t:output"] ~= nil, "tool output fold")
eq(true, folds["t:output"].default_open, "tool output expanded by default")
ok(folds["t:diff"] ~= nil, "inline diff fold")
eq(true, folds["t:diff"].default_open, "inline diff expanded by default")
ok(folds["x"] ~= nil, "unknown fold")
eq(false, folds["x"].default_open, "unknown defaults folded")

-- Layout tracks nested blocks inside the parent range.
local by_id = {}
for _, info in ipairs(build.blocks) do
  by_id[info.id] = info
end
ok(by_id["u"] and by_id["t"], "block layouts present")
ok(by_id["t"].start_line < by_id["t"].end_line, "tool range spans content")
eq(true, by_id["u"].root, "user is root")
eq(true, by_id["t"].root, "tool is root")
eq("t", by_id["t"].id, "layout id normalized")

-- Highlights for diff roles.
local groups = {}
for _, hl in ipairs(build.highlights) do
  groups[hl.group] = true
end
ok(groups["OpencodeDiffAdd"], "addition highlight marker")
ok(groups["OpencodeDiffDelete"], "deletion highlight marker")
ok(groups["OpencodeDiffHunk"], "hunk highlight marker")
ok(groups["OpencodeDiffFile"], "file header highlight marker")
ok(groups["OpencodeError"], "failed status/error highlight")

-- Children are rendered in timeline order under the tool.
local child = {
  id = "child",
  type = "diff",
  parent_id = "t",
  sequence = 1,
  status = "completed",
  content = "@@ -1 +1 @@\n-a\n+b",
}
local with_child = lines_mod.build({
  {
    id = "t",
    type = "tool",
    sequence = 1,
    status = "completed",
    metadata = { tool = "apply_patch" },
    content = { output = "done" },
    children = { child },
  },
}, {})
ok(find_line(with_child.lines, "@@ -1 +1 @@") ~= nil, "nested diff child content")
ok(find_line(with_child.lines, "done") ~= nil, "tool output remains inline")

-- Explicit long-content limit: marker visible, all content retained.
local long_text = {}
for i = 1, 25 do
  long_text[i] = "line " .. i
end
local limited = lines_mod.build({
  { id = "long", type = "assistant", sequence = 1, content = table.concat(long_text, "\n"), status = "completed" },
}, { max_lines = 5 })
local marker = find_line(limited.lines, "more lines (za to expand)")
ok(marker ~= nil, "explicit expansion marker")
ok(find_line(limited.lines, "line 25") ~= nil, "remaining content retained")
eq(true, limited.folds[1].default_open ~= nil, "remainder fold created")
ok(find_line(limited.lines, "line 5") ~= nil, "first page boundary included")
ok(find_line(limited.lines, "line 6") ~= nil, "hidden content begins immediately after marker")

-- Structured diff content (05C shape) keeps file headers, hunks and line kinds.
local structured = {
  files = {
    {
      path = "src/a.lua",
      hunks = {
        {
          header = "@@ -10,4 +10,5 @@",
          lines = {
            { type = "context", text = " local value = get_value()" },
            { type = "remove", text = " return value" },
            { type = "add", text = " return value or default" },
            { type = "add", text = "+end" },
          },
        },
      },
    },
  },
}
local structured_build = lines_mod.build({
  { id = "d", type = "diff", sequence = 1, status = "completed", content = structured },
  {
    id = "t05c",
    type = "tool",
    sequence = 2,
    status = "running",
    content = "edit",
    metadata = {
      part = { tool = "edit", input = { filePath = "a.lua" }, output = "working" },
      input = { filePath = "a.lua" },
      output = "working",
    },
  },
}, {})
ok(find_line(structured_build.lines, "diff --git a/src/a.lua b/src/a.lua") ~= nil, "structured diff git header")
ok(find_line(structured_build.lines, "--- a/src/a.lua") ~= nil, "structured diff old file header")
ok(find_line(structured_build.lines, "+++ b/src/a.lua") ~= nil, "structured diff new file header")
ok(find_line(structured_build.lines, "@@ -10,4 +10,5 @@") ~= nil, "structured diff hunk header")
ok(find_line(structured_build.lines, "   local value = get_value()") ~= nil, "structured diff context line")
ok(find_line(structured_build.lines, " - return value") ~= nil, "structured diff removal prefixed")
ok(find_line(structured_build.lines, " + return value or default") ~= nil, "structured diff addition prefixed")
ok(find_line(structured_build.lines, " +end") ~= nil, "structured diff keeps existing prefix")
ok(find_line(structured_build.lines, "▼ edit") ~= nil, "05C tool block uses tool name from content/metadata")
ok(find_line(structured_build.lines, "working") ~= nil, "05C tool output from metadata.part")

-- Unknown events keep raw metadata inspectable.
local unknown_build = lines_mod.build({
  {
    id = "u",
    type = "unknown",
    sequence = 1,
    status = "unknown",
    content = "future.event",
    metadata = { raw = { type = "future.event", payload = { value = 7 } } },
  },
}, {})
ok(find_line(unknown_build.lines, "future.event") ~= nil, "unknown event name")
ok(find_line(unknown_build.lines, "value") ~= nil, "unknown raw payload retained")

-- Streaming tool: body visible while running.
local streaming = lines_mod.build({
  {
    id = "run",
    type = "tool",
    sequence = 1,
    status = "streaming",
    metadata = { tool = "bash" },
    content = { input = { command = "ls" }, output = "partial" },
  },
}, {})
local stream_fold
for _, fold in ipairs(streaming.folds) do
  if fold.id == "run" then
    stream_fold = fold
  end
end
ok(stream_fold ~= nil, "streaming tool fold")
eq(true, stream_fold.default_open, "streaming tool expanded")

-- Failed tool keeps an explicit error line.
local failed = lines_mod.build({
  {
    id = "bad",
    type = "tool",
    sequence = 1,
    status = "failed",
    metadata = { tool = "bash", error = "exit 1" },
    content = { output = "boom" },
  },
}, {})
ok(find_line(failed.lines, "Error: exit 1") ~= nil, "tool error details visible")
ok(find_line(failed.lines, "exit 1") ~= nil, "tool error summary in header")

local function folds_by_id(build_value)
  local result = {}
  for _, fold in ipairs(build_value.folds) do
    result[fold.id] = fold
  end
  return result
end

local function groups_of(build_value)
  local result = {}
  for _, highlight in ipairs(build_value.highlights) do
    result[highlight.group] = true
  end
  return result
end

-- 05C tool blocks use content as the tool name; it must not leak as output.
local tool_05c = lines_mod.build({
  {
    id = "edit05",
    type = "tool",
    sequence = 1,
    status = "running",
    content = "edit",
    metadata = {
      tool = "edit",
      input = { filePath = "src/x.lua" },
      output = "partial output",
    },
  },
}, {})
ok(find_line(tool_05c.lines, "▼ edit") ~= nil, "05C tool title")
ok(find_line(tool_05c.lines, "partial output") ~= nil, "05C tool output")
eq(nil, find_line(tool_05c.lines, "    edit"), "tool name is not repeated as output")
ok(find_line(tool_05c.lines, "edit") ~= nil, "tool name rendered once as title")

-- Tool input can be discovered through metadata.part.state.input.
local state_input = lines_mod.build({
  {
    id = "state_input",
    type = "tool",
    sequence = 1,
    status = "running",
    metadata = {
      part = { state = { input = { command = "ls -la" } } },
    },
  },
}, {})
ok(find_line(state_input.lines, "ls -la") ~= nil, "part.state.input summary")
ok(find_line(state_input.lines, "Input") ~= nil, "part.state.input section")

-- Multi-line errors keep the summary visible and every detail line.
local multiline_error = lines_mod.build({
  {
    id = "bad2",
    type = "tool",
    sequence = 1,
    status = "failed",
    metadata = {
      tool = "bash",
      error = "first failure line\nsecond failure line\nthird failure line",
    },
  },
}, {})
ok(find_line(multiline_error.lines, "Error: first failure line") ~= nil, "error summary line")
ok(find_line(multiline_error.lines, "second failure line") ~= nil, "error detail line two")
ok(find_line(multiline_error.lines, "third failure line") ~= nil, "error detail line three")

-- Diff context/header/add/remove each get their own highlight role.
local diff_roles = lines_mod.build({
  {
    id = "roles",
    type = "diff",
    sequence = 1,
    status = "completed",
    content = table.concat({
      "diff --git a/a.lua b/a.lua",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1 +1 @@",
      " context",
      "-old",
      "+new",
    }, "\n"),
  },
}, {})
local diff_groups = groups_of(diff_roles)
ok(diff_groups.OpencodeDiffFile, "diff file highlight")
ok(diff_groups.OpencodeDiffHunk, "diff hunk highlight")
ok(diff_groups.OpencodeDiffContext, "diff context highlight")
ok(diff_groups.OpencodeDiffAdd, "diff add highlight")
ok(diff_groups.OpencodeDiffDelete, "diff delete highlight")

-- Long diffs obey the same explicit limit/fold contract as other sections.
local long_diff = {}
for index = 1, 30 do
  long_diff[index] = "+line " .. index
end
local limited_diff = lines_mod.build({
  {
    id = "longdiff",
    type = "diff",
    sequence = 1,
    status = "completed",
    content = table.concat(long_diff, "\n"),
  },
}, { max_lines = 5 })
ok(find_line(limited_diff.lines, "more lines (za to expand)") ~= nil, "long diff marker")
ok(find_line(limited_diff.lines, "+line 30") ~= nil, "long diff content retained")
local limited_diff_folds = folds_by_id(limited_diff)
ok(limited_diff_folds["longdiff:rest"] ~= nil, "long diff rest fold")
eq(false, limited_diff_folds["longdiff:rest"].default_open, "long diff rest starts folded")

-- Markdown headings and fenced code are highlighted.
local markdown = lines_mod.build({
  {
    id = "md",
    type = "assistant",
    sequence = 1,
    status = "completed",
    content = "# Heading\n```lua\nprint('x')\n```\ntext",
  },
}, {})
local markdown_groups = groups_of(markdown)
ok(markdown_groups.OpencodeHeading, "markdown heading highlight")
ok(markdown_groups.OpencodeCode, "markdown code highlight")

-- Permission status blocks keep their semantic label and waiting marker.
local permission = lines_mod.build({
  {
    id = "perm",
    type = "status",
    sequence = 1,
    status = "waiting_permission",
    content = "edit",
    metadata = { kind = "permission" },
  },
}, {})
ok(find_line(permission.lines, "Permission: edit") ~= nil, "permission label")
ok(find_line(permission.lines, "?") ~= nil, "permission waiting marker")

-- Structured diff files preserve added/deleted headers and every hunk.
local multi_file = lines_mod.build({
  {
    id = "multi",
    type = "diff",
    sequence = 1,
    status = "completed",
    content = {
      files = {
        { path = "new.lua", status = "added", hunks = { { header = "@@ -0,0 +1 @@", lines = { { type = "add", text = "new" } } } } },
        { path = "gone.lua", status = "deleted", hunks = { { header = "@@ -1 +0,0 @@", lines = { { type = "remove", text = "gone" } } } } },
      },
    },
  },
}, {})
ok(find_line(multi_file.lines, "+++ /dev/null") ~= nil, "deleted file header")
ok(find_line(multi_file.lines, "--- /dev/null") ~= nil, "added file header")
ok(find_line(multi_file.lines, "@@ -0,0 +1 @@") ~= nil, "added file hunk")
ok(find_line(multi_file.lines, "@@ -1 +0,0 @@") ~= nil, "deleted file hunk")

-- Hunk headers are synthesized when only line numbers are available.
local synthesized = lines_mod.build({
  {
    id = "synthesized",
    type = "diff",
    sequence = 1,
    status = "completed",
    content = {
      files = {
        {
          path = "s.lua",
          hunks = {
            {
              old_start = 4,
              old_count = 2,
              new_start = 4,
              new_count = 3,
              lines = {
                { type = "context", text = " keep" },
                { type = "add", text = "+added" },
              },
            },
          },
        },
      },
    },
  },
}, {})
ok(find_line(synthesized.lines, "@@ -4,2 +4,3 @@") ~= nil, "synthesized hunk header")

-- A raw hunk-only file body still gets complete file headers.
local raw_hunk = lines_mod.build({
  {
    id = "rawhunk",
    type = "diff",
    sequence = 1,
    status = "completed",
    content = {
      files = {
        { path = "raw.lua", diff = "@@ -1 +1 @@\n-old\n+new" },
      },
    },
  },
}, {})
ok(find_line(raw_hunk.lines, "diff --git a/raw.lua b/raw.lua") ~= nil, "raw hunk git header")
ok(find_line(raw_hunk.lines, "--- a/raw.lua") ~= nil, "raw hunk old file header")
ok(find_line(raw_hunk.lines, "+++ b/raw.lua") ~= nil, "raw hunk new file header")
ok(find_line(raw_hunk.lines, "@@ -1 +1 @@") ~= nil, "raw hunk retained")

-- Tool names can come from structured content when metadata has no name.
local content_tool = lines_mod.build({
  {
    id = "contenttool",
    type = "tool",
    sequence = 1,
    status = "completed",
    content = { tool = "write", output = "written" },
  },
}, {})
ok(find_line(content_tool.lines, "▼ write") ~= nil, "content tool name")
ok(find_line(content_tool.lines, "written") ~= nil, "content tool output")

io.stdout:write(string.format("unit renderer: %d checks, %d failures\n", checks, failures))
local shared_runner = vim.env.NVIM_APPNAME == "opencode-test-runner"
if shared_runner then
  local ok, test = pcall(require, "tests.support.test")
  if ok then
    test.it("renders block trees to complete display lines", function()
      if failures > 0 then
        error(string.format("unit renderer: %d failures", failures))
      end
    end)
  elseif failures > 0 then
    error(string.format("unit renderer: %d failures", failures))
  end
elseif failures > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
