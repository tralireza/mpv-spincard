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

-- Compact vote count: 1234567 -> "1.2M", 12345 -> "12k", 999 -> "999".
function M.fmt_votes(n)
    n = tonumber(n); if not n then return nil end
    if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if n >= 1e3 then return string.format("%.0fk", n / 1e3) end
    return string.format("%d", n)
end

-- A numeric cap where 0 means "no cap / all" → returns math.huge (which math.max
-- absorbs and `#t >= cap` never trips). Negative/invalid falls back to `default`.
function M.cap_or_all(v, default)
    local n = tonumber(v)
    if not n or n < 0 then n = default end
    return (n == 0) and math.huge or n
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
-- Origin defaults to (0,0) — the form used by \p1 fills positioned via \pos. Pass
-- (ox,oy) for an ABSOLUTE-coordinate path (e.g. a vector \clip/\iclip, which is not
-- moved by \pos): the whole box is emitted at (ox,oy)..(ox+w,oy+h).
function M.rrect(w, h, r, ox, oy)
    ox, oy = ox or 0, oy or 0
    r = math.max(0, math.min(r, math.floor(w / 2), math.floor(h / 2)))
    local x0, y0, x1, y1 = ox, oy, ox + w, oy + h -- box corners
    return string.format(
        "m %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d",
        x0 + r, y0,                 -- start after the top-left arc
        x1 - r, y0,                 -- top edge
        x1, y0, x1, y0, x1, y0 + r, -- top-right corner
        x1, y1 - r,                 -- right edge
        x1, y1, x1, y1, x1 - r, y1, -- bottom-right corner
        x0 + r, y1,                 -- bottom edge
        x0, y1, x0, y1, x0, y1 - r, -- bottom-left corner
        x0, y0 + r,                 -- left edge
        x0, y0, x0, y0, x0 + r, y0) -- top-left corner
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

-- Approx rendered width (virtual px) of a UTF-8 string at font size `fs`. libass
-- exposes no text-measure API, so we sum per-glyph ADVANCES from a measured table.
-- The weights are the real DejaVu Sans (mpv's default OSD sans) advances in em,
-- captured on the target box with `osd-overlay ... compute_bounds=true` at
-- PlayRes 1280x720 and cross-checked against the font file (see tests/test_text_w.lua
-- for the captured ground truth). Accurate to ~2% on a whole string, so — unlike
-- the old guessed table — this is NOT a ~1.22x over-estimate and callers must not
-- rely on hidden slack. Because it sums ADVANCES it is still an upper bound on the
-- rendered INK (kerning and side bearings only make the ink narrower), so cursor
-- advances and pill backgrounds stay safe.
-- `bold` picks the DejaVu Sans BOLD metrics — pass it for any run drawn with \b1
-- (headings, genres, cast, every pill label): bold is 6-26% wider per glyph and
-- ~11-16% wider per string, which no single factor models well.
local TW, TWB = {}, {}   -- advance in em: regular / bold
do
    local function put(t, w, s) for i = 1, #s do t[s:sub(i, i)] = w end end
    put(TW, 0.238, "'ijl")
    put(TW, 0.255, "IJ")
    put(TW, 0.274, ". ,")
    put(TW, 0.290, "/:;|\\")
    put(TW, 0.308, "f-")
    put(TW, 0.343, "t()[]r!")
    put(TW, 0.394, "\"")
    put(TW, 0.431, "*_`")
    put(TW, 0.458, "zs?")
    put(TW, 0.483, "cL")
    put(TW, 0.505, "FkP")
    put(TW, 0.508, "vxy")
    put(TW, 0.529, "TYaeo")
    put(TW, 0.548, "Ehnu345bp{}$7dgq012689S")
    put(TW, 0.563, "K")
    put(TW, 0.598, "AVXBZR")
    put(TW, 0.603, "C")
    put(TW, 0.629, "U")
    put(TW, 0.645, "HN")
    put(TW, 0.664, "DG")
    put(TW, 0.677, "&OQ")
    put(TW, 0.704, "w")
    put(TW, 0.720, "+<=>^~#")
    put(TW, 0.741, "M")
    put(TW, 0.818, "%")
    put(TW, 0.836, "m")
    put(TW, 0.861, "W@")
    TW["\194\183"]      = 0.274 -- ·
    TW["\226\128\153"]  = 0.274 -- ’
    TW["\226\128\147"]  = 0.431 -- –
    TW["\226\128\162"]  = 0.508 -- •
    TW["\195\169"]      = 0.529 -- é
    TW["\226\152\133"]  = 0.771 -- ★
    TW["\226\152\134"]  = 0.771 -- ☆ (star_rating emits both; DejaVu gives them the same advance)
    TW["\226\128\166"]  = 0.861 -- …
    TW["\226\128\148"]  = 0.861 -- —
    put(TWB, 0.261, "'")
    put(TWB, 0.301, "jil ")
    put(TWB, 0.320, "|/IJ")
    put(TWB, 0.329, "\\,.")
    put(TWB, 0.343, ":;")
    put(TWB, 0.355, "-")
    put(TWB, 0.374, "f")
    put(TWB, 0.395, "!)([]")
    put(TWB, 0.409, "t")
    put(TWB, 0.431, "r`_")
    put(TWB, 0.450, "*\"")
    put(TWB, 0.508, "z?c")
    put(TWB, 0.513, "s")
    put(TWB, 0.554, "Lx")
    put(TWB, 0.563, "vy")
    put(TWB, 0.578, "ka")
    put(TWB, 0.590, "eTEFo")
    put(TWB, 0.599, "01346789$25")
    put(TWB, 0.616, "Ydgqbhnpu{}S")
    put(TWB, 0.628, "ZCP")
    put(TWB, 0.665, "BRXAKV")
    put(TWB, 0.714, "GD")
    put(TWB, 0.724, "#HNU")
    put(TWB, 0.730, "OQ")
    put(TWB, 0.749, "+<=>^~&")
    put(TWB, 0.793, "w")
    put(TWB, 0.859, "M%@")
    put(TWB, 0.894, "m")
    put(TWB, 0.948, "W")
    TWB["\194\183"]     = 0.329 -- ·
    TWB["\226\128\153"] = 0.329 -- ’
    TWB["\226\128\147"] = 0.431 -- –
    TWB["\226\128\162"] = 0.563 -- •
    TWB["\195\169"]     = 0.590 -- é
    TWB["\226\152\133"] = 0.768 -- ★
    TWB["\226\152\134"] = 0.768 -- ☆ (no bold dingbat in DejaVu — same glyph, same advance)
    TWB["\226\128\166"] = 0.859 -- …
    TWB["\226\128\148"] = 0.859 -- —
end
-- Fallback widths for glyphs with no measured entry. Under-prediction is the dangerous
-- direction (it is what walks text off the card), so these lean wide: measured DejaVu
-- p90s, not medians. The 2-byte fallback is BLOCK-aware because the blocks differ a lot:
-- Latin-1 sup + Latin-Ext-A/B are accented ASCII and sit near the lowercase average
-- (p50 0.53 reg / 0.59 bold), but Greek and especially Cyrillic skew wide — Cyrillic bold
-- runs p50 0.662, p90 0.912, max 1.207 (Ж Ш Щ Ю М), so a flat 0.62 under-predicted an
-- all-caps Cyrillic title by ~13% and let it overflow exactly like the old fudge did.
local W_CTRL, W_WIDE = 0.55, 1.00 -- unlisted ASCII / unlisted 3+-byte (real CJK via a
                                  -- fallback font is ~1.0 em; DejaVu itself has no CJK)
-- Per-block 2-byte fallbacks {lo, hi, regular, bold}, first match wins; anything below
-- U+0370 (accented Latin) uses W_LATIN. Values are the measured p75 of each block: the
-- p90 was too blunt because Cyrillic caps and lowercase differ by ~0.15 em, so charging
-- every glyph the caps width over-predicted ordinary lowercase Cyrillic by ~45%.
-- Splitting by case keeps the error to roughly +4..15% — over-predicting, i.e. a title
-- that stops slightly short rather than one that runs off the card.
local W_LATIN, W_LATINB = 0.62, 0.68 -- U+0080-U+036F  accented Latin (near the ASCII mean)
local UBLOCK = {
    { 0x386, 0x3AB, 0.656, 0.730 }, -- Greek capitals
    { 0x3AC, 0x3FF, 0.545, 0.615 }, -- Greek lowercase
    { 0x400, 0x42F, 0.675, 0.765 }, -- Cyrillic capitals (Ж Ш Щ Ю reach 0.94 / 1.14)
    { 0x430, 0x45F, 0.585, 0.637 }, -- Cyrillic lowercase
    { 0x460, 0x4FF, 0.678, 0.801 }, -- Cyrillic extended/historic
}
-- Codepoint of a 2-byte UTF-8 sequence: 0xC0-0xDF lead carries the top 5 bits.
local function cp2(b1, b2) return (b1 - 0xC0) * 64 + (b2 - 0x80) end
local function block_w(cp, bold)
    for k = 1, #UBLOCK do
        local r = UBLOCK[k]
        if cp >= r[1] and cp <= r[2] then return bold and r[4] or r[3] end
    end
    return bold and W_LATINB or W_LATIN
end
local function text_w(s, fs, bold)
    local t = bold and TWB or TW
    local w, i, n = 0, 1, #s
    while i <= n do
        local b = s:byte(i)
        if b < 128 then
            w = w + (t[s:sub(i, i)] or W_CTRL)
            i = i + 1
        else -- multibyte: look the whole glyph up, else a width-class fallback
            local j = i + 1
            while j <= n and s:byte(j) >= 128 and s:byte(j) < 192 do j = j + 1 end
            local g = t[s:sub(i, j - 1)]
            if not g then
                if b >= 0xE0 then g = W_WIDE
                else g = block_w(cp2(b, s:byte(i + 1) or 0x80), bold) end
            end
            w = w + g
            i = j
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
function M.wrap_px(text, maxw, fs, maxlines, bold)
    local chars = utf8_chars(text)
    local lines, line, lastsep, linew = {}, {}, nil, 0 -- linew: running width in fs=1 units
    local truncated = false
    local function reflow() -- recompute lastsep + linew over the current `line`
        lastsep, linew = nil, 0
        for i = 1, #line do
            if WRAP_SEP[line[i]] then lastsep = i end
            linew = linew + text_w(line[i], 1, bold)
        end
    end
    for idx, ch in ipairs(chars) do
        line[#line + 1] = ch
        -- accumulate at fs=1 (raw weight); *fs only in the compare so this equals
        -- text_w(whole line, fs) to the last float bit (text_w multiplies by fs once).
        linew = linew + text_w(ch, 1, bold)
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
-- marker: the truncation suffix (default "…"); pass e.g. "-" for a tighter cut.
function M.ellipsize_px(text, maxw, fs, marker, bold)
    marker = marker or ELLIPSIS
    if text_w(text, fs, bold) <= maxw then return text end
    local chars = utf8_chars(text)
    local line, lastsep, linew = {}, nil, 0
    local ellipw = text_w(marker, 1, bold) -- marker width in fs=1 units
    for _, ch in ipairs(chars) do
        line[#line + 1] = ch
        linew = linew + text_w(ch, 1, bold) -- fs=1 units; *fs in the compare == text_w(line, fs)
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
    return (table.concat(line):gsub("[%s._/,%-]+$", "")) .. marker -- trim trailing seps
end

return M
