-- spincard/cache — on-disk JSON cache under ~/.cache/spincard, the short-TTL
-- rating sub-cache, and the .nfo-supplement field policy (which fields TMDB may
-- fill and how to merge them without clobbering local-first .nfo values).
-- rating_stale needs opts.rating_ttl, so call cache.init(opts) once at startup.

local utils = require "mp.utils"

local M = {}

local opts = {}
function M.init(o) opts = o end

-- Disk cache ----------------------------------------------------------------

local CACHE_DIR = (os.getenv("HOME") or "/tmp") .. "/.cache/spincard"
os.execute("mkdir -p '" .. CACHE_DIR .. "' 2>/dev/null")

local function cache_path(key)
    return CACHE_DIR .. "/" .. (tostring(key):gsub("[^%w%-_]", "_")) .. ".json"
end

local function cache_get(key)
    local f = io.open(cache_path(key), "r"); if not f then return nil end
    local s = f:read("*a"); f:close()
    local ok, d = pcall(utils.parse_json, s)
    return ok and d or nil
end
M.cache_get = cache_get

local function cache_put(key, tbl)
    local ok, json = pcall(utils.format_json, tbl)
    if not ok or not json then return end -- skip on an unserialisable value (don't throw in a callback)
    local f = io.open(cache_path(key), "w"); if not f then return end
    f:write(json); f:close()
end
M.cache_put = cache_put

-- Rating is a dynamic property: cached separately with a short TTL (rating_ttl)
-- so it can be refreshed from TMDB even when the card itself is a local .nfo.
-- Stored as { v = rating, t = os.time } under a "rating/<key>" entry; only a
-- positive rating is kept, so a 0 / no-vote TMDB result won't clobber a valid
-- source rating.
function M.rating_get(cachekey)
    local rc = cache_get("rating/" .. cachekey)
    if rc and rc.v then return tonumber(rc.v), tonumber(rc.t) end
end
function M.rating_put(cachekey, r)
    r = tonumber(r)
    if r and r > 0 then cache_put("rating/" .. cachekey, { v = r, t = os.time() }) end
end
function M.rating_stale(t)
    local ttl = tonumber(opts.rating_ttl) or 0
    return (not t) or (os.time() - t) >= ttl
end

-- IMDb rating (via OMDb) gets its OWN "rating_imdb/<key>" slot so it can be shown
-- alongside the TMDB rating (rating/<key>) without either clobbering the other.
-- Same short TTL (rating_stale) and positive-only policy; also keeps the vote count
-- and the OMDb critic/awards/box-office extras (rt/mc/awards/boxoffice). Bump
-- IMDB_VER when the stored shape grows so pre-version entries refetch once (else the
-- new fields wouldn't appear until the TTL expires) — get flags `_old` for main.
local IMDB_VER = 2
function M.imdb_rating_get(cachekey)
    local rc = cache_get("rating_imdb/" .. cachekey)
    if rc and rc.v then
        return tonumber(rc.v), tonumber(rc.t), {
            votes = tonumber(rc.votes), rt = tonumber(rc.rt), mc = tonumber(rc.mc),
            awards = rc.awards, boxoffice = tonumber(rc.boxoffice),
            _old = (tonumber(rc._v) or 1) < IMDB_VER,
        }
    end
end
function M.imdb_rating_put(cachekey, res)
    local r = tonumber(res and res.rating)
    if r and r > 0 then
        cache_put("rating_imdb/" .. cachekey, {
            _v = IMDB_VER, v = r, t = os.time(), votes = res.votes,
            rt = res.rt, mc = res.mc, awards = res.awards, boxoffice = res.boxoffice,
        })
    end
end

-- Supplement: fields a local .nfo may lack that TMDB can supply (rating is a
-- separate dynamic property, so it is NOT in this list). Cached under a distinct
-- "extra/<key>" entry so the local-first .nfo body on disk is never touched.
local SUPP_FIELDS = { "cast", "genres", "studio", "tagline", "director", "runtime", "mpaa" }

-- Supplement schema version: bump when SUPP_FIELDS or the cast-cap policy changes so
-- stale entries refetch ONCE (else the extra/ cache — which has no TTL — would keep an
-- old, smaller cast forever). Existing entries have no _v (treated as 1), so 2 forces
-- the first refresh. Mirrors IMDB_VER. `_v` is not a SUPP_FIELD, so it never lands on
-- the card. (v2: cast pool sized by max(cast_max, casthead_max); pre-v2 kept only cast_max.)
local SUPP_VER = 2

-- Freshness TTL for the enrichment caches (card + .nfo supplement): an entry stamped
-- with a write time `_t` older than enrich_ttl_days is treated as stale so the caller
-- refetches — stale-while-revalidate (the cached value still shows immediately). 0 days
-- = never expire (version-only). The dynamic rating keeps its own faster rating_ttl.
local function age_stale(t)
    local ttl = (tonumber(opts.enrich_ttl_days) or 0) * 86400
    return ttl > 0 and (os.time() - (tonumber(t) or 0)) >= ttl
end

local function is_empty(v)
    return v == nil or v == "" or (type(v) == "table" and #v == 0)
end
function M.nfo_missing(c)
    for _, f in ipairs(SUPP_FIELDS) do if is_empty(c[f]) then return true end end
    return false
end
-- Fill dst's missing supplementable fields from a cached/fetched supplement `src`,
-- respecting local-first (never overwrite a value dst already has). Returns true when
-- src is present, current-version, AND within the freshness TTL (applied); false when
-- src is nil, an old-version entry, or older than enrich_ttl_days — the caller then
-- refetches to rebuild it (at the current policy, with a fresh write time).
function M.fill_missing(dst, src)
    if type(src) ~= "table" or (tonumber(src._v) or 1) < SUPP_VER or age_stale(src._t) then
        return false
    end
    for _, f in ipairs(SUPP_FIELDS) do
        if is_empty(dst[f]) and not is_empty(src[f]) then dst[f] = src[f] end
    end
    return true
end
-- Extract from a fetched card/details only the supplementable fields that `localc`
-- lacked — this is what gets cached under extra/<key>. Stamped with the schema version
-- and a write time (_t) for the freshness TTL.
function M.pick_supplement(src, localc)
    local extra = { _v = SUPP_VER, _t = os.time() }
    for _, f in ipairs(SUPP_FIELDS) do
        if is_empty(localc[f]) and not is_empty(src[f]) then extra[f] = src[f] end
    end
    return extra
end

return M
