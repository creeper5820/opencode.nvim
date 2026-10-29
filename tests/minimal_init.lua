-- Minimal test init: no user configuration, no automatically loaded plugins,
-- and only this repository (plus $VIMRUNTIME) on 'runtimepath'. Tests that
-- exercise plugin loading must source plugin/opencode.lua explicitly.
local source = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(source, ":p:h:h")
local runtime = vim.env.VIMRUNTIME

local runtimepath = { repo }
if runtime and runtime ~= "" then
  runtimepath[#runtimepath + 1] = runtime
end

vim.opt.runtimepath = runtimepath
vim.opt.loadplugins = false
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.undofile = false
vim.g.mapleader = " "
vim.g.maplocalleader = " "
