-- Strip debris the verdict flagged. Three safety rules, none optional:
--   1. refuse when the file's buffer is loaded and modified
--   2. every candidate's on-disk lines must equal the judged lines exactly
--   3. delete from the bottom up so earlier line numbers stay valid
local M = {}

local function read_lines(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

local function write_lines(path, lines)
  local f = assert(io.open(path, "w"))
  f:write(table.concat(lines, "\n"))
  if #lines > 0 then
    f:write("\n")
  end
  f:close()
end

--- Is a loaded buffer for this path modified?
local function buffer_modified(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false, nil
  end
  return vim.bo[bufnr].modified, bufnr
end

--- Plan the strip for one file without touching disk.
---@param root string
---@param file string repo-relative
---@param candidates table[] verdict.debris entries for this file
---@return { ok: boolean, reason?: string, apply?: table[], skipped: table[] }
function M.plan(root, file, candidates)
  local path = root .. "/" .. file
  local modified, bufnr = buffer_modified(path)
  if modified then
    return { ok = false, reason = ("buffer for %s has unsaved changes"):format(file), skipped = candidates }
  end
  local lines = read_lines(path)
  if not lines then
    return { ok = false, reason = ("cannot read %s"):format(file), skipped = candidates }
  end
  local apply, skipped = {}, {}
  local claimed = {}
  for _, c in ipairs(candidates) do
    local matches = c.end_line <= #lines
    -- Never let two candidates delete the same line; the second would shift.
    for i = c.line, c.end_line do
      if claimed[i] then
        matches = false
      end
    end
    if matches then
      for i = c.line, c.end_line do
        if lines[i] ~= c.lines[i - c.line + 1] then
          matches = false
          break
        end
      end
    end
    if matches then
      apply[#apply + 1] = c
      for i = c.line, c.end_line do
        claimed[i] = true
      end
    else
      skipped[#skipped + 1] = c
    end
  end
  table.sort(apply, function(a, b)
    return a.line > b.line
  end)
  return { ok = true, apply = apply, skipped = skipped, lines = lines, path = path, bufnr = bufnr }
end

--- Apply a plan: delete the verified ranges bottom-up, write, reload buffer.
---@param plan table from M.plan
---@return integer removed_lines
function M.apply(plan)
  if not plan.ok then
    return 0
  end
  local lines = plan.lines
  local removed = 0
  for _, c in ipairs(plan.apply) do
    for _ = c.line, c.end_line do
      table.remove(lines, c.line)
      removed = removed + 1
    end
  end
  if removed > 0 then
    write_lines(plan.path, lines)
    if plan.bufnr and vim.api.nvim_buf_is_loaded(plan.bufnr) then
      vim.api.nvim_buf_call(plan.bufnr, function()
        vim.cmd("silent! edit!")
      end)
    end
  end
  return removed
end

--- Strip every flagged candidate in the given files (or all files when nil).
---@param root string
---@param v table verdict
---@param files string[]|nil
---@return { removed: integer, refused: string[], moved: integer }
function M.run(root, v, files)
  local want = nil
  if files then
    want = {}
    for _, f in ipairs(files) do
      want[f] = true
    end
  end
  local by_file = {}
  for _, c in ipairs(v.debris) do
    if not want or want[c.file] then
      by_file[c.file] = by_file[c.file] or {}
      table.insert(by_file[c.file], c)
    end
  end
  local result = { removed = 0, refused = {}, moved = 0 }
  for file, candidates in pairs(by_file) do
    local plan = M.plan(root, file, candidates)
    if not plan.ok then
      result.refused[#result.refused + 1] = plan.reason
    else
      result.moved = result.moved + #plan.skipped
      result.removed = result.removed + M.apply(plan)
    end
  end
  return result
end

return M
