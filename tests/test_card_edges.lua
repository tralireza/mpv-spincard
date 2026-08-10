-- Card-level overflow test: NO text event may render past the card's inner right
-- edge, on any of the 4 card kinds, with deliberately long/rich fixtures.
--   run:  luajit tests/test_card_edges.lua   (from the repo root)
--
-- Part 1 is the regression for the reported bug: the "unknown" card's raw file
-- name "01.Isle.of.Man.TT.2026x03.RST.Superbike.TT.mp4" measured 987.2 under the
-- OLD guessed text_w weights, slipping under the old fitw = innerw*1.22 = 990 by
-- 2.8 units — so heading() kept fs 38 and ellipsize_px returned the string
-- untouched, and it rendered ~900 real px wide inside an 812 px card. This test
-- FAILS on that code and passes with the measured advance tables + fitw = innerw-12.
--
-- Part 2 generalises it: build all 4 kinds and walk every emitted event, reading
-- its own \pos / \fs / \an / \b1 (including inline {\b1}..{\b0} runs in the movie
-- meta line) and clamping \clip'd marquees, then assert the right edge. Without
-- this, a forgotten bold=true at a call site under-measures by 11-16 % silently.

local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function()
    local props = { ["percent-pos"] = 42, ["time-pos"] = 1200, ["time-remaining"] = 1800 }
    return setmetatable({ get_property_number = function(k) return props[k] end,
        get_property = function() return nil end },
        { __index = function() return function() return nil end end })
end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return { parse_json = function() end, format_json = function() end } end
package.path = "scripts/spincard/?.lua;" .. package.path

local card   = require("card")
local util   = require("util")
local layout = require("layout")

local opts = {
    pos_x = 22, pos_y = 22, disc_size = 0.4, anchor = "bottom",
    overview_lines = 6, overview_scroll = false, imdb_votes = true,
    show_tech = true, cast_scroll = false, cast_max = 5, cast_cols = 2,
    cast_lines = 2, cast_fs = 21, cast_bold = true, cast_scroll_dir = "horizontal",
    cast_scroll_px = 3, logo_height = 0.1, signal_dbm_max = -40.6,
    live_upcoming_delay = 3, live_upcoming_lines = 3, live_upcoming_secs = 1.5,
}
local sig = {
    sig = 62000, sig_unit = "%", sig_level = 3, snr = 12500, snr_unit = "dB", snr_level = 3,
    mbps = 6.4, clean = true,
    mux = { delsys = "DVB-S2", freq = 11914000, pol = "V", symrate = 27500000, mod = "PSK/8", fec = "3/4" },
}
card.init(opts, {
    anim_fade = function() return 1 end, cur_signal = function() return sig end,
    cast_idx = function() return 0 end, overview_idx = function() return 0 end,
    upnext_idx = function() return 0 end,
    tech = function() return {
        vwidth = 3840, hdr = "HDR10", vcodec = "HEVC", acodec = "TrueHD", achan = "7.1",
        fps = "23.976", audio = "English 7.1 TrueHD",
        subs = "English, Spanish, French, German, Italian, Dutch, Portuguese",
        chapters = 24, size = "48.2 GiB" } end,
})

local PAD    = layout.PAD
local INNER  = layout.CARD_W - 2 * PAD          -- 812
local LEFT   = opts.pos_x + PAD                 -- card inner left edge
local RIGHT  = LEFT + INNER                     -- card inner right edge
local SLACK  = 0.5                              -- float/rounding tolerance only

local fails = 0
local function check(label, cond, detail)
    print((cond and "ok   " or "FAIL ") .. label .. (detail and ("  " .. detail) or ""))
    if not cond then fails = fails + 1 end
end

-- Measured width of one ASS event's text, honouring inline {\b1}/{\b0} runs.
-- Returns (width, plaintext) or nil for a non-text event (a \p1 vector drawing).
local function event_width(ev)
    if ev:find("\\p1", 1, true) then return nil end          -- vector drawing, not text
    local head, body = ev:match("^({[^}]*})(.*)$")
    if not head or not body or body == "" then return nil end
    local fs = tonumber(head:match("\\fs(%d+)") or "")
    if not fs then return nil end
    local bold = head:find("\\b1", 1, true) ~= nil
    -- Find the next OVERRIDE tag, skipping escaped braces: ass_escape emits \{ and \} for
    -- literal braces, and the TVH channel marker ({@} / {.}) puts them on every live-TV
    -- card. A naive {[^}]*} eats "{.\}" as a tag and silently under-measures the line.
    local function next_tag(s, from)
        local a = from
        while true do
            a = s:find("{", a, true)
            if not a then return nil end
            if a == 1 or s:sub(a - 1, a - 1) ~= "\\" then
                local b = a + 1
                while true do
                    local c = s:find("}", b, true)
                    if not c then return nil end
                    if s:sub(c - 1, c - 1) ~= "\\" then return a, c end
                    b = c + 1
                end
            end
            a = a + 1
        end
    end
    -- \{ and \} render as bare braces, and \\ as one backslash — unescape before measuring.
    local function unescape(s) return (s:gsub("\\([{}\\])", "%1")) end
    local w, plain, i = 0, {}, 1
    while i <= #body do
        local s, e = next_tag(body, i)
        local chunk = unescape(body:sub(i, (s or (#body + 1)) - 1))
        if chunk ~= "" then
            w = w + util.text_w(chunk, fs, bold)
            plain[#plain + 1] = chunk
        end
        if not s then break end
        local tag = body:sub(s, e)
        if tag:find("\\b1", 1, true) then bold = true
        elseif tag:find("\\b0", 1, true) then bold = false end
        i = e + 1
    end
    return w, table.concat(plain), fs
end

-- Right edge of an event: \an9 right-aligns AT \pos, everything else grows right
-- from it; a \clip'd marquee (cast ticker / synopsis glide) is trimmed by libass.
local function event_right(ev)
    local w, plain, fs = event_width(ev)
    if not w then return nil end
    local xs = ev:match("\\pos%((%-?%d+),%-?%d+%)")
    if not xs then return nil end
    local an = tonumber(ev:match("\\an(%d)") or "7")
    local right = ((an == 9) and (tonumber(xs) - w) or tonumber(xs)) + w
    local cx2 = ev:match("\\clip%(%-?%d+,%-?%d+,(%-?%d+),%-?%d+%)")
    if cx2 then right = math.min(right, tonumber(cx2)) end
    return right, plain, fs
end

-- 1 --------------------------------------------------------------- the bug ----
-- the exact failing title, measured off a 1920x1080 i7 capture
local BAD = "01.Isle.of.Man.TT.2026x03.RST.Superbike.TT.mp4"
local uass = card.build_card({ kind = "unknown", title = BAD })
local hw, hfs, htxt
for ev in uass:gmatch("[^\n]+") do
    -- the heading is the FIRST white bold OUTLINED run (\bord2 — pill labels are
    -- white and bold too, but draw \bord0\shad0)
    if not hw and ev:find("1c&HFFFFFF&", 1, true)
        and ev:find("\\b1", 1, true) and ev:find("\\bord2", 1, true) then
        local w, plain, fs = event_width(ev)
        if w then hw, htxt, hfs = w, plain, fs end
    end
end
check("unknown heading is emitted", hw ~= nil, htxt and ("'" .. htxt .. "'") or "")
check("unknown heading fits the card's INNER width",
    hw ~= nil and hw <= INNER + SLACK,
    hw and string.format("fs%d  width %.1f  <= innerw %d", hfs or 0, hw, INNER) or "")
check("unknown heading dropped to the small font",
    hfs == 28, "fs=" .. tostring(hfs))
check("unknown heading keeps the whole file name (no ellipsis needed at fs28)",
    htxt == BAD, htxt or "")

-- 2 ------------------------------------------------ every kind, every event ----
local OVW = "A long synopsis that has to wrap over several lines so the wrap budget is exercised "
    .. "end to end; it keeps going with ordinary lowercase prose about a pilot, a plan, and an "
    .. "impossible mission that nobody expects to survive."
local common = {
    -- 108 chars: a normal TMDB tagline length, and past the ~88-char point where an
    -- unfitted tagline starts hanging off the card. A short fixture here passed the
    -- sweep while the tagline was drawn with no width fit at all.
    tagline = "Everything you know about the future is about to change, and nothing "
        .. "will ever be the same again for anyone.",
    genres = { "Action", "Adventure", "Drama", "Thriller", "Science Fiction" },
    cast = { { name = "Tom Cruise", role = "Capt. Pete Mitchell" },
             { name = "Jennifer Connelly", role = "Penny Benjamin" },
             { name = "Miles Teller", role = "Lt. Bradley Bradshaw" },
             { name = "Glen Powell", role = "Lt. Jake Seresin" },
             { name = "Ed Harris", role = "Rear Adm. Chester Cain" } },
    overview = OVW, rating = 8.3, rating_src = "TMDB", rating_imdb = 8.7, rating_imdb_votes = 1234567,
    rt = 96, mc = 78, awards = "Won 1 Oscar. 118 wins & 236 nominations total.",
    boxoffice = 1495696292, mpaa = "PG-13", studio = "Skydance Media / Paramount Pictures",
    director = "Joseph Kosinski", runtime = 131,
}
local function mk(t)
    local c = {}
    for k, v in pairs(common) do c[k] = v end
    for k, v in pairs(t) do c[k] = v end
    return c
end
local now = os.time()
local kinds = {
    { "movie",   mk{ kind = "movie", title = "Mission: Impossible - Dead Reckoning Part One", year = "2023" } },
    { "tv",      mk{ kind = "tv", title = "The Lord of the Rings: The Rings of Power", year = "2024",
                     season = 2, episode = 8, ep_total = 8,
                     episode_title = "Shadow and Flame of the Deep Mines" } },
    { "livetv",  mk{ kind = "livetv", title = "The Grand Budapest Hotel", channel = "{@} BBC Two Scotland HD",
                     subtitle = "A concierge and his protege become embroiled in a murder plot spanning "
                        .. "the whole of a fictional European republic",
                     start = now - 600, stop = now + 1800,
                     -- all-caps 72-char EPG title: normal for some feeds, and the case the
                     -- old character budget (innerw/(fs*0.5) = 90 chars) let through
                     upcoming = { { title = "MOTD2 EXTRA: PREMIER LEAGUE HIGHLIGHTS, ANALYSIS AND REACTION FROM TODAY", start = now + 1800 },
                                  { title = "Weather for the Week Ahead across the whole country", start = now + 3600 },
                                  { title = "Sign Zone: Question Time from somewhere far away", start = now + 5400 } } } },
    { "unknown", mk{ kind = "unknown", title = BAD } },
    { "no_epg",  { kind = "livetv", no_epg = true, channel = "{.} BBC Scotland HD",
                   upcoming = { { title = "The Nine with a long programme title", start = now + 900 } } } },
}
for _, kv in ipairs(kinds) do
    local name, c = kv[1], kv[2]
    local ass = card.build_card(c)
    local worst, wtxt, wfs = -math.huge, "", 0
    for ev in ass:gmatch("[^\n]+") do
        local right, plain, fs = event_right(ev)
        if right and right > worst then worst, wtxt, wfs = right, plain, fs end
    end
    check(string.format("%-7s no event crosses the inner edge", name),
        worst <= RIGHT + SLACK,
        string.format("worst right %.1f (inner edge %d, %+.1f)  fs%d  '%s'",
            worst, RIGHT, worst - RIGHT, wfs or 0, (wtxt or ""):sub(1, 44)))
end

-- 3 ---------------------------------- movie meta row: honest mixed-weight reserve ----
-- The row is `(YYYY) • runtime • director` (left) and `cert • $box • studio` (right),
-- but only the year, box office and director render \b1. Measuring either cluster as
-- wholly bold over-books the reserve ~52px and ellipsises a director that fits: the
-- Oppenheimer row needs 724.8 of the 812px inner width, i.e. 87px spare, yet the
-- all-bold reserve left the name 1.3px short.
local mass = card.build_card({
    kind = "movie", title = "Oppenheimer", year = "2023", runtime = 131,
    mpaa = "PG-13", boxoffice = 1495696292, studio = "Warner Bros. Pictures",
    director = "Christopher Nolan", overview = "x", genres = { "Drama" },
})
local mleft
for ev in mass:gmatch("[^\n]+") do
    if ev:find("Christopher", 1, true) then mleft = ev end
end
check("movie meta keeps a director that fits (no phantom bold reserve)",
    mleft ~= nil and mleft:find("Christopher Nolan", 1, true) ~= nil,
    mleft and mleft:sub(-64) or "no director event")

print(string.rep("-", 40))
if fails == 0 then print("ALL PASS") else print(fails .. " FAILURE(S)"); os.exit(1) end
