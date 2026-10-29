local test = require("tests.support.test")
local keybindings = require("opencode.keybindings")

local function resolve(cli_keybinds, extra)
  extra = extra or {}
  local opts = {
    cli_config = { keybinds = cli_keybinds },
    read_cli = false,
  }
  for name, value in pairs(extra) do
    opts[name] = value
  end
  return keybindings.resolve(opts)
end

local function codes(resolved)
  local result = {}
  for _, item in ipairs(resolved.diagnostics) do
    result[#result + 1] = item.code
  end
  return result
end

local function has_code(resolved, code)
  for _, item in ipairs(resolved.diagnostics) do
    if item.code == code then
      return true
    end
  end
  return false
end

test.describe("effective OpenCode keybindings", function()
  test.it("uses the OpenCode V2 native defaults and leader", function()
    local resolved = keybindings.resolve({ cli_config = {}, read_cli = false })
    test.equal("<C-x>", resolved.leader)
    test.equal(2000, resolved.leader_timeout)
    test.truthy(resolved.sequence_timeout > 0)
    test.equal("<Esc>", resolved.bindings["session_interrupt"].keys[1])
    test.equal("<Esc>", resolved.bindings["session.interrupt"].keys[1])
    test.equal("\24n", resolved.bindings["session_new"].alternatives[1].bytes)
  end)

  test.it("parses comma-separated alternatives and encodes each sequence", function()
    local resolved = resolve({ input_move_left = "left,ctrl+b" })
    local binding = resolved.bindings["input_move_left"]
    test.deep_equal({ "<Left>", "<C-b>" }, binding.keys)
    test.equal("\27[D", binding.alternatives[1].bytes)
    test.equal("\2", binding.alternatives[2].bytes)
  end)

  test.it("expands a custom multi-stroke leader into full sequences", function()
    local resolved = resolve({
      leader = "ctrl+x ctrl+x",
      session_new = "<leader>n",
      model_list = "<leader>m",
    })
    test.deep_equal({ "<C-x><C-x>n" }, resolved.bindings["session_new"].keys)
    test.deep_equal({ "<C-x><C-x>m" }, resolved.bindings["model_list"].keys)
    test.equal("\24\24n", resolved.bindings["session_new"].alternatives[1].bytes)
  end)

  test.it("supports arrays, binding objects and modifier combinations", function()
    local resolved = resolve({
      ["custom.action"] = {
        "escape",
        { key = { name = "p", ctrl = true, shift = true, alt = true } },
        { key = "shift+f2" },
      },
    })
    local binding = resolved.bindings["custom_action"]
    test.deep_equal({ "<Esc>", "<C-S-M-p>", "<S-F2>" }, binding.keys)
    test.equal("\27", binding.alternatives[1].bytes)
    test.equal("\27[112;8u", binding.alternatives[2].bytes)
    test.equal("\27[1;2Q", binding.alternatives[3].bytes)
  end)

  test.it("accepts false and none as disabled", function()
    local by_false = resolve({ session_interrupt = false })
    test.equal(true, by_false.bindings["session_interrupt"].disabled)
    test.deep_equal({}, by_false.bindings["session_interrupt"].keys)

    local by_none = resolve({ session_interrupt = "none" })
    test.equal(true, by_none.bindings["session_interrupt"].disabled)
  end)

  test.it("applies Neovim overrides over cli.json and the leader", function()
    local cli = {
      leader = "ctrl+x",
      session_interrupt = "escape",
      model_list = "<leader>m",
    }
    local resolved = resolve(cli, {
      overrides = {
        session_interrupt = "<Esc><Esc>",
        leader = "space",
      },
    })
    test.equal("<Space>", resolved.leader)
    test.deep_equal({ "<Esc><Esc>" }, resolved.bindings["session_interrupt"].keys)
    test.equal("override", resolved.bindings["session_interrupt"].source)
    test.deep_equal({ "<Space>m" }, resolved.bindings["model_list"].keys)
  end)

  test.it("recognizes repeated Escape spellings and reports the sequence", function()
    for _, spelling in ipairs({ "escapeescape", "escape escape", "<Esc><Esc>" }) do
      local resolved = resolve({ session_interrupt = spelling })
      local binding = resolved.bindings["session_interrupt"]
      test.deep_equal({ "<Esc><Esc>" }, binding.keys, spelling)
      test.equal(2, binding.alternatives[1].count, spelling)
      test.equal(true, binding.alternatives[1].repeated, spelling)
      test.truthy(has_code(resolved, "sequence_timeout"), spelling)
    end
  end)

  test.it("degrades unsupported keys without dropping valid alternatives", function()
    local resolved = resolve({ session_interrupt = "hyper+x,escape" })
    test.deep_equal({ "<Esc>" }, resolved.bindings["session_interrupt"].keys)
    test.truthy(has_code(resolved, "unsupported_key"))
  end)

  test.it("does not expand <leader> when the leader is disabled", function()
    local resolved = resolve({
      leader = false,
      model_list = "<leader>m",
    })
    test.equal(nil, resolved.leader)
    test.deep_equal({}, resolved.bindings["model_list"].keys)
    test.truthy(has_code(resolved, "unsupported_key"))
  end)

  test.it("reads an isolated cli.json file and ignores malformed files", function()
    local path = vim.fn.tempname() .. ".json"
    vim.fn.writefile({
      vim.json.encode({
        keybinds = {
          leader = "space",
          session_interrupt = "escapeescape",
        },
        leader_timeout = 750,
      }),
    }, path)
    local resolved = keybindings.resolve({ cli_path = path })
    test.equal(true, resolved.cli.loaded)
    test.equal(path, resolved.cli.path)
    test.equal("<Space>", resolved.leader)
    test.equal(750, resolved.leader_timeout)
    test.deep_equal({ "<Esc><Esc>" }, resolved.bindings["session_interrupt"].keys)

    vim.fn.writefile({ "{ not json" }, path)
    local broken = keybindings.resolve({ cli_path = path })
    test.equal(false, broken.cli.loaded)
    test.truthy(has_code(broken, "cli_config_invalid"))
    test.equal("<Esc>", broken.bindings["session_interrupt"].keys[1])
    vim.fn.delete(path)
  end)

  test.it("encodes navigation and submit keys as PTY bytes, not K_SPECIAL", function()
    local resolved = resolve({
      ["custom.keys"] = "pageup,shift+return,ctrl+delete",
    })
    local binding = resolved.bindings["custom_keys"]
    test.equal("\27[5~", binding.alternatives[1].bytes)
    test.equal("\27[13;2u", binding.alternatives[2].bytes)
    test.equal("\27[3;5~", binding.alternatives[3].bytes)
  end)

  test.it("returns health diagnostics without failing other mappings", function()
    local health = keybindings.health({
      cli_config = { keybinds = { session_interrupt = "hyper+x,escape" } },
      read_cli = false,
    })
    local warning
    for _, item in ipairs(health) do
      if item.level == "warn" and item.message:find("hyper", 1, true) then
        warning = item
        break
      end
    end
    test.truthy(warning, "expected a hyper key warning")
    test.matches("hyper", warning.message)
  end)

  test.it("keeps dotted and underscore command aliases in sync", function()
    local resolved = resolve({ ["session.new"] = "<leader>N" })
    test.equal(resolved.bindings["session_new"], resolved.bindings["session.new"])
    test.deep_equal({ "<C-x>N" }, resolved.bindings["session_new"].keys)
  end)
end)
