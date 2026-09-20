-- Test suite. Plain asserts, one process, prints a summary and exits non-zero
-- on any failure. Run through tests/run.sh.
local root = vim.g.jev_lens_test_root
local data_dir = assert(vim.env.JEV_LENS_DIR, "run through tests/run.sh")

local failures, passed = {}, 0
local function it(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    io.stdout:write("✔ " .. name .. "\n")
  else
    failures[#failures + 1] = name .. "\n" .. tostring(err)
    io.stdout:write("✖ " .. name .. "\n")
  end
end
local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error((msg or "not equal") .. "\n  actual:   " .. vim.inspect(a) .. "\n  expected: " .. vim.inspect(b), 2)
  end
end
local function truthy(v, msg)
  if not v then
    error(msg or "expected truthy", 2)
  end
end
local function has(s, needle)
  if not s:find(needle, 1, true) then
    error(("expected %q in %q"):format(needle, s), 2)
  end
end
local function lacks(s, needle)
  if s:find(needle, 1, true) then
    error(("did not expect %q in %q"):format(needle, s), 2)
  end
end

local function read(path)
  local f = assert(io.open(path))
  local s = f:read("*a")
  f:close()
  return s
end
local function write(path, s)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(s)
  f:close()
end

local fixture = vim.json.decode(read(root .. "/tests/fixtures/verdict.json"))

-- A fake repo root: no git needed, the modules only need a path and the key.
local repo_root = vim.fn.fnamemodify(vim.fn.tempname(), ":p"):gsub("/$", "")
vim.fn.mkdir(repo_root, "p")

local notices = {}
require("jev-lens.config").setup({
  data_dir = data_dir,
  poll_ms = 50,
  notify = function(msg, level)
    notices[#notices + 1] = { msg = msg, level = level }
  end,
})
local Repo = require("jev-lens.repo")
local Verdict = require("jev-lens.verdict")
local Strip = require("jev-lens.strip")
local Popup = require("jev-lens.popup")
local Watch = require("jev-lens.watch")

local function put_verdict(v)
  write(Repo.verdict_path(repo_root), vim.json.encode(v))
end
local function put_state(s)
  write(Repo.state_path(repo_root), vim.json.encode(s))
end

it("repo key is 16 hex chars of sha256(root), same formula as the hook side", function()
  local key = Repo.key("/some/repo")
  eq(#key, 16)
  truthy(key:match("^%x+$"))
  eq(key, vim.fn.sha256("/some/repo"):sub(1, 16))
end)

it("render matches the agreed popup layout", function()
  local lines, meta = Verdict.render(fixture)
  has(lines[1], "jev-lens  base-7a  3 files  +84 -12")
  has(lines[1], "look: yes  0.93")
  eq(meta[1].kind, "header")
  has(lines[3], "src/auth/session.ts")
  has(lines[3], "behavior change")
  has(lines[3], "0.88")
  has(lines[3], "← prompt 1")
  has(lines[4], "src/app.ts")
  has(lines[4], "leftover debris")
  has(lines[4], "4 comments 1 log")
  has(lines[5], "src/util/format.ts")
  has(lines[5], "skip")
  eq(meta[5].flagged, false)
  has(lines[6], "skipped: pnpm-lock.yaml")
  has(lines[#lines], "l lazydiff")
  has(lines[#lines], "s strip debris")
  has(lines[#lines], "r reviewed")
  has(lines[#lines], "q close")
end)

it("render shows ok and unsure and the stale badge", function()
  local v = vim.deepcopy(fixture)
  v.look = { p_ok = 0.95, verdict = "ok" }
  v.stale = true
  local lines = Verdict.render(v)
  has(lines[1], "look: no  0.95")
  has(lines[1], "[stale]")
  v.look = { p_ok = 0.7, verdict = "unsure" }
  has(Verdict.render(v)[1], "look: unsure  0.30")
  has(Verdict.oneline(v), "2 of 3 files need a look, 2 debris")
end)

it("render lists unverified changes as file rows and the one-liner leads with them", function()
  local v = vim.deepcopy(fixture)
  v.unverified = {
    { file = "src/auth/session.ts", line = 40, kind = "branch", summary = "branch changed in refresh: if (!token) return null;", p_risk = 0.91, p_evidence = 0.05 },
    { file = "src/app.ts", line = 3, kind = "default", summary = "value changed in limit: 3 to 5", p_risk = 0.92, p_evidence = 0.12 },
  }
  v.summary.unverified = 2
  local lines, meta = Verdict.render(v)
  local header
  for i, l in ipairs(lines) do
    if l:find("unverified: 2 changes", 1, true) then
      header = i
    end
  end
  truthy(header, "unverified header row")
  eq(meta[header].kind, "unverified_header")
  has(lines[header + 1], "src/auth/session.ts:40")
  has(lines[header + 1], "branch changed in refresh")
  has(lines[header + 1], "0.05")
  eq(meta[header + 1].kind, "file")
  eq(meta[header + 1].file.path, "src/auth/session.ts")
  eq(meta[header + 1].flagged, true)
  has(lines[header + 2], "src/app.ts:3")
  has(Verdict.oneline(v), "2 unverified changes, 2 of 3 files need a look")
  -- Without the field, nothing changes.
  local plain = vim.deepcopy(fixture)
  plain.unverified = nil
  lacks(table.concat(Verdict.render(plain), "\n"), "unverified")
end)

it("route opens the popup for an unverified change even when the look is green", function()
  local v = vim.deepcopy(fixture)
  v.look = { p_ok = 0.95, verdict = "ok" }
  for _, f in ipairs(v.files) do
    f.flagged = false
  end
  v.unverified = { { file = "src/app.ts", line = 3, kind = "default", summary = "value changed in limit: 3 to 5", p_risk = 0.92, p_evidence = 0.12 } }
  v.summary.unverified = 1
  local out = require("jev-lens").route(repo_root, v)
  eq(out, "popup")
  Popup.close()
  v.unverified = {}
  v.summary.unverified = 0
  eq(require("jev-lens").route(repo_root, v), "notify")
  has(notices[#notices].msg, "nothing needs you")
end)

it("pending: unreviewed shows, reviewed hides, shadow hidden unless asked", function()
  put_verdict(fixture)
  put_state({ version = 1, root = repo_root, baseline = "aaaa" })
  truthy(Verdict.pending(repo_root))
  local v = vim.deepcopy(fixture)
  v.reviewed = true
  put_verdict(v)
  eq(Verdict.pending(repo_root), nil)
  v.reviewed = false
  v.mode = "shadow"
  put_verdict(v)
  eq(Verdict.pending(repo_root), nil)
  truthy(Verdict.pending(repo_root, { show_shadow = true }))
  put_state({ version = 1, root = repo_root, baseline = "aaaa", reviewed_id = fixture.id })
  put_verdict(fixture)
  eq(Verdict.pending(repo_root), nil, "state.reviewed_id also hides")
end)

it("mark_reviewed moves the baseline to the judged tree and flags the verdict", function()
  put_state({ version = 1, root = repo_root, baseline = "aaaa", prompts = {} })
  put_verdict(fixture)
  local v = Verdict.read(repo_root)
  truthy(Verdict.mark_reviewed(repo_root, v))
  local s = Verdict.read_state(repo_root)
  eq(s.baseline, "bbbb")
  eq(s.reviewed_id, fixture.id)
  eq(s.baseline_reason, "reviewed")
  eq(Verdict.read(repo_root).reviewed, true)
  eq(Verdict.pending(repo_root), nil)
end)

it("strip removes verified ranges bottom-up and skips moved content", function()
  local file = repo_root .. "/src/app.ts"
  write(file, "// Grab the value\n// and export it\nexport const a = 1;\nconsole.log(a);\nexport const b = 2;\n")
  local result = Strip.run(repo_root, fixture, { "src/app.ts" })
  eq(result.removed, 3)
  eq(result.moved, 0)
  eq(result.refused, {})
  eq(read(file), "export const a = 1;\nexport const b = 2;\n")

  -- Content moved: the debug line is no longer at line 4.
  write(file, "// Grab the value\n// and export it\nexport const a = 1;\nexport const z = 0;\nconsole.log(a);\n")
  local again = Strip.run(repo_root, fixture, { "src/app.ts" })
  eq(again.removed, 2)
  eq(again.moved, 1)
  eq(read(file), "export const a = 1;\nexport const z = 0;\nconsole.log(a);\n")
end)

it("strip never deletes the same line twice when candidates overlap", function()
  local file = repo_root .. "/src/app.ts"
  write(file, "// eslint-disable-next-line\nexport const a = 1;\n")
  local v = vim.deepcopy(fixture)
  v.debris = {
    { file = "src/app.ts", line = 1, end_line = 1, kind = "comment", lines = { "// eslint-disable-next-line" }, p = 0.9 },
    { file = "src/app.ts", line = 1, end_line = 1, kind = "suppression", lines = { "// eslint-disable-next-line" }, p = 0.9 },
  }
  local result = Strip.run(repo_root, v, { "src/app.ts" })
  eq(result.removed, 1)
  eq(result.moved, 1)
  eq(read(file), "export const a = 1;\n")
end)

it("render shows the top guess with a question mark when the kind is unsure", function()
  local v = vim.deepcopy(fixture)
  v.files[1].kind = "unsure"
  v.files[1].kind_top = "out_of_scope"
  has(Verdict.render(v)[3], "out of scope?")
end)

it("strip refuses when the buffer has unsaved changes", function()
  local file = repo_root .. "/src/app.ts"
  write(file, "// Grab the value\n// and export it\nexport const a = 1;\nconsole.log(a);\n")
  vim.cmd.edit(file)
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// typed but unsaved" })
  truthy(vim.bo.modified)
  local result = Strip.run(repo_root, fixture, { "src/app.ts" })
  eq(result.removed, 0)
  eq(#result.refused, 1)
  has(result.refused[1], "unsaved changes")
  vim.cmd("bwipeout!")
end)

it("popup shows the verdict in a float with the rendered lines and keys", function()
  local win, buf = Popup.show(repo_root, fixture)
  truthy(vim.api.nvim_win_is_valid(win))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  has(lines[1], "jev-lens")
  eq(vim.bo[buf].filetype, "jev-lens")
  eq(vim.api.nvim_win_get_cursor(win)[1], 3, "cursor lands on the first file row")
  local maps = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    maps[m.lhs] = true
  end
  for _, k in ipairs({ "l", "s", "r", "j", "R", "q" }) do
    truthy(maps[k], "keymap " .. k)
  end
  Popup.close()
  truthy(not Popup.is_open())
end)

it("Actions.judge passes --force only when asked", function()
  local log = repo_root .. "/judge-args"
  local script = repo_root .. "/fake-judge.sh"
  write(script, '#!/bin/sh\necho "$@" >> "' .. log .. '"\n')
  vim.fn.setfperm(script, "rwxr-xr-x")
  local Config = require("jev-lens.config")
  local prev = Config.options.judge_cmd
  Config.options.judge_cmd = { "/bin/sh", script }

  local Actions = require("jev-lens.actions")
  local done = false
  Actions.judge(repo_root, function()
    done = true
  end)
  vim.wait(3000, function()
    return done
  end)
  done = false
  Actions.judge(repo_root, function()
    done = true
  end, { force = true })
  vim.wait(3000, function()
    return done
  end)
  Config.options.judge_cmd = prev

  local args = vim.split(vim.trim(read(log)), "\n")
  eq(#args, 2)
  lacks(args[1], "--force")
  has(args[2], "--force")
end)

it("R goes through the module judge, which forgets the id so the popup returns", function()
  local lens = require("jev-lens")
  local prev = lens.judge
  local called = false
  lens.judge = function()
    called = true
    return true
  end
  Popup.show(repo_root, fixture)
  vim.api.nvim_feedkeys("R", "x", false)
  lens.judge = prev
  truthy(called, "R should call jev-lens.judge, not Actions.judge directly")
  truthy(not Popup.is_open(), "R closes the popup before re-judging")
end)

it("watcher opens the popup once when a new verdict lands, not for green", function()
  put_state({ version = 1, root = repo_root, baseline = "aaaa" })
  pcall(os.remove, Repo.verdict_path(repo_root))
  local shown = {}
  Watch.start(repo_root, function(_, v)
    shown[#shown + 1] = v.id
  end)
  local v = vim.deepcopy(fixture)
  v.id = "feedfacefeedface"
  put_verdict(v)
  vim.wait(2000, function()
    return #shown == 1
  end, 20)
  eq(shown, { "feedfacefeedface" })
  -- Rewriting the same verdict does not show it again.
  put_verdict(v)
  vim.wait(300, function()
    return #shown == 2
  end, 20)
  eq(#shown, 1)
  -- A different id does.
  v.id = "cafebabecafebabe"
  put_verdict(v)
  vim.wait(2000, function()
    return #shown == 2
  end, 20)
  eq(#shown, 2)
  Watch.stop()
end)

it("render shows routine? for an unsure routine guess", function()
  local v = vim.deepcopy(fixture)
  v.files[3].kind = "unsure"
  v.files[3].kind_top = "routine"
  has(Verdict.render(v)[5], "routine?")
end)

it("route: uneasy overall with no flagged file is a notify line, not a popup", function()
  local lens = require("jev-lens")
  notices = {}
  local v = vim.deepcopy(fixture)
  v.look = { p_ok = 0.43, verdict = "look" }
  for _, f in ipairs(v.files) do
    f.flagged = false
  end
  eq(lens.route(repo_root, v), "notify")
  eq(#notices, 1)
  has(notices[1].msg, "uneasy at 0.57, no file stands out")
  eq(notices[1].level, vim.log.levels.WARN)
  truthy(not Popup.is_open())
  eq(lens.route(repo_root, fixture), "popup")
  truthy(Popup.is_open())
  Popup.close()
end)

it("header caps to unsure when no file is flagged, even if the overall says look", function()
  local v = vim.deepcopy(fixture)
  v.look = { p_ok = 0.4, verdict = "look" }
  for _, f in ipairs(v.files) do
    f.flagged = false
  end
  has(Verdict.render(v)[1], "look: unsure  0.60 · no file stands out")
  lacks(Verdict.render(v)[1], "look: yes")
end)

it("route: judge-side notify_only (tiny) is a notify line", function()
  local lens = require("jev-lens")
  notices = {}
  local v = vim.deepcopy(fixture)
  v.notify_only = "tiny"
  v.summary.added, v.summary.removed = 1, 1
  eq(lens.route(repo_root, v), "notify")
  has(notices[1].msg, "tiny change (+1 -1)")
  truthy(not Popup.is_open())
end)

it("route: green overall wins even with a flagged file", function()
  local lens = require("jev-lens")
  notices = {}
  local v = vim.deepcopy(fixture)
  v.look = { p_ok = 0.95, verdict = "ok" }
  eq(lens.route(repo_root, v), "notify")
  has(notices[1].msg, "nothing needs you")
end)

it("route: flagged files that are all cosmetic do not open a popup", function()
  local lens = require("jev-lens")
  notices = {}
  local v = vim.deepcopy(fixture)
  for _, f in ipairs(v.files) do
    if f.flagged then
      f.kind = "cosmetic"
    end
  end
  eq(lens.route(repo_root, v), "notify")
  has(notices[1].msg, "cosmetic only")
end)

it("route: a dismissed verdict's files do not pop again until a new file joins", function()
  local lens = require("jev-lens")
  lens.forget_dismissed(repo_root)
  eq(lens.route(repo_root, fixture), "popup")
  Popup.close()
  lens.dismissed(repo_root, fixture)
  notices = {}
  local again = vim.deepcopy(fixture)
  again.id = "1111111111111111"
  eq(lens.route(repo_root, again), "notify")
  has(notices[1].msg, "same files as the dismissed verdict")
  local more = vim.deepcopy(fixture)
  more.id = "2222222222222222"
  table.insert(more.files, { path = "src/new.ts", status = "A", added = 5, removed = 0, attention = 0.9, flagged = true, kind = "behavior_change", kind_confidence = 0.9, prompt_index = vim.NIL, prompt_confidence = vim.NIL, debris = {} })
  eq(lens.route(repo_root, more), "popup")
  Popup.close()
  lens.forget_dismissed(repo_root)
  eq(lens.route(repo_root, again), "popup")
  Popup.close()
end)

it("route: the verdict after a strip updates quietly, the one after that pops", function()
  local lens = require("jev-lens")
  lens.forget_dismissed(repo_root)
  lens.quiet_next(repo_root)
  notices = {}
  eq(lens.route(repo_root, fixture), "notify")
  has(notices[1].msg, "after strip")
  eq(lens.route(repo_root, fixture), "popup")
  Popup.close()
end)

it("route: in insert mode the popup waits for InsertLeave", function()
  local lens = require("jev-lens")
  lens.forget_dismissed(repo_root)
  local saved = vim.fn.mode
  vim.fn.mode = function()
    return "i"
  end
  eq(lens.route(repo_root, fixture), "deferred")
  truthy(not Popup.is_open())
  vim.fn.mode = saved
  vim.api.nvim_exec_autocmds("InsertLeave", {})
  truthy(Popup.is_open(), "popup opened once insert mode ended")
  Popup.close()
end)

it("q records a dismissal; r clears it", function()
  local lens = require("jev-lens")
  lens.forget_dismissed(repo_root)
  put_state({ version = 1, root = repo_root, baseline = "aaaa", prompts = {} })
  put_verdict(fixture)
  local v = Verdict.read(repo_root)
  Popup.show(repo_root, v)
  vim.api.nvim_feedkeys("q", "x", false)
  truthy(not Popup.is_open())
  notices = {}
  local again = vim.deepcopy(v)
  again.id = "3333333333333333"
  eq(lens.route(repo_root, again), "notify", "dismissed set remembered after q")
  Popup.show(repo_root, v)
  vim.api.nvim_feedkeys("r", "x", false)
  truthy(not Popup.is_open())
  local fresh = vim.deepcopy(fixture)
  fresh.id = "4444444444444444"
  eq(lens.route(repo_root, fresh), "popup", "reviewed cleared the dismissal memory")
  Popup.close()
end)

it("setup routes green to notify and attention to the popup", function()
  put_state({ version = 1, root = repo_root, baseline = "aaaa" })
  pcall(os.remove, Repo.verdict_path(repo_root))
  -- Drive the real router through the watcher.
  local lens = require("jev-lens")
  local Config = require("jev-lens.config")
  Config.options.on_startup = false
  Watch.start(repo_root, lens.route)
  notices = {}
  local green = vim.deepcopy(fixture)
  green.id = "0000000000000001"
  green.look = { p_ok = 0.96, verdict = "ok" }
  put_verdict(green)
  vim.wait(2000, function()
    return #notices == 1
  end, 20)
  eq(#notices, 1)
  has(notices[1].msg, "nothing needs you")
  truthy(not Popup.is_open())

  local red = vim.deepcopy(fixture)
  red.id = "0000000000000002"
  put_verdict(red)
  vim.wait(2000, function()
    return Popup.is_open()
  end, 20)
  truthy(Popup.is_open())
  Popup.close()
  Watch.stop()
  truthy(type(lens.pending) == "function")
end)

io.stdout:write(("\n%d passed, %d failed\n"):format(passed, #failures))
for _, f in ipairs(failures) do
  io.stdout:write("\n" .. f .. "\n")
end
os.exit(#failures == 0 and 0 or 1)
