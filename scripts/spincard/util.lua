-- spincard/util — pure helpers shared across the script: string/number
-- formatters, ASS drawing/measurement, tech-pill colour tiers, and the generic
-- async curl→JSON fetch (used by both the TMDB and Tvheadend modules). No script
-- state and no dependence on `opts` — everything here is a pure function of its
-- arguments (curl_json aside, which only touches mpv subprocess + JSON parsing).

local mp    = require "mp"
local msg   = require "mp.msg"
local utils = require "mp.utils"

local M = {}

-- Small formatters ----------------------------------------------------------

function M.ass_escape(s)
    if not s then return "" end
    return (tostring(s):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"):gsub("\n", "\\N"))
end

function M.fmt_duration(secs)
    if not secs then return nil end
    local t = math.floor(secs + 0.5)
    local h, m, s = math.floor(t / 3600), math.floor((t % 3600) / 60), t % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

-- Word-wrap to `width` cols, at most `maxlines` (adds an ellipsis if truncated).
function M.wrap(text, width, maxlines)
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

function M.urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function M.human_size(b)
    if not b then return nil end
    local u, i = { "B", "KB", "MB", "GB", "TB" }, 1
    while b >= 1024 and i < #u do b = b / 1024; i = i + 1 end
    return string.format((i >= 3) and "%.1f %s" or "%.0f %s", b, u[i])
end

function M.chan_label(n)
    if not n then return nil end
    if n == 1 then return "Mono" end
    if n == 2 then return "Stereo" end
    if n == 6 then return "5.1" end
    if n == 8 then return "7.1" end
    return n .. "ch"
end

function M.fmt_fps(f)
    if not f then return nil end
    return (string.format("%.3f", f):gsub("%.?0+$", ""))
end

-- Generic async curl -> parsed JSON (nil on any failure). Shared by TMDB + TVH.
function M.curl_json(url, cb)
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

-- ASS drawing / rating / date ----------------------------------------------

-- Rounded-rectangle ASS drawing path (corners approximated with beziers).
function M.rrect(w, h, r)
    r = math.max(0, math.min(r, math.floor(w / 2), math.floor(h / 2)))
    return string.format(
        "m %d 0 l %d 0 b %d 0 %d 0 %d %d l %d %d b %d %d %d %d %d %d l %d %d b 0 %d 0 %d 0 %d l 0 %d b 0 0 0 0 %d 0",
        r, w - r, w, w, w, r, w, h - r, w, h, w, h, w - r, h, r, h, h, h, h - r, r, r)
end

-- 5-star string + BGR colour from a 0-10 score.
function M.star_rating(score)
    local n = math.max(0, math.min(5, math.floor(score / 2 + 0.5)))
    local stars = string.rep("\226\152\133", n) .. string.rep("\226\152\134", 5 - n) -- ★ ☆
    local color = (score >= 7.5) and "78C878" or (score >= 5) and "18C5F5" or "5050E0"
    return stars, color
end

-- ISO date (YYYY-MM-DD) -> "28 Aug 2011"; passes through anything else.
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
function M.fmt_date(iso)
    local y, m, d = tostring(iso or ""):match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return iso end
    return string.format("%d %s %s", tonumber(d), MONTHS[tonumber(m)] or m, y)
end

function M.res_label(w)
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
function M.pill_colors(kind, v)
    local c = PILL_TIER[pill_tier(kind, v)] or PILL_TIER.std
    return c[1], c[2]
end

-- Format a scaled tuner metric: "72%" (relative) or "-42.9 dBm" / "12.3 dB".
function M.fmt_metric(v, unit)
    if unit == "%" then return string.format("%d%%", math.floor(v + 0.5)) end
    return string.format("%.1f %s", v, unit)
end

-- BGR colour (ASS is &HBBGGRR&) for a signal level: 3-4 green, 2 amber, 1 red.
function M.tier_color(t)
    if t >= 3 then return "78C878" end -- green
    if t == 2 then return "18C5F5" end -- amber (BGR!)
    return "5050E0"                    -- red
end

-- Text measurement / wrapping ----------------------------------------------

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
M.text_w = text_w

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
M.utf8_chars = utf8_chars

-- Pixel-aware wrap: break `text` into at most `maxlines` lines that each fit
-- `maxw` virtual px at font size `fs` (measured via text_w). Unlike wrap(), this
-- breaks WITHIN a token, so a space-less filename (dot/underscore separated)
-- still wraps. Prefers a break just after a separator ( . _ - / ,); hard-breaks
-- an over-long run; ellipsizes when content overflows maxlines.
local WRAP_SEP = { [" "] = true, ["."] = true, ["_"] = true,
    ["-"] = true, ["/"] = true, [","] = true }
function M.wrap_px(text, maxw, fs, maxlines)
    local chars = utf8_chars(text)
    local lines, line, lastsep, linew = {}, {}, nil, 0 -- linew: running width in fs=1 units
    local truncated = false
    local function reflow() -- recompute lastsep + linew over the current `line`
        lastsep, linew = nil, 0
        for i = 1, #line do
            if WRAP_SEP[line[i]] then lastsep = i end
            linew = linew + text_w(line[i], 1)
        end
    end
    for idx, ch in ipairs(chars) do
        line[#line + 1] = ch
        -- accumulate at fs=1 (raw weight); *fs only in the compare so this equals
        -- text_w(whole line, fs) to the last float bit (text_w multiplies by fs once).
        linew = linew + text_w(ch, 1)
        if WRAP_SEP[ch] then lastsep = #line end
        if #line > 1 and linew * fs > maxw then
            local cut = (lastsep and lastsep < #line) and lastsep or (#line - 1)
            local head, rest = {}, {}
            for i = 1, cut do head[i] = line[i] end
            for i = cut + 1, #line do rest[#rest + 1] = line[i] end
            lines[#lines + 1] = table.concat(head)
            line = rest
            reflow()
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
function M.ellipsize_px(text, maxw, fs)
    if text_w(text, fs) <= maxw then return text end
    local chars = utf8_chars(text)
    local line, lastsep, linew = {}, nil, 0
    local ellipw = text_w(ELLIPSIS, 1) -- ellipsis width in fs=1 units
    for _, ch in ipairs(chars) do
        line[#line + 1] = ch
        linew = linew + text_w(ch, 1) -- fs=1 units; *fs in the compare == text_w(line, fs)
        if WRAP_SEP[ch] then lastsep = #line end
        if (linew + ellipw) * fs > maxw then -- == text_w(line .. ELLIPSIS, fs) exactly
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

return M
