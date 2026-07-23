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

-- Supplement: fields a local .nfo may lack that TMDB can supply (rating is a
-- separate dynamic property, so it is NOT in this list). Cached under a distinct
-- "extra/<key>" entry so the local-first .nfo body on disk is never touched.
local SUPP_FIELDS = { "cast", "genres", "studio", "tagline", "director", "runtime", "mpaa" }

local function is_empty(v)
    return v == nil or v == "" or (type(v) == "table" and #v == 0)
end
function M.nfo_missing(c)
    for _, f in ipairs(SUPP_FIELDS) do if is_empty(c[f]) then return true end end
    return false
end
-- Fill dst's missing supplementable fields from src; never overwrite a value dst
-- already has (respects local-first — the .nfo stays authoritative).
function M.fill_missing(dst, src)
    for _, f in ipairs(SUPP_FIELDS) do
        if is_empty(dst[f]) and not is_empty(src[f]) then dst[f] = src[f] end
    end
end
-- Extract from a fetched card/details only the supplementable fields that `localc`
-- lacked — this is what gets cached under extra/<key>.
function M.pick_supplement(src, localc)
    local extra = {}
    for _, f in ipairs(SUPP_FIELDS) do
        if is_empty(localc[f]) and not is_empty(src[f]) then extra[f] = src[f] end
    end
    return extra
end

return M
