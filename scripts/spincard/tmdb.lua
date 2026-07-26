-- spincard/tmdb — TMDB lookups: a search hit gives the base card, a follow-up
-- details+credits call enriches it (genres/studio/cast/director/tagline/runtime/
-- certification). Pure fetch: returns cards/field-tables via callbacks and never
-- touches script state or the display. Needs opts (api_key/language/region) via
-- tmdb.init(opts); curl_json + urlencode come from the util module.

local util = require "util"
local curl_json, urlencode = util.curl_json, util.urlencode

local M = {}

local TMDB = "https://api.themoviedb.org/3"

local opts = {}
function M.init(o) opts = o end

-- Certification region: explicit `region` opt, else the country from `language`
-- (en-US -> US, en-GB -> GB); default US.
local function tmdb_region()
    local r = opts.region
    if r and r ~= "" then return r:upper() end
    return (tostring(opts.language):match("[-_](%a%a)$") or "US"):upper()
end

-- Image language: the 2-letter prefix of `language` (en-US -> en); default en.
local function img_lang()
    return (tostring(opts.language):match("^(%a%a)") or "en"):lower()
end
-- include_image_language value so the images block carries the requested language,
-- English, and language-neutral (null) logos/backdrops rather than only `language`.
local function include_lang()
    local l = img_lang()
    return (l == "en") and "en,null" or (l .. ",en,null")
end
-- The `images` append + its include_image_language query param, when remote_art is
-- enabled (else the response stays lean and no logo/backdrop is parsed).
local function images_append() return opts.remote_art and ",images" or "" end
local function images_query()
    return opts.remote_art and ("&include_image_language=" .. include_lang()) or ""
end

-- Map a TMDB details+credits (+release_dates/content_ratings) object to the extra
-- card fields build_card can render: {genres, runtime, tagline, studio, director,
-- cast={name,role}, mpaa}. Pure; a missing sub-object just yields no key.
local function parse_details(kind, d)
    local out = {}
    if not d then return out end
    if type(d.genres) == "table" then
        local g = {}
        for _, x in ipairs(d.genres) do if x.name and x.name ~= "" then g[#g + 1] = x.name end end
        if #g > 0 then out.genres = g end
    end
    if d.tagline and d.tagline ~= "" then out.tagline = d.tagline end
    if kind == "tv" then
        out.runtime = tonumber(d.episode_run_time and d.episode_run_time[1])
        if type(d.networks) == "table" and d.networks[1] then out.studio = d.networks[1].name end
    else
        out.runtime = tonumber(d.runtime)
        if type(d.production_companies) == "table" and d.production_companies[1] then
            out.studio = d.production_companies[1].name
        end
    end
    local cr = d.credits
    if type(cr) == "table" then
        if type(cr.cast) == "table" and #cr.cast > 0 then
            local cast = {}
            for _, p in ipairs(cr.cast) do cast[#cast + 1] = p end
            table.sort(cast, function(a, b) return (a.order or 999) < (b.order or 999) end)
            -- keep the top max(cast_max, casthead_max) (already order-sorted) so the
            -- cached JSON isn't bloated with 30+ people build_card never shows, yet the
            -- scrolling headshot strip (casthead_style=scroll) has its full pool. Trade-off:
            -- raising either cap later needs a refetch (clear the cache) to pull more.
            local nmax = math.max(1, tonumber(opts.cast_max) or 5, tonumber(opts.casthead_max) or 5)
            local out_cast = {}
            for _, p in ipairs(cast) do
                if p.name and p.name ~= "" then
                    out_cast[#out_cast + 1] = {
                        name = p.name,
                        role = (p.character and p.character ~= "") and p.character or nil,
                        -- profile_path (headshot) for the cast-headshots strip; TMDB
                        -- returns it in the credits block. Just the path, like poster/logo.
                        profile = (p.profile_path and p.profile_path ~= "") and p.profile_path or nil,
                    }
                    if #out_cast >= nmax then break end
                end
            end
            if #out_cast > 0 then out.cast = out_cast end
        end
        if type(cr.crew) == "table" then
            for _, p in ipairs(cr.crew) do
                if p.job == "Director" and p.name then out.director = p.name; break end
            end
        end
    end
    local region = tmdb_region()
    if kind == "movie" and type(d.release_dates) == "table" and type(d.release_dates.results) == "table" then
        for _, rr in ipairs(d.release_dates.results) do
            if rr.iso_3166_1 == region and type(rr.release_dates) == "table" then
                for _, rd in ipairs(rr.release_dates) do
                    if rd.certification and rd.certification ~= "" then out.mpaa = rd.certification; break end
                end
            end
            if out.mpaa then break end
        end
    elseif kind == "tv" and type(d.content_ratings) == "table" and type(d.content_ratings.results) == "table" then
        for _, rr in ipairs(d.content_ratings.results) do
            if rr.iso_3166_1 == region and rr.rating and rr.rating ~= "" then out.mpaa = rr.rating; break end
        end
    end
    -- Clearlogo (TMDB-hosted title art): prefer a logo in the requested language,
    -- then English, then language-neutral; skip SVG (the ffmpeg decode can't
    -- rasterise it). Only the file_path is kept — main builds the CDN URL.
    if type(d.images) == "table" and type(d.images.logos) == "table" then
        local want, best, bestscore = img_lang(), nil, -1
        for _, L in ipairs(d.images.logos) do
            local fp = L.file_path
            if fp and not fp:lower():find("%.svg$") then
                local s = (L.iso_639_1 == want and 3) or (L.iso_639_1 == "en" and 2)
                    or ((L.iso_639_1 == nil or L.iso_639_1 == "") and 1) or 0
                s = s + (tonumber(L.vote_average) or 0) / 100 -- tiebreak by popularity
                if s > bestscore then best, bestscore = fp, s end
            end
        end
        out.logo_path = best
    end
    -- IMDb id (tconst) for the IMDb/OMDb rating lookup: TV -> external_ids gives the
    -- SERIES tconst; movie details returns imdb_id at the top level.
    if kind == "tv" then
        if type(d.external_ids) == "table" and d.external_ids.imdb_id and d.external_ids.imdb_id ~= "" then
            out.imdb_id = d.external_ids.imdb_id
        end
    elseif d.imdb_id and d.imdb_id ~= "" then
        out.imdb_id = d.imdb_id
    end
    return out
end

-- Overwrite card fields with the non-nil fields of `extra` (search card -> rich).
local function overlay_fields(card, extra)
    for k, v in pairs(extra) do card[k] = v end
end

-- Details by TMDB id (no search) -> parse_details fields (+ rating). Used to
-- supplement a local .nfo that carries a <uniqueid> tmdb id.
function M.tmdb_details(kind, tmdb_id, cb)
    local lang = "&language=" .. urlencode(opts.language)
    local path = (kind == "tv") and "tv" or "movie"
    local append = ((kind == "tv") and "credits,content_ratings,external_ids"
        or "credits,release_dates,external_ids") .. images_append()
    local url = string.format("%s/%s/%s?api_key=%s%s&append_to_response=%s%s",
        TMDB, path, tostring(tmdb_id), opts.api_key, lang, append, images_query())
    curl_json(url, function(d)
        if not d or d.success == false then return cb(nil) end
        local out = parse_details(kind, d)
        if d.vote_average and d.vote_average > 0 then out.rating = d.vote_average end
        cb(out)
    end)
end

-- id -> metadata card (no local/tech fields; those are merged at show time).
-- A search hit gives the base card (title/year/rating/overview/poster); a
-- follow-up details+credits call overlays genres/studio/cast/director/tagline/
-- runtime/certification. A details failure keeps the base card intact.
function M.tmdb_fetch(id, cb)
    local lang = "&language=" .. urlencode(opts.language)
    if id.kind == "tv" then
        local url = string.format("%s/search/tv?api_key=%s&query=%s%s",
            TMDB, opts.api_key, urlencode(id.query), lang)
        curl_json(url, function(d)
            local r = d and d.results and d.results[1]
            if not r then return cb(nil) end
            local card = {
                kind = "tv", title = r.name, source = "TMDB",
                year = (r.first_air_date or ""):sub(1, 4),
                rating = r.vote_average, overview = r.overview,
                poster = r.poster_path, backdrop = r.backdrop_path,
                season = id.season, episode = id.episode,
            }
            if not r.id then return cb(card) end
            local durl = string.format("%s/tv/%d?api_key=%s%s&append_to_response=credits,content_ratings,external_ids%s%s",
                TMDB, r.id, opts.api_key, lang, images_append(), images_query())
            curl_json(durl, function(dd)
                overlay_fields(card, parse_details("tv", dd))
                if id.season and id.episode then
                    local eurl = string.format("%s/tv/%d/season/%d/episode/%d?api_key=%s%s",
                        TMDB, r.id, id.season, id.episode, opts.api_key, lang)
                    curl_json(eurl, function(e)
                        if e and e.name then
                            card.episode_title = e.name
                            if e.overview and e.overview ~= "" then card.overview = e.overview end
                            if e.vote_average and e.vote_average > 0 then card.rating = e.vote_average end
                            if e.air_date and e.air_date ~= "" then card.air_date = e.air_date end
                            if type(e.runtime) == "number" and e.runtime > 0 then card.runtime = e.runtime end
                            if type(e.crew) == "table" then -- episode director beats show-level
                                for _, p in ipairs(e.crew) do
                                    if p.job == "Director" and p.name then card.director = p.name; break end
                                end
                            end
                        end
                        cb(card)
                    end)
                else
                    cb(card)
                end
            end)
        end)
    else
        local url = string.format("%s/search/movie?api_key=%s&query=%s%s",
            TMDB, opts.api_key, urlencode(id.query), lang)
        if id.year then url = url .. "&year=" .. id.year end
        curl_json(url, function(d)
            local r = d and d.results and d.results[1]
            if not r then return cb(nil) end
            local card = {
                kind = "movie", title = r.title, source = "TMDB",
                year = (r.release_date or ""):sub(1, 4),
                rating = r.vote_average, overview = r.overview,
                poster = r.poster_path, backdrop = r.backdrop_path,
            }
            if not r.id then return cb(card) end
            local durl = string.format("%s/movie/%d?api_key=%s%s&append_to_response=credits,release_dates,external_ids%s%s",
                TMDB, r.id, opts.api_key, lang, images_append(), images_query())
            curl_json(durl, function(dd)
                overlay_fields(card, parse_details("movie", dd))
                cb(card)
            end)
        end)
    end
end

return M
