-- Read and interpret verdict.json and state.json. Pure functions where
-- possible so the renderer and the tests can share them.
local Repo = require("jev-lens.repo")

local M = {}

local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  local ok, value = pcall(vim.json.decode, raw)
  if not ok or type(value) ~= "table" then
    return nil
  end
  return value
end

local function write_json(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(value))
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
end

---@param root string
---@return table|nil verdict
function M.read(root)
  local v = read_json(Repo.verdict_path(root))
  if not v or v.version ~= 1 then
    return nil
  end
  return v
end

---@param root string
---@return table|nil state
function M.read_state(root)
  return read_json(Repo.state_path(root))
end

--- The verdict that still wants the user's attention, or nil.
---@param root string
---@param opts? { show_shadow?: boolean }
---@return table|nil
function M.pending(root, opts)
  opts = opts or {}
  local v = M.read(root)
  if not v or v.reviewed then
    return nil
  end
  if v.mode == "shadow" and not opts.show_shadow then
    return nil
  end
  local state = M.read_state(root)
  if state and state.reviewed_id == v.id then
    return nil
  end
  return v
end

--- Mark the verdict reviewed: baseline moves to the judged tree, verdict is
--- flagged. Mirrors `judge.mjs --reviewed` without needing node.
---@param root string
---@param v table
---@return boolean ok, string|nil err
function M.mark_reviewed(root, v)
  local state = M.read_state(root)
  if not state then
    return false, "no state file for this repo"
  end
  state.baseline = v.tree
  state.baseline_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  state.baseline_reason = "reviewed"
  state.reviewed_id = v.id
  write_json(Repo.state_path(root), state)
  v.reviewed = true
  write_json(Repo.verdict_path(root), v)
  return true
end

local KIND_LABEL = {
  debris = "leftover debris",
  out_of_scope = "out of scope",
  behavior_change = "behavior change",
  rule_violation = "rule violation",
  cosmetic = "cosmetic",
  routine = "skip",
  unsure = "unsure",
  unjudged = "not judged",
}

local DEBRIS_LABEL = {
  comment = { "comment", "comments" },
  debug = { "log", "logs" },
  todo = { "todo", "todos" },
  suppression = { "suppression", "suppressions" },
  any_cast = { "any", "anys" },
}

local function debris_summary(counts)
  local parts = {}
  for _, kind in ipairs({ "comment", "debug", "todo", "suppression", "any_cast" }) do
    local n = counts and counts[kind]
    if n and n > 0 then
      local label = DEBRIS_LABEL[kind]
      parts[#parts + 1] = ("%d %s"):format(n, n == 1 and label[1] or label[2])
    end
  end
  return table.concat(parts, " ")
end

local function fmt_p(p)
  if p == nil or p == vim.NIL then
    return "  -- "
  end
  return ("%.2f"):format(p)
end

--- Render the popup lines. Returns lines plus per-line metadata so the
--- window can map cursor rows to files and paint highlights.
---@param v table
---@return string[] lines, table[] meta
function M.render(v)
  local lines, meta = {}, {}
  local session = (v.session and v.session ~= vim.NIL and v.session.name) or "session"
  local look
  if v.look.verdict == "ok" then
    look = ("look: no  %s"):format(fmt_p(v.look.p_ok))
  elseif v.look.verdict == "unsure" or not M.any_flagged(v) then
    -- The overall question and the per-file questions disagree. The number
    -- stays visible; the word stops overclaiming.
    look = ("look: unsure  %s"):format(fmt_p(1 - v.look.p_ok))
    if v.look.verdict ~= "unsure" then
      look = look .. " · no file stands out"
    end
  else
    look = ("look: yes  %s"):format(fmt_p(1 - v.look.p_ok))
  end
  local head = (" jev-lens  %s  %d files  +%d -%d"):format(session, v.summary.files, v.summary.added, v.summary.removed)
  if v.stale then
    head = head .. "  [stale]"
  end
  lines[#lines + 1] = head .. string.rep(" ", math.max(1, 70 - #head - #look)) .. look
  meta[#meta + 1] = { kind = "header", verdict = v.look.verdict }
  lines[#lines + 1] = " " .. string.rep("─", 69)
  meta[#meta + 1] = { kind = "rule" }

  local widest = 0
  for _, f in ipairs(v.files) do
    widest = math.max(widest, #f.path)
  end
  widest = math.min(widest, 40)

  for _, f in ipairs(v.files) do
    local path = f.path
    if #path > widest then
      path = "…" .. path:sub(-(widest - 1))
    end
    local kind = KIND_LABEL[f.kind] or f.kind
    if f.kind == "unsure" and f.kind_top and f.kind_top ~= vim.NIL then
      -- "skip?" reads oddly; the guess is that the change is routine.
      kind = (f.kind_top == "routine" and "routine" or (KIND_LABEL[f.kind_top] or f.kind_top)) .. "?"
    end
    local extra = debris_summary(f.debris)
    if extra == "" and f.prompt_index ~= nil and f.prompt_index ~= vim.NIL and f.kind == "out_of_scope" then
      extra = "no prompt asked"
    elseif extra == "" and f.prompt_index ~= nil and f.prompt_index ~= vim.NIL then
      extra = ("← prompt %d"):format(f.prompt_index + 1)
    end
    lines[#lines + 1] = ("  %-" .. widest .. "s   %-18s %s   %s"):format(path, kind, fmt_p(f.attention), extra)
    meta[#meta + 1] = { kind = "file", file = f, flagged = f.flagged }
  end

  if #v.summary.skipped > 0 then
    lines[#lines + 1] = ("  skipped: %s"):format(table.concat(v.summary.skipped, ", "))
    meta[#meta + 1] = { kind = "skipped" }
  end

  lines[#lines + 1] = " " .. string.rep("─", 69)
  meta[#meta + 1] = { kind = "rule" }
  local k = require("jev-lens.config").options.keys
  lines[#lines + 1] = ("  %s lazydiff   %s strip debris   %s reviewed   %s session   %s re-judge   %s close"):format(
    k.lazydiff, k.strip, k.reviewed, k.jump, k.judge, k.close
  )
  meta[#meta + 1] = { kind = "keys" }
  return lines, meta
end

--- Number of files over the attention bar.
---@param v table
---@return integer
function M.flagged_count(v)
  local n = 0
  for _, f in ipairs(v.files) do
    if f.flagged then
      n = n + 1
    end
  end
  return n
end

---@param v table
---@return boolean
function M.any_flagged(v)
  return M.flagged_count(v) > 0
end

--- One-line summary for the notify path and for other plugins. `reason` is
--- why the router chose a line over a popup, when it did.
---@param v table
---@param reason? string
---@return string
function M.oneline(v, reason)
  local flagged = M.flagged_count(v)
  if v.look.verdict == "ok" then
    return ("jev-lens: nothing needs you (%s ok, %d files, %d debris)"):format(fmt_p(v.look.p_ok), v.summary.files, #v.debris)
  end
  if reason == "tiny" then
    return ("jev-lens: tiny change (+%d -%d), uneasy at %s, not worth a popup"):format(v.summary.added, v.summary.removed, fmt_p(1 - v.look.p_ok))
  end
  if flagged == 0 then
    return ("jev-lens: uneasy at %s, no file stands out (%d files, %d debris)"):format(fmt_p(1 - v.look.p_ok), v.summary.files, #v.debris)
  end
  local line = ("jev-lens: %d of %d files need a look, %d debris"):format(flagged, v.summary.files, #v.debris)
  if reason then
    line = line .. " · " .. reason
  end
  return line
end

return M
