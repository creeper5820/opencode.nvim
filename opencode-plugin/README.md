# opencode.nvim OpenCode tools plugin

Optional OpenCode V2 server plugin that exposes three tools to the agent:

| Tool | Input | Behavior |
| --- | --- | --- |
| `neovim_open` | `path`, optional `line`, `column` | Opens a file in the Neovim instance registered for the current project. |
| `neovim_notify` | `message`, optional `level` (`info`/`warn`/`error`) | Sends a notification to that Neovim instance. |
| `neovim_diff` | `path`, `proposed` | Shows proposed content in a native Neovim diff. It is never written to disk. |

This package is an optional companion to the Neovim plugin, not a dependency
of it. Installing or loading it does not require Neovim to be running, and the
Neovim plugin does not detect, install, or manage this npm package. Load the
plugin in OpenCode independently; tool calls return a readable `NO_INSTANCE`
error until a Neovim instance has registered its local tool server.

The plugin only talks to the local Neovim tool server implemented by 09A. It
does not implement Neovim actions and never executes arbitrary Lua, Ex, or shell.

## Load

Published package (one entry, either the plain string or the options object):

```jsonc
// opencode.jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["opencode-nvim-tools"]
}
```

```jsonc
// opencode.jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": [
    {
      "package": "opencode-nvim-tools",
      "options": { "healthTimeoutMs": 1500, "requestTimeoutMs": 10000 }
    }
  ]
}
```

Local directory (relative to the config file, or an absolute path):

```jsonc
{
  "plugins": ["./plugins/opencode-nvim"]
}
```

A local directory without `node_modules` can import `@opencode/plugin` through
OpenCode's host resolution. If the directory is loaded by an older OpenCode V2
build that expects conventional entry files, the package root `index.ts`
re-exports the same plugin. OpenCode also discovers package directories placed
directly under `.opencode/plugins/` or `~/.config/opencode/plugins/`.

A test-only example lives at `../tests/opencode-plugin/fixtures/opencode.jsonc`;
load it only from an isolated OpenCode instance with temporary XDG directories
and a temporary project. Never point tests at the user's configuration or
running service.

Plugin options:

- `registryDir`: override the registry directory (default:
  `stdpath("state")/opencode/tools`, i.e. `$XDG_STATE_HOME/nvim/opencode/tools`).
- `healthTimeoutMs`: health check budget, default 1500.
- `requestTimeoutMs`: action request budget, default 10000.

`OPENCODE_NVIM_REGISTRY_DIR` overrides the default registry directory for
harnesses and tests.

## Registry and RPC

Registry entries are created by `lua/opencode/tools/registry.lua`:
`<registryDir>/<instance_id>.json` with `schema: 1`, `instance_id`,
`project_root`, `url`, `token`, and `pid`.

For each call the plugin:

1. Canonicalizes `ctx.location.project.canonical` (falling back to
   `project.directory`, `location.directory`, then the process cwd), resolving
   symlinks.
2. Selects live registry entries whose canonical `project_root` matches.
3. Rejects dead PIDs and entries whose `GET /health` envelope identifies a
   different instance.
4. Returns a clear error for zero instances or multiple healthy instances.
5. Sends `POST /tools/<action>` with `Authorization: Bearer <token>` and the
   09A envelope `{version, request_id, action, input}`, passing
   `context.signal` to `fetch` so cancelled tool calls stop in flight.

Tokens never appear in tool output, metadata, logs, or error messages.

## Development

```sh
npm install
npm run typecheck
npm test
npm run build
```

Unit and fake-server tests use a temporary registry and a local fake Neovim
server. They also verify that registration succeeds and tool calls fail
cleanly when no Neovim instance exists at all. The real-OpenCode check is
opt-in and isolated:

```sh
OPENCODE_NVIM_REAL_TEST=1 \
OPENCODE_NVIM_BIN=/path/to/opencode \
npm test
```

It creates temporary `HOME`/XDG directories and a temporary project under
`/tmp/opencode`, starts `opencode serve` on a random loopback port, and never
reads or writes user OpenCode config or connects to the user's service.
