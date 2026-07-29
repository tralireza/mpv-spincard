-- Standalone unit test for the PURE parts of omdb.lua (parse_omdb + build_url).
-- No network, no mpv. Stubs the mpv modules util.lua pulls in at require time.
--   run:  luajit tests/test_omdb.lua   (from the repo root)

-- Stub mpv modules so `require "util"` (pulled in by omdb.lua) loads outside mpv.
local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function() return noop end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return noop end

package.path = "scripts/spincard/?.lua;" .. package.path
local omdb = require("omdb")

local fails = 0
local function check(name, got, want)
    if got ~= want then
        fails = fails + 1
        print(string.format("FAIL %s\n     got:  %s\n     want: %s", name, tostring(got), tostring(want)))
    else
        print("ok   " .. name)
    end
end
local function contains(name, s, sub)
    check(name .. " ~ '" .. sub .. "'", (s and s:find(sub, 1, true)) ~= nil, true)
end
local function absent(name, s, sub)
    check(name .. " !~ '" .. sub .. "'", (s and s:find(sub, 1, true)) ~= nil, false)
end

-- parse_omdb -----------------------------------------------------------------
local p = omdb.parse_omdb({ Response = "True", imdbRating = "8.1", imdbVotes = "1,234,567", imdbID = "tt111" })
check("parse rating", p and p.rating, 8.1)
check("parse votes", p and p.votes, 1234567)
check("parse imdb_id", p and p.imdb_id, "tt111")

local pna = omdb.parse_omdb({ Response = "True", imdbRating = "N/A" })
check("parse N/A -> nil", pna, nil)

local pfalse = omdb.parse_omdb({ Response = "False", Error = "Request limit reached!" })
check("parse Response=False -> nil", pfalse, nil)

check("parse nil -> nil", omdb.parse_omdb(nil), nil)

local pnv = omdb.parse_omdb({ Response = "True", imdbRating = "7.0", imdbVotes = "N/A" })
check("parse votes N/A -> nil votes", pnv and pnv.votes, nil)
check("parse rating w/o votes", pnv and pnv.rating, 7.0)

-- extras: Rotten Tomatoes / Metacritic / Awards / Box Office ------------------
local pex = omdb.parse_omdb({
    Response = "True", imdbRating = "7.6", imdbVotes = "1,000",
    Ratings = {
        { Source = "Internet Movie Database", Value = "7.6/10" },
        { Source = "Rotten Tomatoes", Value = "82%" },
        { Source = "Metacritic", Value = "67/100" },
    },
    Metascore = "67", Awards = "Won 3 Oscars. 189 wins & 267 nominations total.",
    BoxOffice = "$785,221,649",
})
check("parse RT", pex and pex.rt, 82)
check("parse MC (from Ratings)", pex and pex.mc, 67)
check("parse awards", pex and pex.awards, "Won 3 Oscars. 189 wins & 267 nominations total.")
check("parse boxoffice", pex and pex.boxoffice, 785221649)

-- MC falls back to the top-level Metascore when Ratings has no Metacritic entry
local pmc = omdb.parse_omdb({ Response = "True", imdbRating = "6.0", Metascore = "45",
    Ratings = { { Source = "Rotten Tomatoes", Value = "50%" } } })
check("parse MC (Metascore fallback)", pmc and pmc.mc, 45)
check("parse RT alongside", pmc and pmc.rt, 50)

-- N/A extras -> nil (best-effort, never a spurious 0)
local pnaex = omdb.parse_omdb({ Response = "True", imdbRating = "5.0",
    Metascore = "N/A", Awards = "N/A", BoxOffice = "N/A" })
check("parse MC N/A -> nil", pnaex and pnaex.mc, nil)
check("parse awards N/A -> nil", pnaex and pnaex.awards, nil)
check("parse boxoffice N/A -> nil", pnaex and pnaex.boxoffice, nil)
check("parse no Ratings -> nil rt", pnaex and pnaex.rt, nil)

-- build_url ------------------------------------------------------------------
omdb.init({ omdb_api_key = "KEY" })

local u1 = omdb.build_url({ imdb_id = "tt111" })
contains("by-id key", u1, "?apikey=KEY")
contains("by-id i", u1, "&i=tt111")
absent("by-id no Season", u1, "Season")

local u2 = omdb.build_url({ imdb_id = "tt222", series = true, season = 2, episode = 5 })
contains("series+S/E i", u2, "&i=tt222")
contains("series+S/E season", u2, "&Season=2")
contains("series+S/E episode", u2, "&Episode=5")

local u3 = omdb.build_url({ imdb_id = "tt333", series = false, season = 2, episode = 5 })
contains("nfo episode tconst by-id", u3, "&i=tt333")
absent("nfo episode tconst no Season", u3, "Season")

local u4 = omdb.build_url({ title = "The Matrix", year = 1999, kind = "movie" })
contains("movie title", u4, "&t=The%20Matrix")
contains("movie year", u4, "&y=1999")
contains("movie type", u4, "&type=movie")

local u5 = omdb.build_url({ title = "Breaking Bad", kind = "tv", season = 1, episode = 3 })
contains("tv title", u5, "&t=Breaking%20Bad")
contains("tv S/E season", u5, "&Season=1")
contains("tv S/E episode", u5, "&Episode=3")

local u6 = omdb.build_url({ title = "Breaking Bad", kind = "tv" })
contains("tv show-level type=series", u6, "&type=series")

check("no id/title -> nil", omdb.build_url({}), nil)

-- empty key => no lookup (never spend a request)
omdb.init({ omdb_api_key = "" })
check("empty key -> nil url", omdb.build_url({ imdb_id = "tt111" }), nil)

print(string.rep("-", 40))
if fails == 0 then print("ALL PASS") else print(fails .. " FAILURE(S)"); os.exit(1) end
