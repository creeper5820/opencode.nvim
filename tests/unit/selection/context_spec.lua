-- 04 shared selection context: modes, reverse/exclusive ranges, multibyte
-- columns, buffer metadata, in-memory text and Markdown fence safety.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local context = require("opencode.context")

local uv = vim.uv or vim.loop
local original_cwd = vim.fn.getcwd()
local original_selection = vim.o.selection
local tempdirs = {}
local buffers = {}

local function tempdir(label)
  local base = "/tmp/opencode"
  if not uv.fs_stat(base) then
    uv.fs_mkdir(base, 448)
  end
  local dir = ("%s/nvim-04-context-%s-%d-%x"):format(base, label or "tmp", uv.os_getpid(), uv.hrtime())
  local ok, err = uv.fs_mkdir(dir, 448)
  assert(ok, "cannot create selection test directory: " .. tostring(err))
  tempdirs[#tempdirs + 1] = dir
  return dir
end

local function cleanup()
  pcall(vim.cmd, "silent! only")
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  buffers = {}
  vim.o.selection = original_selection
  pcall(vim.cmd, "silent! cd " .. vim.fn.fnameescape(original_cwd))
  for _, dir in ipairs(tempdirs) do
    if dir:match("^/tmp/opencode/nvim%-04%-context%-") then
      vim.fn.delete(dir, "rf")
    end
  end
  tempdirs = {}
end

local function case(fn)
  return function()
    local ok, err = pcall(fn)
    cleanup()
    if not ok then
      error(err, 0)
    end
  end
end

local function scratch(lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = buf
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = opts.filetype or ""
  if opts.name then
    vim.api.nvim_buf_set_name(buf, opts.name)
  end
  return buf
end

local function select(buf, selection)
  local ctx, err = context.from_selection(buf, selection)
  assert(ctx, tostring(err))
  return ctx
end

test.describe("selection context extraction", function()
  test.it("extracts charwise, linewise and blockwise ranges in both directions", case(function()
    local buf = scratch({ "alpha", "beta", "gamma" })

    local forward = select(buf, {
      mode = "v",
      start = { row = 1, col = 2 },
      ["end"] = { row = 2, col = 3 },
    })
    test.equal("charwise", forward.mode)
    test.equal("lpha\nbet", forward.text)
    test.equal(1, forward.start_line)
    test.equal(2, forward.end_line)

    local reverse = select(buf, {
      mode = "v",
      start = { row = 2, col = 3 },
      ["end"] = { row = 1, col = 2 },
    })
    test.equal(forward.text, reverse.text, "reverse selection has the same ordered text")
    test.equal(forward.start_line, reverse.start_line)
    test.equal(forward.end_line, reverse.end_line)

    local linewise = select(buf, {
      mode = "V",
      start = { row = 1, col = 4 },
      ["end"] = { row = 2, col = 1 },
    })
    test.equal("linewise", linewise.mode)
    test.equal("alpha\nbeta", linewise.text)
    test.equal(1, linewise.start_line)
    test.equal(2, linewise.end_line)

    local block = select(buf, {
      mode = "\22",
      start = { row = 1, col = 2 },
      ["end"] = { row = 3, col = 3 },
    })
    test.equal("blockwise", block.mode)
    test.equal(table.concat({ "lp", "et", "am" }, "\n"), block.text)

    local block_reverse = select(buf, {
      mode = "\22",
      start = { row = 3, col = 3 },
      ["end"] = { row = 1, col = 2 },
    })
    test.equal(block.text, block_reverse.text, "reverse block has the same ordered text")
  end))

  test.it("honors exclusive selections and the single-character exception", case(function()
    local buf = scratch({ "alpha", "beta" })

    local inclusive = select(buf, {
      mode = "v",
      start = { row = 1, col = 2 },
      ["end"] = { row = 1, col = 5 },
      exclusive = false,
    })
    test.equal("lpha", inclusive.text)

    local exclusive = select(buf, {
      mode = "v",
      start = { row = 1, col = 2 },
      ["end"] = { row = 1, col = 5 },
      exclusive = true,
    })
    test.equal("lph", exclusive.text, "the ordered end character is excluded")

    local cross_line = select(buf, {
      mode = "v",
      start = { row = 1, col = 2 },
      ["end"] = { row = 2, col = 1 },
      exclusive = true,
    })
    test.equal("lpha\n", cross_line.text, "exclusive column 1 includes the preceding newline")

    local single = select(buf, {
      mode = "v",
      start = { row = 1, col = 3 },
      ["end"] = { row = 1, col = 3 },
      exclusive = true,
    })
    test.equal("p", single.text, "a one-character selection is still inclusive")

    local block = select(buf, {
      mode = "\22",
      start = { row = 1, col = 2 },
      ["end"] = { row = 2, col = 3 },
      exclusive = true,
    })
    test.equal("l\ne", block.text, "blockwise exclusive drops the rightmost character per row")

    local previous = vim.o.selection
    vim.o.selection = "exclusive"
    local from_option = select(buf, {
      mode = "v",
      start = { row = 1, col = 2 },
      ["end"] = { row = 1, col = 5 },
    })
    vim.o.selection = previous
    test.equal("lph", from_option.text, "'selection' is used when exclusive is omitted")
  end))

  test.it("converts byte and character columns for multibyte text", case(function()
    local buf = scratch({ "aé中b", "xyzw" })

    local charwise = select(buf, {
      mode = "v",
      columns = "char",
      start = { row = 1, col = 2 },
      ["end"] = { row = 1, col = 4 },
    })
    test.equal("é中b", charwise.text)
    test.equal(2, charwise.start_col, "character 2 starts at byte 2")
    test.equal(7, charwise.end_col, "character 4 starts at byte 7")
    test.equal(2, charwise.start_char)
    test.equal(4, charwise.end_char)

    local bytes = select(buf, {
      mode = "v",
      start = { row = 1, col = 2 },
      ["end"] = { row = 1, col = 7 },
    })
    test.equal(charwise.text, bytes.text, "byte and character positions select the same text")

    local block = select(buf, {
      mode = "\22",
      columns = "char",
      start = { row = 1, col = 2 },
      ["end"] = { row = 2, col = 4 },
    })
    test.equal("é中b\nyzw", block.text)
  end))

  test.it("uses relative names, filetypes and safe fallbacks", case(function()
    local dir = tempdir("paths")
    vim.fn.mkdir(dir .. "/src", "p")
    local path = dir .. "/src/a b`c.lua"
    vim.fn.writefile({ "disk content" }, path)
    vim.cmd("silent! cd " .. vim.fn.fnameescape(dir))
    vim.cmd("silent! edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    buffers[#buffers + 1] = buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "memory one", "memory two" })
    vim.bo[buf].filetype = "lua"

    local ctx = select(buf, { mode = "V", start = { row = 1 }, ["end"] = { row = 2 } })
    test.equal("src/a b`c.lua", ctx.path)
    test.equal("lua", ctx.filetype)
    test.equal("memory one\nmemory two", ctx.text, "unsaved buffer text comes from memory")

    local formatted = assert(context.format(ctx))
    test.truthy(formatted:find("src/a b`c.lua:1-2", 1, true), "location keeps the relative path")
    test.truthy(formatted:find("memory one\nmemory two", 1, true), "formatted code keeps memory text")

    local unnamed = scratch({ "single" })
    local unnamed_ctx = select(unnamed, { mode = "v", start = { row = 1, col = 1 }, ["end"] = { row = 1, col = 6 } })
    test.equal("[No Name]", unnamed_ctx.path)
    test.equal(nil, unnamed_ctx.filetype)
    test.equal("`[No Name]:1`\n\n```\nsingle\n```", context.format(unnamed_ctx))
  end))

  test.it("chooses a fence longer than any run in the selected code", case(function()
    local buf = scratch({ "before", "````", "after" }, { filetype = "lua" })
    local ctx = select(buf, { mode = "V", start = { row = 1 }, ["end"] = { row = 3 } })
    local formatted = assert(context.format(ctx))
    test.truthy(formatted:find("\n`````lua\n", 1, true), "opening fence is five backticks")
    test.equal("`````", formatted:sub(-5), "closing fence is five backticks")
    test.truthy(formatted:find("```\nafter", 1, true), "selected fence text stays untouched")

    local inline = context.inline_code("a`b")
    test.equal("``a`b``", inline)
    local edge = context.inline_code("`a")
    test.equal("`` `a ``", edge)
  end))

  test.it("formats single-line and multi-line locations without trailing newlines", case(function()
    local buf = scratch({ "one", "two" }, { filetype = "lua" })
    local single = select(buf, { mode = "v", start = { row = 2, col = 1 }, ["end"] = { row = 2, col = 3 } })
    test.equal("`[No Name]:2`\n\n```lua\ntwo\n```", context.format(single))

    local multi = select(buf, {
      mode = "v",
      start = { row = 2, col = 3 },
      ["end"] = { row = 1, col = 1 },
    })
    local formatted = assert(context.format(multi))
    test.truthy(formatted:find("`[No Name]:1-2`", 1, true))
    test.truthy(formatted:find("one\ntwo", 1, true))
    test.equal("`", formatted:sub(-1), "no trailing newline")
  end))

  test.it("reads the current Visual selection and keeps a detached snapshot", case(function()
    local buf = scratch({ "alpha", "beta", "gamma" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    vim.cmd("normal! " .. string.char(22))
    vim.api.nvim_win_set_cursor(0, { 3, 2 })
    local selection = context.current_selection()
    test.truthy(selection, "current selection is available while Visual mode is active")
    test.equal(buf, selection.buffer)
    test.equal("\22", selection.mode)

    local ctx = select(buf, selection)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed", "changed", "changed" })
    test.equal(table.concat({ "lp", "et", "am" }, "\n"), ctx.text, "context text is a snapshot")
  end))
end)
