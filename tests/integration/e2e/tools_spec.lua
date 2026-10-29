-- Isolated tool-server e2e: a test-owned headless Neovim registers a real
-- local HTTP server; the parent test then performs authenticated open/notify/
-- diff calls exactly like the optional OpenCode companion would.

local test = require("tests.support.test")
local util = require("tests.integration.e2e.util")

local function wait_for_file(path, timeout)
  return vim.wait(timeout or 10000, function()
    return vim.fn.filereadable(path) == 1
  end, 25)
end

local function request(entry, action, input, request_id)
  local http = require("opencode.net.http")
  local response
  local request_err
  local done = false
  local cancel, start_err = http.request({
    method = "POST",
    url = entry.url .. "/tools/" .. action,
    headers = {
      ["Content-Type"] = "application/json",
      Authorization = "Bearer " .. entry.token,
    },
    body = vim.json.encode({
      version = 1,
      request_id = request_id,
      action = action,
      input = input,
    }),
  }, function(err, value)
    request_err = err
    response = value
    done = true
  end)
  test.truthy(cancel, "request did not start: " .. tostring(start_err))
  test.truthy(vim.wait(10000, function()
    return done
  end, 20), "tool request timed out")
  test.falsy(request_err, "tool request failed: " .. tostring(request_err and request_err.message))
  local decoded_ok, decoded = pcall(vim.json.decode, response.body)
  test.truthy(decoded_ok, "invalid tool response JSON: " .. tostring(response.body))
  return response.status, decoded
end

test.describe("e2e tool server", function()
  test.it("registers and serves open/notify/diff over authenticated HTTP", function()
    local harness = require("tests.support.harness").new()
    local child
    local ok, err = pcall(function()
      local project = harness.paths.project
      vim.fn.mkdir(project .. "/src", "p")
      local file = project .. "/src/sample.lua"
      vim.fn.writefile({ "local value = 1", "return value" }, file)
      local script_path = harness.paths.tmp .. "/tools_child.lua"
      vim.fn.writefile(
        vim.split(util.read("tools_child.lua"), "\n", { plain = true }),
        script_path
      )
      local ready = harness.paths.tmp .. "/tools-ready"
      local stop = harness.paths.tmp .. "/tools-stop"

      child = harness:start_process({
        vim.v.progpath,
        "--headless",
        "-n",
        "--noplugin",
        "-u",
        util.repo() .. "/tests/minimal_init.lua",
        "-i",
        harness.paths.shada,
        "-l",
        script_path,
      }, {
        cwd = project,
        env = {
          OPENCODE_NVIM_TEST_REPO = util.repo(),
          OPENCODE_NVIM_REGISTRY_DIR = harness.paths.registry,
          OPENCODE_NVIM_TEST_READY = ready,
          OPENCODE_NVIM_TEST_STOP = stop,
        },
      })
      test.truthy(wait_for_file(ready), "child did not become ready\n" .. table.concat(child.stderr, "\n"))

      local entry
      test.truthy(vim.wait(5000, function()
        local files = vim.fn.glob(harness.paths.registry .. "/*.json", false, true)
        if #files == 0 then
          return false
        end
        local decoded_ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(files[1]), "\n"))
        if decoded_ok then
          entry = decoded
          return true
        end
        return false
      end, 25), "registry entry did not appear")
      test.equal(1, entry.schema)
      test.equal(vim.fs.normalize(project), entry.project_root)
      test.truthy(type(entry.token) == "string" and #entry.token >= 32, "token missing")
      test.matches("^http://127%.0%.0%.1:%d+$", entry.url)

      local status, opened = request(entry, "open", {
        path = "src/sample.lua",
        line = 2,
        column = 2,
      }, "req-open")
      test.equal(200, status)
      test.equal(true, opened.ok)
      test.equal(true, opened.result.opened)
      test.equal("src/sample.lua", opened.result.path)
      test.equal(2, opened.result.line)

      status, opened = request(entry, "notify", {
        message = "tool e2e notification",
        level = "info",
      }, "req-notify")
      test.equal(200, status)
      test.equal(true, opened.ok)
      test.equal(true, opened.result.notified)
      test.equal("info", opened.result.level)

      status, opened = request(entry, "diff", {
        path = "src/sample.lua",
        proposed = "local value = 2\nreturn value\n",
      }, "req-diff")
      test.equal(200, status)
      test.equal(true, opened.ok)
      test.matches("Nothing was written to disk", opened.result.message)
      test.equal(table.concat({ "local value = 1", "return value" }, "\n"), table.concat(vim.fn.readfile(file), "\n"))

      vim.fn.writefile({ "stop" }, stop)
      test.truthy(harness:wait_process(child, 10000) ~= nil, "child did not exit")
      test.equal(0, child.code, "child failed\nstdout:\n" .. table.concat(child.stdout, "\n")
        .. "\nstderr:\n" .. table.concat(child.stderr, "\n"))
      local files = vim.fn.glob(harness.paths.registry .. "/*.json", false, true)
      test.equal(0, #files, "registry entry was not removed on exit")
      local output = table.concat(child.stdout, "\n") .. table.concat(child.stderr, "\n")
      test.falsy(output:find(entry.token, 1, true), "token leaked to child output")
    end)
    if child and not child.done then
      harness:stop_process(child)
    end
    harness:cleanup()
    if not ok then
      error(err, 0)
    end
  end)
end)
