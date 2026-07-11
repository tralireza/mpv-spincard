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
    tvheadend_url = "",    -- e.g. http://127.0.0.1:9981 — live-TV EPG source ("" = off)
    show_poster   = true,  -- render the local poster image (needs ffmpeg)
    poster_height = 0.42,  -- poster height as a fraction of the video height
    poster_margin = 0.02,  -- gap from the top-right corner (fraction of height; 0 = flush)
    show_tech     = true,  -- local file details (codec/HDR/audio/subs/chapters/…)
    show_fanart    = true, -- dimmed fanart.jpg backdrop (needs ffmpeg)
    fanart_opacity = 0.4,  -- backdrop opacity 0..1 (higher = more visible/darker)
    show_banner    = false, -- wide banner.jpg top-left (opaque JPEG, no alpha)
    banner_height  = 0.10,  -- banner height as a fraction of the video height
    show_logo      = true,  -- clearlogo.png title art, top-left (transparent PNG)
    logo_height    = 0.12,  -- logo height as a fraction of the video height
    show_disc      = true,  -- 3/4 disc.png nestled at the card's top-left corner
    disc_size      = 0.22,  -- disc diameter as a fraction of the video height
    disc_spin      = true,  -- spin the disc while the card is showing
    disc_spin_secs = 2.5,   -- seconds per full rotation (higher = slower)
    disc_spin_frames = 64,  -- rotation frames (more = smoother; larger temp file)
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

-- Live playback progress (recomputed each render). nil unless mid-file.
local function progress_line()
    local pct = mp.get_property_number("percent-pos")
    if not pct or pct < 1 or pct > 99.5 then return nil end
    local parts = { string.format("%d%%", math.floor(pct + 0.5)) }
    local rem = mp.get_property_number("time-remaining")
    if rem and rem > 0 then
        parts[#parts + 1] = fmt_duration(rem) .. " left"
        parts[#parts + 1] = "ends " .. os.date("%H:%M", os.time() + math.floor(rem))
    end
    return "\226\150\182 " .. table.concat(parts, "   \226\128\162   ") -- ▶
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
}
local FANART_H = 720

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

local function fanart_decode(srcpath, cb)
    local op = string.format("%.3f", math.max(0, math.min(1, opts.fanart_opacity)))
    -- Premultiplied dim: scale RGB and alpha by the opacity factor.
    local vf = string.format(
        "scale=-2:%d,format=rgba,colorchannelmixer=rr=%s:gg=%s:bb=%s:aa=%s",
        FANART_H, op, op, op, op)
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { "ffmpeg", "-y", "-loglevel", "error", "-i", srcpath,
            "-vf", vf, "-pix_fmt", "bgra", "-f", "rawvideo", fanart.file },
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 then
            msg.warn("fanart decode failed"); return cb(false)
        end
        local fi = utils.file_info(fanart.file)
        if not fi or not fi.size or fi.size == 0 then return cb(false) end
        fanart.h = FANART_H
        fanart.w = math.floor(fi.size / (4 * FANART_H))
        fanart.ready, fanart.src = true, srcpath
        msg.verbose(string.format("fanart %dx%d ready", fanart.w, fanart.h))
        cb(true)
    end)
end

local function fanart_hide()
    if fanart.shown then
        mp.command_native({ "overlay-remove", fanart.id })
        fanart.shown = false
    end
end

local function fanart_show()
    if not opts.show_fanart or not fanart.ready then return end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    mp.command_native({
        name = "overlay-add", id = fanart.id, x = 0, y = 0,
        file = fanart.file, offset = 0, fmt = "bgra",
        w = fanart.w, h = fanart.h, stride = fanart.w * 4, dw = ow, dh = oh,
    })
    fanart.shown = true
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

local disc = {
    id = 5,
    file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-disc-"
        .. (mp.get_property("pid") or "x") .. ".bgra",
    w = 0, h = 0, ready = false, shown = false, src = nil,
    frames = 1, framebytes = 0, spin_idx = 0, spin_timer = nil,
}
local DISC_H = 256      -- decode height (square); modest for mpv 0.41 offsets

-- Decode a transparent PNG to premultiplied BGRA (overlay-add wants premult).
local function png_decode(img, srcpath, height, cb, extra_vf)
    local vf = "scale=-2:" .. height .. ",format=rgba"
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

-- Resolve the channel -> its current programme card (or nil).
local function tvh_fetch(path, chan_name, cb)
    tvh_resolve(path, chan_name, function(uuid)
        if not uuid then return cb(nil) end
        curl_json(string.format("%s/api/epg/events/grid?channel=%s&limit=2",
            opts.tvheadend_url, urlencode(uuid)), function(e)
            local ev = e and e.entries and e.entries[1]
            if not ev then return cb(nil) end
            local nxt = e.entries[2]
            cb({
                kind = "livetv", source = "TVheadend",
                channel = ev.channelName or chan_name,
                title = ev.title,
                subtitle = (ev.subtitle and ev.subtitle ~= "") and ev.subtitle or ev.episodeOnscreen,
                overview = ev.summary or ev.description,
                start = tonumber(ev.start), stop = tonumber(ev.stop),
                next_title = nxt and nxt.title,
                next_start = nxt and tonumber(nxt.start),
            })
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
        if c.next_title and c.next_title ~= "" then
            cy = cy + 4
            local up = "Up next: " .. c.next_title
            if c.next_start then up = up .. "  (" .. os.date("%H:%M", c.next_start) .. ")" end
            line(up, 18, "8C8C8C")
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
        cy = cy + band - 10 -- pull the year up into the logo's lower margin
        if c.year and c.year ~= "" then line(tostring(c.year), 20, "B4B4B4") end
    else
        local head = c.title or "Unknown"
        if c.year and c.year ~= "" then head = head .. "  (" .. c.year .. ")" end
        line(head, 38, "FFFFFF", true)
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

    -- rating: colour-coded stars
    local rscore = tonumber(c.rating)
    if rscore and rscore > 0 then
        local stars, scolor = star_rating(rscore)
        line(string.format("%s  %.1f", stars, rscore), 23, scolor, true)
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

        -- pill badges: resolution · HDR · codec · channels · fps
        local pills = {}
        local rl = res_label(tt.vwidth)
        if rl then pills[#pills + 1] = { t = rl, bg = "3A3A3A", fg = "FFFFFF" } end
        if tt.hdr then pills[#pills + 1] = { t = tt.hdr, bg = "18C5F5", fg = "000000" } end
        if tt.vcodec then pills[#pills + 1] = { t = tt.vcodec, bg = "3A3A3A", fg = "FFFFFF" } end
        if tt.achan then pills[#pills + 1] = { t = tt.achan, bg = "3A3A3A", fg = "FFFFFF" } end
        if tt.fps then pills[#pills + 1] = { t = tt.fps .. "fps", bg = "3A3A3A", fg = "FFFFFF" } end
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
    fanart_show()
    poster_show()
    banner_show()
    disc_spin_start()

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
    local a_order, a_set, sel_lang, sel_ch = {}, {}, nil, nil
    local s_order, s_set, s_forced = {}, {}, {}
    for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
        if tr.type == "audio" then
            local L = (tr.lang or "und"):upper()
            if tr.selected then sel_lang, sel_ch = L, chan_label(tr["demux-channel-count"]) end
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
    t.achan = sel_ch

    msg.verbose(string.format("tech: %s %s %s %s | A:%s S:%s | chapters:%s %s",
        t.vcodec or "-", t.hdr or "-", t.fps or "-", t.reso or "-",
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
    local ep_total = (id.kind == "tv") and count_season_episodes(path, id.season) or nil
    local logo_path = opts.show_logo and find_clearlogo(path, id) or nil
    local disc_path = opts.show_disc and find_disc(path, id) or nil

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
        cur_card = merged(localc)
        msg.verbose("local .nfo: '" .. tostring(localc.title) .. "'"
            .. (poster_path and " [poster]" or ""))
    else
        local cached = cache_get(id.cachekey)
        cur_card = merged(cached or {
            kind = id.kind, title = id.display, year = id.year,
            season = id.season, episode = id.episode, source = "file",
        })
        do_tmdb = (not cached) and opts.enrich and opts.api_key ~= ""
        msg.verbose(string.format("identified %s: '%s'%s%s", id.kind, id.query or "",
            id.season and string.format(" S%02dE%02d", id.season, id.episode) or "",
            poster_path and " [poster]" or ""))
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
    local fanart_path = opts.show_fanart and find_fanart(path, id) or nil
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
    local banner_path = opts.show_banner and find_banner(path, id) or nil
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
            png_decode(clearlogo, logo_path, LOGO_H, function(ok)
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
            if gen ~= current_gen then return end
            cur_card = merged(card)
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

local bind_key = (opts.key ~= "") and opts.key or nil
mp.add_key_binding(bind_key, "toggle", toggle)

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
