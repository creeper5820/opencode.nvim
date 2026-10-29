# Test support

All Neovim tests run in disposable, isolated headless instances. The shared
runner and harness have no external dependencies beyond Neovim 0.10+.

## Running tests

```sh
bash tests/run.sh                                  # tests/unit/**/*_spec.lua
bash tests/run.sh tests/unit/terminal              # a directory
bash tests/run.sh tests/unit/config/config_spec.lua
```

`tests/run.sh` creates a fresh `/tmp/opencode/nvim-run-*` directory and starts
one headless Neovim with `env -i`:

- `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
  `XDG_CACHE_HOME`, `XDG_RUNTIME_DIR` and `TMPDIR` point inside that directory.
- The shada file is explicit and disposable.
- `tests/minimal_init.lua` sets a minimal `runtimepath` and disables automatic
  plugin loading, swap files, backups and undo files.
- `OPENCODE_TEST_*` variables are the only variables forwarded from the caller.
- On `INT`/`TERM`, the runner snapshots and terminates only its test Neovim
  process tree, then removes its disposable root.

`tests/run.lua` refuses to run if its Neovim environment is not isolated under
`/tmp/opencode`. Use `tests/run.sh` or the harness.

## Writing a spec

Use `tests/support/test.lua`; it has no external dependencies.

```lua
local test = require("tests.support.test")

test.describe("my module", function()
  test.it("does the thing", function()
    test.equal(42, require("my_module").answer())
  end)

  test.skip_if(condition, "optional test", "reason")
end)
```

Common assertions: `equal`, `deep_equal`, `truthy`, `falsy`, `matches`,
`error_matches`. `test.reload()` clears loaded `opencode.*` modules between
cases that need fresh module state.

Terminal-dependent unit tests use
`require("opencode.channel").new()` instead of a real OpenCode process. The
terminal smoke test starts the official CLI with `--standalone` in a harness
environment and stops only that test's process.

## Isolated Neovim harness

`tests/support/harness.lua` creates a disposable environment and starts
headless Neovim processes with that environment. Every process it starts is
registered and cleaned up by the harness.

```lua
local test = require("tests.support.test")
local harness = require("tests.support.harness")

test.it("loads in a child Neovim", function()
  local h = harness.new()
  local ok, err = pcall(function()
    local result = h:spawn([[
      vim.cmd("runtime! plugin/opencode.lua")
      local config = require("opencode").setup({ window = { size = 55 } })
      io.stdout:write(tostring(config.window.size))
    ]])
    test.equal(0, result.code, result.stderr)
    test.equal("55", vim.trim(result.stdout))
  end)
  h:cleanup()
  if not ok then
    error(err, 0)
  end
end)
```

### Harness API

- `harness.new()` creates `h.paths.root`, `home`, `config`, `data`, `state`,
  `cache`, `runtime`, `project`, `tmp`, `shada`, `service` and `registry`.
- `h.env` is the isolated child environment. `h:build_env(extra)` merges extra
  variables and refuses to move `HOME`, `TMPDIR` or `XDG_*` outside the
  harness's base under `/tmp/opencode`.
- `h:command_prefix(extra_env)` returns the `env -i` prefix for a process.
- `h:spawn(script, opts)` runs a Lua script in a child Neovim and waits for it.
  `opts`: `timeout` (default 30000 ms), `env`, `cwd`. Returns
  `{ code, stdout, stderr, pid }`; `code == -1` means timeout.
- `h:start_process(cmd, opts)` starts and registers a background process.
- `h:wait_process(handle, timeout)` and `h:stop_process(handle)` manage it.
- `h:free_port()` reserves a currently free loopback port.
- `h:add_cleanup(fn)` registers an extra cleanup action.
- `h:cleanup()` is idempotent and stops only processes registered by this
  harness, then removes only `h.paths.root`.

Always call `h:cleanup()` even when an assertion fails. A `VimLeavePre` handler
also cleans active harnesses when a test run exits.

The harness never talks to a running user Neovim or OpenCode instance and never
uses `pkill`/`pgrep`. Do not add process cleanup by name or port.
