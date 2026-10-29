local test = require("tests.support.test")
local focus_module = require("opencode.focus")

test.describe("logical focus", function()
  test.it("starts in the configured region and records state", function()
    local focus = focus_module.new({ initial = "composer" })
    test.equal("composer", focus:get())
    test.equal(true, focus:is_composer())
    test.deep_equal({
      region = "composer",
      saved = "composer",
      active = true,
      reason = "initial",
      changes = 0,
    }, focus:state())
  end)

  test.it("changes only through explicit set/toggle", function()
    local focus = focus_module.new()
    test.equal("session", focus:toggle())
    test.equal("session", focus:get())
    test.equal("composer", focus:toggle())
    test.equal(true, focus:set("session", "test"))
    test.equal("session", focus:get())
    test.equal("test", focus:state().reason)
  end)

  test.it("restores the previous region after the real window is left", function()
    local focus = focus_module.new()
    focus:set("session", "explicit")
    test.equal("session", focus:leave())
    test.equal(false, focus:state().active)
    test.equal("composer", focus:set("composer", "while-away") and focus:get())
    test.equal("composer", focus:enter())
    test.equal("composer", focus:get())
    test.equal(true, focus:state().active)
  end)

  test.it("keeps the saved region unchanged by unrelated calls", function()
    local focus = focus_module.new()
    focus:set("session", "explicit")
    focus:leave()
    focus:enter()
    test.equal("session", focus:get())
    test.equal("session", focus:state().saved)
  end)

  test.it("rejects unknown regions without mutating state", function()
    local focus = focus_module.new()
    local ok, err = focus:set("popup")
    test.equal(false, ok)
    test.matches("invalid focus region", err)
    test.equal("composer", focus:get())
  end)
end)
