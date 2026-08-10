-- Font-size audit: build all 4 card kinds and extract the \fs of each text element
-- (via marker text) so we can see which sizes differ across movie/tv/livetv/unknown.
--   run:  luajit tests/test_card_fonts.lua
local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function() return setmetatable({}, { __index = function() return function() return nil end end }) end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return { parse_json = function() end, format_json = function() end } end
package.path = "scripts/spincard/?.lua;" .. package.path
local card = require("card")

local opts = {
    pos_x = 40, pos_y = 40, disc_size = 0.4, anchor = "bottom",
    overview_lines = 4, overview_scroll = false, imdb_votes = true,
    show_tech = false, cast_scroll = false, cast_max = 5, cast_cols = 2,
    cast_lines = 2, cast_fs = 21, cast_bold = true, cast_scroll_dir = "horizontal",
    cast_scroll_px = 3, logo_height = 0.1, signal_dbm_max = -40.6,
    live_upcoming_delay = 3, live_upcoming_lines = 3, live_upcoming_secs = 1.5,
}
card.init(opts, {
    anim_fade = function() return 1 end, cur_signal = function() return nil end,
    cast_idx = function() return 0 end, overview_idx = function() return 0 end,
    upnext_idx = function() return 0 end, tech = function() return {} end,
})

-- find the \fs immediately preceding a marker substring in the ASS output
local function fs_of(ass, marker)
    local fs = ass:match("\\fs(%d+)[^}]*}[^{]-" .. marker)
    return fs and tonumber(fs) or nil
end

local common = {
    tagline = "ZTAGZ tagline text", genres = { "ZGENREZ" },
    cast = { { name = "ZCASTZ", role = "Role" } },
    overview = "ZOVWZ a synopsis sentence that is long enough to render on its own line.",
    rating = 7.8, rating_src = "TMDB", director = "ZDIRZ", studio = "Studio",
}
local function mk(t) local c = {}; for k, v in pairs(common) do c[k] = v end; for k, v in pairs(t) do c[k] = v end; return c end

local cards = {
    movie   = mk{ kind = "movie", title = "ZTITLEZ Movie", year = "2025" },
    tv      = mk{ kind = "tv", title = "ZTITLEZ Show", year = "2025", season = 1, episode = 2,
                  episode_title = "ZEPZ Episode", ep_total = 10 },
    livetv  = mk{ kind = "livetv", title = "ZTITLEZ Prog", channel = "ZCHANZ", subtitle = "ZSUBZ sub" },
    -- a LONG dotted release name, so the audit actually exercises heading()'s
    -- 38 -> 28 font drop (the short "ZTITLEZ file.mkv" never tripped it)
    unknown = mk{ kind = "unknown", title = "ZTITLEZ.01.Isle.of.Man.TT.2026x03.RST.Superbike.TT.mp4" },
}

local elems = { "ZTAGZ", "ZGENREZ", "ZCASTZ", "ZOVWZ", "ZEPZ", "ZSUBZ" }
io.write(string.format("%-10s", "kind"))
for _, e in ipairs(elems) do io.write(string.format("%-9s", e:gsub("Z", ""))) end
io.write("\n" .. string.rep("-", 10 + 9 * #elems) .. "\n")
for _, k in ipairs({ "movie", "tv", "livetv", "unknown" }) do
    local ass = card.build_card(cards[k])
    io.write(string.format("%-10s", k))
    for _, e in ipairs(elems) do
        local fs = fs_of(ass, e)
        io.write(string.format("%-9s", fs and tostring(fs) or "-"))
    end
    io.write("\n")
end
