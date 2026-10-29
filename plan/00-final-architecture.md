# opencode.nvim final architecture

## Goal

Host the official `opencode` TUI in a Neovim terminal. OpenCode owns rendering,
the composer, dialog state and the session viewport. The plugin owns process
lifecycle, terminal input routing, logical focus, selection injection and
health checks.

## Module map

| Module | Responsibility |
| --- | --- |
| `lua/opencode/init.lua` | Public facade, setup/teardown, global keymaps, commands and autocmds. |
| `lua/opencode/terminal.lua` | Command construction, PTY lifecycle, split window, hide/show/stop, terminal channel. |
| `lua/opencode/channel.lua` | Fake channel used by tests; production channels come from `terminal:channel()`. |
| `lua/opencode/router.lua` | Buffer-local Normal-mode mapping plan and execution. |
| `lua/opencode/primitives.lua` | Vim-like composer/session primitives mapped to TUI input bytes. |
| `lua/opencode/focus.lua` | Logical composer/session region state. |
| `lua/opencode/keybindings/defaults.lua` | OpenCode V2 native keybinding defaults. |
| `lua/opencode/keybindings/init.lua` | Effective cli.json resolution and diagnostics. |
| `lua/opencode/keybindings/key.lua` | OpenCode/Neovim key syntax parser. |
| `lua/opencode/keybindings/encode.lua` | Terminal PTY byte encoder. |
| `lua/opencode/actions/selection.lua` | Visual selection extraction and TUI composer injection. |
| `lua/opencode/context.lua` | Pure selection capture and Markdown formatting. |
| `lua/opencode/config.lua` | Defaults, merge and validation. |
| `lua/opencode/health.lua` | `:checkhealth` and `:OpenCodeHealth` source. |

## Terminal contract

- `terminal:open(opts)` starts `opencode` with directory/session/continue/prompt
  arguments or reveals the existing window.
- `terminal:close()` hides the window without stopping the job.
- `terminal:stop()` terminates only this plugin's job and deletes its buffer.
- `terminal:channel()` returns `send`, `paste`, `submit` and `is_alive`.
- `paste()` sends bracketed paste (with CR normalization and terminator
  sanitizing); `submit()` sends a distinct Enter. They are never combined into
  one write by the selection actions.

## Input contract

- Insert mode has no plugin mappings.
- Normal mode mappings are buffer-local.
- Native OpenCode bindings come first and are encoded to PTY bytes.
- Composer primitives are installed only when no native binding owns the key.
- Unbound printable/special keys are forwarded.
- No global `on_key` hook and no screen-row inference.

## Focus contract

- Regions: `composer`, `session`.
- Explicit APIs: `focus_input`, `focus_session`, `focus_next`, `get_focus`,
  `get_focus_state`.
- Window leave stores the region; window enter restores it.
- Motion/page/first/last primitives never change the region.

## Selection contract

- `send_selection` pastes formatted context and never submits.
- `question_selection` uses a real float; submit pastes question + context and
  then sends a separate submit event.
- No HTTP client, session controller or plugin-owned session ID.
- Tests inject a fake terminal channel.

## Verification

```sh
bash tests/run.sh
```

The suite covers configuration, focus, key resolution/encoding, router plans and
buffer mappings, primitives, selection actions, terminal lifecycle and an
isolated real OpenCode TUI smoke test. All environments live under
`/tmp/opencode`.
