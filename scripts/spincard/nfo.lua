-- nfo.lua — parse Kodi/Jellyfin .nfo sidecars (movie / episode) next to media.
--
-- Pure Lua (no mpv deps): M.parse(text) auto-detects the root element and
-- returns a card table, or a {tmdb_id/imdb_id} stub for URL-only nfos, or nil.
-- Testable standalone with luajit.

local M = {}

-- Minimal XML entity decode, including numeric refs as UTF-8.
local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    else
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
end

local function unescape(s)
    if not s then return nil end
    s = s:gsub("&#x(%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<")
        :gsub("&gt;", ">"):gsub("&amp;", "&")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Strict tag match (exact <name>, no prefix) so <episode> can't match
-- <episodedetails>. Attributed tags (rating, uniqueid) have their own patterns.
local function tag(text, name)
    local v = text:match("<" .. name .. ">(.-)</" .. name .. ">")
    if v == nil or v == "" then return nil end
    return unescape(v)
end

local function tag_num(text, name)
    local v = tag(text, name)
    return v and tonumber(v:match("[%d%.]+")) or nil
end

local function all_tags(text, name)
    local t = {}
    for v in text:gmatch("<" .. name .. ">(.-)</" .. name .. ">") do
        v = unescape(v)
        if v and v ~= "" then t[#t + 1] = v end
    end
    return t
end

-- top few actor names (each <actor> block's first <name>)
local function cast(text, limit)
    local names = {}
    for block in text:gmatch("<actor>(.-)</actor>") do
        local n = block:match("<name>(.-)</name>")
        if n then names[#names + 1] = unescape(n) end
        if #names >= (limit or 4) then break end
    end
    return names
end

-- Prefer the default-marked rating (usually IMDb); else the bare <rating>.
local function rating(text)
    local v = text:match('default="true"[^>]*>%s*<value>([%d%.]+)')
    if v then return tonumber(v) end
    return tag_num(text, "rating")
end

local function ids(text)
    return text:match("themoviedb%.org/[a-z]+/(%d+)")
        or text:match('uniqueid[^>]*type="tmdb"[^>]*>(%d+)'),
        text:match("imdb%.com/title/(tt%d+)")
        or text:match('uniqueid[^>]*type="imdb"[^>]*>(tt%d+)')
end

function M.parse(text)
    if not text or text == "" then return nil end
    local tmdb_id, imdb_id = ids(text)

    if text:match("<episodedetails") then
        return {
            kind = "tv", source = "local",
            title = tag(text, "showtitle"),
            episode_title = tag(text, "title"),
            season = tag_num(text, "season"),
            episode = tag_num(text, "episode"),
            overview = tag(text, "plot"),
            runtime = tag_num(text, "runtime"),
            aired = tag(text, "aired"),
            rating = rating(text),
            director = tag(text, "director"),
            cast = cast(text, 6),
            tmdb_id = tmdb_id, imdb_id = imdb_id,
        }
    elseif text:match("<movie") then
        return {
            kind = "movie", source = "local",
            title = tag(text, "title"),
            year = tag_num(text, "year"),
            overview = tag(text, "plot"),
            runtime = tag_num(text, "runtime"),
            mpaa = tag(text, "mpaa"),
            studio = tag(text, "studio"),
            genres = all_tags(text, "genre"),
            rating = rating(text),
            tagline = tag(text, "tagline"),
            director = tag(text, "director") or tag(text, "credits"),
            cast = cast(text, 6),
            tmdb_id = tmdb_id, imdb_id = imdb_id,
        }
    elseif tmdb_id or imdb_id then
        -- URL-only nfo: no local metadata, but the IDs enable a precise lookup.
        return { source = "local-id", tmdb_id = tmdb_id, imdb_id = imdb_id }
    end
    return nil
end

return M
