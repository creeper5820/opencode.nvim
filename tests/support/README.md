# Test support

All Neovim tests run in disposable, isolated instances. The shared runner and
harness are intentionally dependency-free: only Neovim 0.10+ (for `vim.uv`) and
plain Lua are required.

## Running tests

```sh
bash tests/run.sh                                  # tests/unit/**/*_spec.lua
bash tests/run.sh tests/unit/config                # a directory
bash tests/run.sh tests/unit/config/config_spec.lua
```

`tests/run.sh` creates a fresh `/tmp/opencode/nvim-run-*` directory and starts
one headless Neovim with `env -i`:

- `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
  `XDG_CACHE_HOME`, `XDG_RUNTIME_DIR` and `TMPDIR` point inside that directory.
- The shada file is explicit and disposable.
- `tests/minimal_init.lua` sets a minimal `runtimepath`, disables automatic
  plugin loading, swap files, backups and undo files.
- `OPENCODE_TEST_*` variables are the only variables forwarded from the caller.
- `OPENCODE_NVIM_TEST_BASE` points the harness at the runner's own disposable
  directory, so interrupting the runner can remove all harness roots too.
- On `INT`/`TERM`, the runner snapshots and terminates only its test Neovim
  process tree, then removes its disposable root.

`tests/run.lua` refuses to run if its Neovim environment is not isolated under
`/tmp/opencode`. Do not bypass that check; use `tests/run.sh` or the harness.

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
cases that need a fresh module state.

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
      local config = require("opencode").setup({ sidebar = { width = 55 } })
      io.stdout:write(tostring(config.sidebar.width))
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

- `harness.new()` returns an object and creates:
  - `h.paths.root`, `home`, `config`, `data`, `state`, `cache`, `runtime`
  - `h.paths.project`, `tmp`, `shada`
  - `h.paths.service`, `registry` for test-owned OpenCode services/registries
- `h.env` is the isolated child environment. `h:build_env(extra)` merges extra
  variables and refuses to move `HOME`, `TMPDIR` or `XDG_*` outside the
  harness's isolated base (which always lives under `/tmp/opencode`).
- `h:command_prefix(extra_env)` returns the `env -i` prefix for a process.
- `h:spawn(script, opts)` runs a Lua script with
  `nvim --headless --noplugin -u tests/minimal_init.lua -i <isolated shada>
  -l <script>` and waits for it. `opts`: `timeout` (default 30000 ms), `env`,
  `cwd`. Returns `{ code, stdout, stderr, pid }`; `code == -1` means timeout.
- `h:start_process(cmd, opts)` starts a background process (for example a
  test-owned OpenCode service) and registers its job and PID. `opts`: `env`,
  `cwd`. Returns `{ job, pid, stdout, stderr, code, done }`. Use
  `h:wait_process(handle, timeout)` and `h:stop_process(handle)` when needed.
- `h:free_port()` reserves a currently free loopback port. Use it immediately
  in the test-owned service.
- `h:add_cleanup(fn)` registers an extra cleanup action.
- `h:cleanup()` is idempotent. It stops only jobs/PIDs registered by this
  harness, runs registered cleanups, then removes only `h.paths.root`.

Always call `h:cleanup()` even when an assertion fails (wrap the body in
`pcall` as above). A `VimLeavePre` handler also cleans active harnesses when a
test run exits, but explicit cleanup keeps tests independent.

The harness never talks to a running user Neovim or OpenCode instance and never
uses `pkill`/`pgrep`. Do not add process cleanup by name or port.

## Real OpenCode service tests

Real-service tests must be opt-in and must never fall back to a user's default
service:

```lua
local service, reason = harness.real_service()
if test.skip_if(service == nil, "real OpenCode smoke", reason) then
  return
end
-- service.url is an explicitly configured, non-default test endpoint.
```

Configuration contract:

- `OPENCODE_TEST_SERVER_URL` is required. Without it `real_service()` returns
  `nil, reason` and the test must skip.
- The default endpoint (`127.0.0.1`/`localhost`/`[::1]` on port 4096) is
  refused even if explicitly set. Start the test service on a distinct port.
- `OPENCODE_TEST_DATA_HOME` is returned when set and should point inside
  `/tmp/opencode` for service data isolation.
- The URL is validated by `opencode.config`; HTTPS is not supported yet.

Start test-owned services with `h:start_process()` and `h:build_env()`, using
`h.paths.service` / `h.paths.registry` and a port from `h:free_port()`. Pass
only test-specific configuration to the service; never point it at the user's
`opencode.json(c)`, registry, data directory or default port.
