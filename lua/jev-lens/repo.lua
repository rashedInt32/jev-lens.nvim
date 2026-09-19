-- Repo identity, computed the same way the hook plugin does: git toplevel,
-- then the first 16 hex chars of its sha256.
local M = {}

local cache = {}

---@param dir string|nil
---@return string|nil root absolute git toplevel, nil outside a repo
function M.root(dir)
  dir = dir or vim.fn.getcwd()
  if cache[dir] ~= nil then
    return cache[dir] or nil
  end
  local ok, res = pcall(function()
    return vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  end)
  local root = nil
  if ok and res and res.code == 0 then
    root = vim.trim(res.stdout or "")
    if root == "" then
      root = nil
    end
  end
  cache[dir] = root or false
  return root
end

function M.clear_cache()
  cache = {}
end

---@param root string
---@return string key
function M.key(root)
  return vim.fn.sha256(root):sub(1, 16)
end

---@param root string
---@return string dir
function M.dir(root)
  return require("jev-lens.config").options.data_dir .. "/repos/" .. M.key(root)
end

function M.verdict_path(root)
  return M.dir(root) .. "/verdict.json"
end

function M.state_path(root)
  return M.dir(root) .. "/state.json"
end

return M
