local test = require("tests.support.test")
local harness = require("tests.support.harness")

local function process_alive(pid)
  local ok, result = pcall(vim.uv.kill, pid, 0)
  return ok and (result == 0 or result == true)
end

test.describe("test harness", function()
  test.it("creates isolated XDG, shada, project and service paths", function()
    local h = harness.new()
    local ok, err = pcall(function()
      test.truthy(h.paths.root:match("^/tmp/opencode/"), "root must live under /tmp/opencode")
      for _, key in ipairs({ "home", "config", "data", "state", "cache", "runtime", "project", "tmp", "service", "registry" }) do
        test.truthy(h.paths[key]:match("^/tmp/opencode/"), key .. " must live under /tmp/opencode")
      end
      test.equal(1, vim.fn.isdirectory(h.paths.project))
      test.equal(1, vim.fn.isdirectory(h.paths.tmp))
      test.equal("rwx------", vim.fn.getfperm(h.paths.runtime), "XDG_RUNTIME_DIR must be 0700")
      test.equal(h.paths.runtime, h.env.XDG_RUNTIME_DIR)
      test.equal(h.paths.root .. "/harness", h.env.OPENCODE_NVIM_TEST_BASE)
      test.truthy(h.paths.shada:match("^/tmp/opencode/"), "shada must live under /tmp/opencode")
      test.truthy(h.paths.config ~= vim.fn.stdpath("config"), "must not reuse user config")
      test.truthy(h.paths.data ~= vim.fn.stdpath("data"), "must not reuse user data")
    end)
    h:cleanup()
    if not ok then
      error(err, 0)
    end
    test.equal(0, vim.fn.isdirectory(h.paths.root), "cleanup must remove the harness root")
  end)

  test.it("spawns headless Neovim with an isolated environment", function()
    local h = harness.new()
    local ok, err = pcall(function()
      local result = h:spawn([[
local out = {
  vim.env.HOME,
  vim.env.XDG_CONFIG_HOME,
  vim.env.XDG_DATA_HOME,
  vim.env.XDG_STATE_HOME,
  vim.env.XDG_CACHE_HOME,
  vim.env.XDG_RUNTIME_DIR,
  vim.fn.stdpath("config"),
  vim.fn.stdpath("data"),
  vim.fn.getcwd(),
  vim.o.shadafile,
  tostring(vim.opt.loadplugins:get()),
  vim.fn.filereadable(vim.fn.stdpath("config") .. "/init.lua") == 1 and "readable" or "absent",
}
io.stdout:write(table.concat(out, "\n"))
]])
      test.equal(0, result.code, "spawn failed: " .. result.stderr)
      local lines = vim.split(result.stdout, "\n", { plain = true })
      test.equal(h.paths.home, lines[1])
      test.equal(h.paths.config, lines[2])
      test.equal(h.paths.data, lines[3])
      test.equal(h.paths.state, lines[4])
      test.equal(h.paths.cache, lines[5])
      test.equal(h.paths.runtime, lines[6])
      test.equal(h.paths.config .. "/opencode-test", lines[7])
      test.equal(h.paths.data .. "/opencode-test", lines[8])
      test.equal(h.paths.project, lines[9])
      test.equal(h.paths.shada, lines[10], "child must use the harness shada file")
      test.equal("false", lines[11], "minimal init must not auto-load plugins")
      test.equal("absent", lines[12], "child must not load a user init.lua")
    end)
    h:cleanup()
    if not ok then
      error(err, 0)
    end
  end)

  test.it("loads plugin/opencode.lua repeatedly without duplicate state", function()
    local h = harness.new()
    local ok, err = pcall(function()
      local result = h:spawn([[
vim.cmd("runtime! plugin/opencode.lua")
vim.cmd("runtime! plugin/opencode.lua")
local opencode = require("opencode")
local cfg = opencode.setup({ sidebar = { width = 55 } })
io.stdout:write(tostring(vim.g.loaded_opencode_nvim) .. "\n")
io.stdout:write(tostring(#vim.api.nvim_get_commands({ builtin = false })) .. "\n")
local has_group = pcall(vim.api.nvim_get_autocmds, { group = "OpencodeNvim" })
io.stdout:write(tostring(has_group) .. "\n")
io.stdout:write(tostring(vim.fn.maparg("<leader>oo", "n") == "" and vim.fn.maparg("<leader>os", "x") == "" and vim.fn.maparg("<C-s>", "n") == "") .. "\n")
io.stdout:write(tostring(cfg.sidebar.width))
]])
      test.equal(0, result.code, "child failed: " .. result.stderr)
      local lines = vim.split(result.stdout, "\n", { plain = true })
      test.equal("1", lines[1], "load guard must be set")
      test.equal("0", lines[2], "no commands should be registered in this phase")
      test.equal("false", lines[3], "no plugin autocmds should be registered")
      test.equal("true", lines[4], "no business keymaps should be registered")
      test.equal("55", lines[5])
    end)
    h:cleanup()
    if not ok then
      error(err, 0)
    end
  end)

  test.it("cleanup only removes its own root", function()
    local h = harness.new()
    local sentinel = h.paths.root .. "-sentinel"
    vim.fn.mkdir(sentinel, "p")
    vim.fn.writefile({ "keep" }, sentinel .. "/keep")
    h:cleanup()
    test.equal(0, vim.fn.isdirectory(h.paths.root), "own root must be removed")
    test.equal(1, vim.fn.isdirectory(sentinel), "unrelated directories must survive")
    vim.fn.delete(sentinel, "rf")
  end)

  test.it("real service tests skip instead of using a default instance", function()
    local saved_url = vim.env.OPENCODE_TEST_SERVER_URL
    vim.env.OPENCODE_TEST_SERVER_URL = nil
    local service, reason = harness.real_service()
    vim.env.OPENCODE_TEST_SERVER_URL = saved_url
    test.equal(nil, service, "must not return a fallback service")
    test.matches("skip", reason)
  end)

  test.it("real service smoke skips unless explicitly configured", function()
    local service, reason = harness.real_service()
    if test.skip_if(service == nil, "real service smoke", reason) then
      return
    end
    test.truthy(service.url, "configured real service must have a URL")
    test.equal(nil, reason)
  end)

  test.it("refuses the default endpoint even when it is explicitly set", function()
    local saved_url = vim.env.OPENCODE_TEST_SERVER_URL
    vim.env.OPENCODE_TEST_SERVER_URL = "http://127.0.0.1:4096"
    local service, reason = harness.real_service()
    vim.env.OPENCODE_TEST_SERVER_URL = saved_url
    test.equal(nil, service, "must not connect to the default instance")
    test.matches("default OpenCode endpoint", reason)
  end)

  test.it("accepts an explicitly configured non-default service without connecting", function()
    local saved_url = vim.env.OPENCODE_TEST_SERVER_URL
    vim.env.OPENCODE_TEST_SERVER_URL = "http://127.0.0.1:43210"
    local service, reason = harness.real_service()
    vim.env.OPENCODE_TEST_SERVER_URL = saved_url
    test.equal(nil, reason)
    test.truthy(service, "explicit non-default service must be returned")
    test.equal("http://127.0.0.1:43210", service.url)
  end)

  test.it("refuses a real service whose data home is outside the isolated tree", function()
    local saved_url = vim.env.OPENCODE_TEST_SERVER_URL
    local saved_data = vim.env.OPENCODE_TEST_DATA_HOME
    vim.env.OPENCODE_TEST_SERVER_URL = "http://127.0.0.1:43210"
    vim.env.OPENCODE_TEST_DATA_HOME = "/tmp/not-isolated-data"
    local service, reason = harness.real_service()
    vim.env.OPENCODE_TEST_SERVER_URL = saved_url
    vim.env.OPENCODE_TEST_DATA_HOME = saved_data
    test.equal(nil, service)
    test.matches("OPENCODE_TEST_DATA_HOME", reason)
  end)

  test.it("can reserve a loopback port and provide an explicit environment", function()
    local h = harness.new()
    local ok, err = pcall(function()
      local port = h:free_port()
      test.truthy(type(port) == "number" and port > 0 and port <= 65535)
      local env = h:build_env({ OPENCODE_TEST_SERVER_URL = "http://127.0.0.1:" .. port })
      test.equal("http://127.0.0.1:" .. port, env.OPENCODE_TEST_SERVER_URL)
      test.equal(h.paths.config, env.XDG_CONFIG_HOME)
    end)
    h:cleanup()
    if not ok then
      error(err, 0)
    end
  end)

  test.it("refuses to point child environment paths outside /tmp/opencode", function()
    local h = harness.new()
    local ok, err = pcall(function()
      h:build_env({ XDG_CONFIG_HOME = "/tmp/not-isolated" })
    end)
    h:cleanup()
    test.falsy(ok, "outside paths must be rejected")
    test.matches("outside /tmp/opencode", tostring(err))
  end)

  test.it("stops only background processes registered by the harness", function()
    local h = harness.new()
    local proc = h:start_process({ "/bin/sh", "-c", "exec sleep 30" })
    local pid = proc.pid
    test.truthy(pid > 0, "background process must have a PID")
    test.truthy(h.jobs[proc.job], "background job must be registered")
    test.truthy(h.pids[pid], "background PID must be registered")
    h:cleanup()
    test.equal(0, vim.fn.isdirectory(h.paths.root), "harness root must be removed")
    test.falsy(h.pids[pid], "PID must be unregistered")
    local gone = vim.wait(2000, function()
      return not process_alive(pid)
    end, 20)
    test.truthy(gone, "registered background process must be stopped")
  end)

  test.it("waits for a background process and reports its exit code", function()
    local h = harness.new()
    local ok, err = pcall(function()
      local proc = h:start_process({ "/bin/sh", "-c", "exit 7" })
      local code = h:wait_process(proc, 5000)
      test.equal(7, code)
      test.truthy(proc.done, "completed process must be marked done")
      test.equal(7, proc.code)
    end)
    h:cleanup()
    if not ok then
      error(err, 0)
    end
  end)

  test.it("can stop a background process explicitly", function()
    local h = harness.new()
    local ok, err = pcall(function()
      local proc = h:start_process({ "/bin/sh", "-c", "exec sleep 30" })
      test.truthy(h:stop_process(proc), "stop_process must report success")
      test.truthy(proc.done, "stopped process must be marked done")
    end)
    h:cleanup()
    if not ok then
      error(err, 0)
    end
  end)

  test.it("does not stop processes it did not create", function()
    local h = harness.new()
    local job = vim.fn.jobstart({ "/bin/sh", "-c", "exec sleep 2" })
    test.truthy(job > 0, "sentinel process must start")
    local pid = vim.fn.jobpid(job)
    local ok, err = pcall(function()
      h:cleanup()
      vim.uv.sleep(50)
      test.truthy(process_alive(pid), "unregistered process must survive harness cleanup")
    end)
    pcall(vim.fn.jobstop, job)
    pcall(vim.fn.jobwait, { job }, 1000)
    if not ok then
      error(err, 0)
    end
  end)

  test.it("stops a timed-out child and removes its own root", function()
    local h = harness.new()
    local ok, err = pcall(function()
      local result = h:spawn([[vim.uv.sleep(5000)]], { timeout = 100 })
      test.equal(-1, result.code, "expected the child to time out")
      test.truthy(result.pid > 0)
    end)
    h:cleanup()
    if not ok then
      error(err, 0)
    end
    test.equal(0, vim.fn.isdirectory(h.paths.root), "timed-out harness must be cleaned up")
  end)
end)
