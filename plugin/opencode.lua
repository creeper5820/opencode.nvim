-- Load guard: loading this file more than once must not create duplicate
-- commands, keymaps or autocmds. Runtime assembly happens in setup().
if vim.g.loaded_opencode_nvim == 1 then
  return
end
vim.g.loaded_opencode_nvim = 1

require("opencode")
