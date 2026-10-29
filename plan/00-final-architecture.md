# Final architecture

`opencode.nvim` is a terminal host for the official OpenCode TUI.  OpenCode
owns rendering, text input, keybindings, the leader, Alt keys, dialogs,
selection, completion, session navigation and the viewport.  The plugin does
not build a second input layer or chat UI.

## Modules

| Module | Responsibility |
| --- | --- |
| `lua/opencode/init.lua` | Public facade, global keymaps/commands, Terminal-mode enforcement, runtime assembly. |
| `lua/opencode/terminal.lua` | PTY lifecycle, window visibility, paste/submit, session width memory. |
| `lua/opencode/config.lua` | Option merge and validation. |
| `lua/opencode/actions/selection.lua` | `<leader>os` / `<leader>oq` paste and question float. |
| `lua/opencode/context.lua` | Visual selection extraction and Markdown formatting. |
| `lua/opencode/health.lua` | Health report without network access. |
| `lua/opencode/channel.lua` | Test double for terminal writes. |

## Input

- The OpenCode window is kept in Terminal mode whenever it is focused.
- `WinEnter`, `BufEnter`, `BufWinEnter` and `ModeChanged` re-enter Terminal mode.
- Global Terminal-mode mappings are shadowed in the OpenCode buffer with a raw
  byte forward so they cannot steal text from the TUI.
- There is no Normal-mode router, logical composer/session region, leader
  pending state, command table, Visual emulation, cursor synchronization or
  click emulation.

## Window lifecycle

- One terminal buffer and one window per embedded TUI.
- `close()` hides the window; the process keeps running.
- `stop()` terminates only the job started by this plugin.
- Vertical layouts remember the last actual window width for the current
  Neovim session and restore it on reopen, clamped to the current columns.
- Horizontal layouts use the configured size.

## Selection

- `<leader>os` opens/focuses the terminal, pastes formatted context and never
  submits.
- `<leader>oq` uses a real Neovim float, then pastes and sends a separate Enter.
- Paste is bracketed and sanitized; no shortcut interpretation.

## Tests

Unit tests cover configuration, facade lifecycle, terminal paste/submit and
width memory, selection formatting/actions and TUI smoke.  A separate tmux
end-to-end script drives an isolated Neovim + official standalone TUI and
verifies native Alt/leader input, real TUI cursor movement, hide/reveal and the
Terminal-mode invariant.
