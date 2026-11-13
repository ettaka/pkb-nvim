# pkb.nvim

A simple Neovim plugin template for PKB.

## Inbox

`:PKBInbox` lists open tasks by day, each with its time slot (`due` to `due` + `effort`):

```
## 2026-11-10 — total effort: 5h
[ ] 08:00–08:30  Water plants ↻  · tasks.md
[!] 11:00–12:30  Meeting  ⚠️ CONFLICT  · work/meetings.md
[ ] 13:00        Call the bank  · tasks.md
```

`[!]` notified, `[x]` dismissed (shown with `t`), `↻` recurring, `⚠️ CONFLICT` overlapping slots.
Keys: `<CR>` open the task, `c` complete, `s` skip, `d` dismiss, `t` show/hide dismissed, `q` close.

`:PKBInbox 2026-11-12` (or `require("pkb.notifier").open_day(2026, 11, 12)`, which calendar-nvim calls) opens it
with the cursor on that day; a day without tasks gets an empty section.

`:PKBInbox tz=-06:00` shows the times and days at another UTC offset (`+05:30`, `-6`, `Z`, and the home letters
`H`/`S` also work), under a `Times in UTC-06:00` header; the notes are not changed. It combines with a date:
`:PKBInbox 2026-11-12 tz=-06:00` (the date is then that offset's day). From Lua: `notifier.inbox({ tz = "-06:00" })`.

## Following file links

`require("pkb.links").follow()` opens the link under the cursor when it is a file link: `[text](path)` relative
to the note, from the PKB root (`/papers/x.pdf`) or absolute, and `[[./path]]` / `[[../path]]`. Markdown files
open in Neovim, others (PDFs, images) with the system opener. It returns `false` for anything else (URLs,
`[[page]]` links, no link), so a mapping can fall back to Telekasten:

```lua
vim.keymap.set("n", "<leader>zz", function()
  if not require("pkb.links").follow() then vim.cmd("Telekasten follow_link") end
end)
```

## Recurrence

`recur::<rule>` repeats a task; completing or skipping it writes the next instance below it.

- Every N days/weeks/months/years: `3d`, `2w`, `3m`, `1y`, or written out: `day`, `2weeks`, `3months`, `1year`
  (singular or plural). Presets: `daily`, `weekly`, `biweekly`/`fortnightly`, `monthly`, `bimonthly`, `yearly`/
  `annually`; a number multiplies them (`3monthly` = every 3 months).
- N-th weekday of the month: `1st_tue`, `2nd_wed`, `3rd_mon`, `4th_thu`, `last_fri` (full names work too).

Monthly steps from the 29th–31st land on the last day of a shorter month. An unknown rule is reported once and
the task does not repeat; complete and skip leave such a task unchanged until the tag is fixed.

## Reminders

A task with `due::` pops up in a digest window (and as a phone notification on Termux) `notify::` before it
is due: 30 min by default, or e.g. `notify::1h` / `notify::2day` per task.
`[q]` snoozes the digest until the task's next reminder: 15, 10, 5 and 0 min before due, and after that every
30 min until the task is done, skipped or dismissed. A snooze never lasts longer than 30 min, so a task with
`notify::2h` comes back every 30 min before the follow-ups start.

```lua
require("pkb.notifier").setup({
  default_notify = "30min",                       -- first reminder when a task has no notify:: tag
  remind_before = { "15min", "10min", "5min", "0min" }, -- follow-ups ({} for none)
  snooze_interval = 30 * 60,                      -- longest snooze, seconds
})
```

## Export

`:PKBExport` copies a subselection of the PKB into a fresh git repo (one commit, no history, no remote), e.g.
to hand notes over without anything else. Run it on an export page, an ordinary note in the PKB:

```markdown
# Security review 2026-11
export::security-review

## Seeds
- [[projects/kqc-simulations]]
- [[howto/ssh-setup]] depth::2

## Settings
depth::1
dates::2026-09-01..2026-11-30
out::~/pkb-export/security-review

## Never
- people/
- [[2026-10-14]]
- #private

## Forbidden words
- customer-x
```

- **Seeds** are exported, and so are the pages they link to, up to `depth` links away (default 1; a seed's own
  `depth::` overrides it). `[[page#heading]]` exports the whole page. Task references (`t-…` ids) count as links
  to the page with that `task::` tag. Images and other files linked from exported pages are copied too.
- File links may be relative to the page, start from the PKB root (`/papers/x.pdf`), or be absolute
  (`/home/me/pkb/papers/x.pdf`, `~/Documents/x.pdf`; `%20` and `<path with spaces>` work). Files outside the PKB
  are copied to `_external/`, and absolute links are rewritten (`[text](path)` relative to the page,
  `[[path]]` from the PKB root, as Telekasten reads them), so the copy contains no paths from your machine.
- **dates** selects too: every daily note (`YYYY-MM-DD.md`) in the range is exported like a seed (its links are
  followed up to `depth`; Never still applies), and daily notes reached by links must be in the range. With no
  seeds, the date range alone decides. Open ends work (`2026-09-01..`), and so do
  spaces and dashes (`dates:: 2026-09-01 – 2026-11-30`). A setting that cannot be read is shown as an error in
  the report, and the report's second line shows the depth and dates in use.
- **Never** (folders, pages, `#tags`, and absolute folders such as `~/Documents/private/`) is never exported, and links into it are not followed. The export page
  itself is never exported.
- In the copy, links to pages that are not exported become plain text. Nothing else is changed (tags stay).
- **Forbidden words** (case-insensitive) in the copy block writing.

`:PKBExport` first shows a report (pages and why, skipped pages, links turned into text, forbidden words);
`w` writes, `<CR>` opens a page, `q` cancels. `out` (default `~/pkb-export/<name>`) is rebuilt from scratch on
every export; a folder that is not an earlier export is never overwritten.

## Tests

```sh
make test                        # or: nvim --clean -l tests/run.lua
make test FILTER=notifier        # only tests whose "file: name" contains the filter
PKB_TEST_VERBOSE=1 make test     # also show why each known bug (xfail) fails
make test NVIM_BIN=/path/to/nvim  # use a specific nvim binary
```

Requires [timestamps-nvim](https://github.com/ettaka/timestamps-nvim): found next to this repo, via
`$TIMESTAMPS_NVIM_DIR`, or cloned into `.deps/` by `make test`.

Tests live in `tests/*_spec.lua` and use the small runner in `tests/run.lua` (no dependencies). They run
headless in a temporary PKB folder (never `~/pkb`) with `TZ=Europe/Helsinki` (override with `PKB_TEST_TZ`).
`t.xfail(...)` marks a known bug: the case must fail, and the run fails with XPASS once the bug is fixed, so the
marker is removed together with the fix.
