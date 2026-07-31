-- LEAN card (the toggle-lean key): verify lean_hide gates each block, that hiding a block
-- takes its leading spacing bump with it (no dead whitespace), that the progress row is NOT
-- part of the `tech` block, and that a deps stub WITHOUT a `lean` getter still renders the
-- full card. Stubs mpv; no network, no ffmpeg.
--   run:  luajit tests/test_lean_card.lua   (from the repo root)

local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function()
    -- numbers for the progress-row props so the footer actually renders
    local props = { ["percent-pos"] = 42, ["time-pos"] = 1200, ["time-remaining"] = 1800 }
    return setmetatable({
        get_property_number = function(k) return props[k] end,
        get_property = function() return nil end,
    }, { __index = function() return function() return nil end end })
end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return { parse_json = function() end, format_json = function() end } end
package.path = "scripts/spincard/?.lua;" .. package.path
local card = require("card")

-- card_aspect="off": no height ceiling, so the per-block height deltas below are exact.
local base_opts = {
    pos_x = 22, pos_y = 22, anchor = "bottom", card_aspect = "off", card_max_height = 0,
    overview_lines = 6, overview_scroll = false, imdb_votes = true, show_tech = true,
    cast_scroll = false, cast_max = 5, cast_cols = 2, cast_lines = 2, cast_fs = 21,
    cast_bold = true, cast_scroll_dir = "horizontal", cast_scroll_px = 3,
    logo_height = 0.12, signal_dbm_max = -40.6, live_signal = false,
    live_upcoming_delay = 3, live_upcoming_lines = 3, live_upcoming_secs = 1.5,
    lean_hide = "",
}
local function O(over)
    local o = {}
    for k, v in pairs(base_opts) do o[k] = v end
    for k, v in pairs(over or {}) do o[k] = v end
    return o
end

local LEAN = true -- flipped per-build by build()/build_full()
local deps = {
    anim_fade = function() return 1 end, cur_signal = function() return nil end,
    cast_idx = function() return 0 end, overview_idx = function() return 0 end,
    upnext_idx = function() return 0 end, casthead_active = function() return false end,
    lean = function() return LEAN end,
    tech = function()
        return { vwidth = 1920, hdr = "HDR10", vcodec = "ZVCODECZ", acodec = "EAC3",
                 achan = "5.1", fps = "24", audio = "ZAUDIOZ", subs = "English",
                 chapters = 12, size = "4.2 GiB" }
    end,
}
-- deps WITHOUT a lean getter — mirrors the four pre-existing build_card tests
local deps_nolean = {}
for k, v in pairs(deps) do deps_nolean[k] = v end
deps_nolean.lean = nil

-- build(c, hide) => ass, height   (LEAN on). build_full(c, hide) => same with LEAN off.
local function raw(c, hide, isLean, d)
    LEAN = isLean
    card.init(O{ lean_hide = hide or "" }, d or deps)
    local a, _, r = card.build_card(c)
    return a, r.h
end
local function build(c, hide) return raw(c, hide, true) end
local function build_full(c, hide) return raw(c, hide, false) end

-- Fixture: one unique marker per block so a substring test can't cross-match.
-- rating_imdb is outside [5,7.5) on purpose — the mid-tier star colour is also 18C5F5,
-- the same BGR as the IMDb pill, so a mid-tier score makes the pill test a false match.
local MOVIE = {
    kind = "movie", title = "A Movie", year = "2025", tagline = "ZTAGZ",
    genres = { "ZGENREZ" }, awards = "Won ZAWARDZ Oscars. Another 12 wins.",
    overview = "ZOVWZ opens the plot and then keeps going for a while so it wraps.",
    cast = { { name = "ZCASTZ", role = "Hero" } },
    runtime = 192, mpaa = "ZCERTZ", boxoffice = 785000000,
    director = "ZDIRZ", studio = "ZSTUDIOZ",
    rating = 7.8, rating_src = "TMDB", rating_imdb = 8.1, rating_imdb_votes = 1200000,
    rt = 82, mc = 67,
}
local TV = {
    kind = "tv", title = "A Series", year = "2025", season = 3, episode = 12,
    episode_title = "An Episode", ep_total = 24, tagline = "ZTAGZ",
    genres = { "ZGENREZ" }, aired = "2025-04-01", runtime = 48, mpaa = "ZCERTZ",
    overview = "ZOVWZ the episode synopsis.", cast = { { name = "ZCASTZ", role = "Hero" } },
    rating_imdb = 8.1, director = "ZDIRZ", studio = "ZSTUDIOZ",
}
local LIVE = { kind = "livetv", title = "A Programme", channel = "{@}Channel HD",
    subtitle = "Ep subtitle", overview = "ZOVWZ the live synopsis." }
local NOEPG = { kind = "livetv", no_epg = true, channel = "{@}Channel HD",
    upcoming = { { title = "Next thing", start = os.time() + 900 } } }

-- name -> marker(s) that must vanish when that name is hidden
local BLOCKS = {
    { "overview", { "ZOVWZ" } },
    { "tagline",  { "ZTAGZ" } },
    { "cast",     { "ZCASTZ" } },
    { "tech",     { "ZVCODECZ", "ZAUDIOZ" } },
    { "genres",   { "ZGENREZ" } },
    { "awards",   { "ZAWARDZ" } },
    { "rating",   { "IMDb", "RT 82%", "MC 67" } },
    { "meta",     { "ZCERTZ", "$785M" } },
}
local ALL = "overview,tagline,cast,tech,genres,awards,rating,meta"
local PROGRESS = "20:00 / 50:00" -- fmt_duration(1200) / fmt_duration(1200+1800)

local fails = 0
local function ok(cond, label)
    if cond then io.write("  ok    " .. label .. "\n")
    else io.write("  FAIL  " .. label .. "\n"); fails = fails + 1 end
end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

io.write("1. lean_hide never leaks into the FULL card\n")
do
    local full_a, full_h = build_full(MOVIE, "")
    local a, h = build_full(MOVIE, ALL)
    ok(a == full_a and h == full_h, "LEAN off + lean_hide=all => byte-identical to lean_hide=''")
end

io.write("\n2. hide/keep matrix (hiding X removes only X)\n")
for _, b in ipairs(BLOCKS) do
    local name, marks = b[1], b[2]
    local a = build(MOVIE, name)
    for _, m in ipairs(marks) do ok(not has(a, m), name .. ": '" .. m .. "' gone") end
    for _, other in ipairs(BLOCKS) do
        if other[1] ~= name then
            for _, m in ipairs(other[2]) do
                ok(has(a, m), name .. ": kept " .. other[1] .. " '" .. m .. "'")
            end
        end
    end
end

io.write("\n3. the progress row is NOT part of `tech`\n")
do
    local a = build(MOVIE, "tech")
    ok(not has(a, "ZVCODECZ") and not has(a, "ZAUDIOZ"), "tech: pills + tech line gone")
    ok(has(a, PROGRESS), "tech: progress row survives")
    ok(has(build(MOVIE, ALL), PROGRESS), "everything hidden: progress row still drawn")
    ok(has(build(MOVIE, ALL), "A Movie"), "everything hidden: title still drawn")
end

io.write("\n4. no dead whitespace (exact height deltas; a stranded cy bump shows up here)\n")
do
    local _, h0 = build(MOVIE, "")
    local function delta(hide) local _, h = build(MOVIE, hide); return h0 - h end
    -- line() advances floor(fs*1.25); the leading bumps are +4 (genre row) / +6 / +8.
    ok(delta("tagline") == 26, "tagline delta 26 (got " .. delta("tagline") .. ")")
    ok(delta("rating") == 28, "rating delta 28 (got " .. delta("rating") .. ")")
    ok(delta("meta") == 26, "meta delta 26 (got " .. delta("meta") .. ")")
    ok(delta("genres") == 0, "genres alone: 0 — the award keeps the row (got " .. delta("genres") .. ")")
    ok(delta("genres,awards") == 30, "genres+awards delta 30 = 4+26 (got " .. delta("genres,awards") .. ")")
    ok(delta("tech") == 62, "tech delta 62 = (8+26)+(6+22) (got " .. delta("tech") .. ")")
    ok(delta("cast") == 30, "cast delta 30 = 4+26 (got " .. delta("cast") .. ")")
    local dov = delta("overview")
    ok(dov > 6 and (dov - 6) % 26 == 0, "overview delta = 6 + N*26 (got " .. dov .. ")")
    -- additivity: independent blocks, no bump counted twice
    local sum = delta("tagline") + delta("rating") + delta("meta") + delta("genres,awards")
        + delta("tech") + delta("cast") + dov
    ok(sum == delta(ALL), "sum of deltas " .. sum .. " == all-hidden delta " .. delta(ALL))
end

io.write("\n4b. hiding `meta` gives a movie its year back in the heading\n")
do
    -- the movie heading deliberately omits the year (it's bold-folded into the meta row),
    -- so without the fallback `lean_hide=meta` would lose it on movies only.
    ok(not has(build(MOVIE, ""), "A Movie  (2025)"), "full card: year is NOT in the heading")
    ok(has(build(MOVIE, "meta"), "A Movie  (2025)"), "meta hidden: year returns to the heading")
    ok(has(build(TV, "meta"), "A Series  (2025)"), "TV keeps its heading year either way")
end

io.write("\n5. live TV\n")
do
    ok(has(build(LIVE, ""), "ZOVWZ"), "live: synopsis present by default")
    ok(not has(build(LIVE, "overview"), "ZOVWZ"), "live: `overview` hides the synopsis")
    local n0, h0 = build(NOEPG, "")
    local n1, h1 = build(NOEPG, "overview")
    ok(has(n0, "[No program information]"), "no_epg: placeholder present by default")
    ok(not has(n1, "[No program information]"), "no_epg: `overview` hides the placeholder")
    ok(h0 - h1 == 32, "no_epg: placeholder delta 32 = 6+26 (got " .. (h0 - h1) .. ")")
    ok(has(n1, "Channel HD"), "no_epg: channel heading kept")
    ok(has(n1, "Next in"), "no_epg: countdown caption kept")
end

io.write("\n6. the TV genre+meta row: genres and meta are independent\n")
do
    local both = build(TV, "")
    ok(has(both, "ZGENREZ") and has(both, "ZCERTZ"), "TV: genres + meta share the row")
    local ng = build(TV, "genres")
    ok(not has(ng, "ZGENREZ") and has(ng, "ZCERTZ"), "TV: hide genres => meta survives")
    -- with no genres the meta falls back to the LEFT edge (\an7 at x+pad = 22+24 = 46)
    ok(ng:find("\\an7\\pos(46,", 1, true) ~= nil, "TV: meta moves to the left edge")
    local nm = build(TV, "meta")
    ok(has(nm, "ZGENREZ") and not has(nm, "ZCERTZ"), "TV: hide meta => genres survive")
    local _, hb = build(TV, "")
    local _, hn = build(TV, "genres,meta")
    ok(hb - hn == 30, "TV: hiding both drops the row + its 4px bump (30, got " .. (hb - hn) .. ")")
    ok(has(nm, "S03E12"), "TV: the SxxEyy subline is never hideable")
end

io.write("\n7. lean_hide parsing\n")
do
    local a = build(MOVIE, " Overview , CAST ")
    ok(not has(a, "ZOVWZ") and not has(a, "ZCASTZ"), "spaces + mixed case + spaced commas")
    local b = build(MOVIE, "overview cast")
    ok(not has(b, "ZOVWZ") and not has(b, "ZCASTZ"), "whitespace-separated")
    local c2 = build(MOVIE, "overview,,cast,")
    ok(not has(c2, "ZOVWZ") and not has(c2, "ZCASTZ"), "empty fields tolerated")
    local d = build(MOVIE, "bogus")
    ok(has(d, "ZOVWZ") and has(d, "ZCASTZ"), "unknown names ignored")
    ok(build(MOVIE, "") == build_full(MOVIE, ""), "lean_hide='' => identical to the full card")
    -- memo is keyed on the raw string, so alternating values must not go stale
    local want_cast, want_ovw = build(MOVIE, "cast"), build(MOVIE, "overview")
    ok(build(MOVIE, "cast") == want_cast and build(MOVIE, "overview") == want_ovw
        and build(MOVIE, "cast") == want_cast, "memo re-parses when lean_hide changes")
end

io.write("\n8. a deps stub with no `lean` getter renders the FULL card\n")
do
    local a = raw(MOVIE, ALL, true, deps_nolean)
    local full = build_full(MOVIE, "")
    ok(a == full, "deps.lean == nil => byte-identical to the full card")
end

io.write("\n9. card.lean_hidden export (main.lua gates its marquee timers on it)\n")
do
    card.init(O{ lean_hide = "cast, overview" }, deps)
    ok(card.lean_hidden("cast") and card.lean_hidden("overview"), "listed names report hidden")
    ok(not card.lean_hidden("tech") and not card.lean_hidden("bogus"), "others report visible")
    card.init(O{ lean_hide = "" }, deps)
    ok(not card.lean_hidden("cast"), "empty lean_hide hides nothing")
end

io.write(fails == 0 and "\nALL PASS\n" or ("\n" .. fails .. " FAILURE(S)\n"))
os.exit(fails == 0 and 0 or 1)
