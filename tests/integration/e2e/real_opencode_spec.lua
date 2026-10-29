-- Real OpenCode V2 smoke test. A test-owned server is always isolated with
-- temporary HOME/XDG directories, a random loopback port, a test password and
-- an explicit temporary project. It never connects to the default 4096 service
-- or the user's OpenCode data.

local test = require("tests.support.test")
local util = require("tests.integration.e2e.util")

local function probe(url, timeout)
  local http = require("opencode.net.http")
  local deadline = vim.uv.now() + timeout
  while vim.uv.now() < deadline do
    local done = false
    local healthy = false
    local cancel = http.request({ method = "GET", url = url .. "/health" }, function(err, response)
      healthy = err == nil and type(response) == "table" and response.status == 200
      done = true
    end)
    if cancel then
      vim.wait(1000, function()
        return done
      end, 20)
    end
    if healthy then
      return true
    end
    vim.wait(100, function()
      return false
    end, 10)
  end
  return false
end

test.describe("e2e real OpenCode", function()
  local bin = vim.env.OPENCODE_TEST_BIN
  if bin == nil or bin == "" then
    bin = vim.fn.exepath("opencode")
  end
  if test.skip_if(bin == "", "runs against an isolated real OpenCode V2 service", "opencode binary not found") then
    return
  end

  test.it("runs session, sync, prompt, idle interrupt and keybinding wiring", function()
    local harness = require("tests.support.harness").new()
    local service
    local ok, err = pcall(function()
      local port = harness:free_port()
      local password = "e2e-" .. tostring(vim.uv.hrtime()) .. "-secret"
      local url = "http://127.0.0.1:" .. tostring(port)
      service = harness:start_process({
        bin,
        "serve",
        "--hostname",
        "127.0.0.1",
        "--port",
        tostring(port),
      }, {
        cwd = harness.paths.project,
        env = {
          OPENCODE_SERVER_PASSWORD = password,
          OPENCODE_NVIM_REGISTRY_DIR = harness.paths.registry,
        },
      })
      test.truthy(probe(url, 20000), "isolated opencode serve did not become healthy")
      local result = util.run_child("real_child.lua", {
        OPENCODE_TEST_SERVICE_URL = url,
        OPENCODE_TEST_AUTH_HEADER = "Basic " .. util.base64("opencode:" .. password),
        OPENCODE_NVIM_REGISTRY_DIR = harness.paths.registry,
      }, 90000)
      test.equal(0, result.code, "child failed\nstdout:\n" .. result.stdout .. "\nstderr:\n" .. result.stderr)
      test.matches("ok real", result.stdout)
      test.matches('"idle":true', result.stdout)
      test.matches('"user_message":true', result.stdout)
      test.matches('"events_applied":true', result.stdout)
      test.falsy(result.stderr:find(password, 1, true), "service password leaked to child stderr")
      test.falsy(result.stdout:find(password, 1, true), "service password leaked to child stdout")
    end)
    if service and not service.done then
      harness:stop_process(service)
    end
    local log = service and (table.concat(service.stdout, "\n") .. table.concat(service.stderr, "\n")) or ""
    harness:cleanup()
    if not ok then
      error(tostring(err) .. "\nopencode log:\n" .. log, 0)
    end
  end)
end)
