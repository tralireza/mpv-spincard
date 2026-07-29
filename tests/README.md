# spincard tests

Headless unit tests for the pure / logic parts of spincard — **no mpv, no network, no
ffmpeg**. Each test stubs the `mp`, `mp.msg` and `mp.utils` modules, `require`s the module
under test, and asserts on the returned values or the produced ASS string.

Run with **luajit** (the deploy target's interpreter) from the **repo root** — the tests
set `package.path` to `scripts/spincard/?.lua`, which is relative to the current directory,
so they must be run from the top of the repo.

## Run everything

```sh
./tests/run.sh            # or: bash tests/run.sh
```

Prints one line per test (`PASS` / `FAIL` / `AUDIT`) and exits non-zero if any
assert-based test fails.

One-liner without the runner:

```sh
for f in tests/test_*.lua; do echo "== $f =="; luajit "$f"; done
```

## Run one

```sh
luajit tests/test_overview_scroll.lua
```

Each assert-based test prints `ok …` lines and ends with `ALL PASS` (exit 0), or a failure
summary (exit 1).

## What's covered

- **`test_identify.lua`** — path → `{kind, query, season, episode}` (`identify.lua`).
- **`test_omdb.lua`** — OMDb URL build + `parse_omdb` (rating, RT %, Metacritic, awards, box office).
- **`test_fanart.lua`** — fanart.tv URL build + best-art `parse` (movie disc / banner pick).
- **`test_epg.lua`** — Tvheadend EPG "covers-now" selection + the no-EPG gap card.
- **`test_card_render.lua`** — `build_card` ASS output (rating/critic pills, awards, cast on/off).
- **`test_card_rating.lua`** — the rating row (IMDb headline + TMDB/RT/MC cluster).
- **`test_card_height.lua`** — the 16:9 / φ height ceiling (trims synopsis / "Next", keeps the footer).
- **`test_overview_scroll.lua`** — synopsis scroll: smooth glide, both-end holds, `line` mode, static-when-fits.
- **`test_card_fonts.lua`** — **audit, not asserts**: dumps each element's font size across all four card kinds (movie / tv / livetv / unknown) so you can check the tiers stay uniform. `run.sh` labels it `AUDIT`.

## Notes

- **luajit** is expected (matches production). Plain `lua` 5.1 works for most too.
- Visual / manual harnesses (e.g. `local/render_noepg.lua`), screenshots and other scratch
  artifacts stay under the git-ignored `local/` dir — the `tests/` here are the automated,
  dependency-free checks.
