-- spincard/images — the artwork pipeline: find, decode (ffmpeg → premultiplied
-- BGRA), and draw (overlay-add) the poster, fanart backdrop (with a packed
-- fade-in/out), banner, clearlogo title art, and the (optionally spinning) disc.
-- Each subsystem owns a small state table {id,file,w,h,ready,shown,src,…}, exported
-- so main can poke .ready/.src/.file during on_file_loaded.
--
-- images.init(opts, deps) wires it to runtime options + three getter closures the
-- draw code needs from main (kept as closures so build_card / show()/hide() keep
-- their own locals unchanged):
--   deps.logo_rect() / deps.card_rect() — the 1280x720 rects build_card computes
--   deps.visible()                      — whether the card is currently shown
-- file_exists comes from the sidecar module (fs discovery).

local mp    = require "mp"
local msg   = require "mp.msg"
local utils = require "mp.utils"
local file_exists = require("sidecar").file_exists
local layout = require("layout")

local M = {}
local RES_X, RES_Y = layout.RES_X, layout.RES_Y -- virtual card space (matches main's overlay res)

local opts, deps = {}, {}
function M.init(o, d) opts, deps = o, d end

-- Poster image: decode a local jpg -> BGRA (ffmpeg), draw with overlay-add ---

local poster = {
    id = 1,
    file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-poster-"
        .. (mp.get_property("pid") or "x") .. ".bgra",
    w = 0, h = 0, ready = false, shown = false, src = nil,
}
M.poster = poster
local POSTER_H = 450 -- decode height in px; on-screen size is scaled to the OSD

function M.poster_decode(srcpath, cb)
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

function M.poster_hide()
    if poster.shown then
        mp.command_native({ "overlay-remove", poster.id })
        poster.shown = false
    end
end

function M.poster_show()
    if not opts.show_poster or not poster.ready then return end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    local dh = math.floor(oh * opts.poster_height)
    local dw = math.floor(poster.w * (dh / poster.h))
    local max_dw = math.floor(ow * (tonumber(opts.poster_max_width) or 0)) -- 0 = no cap
    if max_dw > 0 and dw > max_dw then       -- landscape episode thumbs blow out wide
        dw = max_dw
        dh = math.floor(poster.h * (dw / poster.w)) -- keep aspect ratio
    end
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
M.fanart = fanart
local FANART_H = 720 -- decode height for the dimmed backdrop

function M.find_fanart(path, id)
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

-- Decode the fanart to one premultiplied-BGRA dimmed frame: RGB + alpha scaled by
-- fanart_opacity so the still backdrop sits readably under the card text.
function M.fanart_decode(srcpath, cb)
    local op = string.format("%.3f", math.max(0, math.min(1, opts.fanart_opacity)))
    local vf = string.format(
        "scale=-2:%d,format=rgba,colorchannelmixer=rr=%s:gg=%s:bb=%s:aa=%s",
        FANART_H, op, op, op, op)
    local args = { "ffmpeg", "-y", "-loglevel", "error", "-i", srcpath,
        "-vf", vf, "-pix_fmt", "bgra", "-f", "rawvideo", fanart.file }
    mp.command_native_async({ name = "subprocess", playback_only = false, args = args },
        function(ok, res)
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

-- Static dimmed backdrop: no timer, no fade. Shown while the card is up (gated by
-- fanart_pause_only in main), redrawn on OSD resize via the osd-width observer.
function M.fanart_hide()
    if fanart.shown then
        mp.command_native({ "overlay-remove", fanart.id })
        fanart.shown = false
    end
end

local function fanart_draw()
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return false end
    mp.command_native({ name = "overlay-add", id = fanart.id, x = 0, y = 0,
        file = fanart.file, offset = 0,
        fmt = "bgra", w = fanart.w, h = fanart.h, stride = fanart.w * 4, dw = ow, dh = oh })
    fanart.shown = true
    return true
end

function M.fanart_show()
    if not opts.show_fanart or not fanart.ready then return end
    fanart_draw() -- returns false if the OSD isn't sized yet; retried via the osd-width observer
end

-- Banner: wide title art (banner.jpg), opaque, drawn top-left ---------------

local banner = {
    id = 3,
    file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-banner-"
        .. (mp.get_property("pid") or "x") .. ".bgra",
    w = 0, h = 0, ready = false, shown = false, src = nil,
}
M.banner = banner
local BANNER_H = 200

function M.find_banner(path, id)
    local dir = path:match("^(.*)/[^/]+$") or "."
    local cands = { dir .. "/banner.jpg" }
    if id.kind == "tv" then
        local showdir = dir:match("^(.*)/[^/]+$") -- parent of Season.N
        if showdir then cands[#cands + 1] = showdir .. "/banner.jpg" end
    end
    for _, c in ipairs(cands) do if file_exists(c) then return c end end
    return nil
end

function M.banner_decode(srcpath, cb)
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

function M.banner_hide()
    if banner.shown then
        mp.command_native({ "overlay-remove", banner.id })
        banner.shown = false
    end
end

function M.banner_show()
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
M.clearlogo = clearlogo
local LOGO_H = 240
local LOGO_GAP = 6      -- gap (virtual px) between the clearlogo band and the first text row
M.LOGO_GAP = LOGO_GAP   -- build_card reads this to place the first text row below the logo

local disc = {
    id = 5,
    file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-disc-"
        .. (mp.get_property("pid") or "x") .. ".bgra",
    w = 0, h = 0, ready = false, shown = false, src = nil,
    frames = 1, framebytes = 0, spin_idx = 0, spin_timer = nil,
}
M.disc = disc
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

function M.find_clearlogo(path, id)
    return find_art(path, id, "clearlogo.png") or find_art(path, id, "logo.png")
end
function M.find_disc(path, id) return find_art(path, id, "disc.png") end

-- Decode the clearlogo cropped to its opaque bounding box, so the reserved title
-- slot maps to real artwork rather than the PNG's (variable) transparent margins.
-- Pass 1 runs cropdetect over the ALPHA plane (alphaextract) to find the bbox;
-- pass 2 decodes with that crop applied before scale (native-px coords). If
-- detection yields nothing (older ffmpeg, or a logo whose shadow bleeds to the
-- edge) it falls back to a plain full-frame decode — never breaks the logo.
--   limit=0 : trim only fully-transparent rows/cols (any opacity is kept)
--   skip=0  : cropdetect skips the first 2 frames by default → none for a still,
--             so force skip=0 and feed a few looped frames as belt-and-suspenders
function M.clearlogo_decode(srcpath, cb)
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

function M.img_remove(img)
    if img.shown then mp.command_native({ "overlay-remove", img.id }); img.shown = false end
end

-- Draw the clearlogo in the card's title slot (logo_rect is in 1280x720 virtual
-- coords set by build_card), converted to OSD pixels; clamped to card width.
function M.place_logo()
    local logo_rect = deps.logo_rect()
    if not (opts.show_logo and clearlogo.ready and logo_rect) then return end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    local sx, sy = ow / RES_X, oh / RES_Y
    local dh = math.floor(logo_rect.h * sy)
    local dw = math.floor(clearlogo.w * (dh / clearlogo.h))
    local max_dw = math.floor(layout.INNER * sx) -- card inner width (shared const)
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
function M.disc_decode(srcpath, cb)
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
function M.disc_show(frame)
    local card_rect = deps.card_rect()
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

function M.disc_spin_stop()
    if disc.spin_timer then disc.spin_timer:kill(); disc.spin_timer = nil end
end

function M.disc_spin_start()
    M.disc_spin_stop()
    if not (opts.disc_spin and opts.show_disc and disc.ready and disc.frames > 1) then return end
    if mp.get_property_bool("pause") then return end -- a paused disc doesn't spin; the pause observer restarts it on resume
    disc.spin_timer = mp.add_periodic_timer(opts.disc_spin_secs / disc.frames, function()
        if not deps.visible() then return end
        disc.spin_idx = (disc.spin_idx + 1) % disc.frames
        M.disc_show(disc.spin_idx)
    end)
end

return M
