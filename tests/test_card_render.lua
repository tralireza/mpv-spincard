-- Headless render check for card.build_card: stub mpv, feed a movie card with the
-- new OMDb extras (rt/mc/awards/boxoffice) and assert they reach the ASS output.
--   run:  luajit tests/test_card_render.lua   (from the repo root)

local noop = setmetatable({}, { __index = function() return function() end end })
-- mp stub: any method returns nil (get_property/get_property_number/etc.)
package.preload["mp"] = function() return setmetatable({}, { __index = function() return function() return nil end end }) end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return { parse_json = function() end, format_json = function() end } end
package.path = "scripts/spincard/?.lua;" .. package.path

local card = require("card")

local opts = {
    pos_x = 40, pos_y = 40, disc_size = 0.4, anchor = "bottom",
    overview_lines = 4, overview_scroll = false, imdb_votes = true,
    show_tech = false, cast_scroll = false, cast_max = 5, cast_cols = 2,
    cast_lines = 2, cast_fs = 20, cast_bold = false, cast_scroll_dir = "horizontal",
    cast_scroll_px = 3, logo_height = 0.1, signal_dbm_max = -40.6,
    live_upcoming_delay = 3, live_upcoming_lines = 3, live_upcoming_secs = 1.5,
}
local casthead_flag = false -- toggled to test the cast-headshots text-suppress path
card.init(opts, {
    anim_fade = function() return 1 end, cur_signal = function() return nil end,
    cast_idx = function() return 0 end, overview_idx = function() return 0 end,
    upnext_idx = function() return 0 end, tech = function() return {} end,
    casthead_active = function() return casthead_flag end,
})

local c = {
    kind = "movie", title = "Avatar: Fire and Ash", year = "2025",
    rating_imdb = 7.6, rating_imdb_votes = 12000, rating = 7.8, rating_src = "TMDB",
    rt = 82, mc = 67, awards = "Won 3 Oscars. 189 wins & 267 nominations total.",
    boxoffice = 785221649,
    overview = "A continuation of the Pandora saga.",
    genres = { "Action", "Adventure" }, runtime = 192, mpaa = "PG-13",
    director = "James Cameron", studio = "20th Century",
    cast = { { name = "ZCASTNAMEZ", role = "Jake" } },
}

local ass = card.build_card(c)
local fails = 0
local function want(label, sub)
    local hit = ass:find(sub, 1, true) ~= nil
    print((hit and "ok   " or "FAIL ") .. label .. "  ~ '" .. sub .. "'")
    if not hit then fails = fails + 1 end
end

local function absent(label, sub)
    local hit = ass:find(sub, 1, true) ~= nil
    print((hit and "FAIL " or "ok   ") .. label .. "  !~ '" .. sub .. "'")
    if hit then fails = fails + 1 end
end

want("RT pill", "RT 82%")
want("MC pill", "MC 67")
want("box office in meta", "$785M")
want("awards leading clause", "Won 3 Oscars")
absent("awards trimmed (tail dropped)", "nominations total")
want("text cast shown when heads inactive", "ZCASTNAMEZ")

-- cast-headshots active → build_card must DROP the text cast
casthead_flag = true
ass = card.build_card(c)
absent("text cast suppressed when heads active", "ZCASTNAMEZ")

-- TV card: genres (bold grey, LEFT) + meta (grey, RIGHT) folded onto ONE row
casthead_flag = false
local tv = { kind = "tv", title = "Show", year = "2020", season = 1, episode = 2,
    genres = { "ZTVGENREZ" }, aired = "2020-05-01", runtime = 47, mpaa = "TV-MA",
    overview = "Plot." }
local tass = card.build_card(tv)
local function ev_pos(a, color, needle) -- \pos(x,y) of the event with `color` containing `needle`
    local x, y = a:match("\\pos%((%-?%d+),(%-?%d+)%)[^{]-1c&H" .. color .. "&[^{]-" .. needle)
    return tonumber(x), tonumber(y)
end
local gx, gy = ev_pos(tass, "DCDCDC", "ZTVGENREZ")
local mx, my = ev_pos(tass, "B4B4B4", "Aired")
local function check(label, cond) print((cond and "ok   " or "FAIL ") .. label); if not cond then fails = fails + 1 end end
check("TV genre present + meta present", gx ~= nil and mx ~= nil)
check("TV genre + meta on the SAME row", gx ~= nil and mx ~= nil and gy == my)
check("TV genre is LEFT of meta", gx ~= nil and mx ~= nil and gx < mx)

print(string.rep("-", 40))
if fails == 0 then print("ALL PASS") else print(fails .. " FAILURE(S)"); os.exit(1) end
