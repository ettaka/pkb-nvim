-- Test helpers shared by the *_spec.lua files (see tests/run.lua).
local H = {}

local tmpdirs = {}
local cleanups = {}
H.messages = {} -- everything passed to print()/vim.notify during the current test

local real_print, real_notify = print, vim.notify

--- Build a suite: t.test(name, fn), t.xfail(name, reason, fn).
function H.suite()
  local t = { cases = {} }
  function t.test(name, fn) table.insert(t.cases, { name = name, fn = fn }) end
  function t.xfail(name, reason, fn) table.insert(t.cases, { name = name, fn = fn, xfail = reason }) end
  return t
end

function H.eq(got, want, msg)
  if not vim.deep_equal(got, want) then
    error(("%sexpected %s\n       got %s"):format(msg and (msg .. ": ") or "", vim.inspect(want), vim.inspect(got)), 2)
  end
end

function H.ok(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
  return cond
end

--- Assert `s` contains plain substring `sub`.
function H.has(s, sub, msg)
  if type(s) ~= "string" or not s:find(sub, 1, true) then
    error(("%sexpected %s to contain %s"):format(msg and (msg .. ": ") or "", vim.inspect(s), vim.inspect(sub)), 2)
  end
end

--- Fresh temporary directory, removed after the test.
function H.tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  table.insert(tmpdirs, d)
  return d
end

--- Write lines to path (creating parent dirs) and return path.
function H.write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
  return path
end

--- Local epoch for a wall-clock time in the test TZ.
function H.local_ts(y, m, d, hh, mm)
  return os.time({ year = y, month = m, day = d, hour = hh or 0, min = mm or 0, sec = 0 })
end

--- Epoch as an unambiguous UTC tag value, e.g. "2026-11-10T08:00Z" (independent of DST and HOME_TZ).
function H.iso_utc(ts) return os.date("!%Y-%m-%dT%H:%MZ", ts) end

--- Run fn after the current test, even if it fails.
function H.defer(fn) table.insert(cleanups, fn) end

--- Format epoch as local "YYYY-MM-DD HH:MM".
function H.fmt(ts) return os.date("%Y-%m-%d %H:%M", ts) end

--- Unload modules whose name starts with one of the prefixes, so the next require gets fresh state.
function H.unload(...)
  for _, prefix in ipairs({ ... }) do
    for name in pairs(package.loaded) do
      if name == prefix or name:sub(1, #prefix + 1) == prefix .. "." then package.loaded[name] = nil end
    end
  end
end

--- Evaluate a Lua expression in a child nvim running under timezone `tz`; returns its value
--- (tostring'ed). Needed because TZ cannot be changed inside a running nvim.
function H.eval_in_tz(tz, expr)
  local code = ("vim.opt.rtp:prepend(%q) io.stdout:write(tostring(%s))"):format(H.root, expr)
  local file = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(vim.split(code, "\n"), file)
  local res = vim.system({ vim.v.progpath, "--clean", "-l", file }, { env = { TZ = tz }, text = true }):wait()
  vim.fn.delete(file)
  if res.code ~= 0 then error("child nvim failed: " .. (res.stderr or ""), 2) end
  return res.stdout
end

--- Path to a sibling plugin repo: $<NAME>_DIR, ../<name>, or .deps/<name> (see Makefile `deps`).
function H.find_dep(name)
  local env = vim.env[name:upper():gsub("%-", "_") .. "_DIR"]
  local paths = { H.root .. "/../" .. name, H.root .. "/.deps/" .. name }
  if env then table.insert(paths, 1, env) end
  for _, p in ipairs(paths) do
    if vim.fn.isdirectory(p .. "/lua") == 1 then return vim.fn.fnamemodify(p, ":p") end
  end
  error(("dependency %s not found: clone it next to this repo, into .deps/ (make deps), or set %s_DIR")
    :format(name, name:upper():gsub("%-", "_")))
end

function H.before_each()
  H.messages = {}
  _G.print = function(...)
    table.insert(H.messages, table.concat(vim.tbl_map(tostring, { ... }), " "))
  end
  vim.notify = function(msg, level)
    table.insert(H.messages, msg)
  end
end

function H.after_each()
  for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
  cleanups = {}
  _G.print, vim.notify = real_print, real_notify
  for _, d in ipairs(tmpdirs) do vim.fn.delete(d, "rf") end
  tmpdirs = {}
  -- close any windows/buffers a test opened
  pcall(vim.cmd, "silent! only! | silent! %bwipeout!")
end

return H
