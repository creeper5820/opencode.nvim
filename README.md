# opencode.nvim

A native Neovim client for OpenCode V2. The plugin talks to the OpenCode HTTP
API and renders the conversation in real Neovim windows; it never injects keys
into a terminal UI.

Requirements:

- Neovim >= 0.10 (uses `vim.uv`, `vim.fs` and window-local `winbar`).
- A running OpenCode V2 server reachable over local `http://`.
- Optional: the `opencode-plugin/` TypeScript package to let OpenCode call
  `neovim_open`, `neovim_notify` and `neovim_diff`. The Neovim plugin works
  without it.

## Install

With `lazy.nvim`:

```lua
{
  "your-name/opencode.nvim",
  config = function()
    require("opencode").setup({
      server = {
        url = "http://127.0.0.1:4096",
        headers = {},
      },
    })
  end,
}
```

Start the server separately, for example:

```sh
OPENCODE_SERVER_PASSWORD=your-local-password opencode serve \
  --hostname 127.0.0.1 --port 4096
```

When the server uses a password, pass the matching Basic auth header:

```lua
require("opencode").setup({
  server = {
    url = "http://127.0.0.1:4096",
    headers = {
      Authorization = "Basic " .. vim.base64.encode("opencode:your-local-password"),
    },
  },
})
```

The plugin does not start or stop an OpenCode server. HTTPS/TLS is not
implemented in the first version.

## Commands

| Command | Description |
| --- | --- |
| `:OpenCode [toggle\|open\|close\|submit\|interrupt\|reset\|health]` | Main command; no argument toggles the sidebar. |
| `:OpenCodeToggle` | Open or hide the sidebar. |
| `:OpenCodeSubmit` | Submit the current sidebar input. |
| `:OpenCodeHealth` | Print the combined health report, including semantic keybindings and runtime tool-server errors. |

`:checkhealth opencode` reports the core environment, configuration and
OpenCode `cli.json`/semantic-keybinding diagnostics. `:OpenCodeHealth` prints
the same combined report (including runtime tool-server errors when present).
Missing optional companion files are informational only and never make setup or
health fail.

## Default keymaps

| Key | Mode | Action |
| --- | --- | --- |
| `<leader>oo` | Normal | Open or hide the sidebar. |
| `<leader>os` | Visual | Append the selected code/context to the input draft; never submits. |
| `<leader>oq` | Visual | Open an editable float and submit a question with the selection context. |
| `<C-s>` | Insert/Normal in the input buffer | Submit the current input. |
| `<C-d>` / `<C-u>` | Normal in the messages buffer | Scroll half a page down/up. |
| `<C-f>` / `<C-b>` | Normal in the messages buffer | Scroll a full page down/up. |

All keymaps from `setup()` are configurable. Set a key to `false` to disable it:

```lua
require("opencode").setup({
  keymaps = {
    toggle = "<leader>oo",
    send_selection = "<leader>os",
    question_selection = "<leader>oq",
    submit = "<C-s>",
  },
})
```

The submit key is installed only in the sidebar input buffer. `<Esc>` in Insert
mode is always left to Neovim; the selection and submit keymaps do not affect
normal code buffers.

## OpenCode semantic keybindings

The plugin reads OpenCode V2's semantic command IDs (currently
`session.interrupt`) and maps them buffer-locally on the sidebar messages and
input buffers only. It never forwards raw terminal keys.

Resolution order:

1. `keybindings.cli_path`, when set.
2. Otherwise `$OPENCODE_CONFIG_DIR/cli.json`, or
   `$XDG_CONFIG_HOME/opencode/cli.json` (falling back to `~/.config`).
3. `keybindings.overrides` from Neovim always wins over `cli.json`.
4. `keybindings.read_cli = false` skips the file entirely.

```lua
require("opencode").setup({
  keybindings = {
    enabled = true,
    -- cli_path = "/path/to/cli.json",
    read_cli = true,
    -- OpenCode's default is a single Escape, Normal mode only.
    -- Configure a double Escape like this:
    overrides = { ["session.interrupt"] = "escapeescape" },
    -- sequence_timeout = 300,
  },
})
```

Behavior and constraints:

- The default binding is a single `<Esc>` in **Normal** mode.
- A double Escape can be written as `escapeescape`, `<Esc><Esc>` or
  `escape escape`; the second press must arrive within the sequence timeout.
- The first `<Esc>` in Insert mode only exits Insert. Visual mode is not
  mapped, so a selection is not destroyed by an interrupt.
- A Normal-mode interrupt on an idle session is a server-side no-op and is not
  reported as an error.
- Invalid or conflicting keys produce non-blocking warnings. A mapping that
  would overwrite an existing buffer-local key is skipped and reported by
  `:OpenCodeHealth`.

## Configuration

```lua
require("opencode").setup({
  server = {
    url = "http://127.0.0.1:4096",
    headers = {},
  },
  project = {
    -- nil pins the first resolved project root; set it to override.
    root = nil,
  },
  sidebar = {
    width = 48,
    input_height = 8,
  },
  keymaps = {
    toggle = "<leader>oo",
    send_selection = "<leader>os",
    question_selection = "<leader>oq",
    submit = "<C-s>",
  },
  keybindings = {
    enabled = true,
    cli_path = nil,
    read_cli = true,
    overrides = {},
    sequence_timeout = nil,
  },
  completion = {
    enabled = true,
    auto = true,
    minimum_length = 1,
    debounce = 100,
    limit = 20,
    cache_ttl = 30000,
    file_cache_ttl = 0,
  },
  status = {
    enabled = true,
    spinner_interval = 1000,
    submit_hint = nil,
  },
  tools = {
    -- Start the local tool server once the project root is known.
    enabled = true,
    registry_dir = nil,
    instance_id = nil,
  },
})
```

`setup()` may be called repeatedly; the previous runtime, keymaps, tool
registry entry and session/event subscriptions are replaced.

## Optional OpenCode companion plugin

`opencode-plugin/` is an optional TypeScript package for OpenCode. It exposes
three tools to the agent:

- `neovim_open` opens a file at an optional line/column.
- `neovim_notify` sends an info/warn/error notification.
- `neovim_diff` shows proposed content in a native Neovim diff; it never writes
  to disk.

The Neovim plugin does **not** install, require or probe this package. If it is
absent, setup, health, chat, completion and status keep working; only the
OpenCode -> Neovim tools are unavailable.

Load it from an `opencode.jsonc` that OpenCode reads:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["opencode-nvim-tools"]
}
```

or for a local checkout:

```jsonc
{
  "plugins": ["./plugins/opencode-nvim"]
}
```

The Neovim side starts a local HTTP server on `127.0.0.1` with an ephemeral
port and a generated bearer token, then writes one registry entry under
`stdpath("state")/opencode/tools` (or `tools.registry_dir` /
`$OPENCODE_NVIM_REGISTRY_DIR`). Directory mode is `0700`, file mode is `0600`.
On setup replacement, `:OpenCode reset`, or exit, the entry is removed and the
listener is stopped. Set `tools.enabled = false` to disable the server.

## Testing

All automated tests are isolated:

```sh
bash tests/run.sh                     # unit tests
bash tests/run.sh tests/integration/e2e
OPENCODE_TEST_BIN=opencode bash tests/run.sh tests/integration/e2e
```

The e2e suite uses `tests/support/harness.lua` to create a temporary project,
HOME, all XDG directories and shada under `/tmp/opencode`. It starts its own
headless Neovim and, when requested, its own OpenCode V2 server on a random
loopback port with a test password. It never connects to the user's Neovim,
default OpenCode service, configuration, registry or project. Tests skip the
real-service case when no `opencode` binary is available.

The plugin does not read or modify user OpenCode config in tests; `cli.json`
tests use an explicit temporary path or an isolated XDG tree.

## First-version limitations

- Local `http://` only; TLS/HTTPS is not implemented.
- One current project/session per Neovim instance. There is no session picker,
  rename or multi-session UI yet.
- Permission requests are displayed as `waiting permission`, but there is no
  permission reply UI yet.
- Diffs are shown in the chat timeline and in the native diff view; accepting,
  rejecting or writing proposed content to disk is not implemented.
- The optional companion provides editor tools only; it does not change chat
  behavior.
- No terminal key injection, global `on_key` hook or global Insert mappings.
