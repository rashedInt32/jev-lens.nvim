-- The popup's verbs. Each one is small and pcall-guards its optional
-- neighbours (lazydiff, sidekick, tmux).
local Config = require("jev-lens.config")
local Verdict = require("jev-lens.verdict")
local Strip = require("jev-lens.strip")

local M = {}

local function notify(msg, level)
  Config.options.notify(msg, level or vim.log.levels.INFO)
end

--- Open the file and turn lazydiff on for it when available.
function M.lazydiff(root, file)
  vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. file))
  local ok, lazydiff = pcall(require, "lazydiff")
  if ok and type(lazydiff.enable) == "function" then
    pcall(lazydiff.enable, 0)
    pcall(lazydiff.goto_first, 0)
  end
end

--- Strip debris after a confirm. `files` nil means every file in the verdict.
function M.strip(root, v, files)
  local count = 0
  for _, c in ipairs(v.debris) do
    if not files or vim.tbl_contains(files, c.file) then
      count = count + 1
    end
  end
  if count == 0 then
    notify("nothing to strip")
    return nil
  end
  local where = files and table.concat(files, ", ") or ("%d files"):format(v.summary.files)
  local answer = vim.fn.confirm(("Strip %d flagged debris in %s?"):format(count, where), "&Yes\n&No", 2)
  if answer ~= 1 then
    return nil
  end
  local result = Strip.run(root, v, files)
  local msg = ("removed %d lines"):format(result.removed)
  if result.moved > 0 then
    msg = msg .. (", skipped %d (content moved)"):format(result.moved)
  end
  for _, r in ipairs(result.refused) do
    msg = msg .. "\nrefused: " .. r
  end
  notify(msg, #result.refused > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
  return result
end

function M.reviewed(root, v)
  local ok, err = Verdict.mark_reviewed(root, v)
  if ok then
    notify("marked reviewed; baseline moved")
  else
    notify("could not mark reviewed: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

--- Jump to the session: sidekick window by pid, else tmux pane.
function M.jump(v)
  local s = v.session
  if not s or s == vim.NIL then
    notify("no session recorded on this verdict", vim.log.levels.WARN)
    return false
  end
  local ok, Terminal = pcall(require, "sidekick.cli.terminal")
  if ok and s.pid and s.pid ~= vim.NIL then
    for _, t in ipairs(Terminal.sessions()) do
      if vim.tbl_contains(t.pids or {}, s.pid) and t:win_valid() then
        vim.api.nvim_set_current_win(t.win)
        return true
      end
    end
  end
  if s.tmux and s.tmux ~= vim.NIL and vim.env.TMUX then
    local res = vim.system({ "tmux", "switch-client", "-t", s.tmux }, { text = true }):wait()
    if res.code == 0 then
      vim.system({ "tmux", "select-window", "-t", s.tmux }):wait()
      vim.system({ "tmux", "select-pane", "-t", s.tmux }):wait()
      return true
    end
    notify("tmux could not switch to " .. s.tmux, vim.log.levels.WARN)
    return false
  end
  notify("session pane not reachable from here", vim.log.levels.WARN)
  return false
end

--- Resolve the judge command: config, $JEV_LENS_ROOT, or the plugin cache.
---@return string[]|nil
function M.judge_cmd()
  if Config.options.judge_cmd then
    return Config.options.judge_cmd
  end
  local candidates = {}
  if vim.env.JEV_LENS_ROOT then
    candidates[#candidates + 1] = vim.env.JEV_LENS_ROOT .. "/bin/judge.mjs"
  end
  local cache = (vim.env.CLAUDE_CONFIG_DIR or (vim.env.HOME .. "/.claude")) .. "/plugins/cache/jev-lens/jev-lens"
  local versions = vim.fn.glob(cache .. "/*/bin/judge.mjs", true, true)
  table.sort(versions)
  for i = #versions, 1, -1 do
    candidates[#candidates + 1] = versions[i]
  end
  for _, path in ipairs(candidates) do
    if vim.uv.fs_stat(path) then
      return { "node", path }
    end
  end
  return nil
end

--- Run the judge now for this repo. Callback receives the exit code.
function M.judge(root, cb)
  local cmd = M.judge_cmd()
  if not cmd then
    notify("judge not found: set judge_cmd or $JEV_LENS_ROOT", vim.log.levels.ERROR)
    return false
  end
  local args = vim.list_extend(vim.deepcopy(cmd), { "--cwd", root, "--reason", "manual" })
  notify("judging…")
  vim.system(args, { text = true }, function(res)
    vim.schedule(function()
      if cb then
        cb(res.code)
      end
    end)
  end)
  return true
end

return M
