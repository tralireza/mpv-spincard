-- Artwork discovery: sidecar.find_poster + images.find_fanart/banner/clearlogo/disc,
-- over a virtual readdir. No mpv, network or filesystem.
--   run:  luajit tests/test_artfind.lua   (from the repo root)
--
-- Every fixture was confirmed FAILING pre-fix; one that already passed would be
-- decoration. The Windows cases are issue #1 (backslash path -> dir ".", nothing
-- found whatever the naming, which is why the reporter's renaming never helped).

local noop = setmetatable({}, { __index = function() return function() end end })

-- <dir> -> { "Real Name.jpg", ... }. Both counters are asserted at the end.
local FS, readdirs, file_infos = {}, 0, 0
local utils_stub = setmetatable({
    readdir = function(dir, _) readdirs = readdirs + 1; return FS[dir] end,
    file_info = function(_) file_infos = file_infos + 1; return nil end,
}, { __index = function() return function() end end })

package.preload["mp"] = function() return noop end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return utils_stub end
package.path = "scripts/spincard/?.lua;" .. package.path

local real_execute = os.execute
os.execute = function() return true end -- images.lua mkdir_p's its image cache at require time
local sidecar = require("sidecar")
local images  = require("images")
os.execute = real_execute

local fails = 0
local function check(name, got, want)
    if got ~= want then
        fails = fails + 1
        print(string.format("FAIL %s\n     got:  %s\n     want: %s", name, tostring(got), tostring(want)))
    else
        print("ok   " .. name)
    end
end

-- Swap the virtual filesystem and drop the directory index between fixtures.
local function fs(t) FS = t; sidecar.dir_cache_reset(); readdirs, file_infos = 0, 0 end

local MOVIE = { kind = "movie" }
local TV1   = { kind = "tv", season = 1 }

-- ---- Windows paths: the reported bug ----------------------------------------
local WD = "D:\\Movies\\Foo (2019)"
fs({ [WD] = { "poster.jpg", "fanart.jpg", "banner.jpg", "clearlogo.png", "disc.png" } })
local wp = WD .. "\\Foo (2019).mkv"
check("win: poster",    sidecar.find_poster(wp, MOVIE),   WD .. "\\poster.jpg")
check("win: fanart",    images.find_fanart(wp, MOVIE),    WD .. "\\fanart.jpg")
check("win: banner",    images.find_banner(wp, MOVIE),    WD .. "\\banner.jpg")
check("win: clearlogo", images.find_clearlogo(wp, MOVIE), WD .. "\\clearlogo.png")
check("win: disc",      images.find_disc(wp, MOVIE),      WD .. "\\disc.png")

-- The reporter's own naming, in a shared Movies folder, on Windows.
local WD2 = "D:\\Movies"
fs({ [WD2] = { "Foo (2019)-cover.jpg", "Foo (2019)-fanart.jpg" } })
local wp2 = WD2 .. "\\Foo (2019).mkv"
check("win: <file>-cover",  sidecar.find_poster(wp2, MOVIE), WD2 .. "\\Foo (2019)-cover.jpg")
check("win: <file>-fanart", images.find_fanart(wp2, MOVIE),  WD2 .. "\\Foo (2019)-fanart.jpg")

-- ---- Kodi "movie in a shared folder" naming ---------------------------------
fs({ ["/m/Movies"] = { "Arrival (2016)-poster.jpg", "poster.jpg" } })
check("<file>-poster outranks generic poster",
    sidecar.find_poster("/m/Movies/Arrival (2016).mkv", MOVIE),
    "/m/Movies/Arrival (2016)-poster.jpg")

-- ---- Case-insensitive matching + png ----------------------------------------
fs({ ["/m/A"] = { "Fanart.JPG", "Poster.PNG" } })
check("mixed-case fanart", images.find_fanart("/m/A/A.mkv", MOVIE),  "/m/A/Fanart.JPG")
check("png poster",        sidecar.find_poster("/m/A/A.mkv", MOVIE), "/m/A/Poster.PNG")

-- ---- New names --------------------------------------------------------------
fs({ ["/m/D"] = { "D-banner.jpg", "D-clearlogo.png", "discart.png" } })
check("<file>-banner",    images.find_banner("/m/D/D.mkv", MOVIE),    "/m/D/D-banner.jpg")
check("<file>-clearlogo", images.find_clearlogo("/m/D/D.mkv", MOVIE), "/m/D/D-clearlogo.png")
check("discart alias",    images.find_disc("/m/D/D.mkv", MOVIE),      "/m/D/discart.png")

-- ---- Deliberate NON-change: clearlogo/disc need alpha, so jpg must not match -
fs({ ["/m/C"] = { "clearlogo.jpg", "disc.jpg", "discart.jpg" } })
check("clearlogo rejects jpg", images.find_clearlogo("/m/C/C.mkv", MOVIE), nil)
check("disc rejects jpg",      images.find_disc("/m/C/C.mkv", MOVIE),      nil)

-- ---- Regression: the layouts that already worked ----------------------------
fs({ ["/m/B"] = { "poster.jpg", "fanart.jpg", "backdrop.jpg", "folder.jpg" } })
check("own-folder poster",     sidecar.find_poster("/m/B/B.mkv", MOVIE), "/m/B/poster.jpg")
check("fanart before backdrop", images.find_fanart("/m/B/B.mkv", MOVIE), "/m/B/fanart.jpg")

fs({
    ["/tv/Show/Season 01"] = { "Show.S01E02-thumb.jpg", "Show.S01E02.mkv" },
    ["/tv/Show"]           = { "season01-poster.jpg", "poster.jpg", "fanart.jpg" },
})
local tvp = "/tv/Show/Season 01/Show.S01E02.mkv"
check("tv: episode thumb wins", sidecar.find_poster(tvp, TV1),
    "/tv/Show/Season 01/Show.S01E02-thumb.jpg")
check("tv: fanart from show root", images.find_fanart(tvp, TV1), "/tv/Show/fanart.jpg")

fs({
    ["/tv/S2/Season 03"] = { "S2.S03E01.mkv" },
    ["/tv/S2"]           = { "poster.jpg", "season03-poster.jpg" },
})
check("tv: season poster outranks show poster",
    sidecar.find_poster("/tv/S2/Season 03/S2.S03E01.mkv", { kind = "tv", season = 3 }),
    "/tv/S2/season03-poster.jpg")

-- ---- Non-local paths are skipped entirely (live TV re-runs this per zap) -----
fs({})
local url = "http://127.0.0.1:9981/stream/channel/abcdef"
check("url: no poster", sidecar.find_poster(url, { kind = "livetv" }), nil)
check("url: no fanart", images.find_fanart(url, { kind = "livetv" }), nil)
check("url: no disc",   images.find_disc(url, { kind = "livetv" }),   nil)
check("url: zero readdir", readdirs, 0)

-- ---- One directory listing serves every finder ------------------------------
fs({ ["/m/E"] = { "poster.jpg" } })
local ep = "/m/E/E.mkv"
sidecar.find_poster(ep, MOVIE)
images.find_fanart(ep, MOVIE)
images.find_banner(ep, MOVIE)
images.find_clearlogo(ep, MOVIE)
images.find_disc(ep, MOVIE)
sidecar.dir_has_image(ep)
check("one readdir serves all five finders + dir_has_image", readdirs, 1)
check("discovery makes no per-candidate stat calls", file_infos, 0) -- pre-fix: 9

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
