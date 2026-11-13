---------------------------------------------------------------
-- EXPORT
-- Copies a subselection of the PKB into a fresh git repo (one commit, no history, no remote), e.g. to hand
-- over notes without anything else. What to copy is defined on an export page in the PKB:
--
--   export::security-review
--   ## Seeds
--   - [[projects/kqc]] depth::2        start pages; depth:: (optional) overrides the default for this one
--   ## Settings
--   depth::1                           follow links this many steps from each seed (default 1)
--   dates::2026-09-01..2026-11-30      daily notes (YYYY-MM-DD.md) reached by links must be in this range
--   out::~/pkb-export/review           default ~/pkb-export/<name>
--   ## Never
--   - people/                          folder, [[page]] or #tag: never exported, links into it not followed
--   ## Forbidden words
--   - customer-x                       writing fails if the copy contains one (case-insensitive)
--
-- Links ([[page]], [[page#heading]], [[page|alias]], ![[file]], [text](path)) and task references (t-… ids,
-- to the page with that task:: tag) are followed. A heading link exports the whole page. In the copy, links
-- to pages that are not exported become plain text; everything else (tags too) is copied as is. The
-- export page itself is never exported.
---------------------------------------------------------------
local M = {}

local task_id = require("pkb.task_id")

M.MARKER = ".pkb-export" -- marks a folder as written by this module, so a later export may replace it

---------------------------------------------------------------- export page
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Reads an export page. nil if it has no export:: line.
function M.parse(lines)
  local def = { seeds = {}, depth = 1, never = {}, forbidden = {}, problems = {} }
  local section
  for _, line in ipairs(lines) do
    def.name = def.name or line:match("export::(%S.-)%s*$")
    local heading = line:match("^#+%s+(.-)%s*$")
    if heading then
      section = heading:lower()
    else
      local item = line:match("^%s*[-*+]%s+(.-)%s*$")
      if section == "seeds" and item then
        local link = item:match("^%[%[([^%]]+)%]%]")
        if link then
          table.insert(def.seeds, { link = link, depth = tonumber(item:match("depth::%s*(%d+)")) })
        end
      elseif section == "never" and item and item ~= "" then
        table.insert(def.never, item:match("^%[%[([^%]|#]+).-%]%]$") or item)
      elseif section == "forbidden words" and item and item ~= "" then
        table.insert(def.forbidden, item)
      elseif section == "settings" then
        M.parse_setting(def, (item or line))
      end
    end
  end
  if not def.name then return nil end
  return def
end

local DATE = "^%d%d%d%d%-%d%d%-%d%d$"

--- One line of the Settings section, written by hand: "key::value", spaces allowed after ::. Values that
--- cannot be read are collected in def.problems (shown as errors) instead of being ignored.
function M.parse_setting(def, line)
  local key, value = line:match("^%s*([%w_]+)::%s*(.-)%s*$")
  if not key then return end
  local function problem(msg) table.insert(def.problems, "Settings: " .. msg) end
  if key == "depth" then
    local n = value:match("^%d+$") and tonumber(value)
    if n then def.depth = n else problem(("depth::%s not understood (a number)"):format(value)) end
  elseif key == "out" then
    def.out = value
  elseif key == "dates" then
    -- en/em dashes are multi-byte, so not in a [] set
    local range = value:gsub("%s*–%s*", ".."):gsub("%s*—%s*", ".."):gsub("%s+%-%s+", "..")
    local from, to = range:match("^(.-)%s*%.%.%s*(.-)$")
    if from and (from == "" or from:match(DATE)) and (to == "" or to:match(DATE)) and (from ~= "" or to ~= "") then
      def.dates = { from = from ~= "" and from or nil, to = to ~= "" and to or nil }
    else
      problem(("dates::%s not understood (use dates::2026-09-01..2026-11-30, open ends work)"):format(value))
    end
  elseif key ~= "export" then
    problem(("unknown setting %s:: (known: depth, dates, out)"):format(key))
  end
end

---------------------------------------------------------------- the PKB
local function rel_path(root, path)
  path = vim.fs.normalize(path)
  if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
end

--- Every file in the PKB (relative paths), skipping hidden folders such as .git.
local function list_files(root)
  local out = {}
  for name, kind in vim.fs.dir(root, { depth = 50, skip = function(dir) return not dir:match("^%.") end }) do
    if kind == "file" and not name:match("^%.") and not name:match("/%.") then table.insert(out, name) end
  end
  table.sort(out)
  return out
end

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

--- Index of the PKB: files by relative path and by basename, page contents, and where each task id is defined.
local function index(root)
  local idx = { root = root, files = {}, by_name = {}, lines = {}, task_page = {} }
  for _, rel in ipairs(list_files(root)) do
    idx.files[rel] = true
    local base = vim.fs.basename(rel)
    local key = rel:match("%.md$") and base:sub(1, -4) or base
    idx.by_name[key] = idx.by_name[key] or {}
    table.insert(idx.by_name[key], rel)
    if rel:match("%.md$") then
      local lines = read_file(root .. "/" .. rel)
      idx.lines[rel] = lines
      for _, line in ipairs(lines) do
        local id = task_id.from_line(line)
        if id then idx.task_page[id] = idx.task_page[id] or rel end
      end
    end
  end
  return idx
end

local function is_url(path) return path:match("^%a[%w+.-]*:") ~= nil end

--- What a link path refers to: { rel = <path in the PKB> } or { abs = <file outside the PKB> }, or nil.
--- rel results also say whether the link was written as an absolute path (absolute = true).
--- `from` is the page the link is on. Paths may be relative to that page or to the PKB root, written from the
--- root with a leading "/" (/papers/x.pdf), absolute (/home/me/pkb/papers/x.pdf, ~/Documents/x.pdf) or a bare
--- page name found anywhere in the PKB ([[name]]).
local function resolve(idx, path, from)
  path = trim(path)
  if path == "" or is_url(path) then return nil end
  if path:match("^~") or path:match("^/") then
    local abs = vim.fs.normalize(vim.fn.expand(path))
    local stat = vim.uv.fs_stat(abs)
    if stat and stat.type == "file" then
      local rel = rel_path(idx.root, abs)
      if rel then return { rel = rel, absolute = true } end
      return { abs = abs }
    end
    if path:match("^/") and idx.files[path:sub(2)] then return { rel = path:sub(2) } end -- from the PKB root
    if path:match("^/") and idx.files[path:sub(2) .. ".md"] then return { rel = path:sub(2) .. ".md" } end
    return nil
  end
  local is_page = not path:match("%.%w+$") or path:match("%.md$")
  local name = is_page and path:gsub("%.md$", "") .. ".md" or path
  local candidates = { (vim.fs.normalize(name):gsub("^%./", "")) }
  local dir = vim.fs.dirname(from)
  if dir ~= "." then table.insert(candidates, (vim.fs.normalize(dir .. "/" .. name):gsub("^%./", ""))) end
  for _, c in ipairs(candidates) do
    if idx.files[c] then return { rel = c } end
  end
  if not path:find("/", 1, true) then
    local matches = idx.by_name[is_page and path:gsub("%.md$", "") or path]
    if matches then return { rel = matches[1] } end
  end
end

local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Every link on a line: { kind = "wiki"|"md", s, e (byte range of the whole link), path (decoded),
--- text (shown when the link is turned into plain text), embed, and how to write it back: rest (wiki: #heading
--- and |alias; md: a "title"), angle (<path>), encoded (%20) }.
local function links_in(line)
  local out = {}
  local pos = 1
  while true do
    local s, e, inner = line:find("%[%[([^%]]+)%]%]", pos)
    if not s then break end
    local embed = s > 1 and line:sub(s - 1, s - 1) == "!"
    local path, rest = inner:match("^([^|#]*)(.*)$")
    -- as plain text: the alias, else the link; an absolute path only by its file name (no home folder in the copy)
    local text = inner:match("|(.*)$") or (path:match("^[/~]") and vim.fs.basename(path) .. rest) or inner
    table.insert(out, { kind = "wiki", s = embed and s - 1 or s, e = e, path = path, rest = rest, embed = embed,
                        text = text })
    pos = e + 1
  end
  pos = 1
  while true do
    local s, e, bang, text, inside = line:find("(!?)%[([^%]]*)%]%(([^%)]+)%)", pos)
    if not s then break end
    local inside_wiki = false
    for _, l in ipairs(out) do
      if s >= l.s and s <= l.e then inside_wiki = true end
    end
    if not inside_wiki then
      local path, rest = inside:match("^<([^>]*)>(.*)$")
      local angle = path ~= nil
      if not angle then path, rest = inside:match("^(%S+)(.*)$") end
      if path then
        local decoded = url_decode(path)
        table.insert(out, { kind = "md", s = s, e = e, path = decoded:gsub("#.*$", ""), anchor = decoded:match("#.*$"),
                            rest = rest, text = text, embed = bang == "!", angle = angle, encoded = decoded ~= path })
      end
    end
    pos = e + 1
  end
  table.sort(out, function(a, b) return a.s < b.s end)
  return out
end

--- Path from folder `from_dir` (PKB-relative, "." for the root) to PKB-relative `to`.
local function relative_to(from_dir, to)
  local a = from_dir == "." and {} or vim.split(from_dir, "/", { plain = true })
  local b = vim.split(to, "/", { plain = true })
  local i = 1
  while i <= #a and i < #b and a[i] == b[i] do i = i + 1 end
  local parts = {}
  for _ = i, #a do table.insert(parts, "..") end
  for k = i, #b do table.insert(parts, b[k]) end
  return table.concat(parts, "/")
end

--- The link written back with a new path.
local function relink(link, path)
  local bang = link.embed and "!" or ""
  if link.kind == "wiki" then return ("%s[[%s%s]]"):format(bang, path, link.rest) end
  path = path .. (link.anchor or "")
  if link.angle or (path:find(" ", 1, true) and not link.encoded) then
    path = "<" .. path .. ">"
  elseif link.encoded then
    path = path:gsub(" ", "%%20")
  end
  return ("%s[%s](%s%s)"):format(bang, link.text, path, link.rest)
end

local function is_daily(rel)
  return vim.fs.basename(rel):match("^(%d%d%d%d%-%d%d%-%d%d)%.md$")
end

local function has_tag(lines, tag)
  for _, line in ipairs(lines) do
    local pos = 1
    while true do
      local s, e = line:find(tag, pos, true)
      if not s then break end
      local before, after = line:sub(s - 1, s - 1), line:sub(e + 1, e + 1)
      if (s == 1 or before:match("[%s%(%[]")) and not after:match("[%w_/-]") then return true end
      pos = e + 1
    end
  end
  return false
end

---------------------------------------------------------------- plan
--- What an export would write, without writing anything.
--- @return table plan { name, out, def_rel, pages = {{rel, why}}, files = {{rel, why}}, skipped = {{rel, reason, from}},
---   missing = {{link, from}}, unlinked = {{rel, line, text}}, forbidden = {{rel, line, word}}, errors = {string},
---   content = { [rel] = lines } }
function M.plan(def_file, def_lines)
  local root = vim.fs.normalize(require("pkb.notifier").PKB_ROOT or vim.env.PKB_ROOT or "~/pkb")
  root = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(root), ":p")):gsub("/$", "")
  def_file = vim.fs.normalize(vim.fn.fnamemodify(def_file, ":p"))
  local def = M.parse(def_lines or read_file(def_file))
  local plan = { pages = {}, files = {}, skipped = {}, missing = {}, unlinked = {}, forbidden = {}, errors = {},
                 content = {} }
  if not def then
    table.insert(plan.errors, "not an export page (no export:: line)")
    return plan
  end
  plan.name = def.name
  plan.depth, plan.dates = def.depth, def.dates
  vim.list_extend(plan.errors, def.problems)
  plan.out = vim.fs.normalize(vim.fn.expand(def.out or ("~/pkb-export/" .. def.name:gsub("[^%w._-]+", "-"))))
  plan.def_rel = rel_path(root, def_file)
  if not plan.def_rel then
    table.insert(plan.errors, ("the export page is not inside the PKB (%s)"):format(root))
    return plan
  end

  local idx = index(root)

  -- Why a page may not be exported (nil if it may).
  local function refused(rel, is_seed, abs)
    if rel == plan.def_rel then return "export page" end
    abs = abs or (root .. "/" .. rel)
    for _, rule in ipairs(def.never) do
      if rule:match("^[/~]") then
        local folder = vim.fs.normalize(vim.fn.expand(rule))
        if abs == folder or abs:sub(1, #folder + 1) == folder .. "/" then return ("never (%s)"):format(rule) end
      elseif not rel then -- a file outside the PKB: only absolute rules apply
      elseif rule:match("^#") then
        if idx.lines[rel] and has_tag(idx.lines[rel], rule) then return ("never (%s)"):format(rule) end
      elseif rule:match("/$") then
        if rel:sub(1, #rule) == rule then return ("never (%s)"):format(rule) end
      elseif rel == rule or rel == rule .. ".md" or (resolve(idx, rule, "") or {}).rel == rel then
        return ("never (%s)"):format(rule)
      end
    end
    local day = rel and is_daily(rel)
    if day and def.dates and not is_seed then
      if (def.dates.from and day < def.dates.from) or (def.dates.to and day > def.dates.to) then
        return "outside dates"
      end
    end
  end

  -- Breadth-first from the seeds; budget = how many more links may be followed from a page.
  local budget, why, order, queue = {}, {}, {}, {}
  local skipped, missing_seen = {}, {}
  local function skip(rel, reason, from)
    if not skipped[rel] and not budget[rel] then
      skipped[rel] = { rel = rel, reason = reason, from = from }
    end
  end
  local function visit(rel, left, from, is_seed)
    if budget[rel] and budget[rel] >= left then return end
    local reason = refused(rel, is_seed)
    if reason then return skip(rel, reason, from) end
    if not budget[rel] then
      table.insert(order, rel)
      why[rel] = from and from or "seed"
    end
    skipped[rel] = nil
    budget[rel] = left
    table.insert(queue, rel)
  end

  for _, seed in ipairs(def.seeds) do
    local rel = (resolve(idx, (seed.link:gsub("[|#].*$", "")), plan.def_rel) or {}).rel
    if not rel then
      table.insert(plan.errors, ("seed [[%s]] does not exist"):format(seed.link))
    else
      visit(rel, seed.depth or def.depth, nil, true)
    end
  end

  -- Files linked from exported pages. Files outside the PKB are copied to _external/<name>.
  local attachments, attachment_why, attachment_src = {}, {}, {}
  local external = {} -- absolute path -> its path in the copy
  local function external_dest(abs)
    if external[abs] then return external[abs] end
    local base = vim.fs.basename(abs)
    local stem, ext = base:match("^(.*)(%.[^.]+)$")
    if not stem then stem, ext = base, "" end
    local dest, n = "_external/" .. base, 1
    while attachments[dest] do
      n = n + 1
      dest = ("_external/%s-%d%s"):format(stem, n, ext)
    end
    external[abs] = dest
    return dest
  end

  local head = 1
  while head <= #queue do
    local rel = queue[head]
    head = head + 1
    local left = budget[rel]
    for _, line in ipairs(idx.lines[rel] or {}) do
      for _, link in ipairs(links_in(line)) do
        local target = resolve(idx, link.path, rel)
        if not target then
          local name = trim(link.path)
          if name ~= "" and not is_url(name) and not missing_seen[name] then
            missing_seen[name] = true
            table.insert(plan.missing, { link = name, from = rel })
          end
        elseif target.abs then
          local reason = refused(nil, false, target.abs)
          if reason then
            skip(target.abs, reason, rel)
          elseif not external[target.abs] then
            local dest = external_dest(target.abs)
            attachments[dest], attachment_why[dest], attachment_src[dest] = true, rel, target.abs
          end
        elseif target.rel:match("%.md$") then
          if left > 0 then visit(target.rel, left - 1, rel) else skip(target.rel, "beyond depth", rel) end
        elseif not attachments[target.rel] then
          local reason = refused(target.rel)
          if reason then
            skip(target.rel, reason, rel)
          else
            attachments[target.rel], attachment_why[target.rel] = true, rel
          end
        end
      end
      for id in line:gmatch(task_id.PATTERN) do
        local target = idx.task_page[id]
        if target and target ~= rel then
          if left > 0 then visit(target, left - 1, rel) else skip(target, "beyond depth", rel) end
        end
      end
    end
  end

  for _, rel in ipairs(order) do table.insert(plan.pages, { rel = rel, why = why[rel] }) end
  local files = vim.tbl_keys(attachments)
  table.sort(files)
  for _, rel in ipairs(files) do
    table.insert(plan.files, { rel = rel, why = attachment_why[rel], src = attachment_src[rel] })
  end
  plan.files_src = attachment_src
  local skipped_list = vim.tbl_values(skipped)
  table.sort(skipped_list, function(a, b) return a.rel < b.rel end)
  plan.skipped = skipped_list

  -- Content of the copy: links to anything not exported become their text; links written as absolute paths
  -- (which would not work in the copy and show where your files are) are rewritten relative to the page.
  for _, rel in ipairs(order) do
    local out = {}
    local dir = vim.fs.dirname(rel)
    for n, line in ipairs(idx.lines[rel]) do
      local links = links_in(line)
      for i = #links, 1, -1 do
        local link = links[i]
        local target = resolve(idx, link.path, rel)
        -- [[wiki]] links are read from the PKB root (as Telekasten does), [text](path) from the page
        local function from_here(p) return link.kind == "wiki" and p or relative_to(dir, p) end
        local new_path
        if target and target.abs and external[target.abs] then
          new_path = from_here(external[target.abs])
        elseif target and target.rel and (budget[target.rel] or attachments[target.rel]) then
          if target.absolute then new_path = from_here(target.rel) end
        elseif link.kind == "md" and is_url(link.path) then
          -- a web link: copied as is
        else
          line = line:sub(1, link.s - 1) .. link.text .. line:sub(link.e + 1)
          table.insert(plan.unlinked, { rel = rel, line = n, text = link.text })
        end
        if new_path then line = line:sub(1, link.s - 1) .. relink(link, new_path) .. line:sub(link.e + 1) end
      end
      out[n] = line
    end
    plan.content[rel] = out
  end
  table.sort(plan.unlinked, function(a, b) return a.rel < b.rel or (a.rel == b.rel and a.line < b.line) end)

  -- Forbidden words anywhere in the copy (contents and file names).
  for _, word in ipairs(def.forbidden) do
    local w = word:lower()
    for _, rel in ipairs(order) do
      if rel:lower():find(w, 1, true) then
        table.insert(plan.forbidden, { rel = rel, line = 0, word = word })
      end
      for n, line in ipairs(plan.content[rel]) do
        if line:lower():find(w, 1, true) then table.insert(plan.forbidden, { rel = rel, line = n, word = word }) end
      end
    end
    for _, f in ipairs(plan.files) do
      if f.rel:lower():find(w, 1, true) then table.insert(plan.forbidden, { rel = f.rel, line = 0, word = word }) end
    end
    -- the name goes into the commit message and the marker file
    if plan.name:lower():find(w, 1, true) then
      table.insert(plan.forbidden, { rel = "export::" .. plan.name, line = 0, word = word })
    end
  end

  plan.root = root
  return plan
end

---------------------------------------------------------------- write
local function run(cmd, cwd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  if res.code ~= 0 then return nil, vim.trim((res.stderr or "") .. (res.stdout or "")) end
  return vim.trim(res.stdout or "")
end

--- Writes the plan as a fresh git repo at plan.out (replacing an earlier export there).
--- @return boolean ok
--- @return string message
function M.write(plan)
  if #plan.errors > 0 then return false, "export has errors: " .. table.concat(plan.errors, "; ") end
  if #plan.forbidden > 0 then
    return false, ("forbidden words in the copy (%d), nothing written"):format(#plan.forbidden)
  end
  local out = plan.out
  if vim.uv.fs_stat(out) then
    local is_export = vim.uv.fs_stat(out .. "/" .. M.MARKER) ~= nil
    local empty = vim.fn.empty(vim.fn.readdir(out)) == 1
    if not is_export and not empty then
      return false, out .. " exists and is not an earlier export; choose another out:: or remove it"
    end
    if is_export then vim.fn.delete(out, "rf") end
  end
  vim.fn.mkdir(out, "p")

  for _, page in ipairs(plan.pages) do
    local dest = out .. "/" .. page.rel
    vim.fn.mkdir(vim.fs.dirname(dest), "p")
    vim.fn.writefile(plan.content[page.rel], dest)
  end
  for _, f in ipairs(plan.files) do
    local dest = out .. "/" .. f.rel
    vim.fn.mkdir(vim.fs.dirname(dest), "p")
    local ok, err = vim.uv.fs_copyfile(f.src or (plan.root .. "/" .. f.rel), dest)
    if not ok then return false, "copying " .. f.rel .. " failed: " .. tostring(err) end
  end
  vim.fn.writefile({ "Written by pkb-nvim :PKBExport (" .. plan.name .. ")." }, out .. "/" .. M.MARKER)

  for _, cmd in ipairs({
    { "git", "init", "-q" },
    { "git", "add", "-A" },
    { "git", "commit", "-q", "-m", "PKB export: " .. plan.name },
  }) do
    local _, err = run(cmd, out)
    if err then return false, ("%s failed in %s: %s"):format(table.concat(cmd, " "), out, err) end
  end
  return true, ("exported %d pages and %d files to %s (one commit)"):format(#plan.pages, #plan.files, out)
end

---------------------------------------------------------------- report
function M.report_lines(plan)
  local lines = {}
  local function add(s) table.insert(lines, s) end
  local map = {}
  local function add_rel(s, rel) add(s); map[#lines] = rel end
  add(("EXPORT %s: %d pages, %d files → %s"):format(plan.name or "?", #plan.pages, #plan.files, plan.out or "?"))
  local settings = ("depth %s"):format(plan.depth or "?")
  if plan.dates then
    settings = settings .. (", dates %s..%s"):format(plan.dates.from or "", plan.dates.to or "")
  end
  add(settings)
  add("[w] write  [<CR>] open page  [q] cancel")
  for _, e in ipairs(plan.errors) do add("ERROR: " .. e) end
  add("")
  add("Pages:")
  for _, p in ipairs(plan.pages) do
    add_rel(("  %s  %s"):format(p.rel, p.why == "seed" and "seed" or "← " .. p.why), p.rel)
  end
  if #plan.files > 0 then
    add("Files:")
    for _, f in ipairs(plan.files) do
      add_rel(("  %s  ← %s%s"):format(f.rel, f.why, f.src and ("  (" .. f.src .. ")") or ""), f.rel)
    end
  end
  if #plan.skipped > 0 then
    add("Skipped:")
    for _, s in ipairs(plan.skipped) do
      add_rel(("  %s  %s%s"):format(s.rel, s.reason, s.from and ("  ← " .. s.from) or ""), s.rel)
    end
  end
  if #plan.missing > 0 then
    add("Links to nothing:")
    for _, m in ipairs(plan.missing) do add_rel(("  [[%s]]  in %s"):format(m.link, m.from), m.from) end
  end
  if #plan.unlinked > 0 then
    add("Links turned into plain text:")
    for _, u in ipairs(plan.unlinked) do add_rel(("  %s:%d  %s"):format(u.rel, u.line, u.text), u.rel) end
  end
  if #plan.forbidden == 0 then
    add("Forbidden words: none")
  else
    add("FORBIDDEN WORDS (writing is blocked):")
    for _, f in ipairs(plan.forbidden) do add_rel(("  %s:%d  %s"):format(f.rel, f.line, f.word), f.rel) end
  end
  return lines, map
end

--- :PKBExport — plan the export defined by the current buffer and show the report.
function M.run(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if not M.parse(lines) then
    vim.notify("[PKB] Not an export page: add an export::<name> line (see :help or the README)", vim.log.levels.WARN)
    return
  end
  local plan = M.plan(vim.api.nvim_buf_get_name(buf), lines)
  local report, map = M.report_lines(plan)

  vim.cmd("botright new")
  local rbuf = vim.api.nvim_get_current_buf()
  vim.bo[rbuf].buftype = "nofile"
  vim.bo[rbuf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, report)
  vim.bo[rbuf].modifiable = false
  local win = vim.api.nvim_get_current_win()

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  local o = { buffer = rbuf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", o, { desc = "Cancel the export" }))
  vim.keymap.set("n", "w", function()
    local ok, msg = M.write(plan)
    vim.notify("[PKB] " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    if ok then close() end
  end, vim.tbl_extend("force", o, { desc = "Write the export repo" }))
  vim.keymap.set("n", "<CR>", function()
    local rel = map[vim.api.nvim_win_get_cursor(0)[1]]
    if rel and plan.root then
      close()
      local path = rel:match("^/") and rel or (plan.files_src or {})[rel] or (plan.root .. "/" .. rel)
      vim.cmd.edit(vim.fn.fnameescape(path))
    end
  end, vim.tbl_extend("force", o, { desc = "Open this page" }))
end

return M
