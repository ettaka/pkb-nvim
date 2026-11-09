-- pkb.export: a fresh git repo with a subselection of the PKB, defined by an export page in the PKB.
local H = require("tests.helpers")
local t = H.suite()
local notifier = require("tests.pkb").notifier

local function read(path) return vim.fn.readfile(path) end

--- A small PKB. Links from projects/a.md:
---   [[b]] (b links [[c]]), [[secret|the plan]] (#private), [[bob]] (people/), [[2026-10-02]] (in range),
---   [[2026-12-24]] (out of range), ![[diagram.png]], [spec](docs/spec.pdf), [[nowhere]] (no such page),
---   a reference to task t-2026-01-01T10:00 (defined in tasks/t.md), [[exports/review]] (the export page).
local function make_pkb(def)
  local root = H.tmpdir()
  H.write(root .. "/projects/a.md", {
    "# A",
    "See [[b]] and [[secret|the plan]], ask [[bob]].",
    "Log: [[2026-10-02]], later [[2026-12-24]].",
    "![[diagram.png]] and [spec](docs/spec.pdf) and [[nowhere]] and https://example.com/x.",
    "Follow-up of t-2026-01-01T10:00, see [[exports/review]].",
    "- [ ] own task due::2026-11-10T08:00Z task::t-2026-02-02T10:00",
  })
  H.write(root .. "/b.md", { "# B", "Next: [[c#Details]]" })
  H.write(root .. "/c.md", { "# C", "## Details", "end" })
  H.write(root .. "/d.md", { "# D", "## Some heading", "Links [[c]]" })
  H.write(root .. "/secret.md", { "# Secret #private", "hunter2" })
  H.write(root .. "/people/bob.md", { "# Bob" })
  H.write(root .. "/2026-10-02.md", { "# 2026-10-02", "- worked on [[projects/a]]" })
  H.write(root .. "/2026-12-24.md", { "# 2026-12-24" })
  H.write(root .. "/tasks/t.md", { "- [ ] x due::2026-11-10T08:00Z task::t-2026-01-01T10:00" })
  H.write(root .. "/other.md", { "# Unrelated" })
  H.write(root .. "/img/diagram.png", { "PNG" })
  H.write(root .. "/projects/docs/spec.pdf", { "PDF" })
  local out = root .. "-out"
  H.defer(function() vim.fn.delete(out, "rf") end)
  local lines = def or {
    "# Review",
    "export::review",
    "",
    "## Seeds",
    "- [[projects/a]]",
    "- [[d#Some heading]] depth::0",
    "",
    "## Settings",
    "depth::1",
    "dates::2026-09-01..2026-11-30",
    "out::" .. out,
    "",
    "## Never",
    "- people/",
    "- #private",
    "",
    "## Forbidden words",
    "- hunter2",
  }
  local def_file = H.write(root .. "/exports/review.md", lines)
  notifier(root)
  return root, def_file, out
end

local function plan_for(def_file)
  return require("pkb.export").plan(def_file, read(def_file))
end

local function rels(list)
  local out = vim.tbl_map(function(e) return e.rel end, list)
  table.sort(out)
  return out
end

---------------------------------------------------------------- reading the export page
t.test("export page: name, seeds with their own depth, settings, never, forbidden words", function()
  local _, def_file, out = make_pkb()
  local def = require("pkb.export").parse(read(def_file))
  H.eq(def.name, "review")
  H.eq(def.seeds, { { link = "projects/a" }, { link = "d#Some heading", depth = 0 } })
  H.eq({ def.depth, def.dates, def.out }, { 1, { from = "2026-09-01", to = "2026-11-30" }, out })
  H.eq(def.never, { "people/", "#private" })
  H.eq(def.forbidden, { "hunter2" })
end)

t.test("export page: headings are case-insensitive, missing sections use defaults", function()
  local def = require("pkb.export").parse({ "export::x", "## SEEDS", "- [[a]] depth::3", "- not a link" })
  H.eq(def.seeds, { { link = "a", depth = 3 } })
  H.eq({ def.depth, def.dates, def.out, def.never, def.forbidden }, { 1, nil, nil, {}, {} })
end)

t.test("export page: open-ended date ranges", function()
  local P = require("pkb.export")
  H.eq(P.parse({ "export::x", "## Settings", "dates::2026-09-01.." }).dates, { from = "2026-09-01" })
  H.eq(P.parse({ "export::x", "## Settings", "dates::..2026-11-30" }).dates, { to = "2026-11-30" })
end)

t.test("a page without export:: is not an export page", function()
  H.eq(require("pkb.export").parse({ "# notes", "## Seeds", "- [[a]]" }), nil)
end)

---------------------------------------------------------------- selection
t.test("selection: seeds, links up to the depth, task references, dates, never; heading links take the whole page", function()
  local _, def_file = make_pkb()
  local plan = plan_for(def_file)
  H.eq(rels(plan.pages), { "2026-10-02.md", "b.md", "d.md", "projects/a.md", "tasks/t.md" })
  H.eq(rels(plan.files), { "img/diagram.png", "projects/docs/spec.pdf" })
  local why = {}
  for _, p in ipairs(plan.pages) do why[p.rel] = p.why end
  H.eq(why["projects/a.md"], "seed")
  H.eq(why["b.md"], "projects/a.md")
  H.eq(why["tasks/t.md"], "projects/a.md")
end)

t.test("selection: skipped pages say why", function()
  local _, def_file = make_pkb()
  local plan = plan_for(def_file)
  local skipped = {}
  for _, s in ipairs(plan.skipped) do skipped[s.rel] = s.reason end
  H.eq(skipped, {
    ["secret.md"] = "never (#private)",
    ["people/bob.md"] = "never (people/)",
    ["2026-12-24.md"] = "outside dates",
    ["c.md"] = "beyond depth",
    ["exports/review.md"] = "export page",
  })
  H.eq(plan.missing, { { link = "nowhere", from = "projects/a.md" } })
end)

t.test("selection: a seed's own depth:: overrides the default", function()
  local root, def_file = make_pkb()
  local lines = read(def_file)
  lines[5] = "- [[projects/a]] depth::2"
  H.write(def_file, lines)
  H.ok(vim.tbl_contains(rels(plan_for(def_file).pages), "c.md"), "c is two links from a")
  H.ok(root)
end)

t.test("selection: depth::0 seed exports only the seed", function()
  local _, def_file = make_pkb({ "export::x", "## Seeds", "- [[projects/a]] depth::0" })
  H.eq(rels(plan_for(def_file).pages), { "projects/a.md" })
end)

t.test("selection: a seed that does not exist is an error", function()
  local _, def_file = make_pkb({ "export::x", "## Seeds", "- [[ghost]]" })
  local plan = plan_for(def_file)
  H.eq(plan.pages, {})
  H.has(plan.errors[1], "ghost")
end)

---------------------------------------------------------------- content of the copy
t.test("copy: links to pages outside the export become plain text; others and all tags stay", function()
  local _, def_file = make_pkb()
  local plan = plan_for(def_file)
  local a = plan.content["projects/a.md"]
  H.eq(a, {
    "# A",
    "See [[b]] and the plan, ask bob.",
    "Log: [[2026-10-02]], later 2026-12-24.",
    "![[diagram.png]] and [spec](docs/spec.pdf) and nowhere and https://example.com/x.",
    "Follow-up of t-2026-01-01T10:00, see exports/review.",
    "- [ ] own task due::2026-11-10T08:00Z task::t-2026-02-02T10:00",
  })
  H.eq(plan.content["b.md"], { "# B", "Next: c#Details" })
  H.eq(#plan.unlinked, 7)
end)

t.test("copy: forbidden words in the copy are reported (case-insensitive) and block writing", function()
  local _, def_file, out = make_pkb()
  H.write(vim.fs.dirname(def_file) .. "/../b.md", { "# B", "password: HUNTER2" })
  local E = require("pkb.export")
  local plan = plan_for(def_file)
  H.eq(plan.forbidden, { { rel = "b.md", line = 2, word = "hunter2" } })
  local ok, err = E.write(plan)
  H.eq(ok, false)
  H.has(err, "forbidden")
  H.eq(vim.fn.isdirectory(out), 0, "nothing written")
end)

t.test("copy: a forbidden word in the export name is reported too (it goes into the commit message)", function()
  local _, def_file = make_pkb({ "export::hunter2-review", "## Seeds", "- [[other]]", "## Forbidden words", "- hunter2" })
  H.eq(plan_for(def_file).forbidden, { { rel = "export::hunter2-review", line = 0, word = "hunter2" } })
end)

---------------------------------------------------------------- writing
local function git(dir, ...)
  return vim.trim(vim.system({ "git", "-C", dir, ... }, { text = true }):wait().stdout)
end

local function with_identity()
  for k, v in pairs({ GIT_AUTHOR_NAME = "Owner", GIT_AUTHOR_EMAIL = "owner@example.com",
                      GIT_COMMITTER_NAME = "Owner", GIT_COMMITTER_EMAIL = "owner@example.com" }) do
    local old = vim.env[k]
    vim.env[k] = v
    H.defer(function() vim.env[k] = old end)
  end
end

t.test("write: a fresh repo with one commit holding exactly the selected files", function()
  with_identity()
  local _, def_file, out = make_pkb()
  local E = require("pkb.export")
  local ok, msg = E.write(plan_for(def_file))
  H.eq(ok, true, msg)
  H.eq(git(out, "rev-list", "--count", "HEAD"), "1")
  H.eq(vim.split(git(out, "ls-files"), "\n"), {
    ".pkb-export", "2026-10-02.md", "b.md", "d.md", "img/diagram.png", "projects/a.md",
    "projects/docs/spec.pdf", "tasks/t.md",
  })
  H.eq(read(out .. "/b.md"), { "# B", "Next: c#Details" })
  H.eq(git(out, "log", "-1", "--format=%an <%ae>"), "Owner <owner@example.com>")
  H.eq(git(out, "remote"), "")
end)

t.test("write: running again rebuilds from scratch (no stale pages, still one commit)", function()
  with_identity()
  local _, def_file, out = make_pkb()
  local E = require("pkb.export")
  assert(E.write(plan_for(def_file)))
  local lines = read(def_file)
  lines[5] = "- [[other]] depth::0"
  lines[6] = ""
  H.write(def_file, lines)
  local ok, msg = E.write(plan_for(def_file))
  H.eq(ok, true, msg)
  H.eq(vim.split(git(out, "ls-files"), "\n"), { ".pkb-export", "other.md" })
  H.eq(git(out, "rev-list", "--count", "HEAD"), "1")
end)

t.test("write: refuses an existing folder that is not an earlier export", function()
  with_identity()
  local _, def_file, out = make_pkb()
  H.write(out .. "/important.txt", { "keep me" })
  local ok, err = require("pkb.export").write(plan_for(def_file))
  H.eq(ok, false)
  H.has(err, "not an earlier export")
  H.eq(read(out .. "/important.txt"), { "keep me" })
end)

t.test("write: out defaults to ~/pkb-export/<name>", function()
  local _, def_file = make_pkb({ "export::my review", "## Seeds", "- [[other]]" })
  H.eq(plan_for(def_file).out, vim.fn.expand("~/pkb-export/my-review"))
end)

---------------------------------------------------------------- :PKBExport
t.test(":PKBExport on a page without export:: warns", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/note.md", { "# just a note" })
  notifier(root)
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  vim.cmd.edit(f)
  vim.cmd("PKBExport")
  H.has(H.messages[#H.messages], "export::")
end)

t.test(":PKBExport shows a report; w writes the repo, q cancels", function()
  with_identity()
  local _, def_file, out = make_pkb()
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  vim.cmd.edit(def_file)
  vim.cmd("PKBExport")
  local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  H.has(report, "EXPORT review: 5 pages, 2 files")
  H.has(report, "projects/a.md")
  H.has(report, "secret.md  never (#private)")
  H.has(report, "the plan")
  H.has(report, "Forbidden words: none")
  H.eq(vim.fn.isdirectory(out), 0, "nothing written before w")
  vim.fn.maparg("w", "n", false, true).callback()
  H.eq(git(out, "rev-list", "--count", "HEAD"), "1")
end)

return t
