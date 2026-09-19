local M = {}

local SUB = { "show", "judge", "reviewed", "toggle" }

function M.setup()
  vim.api.nvim_create_user_command("JevLens", function(cmd)
    local sub = cmd.fargs[1] or "toggle"
    local lens = require("jev-lens")
    if not vim.tbl_contains(SUB, sub) then
      vim.notify("JevLens: unknown subcommand " .. sub, vim.log.levels.ERROR)
      return
    end
    lens[sub]()
  end, {
    nargs = "?",
    complete = function()
      return SUB
    end,
    desc = "jev-lens verdict popup",
  })
end

return M
