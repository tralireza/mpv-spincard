-- spincard/fanart — fanart.tv artwork that the TMDB API does NOT provide: movie DISC
-- art (moviedisc) and BANNER (moviebanner), plus clearlogo/clearart as best-effort
-- extras. Mirrors tmdb.lua / omdb.lua: fanart.init(opts), fetch_art(query, cb) ->
-- { disc, banner, logo, clearart } of image URLs | nil, over the shared curl_json.
--
-- Needs a free fanart.tv project API key (opts.fanart_tv_api_key). Movies are looked
-- up by TMDB id OR IMDb tconst (the /movies endpoint accepts either). TV is skipped:
-- fanart.tv's TV endpoint keys on a TheTVDB id, which the card doesn't carry.
--
-- The returned values are absolute https://assets.fanart.tv/... image URLs (no key in
-- them); images.fetch_url downloads them into the same disk cache as the TMDB art and
-- hands the local path to disc_decode / banner_decode.
local util = require("util")
local msg = require("mp.msg")

local M = {}
local opts = {}
function M.init(o) opts = o end

local BASE = "https://webservice.fanart.tv/v3/movies/"

-- Pick the best URL from a fanart.tv artwork array: prefer English, then language-neutral
-- (disc art is often lang "00"/""), then anything; tie-break by community "likes".
local function pick(arr)
    if type(arr) ~= "table" then return nil end
    local best, bestscore
    for _, e in ipairs(arr) do
        if type(e) == "table" and e.url and e.url ~= "" then
            local lang = e.lang or ""
            local langscore = (lang == "en") and 2 or ((lang == "" or lang == "00") and 1 or 0)
            local score = langscore * 100000 + (tonumber(e.likes) or 0)
            if not bestscore or score > bestscore then best, bestscore = e.url, score end
        end
    end
    return best
end

-- Build the /movies/<id> lookup URL, or nil if no key / no usable id. Prefers the TMDB
-- id; falls back to the IMDb tconst (both accepted by the movies endpoint).
function M.build_url(query)
    local key = opts.fanart_tv_api_key
    if not key or key == "" then return nil end
    local id = query and (query.id or query.imdb_id)
    if not id or id == "" then return nil end
    return BASE .. tostring(id) .. "?api_key=" .. key
end

-- Parse a fanart.tv movie response -> best-effort { disc, banner, logo, clearart }.
-- Returns nil when nothing usable is present (so callers can no-op cleanly).
function M.parse(j)
    if type(j) ~= "table" then return nil end
    local r = {
        disc     = pick(j.moviedisc),
        banner   = pick(j.moviebanner),
        logo     = pick(j.hdmovielogo) or pick(j.movielogo),
        clearart = pick(j.hdmovieclearart) or pick(j.movieart),
    }
    if not (r.disc or r.banner or r.logo or r.clearart) then return nil end
    return r
end

-- query = { id = <tmdb id>, imdb_id = <tt...>, kind = "movie"|... }. cb(res|nil).
function M.fetch_art(query, cb)
    if type(query) ~= "table" then return cb(nil) end
    -- movie-only: fanart.tv TV needs a TVDB id we don't have (a promoted "unknown" is a
    -- best-effort movie, so allow it; skip explicit tv / live-TV).
    if query.kind == "tv" or query.kind == "livetv" then return cb(nil) end
    local url = M.build_url(query)
    if not url then return cb(nil) end
    util.curl_json(url, function(j)
        cb(M.parse(j))
    end)
end

return M
