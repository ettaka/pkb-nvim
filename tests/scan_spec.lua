-- pkb.parser.scan_dir: what counts as a task when the PKB folder is scanned.
local H = require("tests.helpers")
local t = H.suite()
local P = require("pkb.parser")

local function scan(root, existing)
  local out = {}
  P.scan_dir(existing or {}, root, out)
  return out
end

local function by_line(state)
  local r = {}
  for _, e in pairs(state) do r[e.line] = e end
  return r
end

t.test("finds due:: tasks, keyed by file:line, with notify_ts = due - default 15min", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/tasks.md", { "# tasks", "- [ ] a due::2026-11-10T08:00Z" })
  local e = scan(root)[f .. ":2"]
  H.ok(e, "entry not found")
  H.eq(e.due_ts, 1794297600)
  H.eq(e.notify_ts, 1794297600 - 900)
  H.eq({ e.file, e.line_num, e.triggered, e.dismissed }, { f, 2, false, false })
end)

t.test("explicit notify:: overrides the default", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z notify::2h" })
  local e = by_line(scan(root))["- [ ] a due::2026-11-10T08:00Z notify::2h"]
  H.eq(e.due_ts - e.notify_ts, 7200)
end)

t.test("recurses into subdirectories and ignores non-markdown files", function()
  local root = H.tmpdir()
  H.write(root .. "/a/b/deep.md", { "- [ ] deep due::2026-11-10T08:00Z" })
  H.write(root .. "/notes.txt", { "- [ ] txt due::2026-11-10T08:00Z" })
  local lines = vim.tbl_keys(by_line(scan(root)))
  H.eq(lines, { "- [ ] deep due::2026-11-10T08:00Z" })
end)

t.test("skips lines inside fenced code blocks", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", {
    "```", "- [ ] in code due::2026-11-10T08:00Z", "```",
    "  ```lua", "- [ ] indented fence due::2026-11-10T08:00Z", "  ```",
    "- [ ] real due::2026-11-10T08:00Z",
  })
  H.eq(vim.tbl_keys(by_line(scan(root))), { "- [ ] real due::2026-11-10T08:00Z" })
end)

t.test("skips template/documentation lines", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", {
    "- [ ] example due::YYYY-MM-DDTHH:MM[Z/H]",
    "- [ ] other due::[date]",
    "- [ ] doc due::2026-11-10T08:00[Z/H]",
  })
  H.eq(vim.tbl_count(scan(root)), 0)
end)

t.test("tags with trailing punctuation still parse", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] x (due::2026-11-10T08:00Z)." })
  local e = by_line(scan(root))["- [ ] x (due::2026-11-10T08:00Z)."]
  H.eq(e.due_ts, 1794297600)
end)

t.test("invalid date warns with file and line, and parks the task far in the future", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "", "- [ ] bad due::2026-02-30T08:00Z" })
  local e = by_line(scan(root))["- [ ] bad due::2026-02-30T08:00Z"]
  H.ok(e.due_ts > os.time() + 365 * 86400, "not parked in the future")
  H.has(H.messages[1], "Invalid date")
  H.has(H.messages[1], "Line 2")
end)

t.test("checked tasks are still scanned (filtered later by consumers)", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [x] done due::2026-11-10T08:00Z" })
  H.eq(vim.tbl_count(scan(root)), 1)
end)

t.test("rescan keeps triggered/dismissed/snooze state for the same file:line", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  local first = scan(root)
  first[f .. ":1"].dismissed = true
  first[f .. ":1"].triggered = true
  first[f .. ":1"].auto_snoozed_until = 42
  local second = scan(root, first)[f .. ":1"]
  H.eq({ second.dismissed, second.triggered, second.auto_snoozed_until }, { true, true, 42 })
end)

t.test("missing directory scans to nothing", function()
  H.eq(scan(H.tmpdir() .. "/does-not-exist"), {})
end)

return t
