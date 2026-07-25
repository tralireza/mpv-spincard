-- spincard/omdb — IMDb ratings via the OMDb API (https://www.omdbapi.com/).
-- IMDb has no free public API; OMDb is a third-party JSON proxy that returns
-- imdbRating/imdbVotes by IMDb id (tt…) or by title(+year). Pure fetch: returns a
-- { rating, votes, imdb_id } table via callback and never touches script state or
-- the display. Needs opts.omdb_api_key via omdb.init(opts); curl_json + urlencode
-- come from the util module (same async model as tmdb.lua).

local util = require "util"
local curl_json, urlencode = util.curl_json, util.urlencode

local M = {}

local OMDB = "https://www.omdbapi.com/"

local opts = {}
function M.init(o) opts = o end

-- Parse an OMDb response object -> { rating=<0..10>, votes=<num|nil>, imdb_id } or
-- nil. Pure (no network) so it can be unit-tested with a fabricated table. OMDb
-- returns strings: imdbRating "8.0" or "N/A"; imdbVotes "1,234,567" or "N/A";
-- Response "True"/"False". A rate-limit/error still returns valid JSON with
-- Response=="False" (curl exits 0), so this yields nil -> graceful fallback.
local function parse_omdb(d)
    if not d or tostring(d.Response) ~= "True" then return nil end
    local r = tonumber(d.imdbRating) -- "N/A" -> nil
    if not r or r <= 0 then return nil end
    local votes
    if d.imdbVotes and d.imdbVotes ~= "N/A" then
        votes = tonumber((tostring(d.imdbVotes):gsub("[^%d]", ""))) -- "1,234,567" -> 1234567
    end
    return { rating = r, votes = votes, imdb_id = d.imdbID }
end
M.parse_omdb = parse_omdb -- exported for the standalone unit test

-- Build the OMDb query URL from an identity hint, or nil when there's nothing to
-- look up (no key, or neither an IMDb id nor a title). Prefers a known IMDb id
-- (tt…): a .nfo tconst is episode/movie-level so `&i=<id>` returns it directly; a
-- TMDB tconst for TV is the SERIES tconst, so add &Season/&Episode for the episode
-- rating. No id -> title fallback (+year for movies, +Season/Episode for TV).
-- q = { imdb_id, series(bool), title, year, kind, season, episode }
local function build_url(q)
    if not opts.omdb_api_key or opts.omdb_api_key == "" then return nil end
    local base = OMDB .. "?apikey=" .. urlencode(opts.omdb_api_key)
    if q.imdb_id and q.imdb_id ~= "" then
        local url = base .. "&i=" .. urlencode(q.imdb_id)
        if q.series and q.season and q.episode then
            url = url .. "&Season=" .. tonumber(q.season) .. "&Episode=" .. tonumber(q.episode)
        end
        return url
    end
    if q.title and q.title ~= "" then
        local url = base .. "&t=" .. urlencode(q.title)
        if q.kind == "tv" then
            if q.season and q.episode then
                url = url .. "&Season=" .. tonumber(q.season) .. "&Episode=" .. tonumber(q.episode)
            else
                url = url .. "&type=series"
            end
        else
            if q.year and tostring(q.year) ~= "" then url = url .. "&y=" .. tostring(q.year) end
            url = url .. "&type=movie"
        end
        return url
    end
    return nil
end
M.build_url = build_url -- exported for the standalone unit test

-- Async: fetch the IMDb rating for an identity hint. cb(res) with res =
-- { rating, votes, imdb_id } or nil (no key / no id-or-title / N/A / error).
function M.fetch_rating(q, cb)
    local url = build_url(q or {})
    if not url then return cb(nil) end
    curl_json(url, function(d) cb(parse_omdb(d)) end)
end

return M
