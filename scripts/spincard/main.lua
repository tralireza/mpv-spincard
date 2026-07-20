-- spincard — identify the playing file from its full path and show a
-- metadata card. Identity comes from identify.lua; enrichment from TMDB (via a
-- curl subprocess, per Docs/MpvLuaMetadataApiProvider.md), cached on disk.
--
-- Degrades gracefully: with no API key or no network it shows a card built from
-- the parsed filename + mpv's own local properties.
--
-- Target: mpv on i7 (Linux). Config in ~/.mpv (see README).

local mp      = require "mp"
local msg     = require "mp.msg"
local utils   = require "mp.utils"
local options = require "mp.options"

-- Load the sibling identify module from this script's directory.
local sd = mp.get_script_directory()
if sd then package.path = sd .. "/?.lua;" .. package.path end
local identify = require("identify").identify
local nfo = require("nfo")

-- Options (override in ~/.mpv/script-opts/spincard.conf) -------------
local opts = {
    auto_show = true,      -- show the card automatically when a file loads
    show_on_pause = false, -- pop the card while paused, hide on resume (opt-in)
    duration  = 7,         -- auto-show-on-open timeout (0 = stay until toggled)
    toggle_timeout = 17,   -- toggle-key auto-close timeout (0 = stay until toggled)
    key       = "",        -- default toggle key ("" = bind via input.conf)
    pos_x     = 40,
    pos_y     = 40,     -- margin from the top OR bottom edge (see anchor)
    anchor    = "bottom", -- "bottom" (hug bottom, grow up) or "top"
    enrich    = true,      -- look up online metadata (needs api_key)
    api_key   = "",        -- TMDB API key; empty => filename-only card
    language  = "en-US",   -- TMDB response language
    rating_ttl = 3600,     -- refresh rating from TMDB when the cached value is older than this (s); 0 = off
    tvheadend_url = "",    -- e.g. http://127.0.0.1:9981 — live-TV EPG source ("" = off)
    live_upcoming = 3,     -- live TV: how many upcoming programmes to list under "Up next" (0 = none)
    live_signal   = true,  -- live TV: show tuner signal strength / SNR meter (needs tvheadend_url)
    live_signal_interval = 3, -- live TV: seconds between signal polls while the card is visible (0 = read once on show)
    signal_dbm_max = -40.6, -- live TV: dBm that fills the signal meter (tuner's max; meter spans 50 dB below it)
    show_poster   = true,  -- render the local poster image (needs ffmpeg)
    poster_height = 0.42,  -- poster height as a fraction of the video height
    poster_margin = 0.02,  -- gap from the top-right corner (fraction of height; 0 = flush)
    show_tech     = true,  -- local file details (codec/HDR/audio/subs/chapters/…)
    show_fanart    = true, -- dimmed fanart.jpg backdrop (needs ffmpeg)
    fanart_opacity = 0.6,  -- backdrop / fade-peak opacity 0..1 (higher = more visible/darker)
    fanart_timeout = 3,    -- fanart lifetime: hide it this many seconds after it appears (0 = keep)
    fanart_fade    = true, -- fade fanart in (0.1→fanart_opacity) then out (→0.1, held) over fanart_timeout
    fanart_fade_frames = 16, -- fade smoothness: pre-rendered opacity steps (more = smoother/heavier)
    show_banner    = false, -- wide banner.jpg top-left (opaque JPEG, no alpha)
    banner_height  = 0.10,  -- banner height as a fraction of the video height
    show_logo      = true,  -- clearlogo.png title art, top-left (transparent PNG)
    logo_height    = 0.12,  -- logo height as a fraction of the video height
    logo_autocrop  = true,  -- crop the clearlogo's transparent margins so its slot maps to real artwork
    show_disc      = true,  -- 3/4 disc.png nestled at the card's top-left corner
    disc_size      = 0.22,  -- disc diameter as a fraction of the video height
    disc_spin      = true,  -- spin the disc while the card is showing
    disc_spin_secs = 2.5,   -- seconds per full rotation (higher = slower)
    disc_spin_frames = 96,  -- rotation frames (more = smoother; larger temp file)
}
options.read_options(opts, "spincard")

local RES_X, RES_Y = 1280, 720
local TMDB = "https://api.themoviedb.org/3"

local overlay = mp.create_osd_overlay("ass-events")
overlay.res_x = RES_X
overlay.res_y = RES_Y

local visible, hide_timer, cur_card = false, nil, nil
local content_ok = false -- true only while a real video (not image/audio) plays
local live_ctx = nil     -- { path, chan } while a Tvheadend live stream plays
local cur_signal = nil   -- latest live-TV tuner reading (or nil); read directly by build_card
local signal_timer = nil -- periodic signal poll while the live card is visible
local signal_inflight = false -- guards overlapping polls (two chained curls per poll)
local logo_rect = nil    -- clearlogo slot in 1280x720 coords, set by build_card
local card_rect = nil    -- card box rect in 1280x720 coords, set by build_card
local anim_fade, refresh_timer = 1, nil -- anim_fade stays 1 (fades disabled)
local current_gen = 0
local render, show, hide, toggle, gather_tech   -- forward declarations

-- Small helpers -------------------------------------------------------------

local function ass_escape(s)
    if not s then return "" end
    return (tostring(s):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"):gsub("\n", "\\N"))
end

local function fmt_duration(secs)
    if not secs then return nil end
    local t = math.floor(secs + 0.5)
    local h, m, s = math.floor(t / 3600), math.floor((t % 3600) / 60), t % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

-- Word-wrap to `width` cols, at most `maxlines` (adds an ellipsis if truncated).
local function wrap(text, width, maxlines)
    local out, cur = {}, ""
    for w in text:gmatch("%S+") do
        local cand = (cur == "") and w or (cur .. " " .. w)
        if #cand <= width then
            cur = cand
        else
            out[#out + 1] = cur
            cur = w
            if #out == maxlines then break end
        end
    end
    if #out < maxlines then
        if cur ~= "" then out[#out + 1] = cur end
    else
        out[maxlines] = out[maxlines] .. "\226\128\166" -- …
    end
    return out
end

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function human_size(b)
    if not b then return nil end
    local u, i = { "B", "KB", "MB", "GB", "TB" }, 1
    while b >= 1024 and i < #u do b = b / 1024; i = i + 1 end
    return string.format((i >= 3) and "%.1f %s" or "%.0f %s", b, u[i])
end

local function chan_label(n)
    if not n then return nil end
    if n == 1 then return "Mono" end
    if n == 2 then return "Stereo" end
    if n == 6 then return "5.1" end
    if n == 8 then return "7.1" end
    return n .. "ch"
end

local function fmt_fps(f)
    if not f then return nil end
    return (string.format("%.3f", f):gsub("%.?0+$", ""))
end

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

local function cache_put(key, tbl)
    local f = io.open(cache_path(key), "w"); if not f then return end
    f:write(utils.format_json(tbl)); f:close()
end

-- Rating is a dynamic property: cached separately with a short TTL (rating_ttl)
-- so it can be refreshed from TMDB even when the card itself is a local .nfo.
-- Stored as { v = rating, t = os.time } under a "rating/<key>" entry; only a
-- positive rating is kept, so a 0 / no-vote TMDB result won't clobber a valid
-- source rating.
local function rating_get(cachekey)
    local rc = cache_get("rating/" .. cachekey)
    if rc and rc.v then return tonumber(rc.v), tonumber(rc.t) end
end
local function rating_put(cachekey, r)
    r = tonumber(r)
    if r and r > 0 then cache_put("rating/" .. cachekey, { v = r, t = os.time() }) end
end
local function rating_stale(t)
    local ttl = tonumber(opts.rating_ttl) or 0
    return (not t) or (os.time() - t) >= ttl
end

-- Local sidecars (.nfo metadata + poster image) -----------------------------

local function file_exists(p)
    local i = utils.file_info(p)
    return i ~= nil and not i.is_dir
end

-- <video>.mkv -> <video>.nfo in the same dir; parsed if it has real metadata.
local function read_local(path)
    local nfopath = path:gsub("%.%a%w?%w?%w?$", "") .. ".nfo"
    local f = io.open(nfopath, "r")
    if not f then return nil end
    local text = f:read("*a"); f:close()
    local card = nfo.parse(text)
    if card and card.overview and card.overview ~= "" then return card end
    return nil
end

-- First existing poster/thumb near the media (Kodi/Jellyfin naming).
local function find_poster(path, id)
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
local function count_season_episodes(path, season)
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
local function dir_has_image(path)
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

-- Poster image: decode a local jpg -> BGRA (ffmpeg), draw with overlay-add ---

local poster = {
    id = 1,
    file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-poster-"
        .. (mp.get_property("pid") or "x") .. ".bgra",
    w = 0, h = 0, ready = false, shown = false, src = nil,
}
local POSTER_H = 450 -- decode height in px; on-screen size is scaled to the OSD

local function poster_decode(srcpath, cb)
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { "ffmpeg", "-y", "-loglevel", "error", "-i", srcpath,
            "-vf", "scale=-2:" .. POSTER_H, "-pix_fmt", "bgra", "-f", "rawvideo", poster.file },
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 then
            msg.warn("poster decode failed"); return cb(false)
        end
        local fi = utils.file_info(poster.file)
        if not fi or not fi.size or fi.size == 0 then return cb(false) end
        poster.h = POSTER_H
        poster.w = math.floor(fi.size / (4 * POSTER_H))
        poster.ready, poster.src = true, srcpath
        msg.verbose(string.format("poster %dx%d ready", poster.w, poster.h))
        cb(true)
    end)
end

local function poster_hide()
    if poster.shown then
        mp.command_native({ "overlay-remove", poster.id })
        poster.shown = false
    end
end

local function poster_show()
    if not opts.show_poster or not poster.ready then return end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    local dh = math.floor(oh * opts.poster_height)
    local scale = dh / poster.h
    local dw = math.floor(poster.w * scale)
    local margin = math.floor(oh * opts.poster_margin)
    mp.command_native({
        name = "overlay-add", id = poster.id,
        x = ow - dw - margin, y = margin,
        file = poster.file, offset = 0, fmt = "bgra",
        w = poster.w, h = poster.h, stride = poster.w * 4, dw = dw, dh = dh,
    })
    poster.shown = true
end

-- Fanart backdrop: decode a dimmed local jpg -> BGRA, draw full-frame ---------
-- Kodi/Emby naming: fanart.jpg, <name>-fanart.jpg, backdrop.jpg (+ show-level).
-- Note: mpv draws image overlays above ASS text, so this tints the card too;
-- fanart.id is lower than poster.id so the poster stays on top.

local fanart = {
    id = 0,
    file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-fanart-"
        .. (mp.get_property("pid") or "x") .. ".bgra",
    w = 0, h = 0, ready = false, shown = false, src = nil,
    frames = 1, framebytes = 0, fade_idx = 0, -- packed opacity frames (fade mode)
}
local FANART_H = 720        -- decode height for the static (non-fade) backdrop
local FANART_FADE_H = 360   -- decode height per fade frame (kept small: N frames packed)
local FANART_FADE_MIN = 0.1 -- fade floor opacity (0.1 → fanart_opacity → 0.1, then held)

local function find_fanart(path, id)
    local dir = path:match("^(.*)/[^/]+$") or "."
    local base = (path:match("([^/]+)$") or path):gsub("%.%a%w?%w?%w?$", "")
    local cands = {
        dir .. "/" .. base .. "-fanart.jpg",
        dir .. "/fanart.jpg",
        dir .. "/backdrop.jpg",
    }
    if id.kind == "tv" then
        local showdir = dir:match("^(.*)/[^/]+$") -- parent of Season.N
        if showdir then
            cands[#cands + 1] = showdir .. "/fanart.jpg"
            cands[#cands + 1] = showdir .. "/backdrop.jpg"
        end
    end
    for _, c in ipairs(cands) do if file_exists(c) then return c end end
    return nil
end

-- Decode the fanart to premultiplied BGRA: either one dimmed frame
-- (fanart_opacity), or — when fading — a packed strip of fanart_fade_frames
-- whose opacity rises FANART_FADE_MIN→fanart_opacity then falls →0. The fade is
-- one ffmpeg pass: the loop filter replicates the still, and a frame-indexed geq
-- envelope scales all four premultiplied channels; frames are stepped later by
-- overlay byte offset (like the disc).
local function fanart_decode(srcpath, cb)
    local fade = opts.fanart_fade and (tonumber(opts.fanart_timeout) or 0) > 0
    local dech = fade and FANART_FADE_H or FANART_H
    local nf = fade and math.max(2, math.floor(tonumber(opts.fanart_fade_frames) or 16)) or 1
    local args
    if fade then
        local peak = math.max(0, math.min(1, opts.fanart_opacity))
        local lo = math.min(FANART_FADE_MIN, peak)
        local d = nf - 1
        local frac = "N/" .. d
        local env = string.format(
            "if(lte(%s\\,0.5)\\,%.4f+(%.4f-%.4f)*2*(%s)\\,%.4f+(%.4f-%.4f)*2*(1-(%s)))",
            frac, lo, peak, lo, frac, lo, peak, lo, frac)
        local vf = string.format(
            "scale=-2:%d,format=rgba,loop=loop=%d:size=1:start=0,"
                .. "geq=r=r(X\\,Y)*%s:g=g(X\\,Y)*%s:b=b(X\\,Y)*%s:a=alpha(X\\,Y)*%s",
            dech, d, env, env, env, env)
        args = { "ffmpeg", "-y", "-loglevel", "error", "-i", srcpath,
            "-vf", vf, "-frames:v", tostring(nf), "-pix_fmt", "bgra", "-f", "rawvideo", fanart.file }
    else
        local op = string.format("%.3f", math.max(0, math.min(1, opts.fanart_opacity)))
        -- Premultiplied dim: scale RGB and alpha by the opacity factor.
        local vf = string.format(
            "scale=-2:%d,format=rgba,colorchannelmixer=rr=%s:gg=%s:bb=%s:aa=%s",
            dech, op, op, op, op)
        args = { "ffmpeg", "-y", "-loglevel", "error", "-i", srcpath,
            "-vf", vf, "-pix_fmt", "bgra", "-f", "rawvideo", fanart.file }
    end
    mp.command_native_async({ name = "subprocess", playback_only = false, args = args },
        function(ok, res)
        if not ok or not res or res.status ~= 0 then
            msg.warn("fanart decode failed"); return cb(false)
        end
        local fi = utils.file_info(fanart.file)
        if not fi or not fi.size or fi.size == 0 then return cb(false) end
        fanart.h = dech
        fanart.frames = nf
        fanart.framebytes = math.floor(fi.size / nf)
        fanart.w = math.floor(fanart.framebytes / (4 * dech))
        fanart.fade_idx = 0
        fanart.ready, fanart.src = true, srcpath
        msg.verbose(string.format("fanart %dx%d x%d frames ready", fanart.w, fanart.h, fanart.frames))
        cb(true)
    end)
end

-- fanart lifetime. In fade mode the packed frames are stepped 0..N-1 across
-- opts.fanart_timeout then removed; otherwise the static backdrop is hard-hidden
-- after the timeout. `dismissed` stops the osd-width re-show from reviving it
-- once done; it (and fade_idx) reset in show() on each (re)display.
local fanart_timer = nil
local fanart_dismissed = false

local function fanart_hide()
    if fanart_timer then fanart_timer:kill(); fanart_timer = nil end
    if fanart.shown then
        mp.command_native({ "overlay-remove", fanart.id })
        fanart.shown = false
    end
end

-- Draw the current fanart frame (fade_idx picks the packed frame; 0 when static).
local function fanart_draw()
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return false end
    mp.command_native({ name = "overlay-add", id = fanart.id, x = 0, y = 0,
        file = fanart.file, offset = (fanart.fade_idx or 0) * (fanart.framebytes or 0),
        fmt = "bgra", w = fanart.w, h = fanart.h, stride = fanart.w * 4, dw = ow, dh = oh })
    fanart.shown = true
    return true
end

local function fanart_show()
    if not opts.show_fanart or not fanart.ready then return end
    local nf = fanart.frames or 1
    if nf <= 1 and fanart_dismissed then return end -- static backdrop stays hard-hidden
    if not fanart_draw() then return end            -- OSD not ready yet; retried via osd-width
    if fanart_dismissed then return end             -- fade done: hold the final (0.1) frame, no timer
    if fanart_timer then return end                 -- already animating (e.g. an osd-width re-show)
    if nf > 1 then
        -- fade in then out to the FANART_FADE_MIN floor, and HOLD the final frame
        local step = (tonumber(opts.fanart_timeout) or 3) / (nf - 1)
        fanart_timer = mp.add_periodic_timer(step, function()
            fanart.fade_idx = (fanart.fade_idx or 0) + 1
            if fanart.fade_idx >= nf then
                fanart.fade_idx = nf - 1 -- clamp to the final (0.1) frame and leave it drawn
                fanart_dismissed = true
                if fanart_timer then fanart_timer:kill(); fanart_timer = nil end
            else
                fanart_draw()
            end
        end)
    elseif (tonumber(opts.fanart_timeout) or 0) > 0 then
        -- static backdrop: hard-hide once the timeout elapses
        fanart_timer = mp.add_timeout(opts.fanart_timeout, function()
            fanart_dismissed = true
            fanart_hide()
        end)
    end
end

-- Banner: wide title art (banner.jpg), opaque, drawn top-left ---------------

local banner = {
    id = 3,
    file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-banner-"
        .. (mp.get_property("pid") or "x") .. ".bgra",
    w = 0, h = 0, ready = false, shown = false, src = nil,
}
local BANNER_H = 200

local function find_banner(path, id)
    local dir = path:match("^(.*)/[^/]+$") or "."
    local cands = { dir .. "/banner.jpg" }
    if id.kind == "tv" then
        local showdir = dir:match("^(.*)/[^/]+$") -- parent of Season.N
        if showdir then cands[#cands + 1] = showdir .. "/banner.jpg" end
    end
    for _, c in ipairs(cands) do if file_exists(c) then return c end end
    return nil
end

local function banner_decode(srcpath, cb)
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { "ffmpeg", "-y", "-loglevel", "error", "-i", srcpath,
            "-vf", "scale=-2:" .. BANNER_H, "-pix_fmt", "bgra", "-f", "rawvideo", banner.file },
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 then
            msg.warn("banner decode failed"); return cb(false)
        end
        local fi = utils.file_info(banner.file)
        if not fi or not fi.size or fi.size == 0 then return cb(false) end
        banner.h = BANNER_H
        banner.w = math.floor(fi.size / (4 * BANNER_H))
        banner.ready, banner.src = true, srcpath
        msg.verbose(string.format("banner %dx%d ready", banner.w, banner.h))
        cb(true)
    end)
end

local function banner_hide()
    if banner.shown then
        mp.command_native({ "overlay-remove", banner.id })
        banner.shown = false
    end
end

local function banner_show()
    if not opts.show_banner or not banner.ready then return end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    local dh = math.floor(oh * opts.banner_height)
    local scale = dh / banner.h
    local dw = math.floor(banner.w * scale)
    local margin = math.floor(oh * 0.03)
    mp.command_native({
        name = "overlay-add", id = banner.id, x = margin, y = margin,
        file = banner.file, offset = 0, fmt = "bgra",
        w = banner.w, h = banner.h, stride = banner.w * 4, dw = dw, dh = dh,
    })
    banner.shown = true
end

-- Clearlogo (title art) + disc: transparent PNGs, premultiplied -------------

local clearlogo = {
    id = 4,
    file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-logo-"
        .. (mp.get_property("pid") or "x") .. ".bgra",
    w = 0, h = 0, ready = false, shown = false, src = nil,
}
local LOGO_H = 240
local LOGO_GAP = 6      -- gap (virtual px) between the clearlogo band and the first text row

local disc = {
    id = 5,
    file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-disc-"
        .. (mp.get_property("pid") or "x") .. ".bgra",
    w = 0, h = 0, ready = false, shown = false, src = nil,
    frames = 1, framebytes = 0, spin_idx = 0, spin_timer = nil,
}
local DISC_H = 256      -- decode height (square); modest for mpv 0.41 offsets

-- Decode a transparent PNG to premultiplied BGRA (overlay-add wants premult).
-- pre_vf runs BEFORE scale (native px, e.g. crop=W:H:X:Y); extra_vf runs after
-- scale, before premultiply (e.g. an alpha mask).
local function png_decode(img, srcpath, height, cb, extra_vf, pre_vf)
    local vf = ""
    if pre_vf then vf = pre_vf .. "," end -- native-px crop, before scale
    vf = vf .. "scale=-2:" .. height .. ",format=rgba"
    if extra_vf then vf = vf .. "," .. extra_vf end -- e.g. alpha mask, before premult
    vf = vf .. ",premultiply=inplace=1"
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { "ffmpeg", "-y", "-loglevel", "error", "-i", srcpath,
            "-vf", vf, "-pix_fmt", "bgra", "-f", "rawvideo", img.file },
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 then
            msg.warn("png decode failed"); return cb(false)
        end
        local fi = utils.file_info(img.file)
        if not fi or not fi.size or fi.size == 0 then return cb(false) end
        img.h = height
        img.w = math.floor(fi.size / (4 * height))
        img.ready, img.src = true, srcpath
        msg.verbose(string.format("%s %dx%d ready", srcpath:match("([^/]+)$"), img.w, img.h))
        cb(true)
    end)
end

local function find_art(path, id, name)
    local dir = path:match("^(.*)/[^/]+$") or "."
    local cands = { dir .. "/" .. name }
    if id.kind == "tv" then
        local showdir = dir:match("^(.*)/[^/]+$")
        if showdir then cands[#cands + 1] = showdir .. "/" .. name end
    end
    for _, c in ipairs(cands) do if file_exists(c) then return c end end
    return nil
end

local function find_clearlogo(path, id)
    return find_art(path, id, "clearlogo.png") or find_art(path, id, "logo.png")
end
local function find_disc(path, id) return find_art(path, id, "disc.png") end

-- Decode the clearlogo cropped to its opaque bounding box, so the reserved title
-- slot maps to real artwork rather than the PNG's (variable) transparent margins.
-- Pass 1 runs cropdetect over the ALPHA plane (alphaextract) to find the bbox;
-- pass 2 decodes with that crop applied before scale (native-px coords). If
-- detection yields nothing (older ffmpeg, or a logo whose shadow bleeds to the
-- edge) it falls back to a plain full-frame decode — never breaks the logo.
--   limit=0 : trim only fully-transparent rows/cols (any opacity is kept)
--   skip=0  : cropdetect skips the first 2 frames by default → none for a still,
--             so force skip=0 and feed a few looped frames as belt-and-suspenders
local function clearlogo_decode(srcpath, cb)
    if not opts.logo_autocrop then return png_decode(clearlogo, srcpath, LOGO_H, cb) end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stderr = true,
        args = { "ffmpeg", "-y", "-loglevel", "info", "-loop", "1", "-i", srcpath,
            "-vf", "format=rgba,alphaextract,cropdetect=limit=0:round=2:reset=1:skip=0",
            "-frames:v", "3", "-f", "null", "-" },
    }, function(ok, res)
        local crop
        if ok and res and res.stderr then
            for w, h, ox, oy in res.stderr:gmatch("crop=(%d+):(%d+):(%d+):(%d+)") do
                crop = string.format("crop=%s:%s:%s:%s", w, h, ox, oy) -- keep the last
            end
        end
        png_decode(clearlogo, srcpath, LOGO_H, cb, nil, crop)
    end)
end

local function img_remove(img)
    if img.shown then mp.command_native({ "overlay-remove", img.id }); img.shown = false end
end

-- Draw the clearlogo in the card's title slot (logo_rect is in 1280x720 virtual
-- coords set by build_card), converted to OSD pixels; clamped to card width.
local function place_logo()
    if not (opts.show_logo and clearlogo.ready and logo_rect) then return end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    local sx, sy = ow / RES_X, oh / RES_Y
    local dh = math.floor(logo_rect.h * sy)
    local dw = math.floor(clearlogo.w * (dh / clearlogo.h))
    local max_dw = math.floor(812 * sx) -- card inner width
    if dw > max_dw then dw = max_dw; dh = math.floor(clearlogo.h * (dw / clearlogo.w)) end
    mp.command_native({ name = "overlay-add", id = clearlogo.id,
        x = math.floor(logo_rect.x * sx), y = math.floor(logo_rect.y * sy),
        file = clearlogo.file, offset = 0, fmt = "bgra",
        w = clearlogo.w, h = clearlogo.h, stride = clearlogo.w * 4, dw = dw, dh = dh })
    clearlogo.shown = true
end

local DISC_MASK = "geq=r=r(X\\,Y):g=g(X\\,Y):b=b(X\\,Y):a=if(gt(X\\,W/2)*gt(Y\\,H/2)\\,0\\,alpha(X\\,Y))"

-- Decode the disc: a single 3/4 frame, or DISC_FRAMES rotation frames packed
-- into one file (rotate -> fixed notch mask -> premultiply -> bgra).
local function disc_decode(srcpath, cb)
    local args
    if opts.disc_spin then
        local n = math.max(2, math.floor(opts.disc_spin_frames or 36))
        local vf = string.format(
            "scale=%d:%d,format=rgba,rotate=2*PI*t:fillcolor=none,%s,premultiply=inplace=1",
            DISC_H, DISC_H, DISC_MASK)
        args = { "ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-i", srcpath,
            "-r", tostring(n), "-t", "1", "-vf", vf,
            "-frames:v", tostring(n), "-pix_fmt", "bgra", "-f", "rawvideo", disc.file }
        disc.frames = n
    else
        local vf = string.format("scale=-2:%d,format=rgba,%s,premultiply=inplace=1", DISC_H, DISC_MASK)
        args = { "ffmpeg", "-y", "-loglevel", "error", "-i", srcpath,
            "-vf", vf, "-pix_fmt", "bgra", "-f", "rawvideo", disc.file }
        disc.frames = 1
    end
    mp.command_native_async({ name = "subprocess", playback_only = false, args = args }, function(ok, res)
        if not ok or not res or res.status ~= 0 then msg.warn("disc decode failed"); return cb(false) end
        local fi = utils.file_info(disc.file)
        if not fi or not fi.size or fi.size == 0 then return cb(false) end
        disc.h = DISC_H
        disc.w = opts.disc_spin and DISC_H or math.floor(fi.size / (4 * DISC_H))
        disc.framebytes = disc.w * disc.h * 4
        disc.ready, disc.src = true, srcpath
        msg.verbose(string.format("disc %dx%d x%d frames ready", disc.w, disc.h, disc.frames))
        cb(true)
    end)
end

-- 3/4 disc centred on the card's top-left corner; `frame` picks a rotation frame
-- via the file byte offset (defaults to the current spin frame).
local function disc_show(frame)
    if not (opts.show_disc and disc.ready and card_rect) then return end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    frame = frame or disc.spin_idx or 0
    local sx, sy = ow / RES_X, oh / RES_Y
    local dh = math.floor(oh * opts.disc_size)
    local dw = math.floor(disc.w * (dh / disc.h))
    local cx, cy = card_rect.x * sx, card_rect.y * sy
    mp.command_native({ name = "overlay-add", id = disc.id,
        x = math.floor(cx - dw / 2), y = math.floor(cy - dh / 2),
        file = disc.file, offset = frame * (disc.framebytes or 0), fmt = "bgra",
        w = disc.w, h = disc.h, stride = disc.w * 4, dw = dw, dh = dh })
    disc.shown = true
end

local function disc_spin_stop()
    if disc.spin_timer then disc.spin_timer:kill(); disc.spin_timer = nil end
end

local function disc_spin_start()
    disc_spin_stop()
    if not (opts.disc_spin and opts.show_disc and disc.ready and disc.frames > 1) then return end
    disc.spin_timer = mp.add_periodic_timer(opts.disc_spin_secs / disc.frames, function()
        if not visible then return end
        disc.spin_idx = (disc.spin_idx + 1) % disc.frames
        disc_show(disc.spin_idx)
    end)
end

-- TMDB (async curl) ---------------------------------------------------------

local function curl_json(url, cb)
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "curl", "-sL", "--max-time", "10", url },
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            msg.warn("curl failed (status=" .. tostring(res and res.status) .. ")")
            return cb(nil)
        end
        local okp, data = pcall(utils.parse_json, res.stdout)
        cb(okp and data or nil)
    end)
end

-- id -> metadata card (no local/tech fields; those are merged at show time)
local function tmdb_fetch(id, cb)
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
                poster = r.poster_path, season = id.season, episode = id.episode,
            }
            if id.season and id.episode and r.id then
                local eurl = string.format("%s/tv/%d/season/%d/episode/%d?api_key=%s%s",
                    TMDB, r.id, id.season, id.episode, opts.api_key, lang)
                curl_json(eurl, function(e)
                    if e and e.name then
                        card.episode_title = e.name
                        if e.overview and e.overview ~= "" then card.overview = e.overview end
                        if e.vote_average and e.vote_average > 0 then card.rating = e.vote_average end
                        if e.air_date and e.air_date ~= "" then card.air_date = e.air_date end
                    end
                    cb(card)
                end)
            else
                cb(card)
            end
        end)
    else
        local url = string.format("%s/search/movie?api_key=%s&query=%s%s",
            TMDB, opts.api_key, urlencode(id.query), lang)
        if id.year then url = url .. "&year=" .. id.year end
        curl_json(url, function(d)
            local r = d and d.results and d.results[1]
            if not r then return cb(nil) end
            cb({
                kind = "movie", title = r.title, source = "TMDB",
                year = (r.release_date or ""):sub(1, 4),
                rating = r.vote_average, overview = r.overview, poster = r.poster_path,
            })
        end)
    end
end

-- Tvheadend live-TV EPG (async curl) ----------------------------------------
-- Resolve the played stream to a channel, then fetch its current programme.
-- The stream URL carries a numeric channelid; TVH's own /playlist/channels maps
-- that id -> channel uuid (the tvg-id), so we key off the URL (robust). A
-- /stream/channel/<uuid> URL is used directly; the channel name (mpv's
-- media-title) is the last-resort fallback.

local tvh_map = nil -- { id2uuid = {channelid -> uuid}, name2uuid = {name -> uuid} }

-- Fetch + parse TVH's M3U playlist once: pairs of an #EXTINF (tvg-id + name)
-- line and the following /stream/channelid/<N> URL.
local function tvh_get_map(cb)
    if tvh_map then return cb(tvh_map) end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "curl", "-sL", "--max-time", "10", opts.tvheadend_url .. "/playlist/channels" },
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            msg.warn("tvheadend playlist fetch failed"); return cb(nil)
        end
        local m = { id2uuid = {}, name2uuid = {} }
        local uuid, name
        for line in res.stdout:gmatch("[^\r\n]+") do
            local u = line:match('tvg%-id="([^"]+)"')
            if u then
                uuid = u
                name = line:match(",%s*(.-)%s*$")
                if name then name = name:gsub("^%b{}%s*", "") end -- strip {.} / {@} markers
            else
                local cid = line:match("/stream/channelid/(%d+)")
                if cid and uuid then
                    m.id2uuid[cid] = uuid
                    if name and name ~= "" then m.name2uuid[name:lower()] = uuid end
                    uuid, name = nil, nil
                end
            end
        end
        tvh_map = m
        cb(m)
    end)
end

-- Path (or media-title) -> channel uuid, else nil.
local function tvh_resolve(path, chan_name, cb)
    local direct = path:match("/stream/channel/([%x][%x%-]+)") -- URL is already a uuid
    if direct then return cb(direct) end
    tvh_get_map(function(m)
        if not m then return cb(nil) end
        local cid = path:match("/stream/channelid/(%d+)")
        if cid and m.id2uuid[cid] then return cb(m.id2uuid[cid]) end
        if chan_name and chan_name ~= "" then -- fall back to the channel name
            local uuid = m.name2uuid[chan_name:lower()]
            if not uuid then -- ignore a trailing HD/UHD/FHD marker on either side
                local base = chan_name:lower():gsub("%s+[uf]?hd$", "")
                for nm, u in pairs(m.name2uuid) do
                    if nm:gsub("%s+[uf]?hd$", "") == base then uuid = u; break end
                end
            end
            return cb(uuid)
        end
        cb(nil)
    end)
end

-- Resolve the channel -> its current programme card (or nil). entries[1] is the
-- programme on now; entries[2..] are what follows, kept as an `upcoming` list.
local function tvh_fetch(path, chan_name, cb)
    tvh_resolve(path, chan_name, function(uuid)
        if not uuid then return cb(nil) end
        local want = math.max(0, math.floor(tonumber(opts.live_upcoming) or 0))
        curl_json(string.format("%s/api/epg/events/grid?channel=%s&limit=%d",
            opts.tvheadend_url, urlencode(uuid), want + 1), function(e)
            local ev = e and e.entries and e.entries[1]
            if not ev then return cb(nil) end
            local upcoming = {}
            for i = 2, math.min(#e.entries, want + 1) do
                local nx = e.entries[i]
                if nx and nx.title and nx.title ~= "" then
                    upcoming[#upcoming + 1] = { title = nx.title, start = tonumber(nx.start) }
                end
            end
            cb({
                kind = "livetv", source = "TVheadend",
                channel = ev.channelName or chan_name,
                title = ev.title,
                subtitle = (ev.subtitle and ev.subtitle ~= "") and ev.subtitle or ev.episodeOnscreen,
                overview = ev.summary or ev.description,
                start = tonumber(ev.start), stop = tonumber(ev.stop),
                upcoming = upcoming,
            })
        end)
    end)
end

-- Tvheadend tuner signal (async curl) --------------------------------------
-- Signal/SNR live on the DVB *input*; the channel lives on the *subscription*;
-- they join by the input name being the prefix of the subscription's service.
-- Values are scale-tagged: 1 = relative (0..65535 → %), 2 = decibel (milli-dB →
-- dB/dBm), 0 = unknown. Bitrate is the per-channel subscription rate (never the
-- input's whole-transponder bps). cb(nil) when there is no RF telemetry.

-- Convert a scaled Tvheadend value: returns (value, is_percent) or nil.
local function tvh_scaled(v, scale)
    v, scale = tonumber(v), tonumber(scale)
    if not v or not scale or scale == 0 then return nil end
    if scale == 1 then return v / 65535 * 100, true end -- relative %
    if scale == 2 then return v / 1000, false end       -- decibel (milli-dB)
    return nil
end

-- Per-metric quality level 1..4: % (relative), dB (SNR), dBm (signal strength).
-- Rough DVB-S ballparks — they drive the meter fill + colour only.
local function level_pct(p) return (p >= 80 and 4) or (p >= 60 and 3) or (p >= 40 and 2) or 1 end
local function level_db(d)  return (d >= 12 and 4) or (d >= 9 and 3) or (d >= 6 and 2) or 1 end
local function level_dbm(s) return (s >= -45 and 4) or (s >= -55 and 3) or (s >= -65 and 2) or 1 end

-- BGR colour (ASS is &HBBGGRR&) for a level: 3-4 green, 2 amber, 1 red.
local function tier_color(t)
    if t >= 3 then return "78C878" end -- green
    if t == 2 then return "18C5F5" end -- amber (BGR!)
    return "5050E0"                    -- red
end

-- Normalise a TVH channel label: drop TVH's leading space + a {.}/{@} marker,
-- lowercase, tolerate a trailing HD/UHD/FHD marker (matches tvh_resolve).
local function chan_norm(s)
    s = tostring(s or ""):gsub("^%s*", ""):gsub("^%b{}%s*", ""):lower()
    return (s:gsub("%s+[uf]?hd$", ""))
end

-- Mux (transponder) parameters, fetched once and memoised: name -> {delsys,
-- freq (kHz), symrate (sym/s), mod, fec, pol}. The mux name equals the first
-- token of an input's `stream` field (e.g. "11641H in Astra 28.2E" -> "11641H").
local tvh_muxes = nil
local function tvh_get_muxes(cb)
    if tvh_muxes then return cb(tvh_muxes) end
    curl_json(opts.tvheadend_url .. "/api/mpegts/mux/grid?limit=1000", function(d)
        local m = {}
        if d and d.entries then
            for _, e in ipairs(d.entries) do
                if e.name and e.delsys then -- DVB muxes carry delsys; IPTV ones don't
                    m[e.name] = { delsys = e.delsys, freq = tonumber(e.frequency),
                        symrate = tonumber(e.symbolrate), mod = e.modulation,
                        fec = e.fec, pol = e.polarisation }
                end
            end
        end
        tvh_muxes = m
        cb(m)
    end)
end

local function tvh_signal(chan_name, cb)
    local want = chan_norm(chan_name)
    curl_json(opts.tvheadend_url .. "/api/status/subscriptions", function(subs)
        local list = subs and subs.entries
        if not list then return cb(nil) end
        -- Pick our subscription: prefer client=="libmpv"; disambiguate by name
        -- only when more than one exists. Any named match is a last resort.
        local mpvsubs, namematch = {}, nil
        for _, s in ipairs(list) do
            if s.service and s.service ~= "" then
                if s.client == "libmpv" then mpvsubs[#mpvsubs + 1] = s end
                if chan_norm(s.channel) == want then namematch = namematch or s end
            end
        end
        local chosen
        if #mpvsubs == 1 then
            chosen = mpvsubs[1]
        elseif #mpvsubs > 1 then
            for _, s in ipairs(mpvsubs) do if chan_norm(s.channel) == want then chosen = s; break end end
            chosen = chosen or mpvsubs[1]
        else
            chosen = namematch
        end
        if not chosen then return cb(nil) end
        local service = chosen.service
        local rate = tonumber(chosen.out) or tonumber(chosen["in"]) -- bytes/s (prefer delivered)

        curl_json(opts.tvheadend_url .. "/api/status/inputs", function(inps)
            local ilist = inps and inps.entries
            if not ilist then return cb(nil) end
            -- Join by plain-string prefix (input name has Lua magic chars).
            local inp
            for _, it in ipairs(ilist) do
                local nm = it.input
                if nm and nm ~= "" and service:sub(1, #nm) == nm
                    and service:sub(#nm + 1, #nm + 1) == "/" then
                    inp = it; break
                end
            end
            if not inp then -- fallback: exactly one active input (one tuner in use)
                local active = {}
                for _, it in ipairs(ilist) do
                    if (tonumber(it.subs) or 0) >= 1 then active[#active + 1] = it end
                end
                if #active == 1 then inp = active[1] end
            end
            if not inp then return cb(nil) end

            local rd = { ber = tonumber(inp.ber) or 0, unc = tonumber(inp.unc) or 0 }
            rd.clean = (rd.ber == 0 and rd.unc == 0)
            local sv, sp = tvh_scaled(inp.signal, inp.signal_scale)
            if sv then
                rd.sig, rd.sig_unit = sv, (sp and "%" or "dBm")
                rd.sig_level = sp and level_pct(sv) or level_dbm(sv)
            end
            local nv, np = tvh_scaled(inp.snr, inp.snr_scale)
            if nv then
                rd.snr, rd.snr_unit = nv, (np and "%" or "dB")
                rd.snr_level = np and level_pct(nv) or level_db(nv)
            end
            if not rd.sig and not rd.snr then return cb(nil) end -- no RF telemetry (scale 0)
            if rate then rd.mbps = rate * 8 / 1e6 end
            local muxname = (inp.stream or ""):match("^(%S+)") -- e.g. "11641H"
            if muxname then
                if tvh_muxes then rd.mux = tvh_muxes[muxname]
                else tvh_get_muxes(function() end) end -- warm the cache for the next poll
            end
            cb(rd)
        end)
    end)
end

-- Re-read the current programme from the EPG for the live channel. Called each
-- time the card is shown, so it stays current across programme boundaries (the
-- EPG is otherwise only fetched on channel change).
local function live_refresh()
    if not live_ctx then return end
    local ctx, gen = live_ctx, current_gen
    tvh_fetch(ctx.path, ctx.chan, function(card)
        if card and gen == current_gen and live_ctx == ctx then
            cur_card = card
            if visible then render() end
        end
    end)
end

-- Poll the tuner signal for the live channel and update cur_signal (kept apart
-- from cur_card so the EPG refresh's wholesale `cur_card = card` can't wipe it).
-- Guarded like live_refresh, plus an in-flight flag so a slow poll (two chained
-- curls) can't stack under the periodic timer / short interval.
local function live_signal_refresh()
    if not (live_ctx and opts.live_signal) then return end
    if signal_inflight then return end
    signal_inflight = true
    local ctx, gen = live_ctx, current_gen
    tvh_signal(ctx.chan, function(rd)
        signal_inflight = false -- cb always fires exactly once (all paths), so this clears every time
        if gen ~= current_gen or live_ctx ~= ctx or not opts.live_signal then return end
        cur_signal = rd
        if visible then render() end
    end)
end

-- Render --------------------------------------------------------------------

-- Rounded-rectangle ASS drawing path (corners approximated with beziers).
local function rrect(w, h, r)
    r = math.max(0, math.min(r, math.floor(w / 2), math.floor(h / 2)))
    return string.format(
        "m %d 0 l %d 0 b %d 0 %d 0 %d %d l %d %d b %d %d %d %d %d %d l %d %d b 0 %d 0 %d 0 %d l 0 %d b 0 0 0 0 %d 0",
        r, w - r, w, w, w, r, w, h - r, w, h, w, h, w - r, h, r, h, h, h, h - r, r, r)
end

-- 5-star string + BGR colour from a 0-10 score.
local function star_rating(score)
    local n = math.max(0, math.min(5, math.floor(score / 2 + 0.5)))
    local stars = string.rep("\226\152\133", n) .. string.rep("\226\152\134", 5 - n) -- ★ ☆
    local color = (score >= 7.5) and "78C878" or (score >= 5) and "18C5F5" or "5050E0"
    return stars, color
end

-- ISO date (YYYY-MM-DD) -> "28 Aug 2011"; passes through anything else.
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local function fmt_date(iso)
    local y, m, d = tostring(iso or ""):match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return iso end
    return string.format("%d %s %s", tonumber(d), MONTHS[tonumber(m)] or m, y)
end

local function res_label(w)
    if not w then return nil end
    if w >= 3800 then return "4K" end
    if w >= 1900 then return "1080p" end
    if w >= 1200 then return "720p" end
    return "SD"
end

-- Tech-pill quality tiers → {bg, fg} (ASS BGR). Colour encodes how good a spec
-- is at a glance: gold = premium, green = good, grey = standard, dim = legacy.
local PILL_TIER = {
    gold = { "18C5F5", "000000" }, -- premium  (matches the HDR pill / IMDb gold)
    good = { "78C878", "000000" }, -- good     (the card's quality-green)
    std  = { "3A3A3A", "FFFFFF" }, -- standard (the old flat pill)
    dim  = { "2A2A2A", "A0A0A0" }, -- legacy/low
}

-- Exact-match tiers for the enumerable specs (values come straight from
-- res_label / chan_label, so the keys are the only strings they can produce).
local RES_TIER  = { ["4K"] = "gold", ["1080p"] = "good", ["720p"] = "std", SD = "dim" }
local CHAN_TIER = { ["7.1"] = "gold", ["5.1"] = "good", Stereo = "std", Mono = "dim" }

-- Codec tiers keyed by the uppercased mpv codec token; unknowns fall back to
-- "std" (never dim — an unrecognised codec is likely just newer than this list).
local VCODEC_TIER = {
    HEVC = "good", H265 = "good", AV1 = "good", VP9 = "good",
    H264 = "std", AVC = "std", VP8 = "std",
    MPEG2VIDEO = "dim", MPEG2 = "dim", MPEG1VIDEO = "dim", VC1 = "dim",
    MPEG4 = "dim", MSMPEG4V3 = "dim", WMV3 = "dim",
}
local ACODEC_TIER = {
    TRUEHD = "gold", MLP = "gold", FLAC = "gold", ALAC = "gold", DTSHD = "gold",
    EAC3 = "good", AAC = "good", OPUS = "good", DTS = "good", VORBIS = "good",
    AC3 = "std", -- PCM* handled by prefix below
    MP3 = "dim", MP2 = "dim", WMAV1 = "dim", WMAV2 = "dim",
}

-- kind + value → tier name. Kinds: res, chan, hdr, vcodec, acodec, fps.
local function pill_tier(kind, v)
    if not v then return "std" end
    if kind == "res"    then return RES_TIER[v] or "std" end
    if kind == "chan"   then return CHAN_TIER[v] or "std" end
    if kind == "hdr"    then return "gold" end
    if kind == "vcodec" then return VCODEC_TIER[v] or "std" end
    if kind == "acodec" then
        if v:match("^PCM") then return "std" end
        return ACODEC_TIER[v] or "std"
    end
    return "std" -- fps + anything else: neutral (informational, not a quality tier)
end

-- kind + value → (bg, fg) ASS BGR colours for a tech pill.
local function pill_colors(kind, v)
    local c = PILL_TIER[pill_tier(kind, v)] or PILL_TIER.std
    return c[1], c[2]
end

-- Format a scaled tuner metric: "72%" (relative) or "-42.9 dBm" / "12.3 dB".
local function fmt_metric(v, unit)
    if unit == "%" then return string.format("%d%%", math.floor(v + 0.5)) end
    return string.format("%.1f %s", v, unit)
end

-- Approx rendered width (virtual px) of a UTF-8 string at font size fs — libass
-- has no text-measure API, so we sum per-character advances (slightly generous so
-- runs never overlap). Per-char (not flat) keeps label→meter gaps consistent
-- regardless of how narrow the letters are (e.g. "Signal " vs "SNR ").
local function text_w(s, fs)
    local w, i, n = 0, 1, #s
    while i <= n do
        local b = s:byte(i)
        if b < 128 then
            local c = s:sub(i, i)
            if c == " " or c:match("[iIjl.,:;!'|]") then w = w + 0.32
            elseif c:match("[ftr()%-]") then w = w + 0.42
            elseif c == "m" or c == "w" or c == "M" or c == "W" then w = w + 0.95
            elseif c:match("[A-Z]") or c == "%" then w = w + 0.72
            else w = w + 0.62 end
            i = i + 1
        else -- multibyte glyph: count as one wide symbol, skip continuation bytes
            w = w + 0.75; i = i + 1
            while i <= n and s:byte(i) >= 128 and s:byte(i) < 192 do i = i + 1 end
        end
    end
    return w * fs
end

-- Split a UTF-8 string into a list of whole characters (multibyte-safe), so we
-- never break in the middle of a glyph when wrapping.
local function utf8_chars(s)
    local t, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local len = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
        t[#t + 1] = s:sub(i, i + len - 1)
        i = i + len
    end
    return t
end

-- Pixel-aware wrap: break `text` into at most `maxlines` lines that each fit
-- `maxw` virtual px at font size `fs` (measured via text_w). Unlike wrap(), this
-- breaks WITHIN a token, so a space-less filename (dot/underscore separated)
-- still wraps. Prefers a break just after a separator ( . _ - / ,); hard-breaks
-- an over-long run; ellipsizes when content overflows maxlines.
local WRAP_SEP = { [" "] = true, ["."] = true, ["_"] = true,
    ["-"] = true, ["/"] = true, [","] = true }
local function wrap_px(text, maxw, fs, maxlines)
    local chars = utf8_chars(text)
    local lines, line, lastsep = {}, {}, nil -- lastsep: index in `line` after a separator
    local truncated = false
    local function scan_sep() -- recompute lastsep over the current `line`
        lastsep = nil
        for i = 1, #line do if WRAP_SEP[line[i]] then lastsep = i end end
    end
    for idx, ch in ipairs(chars) do
        line[#line + 1] = ch
        if WRAP_SEP[ch] then lastsep = #line end
        if #line > 1 and text_w(table.concat(line), fs) > maxw then
            local cut = (lastsep and lastsep < #line) and lastsep or (#line - 1)
            local head, rest = {}, {}
            for i = 1, cut do head[i] = line[i] end
            for i = cut + 1, #line do rest[#rest + 1] = line[i] end
            lines[#lines + 1] = table.concat(head)
            line = rest
            scan_sep()
            if #lines >= maxlines then
                truncated = (idx < #chars) or (#line > 0)
                break
            end
        end
    end
    if not truncated and #line > 0 then lines[#lines + 1] = table.concat(line) end
    if truncated and #lines > 0 then
        lines[#lines] = (lines[#lines]:gsub("[%s%.]+$", "")) .. "\226\128\166" -- …
    end
    return lines
end

-- Single-line fit: return `text` unchanged if it fits `maxw` at `fs`; else keep
-- the leading portion that fits and append an ellipsis. The cut snaps back to the
-- last separator ( . _ - / ,) when one is close by, so we end on a word boundary
-- rather than slicing mid-token; a separator-less run is hard-cut. Used for the
-- "unknown" card's raw file name, where wrapping a long dotted name reads poorly.
local ELLIPSIS = "\226\128\166" -- …
local function ellipsize_px(text, maxw, fs)
    if text_w(text, fs) <= maxw then return text end
    local chars = utf8_chars(text)
    local line, lastsep = {}, nil
    for _, ch in ipairs(chars) do
        line[#line + 1] = ch
        if WRAP_SEP[ch] then lastsep = #line end
        if text_w(table.concat(line) .. ELLIPSIS, fs) > maxw then
            line[#line] = nil -- drop the char that pushed it over the edge
            if lastsep and lastsep <= #line
                and (#line - lastsep) <= math.max(4, math.floor(#line * 0.33)) then
                for i = #line, lastsep, -1 do line[i] = nil end -- snap to the boundary
            end
            break
        end
    end
    return (table.concat(line):gsub("[%s._/,%-]+$", "")) .. ELLIPSIS -- trim trailing seps
end

-- Display fraction 0..1 for the bar fill (rough ranges — lit count only). Signal
-- dBm fills a 50 dB window whose top is the tuner's configured max (signal_dbm_max,
-- default the observed DS3000 ceiling); % maps directly; SNR dB ~ 0..20.
local function metric_frac(v, unit)
    local f
    if unit == "%" then f = v / 100
    elseif unit == "dBm" then
        local top = tonumber(opts.signal_dbm_max) or -40
        f = (v - (top - 50)) / 50
    else f = v / 20 end -- dB
    return math.max(0, math.min(1, f))
end

local function build_card(c)
    if not c then return "" end
    local x, y, pad = opts.pos_x, opts.pos_y, 24
    if c.has_disc then -- leave room for the disc's left half at the top-left corner
        x = math.max(x, math.floor(opts.disc_size * RES_Y / 2) + 8)
    end
    local bw, content, cy = 860, {}, y + pad
    local innerw = bw - 2 * pad

    -- fade alpha for a given base alpha (00 = opaque), scaled by anim_fade (0..1)
    local function fa(base)
        local a = base + (1 - (anim_fade or 1)) * (255 - base)
        return string.format("%02X", math.max(0, math.min(255, math.floor(a + 0.5))))
    end

    local function line(str, fs, color, bold, ital)
        if not str or str == "" then return end
        content[#content + 1] = string.format(
            "{\\an7\\pos(%d,%d)\\alpha&H%s&\\bord2\\shad1\\3c&H000000&\\1c&H%s&\\fs%d%s%s}%s",
            x + pad, math.floor(cy), fa(0), color, fs,
            bold and "\\b1" or "", ital and "\\i1" or "", ass_escape(str))
        cy = cy + math.floor(fs * 1.25)
    end

    logo_rect = nil
    if c.kind == "livetv" then
        -- Live TV: programme title, channel + episode, plot, a live "now" bar.
        line(c.title and c.title ~= "" and c.title or (c.channel or "Live TV"), 34, "FFFFFF", true)
        local sub = c.channel or ""
        if c.subtitle and c.subtitle ~= "" then
            sub = (sub ~= "" and (sub .. "   \226\128\162   ") or "") .. c.subtitle
        end
        if sub ~= "" then line(sub, 24, "00D7FF") end
        if c.overview and c.overview ~= "" then
            cy = cy + 6
            for _, ln in ipairs(wrap(c.overview, 74, 4)) do line(ln, 22, "C8C8C8") end
        end
        if c.start and c.stop and c.stop > c.start then
            local now = os.time()
            local pct = math.max(0, math.min(100, (now - c.start) / (c.stop - c.start) * 100))
            cy = cy + 12
            local barh = 8
            local fillw = math.max(2, math.floor(innerw * pct / 100))
            local bx = x + pad
            content[#content + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H555555&\\1a&H%s&\\p1}%s{\\p0}",
                bx, math.floor(cy), fa(64), rrect(innerw, barh, 4))
            content[#content + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H00D7FF&\\1a&H%s&\\p1}%s{\\p0}",
                bx, math.floor(cy), fa(0), rrect(fillw, barh, 4))
            cy = cy + barh + 6
            line(string.format("%s \226\128\147 %s   \226\128\162   ends %s",
                os.date("%H:%M", c.start), os.date("%H:%M", c.stop), os.date("%H:%M", c.stop)),
                18, "A0A0A0")
        end
        -- live tuner signal meter: dBm • SNR as a segmented [████░░] gauge (filled
        -- = quality colour, empty = dim) • bitrate • a ✔/✗ health tick. One \pos'd
        -- event assembled from inline {\1c} colour spans (libass advances the pen;
        -- line() can't carry tags). Read from module-level cur_signal so the EPG
        -- refresh can't clobber it; whole row (incl. its gaps) is gated on it.
        -- signal meter row: labels/values as \pos'd text runs, the 8-step meters
        -- as crisp \p1 vector rectangles (same drawing mechanism as the card's
        -- rounded box / progress bars) for full-pixel smoothness. A left-to-right
        -- cursor `cx` places each piece — text widths estimated (text_w), meter
        -- widths exact. Each piece keeps its own \pos so the bottom-anchor shift
        -- still moves the whole row.
        if cur_signal then
            local sg = cur_signal
            cy = cy + 8
            local fs = 18
            local DIM, TXT = "A0A0A0", "C8C8C8" -- label / value (BGR)
            local cx, y0 = x + pad, cy
            local function put(str, color)
                content[#content + 1] = string.format(
                    "{\\an7\\pos(%d,%d)\\bord2\\shad1\\3c&H000000&\\1c&H%s&\\fs%d}%s",
                    math.floor(cx), math.floor(y0), color, fs, ass_escape(str))
                cx = cx + text_w(str, fs)
            end
            local function sepc() cx = cx + 34 end -- fixed gap between groups (no bullet)

            -- 8-step vector meter (no frame): dim + lit bars, each a \p1 drawing at
            -- the same \pos (separate events don't share the pen).
            local NB, BW, G, H = 8, 6, 2, 14 -- bars, bar width, gap, height
            local WM = NB * BW + (NB - 1) * G
            local function meter(frac, level)
                local lit = math.max(0, math.min(NB, math.floor(frac * NB + 0.5)))
                local litp, dimp = {}, {}
                for i = 1, NB do
                    local h = math.floor(H * i / NB + 0.5)
                    local bx = (i - 1) * (BW + G)
                    local r = string.format("m %d %d l %d %d %d %d %d %d",
                        bx, H - h, bx + BW, H - h, bx + BW, H, bx, H)
                    if i <= lit then litp[#litp + 1] = r else dimp[#dimp + 1] = r end
                end
                local function draw(color, path)
                    content[#content + 1] = string.format(
                        "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\p1}%s{\\p0}",
                        math.floor(cx), math.floor(y0), color, path)
                end
                if #dimp > 0 then draw("555555", table.concat(dimp, " ")) end
                if #litp > 0 then draw(tier_color(level or 1), table.concat(litp, " ")) end
                cx = cx + WM + 6 -- trailing breathing room before the value
            end

            local wrote = false
            if sg.sig then
                put("Signal ", DIM); meter(metric_frac(sg.sig, sg.sig_unit), sg.sig_level)
                put(fmt_metric(sg.sig, sg.sig_unit), TXT); wrote = true
            end
            if sg.snr then
                if wrote then sepc() end
                put("SNR ", DIM); meter(metric_frac(sg.snr, sg.snr_unit), sg.snr_level)
                put(fmt_metric(sg.snr, sg.snr_unit), TXT); wrote = true
            end
            if sg.mbps then
                if wrote then sepc() end
                put(string.format("%.1f Mbps", sg.mbps), TXT); wrote = true
            end
            if wrote then sepc() end
            put(sg.clean and "\226\156\148" or "\226\156\151", sg.clean and "78C878" or "5050E0")
            cy = cy + math.floor(fs * 1.25)
        end
        -- transponder line: delivery system, polarisation and modulation as pill
        -- badges (tech-pill style); frequency + symbol rate as plain text between.
        if cur_signal and cur_signal.mux then
            local m = cur_signal.mux
            cy = cy + 8
            local tfs, y0 = 17, cy
            local cx = x + pad
            local function txt(s)
                content[#content + 1] = string.format(
                    "{\\an7\\pos(%d,%d)\\bord2\\shad1\\3c&H000000&\\1c&H8C8C8C&\\fs%d}%s",
                    math.floor(cx), math.floor(y0), tfs, ass_escape(s))
                cx = cx + text_w(s, tfs)
            end
            local function pill(s, bg, fg)
                local padx, ph = 8, tfs + 8
                local pw = math.floor(text_w(s, tfs) + 2 * padx)
                content[#content + 1] = string.format(
                    "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}%s{\\p0}",
                    math.floor(cx), math.floor(y0 - 4), bg, fa(16), rrect(pw, ph, 7))
                content[#content + 1] = string.format(
                    "{\\an7\\pos(%d,%d)\\alpha&H%s&\\bord0\\shad0\\1c&H%s&\\fs%d\\b1}%s",
                    math.floor(cx + padx), math.floor(y0), fa(0), fg, tfs, ass_escape(s))
                cx = cx + pw + 8
            end
            local ACC = "00D7FF" -- card accent (gold, BGR): delivery system + modulation
            pill(m.delsys or "DVB-S", ACC, "000000")
            if m.freq then cx = cx + 2; txt(string.format("%d MHz", math.floor(m.freq / 1000 + 0.5))); cx = cx + 8 end
            -- polarisation colour-coded (BGR): V = blue, H = violet — distinct from the quality colours
            if m.pol then pill(m.pol, (m.pol == "V") and "F5963C" or "F082B4", "FFFFFF") end
            if m.symrate then cx = cx + 2; txt(string.format("%.1f MSym/s", m.symrate / 1e6)); cx = cx + 8 end
            if m.mod and m.mod ~= "" then
                local mod = (m.mod:gsub("PSK/8", "8PSK"))
                if m.fec and m.fec ~= "AUTO" and m.fec ~= "NONE" then mod = mod .. " " .. m.fec end
                pill(mod, ACC, "000000")
            end
            cy = y0 + tfs + 8
        end
        if c.upcoming and #c.upcoming > 0 then
            cy = cy + 6
            line("Up next", 18, "00D7FF", true)
            -- Fit each row to the card's inner width rather than a fixed char
            -- count. The OSD sans font averages ~0.5*fs px per glyph (matches
            -- the overview wrap's 74 chars @ fs22); mpv exposes no text-measure
            -- API, so this is an estimate and wrap() still ellipsizes overruns.
            local fs = 18
            local budget = math.floor(innerw / (fs * 0.5))
            for _, up in ipairs(c.upcoming) do
                local pfx = up.start and (os.date("%H:%M", up.start) .. "   ") or ""
                local title = wrap(up.title, math.max(8, budget - #pfx), 1)[1] or up.title
                line(pfx .. title, fs, "8C8C8C")
            end
        end
    else
    -- heading: text title, OR a reserved slot the clearlogo bitmap fills in
    if c.has_logo then
        cy = y + 8 -- logo hugs the card's top edge
        local band = math.floor(opts.logo_height * RES_Y)
        if clearlogo.ready and clearlogo.w and clearlogo.h and clearlogo.h > 0 then
            local w_at = clearlogo.w / clearlogo.h * band -- fit width to the card
            if w_at > 812 then band = math.floor(812 * clearlogo.h / clearlogo.w) end
        end
        logo_rect = { x = x + pad, y = cy, h = band }
        cy = cy + band + LOGO_GAP -- clear the logo band (autocrop makes band == artwork)
        if c.year and c.year ~= "" then line(tostring(c.year), 20, "B4B4B4") end
    else
        local head = c.title or "Unknown"
        if c.year and c.year ~= "" then head = head .. "  (" .. c.year .. ")" end
        -- Fit the heading to the card: keep the big font when it fits on one line,
        -- otherwise drop to a smaller size. The "unknown" card's raw file name is
        -- kept to ONE line, tail-ellipsised at a separator (wrapping a long dotted
        -- name reads poorly); a real movie/TV title wraps instead, so no meaningful
        -- words are hidden.
        local hfs = 38
        if text_w(head, hfs) > innerw then hfs = 28 end
        if c.kind == "unknown" then
            line(ellipsize_px(head, innerw, hfs), hfs, "FFFFFF", true)
        else
            for _, hl in ipairs(wrap_px(head, innerw, hfs, 3)) do line(hl, hfs, "FFFFFF", true) end
        end
    end

    -- tagline (italic)
    if c.tagline and c.tagline ~= "" then line(c.tagline, 20, "A0A0A0", false, true) end

    -- TV: SxxEyy · Episode Title
    if c.kind == "tv" and c.season and c.episode then
        local sub = string.format("S%02dE%02d", c.season, c.episode)
        if c.ep_total and c.ep_total > 0 then sub = sub .. string.format(" (/%d)", c.ep_total) end
        if c.episode_title and c.episode_title ~= "" then sub = sub .. "   " .. c.episode_title end
        line(sub, 25, "00D7FF")
    end

    -- rating: colour-coded stars, plus a source pill (e.g. TMDB) right-aligned on
    -- the row when the shown rating is remote-sourced (c.rating_src).
    local rscore = tonumber(c.rating)
    if rscore and rscore > 0 then
        local stars, scolor = star_rating(rscore)
        local ry = cy
        line(string.format("%s  %.1f", stars, rscore), 23, scolor, true)
        if c.rating_src and c.rating_src ~= "" then
            local t, pfs, ph, ppadx = c.rating_src, 15, 24, 9
            local pw = math.floor(#t * pfs * 0.62 + 2 * ppadx)
            local ppx = x + pad + innerw - pw -- right-align to the card inner width
            content[#content + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}%s{\\p0}",
                ppx, math.floor(ry + 2), "E4B401", fa(16), rrect(pw, ph, 8))
            content[#content + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\alpha&H%s&\\bord0\\shad0\\1c&H%s&\\fs%d\\b1}%s",
                ppx + ppadx, math.floor(ry + 6), fa(0), "FFFFFF", pfs, ass_escape(t))
        end
    end

    -- meta: aired · runtime · mpaa
    local meta = {}
    local aired = c.aired or c.air_date
    if aired and aired ~= "" then meta[#meta + 1] = "Aired " .. fmt_date(aired) end
    if c.runtime and tonumber(c.runtime) then meta[#meta + 1] = string.format("%d min", c.runtime) end
    if c.mpaa and c.mpaa ~= "" then meta[#meta + 1] = c.mpaa end
    if #meta > 0 then line(table.concat(meta, "   \226\128\162   "), 21, "B4B4B4") end

    -- genres (slightly larger + bold)
    if c.genres and #c.genres > 0 then
        local g = {}
        for i = 1, math.min(3, #c.genres) do g[i] = c.genres[i] end
        line(table.concat(g, "  \226\128\162  "), 24, "DCDCDC", true)
    end

    -- overview
    if c.overview and c.overview ~= "" then
        cy = cy + 6
        for _, ln in ipairs(wrap(c.overview, 74, 3)) do line(ln, 22, "C8C8C8") end
    end

    -- director / studio
    local credit = {}
    if c.director and c.director ~= "" then credit[#credit + 1] = "Directed by " .. c.director end
    if c.studio and c.studio ~= "" then credit[#credit + 1] = c.studio end
    if #credit > 0 then cy = cy + 4; line(table.concat(credit, "   \226\128\162   "), 19, "A0A0A0") end

    -- cast (amber, bold) — up to 5 names packed onto at most 2 lines
    if c.cast and #c.cast > 0 then
        local names = {}
        for i = 1, math.min(5, #c.cast) do names[#names + 1] = c.cast[i] end
        cy = cy + 4
        local budget, rows, cur = 58, {}, ""
        for _, nm in ipairs(names) do
            local piece = (cur == "") and nm or (cur .. ", " .. nm)
            if #piece > budget and cur ~= "" then
                rows[#rows + 1] = cur .. ","
                cur = nm
                if #rows >= 2 then break end
            else
                cur = piece
            end
        end
        if cur ~= "" and #rows < 2 then rows[#rows + 1] = cur end
        for _, r in ipairs(rows) do line(r, 22, "00D7FF", true) end
    end

    -- local file details — read live from mpv properties at render time
    if opts.show_tech then
        local tt = gather_tech()

        -- pill badges: resolution · HDR · video codec · audio codec · channels ·
        -- fps — each tier-coloured (gold/green/grey/dim) by pill_colors().
        local pills = {}
        local function add(kind, text)
            if not text then return end
            local bg, fg = pill_colors(kind, text)
            pills[#pills + 1] = { t = text, bg = bg, fg = fg }
        end
        add("res", res_label(tt.vwidth))
        add("hdr", tt.hdr)
        add("vcodec", tt.vcodec)
        add("acodec", tt.acodec)
        add("chan", tt.achan)
        add("fps", tt.fps and (tt.fps .. "FPS") or nil) -- e.g. "24FPS" / "23.976FPS" / "50FPS"
        if #pills > 0 then
            cy = cy + 8
            local ph, pfs, ppadx, pgap, charw = 30, 18, 12, 8, 18 * 0.62
            local px = x + pad
            for _, p in ipairs(pills) do
                local pw = math.floor(#p.t * charw + 2 * ppadx)
                content[#content + 1] = string.format(
                    "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}%s{\\p0}",
                    px, math.floor(cy), p.bg, fa(16), rrect(pw, ph, 8))
                content[#content + 1] = string.format(
                    "{\\an7\\pos(%d,%d)\\alpha&H%s&\\bord0\\shad0\\1c&H%s&\\fs%d\\b1}%s",
                    px + ppadx, math.floor(cy + 5), fa(0), p.fg, pfs, ass_escape(p.t))
                px = px + pw + pgap
            end
            cy = cy + ph
        end

        -- audio / subtitle languages
        local as = {}
        if tt.audio then as[#as + 1] = "Audio: " .. tt.audio end
        if tt.subs then as[#as + 1] = "Subs: " .. tt.subs end
        if #as > 0 then cy = cy + 6; line(table.concat(as, "    "), 18, "8C8C8C") end

        -- duration · chapters · size
        local d = {}
        if tt.dur then d[#d + 1] = tt.dur end
        if tt.chapters and tt.chapters > 0 then d[#d + 1] = string.format("%d chapters", tt.chapters) end
        if tt.size then d[#d + 1] = tt.size end
        if #d > 0 then cy = cy + 4; line(table.concat(d, "  \226\128\162  "), 18, "8C8C8C") end

        -- live progress bar
        local pct = mp.get_property_number("percent-pos")
        if pct and pct > 0.5 and pct < 99.5 then
            cy = cy + 12
            local barh = 8
            local fillw = math.max(2, math.floor(innerw * pct / 100))
            local bx = x + pad
            content[#content + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H555555&\\1a&H%s&\\p1}%s{\\p0}",
                bx, math.floor(cy), fa(64), rrect(innerw, barh, 4))
            content[#content + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H00D7FF&\\1a&H%s&\\p1}%s{\\p0}",
                bx, math.floor(cy), fa(0), rrect(fillw, barh, 4))
            cy = cy + barh + 6
            local rem, tp = mp.get_property_number("time-remaining"), mp.get_property_number("time-pos")
            local info = string.format("%d%%", math.floor(pct + 0.5))
            if tp and rem then
                info = fmt_duration(tp) .. " / " .. fmt_duration(tp + rem)
                    .. "   \226\128\162   ends " .. os.date("%H:%M", os.time() + math.floor(rem))
            end
            line(info, 17, "A0A0A0")
        end
    end

    end -- close the livetv / movie-tv content branch

    local bh = (cy - y) + pad
    card_rect = { x = x, y = y, w = bw, h = bh }
    local out = {}
    -- rounded box with a soft drop shadow
    out[#out + 1] = string.format(
        "{\\an7\\pos(%d,%d)\\bord0\\shad6\\4c&H000000&\\4a&H%s&\\1c&H141414&\\1a&H%s&\\p1}%s{\\p0}",
        x, y, fa(96), fa(51), rrect(bw, bh, 16))
    -- inset accent bar (thin)
    out[#out + 1] = string.format(
        "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H00D7FF&\\1a&H%s&\\p1}m 0 0 l 3 0 3 %d 0 %d{\\p0}",
        x + 3, y + 16, fa(0), bh - 32, bh - 32)
    for _, l in ipairs(content) do out[#out + 1] = l end

    -- Bottom-anchor: shift every element's \pos so the box bottom sits at
    -- RES_Y - pos_y, i.e. the card hugs the bottom and grows upward.
    if opts.anchor == "bottom" then
        local new_top = math.max(opts.pos_y, RES_Y - opts.pos_y - bh)
        card_rect.y = new_top
        local shift = new_top - y
        if shift ~= 0 then
            for i = 1, #out do
                out[i] = out[i]:gsub("\\pos%((%-?%d+),(%-?%d+)%)", function(px, py)
                    return string.format("\\pos(%s,%d)", px, tonumber(py) + shift)
                end)
            end
            if logo_rect then logo_rect.y = logo_rect.y + shift end
        end
    end
    return table.concat(out, "\n")
end

render = function()
    if not cur_card then return end
    overlay.data = build_card(cur_card)
    overlay.hidden = false
    overlay:update()
    place_logo()
    disc_show()
end

hide = function()
    if hide_timer then hide_timer:kill(); hide_timer = nil end
    if refresh_timer then refresh_timer:kill(); refresh_timer = nil end
    if signal_timer then signal_timer:kill(); signal_timer = nil end
    overlay:remove()
    fanart_hide()
    poster_hide()
    banner_hide()
    img_remove(clearlogo)
    disc_spin_stop()
    img_remove(disc)
    visible = false
    msg.verbose("hide")
end

-- show(timeout): auto-hide after `timeout`s (nil/0 = stay until toggled).
show = function(timeout)
    if not content_ok then return end
    visible = true
    if live_ctx then live_refresh() end -- re-read the EPG each time the card appears
    render()
    fanart_dismissed, fanart.fade_idx = false, 0 -- restart the fanart's timed window / fade
    fanart_show()
    poster_show()
    banner_show()
    disc_spin_start()

    -- live tuner signal: kill-before-create (show() is re-entered without hide()
    -- on channel change / live→file), an immediate reading, then poll on its own
    -- cadence. Recreated only for a live card with the feature on.
    if signal_timer then signal_timer:kill(); signal_timer = nil end
    if live_ctx and opts.live_signal then
        live_signal_refresh()
        local iv = tonumber(opts.live_signal_interval) or 0
        if iv > 0 then
            signal_timer = mp.add_periodic_timer(iv, function()
                if visible then live_signal_refresh() end
            end)
        end
    end

    -- live-refresh the progress bar / ETA while the card is visible
    if refresh_timer then refresh_timer:kill() end
    refresh_timer = mp.add_periodic_timer(1, function() if visible then render() end end)

    if hide_timer then hide_timer:kill(); hide_timer = nil end
    if timeout and timeout > 0 then hide_timer = mp.add_timeout(timeout, hide) end
    msg.verbose(string.format("show (timeout=%s)", tostring(timeout or 0)))
end

toggle = function()
    if visible then hide() else show(opts.toggle_timeout) end
end

-- Orchestration -------------------------------------------------------------

gather_tech = function()
    local t = {}
    local w, h = mp.get_property_number("width"), mp.get_property_number("height")
    if w and h then t.reso = string.format("%d\195\151%d", w, h) end -- W×H
    t.vwidth = w
    t.dur = fmt_duration(mp.get_property_number("duration"))

    local vc = mp.get_property("current-tracks/video/codec")
    if vc then t.vcodec = vc:upper() end

    local gamma = mp.get_property("video-params/gamma")
    if gamma == "pq" then t.hdr = "HDR10" elseif gamma == "hlg" then t.hdr = "HLG" end

    t.fps = fmt_fps(mp.get_property_number("container-fps")
        or mp.get_property_number("estimated-vf-fps"))

    local ext = (mp.get_property("path") or ""):match("%.([%a%d]+)$")
    if ext then t.container = ext:upper() end
    t.size = human_size(mp.get_property_number("file-size"))
    t.chapters = mp.get_property_number("chapters")

    -- Audio / subtitle languages (deduped by language, in order).
    local a_order, a_set, sel_lang, sel_ch, sel_codec = {}, {}, nil, nil, nil
    local s_order, s_set, s_forced = {}, {}, {}
    for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
        if tr.type == "audio" then
            local L = (tr.lang or "und"):upper()
            if tr.selected then
                sel_lang, sel_ch = L, chan_label(tr["demux-channel-count"])
                sel_codec = tr.codec and tr.codec:upper() or nil
            end
            if not a_set[L] then a_set[L] = true; a_order[#a_order + 1] = L end
        elseif tr.type == "sub" then
            local L = (tr.lang or "und"):upper()
            if not s_set[L] then s_set[L] = true; s_order[#s_order + 1] = L end
            if tr.forced then s_forced[L] = true end
        end
    end
    local a = {}
    for _, L in ipairs(a_order) do
        a[#a + 1] = (L == sel_lang and sel_ch) and (L .. " " .. sel_ch) or L
    end
    local s = {}
    for _, L in ipairs(s_order) do s[#s + 1] = s_forced[L] and (L .. "(f)") or L end

    local function join(list, max)
        if #list == 0 then return nil end
        local o = {}
        for i = 1, math.min(max, #list) do o[i] = list[i] end
        if #list > max then o[#o + 1] = "+" .. (#list - max) end
        return table.concat(o, ", ")
    end
    t.audio, t.subs = join(a, 4), join(s, 6)
    t.achan, t.acodec = sel_ch, sel_codec

    msg.verbose(string.format("tech: %s/%s %s %s %s | A:%s S:%s | chapters:%s %s",
        t.vcodec or "-", t.acodec or "-", t.hdr or "-", t.fps or "-", t.reso or "-",
        t.audio or "-", t.subs or "-", tostring(t.chapters or 0), t.size or "-"))
    return t
end

-- True only for a real movie/episode video (not an image, album art, or audio).
local function is_video_playback()
    return mp.get_property("current-tracks/video/codec") ~= nil
        and mp.get_property_native("current-tracks/video/image") ~= true
end

local function on_file_loaded()
    current_gen = current_gen + 1
    local gen = current_gen
    cur_signal = nil -- new file: drop any prior tuner reading (a fresh channel re-polls)
    content_ok = is_video_playback()
    if not content_ok then live_ctx = nil; hide(); return end -- no card for images / audio
    local path = mp.get_property("path") or mp.get_property("filename") or ""

    -- Live TV via Tvheadend EPG (takes priority over file identification).
    if opts.tvheadend_url ~= "" and path:find("/stream/channel") then
        -- No library artwork for a live stream: clear anything from a prior file.
        img_remove(clearlogo); img_remove(disc); disc_spin_stop()
        poster_hide(); fanart_hide(); banner_hide()
        poster.ready, fanart.ready, banner.ready, clearlogo.ready, disc.ready =
            false, false, false, false, false
        logo_rect, card_rect = nil, nil
        live_ctx = { path = path, chan = mp.get_property("media-title") or "" }
        cur_card = { kind = "livetv", title = "Live TV", source = "TVheadend" }
        if opts.auto_show then show(opts.duration) end -- show() reloads the EPG
        return
    end
    live_ctx = nil -- a normal file: leave live-TV mode

    local id = identify(path)
    local poster_path = find_poster(path, id)
    local logo_path = opts.show_logo and find_clearlogo(path, id) or nil
    local disc_path = opts.show_disc and find_disc(path, id) or nil
    local fanart_path = opts.show_fanart and find_fanart(path, id) or nil
    local banner_path = opts.show_banner and find_banner(path, id) or nil

    -- Confidence promotion: identify() returns kind="unknown" when the path
    -- carries no content-type signal (no Movies/Films or TV folder, no SxxEyy).
    -- Any image (artwork or a stray jpg/png) beside the media marks it as a
    -- catalogued movie/TV item, so promote the unknown to its best-effort movie
    -- identity and let TMDB enrich it. Only a bare video with NO image alongside
    -- stays a raw-filename card (no type guess, no remote query). The poster/movie
    -- candidate sets are kind-independent, so no re-scan is needed after promotion.
    if id.kind == "unknown" and id.promote
        and (poster_path or logo_path or disc_path or fanart_path or banner_path
            or dir_has_image(path)) then
        id = id.promote
    end
    local ep_total = (id.kind == "tv") and count_season_episodes(path, id.season) or nil

    local function merged(m)
        local c = {}
        for k, v in pairs(m) do c[k] = v end
        c.poster = c.poster or poster_path
        c.ep_total = c.ep_total or ep_total
        c.has_logo = c.has_logo or (logo_path ~= nil)
        c.has_disc = c.has_disc or (disc_path ~= nil)
        return c
    end

    -- Pick the metadata source: local .nfo (primary) -> cache -> filename.
    local do_tmdb = false
    local localc = read_local(path)
    if localc then
        localc.season = localc.season or id.season
        localc.episode = localc.episode or id.episode
        localc.title = localc.title or id.display -- episode .nfo without <showtitle>: use the path-derived show name
        cur_card = merged(localc)
        msg.verbose("local .nfo: '" .. tostring(localc.title) .. "'"
            .. (poster_path and " [poster]" or ""))
    else
        local cached = cache_get(id.cachekey)
        cur_card = merged(cached or {
            kind = id.kind, title = id.display, year = id.year,
            season = id.season, episode = id.episode, source = "file",
        })
        if cached then cur_card.rating_src = "TMDB" end
        do_tmdb = (not cached) and opts.enrich and opts.api_key ~= "" and id.kind ~= "unknown"
        msg.verbose(string.format("identified %s: '%s'%s%s", id.kind, id.query or id.display or "",
            id.season and string.format(" S%02dE%02d", id.season, id.episode) or "",
            poster_path and " [poster]" or ""))
    end

    -- Rating is a dynamic property: show the freshest cached rating now
    -- (overriding the source rating), and refetch on load when missing/stale.
    -- do_tmdb already returns a rating, so only fetch rating-only when it won't.
    local do_rating = false
    if opts.enrich and opts.api_key ~= "" and (tonumber(opts.rating_ttl) or 0) > 0
        and id.kind ~= "unknown" then
        local rv, rt = rating_get(id.cachekey)
        if rv then cur_card.rating, cur_card.rating_src = rv, "TMDB" end
        if not do_tmdb and rating_stale(rt) then do_rating = true end
    end

    -- Poster image: decode the local jpg (once per poster), show when ready.
    poster_hide()
    if opts.show_poster and poster_path then
        if not (poster.ready and poster.src == poster_path) then
            poster.ready = false
            poster_decode(poster_path, function(ok)
                if ok and gen == current_gen and visible then poster_show() end
            end)
        end
    else
        poster.ready = false
    end

    -- Fanart backdrop: decode the dimmed jpg (once per fanart), show when ready.
    fanart_hide()
    if fanart_path then
        if not (fanart.ready and fanart.src == fanart_path) then
            fanart.ready = false
            fanart_decode(fanart_path, function(ok)
                if ok and gen == current_gen and visible then fanart_show() end
            end)
        end
    else
        fanart.ready = false
    end

    -- Banner: decode the wide title jpg (once per banner), show when ready.
    banner_hide()
    if banner_path then
        if not (banner.ready and banner.src == banner_path) then
            banner.ready = false
            banner_decode(banner_path, function(ok)
                if ok and gen == current_gen and visible then banner_show() end
            end)
        end
    else
        banner.ready = false
    end

    -- Clearlogo (transparent title art, top-left).
    img_remove(clearlogo)
    if logo_path then
        if not (clearlogo.ready and clearlogo.src == logo_path) then
            clearlogo.ready = false
            clearlogo_decode(logo_path, function(ok)
                if ok and gen == current_gen and visible then render() end
            end)
        end
    else
        clearlogo.ready = false
    end

    -- Disc art (3/4, nestled at the card's top-left corner; optional spin).
    img_remove(disc)
    disc_spin_stop()
    disc.spin_idx = 0
    if disc_path then
        if not (disc.ready and disc.src == disc_path) then
            disc.ready = false
            disc_decode(disc_path, function(ok)
                if ok and gen == current_gen and visible then disc_show(); disc_spin_start() end
            end)
        end
    else
        disc.ready = false
    end

    if opts.auto_show then show(opts.duration) end

    if do_tmdb then
        tmdb_fetch(id, function(card)
            if not card then return end
            cache_put(id.cachekey, card)
            rating_put(id.cachekey, card.rating) -- seed the dynamic rating cache
            if gen ~= current_gen then return end
            cur_card = merged(card)
            cur_card.rating_src = "TMDB"
            if visible then render() end
        end)
    elseif do_rating then
        -- rating-only refresh (local .nfo card, or a stale cache hit): update
        -- just the rating, leaving the authoritative source card intact.
        tmdb_fetch(id, function(card)
            local r = card and tonumber(card.rating)
            if not r or r <= 0 then return end
            rating_put(id.cachekey, r)
            if gen ~= current_gen then return end
            cur_card.rating, cur_card.rating_src = r, "TMDB"
            if visible then render() end
        end)
    end
end

-- Wiring --------------------------------------------------------------------

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", hide)
mp.register_event("shutdown", function()
    os.remove(poster.file)
    os.remove(fanart.file)
    os.remove(banner.file)
    os.remove(clearlogo.file)
    os.remove(disc.file)
end)

-- Pop the card while paused (sticky), hide it on resume.
if opts.show_on_pause then
    mp.observe_property("pause", "bool", function(_, paused)
        if paused == nil then return end
        if paused then
            if not visible then show(0) end
        elseif visible then
            hide()
        end
    end)
end

-- Runtime toggle: fanart fade in/out  <->  hard show-then-hide. Flips
-- opts.fanart_fade and re-decodes the current backdrop in the new mode so the
-- switch is visible immediately. Bind by name in input.conf, e.g.:
--   f script-binding spincard/toggle-fanart-fade
local function toggle_fanart_fade()
    opts.fanart_fade = not opts.fanart_fade
    mp.osd_message("spincard: fanart " .. (opts.fanart_fade and "fade in/out" or "show then hide"))
    if not (opts.show_fanart and fanart.ready and fanart.src and not live_ctx) then return end
    local gen = current_gen
    fanart_hide()
    fanart.ready = false
    fanart_dismissed, fanart.fade_idx = false, 0
    fanart_decode(fanart.src, function(ok)
        if ok and gen == current_gen and visible then fanart_show() end
    end)
end

local bind_key = (opts.key ~= "") and opts.key or nil
mp.add_key_binding(bind_key, "toggle", toggle)
mp.add_key_binding(nil, "toggle-fanart-fade", toggle_fanart_fade)

-- The VO/OSD often isn't ready when a poster finishes decoding at playback
-- start, so overlay-add would use a zero size and skip. Re-show once the OSD
-- size is known (also repositions on window resize).
mp.observe_property("osd-width", "number", function(_, w)
    if w and w > 0 and visible then
        if fanart.ready then fanart_show() end
        if poster.ready then poster_show() end
        if banner.ready then banner_show() end
        if clearlogo.ready then place_logo() end
        if disc.ready then disc_show() end
    end
end)

msg.verbose("spincard loaded (identify + tmdb)")
