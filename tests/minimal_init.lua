-- Minimal init for the test suite: the plugin and nothing else. The data dir
-- is a temp directory passed in by run.sh via $JEV_LENS_DIR.
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")

vim.opt.rtp:prepend(root)
vim.g.jev_lens_test_root = root
vim.o.swapfile = false
