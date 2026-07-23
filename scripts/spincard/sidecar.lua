-- spincard/sidecar — filesystem discovery of the metadata + artwork that sit
-- beside the media (Kodi/Jellyfin naming): the .nfo, poster/thumb, and helpers to
-- count a season's episodes or detect any stray image. Pure filesystem work; the
-- .nfo body is parsed by the nfo module. file_exists is also used by the image
-- module's fanart/banner/art finders, so it is exported.

local utils = require "mp.utils"
local nfo   = require "nfo"

local M = {}

local function file_exists(p)
    local i = utils.file_info(p)
    return i ~= nil and not i.is_dir
end
M.file_exists = file_exists

-- <video>.mkv -> <video>.nfo in the same dir; parsed if it has real metadata.
function M.read_local(path)
    local nfopath = path:gsub("%.%a%w?%w?%w?$", "") .. ".nfo"
    local f = io.open(nfopath, "r")
    if not f then return nil end
    local text = f:read("*a"); f:close()
    local ok, card = pcall(nfo.parse, text) -- malformed/untrusted .nfo must not throw
    if ok and card and card.overview and card.overview ~= "" then return card end
    return nil
end

-- First existing poster/thumb near the media (Kodi/Jellyfin naming).
function M.find_poster(path, id)
    local dir = path:match("^(.*)/[^/]+$") or "."
    local base = (path:match("([^/]+)$") or path):gsub("%.%a%w?%w?%w?$", "")
    local cands = {}
    if id.kind == "tv" then cands[#cands + 1] = dir .. "/" .. base .. "-thumb.jpg" end
    cands[#cands + 1] = dir .. "/" .. base .. ".jpg"
    cands[#cands + 1] = dir .. "/poster.jpg"
    cands[#cands + 1] = dir .. "/folder.jpg"
    cands[#cands + 1] = dir .. "/cover.jpg"
    if id.kind == "tv" then
        local showdir = dir:match("^(.*)/[^/]+$") -- parent of Season.N
        if showdir then
            if id.season then
                cands[#cands + 1] = showdir .. string.format("/season%02d-poster.jpg", id.season)
            end
            cands[#cands + 1] = showdir .. "/poster.jpg"
            cands[#cands + 1] = showdir .. "/folder.jpg"
        end
    end
    for _, c in ipairs(cands) do if file_exists(c) then return c end end
    return nil
end

-- Count distinct episodes present in the same season folder (local).
function M.count_season_episodes(path, season)
    if not season then return nil end
    local dir = path:match("^(.*)/[^/]+$")
    if not dir then return nil end
    local files = utils.readdir(dir, "files")
    if not files then return nil end
    local pat = string.format("[sS]0*%d[eE](%%d+)", season)
    local seen, n = {}, 0
    for _, f in ipairs(files) do
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
    local dir = path:match("^(.*)/[^/]+$")
    if not dir then return false end
    local files = utils.readdir(dir, "files")
    if not files then return false end
    for _, f in ipairs(files) do
        local ext = f:match("%.([%a]+)$")
        if ext and IMG_EXT[ext:lower()] then return true end
    end
    return false
end

return M
