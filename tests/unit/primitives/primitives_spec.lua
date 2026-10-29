local test = require("tests.support.test")
local channel = require("opencode.channel")
local focus_module = require("opencode.focus")
local keybindings = require("opencode.keybindings")
local primitives = require("opencode.primitives")

local function context(fake, focus)
  return {
    channel = fake,
    focus = focus,
    keybindings = keybindings.resolve({ cli_config = {}, read_cli = false }),
  }
end

test.describe("composer primitives", function()
  test.it("uses native TUI input commands per logical region", function()
    local fake = channel.new()
    local focus = focus_module.new()
    local ctx = context(fake, focus)

    test.truthy(primitives.apply("line_down", 1, ctx))
    test.equal("\27[B", fake.sent[#fake.sent])

    focus:set("session", "test")
    test.truthy(primitives.apply("line_down", 1, ctx))
    test.equal("\27[101;7u", fake.sent[#fake.sent])
    test.equal("session", focus:get())
  end)

  test.it("forwards counts by repeating the native input", function()
    local fake = channel.new()
    local focus = focus_module.new()
    test.truthy(primitives.apply("word_forward", 4, context(fake, focus)))
    test.equal(4, #fake.sent)
    test.equal("composer", focus:get())
  end)

  test.it("implements common delete and change operator motions", function()
    local fake = channel.new()
    local focus = focus_module.new()
    local ctx = context(fake, focus)

    test.truthy(primitives.operator("delete", "d", 1, ctx))
    test.equal("\27[100;6u", fake.sent[#fake.sent])

    fake:clear()
    test.truthy(primitives.operator("delete", "w", 1, ctx))
    test.equal("\27d", fake.sent[#fake.sent])

    fake:clear()
    test.truthy(primitives.operator("delete", "$", 1, ctx))
    test.equal("\11", fake.sent[#fake.sent])
    test.equal("composer", focus:get())
  end)

  test.it("reports unknown primitives and refuses composer edits in session", function()
    local fake = channel.new()
    local focus = focus_module.new()
    local ctx = context(fake, focus)
    local ok, err = primitives.apply("does_not_exist", 1, ctx)
    test.equal(false, ok)
    test.matches("unknown primitive", err)

    focus:set("session", "test")
    local delete_ok, delete_err = primitives.apply("delete_char", 1, ctx)
    test.equal(false, delete_ok)
    test.matches("not available in the session region", delete_err)
  end)

  test.it("never changes focus while applying a primitive", function()
    local fake = channel.new()
    local focus = focus_module.new()
    local ctx = context(fake, focus)
    for _, name in ipairs({ "line_up", "line_down", "page_up", "page_down", "first", "last" }) do
      test.truthy(primitives.apply(name, 1, ctx), name)
      test.equal("composer", focus:get(), name)
    end
  end)

  test.it("lists public primitive names and definitions", function()
    test.truthy(#primitives.names("composer") > 10)
    test.truthy(#primitives.names("session") > 3)
    local definition = primitives.get("submit")
    test.equal("Submit the composer", definition.description)
  end)
end)
