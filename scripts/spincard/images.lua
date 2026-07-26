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
local util  = require("util") -- ellipsize_px / ass_escape for the cast-headshot name labels

local M = {}
local RES_X, RES_Y = layout.RES_X, layout.RES_Y -- virtual card space (matches main's overlay res)

local opts, deps = {}, {}
function M.init(o, d) opts, deps = o, d end

-- Remote artwork (TMDB CDN) ------------------------------------------------
-- Fetch a TMDB image (path like "/abc.jpg") at `size` (w500/w1280/original) via curl
-- and hand the file to the normal decode path. cb(file) or cb(nil) on any failure
-- (offline, 404, empty) so callers fall through cleanly. The SOURCE image is cached
-- PERSISTENTLY under ~/.cache/spincard/img/<size>_<sanitised-path> — keyed on the
-- stable TMDB path (NOT the mpv pid), so a title's art downloads ONCE and is reused
-- across playback sessions; a cache hit skips curl entirely. (The per-session BGRA
-- decode still runs, same as local art.) Download to a pid-tagged .part temp then
-- rename, so an interrupted/concurrent transfer never leaves a corrupt cache entry.
local TMDB_IMG = "https://image.tmdb.org/t/p/"
local IMG_CACHE = (os.getenv("HOME") or "/tmp") .. "/.cache/spincard/img"
os.execute("mkdir -p '" .. IMG_CACHE .. "' 2>/dev/null")
local function img_cache_path(size, path)
    return IMG_CACHE .. "/" .. size .. "_" .. (path:gsub("[^%w%-_.]", "_"))
end
function M.fetch_image(path, size, _tag, cb)
    if not path or path == "" then return cb(nil) end
    local dest = img_cache_path(size, path)
    local fi = utils.file_info(dest)
    if fi and fi.size and fi.size > 0 then return cb(dest) end -- cache hit: no download
    local tmp = dest .. "." .. (mp.get_property("pid") or "x") .. ".part"
    local url = TMDB_IMG .. size .. path
    mp.command_native_async({ name = "subprocess", playback_only = false,
        args = { "curl", "-fsSL", "--max-time", "15", "-o", tmp, url } },
        function(ok, res)
            if not ok or not res or res.status ~= 0 then
                os.remove(tmp); msg.warn("image fetch failed: " .. url); return cb(nil)
            end
            local f2 = utils.file_info(tmp)
            if not f2 or not f2.size or f2.size == 0 then os.remove(tmp); return cb(nil) end
            os.rename(tmp, dest) -- atomic publish into the cache
            cb(dest)
        end)
end

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

-- Fixed notch: cut the BOTTOM-LEFT quadrant (the one that overlaps the card at the
-- top-right corner) so the 3/4 disc nestles into the card's top-right corner.
local DISC_MASK = "geq=r=r(X\\,Y):g=g(X\\,Y):b=b(X\\,Y):a=if(lt(X\\,W/2)*gt(Y\\,H/2)\\,0\\,alpha(X\\,Y))"

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

-- 3/4 disc centred on the card's top-RIGHT corner; `frame` picks a rotation frame
-- via the file byte offset (defaults to the current spin frame). (Moved from the
-- top-left corner so it never clashes with the top-left cast-headshot strip.)
function M.disc_show(frame)
    local card_rect = deps.card_rect()
    if not (opts.show_disc and disc.ready and card_rect) then return end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    frame = frame or disc.spin_idx or 0
    local sx, sy = ow / RES_X, oh / RES_Y
    local dh = math.floor(oh * opts.disc_size)
    local dw = math.floor(disc.w * (dh / disc.h))
    local cx, cy = (card_rect.x + card_rect.w) * sx, card_rect.y * sy
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

-- Cast headshots strip: a row of TMDB profile photos drawn as a SEPARATE desktop
-- overlay (a sibling of the banner/poster, NOT on the card), top-left, under the
-- banner when one is present. Each head is a square opaque BGRA (its own overlay,
-- ids 6+); the names ride a SECOND osd-overlay (kept off the card overlay so the
-- card's bottom-anchor shift never moves them). Static: draws only the faces that
-- fit one row. TMDB-only (profiles come from credits[].profile_path).
local casthead = {
    base = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-cast-" .. (mp.get_property("pid") or "x"),
    ids = { 6, 7, 8, 9, 10, 11 }, -- free overlay-id block (static: one per head; scroll: 6=window, 7=wrap seam)
    heads = {},   -- static style: [i] = { file, w, h, ready, src, name }
    names_ov = nil,
    packed = {    -- scroll style: ALL faces hstacked into ONE wide premultiplied BGRA
        file = (os.getenv("TMPDIR") or "/tmp") .. "/spincard-castrow-" .. (mp.get_property("pid") or "x") .. ".bgra",
        w = 0, h = 0, face_h = 0, ready = false, -- h includes the baked shadow band; face_h is the face row
    },
    scroll_idx = 0, scroll_timer = nil, wrap_shown = false, -- marquee offset, timer, seam-overlay state
    labels = nil, -- scroll style: [i] = {name, role} in lockstep with the packed faces
    shown = false,
    token = 0,    -- bumped per prepare(); async cbs bail on a stale token
}
M.casthead = casthead
local CAST_DECODE_H = 160 -- head native height (square); scaled to OSD at draw

-- SCROLL style: pack all fetched faces into ONE wide premultiplied BGRA (square
-- face-biased crop + a transparent trailing gap per face → a uniform loop seam), so
-- the marquee is a single overlay windowed by byte offset — overlay-add has no clip,
-- which is exactly why scroll was deferred; the offset/stride trick sidesteps it.
local function casthead_build_packed(files, token, cb)
    local n = #files
    if n == 0 then return cb(0) end
    local H = CAST_DECODE_H
    local G = math.max(8, math.floor(H * 0.18))   -- transparent gap between faces
    local SHO = math.max(2, math.floor(H * 0.045)) -- drop-shadow offset (down-right)
    local SIG = 5                                    -- shadow blur sigma
    local PB = SHO + 3 * SIG                          -- bottom room so the shadow isn't clipped
    local W, HP = n * (H + G), H + PB
    local args = { "ffmpeg", "-y", "-loglevel", "error" }
    for _, f in ipairs(files) do args[#args + 1] = "-i"; args[#args + 1] = f end
    local fc = {}
    for i = 1, n do -- per input: square face-crop → scale → transparent trailing gap
        fc[#fc + 1] = string.format(
            "[%d:v]crop=iw:iw:0:(ih-iw)/4,scale=%d:%d,format=rgba,pad=%d:%d:0:0:color=black@0[v%d]",
            i - 1, H, H, H + G, H, i - 1)
    end
    local row = "[v0]"
    if n > 1 then
        local lab = {}
        for i = 1, n do lab[#lab + 1] = string.format("[v%d]", i - 1) end
        fc[#fc + 1] = table.concat(lab) .. string.format("hstack=inputs=%d[row]", n)
        row = "[row]"
    end
    -- Soft drop shadow behind each face (matches the static strip): pad a bottom band
    -- for the offset shadow, blur a black silhouette of the faces, composite it UNDER
    -- them. Faces are opaque squares separated by transparent gaps, so each gets its own
    -- shadow peeking down-right into the gap; premultiply last for overlay-add.
    fc[#fc + 1] = row .. string.format("pad=%d:%d:0:0:color=black@0,split[top][shsrc]", W, HP)
    fc[#fc + 1] = string.format("[shsrc]geq=r=0:g=0:b=0:a=alpha(X\\,Y),gblur=sigma=%d[sh]", SIG)
    fc[#fc + 1] = string.format("color=black@0:s=%dx%d:d=1,format=rgba[bg]", W, HP)
    fc[#fc + 1] = string.format("[bg][sh]overlay=%d:%d:shortest=1[bgsh]", SHO, SHO)
    fc[#fc + 1] = "[bgsh][top]overlay=0:0,premultiply=inplace=1[o]"
    args[#args + 1] = "-filter_complex"; args[#args + 1] = table.concat(fc, ";")
    args[#args + 1] = "-map"; args[#args + 1] = "[o]"
    args[#args + 1] = "-frames:v"; args[#args + 1] = "1"
    args[#args + 1] = "-pix_fmt"; args[#args + 1] = "bgra"
    args[#args + 1] = "-f"; args[#args + 1] = "rawvideo"
    args[#args + 1] = casthead.packed.file
    mp.command_native_async({ name = "subprocess", playback_only = false, args = args }, function(ok, res)
        if not ok or not res or res.status ~= 0 then msg.warn("casthead pack failed"); return cb(0) end
        local fi = utils.file_info(casthead.packed.file)
        if not fi or not fi.size or fi.size == 0 then return cb(0) end
        casthead.packed.face_h = H  -- face height within the row (excludes the shadow band)
        casthead.packed.h = HP      -- full packed height (faces + shadow band)
        casthead.packed.w = math.floor(fi.size / (4 * HP))
        casthead.packed.ready = (casthead.token == token)
        msg.verbose(string.format("casthead packed %dx%d (%d faces)", casthead.packed.w, HP, n))
        cb(casthead.token == token and n or 0)
    end)
end

-- Fetch all picked profiles (persistent w185 cache), preserving cast order, then
-- build the packed row once every fetch has settled.
local function casthead_prepare_scroll(picks, token, cb)
    local files, pending = {}, #picks
    for i, e in ipairs(picks) do
        M.fetch_image(e.profile, "w185", "cast", function(f)
            if casthead.token == token then files[i] = f or false end
            pending = pending - 1
            if pending == 0 and casthead.token == token then
                local ordered, labels = {}, {}
                for j = 1, #picks do
                    if files[j] then -- keep the labels in lockstep with the packed faces
                        ordered[#ordered + 1] = files[j]
                        labels[#labels + 1] = { name = picks[j].name, role = picks[j].role }
                    end
                end
                casthead.labels = labels
                casthead_build_packed(ordered, token, cb)
            end
        end)
    end
end

-- Fetch + decode up to casthead_max cast that HAVE a profile; cb(count_ready) when
-- the whole batch settles (only fires for the current token). Reuses fetch_image
-- (persistent w185 cache) + png_decode (square crop, opaque). Orchestrated here so
-- on_file_loaded stays a single images.* call (LuaJIT 60-upvalue ceiling).
function M.casthead_prepare(cast, token, cb)
    casthead.token = token
    casthead.heads = {}
    casthead.labels = nil
    casthead.packed.ready = false
    casthead.scroll_idx = 0
    local scroll = (tostring(opts.casthead_style or "static"):lower() == "scroll")
    -- scroll shows up to casthead_max faces; static is also bounded by the overlay-id block
    local cap = math.max(1, tonumber(opts.casthead_max) or 5)
    local nmax = scroll and cap or math.min(#casthead.ids, cap)
    local picks = {}
    for _, e in ipairs(cast or {}) do
        if type(e) == "table" and e.profile and e.profile ~= "" then
            picks[#picks + 1] = e
            if #picks >= nmax then break end
        end
    end
    if #picks == 0 then return cb(0) end
    if scroll then return casthead_prepare_scroll(picks, token, cb) end
    local pending, ready = #picks, 0
    for i, e in ipairs(picks) do
        local head = { file = casthead.base .. i .. ".bgra", ready = false, name = e.name }
        casthead.heads[i] = head
        M.fetch_image(e.profile, "w185", "cast", function(f)
            local function done(ok)
                if ok and casthead.token == token then head.ready, ready = true, ready + 1 end
                pending = pending - 1
                if pending == 0 and casthead.token == token then cb(ready) end
            end
            if not f then return done(false) end
            -- crop the portrait (185x278) to a square biased toward the face, then scale
            png_decode(head, f, CAST_DECODE_H, done, nil, "crop=iw:iw:0:(ih-iw)/4")
        end)
    end
end

-- Any face ready? (static: a decoded head; scroll: the packed row)
function M.casthead_ready()
    if casthead.packed.ready then return true end
    for _, h in ipairs(casthead.heads) do if h and h.ready then return true end end
    return false
end

function M.casthead_hide()
    M.casthead_scroll_stop()
    for _, id in ipairs(casthead.ids) do mp.command_native({ "overlay-remove", id }) end
    if casthead.names_ov then casthead.names_ov:remove() end
    casthead.shown, casthead.wrap_shown = false, false
end

-- SCROLL style helpers -----------------------------------------------------
-- Window geometry (OSD px): top-left, under the banner, spanning from the left
-- margin to just before the top-right poster. Returns x0,y0,dh,scale,W_src (the
-- window width in packed-source px). nil until the OSD is sized and the row is built.
local function casthead_window()
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 or not casthead.packed.ready then return nil end
    local sx = ow / RES_X
    local margin = math.floor(oh * 0.03)
    local face_h = casthead.packed.face_h or casthead.packed.h
    local face_disp = math.floor(oh * (tonumber(opts.casthead_height) or 0.19))
    local scale = face_disp / face_h                    -- faces at casthead_height
    local dh = math.floor(casthead.packed.h * scale)    -- overlay height = faces + baked shadow band
    local gap = math.max(4, math.floor(face_disp * 0.16))
    local y0 = margin
    if opts.show_banner and banner.ready then -- sit under the banner when it's shown
        y0 = margin + math.floor(oh * opts.banner_height) + gap
    end
    -- Span the full CARD width: from the left margin (≈ the card's left edge) to the
    -- card's RIGHT edge, where the spinning disc sits — so the marquee runs right up
    -- under the disc (which is drawn on top). Fall back to clearing the top-right
    -- poster if the card rect isn't known yet.
    local cr = deps.card_rect and deps.card_rect()
    local right = cr and math.floor((cr.x + cr.w) * sx) or (ow - 2 * margin) -- card's right edge
    local pad = math.max(4, math.floor(oh * 0.006))
    if cr and opts.show_disc and disc.ready and disc.h > 0 then
        -- the disc is centred on the card's right corner; stop the strip at the disc's
        -- LEFT side (minus a hair) so the marquee's right border hugs, not runs under it.
        local disc_dw = disc.w * ((oh * (tonumber(opts.disc_size) or 0.22)) / disc.h)
        right = math.min(right, math.floor((cr.x + cr.w) * sx - disc_dw / 2 - pad))
    end
    if opts.show_poster and poster.ready and poster.h > 0 then
        -- also stay clear of the top-right poster (matters when there's no disc to stop at,
        -- e.g. a TV episode's wide landscape thumb reaching left toward the card).
        local pdh = math.floor(oh * (tonumber(opts.poster_height) or 0.42))
        local pdw = math.floor(poster.w * (pdh / poster.h))
        local cap = math.floor(ow * (tonumber(opts.poster_max_width) or 0))
        if cap > 0 and pdw > cap then pdw = cap end
        local pl = ow - pdw - math.floor(oh * (tonumber(opts.poster_margin) or 0))
        right = math.min(right, pl - pad)
    end
    local W_disp = math.max(face_disp, right - margin)
    return margin, y0, dh, scale, math.max(1, math.floor(W_disp / scale))
end

-- Draw the marquee: a W_src-wide vertical slice of the packed row at byte offset o
-- (o grows → content glides right→left). If the row fits the window it draws once
-- (no scroll). At the wrap seam a 2nd overlay fills the tail from the row start
-- (a single overlay-add read can't cross a row end).
-- Aligned name/role labels UNDER the scrolling faces: one two-line label per face,
-- shifted by the SAME source offset o so each name stays locked under its actor. On the
-- names_ov osd-overlay (z=50), clipped to the window so labels don't spill past the disc
-- or the left margin. Rebuilt every tick alongside the faces. (osd text draws below image
-- overlays, so a label only hides behind the clearlogo if a tall card rises into the
-- strip — same caveat as the static strip's labels.)
local function casthead_labels_draw(x0, y0, scale, o, W_disp)
    local labels = casthead.labels
    if not (labels and #labels > 0) then
        if casthead.names_ov then casthead.names_ov.data = ""; casthead.names_ov:update() end
        return
    end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    local sx, sy = ow / RES_X, oh / RES_Y
    local n, pw = #labels, casthead.packed.w
    local cell = pw / n              -- source cell width (face + gap)
    local fh = casthead.packed.face_h
    local ly = y0 + math.floor(fh * scale) + math.max(2, math.floor(oh * 0.006)) -- just under the faces
    local fs = 16
    local wv = (cell * scale) / sx  -- label width in the 1280x720 virtual space
    local right = x0 + W_disp
    local clip = string.format("\\clip(%d,%d,%d,%d)",
        math.floor(x0 / sx), 0, math.ceil(right / sx), math.ceil(oh / sy))
    local ev = {}
    -- k=1 is the wrapped 2nd copy for the scroll seam; only emit it when the strip
    -- actually SCROLLS. When it fits (static), the wider window would otherwise place
    -- wrapped name copies past the faces → "empty boxes with names".
    local kmax = (casthead.packed.w * scale > W_disp) and 1 or 0
    for i = 1, n do
        local center = (i - 1) * cell + fh / 2 -- face centre in source px
        for k = 0, kmax do
            local dx = x0 + (center - o + k * pw) * scale
            -- label a face only while its CENTRE is inside the window, so a name never
            -- floats past its face onto the poster/disc at the wrap seam (the \clip below
            -- still trims a label that straddles an edge).
            if dx >= x0 and dx <= right then
                local L = labels[i]
                local function e(t) return util.ass_escape(util.ellipsize_px(t, wv, fs, "-")) end
                -- name on ONE line (ellipsised to the cell), then the role on a
                -- 2nd, dimmer line (no parens). Truncation marker is "-".
                local txt = e(L.name or "")
                if L.role and L.role ~= "" then
                    txt = txt .. "\\N{\\1c&HC8C8C8&}" .. e(L.role)
                end
                ev[#ev + 1] = string.format(
                    "{\\an8%s\\pos(%d,%d)\\bord2\\shad1\\3c&H000000&\\1c&HFFFFFF&\\fs%d\\b1}%s",
                    clip, math.floor(dx / sx), math.floor(ly / sy), fs, txt)
            end
        end
    end
    if not casthead.names_ov then casthead.names_ov = mp.create_osd_overlay("ass-events") end
    casthead.names_ov.res_x, casthead.names_ov.res_y = RES_X, RES_Y
    casthead.names_ov.z = 50
    casthead.names_ov.data = table.concat(ev, "\n")
    casthead.names_ov:update()
end

local function casthead_scroll_draw()
    local x0, y0, dh, scale, W_src = casthead_window()
    if not x0 then return end
    local pw, ph = casthead.packed.w, casthead.packed.h
    -- overlay-add REPLACES an existing id in place (atomically), same as the spinning
    -- disc. Do NOT overlay-remove then re-add the SAME id each tick — the 1-frame gap
    -- between the two gets composited on macOS and reads as a dark strobe (~1/s, a beat
    -- against the refresh). id 6 is redrawn in place; id 7 (wrap tail) is only removed
    -- when we leave the seam.
    local function put(id, off, w, dx)
        mp.command_native({ name = "overlay-add", id = id, x = dx, y = y0,
            file = casthead.packed.file, offset = off * 4, fmt = "bgra",
            w = w, h = ph, stride = pw * 4, dw = math.floor(w * scale), dh = dh })
    end
    local o = 0
    if pw > W_src then -- doesn't fit → scroll
        local px = math.max(1, tonumber(opts.cast_scroll_px) or 3)
        o = math.floor((casthead.scroll_idx * (px / scale)) % pw)
        local w1 = math.min(W_src, pw - o)
        put(casthead.ids[1], o, w1, x0)
        if w1 < W_src then -- wrap seam: fill the tail from the start of the row
            put(casthead.ids[2], 0, W_src - w1, x0 + math.floor(w1 * scale))
            casthead.wrap_shown = true
        elseif casthead.wrap_shown then
            mp.command_native({ "overlay-remove", casthead.ids[2] }); casthead.wrap_shown = false
        end
    else -- everything fits → one static overlay
        put(casthead.ids[1], 0, pw, x0)
        if casthead.wrap_shown then
            mp.command_native({ "overlay-remove", casthead.ids[2] }); casthead.wrap_shown = false
        end
    end
    casthead_labels_draw(x0, y0, scale, o, math.floor(W_src * scale))
    casthead.shown = true
end

function M.casthead_scroll_stop()
    if casthead.scroll_timer then casthead.scroll_timer:kill(); casthead.scroll_timer = nil end
end

function M.casthead_scroll_start()
    M.casthead_scroll_stop()
    local iv = tonumber(opts.cast_scroll_interval) or 0.1
    if iv <= 0 then return end -- timer-driven (like the cast marquee) → glides while paused too
    casthead.scroll_timer = mp.add_periodic_timer(iv, function()
        if not deps.visible() then return end
        casthead.scroll_idx = casthead.scroll_idx + 1
        casthead_scroll_draw()
    end)
end

-- Show the scrolling faces marquee: draw the first window, then run the timer only
-- when the row is wider than the window (else it's a clean static row).
function M.casthead_scroll_show()
    if not casthead.packed.ready then return end
    casthead_scroll_draw()
    local x0, _, _, _, W_src = casthead_window()
    if x0 and casthead.packed.w > W_src then M.casthead_scroll_start() else M.casthead_scroll_stop() end
end

-- STATIC style: draw the ready heads left→right, top-left, under the banner if
-- present; cap the row to ~42% of the width so it clears the top-right poster.
-- Names go on a 2nd osd-overlay in the 1280x720 virtual space (head OSD-px → /sx,/sy).
function M.casthead_show()
    if not opts.cast_headshots then return end
    if tostring(opts.casthead_style or "static"):lower() == "scroll" then
        return M.casthead_scroll_show()
    end
    local ow, oh = mp.get_osd_size()
    if not ow or ow == 0 or not oh or oh == 0 then return end
    local heads = {}
    for i = 1, #casthead.heads do
        local h = casthead.heads[i]
        if h and h.ready then heads[#heads + 1] = h end
    end
    M.casthead_hide()
    if #heads == 0 then return end
    local sx, sy = ow / RES_X, oh / RES_Y
    local margin = math.floor(oh * 0.03)
    local dh = math.floor(oh * (tonumber(opts.casthead_height) or 0.19))
    local gap = math.max(4, math.floor(dh * 0.16))
    local y0 = margin
    if opts.show_banner and banner.ready then -- sit under the banner when it's shown
        y0 = margin + math.floor(oh * opts.banner_height) + gap
    end
    local maxw = math.floor(ow * 0.42) -- keep clear of the top-right poster
    local x, drawn, events = margin, 0, {}
    for _, h in ipairs(heads) do
        local dw = math.floor(h.w * (dh / h.h)) -- square → dw == dh
        if drawn > 0 and (x + dw - margin) > maxw then break end -- no room; stop the row
        mp.command_native({ name = "overlay-add", id = casthead.ids[drawn + 1], x = x, y = y0,
            file = h.file, offset = 0, fmt = "bgra",
            w = h.w, h = h.h, stride = h.w * 4, dw = dw, dh = dh })
        -- soft drop shadow behind the head: image overlays draw ABOVE this ASS
        -- overlay, so a dark rect offset down-right + blurred peeks out as a shadow
        -- (same trick as the card box). Virtual coords (÷ sx,sy).
        local shO = math.max(2, math.floor(dh * 0.045))
        events[#events + 1] = string.format(
            "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H000000&\\1a&H80&\\blur4\\p1}%s{\\p0}",
            math.floor((x + shO) / sx), math.floor((y0 + shO) / sy),
            util.rrect(math.floor(dw / sx), math.floor(dh / sy), 4))
        if h.name and h.name ~= "" then -- name label centred under the head (virtual coords)
            local cxv = (x + dw / 2) / sx
            local yv = (y0 + dh + math.floor(oh * 0.008)) / sy
            local wv = dw / sx
            -- name on one line, ellipsised to the head width.
            local function esc(t) return util.ass_escape(util.ellipsize_px(t, wv, 16)) end
            local label = esc(h.name)
            events[#events + 1] = string.format(
                "{\\an8\\pos(%d,%d)\\bord2\\shad1\\3c&H000000&\\1c&HFFFFFF&\\fs16\\b1}%s",
                math.floor(cxv), math.floor(yv), label)
        end
        drawn, x = drawn + 1, x + dw + gap
    end
    casthead.shown = drawn > 0
    if #events > 0 then
        if not casthead.names_ov then casthead.names_ov = mp.create_osd_overlay("ass-events") end
        casthead.names_ov.res_x, casthead.names_ov.res_y = RES_X, RES_Y
        -- Draw ABOVE the card overlay (default z=0). On a wider-than-16:9 window the
        -- tall card's top can rise into the top-left strip; with equal z the render
        -- order is platform-dependent (macOS drew the card over the names → "behind").
        casthead.names_ov.z = 50
        casthead.names_ov.data = table.concat(events, "\n")
        casthead.names_ov:update()
    end
end

return M
