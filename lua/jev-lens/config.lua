local M = {}

---@class JevLensConfig
---@field data_dir string        root of the jev-lens data dir (honours $JEV_LENS_DIR)
---@field poll_ms integer        fallback poll interval for the verdict file
---@field show_shadow boolean    render verdicts judged in shadow mode
---@field on_startup boolean     show a pending verdict when nvim opens in the repo
---@field judge_cmd string[]|nil command that runs the judge; nil = auto-resolve
---@field notify fun(msg: string, level: integer)
---@field keys table<string, string>
---@field float { width: number, border: string }
M.defaults = {
  data_dir = (vim.env.JEV_LENS_DIR and vim.env.JEV_LENS_DIR) or (vim.env.HOME .. "/.claude/jev-lens"),
  poll_ms = 1000,
  show_shadow = false,
  on_startup = true,
  judge_cmd = nil,
  notify = function(msg, level)
    vim.notify(msg, level, { title = "jev-lens" })
  end,
  keys = {
    lazydiff = "l",
    strip = "s",
    reviewed = "r",
    jump = "j",
    judge = "R",
    close = "q",
  },
  float = { width = 0.7, border = "rounded" },
}

---@type JevLensConfig
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  vim.validate({
    data_dir = { M.options.data_dir, "string" },
    poll_ms = { M.options.poll_ms, "number" },
    show_shadow = { M.options.show_shadow, "boolean" },
    on_startup = { M.options.on_startup, "boolean" },
    notify = { M.options.notify, "function" },
  })
  return M.options
end

return M
