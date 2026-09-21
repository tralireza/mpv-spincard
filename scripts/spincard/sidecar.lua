-- spincard/sidecar — filesystem discovery of the metadata + artwork that sit
-- beside the media (Kodi/Jellyfin naming): the .nfo, poster/thumb, and helpers to
-- count a season's episodes or detect any stray image. Pure filesystem work; the
-- .nfo body is parsed by the nfo module. The directory index and the candidate
-- resolvers are used by the image module's fanart/banner/art finders too, so they
-- are exported alongside file_exists.

local utils = require "mp.utils"
local nfo   = require "nfo"
local util  = require "util" -- split_path / parent_dir / is_url (separator-safe)

local M = {}

local function file_exists(p)
    local i = utils.file_info(p)
    return i ~= nil and not i.is_dir
end
M.file_exists = file_exists

-- Directory index -----------------------------------------------------------
-- ONE readdir per directory, lowercased into <lowercase> -> <real name>, shared
-- by every finder: cheaper than a file_info per candidate (which matters over
-- SMB) and case-insensitive, so a scraper's Fanart.JPG is found on a
-- case-sensitive filesystem. A short TTL rather than an explicit reset from
-- main — on_file_loaded is at the 60-upvalue ceiling and can't take the call.
local INDEX_TTL = 5
local dir_cache, dir_cache_n = {}, 0

function M.dir_index(dir)
    if not dir then return nil end
    local now = os.time()
    local e = dir_cache[dir]
    if e and (now - e.t) < INDEX_TTL then return e.idx end
    local idx = nil
    local files = utils.readdir(dir, "files")
    if files then
        idx = {}
        for _, f in ipairs(files) do idx[f:lower()] = f end
    end
    if dir_cache_n > 64 then dir_cache, dir_cache_n = {}, 0 end -- bound a long session
    if dir_cache[dir] == nil then dir_cache_n = dir_cache_n + 1 end
    dir_cache[dir] = { t = now, idx = idx }
    return idx
end

M.dir_cache_reset = function() dir_cache, dir_cache_n = {}, 0 end -- tests

-- First existing <name>.<ext> in `dir`. `names` is the outer loop, so a
-- file-specific "<base>-poster" beats a generic "poster".
function M.find_in_dir(dir, names, exts)
    local idx = M.dir_index(dir)
    if not idx then return nil end
    for _, n in ipairs(names) do
        for _, e in ipairs(exts) do
            local hit = idx[(n .. "." .. e):lower()]
            if hit then return util.join(dir, hit) end
        end
    end
    return nil
end

-- `own` = names only meaningful beside the media (the "<file>-poster" forms);
-- `shared` = generics, tried there and then in the TV show root above Season NN.
function M.find_art_near(path, id, own, shared, exts)
    if util.is_url(path) then return nil end
    local dir = (util.split_path(path))
    local names = {}
    for _, n in ipairs(own) do names[#names + 1] = n end
    for _, n in ipairs(shared) do names[#names + 1] = n end
    local hit = M.find_in_dir(dir, names, exts)
    if hit then return hit end
    if id and id.kind == "tv" then
        return M.find_in_dir(util.parent_dir(dir), shared, exts)
    end
    return nil
end

M.IMG_EXTS = { "jpg", "jpeg", "png" }
-- png-only ON PURPOSE: clearlogo/disc need alpha (clearlogo_decode crops to the
-- opaque bbox, both composite over video), so an opaque jpg would draw as a block.
M.ALPHA_EXTS = { "png" }

-- <video>.mkv -> <video>.nfo in the same dir; parsed if it has real metadata.
function M.read_local(path)
    local nfopath
    if not util.is_url(path) then
        local dir, base = util.split_path(path)
        local idx = M.dir_index(dir)
        if idx then
            local hit = idx[(base .. ".nfo"):lower()]
            nfopath = hit and util.join(dir, hit) or nil
        else
            nfopath = path:gsub("%.%a%w?%w?%w?$", "") .. ".nfo"
        end
    end
    if not nfopath then return nil end
    local f = io.open(nfopath, "r")
    if not f then return nil end
    local text = f:read("*a"); f:close()
    local ok, card = pcall(nfo.parse, text) -- malformed/untrusted .nfo must not throw
    if ok and card and card.overview and card.overview ~= "" then return card end
    return nil
end

-- Kodi/Jellyfin naming: own-folder movies get poster/folder/cover; shared-folder
-- movies get <file>-poster; TV prefers the landscape <file>-thumb episode still.
function M.find_poster(path, id)
    if util.is_url(path) then return nil end
    local dir, base = util.split_path(path)
    local own = (id.kind == "tv")
        and { base .. "-thumb", base .. "-poster", base .. "-cover", base }
        or { base .. "-poster", base .. "-cover", base .. "-thumb", base }
    local generic = { "poster", "folder", "cover" }
    local names = {}
    for _, n in ipairs(own) do names[#names + 1] = n end
    for _, n in ipairs(generic) do names[#names + 1] = n end
    local hit = M.find_in_dir(dir, names, M.IMG_EXTS)
    if hit then return hit end
    if id.kind == "tv" then
        -- Show root: the season poster outranks the show-level generics.
        local up = {}
        if id.season then up[#up + 1] = string.format("season%02d-poster", id.season) end
        for _, n in ipairs(generic) do up[#up + 1] = n end
        return M.find_in_dir(util.parent_dir(dir), up, M.IMG_EXTS)
    end
    return nil
end

-- Count distinct episodes present in the same season folder (local).
function M.count_season_episodes(path, season)
    if not season or util.is_url(path) then return nil end
    local idx = M.dir_index((util.split_path(path)))
    if not idx then return nil end
    local pat = string.format("[sS]0*%d[eE](%%d+)", season)
    local seen, n = {}, 0
    for _, f in pairs(idx) do
        local ep = f:match(pat)
        if ep then
            ep = tonumber(ep)
            if ep and not seen[ep] then seen[ep] = true; n = n + 1 end
        end
    end
    return n > 0 and n or nil
end

-- Any JPG/PNG image sitting next to the media? Artwork (or any stray image)
-- marks the folder as a catalogued movie/TV item, which makes it a legitimate
-- remote-lookup candidate. A bare video with NO image beside it stays "unknown"
-- (raw file name, no type guess, no TMDB query).
local IMG_EXT = { jpg = true, jpeg = true, png = true }
function M.dir_has_image(path)
    if util.is_url(path) then return false end
    local idx = M.dir_index((util.split_path(path)))
    if not idx then return false end
    for lower in pairs(idx) do -- keys are already lowercased by dir_index
        local ext = lower:match("%.([%a]+)$")
        if ext and IMG_EXT[ext] then return true end
    end
    return false
end

return M
