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

-- Settings are written by hand: spaces after :: or around the range, and a dash between dates, all work.
local date_forms = {
  "dates::2026-09-01..2026-11-30",
  "dates:: 2026-09-01..2026-11-30",
  "dates::2026-09-01 .. 2026-11-30",
  "dates:: 2026-09-01 – 2026-11-30",
  "dates::2026-09-01—2026-11-30",
  "- dates:: 2026-09-01..2026-11-30",
}
for _, line in ipairs(date_forms) do
  t.test("export page: " .. line, function()
    local def = require("pkb.export").parse({ "export::x", "## Settings", line })
    H.eq(def.dates, { from = "2026-09-01", to = "2026-11-30" })
    H.eq(def.problems, {})
  end)
end

t.test("export page: spaces after :: in depth and out, and in a seed's depth", function()
  local def = require("pkb.export").parse({ "export::x", "## Seeds", "- [[a]] depth:: 3", "## Settings", "depth:: 2",
                                            "out:: ~/exports/my review" })
  H.eq({ def.depth, def.out, def.seeds }, { 2, "~/exports/my review", { { link = "a", depth = 3 } } })
end)

t.test("export page: a setting that cannot be read is an error, not silently ignored", function()
  local _, def_file = make_pkb({ "export::x", "## Seeds", "- [[other]]", "## Settings", "dates::last autumn",
                                 "depth::deep", "colour::blue" })
  local plan = plan_for(def_file)
  H.eq(plan.errors, {
    "Settings: dates::last autumn not understood (use dates::2026-09-01..2026-11-30, open ends work)",
    "Settings: depth::deep not understood (a number)",
    "Settings: unknown setting colour:: (known: depth, dates, out)",
  })
end)

t.test("export page: the report shows the settings in use", function()
  local _, def_file = make_pkb()
  local report = require("pkb.export").report_lines(plan_for(def_file))
  H.eq(report[2], "depth 1, dates 2026-09-01..2026-11-30")
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

t.test("export page: dates:: under Seeds is a date seed, with its own depth; a bad range is an error", function()
  local def = require("pkb.export").parse({ "export::x", "## Seeds", "- dates::2026-09-01..2026-11-30",
    "- dates:: 2026-12-01 – 2026-12-31 depth::0", "- [[a]]", "- dates::someday" })
  H.eq(def.seeds, {
    { dates = { from = "2026-09-01", to = "2026-11-30" } },
    { dates = { from = "2026-12-01", to = "2026-12-31" }, depth = 0 },
    { link = "a" },
  })
  H.eq(def.dates, nil, "a date seed is not the Settings filter")
  H.eq(def.problems, { "Seeds: dates::someday not understood (use dates::2026-09-01..2026-11-30, open ends work)" })
end)

t.test("selection: a date seed exports the daily notes in its range and what they link to", function()
  local _, def_file = make_pkb({ "export::x", "## Seeds", "- dates::2026-09-01..2026-11-30" })
  local plan = plan_for(def_file)
  H.eq(plan.errors, {})
  H.eq(vim.tbl_map(function(p) return p.rel .. " " .. p.why end, plan.pages),
    { "2026-10-02.md dates::2026-09-01..2026-11-30", "projects/a.md 2026-10-02.md" })
end)

t.test("selection: date seeds and link seeds together; a date seed's depth; Never still applies", function()
  local root, def_file = make_pkb({ "export::x", "## Seeds", "- [[other]]", "- dates::2026-10-01..2026-10-31 depth::0",
                                    "## Never", "- #private" })
  H.write(root .. "/2026-10-05.md", { "# 2026-10-05 #private" })
  local plan = plan_for(def_file)
  H.eq(rels(plan.pages), { "2026-10-02.md", "other.md" })
  H.eq(vim.tbl_map(function(s) return s.rel .. " " .. s.reason end, plan.skipped),
    { "2026-10-05.md never (#private)", "projects/a.md beyond depth" })
end)

t.test("selection: an open-ended date seed selects from that day on", function()
  local _, def_file = make_pkb({ "export::x", "## Seeds", "- dates::2026-12-01.. depth::0" })
  H.eq(rels(plan_for(def_file).pages), { "2026-12-24.md" })
end)

t.test("selection: dates:: under Settings only filters, it selects nothing by itself", function()
  local _, def_file = make_pkb({ "export::x", "## Settings", "dates::2026-09-01..2026-11-30" })
  local plan = plan_for(def_file)
  H.eq(plan.pages, {})
  H.eq(plan.errors, { "nothing to export: add seeds under ## Seeds ([[page]] or dates::from..to)" })
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

local function with_identity()
  for k, v in pairs({ GIT_AUTHOR_NAME = "Owner", GIT_AUTHOR_EMAIL = "owner@example.com",
                      GIT_COMMITTER_NAME = "Owner", GIT_COMMITTER_EMAIL = "owner@example.com" }) do
    local old = vim.env[k]
    vim.env[k] = v
    H.defer(function() vim.env[k] = old end)
  end
end

---------------------------------------------------------------- file links: root-relative, absolute, outside the PKB
local function file_links_pkb(extra_never)
  local root, ext = H.tmpdir(), H.tmpdir()
  H.write(root .. "/papers/qc.pdf", { "QC" })
  H.write(root .. "/notes/local.pdf", { "LOCAL" })
  H.write(ext .. "/docs/report final.pdf", { "REPORT" })
  H.write(ext .. "/other/report final.pdf", { "OTHER REPORT" })
  H.write(ext .. "/private/salary.pdf", { "SALARY" })
  H.write(root .. "/notes/a.md", {
    "root-relative [qc](/papers/qc.pdf)",
    "absolute inside [qc2](" .. root .. "/papers/qc.pdf \"a title\")",
    "absolute outside [r](" .. ext .. "/docs/report%20final.pdf)",
    "angle brackets ![r2](<" .. ext .. "/other/report final.pdf>)",
    "never [s](" .. ext .. "/private/salary.pdf)",
    "page-relative [l](local.pdf)",
    "wiki absolute [[" .. root .. "/papers/qc.pdf]]",
    "wiki never [[" .. ext .. "/private/salary.pdf]]",
    "wiki outside [[" .. ext .. "/docs/report final.pdf|the report]]",
  })
  local out = root .. "-out"
  H.defer(function() vim.fn.delete(out, "rf") end)
  local def_file = H.write(root .. "/x.md", { "export::x", "## Seeds", "- [[notes/a]]", "## Settings", "out::" .. out,
                                              "## Never", "- " .. ext .. "/private/", extra_never })
  notifier(root)
  return root, ext, def_file, out
end

t.test("file links: root-relative, absolute and outside-the-PKB files are followed and copied", function()
  local _, _, def_file = file_links_pkb()
  local plan = plan_for(def_file)
  H.eq(rels(plan.files), { "_external/report final-2.pdf", "_external/report final.pdf", "notes/local.pdf", "papers/qc.pdf" })
  H.eq(plan.missing, {})
end)

t.test("file links: absolute paths are rewritten relative to the page; no home path left in the copy", function()
  local root, ext, def_file = file_links_pkb()
  local a = plan_for(def_file).content["notes/a.md"]
  H.eq(a, {
    "root-relative [qc](/papers/qc.pdf)",
    "absolute inside [qc2](../papers/qc.pdf \"a title\")",
    "absolute outside [r](../_external/report%20final.pdf)",
    "angle brackets ![r2](<../_external/report final-2.pdf>)",
    "never s",
    "page-relative [l](local.pdf)",
    "wiki absolute [[papers/qc.pdf]]",
    "wiki never salary.pdf",
    "wiki outside [[_external/report final.pdf|the report]]",
  })
  local all = table.concat(a, "\n")
  H.ok(not all:find(root, 1, true) and not all:find(ext, 1, true), all)
end)

t.test("file links: Never takes absolute folders; the report shows where outside files come from", function()
  local _, ext, def_file = file_links_pkb()
  local plan = plan_for(def_file)
  H.eq(vim.tbl_map(function(s) return s.reason end, plan.skipped), { "never (" .. ext .. "/private/)" })
  local report = table.concat((require("pkb.export").report_lines(plan)), "\n")
  H.has(report, "_external/report final.pdf  ← notes/a.md  (" .. ext .. "/docs/report final.pdf)")
end)

t.test("file links: the written repo has the outside files", function()
  with_identity()
  local _, _, def_file, out = file_links_pkb()
  local ok, msg = require("pkb.export").write(plan_for(def_file))
  H.eq(ok, true, msg)
  H.eq(read(out .. "/_external/report final.pdf"), { "REPORT" })
  H.eq(read(out .. "/_external/report final-2.pdf"), { "OTHER REPORT" })
  H.eq(read(out .. "/papers/qc.pdf"), { "QC" })
end)

---------------------------------------------------------------- writing
local function git(dir, ...)
  return vim.trim(vim.system({ "git", "-C", dir, ... }, { text = true }):wait().stdout)
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

---------------------------------------------------------------- round trip: export, travel, import with git pull
-- The export is recorded in the full PKB's history (a merge that changes no files), so the import is a plain
-- `git pull` from the travel copy: git merges each file three ways (as exported / at home / after travel).
local function git_ok(dir, ...)
  local res = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  return res.code == 0, vim.trim((res.stdout or "") .. (res.stderr or ""))
end

local function git_pkb(def)
  with_identity()
  local root, def_file, out = make_pkb(def)
  -- b.md at home has a link that the export turns into text (line 2)
  H.write(root .. "/b.md", { "# B", "Next: [[c#Details]]", "", "## Notes", "- first" })
  git_ok(root, "init", "-q")
  git_ok(root, "add", "-A")
  git_ok(root, "commit", "-q", "-m", "full PKB")
  return root, def_file, out
end

local function travel(out)
  local dir = out .. "-travel"
  H.defer(function() vim.fn.delete(dir, "rf") end)
  assert(git_ok(vim.fs.dirname(out), "clone", "-q", out, dir))
  return dir
end

t.test("export records itself in the full PKB's history without changing any file", function()
  local root, def_file, out = git_pkb()
  local ok, msg = require("pkb.export").write(plan_for(def_file))
  H.eq(ok, true, msg)
  H.has(msg, "pull <copy>")
  H.eq(git(root, "rev-list", "--count", "HEAD"), "3", "full commit + export commit + recording merge")
  H.eq(git(root, "rev-parse", "HEAD^2"), git(out, "rev-parse", "HEAD"))
  H.eq(git(root, "diff", "--stat", "HEAD^1", "HEAD"), "", "no file changed")
  H.eq(git(root, "status", "--porcelain"), "")
end)

t.test("import: git pull brings travel changes home; untouched lines keep the full version and its links", function()
  local root, def_file, out = git_pkb()
  assert(require("pkb.export").write(plan_for(def_file)))
  local tr = travel(out)
  -- while travelling: add a line to b.md (its link line was exported as text), a new page, a new daily note
  H.write(tr .. "/b.md", { "# B", "Next: c#Details", "", "## Notes", "- first", "- added while travelling" })
  H.write(tr .. "/trip.md", { "# Trip", "see [[b]]" })
  git_ok(tr, "add", "-A")
  git_ok(tr, "commit", "-q", "-m", "travel notes")
  -- meanwhile at home: another page changes
  H.write(root .. "/other.md", { "# Unrelated", "changed at home" })
  git_ok(root, "commit", "-qam", "home change")

  local ok, out_msg = git_ok(root, "pull", "-q", "--no-rebase", "--no-edit", tr)
  H.eq(ok, true, out_msg)
  H.eq(read(root .. "/b.md"), { "# B", "Next: [[c#Details]]", "", "## Notes", "- first", "- added while travelling" },
    "link kept")
  H.eq(read(root .. "/trip.md"), { "# Trip", "see [[b]]" })
  H.eq(read(root .. "/other.md"), { "# Unrelated", "changed at home" })
  H.eq(read(root .. "/secret.md"), { "# Secret #private", "hunter2" }, "unexported pages untouched")
  H.eq(vim.fn.filereadable(root .. "/" .. require("pkb.export").MARKER), 0, "export marker not imported")
  H.eq(vim.fn.isdirectory(root .. "/_external"), 0)
end)

t.test("import: importing again from the same copy brings only the new notes", function()
  local root, def_file, out = git_pkb()
  assert(require("pkb.export").write(plan_for(def_file)))
  local tr = travel(out)
  H.write(tr .. "/trip.md", { "# Trip", "day 1" })
  git_ok(tr, "add", "-A")
  git_ok(tr, "commit", "-q", "-m", "day 1")
  assert(git_ok(root, "pull", "-q", "--no-rebase", "--no-edit", tr))
  H.write(root .. "/trip.md", { "# Trip", "day 1", "home: sorted the photos" })
  git_ok(root, "commit", "-qam", "home edit of an imported page")
  H.write(tr .. "/day2.md", { "# Day 2" })
  git_ok(tr, "add", "-A")
  git_ok(tr, "commit", "-q", "-m", "day 2")
  local ok, msg = git_ok(root, "pull", "-q", "--no-rebase", "--no-edit", tr)
  H.eq(ok, true, msg)
  H.eq(read(root .. "/day2.md"), { "# Day 2" })
  H.eq(read(root .. "/trip.md"), { "# Trip", "day 1", "home: sorted the photos" }, "home edit kept, day 1 not re-applied")
end)

t.test("import: a line edited while travelling that the export had changed is a git conflict", function()
  local root, def_file, out = git_pkb()
  assert(require("pkb.export").write(plan_for(def_file)))
  local tr = travel(out)
  H.write(tr .. "/b.md", { "# B", "Next: c#Details and more", "", "## Notes", "- first" })
  git_ok(tr, "commit", "-qam", "edit the unlinked line")
  local ok = git_ok(root, "pull", "-q", "--no-rebase", "--no-edit", tr)
  H.eq(ok, false, "conflict")
  H.has(table.concat(read(root .. "/b.md"), "\n"), "<<<<<<<")
  H.has(git(root, "status", "--porcelain"), "UU b.md")
end)

t.test("export: refuses when the full PKB has staged changes or a merge in progress", function()
  local root, def_file, out = git_pkb()
  H.write(root .. "/other.md", { "staged" })
  git_ok(root, "add", "other.md")
  local ok, err = require("pkb.export").write(plan_for(def_file))
  H.eq(ok, false)
  H.has(err, "staged")
  H.eq(vim.fn.isdirectory(out), 0, "nothing written")
end)

t.test("export: without git in the PKB the copy is still written; the message says import needs git", function()
  with_identity()
  local _, def_file = make_pkb()
  local ok, msg = require("pkb.export").write(plan_for(def_file))
  H.eq(ok, true, msg)
  H.has(msg, "not a git repo")
end)

t.test("re-export: refused while the export folder has commits not yet in the full PKB", function()
  local root, def_file, out = git_pkb()
  local E = require("pkb.export")
  assert(E.write(plan_for(def_file)))
  H.write(out .. "/new.md", { "written in the export folder" })
  git_ok(out, "add", "-A")
  git_ok(out, "commit", "-q", "-m", "not imported")
  local ok, err = E.write(plan_for(def_file))
  H.eq(ok, false)
  H.has(err, "not yet imported")
  H.eq(read(out .. "/new.md"), { "written in the export folder" }, "kept")
  -- after importing, re-exporting works
  assert(git_ok(root, "pull", "-q", "--no-rebase", "--no-edit", out))
  local ok2, msg2 = E.write(plan_for(def_file))
  H.eq(ok2, true, msg2)
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
  H.has(report, "depth 1, dates 2026-09-01..2026-11-30")
  H.has(report, "projects/a.md")
  H.has(report, "secret.md  never (#private)")
  H.has(report, "the plan")
  H.has(report, "Forbidden words: none")
  H.eq(vim.fn.isdirectory(out), 0, "nothing written before w")
  vim.fn.maparg("w", "n", false, true).callback()
  H.eq(git(out, "rev-list", "--count", "HEAD"), "1")
end)

return t
