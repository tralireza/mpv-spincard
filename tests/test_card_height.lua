-- Height-ceiling audit: verify the parameterized card height cap (card_aspect /
-- card_max_height) trims the elastic section (movie/TV synopsis window / live-TV "Up
-- next") to fit, never clips the footer, and leaves short cards untouched.
--   run:  luajit tests/test_card_height.lua
local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function()
    -- return numbers for the progress-row props so the footer (progress bar) renders
    local props = { ["percent-pos"] = 42, ["time-pos"] = 1200, ["time-remaining"] = 1800 }
    return setmetatable({
        get_property_number = function(k) return props[k] end,
        get_property = function() return nil end,
    }, { __index = function() return function() return nil end end })
end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return { parse_json = function() end, format_json = function() end } end
package.path = "scripts/spincard/?.lua;" .. package.path
local layout = require("layout")
local card = require("card")

local CAP_169 = math.floor(layout.CARD_W * 9 / 16 + 0.5)  -- 484
local CAP_PHI = math.floor(layout.CARD_W / layout.PHI + 0.5) -- 532

local base_opts = {
    pos_x = 22, pos_y = 22, disc_size = 0.22, anchor = "bottom",
    overview_lines = 12, overview_scroll = false, imdb_votes = true,
    show_tech = true, cast_scroll = true, cast_max = 5, cast_cols = 2,
    cast_lines = 2, cast_fs = 21, cast_bold = true, cast_scroll_dir = "horizontal",
    cast_scroll_px = 3, logo_height = 0.12, signal_dbm_max = -40.6,
    live_upcoming_delay = 3, live_upcoming_lines = 20, live_upcoming_secs = 1.5,
    live_signal = false,
    card_max_height = 0, -- default: derive from card_aspect (unset => 16:9)
}
local function O(over) local o = {}; for k, v in pairs(base_opts) do o[k] = v end; for k, v in pairs(over or {}) do o[k] = v end; return o end
local deps = {
    anim_fade = function() return 1 end, cur_signal = function() return nil end,
    cast_idx = function() return 0 end, overview_idx = function() return 0 end,
    upnext_idx = function() return 0 end,
    casthead_active = function() return false end,
    tech = function()
        return { vwidth = 1920, hdr = "HDR10", vcodec = "HEVC", acodec = "EAC3",
                 achan = "5.1", fps = "24", audio = "English EAC3 5.1",
                 subs = "English, Spanish", chapters = 12, size = "4.2 GiB" }
    end,
}
local function build(c, over) card.init(O(over), deps); local _, _, r = card.build_card(c); return r end
local function ass(c, over) card.init(O(over), deps); return (card.build_card(c)) end
local function count(s, needle) local n = 0; for _ in s:gmatch(needle) do n = n + 1 end; return n end

-- aspect presets
local UNCAP = { card_aspect = "off" }
local A169  = { card_aspect = "16:9" }
local APHI  = { card_aspect = "phi" }

local LONG = ("A gripping, sprawling synopsis sentence that keeps going and going so it "
    .. "wraps across many lines when rendered into the card body area. "):rep(10)
local common = {
    tagline = "A short tagline", genres = { "Drama", "Sci-Fi", "Thriller" },
    cast = { { name = "Actor One", role = "Hero" }, { name = "Actor Two", role = "Villain" } },
    rating = 7.8, rating_imdb = 8.1, rating_imdb_votes = 1200000, rating_src = "TMDB",
    rt = 82, mc = 67, director = "A Director", studio = "A Studio",
    awards = "Won 3 Oscars. Another 12 wins.", boxoffice = 785000000,
}
local function mk(t) local c = {}; for k, v in pairs(common) do c[k] = v end; for k, v in pairs(t) do c[k] = v end; return c end
local upcoming = {}
for i = 1, 22 do upcoming[i] = { title = "Upcoming programme number " .. i, start = 1700000000 + i * 1800 } end

local movie_tall = mk{ kind = "movie",
    title = "A Very Long Movie Title That Will Wrap Across Several Lines In The Heading Area", year = "2025", overview = LONG }
local tv_tall = mk{ kind = "tv",
    title = "A Long Television Series Title That Wraps", year = "2025", season = 3, episode = 12,
    episode_title = "The Episode With A Rather Long Name", ep_total = 24, overview = LONG }
local movie_short = mk{ kind = "movie", title = "Short Movie", year = "2025", overview = "One brief line." }
local unknown_lean = { kind = "unknown", title = "some.random.file.2025.1080p.mkv" }
local livetv_tall = { kind = "livetv", title = "A Live Programme", channel = "{@}Channel HD",
    subtitle = "Episode subtitle here", overview = LONG, upcoming = upcoming }

local pass, fail = 0, 0
local function check(cond, msg)
    if cond then pass = pass + 1; io.write("  PASS  " .. msg .. "\n")
    else fail = fail + 1; io.write("  FAIL  " .. msg .. "\n") end
end

io.write(string.format("16:9 ceiling = %d   phi ceiling = %d   (CARD_W=%d)\n\n", CAP_169, CAP_PHI, layout.CARD_W))
io.write(string.format("%-14s %8s %8s %8s %8s\n", "scenario", "uncap", "16:9", "phi", "px=450"))
io.write(string.rep("-", 50) .. "\n")
for _, s in ipairs({ { "movie-tall", movie_tall }, { "tv-tall", tv_tall }, { "movie-short", movie_short },
                     { "unknown-lean", unknown_lean }, { "livetv-tall", livetv_tall } }) do
    io.write(string.format("%-14s %8d %8d %8d %8d\n", s[1],
        build(s[2], UNCAP).h, build(s[2], A169).h, build(s[2], APHI).h, build(s[2], { card_max_height = 450 }).h))
end

io.write("\nAssertions:\n")
-- Default (16:9) caps at 484; phi caps at 532 (taller); both keep tall cards within bound.
for _, s in ipairs({ { "movie-tall", movie_tall }, { "tv-tall", tv_tall } }) do
    check(build(s[2], A169).h <= CAP_169, s[1] .. ": 16:9 within " .. CAP_169)
    check(build(s[2], APHI).h <= CAP_PHI, s[1] .. ": phi within " .. CAP_PHI)
    check(build(s[2], APHI).h > build(s[2], A169).h, s[1] .. ": phi renders TALLER than 16:9")
    check(build(s[2], UNCAP).h > CAP_PHI, s[1] .. ": uncapped overflows both ceilings")
    -- trim, not clip: footer (tech line 8C8C8C + progress caption A0A0A0) survives under 16:9
    local a = ass(s[2], A169)
    check(a:find("1c&H8C8C8C&", 1, true) and a:find("1c&HA0A0A0&", 1, true), s[1] .. ": footer kept after 16:9 trim")
    -- synopsis window shrinks vs uncapped
    check(count(ass(s[2], A169), "1c&HC8C8C8&") < count(ass(s[2], UNCAP), "1c&HC8C8C8&"), s[1] .. ": synopsis trimmed by 16:9")
end
-- Short/lean cards: untouched by any ceiling (identical to uncapped, below 484).
for _, s in ipairs({ { "movie-short", movie_short }, { "unknown-lean", unknown_lean } }) do
    check(build(s[2], A169).h == build(s[2], UNCAP).h, s[1] .. ": 16:9 does not change a short card")
    check(build(s[2], APHI).h == build(s[2], UNCAP).h, s[1] .. ": phi does not change a short card")
    check(build(s[2], UNCAP).h < CAP_169, s[1] .. ": naturally below both ceilings")
end
-- Explicit px override wins over the aspect.
check(build(movie_tall, { card_max_height = 450 }).h <= 450, "movie-tall: explicit card_max_height=450 honoured")
check(build(movie_tall, { card_max_height = 450, card_aspect = "phi" }).h <= 450, "px override beats card_aspect")
-- 'off' truly disables the cap.
check(build(movie_tall, { card_aspect = "off" }).h > CAP_PHI, "card_aspect=off => uncapped")
-- Live-TV: 16:9 within bound, up-next trimmed, pinned row kept.
check(build(livetv_tall, UNCAP).h > CAP_169, "livetv-tall: uncapped overflows")
check(build(livetv_tall, A169).h <= CAP_169, "livetv-tall: 16:9 within bound")
check(ass(livetv_tall, A169):find("1c&HFFFFFF&", 1, true) ~= nil, "livetv-tall: pinned 'Next' row kept")

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
