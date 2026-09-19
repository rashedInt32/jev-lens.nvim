-- Watch the repo's data dir for a new verdict. fs_event first, a slow poll
-- as the fallback, both feeding one debounced check.
local Config = require("jev-lens.config")
local Repo = require("jev-lens.repo")
local Verdict = require("jev-lens.verdict")

local uv = vim.uv or vim.loop

local M = {}

local state = {
  root = nil,
  handle = nil,
  timer = nil,
  last_mtime = nil,
  shown = {}, -- verdict id -> true
  on_verdict = nil,
}

local function mtime(path)
  local st = uv.fs_stat(path)
  return st and (st.mtime.sec * 1e9 + st.mtime.nsec) or nil
end

--- Look at the file once; fire the callback when a new pending verdict is there.
function M.check(force)
  if not state.root then
    return
  end
  local path = Repo.verdict_path(state.root)
  local m = mtime(path)
  if not force and m == state.last_mtime then
    return
  end
  state.last_mtime = m
  local v = Verdict.pending(state.root, { show_shadow = Config.options.show_shadow })
  if not v or state.shown[v.id] then
    return
  end
  state.shown[v.id] = true
  if state.on_verdict then
    state.on_verdict(state.root, v)
  end
end

local function start_fs_event(dir)
  if state.handle then
    state.handle:stop()
    state.handle = nil
  end
  local ok, handle = pcall(uv.new_fs_event)
  if not ok or not handle then
    return
  end
  local started = handle:start(dir, {}, function(err)
    if err then
      return
    end
    vim.schedule(function()
      M.check(false)
    end)
  end)
  if started == 0 then
    state.handle = handle
  end
end

--- Start watching for the given repo root.
---@param root string
---@param on_verdict fun(root: string, v: table)
function M.start(root, on_verdict)
  M.stop()
  state.root = root
  state.on_verdict = on_verdict
  local dir = Repo.dir(root)
  vim.fn.mkdir(dir, "p")
  start_fs_event(dir)
  state.timer = uv.new_timer()
  state.timer:start(Config.options.poll_ms, Config.options.poll_ms, function()
    vim.schedule(function()
      M.check(false)
    end)
  end)
  if Config.options.on_startup then
    M.check(true)
  else
    state.last_mtime = mtime(Repo.verdict_path(root))
    local v = Verdict.pending(root, { show_shadow = Config.options.show_shadow })
    if v then
      state.shown[v.id] = true
    end
  end
end

function M.stop()
  if state.handle then
    state.handle:stop()
    state.handle = nil
  end
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  state.root = nil
  state.last_mtime = nil
end

--- Forget a verdict id so it can be shown again (used by :JevLens show).
function M.forget(id)
  state.shown[id] = nil
end

function M.root()
  return state.root
end

return M
