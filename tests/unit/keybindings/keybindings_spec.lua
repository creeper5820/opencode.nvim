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

test.describe("opencode.keybindings resolve", function()
  test.it("defaults to the V2 single Escape interrupt binding and leader", function()
    local resolved = keybindings.resolve({ cli_config = {}, read_cli = false })
    test.equal("<C-x>", resolved.leader)
    test.equal(2000, resolved.leader_timeout)
    test.truthy(resolved.sequence_timeout > 0)
    test.equal("<Esc>", resolved.bindings["session.interrupt"].keys[1])
    test.equal("n", resolved.bindings["session.interrupt"].modes[1])
    test.equal(true, resolved.bindings["session.interrupt"].supported)
    test.deep_equal({}, resolved.diagnostics)
  end)

  test.it("parses comma-separated alternatives", function()
    local resolved = resolve({ ["session.interrupt"] = "escape,ctrl+c" })
    test.deep_equal({ "<Esc>", "<C-c>" }, resolved.bindings["session.interrupt"].keys)
    test.deep_equal({}, resolved.diagnostics)
  end)

  test.it("parses arrays, binding objects and key objects", function()
    local resolved = resolve({
      ["session.interrupt"] = {
        "escape",
        { key = { name = "c", ctrl = true } },
        { key = "shift+f2" },
      },
    })
    test.deep_equal(
      { "<Esc>", "<C-c>", "<S-F2>" },
      resolved.bindings["session.interrupt"].keys
    )
    test.deep_equal({}, resolved.diagnostics)
  end)

  test.it("accepts false and none as disabled", function()
    local by_false = resolve({ ["session.interrupt"] = false })
    test.equal(true, by_false.bindings["session.interrupt"].disabled)
    test.deep_equal({}, by_false.bindings["session.interrupt"].keys)

    local by_none = resolve({ ["session.interrupt"] = "none" })
    test.equal(true, by_none.bindings["session.interrupt"].disabled)
    test.deep_equal({}, by_none.bindings["session.interrupt"].keys)
  end)

  test.it("expands <leader> from the effective leader", function()
    local resolved = resolve({
      leader = "space",
      ["model.list"] = "<leader>m",
    })
    test.equal("<Space>", resolved.leader)
    test.deep_equal({ "<Space>m" }, resolved.bindings["model.list"].keys)
    test.equal(false, resolved.bindings["model.list"].supported)
    test.truthy(has_code(resolved, "unsupported_command"))
  end)

  test.it("applies Neovim overrides over CLI values and leader", function()
    local cli = {
      leader = "ctrl+x",
      ["session.interrupt"] = "escape",
      ["model.list"] = "<leader>m",
    }
    local resolved = resolve(cli, {
      overrides = {
        ["session.interrupt"] = "<Esc><Esc>",
        leader = "space",
      },
    })
    test.equal("<Space>", resolved.leader)
    test.deep_equal({ "<Esc><Esc>" }, resolved.bindings["session.interrupt"].keys)
    test.equal("override", resolved.bindings["session.interrupt"].source)
    test.deep_equal({ "<Space>m" }, resolved.bindings["model.list"].keys)

    local disabled = resolve(cli, {
      overrides = { ["session.interrupt"] = false },
    })
    test.equal(true, disabled.bindings["session.interrupt"].disabled)
  end)

  test.it("recognizes every supported multi-key spelling as one sequence", function()
    for _, spelling in ipairs({ "escapeescape", "escape escape", "<Esc><Esc>" }) do
      local resolved = resolve({ ["session.interrupt"] = spelling })
      local binding = resolved.bindings["session.interrupt"]
      test.deep_equal({ "<Esc><Esc>" }, binding.keys, spelling)
      test.equal(2, binding.alternatives[1].count, spelling)
      test.equal(true, binding.alternatives[1].repeated, spelling)
      test.truthy(has_code(resolved, "sequence_timeout"), spelling)
    end
  end)

  test.it("degrades unsupported keys without dropping valid alternatives", function()
    local resolved = resolve({ ["session.interrupt"] = "hyper+x,escape" })
    test.deep_equal({ "<Esc>" }, resolved.bindings["session.interrupt"].keys)
    test.truthy(has_code(resolved, "unsupported_key"))
  end)

  test.it("reports unsupported commands but keeps their resolved keys", function()
    local resolved = resolve({ ["model.list"] = "ctrl+m" })
    test.deep_equal({ "<C-m>" }, resolved.bindings["model.list"].keys)
    test.equal(false, resolved.bindings["model.list"].supported)
    test.truthy(has_code(resolved, "unsupported_command"))
  end)

  test.it("does not expand <leader> when the leader is disabled", function()
    local resolved = resolve({
      leader = false,
      ["model.list"] = "<leader>m",
    })
    test.equal(nil, resolved.leader)
    test.deep_equal({}, resolved.bindings["model.list"].keys)
    test.truthy(has_code(resolved, "unsupported_key"))
  end)

  test.it("reads V2 leader.timeout and rejects invalid values non-blockingly", function()
    local resolved = keybindings.resolve({
      cli_config = { keybinds = {}, leader = { timeout = 1500 } },
      read_cli = false,
    })
    test.equal(1500, resolved.leader_timeout)
    test.equal(1500, resolved.timeout)

    local invalid = keybindings.resolve({
      cli_config = { keybinds = {}, leader = { timeout = 0 } },
      read_cli = false,
    })
    test.equal(2000, invalid.leader_timeout)
    test.truthy(has_code(invalid, "invalid_timeout"))
    test.equal("<Esc>", invalid.bindings["session.interrupt"].keys[1])
  end)

  test.it("accepts a timing-only leader override and falls back from invalid leaders", function()
    local timed = resolve({}, {
      overrides = { leader = { timeout = 350 }, timeout = 45 },
    })
    test.equal("<C-x>", timed.leader)
    test.equal(350, timed.leader_timeout)
    test.equal(45, timed.sequence_timeout)

    local invalid = resolve({}, {
      overrides = { leader = "hyper+x" },
    })
    test.equal("<C-x>", invalid.leader)
    test.equal("default", invalid.leader_source)
    test.truthy(has_code(invalid, "unsupported_key"))
    test.truthy(has_code(invalid, "leader_fallback"))
  end)

  test.it("supports Neovim-style key tokens in overrides", function()
    local resolved = resolve({}, {
      overrides = {
        ["session.interrupt"] = "<C-S-x>,<leader>z",
        leader = "<C-space>",
      },
    })
    test.deep_equal({ "<C-S-x>", "<C-Space>z" }, resolved.bindings["session.interrupt"].keys)
  end)

  test.it("reads an isolated cli.json file and ignores malformed files", function()
    local path = vim.fn.tempname() .. ".json"
    vim.fn.writefile({
      vim.json.encode({
        keybinds = {
          leader = "space",
          ["session.interrupt"] = "escapeescape",
        },
        leader = { timeout = 750 },
      }),
    }, path)
    local resolved = keybindings.resolve({ cli_path = path })
    test.equal(true, resolved.cli.loaded)
    test.equal(path, resolved.cli.path)
    test.equal("<Space>", resolved.leader)
    test.equal(750, resolved.leader_timeout)
    test.deep_equal({ "<Esc><Esc>" }, resolved.bindings["session.interrupt"].keys)

    vim.fn.writefile({ "{ not json" }, path)
    local broken = keybindings.resolve({ cli_path = path })
    test.equal(false, broken.cli.loaded)
    test.truthy(has_code(broken, "cli_config_invalid"))
    test.deep_equal({ "<Esc>" }, broken.bindings["session.interrupt"].keys)
    vim.fn.delete(path)
  end)

  test.it("returns health-style diagnostics without failing other mappings", function()
    local resolved = resolve({ ["session.interrupt"] = "hyper+x,escape" })
    local health = keybindings.health({
      cli_config = { keybinds = { ["session.interrupt"] = "hyper+x,escape" } },
      read_cli = false,
    })
    test.truthy(has_code(resolved, "unsupported_key"))
    test.equal("warn", health[1].level)
    test.matches("hyper", health[1].message)
    test.deep_equal({ "<Esc>" }, resolved.bindings["session.interrupt"].keys)
  end)
end)
