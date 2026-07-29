-- Standalone unit test for the PURE parts of fanart.lua (build_url + parse + pick).
-- No network, no mpv. Stubs the mpv modules util.lua pulls in at require time.
--   run:  luajit tests/test_fanart.lua   (from the repo root)
local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function() return noop end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return noop end
package.path = "scripts/spincard/?.lua;" .. package.path
local fanart = require("fanart")

local fails = 0
local function check(name, got, want)
    if got ~= want then
        fails = fails + 1
        print(string.format("FAIL %s\n     got:  %s\n     want: %s", name, tostring(got), tostring(want)))
    else
        print("ok   " .. name)
    end
end

-- ---- build_url --------------------------------------------------------------
fanart.init({ fanart_tv_api_key = "" })
check("no key => nil url", fanart.build_url({ id = 120 }), nil)

fanart.init({ fanart_tv_api_key = "KEY123" })
check("tmdb id preferred", fanart.build_url({ id = 120, imdb_id = "tt0120737" }),
    "https://webservice.fanart.tv/v3/movies/120?api_key=KEY123")
check("imdb fallback", fanart.build_url({ imdb_id = "tt0120737" }),
    "https://webservice.fanart.tv/v3/movies/tt0120737?api_key=KEY123")
check("no id => nil", fanart.build_url({}), nil)

-- ---- parse / pick -----------------------------------------------------------
local resp = {
    moviedisc = {
        { url = "https://assets.fanart.tv/disc_fr.png", lang = "fr", likes = "50" },
        { url = "https://assets.fanart.tv/disc_en.png", lang = "en", likes = "3" },
        { url = "https://assets.fanart.tv/disc_neutral.png", lang = "00", likes = "99" },
    },
    moviebanner = {
        { url = "https://assets.fanart.tv/banner_a.jpg", lang = "en", likes = "2" },
        { url = "https://assets.fanart.tv/banner_b.jpg", lang = "en", likes = "10" },
    },
    hdmovielogo = { { url = "https://assets.fanart.tv/logo.png", lang = "en", likes = "1" } },
}
local r = fanart.parse(resp)
check("disc prefers en over higher-likes neutral/fr", r.disc, "https://assets.fanart.tv/disc_en.png")
check("banner ties broken by likes", r.banner, "https://assets.fanart.tv/banner_b.jpg")
check("logo picked", r.logo, "https://assets.fanart.tv/logo.png")

-- neutral-language disc when no en available
local r2 = fanart.parse({ moviedisc = {
    { url = "https://assets.fanart.tv/d_fr.png", lang = "fr", likes = "5" },
    { url = "https://assets.fanart.tv/d_00.png", lang = "00", likes = "1" },
} })
check("no-en disc: neutral beats other-lang", r2.disc, "https://assets.fanart.tv/d_00.png")

check("empty response => nil", fanart.parse({}), nil)
check("non-table => nil", fanart.parse("nope"), nil)

-- ---- fetch_art guards (no network path exercised) ---------------------------
local called
fanart.fetch_art({ kind = "tv", id = 5 }, function(x) called = x end)
check("tv is skipped (movie-only)", called, nil)
called = "unset"
fanart.fetch_art({ kind = "livetv" }, function(x) called = x end)
check("livetv is skipped", called, nil)

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
