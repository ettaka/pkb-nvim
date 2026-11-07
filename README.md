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
