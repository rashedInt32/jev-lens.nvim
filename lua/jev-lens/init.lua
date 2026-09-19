-- jev-lens.nvim: a verdict popup for Claude Code edits, judged by Jev.
-- The hook plugin writes verdict.json; this plugin watches and renders it.
local Config = require("jev-lens.config")
local Repo = require("jev-lens.repo")
local Verdict = require("jev-lens.verdict")

local M = {}

local function notify(msg, level)
  Config.options.notify(msg, level or vim.log.levels.INFO)
end

-- Per-repo memory the router consults. Lives for this nvim only.
local quiet_next = {} -- root -> true: the next verdict came from a strip; update silently
local dismissed = {} -- root -> set of flagged paths the user closed with q/Esc

--- The next verdict for this repo is expected (a re-judge after a strip)
--- and must not reopen the popup.
function M.quiet_next(root)
  quiet_next[root] = true
end

--- Remember what the user dismissed, so the same files do not pop again.
function M.dismissed(root, v)
  local set = {}
  for _, f in ipairs(v.files) do
    if f.flagged then
      set[f.path] = true
    end
  end
  dismissed[root] = set
end

function M.forget_dismissed(root)
  dismissed[root] = nil
end

local function flagged_subset_of_dismissed(root, v)
  local set = dismissed[root]
  if not set then
    return false
  end
  for _, f in ipairs(v.files) do
    if f.flagged and not set[f.path] then
      return false
    end
  end
  return true
end

local function all_flagged_cosmetic(v)
  local any = false
  for _, f in ipairs(v.files) do
    if f.flagged then
      any = true
      if f.kind ~= "cosmetic" then
        return false
      end
    end
  end
  return any
end

--- Route a new pending verdict. The popup opens only when it has a row worth
--- reading and the moment is right; everything else is one notify line.
---@param root string
---@param v table
---@return "notify"|"popup"|"deferred"
function M.route(root, v)
  -- Never steal focus while typing; route again once insert mode ends.
  if vim.fn.mode():sub(1, 1) == "i" then
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = vim.api.nvim_create_augroup("jev-lens-defer", { clear = true }),
      once = true,
      callback = function()
        M.route(root, v)
      end,
    })
    return "deferred"
  end
  local reason = nil
  if v.notify_only and v.notify_only ~= vim.NIL then
    reason = v.notify_only -- judge-side: tiny diff
  elseif v.look.verdict == "ok" then
    reason = "ok"
  elseif not Verdict.any_flagged(v) then
    reason = "no file stands out"
  elseif all_flagged_cosmetic(v) then
    reason = "cosmetic only"
  elseif quiet_next[root] then
    reason = "after strip"
  elseif flagged_subset_of_dismissed(root, v) then
    reason = "same files as the dismissed verdict"
  end
  quiet_next[root] = nil
  if reason then
    notify(Verdict.oneline(v, reason), v.look.verdict == "ok" and vim.log.levels.INFO or vim.log.levels.WARN)
    return "notify"
  end
  require("jev-lens.popup").show(root, v)
  return "popup"
end

local function on_verdict(root, v)
  M.route(root, v)
end

---@param opts? JevLensConfig
function M.setup(opts)
  Config.setup(opts)
  local root = Repo.root()
  if root then
    require("jev-lens.watch").start(root, on_verdict)
  end
  vim.api.nvim_create_autocmd("DirChanged", {
    group = vim.api.nvim_create_augroup("jev-lens", { clear = true }),
    callback = function()
      Repo.clear_cache()
      local r = Repo.root()
      if r and r ~= require("jev-lens.watch").root() then
        require("jev-lens.watch").start(r, on_verdict)
      end
    end,
  })
  require("jev-lens.commands").setup()
end

--- The unreviewed verdict for the current repo, or nil. For other plugins.
---@return table|nil
function M.pending()
  local root = Repo.root()
  if not root then
    return nil
  end
  return Verdict.pending(root, { show_shadow = Config.options.show_shadow })
end

--- Show the latest verdict for this repo, reviewed or not.
function M.show()
  local root = Repo.root()
  local v = root and Verdict.read(root)
  if not v then
    notify("no verdict for this repo", vim.log.levels.WARN)
    return false
  end
  require("jev-lens.popup").show(root, v)
  return true
end

function M.judge()
  local root = Repo.root()
  if not root then
    notify("not in a git repo", vim.log.levels.WARN)
    return false
  end
  local Watch = require("jev-lens.watch")
  return require("jev-lens.actions").judge(root, function(code)
    if code ~= 0 then
      notify("judge exited " .. tostring(code), vim.log.levels.ERROR)
      return
    end
    local v = Verdict.read(root)
    if v then
      Watch.forget(v.id)
    end
    Watch.check(true)
    if not v then
      notify("no diff since baseline")
    end
  end)
end

function M.reviewed()
  local root = Repo.root()
  local v = root and Verdict.read(root)
  if not v then
    notify("no verdict to mark", vim.log.levels.WARN)
    return false
  end
  return require("jev-lens.actions").reviewed(root, v)
end

function M.toggle()
  local Popup = require("jev-lens.popup")
  if Popup.is_open() then
    Popup.close()
    return
  end
  M.show()
end

return M
