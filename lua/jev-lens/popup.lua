-- The verdict window. A plain float over a scratch buffer, no dependencies.
local Config = require("jev-lens.config")
local Verdict = require("jev-lens.verdict")
local Actions = require("jev-lens.actions")

local M = {}

local ns = vim.api.nvim_create_namespace("jev-lens")
local current = nil -- { buf, win, root, verdict, meta }

local function set_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "JevLensHeader", { link = "Title", default = true })
  hl(0, "JevLensLook", { link = "DiagnosticError", default = true })
  hl(0, "JevLensUnsure", { link = "DiagnosticWarn", default = true })
  hl(0, "JevLensOk", { link = "DiagnosticOk", default = true })
  hl(0, "JevLensFlagged", { link = "Normal", default = true })
  hl(0, "JevLensSkip", { link = "Comment", default = true })
  hl(0, "JevLensRule", { link = "FloatBorder", default = true })
  hl(0, "JevLensKeys", { link = "Comment", default = true })
end

function M.is_open()
  return current ~= nil and vim.api.nvim_win_is_valid(current.win)
end

function M.close()
  if current and vim.api.nvim_win_is_valid(current.win) then
    vim.api.nvim_win_close(current.win, true)
  end
  current = nil
end

local function file_under_cursor()
  if not current then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(current.win)[1]
  local m = current.meta[row]
  if m and m.kind == "file" then
    return m.file
  end
  return nil
end

local function paint(buf, meta)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row, m in ipairs(meta) do
    local group
    if m.kind == "header" then
      group = "JevLensHeader"
      local look = ({ ok = "JevLensOk", unsure = "JevLensUnsure", look = "JevLensLook" })[m.verdict]
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
      local at = line:find("look:")
      if at and look then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, at - 1, { end_col = #line, hl_group = look })
      end
    elseif m.kind == "file" then
      group = m.flagged and "JevLensFlagged" or "JevLensSkip"
    elseif m.kind == "rule" then
      group = "JevLensRule"
    else
      group = "JevLensKeys"
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { end_row = row, hl_group = group, hl_eol = true, priority = 10 })
  end
end

local function map(buf, lhs, fn)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
end

--- Show a verdict in a float. Re-opening the same verdict replaces the window.
---@param root string
---@param v table
function M.show(root, v)
  set_highlights()
  M.close()
  local lines, meta = Verdict.render(v)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "jev-lens"
  paint(buf, meta)

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = Config.options.float.border,
    title = " jev-lens ",
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[win].cursorline = true
  current = { buf = buf, win = win, root = root, verdict = v, meta = meta }
  -- Land on the first file row.
  for row, m in ipairs(meta) do
    if m.kind == "file" then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      break
    end
  end

  local k = Config.options.keys
  -- q and Esc are a dismissal: remember the flagged set so the same files do
  -- not pop again on the next stop. Reviewing clears that memory.
  local function dismiss()
    require("jev-lens").dismissed(root, v)
    M.close()
  end
  map(buf, k.close, dismiss)
  map(buf, "<Esc>", dismiss)
  map(buf, k.lazydiff, function()
    local f = file_under_cursor()
    if not f then
      return
    end
    M.close()
    Actions.lazydiff(root, f.path)
  end)
  map(buf, k.strip, function()
    local f = file_under_cursor()
    local result = Actions.strip(root, v, f and { f.path } or nil)
    if result and result.removed > 0 then
      M.close()
      -- The re-judge after a strip is expected; it updates quietly.
      require("jev-lens").quiet_next(root)
      Actions.judge(root)
    end
  end)
  map(buf, k.reviewed, function()
    if Actions.reviewed(root, v) then
      require("jev-lens").forget_dismissed(root)
      M.close()
    end
  end)
  map(buf, k.jump, function()
    M.close()
    Actions.jump(v)
  end)
  map(buf, k.judge, function()
    M.close()
    Actions.judge(root)
  end)
  return win, buf
end

--- The current window's buffer, for tests.
function M.current()
  return current
end

return M
