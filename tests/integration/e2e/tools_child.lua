-- Background isolated Neovim used by tools_spec.lua. It starts the real local
-- tool server, waits for the parent to finish HTTP action calls, then exits and
-- unregisters its registry entry.

local repo = assert(vim.env.OPENCODE_NVIM_TEST_REPO, "OPENCODE_NVIM_TEST_REPO is required")
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local root = vim.fn.getcwd()
local ready = assert(vim.env.OPENCODE_NVIM_TEST_READY)
local stop = assert(vim.env.OPENCODE_NVIM_TEST_STOP)

local opencode = require("opencode")
opencode.setup({
  project = { root = root },
  keybindings = { enabled = false },
  status = { enabled = false },
  tools = { enabled = true },
})

local registry = require("opencode.tools.registry")
local ready_ok = vim.wait(10000, function()
  return #registry.list() > 0
end, 50)
if not ready_ok then
  io.stderr:write("tool server did not register\n")
  vim.cmd("cquit 1")
end
vim.fn.writefile({ "ready" }, ready)

-- Keep the event loop alive so the HTTP server can serve tool calls.
while vim.fn.filereadable(stop) == 0 do
  vim.wait(50, function()
    return false
  end, 5)
end

opencode.stop()
vim.cmd("qall!")
