local test = require("tests.support.test")
local channel = require("opencode.channel")
local focus_module = require("opencode.focus")
local keybindings = require("opencode.keybindings")
local router_module = require("opencode.router")

local function has_mapping(buf, lhs)
  local raw = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  local wanted = vim.fn.keytrans(raw)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == lhs or map.lhsraw == raw then
      return true
    end
    if type(map.lhsraw) == "string" and vim.fn.keytrans(map.lhsraw) == wanted then
      return true
    end
  end
  return false
end

local function entry_for(plan, lhs)
  for _, entry in ipairs(plan) do
    if entry.lhs == lhs then
      return entry
    end
  end
  return nil
end

test.describe("terminal input router", function()
  test.it("plans native bindings with a custom full leader sequence", function()
    local resolved = keybindings.resolve({
      cli_config = {
        keybinds = {
          leader = "space",
          session_new = "<leader>n",
          model_list = "<leader>m",
        },
      },
      read_cli = false,
    })
    local plan = router_module.plan(resolved, {
      keymaps = { focus_next = "<F12>" },
      input = { passthrough = true, primitives = true },
    })
    local new = entry_for(plan, "<Space>n")
    test.truthy(new)
    test.equal("feed", new.kind)
    test.equal(" n", new.bytes)
    test.equal("session_new", new.command)
    test.truthy(entry_for(plan, "<Space>m"))
    test.truthy(entry_for(plan, "<F12>"))
    -- A single Space is a prefix of the native leader, so it is not a raw
    -- passthrough mapping that could shadow the sequence.
    test.falsy(entry_for(plan, "<Space>"))
  end)

  test.it("prefers native cli bindings over composer primitives", function()
    local resolved = keybindings.resolve({
      cli_config = {
        keybinds = {
          input_move_left = "h",
          input_move_down = "j",
        },
      },
      read_cli = false,
    })
    local plan = router_module.plan(resolved, {
      keymaps = { focus_next = false },
      input = { primitives = true, passthrough = true },
    })
    test.equal("feed", entry_for(plan, "h").kind)
    test.equal("feed", entry_for(plan, "j").kind)
    test.equal("primitive", entry_for(plan, "x").kind)
    test.equal("operator", entry_for(plan, "d").kind)
  end)

  test.it("reserves Insert entry keys from Normal passthrough", function()
    local resolved = keybindings.resolve({ cli_config = {}, read_cli = false })
    local plan = router_module.plan(resolved, {
      keymaps = { focus_next = false },
      input = { primitives = true, passthrough = true },
    })
    for _, lhs in ipairs({ "i", "a", "I", "A", ":", "/" }) do
      local entry = entry_for(plan, lhs)
      test.truthy(entry == nil or entry.kind == "feed", "expected " .. lhs .. " to remain a Neovim mode key")
    end
    test.truthy(entry_for(plan, "z"))
    test.equal("passthrough", entry_for(plan, "z").kind)
  end)

  test.it("attaches only Normal-mode buffer-local mappings", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local resolved = keybindings.resolve({
      cli_config = { keybinds = { leader = "space", session_new = "<leader>n" } },
      read_cli = false,
    })
    local focus = focus_module.new()
    local fake = channel.new()
    local router = router_module.new({
      focus = focus,
      channel = fake,
      keybindings = resolved,
      config = { keymaps = { focus_next = "<F12>" }, input = { primitives = true, passthrough = true } },
    })
    local ok, err = router:attach(buf)
    test.truthy(ok, tostring(err))
    test.truthy(has_mapping(buf, "<Space>n"))
    test.truthy(has_mapping(buf, "x"))
    test.deep_equal({}, vim.api.nvim_buf_get_keymap(buf, "i"))

    test.truthy(router:press("<Space>n"))
    test.equal(" n", fake.sent[#fake.sent])

    test.truthy(router:press("x"))
    test.equal("\4", fake.sent[#fake.sent])
    test.equal("composer", focus:get())

    fake:clear()
    test.truthy(router:press("j", 3))
    test.equal("\27[B\27[B\27[B", table.concat(fake.sent, ""))

    fake:clear()
    test.truthy(router:press("z", 2))
    test.equal("zz", table.concat(fake.sent, ""))

    test.truthy(router:detach() == nil or true)
    test.deep_equal({}, vim.api.nvim_buf_get_keymap(buf, "n"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test.it("does not cross logical regions when primitives are pressed", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local resolved = keybindings.resolve({ cli_config = {}, read_cli = false })
    local focus = focus_module.new()
    local fake = channel.new()
    local router = router_module.new({
      focus = focus,
      channel = fake,
      keybindings = resolved,
      config = { keymaps = { focus_next = false }, input = { primitives = true, passthrough = true } },
    })
    test.truthy(router:attach(buf))
    test.truthy(router:press("j"))
    test.equal("composer", focus:get())
    focus:set("session", "test")
    test.truthy(router:press("j"))
    test.equal("session", focus:get())
    test.truthy(router:press("gg"))
    test.equal("session", focus:get())
    test.truthy(router:press("G"))
    test.equal("session", focus:get())

    fake:clear()
    test.truthy(router:press("x"))
    test.equal("x", table.concat(fake.sent, ""))
    test.equal("session", focus:get())

    fake:clear()
    test.truthy(router:press("d"))
    test.equal("d", table.concat(fake.sent, ""))
    test.equal("session", focus:get())
    router:detach()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test.it("focus mapping changes region only through the focus primitive", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local resolved = keybindings.resolve({ cli_config = {}, read_cli = false })
    local focus = focus_module.new()
    local fake = channel.new()
    local calls = {}
    local router = router_module.new({
      focus = focus,
      channel = fake,
      keybindings = resolved,
      config = { keymaps = { focus_next = "<F12>" }, input = { primitives = true, passthrough = true } },
      on_focus = function(region)
        calls[#calls + 1] = region
      end,
    })
    test.truthy(router:attach(buf))
    test.truthy(router:press("<F12>"))
    test.equal("session", focus:get())
    test.deep_equal({ "session" }, calls)
    test.truthy(router:press("<F12>"))
    test.equal("composer", focus:get())
    test.deep_equal({ "session", "composer" }, calls)
    router:detach()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test.it("installs user primitive mappings with counts", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local resolved = keybindings.resolve({ cli_config = {}, read_cli = false })
    local focus = focus_module.new()
    local fake = channel.new()
    local router = router_module.new({
      focus = focus,
      channel = fake,
      keybindings = resolved,
      config = { keymaps = { focus_next = false }, input = { primitives = false, passthrough = false } },
    })
    test.truthy(router:attach(buf))
    local ok, err = router:map_primitive("gl", "page_down")
    test.truthy(ok, tostring(err))
    test.truthy(router:press("gl", 2))
    test.equal("\27[6~\27[6~", table.concat(fake.sent, ""))
    test.truthy(router:unmap("gl"))
    test.falsy(router:press("gl"))
    router:detach()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
