-- Incremental rescans: saving one note rescans only that note (known issue 13).
local H = require("tests.helpers")
local t = H.suite()
local pkb = require("tests.pkb")
local notifier, find = pkb.notifier, pkb.find

local function has(n, needle)
  for _, e in pairs(n.notifications) do
    if e.line:find(needle, 1, true) then return true end
  end
  return false
end

--- PKB with two notes, scanned once.
local function two_notes()
  local root = H.tmpdir()
  local a = H.write(root .. "/a.md", { "- [ ] a1 due::2026-11-10T08:00Z" })
  local b = H.write(root .. "/sub/b.md", { "- [ ] b1 due::2026-11-10T09:00Z" })
  local n = notifier(root)
  n.notify()
  return n, root, a, b
end

t.test("rescan_files picks up changes in the given note", function()
  local n, _, a = two_notes()
  H.write(a, { "- [ ] a2 due::2026-11-11T08:00Z" })
  n.rescan_files({ a })
  H.ok(has(n, "a2"), "new task missing")
  H.ok(not has(n, "a1"), "removed task still there")
  H.ok(has(n, "b1"), "other note's task lost")
end)

t.test("rescan_files does not read other notes", function()
  local n, _, a, b = two_notes()
  H.write(b, { "- [ ] b2 due::2026-11-12T08:00Z" }) -- changed on disk, but not rescanned
  H.write(a, { "- [ ] a1 due::2026-11-10T08:00Z", "- [ ] a2 due::2026-11-11T08:00Z" })
  n.rescan_files({ a })
  H.ok(has(n, "a2"))
  H.ok(has(n, "b1") and not has(n, "b2"), "b.md was rescanned")
end)

t.test("rescan_files keeps state of the note's tasks when lines shift", function()
  local n, _, a = two_notes()
  find(n, "a1").dismissed = true
  H.write(a, { "# heading", "- [ ] a1 due::2026-11-10T08:00Z" })
  n.rescan_files({ a })
  local e = find(n, "a1")
  H.eq({ e.line_num, e.dismissed }, { 2, true })
end)

t.test("rescan_files on a deleted note removes its tasks", function()
  local n, _, a = two_notes()
  vim.fn.delete(a)
  n.rescan_files({ a })
  H.ok(not has(n, "a1"))
  H.ok(has(n, "b1"))
end)

t.test("rescan_files ignores notes outside the PKB and non-markdown files", function()
  local n, root = two_notes()
  local outside = H.write(H.tmpdir() .. "/x.md", { "- [ ] outside due::2026-11-10T08:00Z" })
  local txt = H.write(root .. "/c.txt", { "- [ ] txt due::2026-11-10T08:00Z" })
  n.rescan_files({ outside, txt })
  H.ok(not has(n, "outside") and not has(n, "txt"))
  H.eq(vim.tbl_count(n.notifications), 2)
end)

t.test("rescan_files keys entries like a full scan, also for paths given differently", function()
  local n, root, a = two_notes()
  H.write(a, { "- [ ] a1 due::2026-11-10T08:00Z", "- [ ] a2 due::2026-11-11T08:00Z" })
  n.rescan_files({ root .. "/./sub/../a.md" })
  local ids = vim.tbl_keys(n.notifications)
  table.sort(ids)
  H.eq(ids, { root .. "/a.md:1", root .. "/a.md:2", root .. "/sub/b.md:1" })
end)

t.test("a task with an id moved between notes keeps its state across two saves", function()
  local n, _, a, b = two_notes()
  H.write(a, { "- [ ] call bank due::2026-11-10T08:00Z task::t-2026-01-01T10:00" })
  n.rescan_files({ a })
  find(n, "call bank").dismissed = true
  H.write(a, {})
  n.rescan_files({ a }) -- cut and save
  H.write(b, { "- [ ] b1 due::2026-11-10T09:00Z", "- [ ] call bank due::2026-11-10T08:00Z task::t-2026-01-01T10:00" })
  n.rescan_files({ b }) -- paste and save
  H.eq(find(n, "call bank").dismissed, true)
end)

t.test("queue_rescan batches saves of different notes", function()
  local n, _, a, b = two_notes()
  H.write(a, { "- [ ] a2 due::2026-11-11T08:00Z" })
  H.write(b, { "- [ ] b2 due::2026-11-12T08:00Z" })
  n.queue_rescan(a, 50)
  n.queue_rescan(b, 50)
  H.ok(has(n, "a1") and has(n, "b1"), "rescanned before the delay")
  H.ok(vim.wait(1000, function() return has(n, "a2") and has(n, "b2") end), "both notes should be rescanned")
end)

t.test("complete_task rescans only the notes it changed", function()
  local n, _, a, b = two_notes()
  H.write(b, { "- [ ] b2 due::2026-11-12T08:00Z" }) -- unrelated change on disk
  n.complete_task(find(n, "a1"))
  H.ok(not has(n, "a1 due::"), "completed task still listed")
  H.ok(has(n, "b1") and not has(n, "b2"), "b.md was rescanned")
end)

t.test("skip_task rescans the note and shows the new due date", function()
  local n = two_notes()
  n.skip_task(find(n, "a1"))
  local e = find(n, "a1")
  H.eq(e.due_ts, 1794297600 + 86400)
end)

return t
