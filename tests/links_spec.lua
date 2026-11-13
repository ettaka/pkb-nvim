-- pkb.links: following the link under the cursor where Telekasten does not (it is mapped before Telekasten's
-- follow_link): [text](path) relative to the note, from the PKB root (/path) or absolute, and [[./path]] / [[../path]].
local H = require("tests.helpers")
local t = H.suite()
local notifier = require("tests.pkb").notifier

local opened -- what vim.ui.open was asked to open
local function stub_open()
  local orig = vim.ui.open
  opened = nil
  vim.ui.open = function(path) opened = path; return {}, nil end
  H.defer(function() vim.ui.open = orig end)
end

local function pkb()
  local root = H.tmpdir()
  H.write(root .. "/papers/qc.pdf", { "PDF" })
  H.write(root .. "/papers/my paper.pdf", { "PDF" })
  H.write(root .. "/notes/other.md", { "# other" })
  local note = H.write(root .. "/notes/a.md", {
    "pdf [qc](../papers/qc.pdf) here",                   -- 1: relative to the note
    "from root [qc](/papers/qc.pdf)",                    -- 2: from the PKB root
    "note [o](other.md#Section)",                         -- 3: markdown file, anchor
    "spaces [p](../papers/my%20paper.pdf) and [p2](<../papers/my paper.pdf>)", -- 4
    "web [w](https://example.com/x)",                    -- 5: a URL: left to Telekasten
    "wiki [[../papers/qc.pdf]] and [[other]]",           -- 6: ./ ../ wiki links here, others to Telekasten
    "missing [m](../papers/gone.pdf)",                   -- 7
    "no link here",                                       -- 8
    "absolute [abs](" .. root .. "/papers/qc.pdf)",      -- 9
  })
  notifier(root)
  vim.cmd.edit(note)
  return root
end

local function follow_at(row, needle)
  local col = vim.fn.getline(row):find(needle, 1, true) - 1
  vim.api.nvim_win_set_cursor(0, { row, col })
  return require("pkb.links").follow()
end

t.test("a relative [text](path) opens relative to the note, a PDF with the system opener", function()
  stub_open()
  local root = pkb()
  H.eq(follow_at(1, "qc]"), true)
  H.eq(opened, root .. "/papers/qc.pdf")
end)

t.test("/path is read from the PKB root when no such absolute file exists; absolute paths work", function()
  stub_open()
  local root = pkb()
  H.eq(follow_at(2, "(/papers"), true)
  H.eq(opened, root .. "/papers/qc.pdf")
  H.eq(follow_at(9, "[abs]"), true)
  H.eq(opened, root .. "/papers/qc.pdf")
end)

t.test("a markdown file opens in Neovim (the #anchor is ignored)", function()
  stub_open()
  local root = pkb()
  H.eq(follow_at(3, "[o]"), true)
  H.eq(vim.api.nvim_buf_get_name(0), root .. "/notes/other.md")
  H.eq(opened, nil)
end)

t.test("%20 and <path with spaces> are understood; the cursor picks the link it is on", function()
  stub_open()
  local root = pkb()
  H.eq(follow_at(4, "p2"), true)
  H.eq(opened, root .. "/papers/my paper.pdf")
  opened = nil
  H.eq(follow_at(4, "[p]"), true)
  H.eq(opened, root .. "/papers/my paper.pdf")
end)

t.test("[[../path]] wiki links open relative to the note", function()
  stub_open()
  local root = pkb()
  H.eq(follow_at(6, "../papers"), true)
  H.eq(opened, root .. "/papers/qc.pdf")
end)

t.test("URLs, plain [[page]] links and text without a link are left to Telekasten", function()
  stub_open()
  pkb()
  H.eq(follow_at(5, "[w]"), false)
  H.eq(follow_at(6, "[[other"), false)
  H.eq(follow_at(8, "link"), false)
  H.eq(opened, nil)
end)

t.test("a link to a file that does not exist warns and is handled", function()
  stub_open()
  pkb()
  H.eq(follow_at(7, "[m]"), true)
  H.has(H.messages[#H.messages], "gone.pdf")
  H.eq(opened, nil)
end)

return t
