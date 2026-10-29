# opencode.nvim

Host the official OpenCode terminal UI inside Neovim. OpenCode remains the
renderer, composer, dialog owner and input owner; the plugin only manages the
terminal process, window visibility, selection actions and health checks.

Requirements:

- Neovim >= 0.10 (`vim.uv`, terminal buffers, `vim.keymap`).
- The `opencode` CLI on `$PATH`.

No OpenCode server has to be started separately. The plugin starts the official
CLI in a terminal buffer, so providers, models, permissions, sessions, dialogs,
completion and every keybinding stay inside OpenCode.

## Install

With `lazy.nvim`:

```lua
{
  "creeper5820/opencode.nvim",
  config = function()
    require("opencode").setup()
  end,
}
```

The plugin is pure Lua. It loads no TypeScript package, HTTP client, external
service or companion process.

## Commands

| Command | Description |
| --- | --- |
| `:OpenCode [toggle]` | Open or hide the TUI. |
| `:OpenCode open [dir]` | Open in `dir` (defaults to `project.root` or the current directory). |
| `:OpenCode close` | Hide the TUI window; the OpenCode process keeps running. |
| `:OpenCode stop` | Stop the OpenCode process started by this plugin. |
| `:OpenCode restart [dir]` | Stop and start a fresh TUI. |
| `:OpenCode continue [dir]` | Start with `--continue` (last session). |
| `:OpenCode session <id> [dir]` | Start or resume a specific session with `--session`. |
| `:OpenCode new [dir]` | Start without the configured session/continue flags. |
| `:OpenCode submit` | Send Enter to the TUI composer. |
| `:OpenCode health` | Print the health report. |

Convenience commands: `:OpenCodeToggle`, `:OpenCodeOpen`, `:OpenCodeClose`,
`:OpenCodeStop`, `:OpenCodeContinue`, `:OpenCodeSession`, `:OpenCodeSubmit`,
`:OpenCodeHealth`.

Opening a TUI that is already running reveals its window. Use `:OpenCode stop`
or `:OpenCode restart` before changing session or directory flags.

## Default keymaps

| Key | Mode | Action |
| --- | --- | --- |
| `<leader>oo` | Normal | Open or hide the OpenCode TUI. |
| `<leader>os` | Visual | Paste formatted selection context into the TUI composer; never submits. |
| `<leader>oq` | Visual | Open a real Neovim float, then paste question + context and submit it. |

Each keymap can be changed or disabled with `false`:

```lua
require("opencode").setup({
  keymaps = {
    toggle = "<leader>oo",
    send_selection = "<leader>os",
    question_selection = "<leader>oq",
  },
})
```

These are ordinary global editor mappings. The plugin installs no Normal-mode
mappings inside the OpenCode terminal.

## Terminal behaviour

The TUI runs in one terminal buffer and one Neovim window. While that window is
focused it stays in Terminal mode, so OpenCode receives every key directly:

- text, Enter, Escape, arrows, function keys and modified keys;
- Alt keys and Alt combinations;
- the OpenCode leader key and all multi-key sequences;
- dialogs, completion, session navigation and all native editing behavior.

There is no logical composer/session split, Normal-mode command table, leader
replay, Visual emulation, cursor synchronization or click emulation. OpenCode
owns all of that.

Global Neovim `Terminal`-mode mappings are shadowed in the OpenCode buffer by a
raw byte forward of their own lhs. This keeps LazyVim-style terminal mappings
such as `t jk` from stealing text from the TUI. The forwarding is plain
pass-through; it does not interpret OpenCode commands.

If the terminal window is focused and something leaves Terminal mode, the
plugin re-enters Terminal mode on `WinEnter`, `BufEnter`, `BufWinEnter` and
`ModeChanged`. Hiding, revealing and ordinary window switching keep the same
process and buffer semantics as any Neovim terminal.

Closing the window hides the terminal; the process and its session remain
alive. `:OpenCode stop` terminates only the process started by this plugin.

For vertical `right`/`left` layouts the plugin remembers the actual window
width you set during the current Neovim session. Hiding/closing and reopening
restores that width, clamped to the current `vim.o.columns`. Horizontal
layouts use `window.size`. Disable this with `window.remember_width = false`.

## Configuration

```lua
require("opencode").setup({
  cmd = "opencode",
  args = {},
  cwd = nil,
  project = { root = nil },
  session = { continue = false, id = nil, prompt = nil },
  window = {
    layout = "right",       -- right | left | above | below
    size = 80,
    remember_width = true,
  },
  keymaps = {
    toggle = "<leader>oo",
    send_selection = "<leader>os",
    question_selection = "<leader>oq",
  },
  paste = {
    bracketed = true,
    ready_delay = 150,
    submit_delay = 30,
  },
})
```

Per-open flags are available through the Lua API:

```lua
require("opencode").open({
  directory = "~/src/project",
  session = "ses_123",
  continue = false,
  prompt = "Review the current diff",
})
```

`session` wins over `continue`. The project directory is appended as OpenCode's
positional directory argument.

## Selection actions

`<leader>os` extracts the current Visual selection, formats it as Markdown with
a safe fence and path/line range, opens/focuses the terminal and pastes it into
the TUI composer. It never submits.

`<leader>oq` opens an editable Neovim float. On `<C-s>` the plugin:

1. pastes the question plus formatted selection as one bracketed paste;
2. sends a separate Enter/Submit event after a short delay.

The float keeps its text on failure and closes on cancellation. Empty questions
are rejected. Ordinary text, including text beginning with `/`, `:` or a key
name, is never interpreted as TUI shortcuts because it travels inside a
bracketed paste. The bracketed-paste terminator is sanitized before sending.

No session ID is created or tracked by the plugin; OpenCode owns the session.

## Health

`:checkhealth opencode` and `:OpenCodeHealth` report:

- Neovim and `vim.uv` availability;
- configuration validity;
- the configured OpenCode executable and its `--version`;
- terminal process/window state.

No network service is required for health checks.

## Testing

All unit tests use an isolated headless Neovim with temporary HOME/XDG
directories, shada and project under `/tmp/opencode`:

```sh
bash tests/run.sh
```

The terminal smoke test starts an isolated official OpenCode TUI with
`--standalone`, verifies that it renders and receives terminal input, then stops
only the process created by that test.

A real tmux end-to-end check drives an isolated Neovim + official TUI through a
private tmux socket:

```sh
python3 tests/e2e/tmux_e2e.py
```

It verifies native text input despite a global `t jk` mapping, Alt word
movement, the native leader combination, real TUI cursor movement, window
hide/reveal returning to Terminal mode, explicit `Ctrl-\ Ctrl-n` returning to
Terminal mode, and remembered vertical width across close/open. It never
connects to the user's OpenCode service or tmux sessions.

## Limitations

- One embedded TUI per Neovim instance.
- OpenCode renders every region; the plugin does not add a separate chat UI,
  dialog layer, completion source or input state machine.
- Modified-key support depends on the terminal and OpenCode's input protocol.
- The selection float submits through the terminal channel and does not wait for
  agent completion.
