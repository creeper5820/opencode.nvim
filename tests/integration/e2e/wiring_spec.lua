-- Isolated end-to-end wiring test. The child Neovim starts its own fake
-- OpenCode V2 HTTP service on an ephemeral loopback port and uses the real
-- client/session/sync/state/UI/render/completion/status/keybinding stack.

local test = require("tests.support.test")
local util = require("tests.integration.e2e.util")

test.describe("e2e wiring", function()
  test.it("assembles the full client -> UI -> submit -> selection pipeline", function()
    local result = util.run_child("wiring_child.lua", {}, 60000)
    test.equal(0, result.code, "child failed\nstdout:\n" .. result.stdout .. "\nstderr:\n" .. result.stderr)
    test.matches("ok wiring", result.stdout)
  end)
end)
