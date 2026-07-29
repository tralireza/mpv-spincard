-- Stubbed build_card render check for the rating row (headline + secondary pills).
-- No mpv: stubs mp/mp.msg/mp.utils; drives card.build_card and greps the ASS.
--   run:  luajit tests/test_card_rating.lua   (from the repo root)

local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function() return noop end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return noop end
package.path = "scripts/spincard/?.lua;" .. package.path

local card = require("card")

-- Minimal opts: disable every heavy section so only the rating row is exercised.
local opts = {
    pos_x = 40, pos_y = 40, anchor = "bottom",
    logo_height = 0.12, disc_size = 0.22, signal_dbm_max = -40.6,
    show_tech = false, show_logo = false, show_disc = false, show_poster = false,
    show_banner = false, show_fanart = false,
    cast_scroll = false, overview_scroll = false,
    cast_fs = 22, cast_bold = true, cast_max = 5, cast_lines = 2, cast_cols = 2,
    overview_lines = 3,
    imdb_votes = false,
}
local deps = {
    anim_fade = function() return 1 end,
    cur_signal = function() return nil end,
    cast_idx = function() return 0 end,
    overview_idx = function() return 0 end,
    upnext_idx = function() return 0 end,
    tech = function() return {} end,
}
card.init(opts, deps)

local fails = 0
local function want(name, ass, sub, present)
    local has = ass:find(sub, 1, true) ~= nil
    if has ~= present then
        fails = fails + 1
        print(string.format("FAIL %s : expected '%s' %s", name, sub, present and "PRESENT" or "ABSENT"))
    else
        print(string.format("ok   %s : '%s' %s", name, sub, present and "present" or "absent"))
    end
end
local function build(c) return (card.build_card(c)) end

-- 1) IMDb-only ---------------------------------------------------------------
local a1 = build({ kind = "movie", title = "Alpha", rating_imdb = 8.1 })
want("imdb-only: yellow pill", a1, "18C5F5", true)
want("imdb-only: label IMDb", a1, "IMDb", true)
want("imdb-only: score 8.1", a1, "8.1", true)
want("imdb-only: no TMDB pill", a1, "E4B401", false)

-- 2) Both present ------------------------------------------------------------
local a2 = build({ kind = "movie", title = "Beta", rating = 7.8, rating_src = "TMDB", rating_imdb = 8.1 })
want("both: IMDb yellow pill", a2, "18C5F5", true)
want("both: TMDB blue pill", a2, "E4B401", true)
want("both: headline IMDb", a2, "IMDb", true)
want("both: secondary 'TMDB 7.8'", a2, "TMDB 7.8", true)
want("both: headline score 8.1", a2, "8.1", true)

-- 3) TMDB-only (regression: unchanged from before) --------------------------
local a3 = build({ kind = "movie", title = "Gamma", rating = 7.8, rating_src = "TMDB" })
want("tmdb-only: blue pill", a3, "E4B401", true)
want("tmdb-only: label TMDB", a3, "TMDB", true)
want("tmdb-only: no yellow pill", a3, "18C5F5", false)
want("tmdb-only: no value in pill (label only)", a3, "TMDB 7.8", false)

-- 4) Votes shown ------------------------------------------------------------
opts.imdb_votes = true
local a4 = build({ kind = "movie", title = "Delta", rating_imdb = 8.1, rating_imdb_votes = 1234567 })
want("votes: (1.2M)", a4, "(1.2M)", true)
opts.imdb_votes = false

-- 5) Bare .nfo rating (no source) => stars only, no pill --------------------
-- Use 8.5 so the star tier is green (78C878); the mid tier [5,7.5) colours stars
-- 18C5F5 (== the IMDb pill gold), which would confound the "no pill" grep.
local a5 = build({ kind = "movie", title = "Eps", rating = 8.5 })
want("nfo-bare: score 8.5", a5, "8.5", true)
want("nfo-bare: no blue pill", a5, "E4B401", false)
want("nfo-bare: no yellow pill", a5, "18C5F5", false)

print(string.rep("-", 40))
if fails == 0 then print("ALL PASS") else print(fails .. " FAILURE(S)"); os.exit(1) end
