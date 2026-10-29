# opencode.nvim

Host the official OpenCode terminal UI inside Neovim. OpenCode remains the
renderer, composer and viewport owner; the plugin owns the terminal process,
input routing, logical focus, selection actions and health checks.

Requirements:

- Neovim >= 0.10 (`vim.uv`, terminal buffers, `vim.keymap`).
- The `opencode` CLI on `$PATH`.

No OpenCode server has to be started separately. The plugin starts the official
CLI in a terminal buffer, so providers, models, permissions, session pickers,
dialogs, completion and all TUI rendering stay in OpenCode.

## Install

With `lazy.nvim`:

```lua
{
  "your-name/opencode.nvim",
  config = function()
    require("opencode").setup()
  end,
}
```

The plugin loads no TypeScript package, HTTP client or external service.

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
| `:OpenCode focus-input` | Make the logical composer region current. |
| `:OpenCode focus-session` | Make the logical session region current. |
| `:OpenCode focus-next` | Switch logical regions. |
| `:OpenCode submit` | Send Enter to the TUI composer. |
| `:OpenCode health` | Print the health report. |

Convenience commands: `:OpenCodeToggle`, `:OpenCodeOpen`, `:OpenCodeClose`,
`:OpenCodeStop`, `:OpenCodeContinue`, `:OpenCodeSession`, `:OpenCodeSubmit`,
`:OpenCodeFocusInput`, `:OpenCodeFocusSession`, `:OpenCodeHealth`.

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

The keymaps are global editor mappings. All terminal input handling is
buffer-local to the OpenCode terminal buffer.

## Terminal behaviour

The TUI runs in one terminal buffer and one Neovim window. Closing the window
hides the terminal; the process and its session remain alive. `:OpenCode stop`
terminates only the process started by this plugin.

`setup()` accepts the command and initial session flags:

```lua
require("opencode").setup({
  cmd = "opencode",                 -- or { "bunx", "opencode" }
  args = {},                        -- extra CLI arguments
  cwd = nil,                        -- defaults to project.root/current dir
  project = { root = nil },
  session = {
    continue = false,
    id = nil,
    prompt = nil,
  },
  window = {
    layout = "right",               -- right | left | above | below
    size = 80,
    start_insert = true,
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

## Input routing

Insert mode is pass-through: the official TUI receives all keys. `<Esc>` keeps
its normal Neovim meaning and leaves terminal Insert mode; Neovim's
`<C-\><C-n>` terminal escape also remains available.

Normal mode installs buffer-local mappings in the OpenCode terminal buffer:

1. Effective OpenCode `cli.json` keybindings, including alternatives, custom
   leaders, full multi-key sequences and modifier combinations. Each mapping
   forwards the encoded key sequence to the PTY.
2. Composer editing primitives when no native OpenCode binding owns the key.
3. The optional logical-focus key.
4. Pass-through for otherwise unbound printable and special keys.

There is no global `on_key` hook and no screen/row inspection. `i` and `a`
enter terminal Insert mode, and `:` / `/` remain Neovim commands. `I` and `A`
fall back to Neovim when no native OpenCode binding owns them; all other
unbound Normal keys are forwarded to the TUI.

### Editing primitives

The plugin translates a small Vim-like vocabulary into the TUI's own input
commands. It does not implement text objects, registers or macros, and it does
not redraw the composer.

| Primitive | Behaviour |
| --- | --- |
| `char_left`, `char_right` | Move by character. |
| `line_up`, `line_down` | Move by line in the current region. |
| `word_forward`, `word_backward`, `word_end` | Move by word. |
| `line_start`, `line_end` | Move to line start/end. |
| `buffer_start`, `buffer_end`, `first`, `last` | Start/end of the current region. |
| `page_up`, `page_down`, `half_page_up`, `half_page_down` | Page within the current region. |
| `delete_char`, `delete_char_backward` | Delete character. |
| `delete_line`, `delete_word_forward`, `delete_word_backward` | Delete line/word. |
| `delete_to_line_end`, `delete_to_line_start` | Delete to line boundary. |
| `newline`, `submit`, `clear` | Composer newline, submit, clear. |
| `history_previous`, `history_next` | Composer history. |
| `undo`, `redo` | Composer undo/redo. |

The same names dispatch by logical region: `j` moves the composer cursor in the
composer region and scrolls the session in the session region. Movement and
paging never change the logical region.

Public primitive API:

```lua
local opencode = require("opencode")

-- Execute a primitive; count is forwarded.
opencode.primitive("page_down", 2)

-- Install a Normal-mode buffer-local mapping with count support:
opencode.map_primitive("<C-n>", "page_down")
opencode.map_primitive("gl", "line_down", { count = false })

-- Or bind your own key directly:
vim.keymap.set("n", "<C-p>", function()
  opencode.primitive("page_up", vim.v.count1)
end)
```

`map_primitive` installs into the current OpenCode terminal buffer. Use
`unmap_primitive(lhs)` to remove it. `setup()` replaces all plugin-owned
mappings.

### Native OpenCode keybindings

The effective keybindings are resolved in this order:

1. OpenCode V2 TUI defaults.
2. `keybindings.cli_path`, when set; otherwise
   `$OPENCODE_CONFIG_DIR/cli.json` or `$XDG_CONFIG_HOME/opencode/cli.json`.
3. Neovim `keybindings.overrides`, which always win.
4. `keybindings.read_cli = false` skips the file; `keybindings.enabled = false`
   disables native Normal-mode mappings.

Both `keybinds` and `keybindings` objects in `cli.json` are accepted, including
comma-separated alternatives, arrays, objects and key objects. A custom leader
is expanded in every binding; `<leader>` resolves to the complete configured
leader sequence. Keys that cannot be represented as terminal input are skipped
with a non-blocking diagnostic.

## Logical focus

OpenCode renders one terminal, but input routing keeps two logical regions:

- `composer`
- `session`

Focus changes only through:

- `require("opencode").focus_input()`
- `require("opencode").focus_session()`
- the configurable `keymaps.focus_next` mapping (skipped when an effective
  OpenCode binding already owns that key, so native Tab/Shift-Tab remain
  available)
- leaving and returning to the real OpenCode window

Cursor movement, screen rows, scrolling and `j`/`k` never switch regions.
Returning to the OpenCode window restores the region that was current when the
window was left.

```lua
local opencode = require("opencode")

opencode.focus_input()   -- composer region, Insert when configured
opencode.focus_session() -- session region, Normal for navigation
opencode.focus_next()    -- switch regions

opencode.get_focus()       -- "composer" | "session"
opencode.get_focus_state() -- { region, saved, active, reason, changes }
```

## Selection actions

`<leader>os` extracts the current Visual selection, formats it as Markdown with
a safe fence and path/line range, and pastes it into the TUI composer through
the terminal channel. It never submits.

`<leader>oq` opens an editable Neovim float. On `<C-s>` the plugin:

1. pastes the question plus formatted selection as one bracketed paste;
2. sends a separate Enter/Submit event after a short delay.

The float keeps its text on failure and closes on cancellation. Empty questions
are rejected. Ordinary text, including text beginning with `/`, `:` or a key
name, is never interpreted as TUI shortcuts because it travels inside a
bracketed paste. The bracketed-paste terminator is sanitized before sending.

No session ID is created or tracked by the plugin; OpenCode owns the session.

## Configuration

```lua
require("opencode").setup({
  cmd = "opencode",
  args = {},
  cwd = nil,
  project = { root = nil },
  session = { continue = false, id = nil, prompt = nil },
  window = { layout = "right", size = 80, start_insert = true },
  keymaps = {
    toggle = "<leader>oo",
    send_selection = "<leader>os",
    question_selection = "<leader>oq",
    focus_next = "<Tab>",
  },
  keybindings = {
    enabled = true,
    cli_path = nil,
    read_cli = true,
    overrides = {},
    sequence_timeout = nil,
  },
  input = {
    primitives = true,
    passthrough = true,
  },
  paste = {
    bracketed = true,
    ready_delay = 150,
    submit_delay = 30,
  },
  focus = { initial = "composer" },
})
```

`setup()` may be called repeatedly. The previous terminal process, buffer-local
mappings and autocmds are replaced.

## Health

`:checkhealth opencode` and `:OpenCodeHealth` report:

- Neovim and `vim.uv` availability;
- configuration validity;
- the configured OpenCode executable and its `--version`;
- terminal process/window state;
- effective `cli.json` and keybinding diagnostics.

No network service is required for health checks.

## Testing

All tests use an isolated headless Neovim, temporary HOME/XDG directories,
shada and project under `/tmp/opencode`:

```sh
bash tests/run.sh
bash tests/run.sh tests/unit/router
```

The terminal smoke test starts an isolated official OpenCode TUI with
`--standalone` in its own temporary project, verifies that it renders output and receives terminal input,
then stops only the process created by that test. It does not connect to a user
OpenCode service or configuration.

## Limitations

- One embedded TUI per Neovim instance.
- The logical focus regions are an input-routing abstraction; OpenCode still
  renders both areas in one terminal.
- TUI dialogs, permissions, session selection and completion are driven by
  OpenCode itself; the plugin does not add a separate dialog layer.
- Modified-key support depends on the terminal and OpenCode's input protocol.
- The selection float submits through the terminal channel and does not wait for
  agent completion.
