local test = require("tests.support.test")

local function capture_health(fn)
  local saved = {
    start = vim.health.start,
    ok = vim.health.ok,
    info = vim.health.info,
    warn = vim.health.warn,
    error = vim.health.error,
  }
  local messages = {}
  local function capture(level)
    return function(message)
      messages[#messages + 1] = level .. ":" .. message
    end
  end
  vim.health.start = function(name)
    messages[#messages + 1] = "start:" .. name
  end
  vim.health.ok = capture("ok")
  vim.health.info = capture("info")
  vim.health.warn = capture("warn")
  vim.health.error = capture("error")

  local ok, err = pcall(fn)
  vim.health.start = saved.start
  vim.health.ok = saved.ok
  vim.health.info = saved.info
  vim.health.warn = saved.warn
  vim.health.error = saved.error
  return ok, err, messages
end

local function with_loaded(name, value, fn)
  local original = package.loaded[name]
  package.loaded[name] = value
  local ok, err = pcall(fn)
  package.loaded[name] = original
  if not ok then
    error(err, 0)
  end
end

test.describe("health", function()
  test.it("reports Neovim, vim.uv and the default configuration", function()
    test.reload()
    local health = require("opencode.health")
    local results = health.collect()

    local found_version = false
    local found_uv = false
    local found_config = false
    local found_url = false
    local mentions_curl = false
    for _, item in ipairs(results) do
      if item.level == "ok" and item.message:match("^Neovim %d") then
        found_version = true
      end
      if item.level == "ok" and item.message:match("vim%.uv") then
        found_uv = true
      end
      if item.level == "ok" and item.message:match("configuration is valid") then
        found_config = true
      end
      if item.level == "info" and item.message:match("http://127%.0%.0%.1:4096") then
        found_url = true
      end
      if item.message:lower():match("curl") then
        mentions_curl = true
      end
    end

    test.truthy(found_version, "expected a Neovim version result")
    test.truthy(found_uv, "expected a vim.uv result")
    test.truthy(found_config, "expected a configuration result")
    test.truthy(found_url, "expected the resolved server URL")
    test.falsy(mentions_curl, "health must not depend on curl")
  end)

  test.it("reports an error when configuration cannot be loaded", function()
    local health = require("opencode.health")
    local original = package.loaded["opencode"]
    package.loaded["opencode"] = {
      get_config = function()
        error("broken config")
      end,
    }
    local ok, results = pcall(health.collect)
    package.loaded["opencode"] = original
    test.truthy(ok, "collect must not raise")
    local found = false
    for _, item in ipairs(results) do
      if item.level == "error" and item.message:match("configuration is invalid") then
        found = true
      end
    end
    test.truthy(found, "expected a configuration error")
  end)

  test.it("reports an old Neovim and missing vim.uv as errors", function()
    local health = require("opencode.health")
    local saved_version = vim.version
    local saved_uv = vim.uv
    local ok, err = pcall(function()
      vim.version = function()
        return { major = 0, minor = 9, patch = 0 }
      end
      vim.uv = nil
      local results = health.collect()
      local found_old = false
      local found_uv = false
      for _, item in ipairs(results) do
        if item.level == "error" and item.message:match("too old") then
          found_old = true
        end
        if item.level == "error" and item.message:match("vim%.uv is unavailable") then
          found_uv = true
        end
      end
      test.truthy(found_old, "expected an old Neovim error")
      test.truthy(found_uv, "expected a missing vim.uv error")
    end)
    vim.version = saved_version
    vim.uv = saved_uv
    if not ok then
      error(err, 0)
    end
  end)

  test.it("reports an explicit error for an https configuration", function()
    local health = require("opencode.health")
    local original = package.loaded["opencode"]
    package.loaded["opencode"] = {
      get_config = function()
        return { server = { url = "https://127.0.0.1:4096" } }
      end,
    }
    local ok, results = pcall(health.collect)
    package.loaded["opencode"] = original
    test.truthy(ok, "collect must not raise")
    local found = false
    for _, item in ipairs(results) do
      if item.level == "error" and item.message:match("HTTPS") then
        found = true
      end
    end
    test.truthy(found, "expected an HTTPS unsupported error")
  end)

  test.it("check() can run in headless Neovim", function()
    package.loaded["opencode.health"] = nil
    local health = require("opencode.health")
    local ok, err = pcall(health.check)
    test.truthy(ok, "health.check failed: " .. tostring(err))
  end)

  test.it("collects keybinding diagnostics directly", function()
    local health = require("opencode.health")
    local results = health.collect_keybindings({
      keybindings = { enabled = true, read_cli = false, overrides = {} },
    })
    test.equal(1, #results)
    test.equal("ok", results[1].level)
    test.matches("keybindings:.*resolved", results[1].message)
  end)

  test.it("surfaces keybinding warnings from keybindings.health", function()
    local health = require("opencode.health")
    local results = health.collect_keybindings({
      keybindings = {
        enabled = true,
        read_cli = false,
        overrides = { ["session.interrupt"] = "hyper+x" },
      },
    })
    test.equal("warn", results[1].level)
    test.matches("keybindings:.*hyper", results[1].message)
  end)

  test.it("reports disabled and missing optional keybindings as info", function()
    local health = require("opencode.health")
    local disabled = health.collect_keybindings({
      keybindings = { enabled = false },
    })
    test.equal("info", disabled[1].level)
    test.matches("disabled", disabled[1].message)

    with_loaded("opencode.keybindings", true, function()
      local missing = health.collect_keybindings({
        keybindings = { enabled = true },
      })
      test.equal("info", missing[1].level)
      test.matches("not installed", missing[1].message)
      for _, item in ipairs(missing) do
        test.truthy(item.level ~= "error", "optional module absence must not be an error")
      end
    end)
  end)

  test.it("check() includes keybinding diagnostics exactly once without opencode.health()", function()
    local health = require("opencode.health")
    local stub = {
      get_config = function()
        return {
          server = { url = "http://127.0.0.1:4096" },
          keybindings = {
            enabled = true,
            read_cli = false,
            overrides = { ["session.interrupt"] = "hyper+x" },
          },
        }
      end,
      health = function()
        error("opencode.health must not be called from health.collect")
      end,
    }
    with_loaded("opencode", stub, function()
      local ok, err, messages = capture_health(health.check)
      test.truthy(ok, "health.check failed: " .. tostring(err))
      local keybinding_lines = 0
      local found_warning = false
      for _, message in ipairs(messages) do
        if message:find("keybindings:", 1, true) then
          keybinding_lines = keybinding_lines + 1
        end
        if message:sub(1, 5) == "warn:" and message:find("hyper", 1, true) then
          found_warning = true
        end
      end
      test.equal(1, keybinding_lines, "keybinding diagnostics must be appended exactly once")
      test.truthy(found_warning, "expected the keybinding warning in checkhealth output")
    end)
  end)

  test.it("public health() keeps one set of keybinding diagnostics", function()
    test.reload()
    local opencode = require("opencode")
    local ok, err = pcall(function()
      opencode.setup({
        keybindings = {
          read_cli = false,
          overrides = { ["session.interrupt"] = "hyper+x" },
        },
        completion = { enabled = false },
        status = { enabled = false },
        tools = { enabled = false },
      })
      local results = opencode.health()
      local count = 0
      local found_warning = false
      for _, item in ipairs(results) do
        if item.message:find("keybindings:", 1, true) then
          count = count + 1
        end
        if item.level == "warn" and item.message:find("hyper", 1, true) then
          found_warning = true
        end
      end
      test.equal(1, count, "opencode.health must not duplicate keybinding diagnostics")
      test.truthy(found_warning, "expected the keybinding warning in public health")
    end)
    pcall(opencode.stop)
    if not ok then
      error(err, 0)
    end
  end)

  test.it("check() treats a missing optional keybindings module as info", function()
    local health = require("opencode.health")
    local stub = {
      get_config = function()
        return {
          server = { url = "http://127.0.0.1:4096" },
          keybindings = { enabled = true },
        }
      end,
    }
    with_loaded("opencode", stub, function()
      with_loaded("opencode.keybindings", true, function()
        local ok, err, messages = capture_health(health.check)
        test.truthy(ok, "health.check failed: " .. tostring(err))
        local found_info = false
        for _, message in ipairs(messages) do
          test.falsy(
            message:sub(1, 6) == "error:" and message:find("keybindings", 1, true),
            "missing optional keybindings must not be an error"
          )
          if message:sub(1, 5) == "info:" and message:find("not installed", 1, true) then
            found_info = true
          end
        end
        test.truthy(found_info, "expected an informational missing-keybindings line")
      end)
    end)
  end)
end)
