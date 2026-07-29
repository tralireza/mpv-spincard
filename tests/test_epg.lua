-- Headless test for the live-TV "no EPG for the current time" fix.
--   run:  luajit tests/test_epg.lua   (from the repo root)
--
-- Part 1 — tvheadend.tvh_fetch: given a Tvheadend EPG grid (ordered by start,
--   forward-filtered) it must pick the programme that COVERS now (start<=now<stop),
--   not blindly entries[1]; on a guide gap it must return a `no_epg` card (channel +
--   upcoming only). Grids use the REAL timestamps captured from the i7 server.
-- Part 2 — card.build_card: a `no_epg` livetv card renders the channel as the
--   heading + "No programme information" (and still lists upcoming), never a
--   stale/future programme dressed up as "now".

local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function() return setmetatable({}, { __index = function() return function() return nil end end }) end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return { parse_json = function() end, format_json = function() end } end
package.path = "scripts/spincard/?.lua;" .. package.path

-- Freeze "now" to the capture instant so the fixed EPG timestamps are meaningful.
local NOW = 1785066321 -- 2026 ... 12:45:21 (matches the captured grid)
os.time = function() return NOW end

-- Real util (card needs its formatters); only curl_json is stubbed to feed a grid.
-- Must be replaced BEFORE requiring tvheadend, which captures curl_json as an upvalue.
local util = require("util")
local GRID -- set per case
util.curl_json = function(_, cb) cb(GRID) end

local tvh = require("tvheadend")
local card = require("card")

local fails = 0
local function check(cond, label)
    print((cond and "ok   " or "FAIL ") .. label)
    if not cond then fails = fails + 1 end
end

-- ---- Part 1: tvh_fetch selection ----------------------------------------
local function fetch(grid, want, chan_name)
    tvh.init({ tvheadend_url = "http://x", live_upcoming = want })
    GRID = grid
    local out
    -- a /stream/channel/<uuid> path takes tvh_resolve's direct branch (no mp needed)
    tvh.tvh_fetch("http://x/stream/channel/abcd1234", chan_name or "FallbackChan",
        function(c) out = c end)
    return out
end

-- A: programme covering now (real "5 HD" slot: 63600 <= 66321 < 67200)
local a = fetch({ entries = {
    { title = "Happy Campers", start = 1785063600, stop = 1785067200, channelName = "5 HD" },
    { title = "The Next Show", start = 1785067200, stop = 1785070800, channelName = "5 HD" },
    { title = "Later Show",    start = 1785070800, stop = 1785074400, channelName = "5 HD" },
} }, 7)
check(a and not a.no_epg, "A: covering slot -> current card (not no_epg)")
check(a and a.title == "Happy Campers", "A: title is the programme on now")
check(a and a.start == 1785063600 and a.stop == 1785067200, "A: start/stop of the current programme")
check(a and a.channel == "5 HD", "A: channel name")
check(a and #a.upcoming == 2 and a.upcoming[1].title == "The Next Show", "A: upcoming = the future programmes")

-- B: guide GAP (real "ITV2 HD": entries[1] is +851s in the FUTURE) -> no_epg
local b = fetch({ entries = {
    { title = "Bob's Burgers", start = 1785067172, stop = 1785068972, channelName = "ITV2 HD" },
    { title = "Family Guy",    start = 1785068972, stop = 1785070772, channelName = "ITV2 HD" },
} }, 7)
check(b and b.no_epg == true, "B: gap over now -> no_epg card")
check(b and b.title == nil, "B: no stale/future programme passed off as now")
check(b and b.channel == "ITV2 HD", "B: channel still resolved")
check(b and #b.upcoming == 2 and b.upcoming[1].title == "Bob's Burgers", "B: future programme becomes upcoming[1]")

-- C: long off-air gap, single future entry (real "BBCScotlandHD")
local c = fetch({ entries = {
    { title = "This is BBC Scotland", start = 1785085200, stop = 1785088800, channelName = "BBCScotlandHD" },
} }, 7)
check(c and c.no_epg == true, "C: off-air -> no_epg")
check(c and c.channel == "BBCScotlandHD" and #c.upcoming == 1, "C: channel + single upcoming")

-- D: robustness — entries[1] already ENDED (past), entries[2] covers now. The scan
--    (not entries[1]) must find the true current; past entry excluded from upcoming.
local d = fetch({ entries = {
    { title = "Past Prog",   start = 1785060000, stop = 1785066000, channelName = "RobustChan" }, -- ended (< now)
    { title = "Now Prog",    start = 1785066000, stop = 1785067200, channelName = "RobustChan" }, -- covers now
    { title = "Future Prog", start = 1785067200, stop = 1785070800, channelName = "RobustChan" },
} }, 7)
check(d and not d.no_epg and d.title == "Now Prog", "D: scans past a stale entries[1] to the covering programme")
check(d and #d.upcoming == 1 and d.upcoming[1].title == "Future Prog", "D: past/current excluded from upcoming")

-- E: live_upcoming = 0 must yield an EMPTY upcoming list (no off-by-one leak)
local e = fetch({ entries = {
    { title = "Bob's Burgers", start = 1785067172, stop = 1785068972, channelName = "ITV2 HD" },
    { title = "Family Guy",    start = 1785068972, stop = 1785070772, channelName = "ITV2 HD" },
} }, 0)
check(e and e.no_epg == true and #e.upcoming == 0, "E: live_upcoming=0 -> empty upcoming")

-- F: empty grid -> no_epg card that still carries the fallback channel name
local f = fetch({ entries = {} }, 7, "MyChannel HD")
check(f and f.no_epg == true and f.channel == "MyChannel HD", "F: empty grid -> no_epg with fallback channel")

-- G: transient fetch/parse failure (nil, or no entries field) -> nil (keep prior card)
check(fetch(nil, 7) == nil, "G1: nil response -> nil (don't overwrite the card)")
check(fetch({}, 7) == nil, "G2: response without .entries -> nil")

-- ---- Part 2: build_card renders a no_epg card sensibly -------------------
local opts = {
    pos_x = 40, pos_y = 40, anchor = "bottom", show_tech = false,
    live_upcoming_delay = 3, live_upcoming_lines = 3, live_upcoming_secs = 1.5,
    signal_dbm_max = -40.6, cast_max = 5,
}
card.init(opts, {
    anim_fade = function() return 1 end, cur_signal = function() return nil end,
    cast_idx = function() return 0 end, overview_idx = function() return 0 end,
    upnext_idx = function() return 0 end, tech = function() return {} end,
    casthead_active = function() return false end,
})

local ass_gap = card.build_card({
    kind = "livetv", channel = "BBCScotlandHD", no_epg = true,
    upcoming = { { title = "This is BBC Scotland", start = NOW + 540 } }, -- next in 9 min
})
local function has(s) return ass_gap:find(s, 1, true) ~= nil end
local function count(hay, needle)
    local n, i = 0, 1
    while true do local s = hay:find(needle, i, true); if not s then break end; n = n + 1; i = s + 1 end
    return n
end
check(has("BBCScotlandHD"), "P2: no_epg card shows the channel")
check(count(ass_gap, "BBCScotlandHD") >= 2, "P2: channel appears in BOTH the heading and the subline")
check(has("[No program information]"), "P2: no_epg card shows the note in the synopsis slot")
check(has("Next in"), "P2: no_epg card shows a countdown bar to the next programme")
check(has("This is BBC Scotland"), "P2: no_epg card still lists upcoming programmes")

-- no_epg with NO upcoming: channel + note render, but no countdown bar (no next.start)
local ass_gap0 = card.build_card({ kind = "livetv", channel = "Dead Chan", no_epg = true, upcoming = {} })
check(ass_gap0:find("Dead Chan", 1, true) and ass_gap0:find("[No program information]", 1, true) ~= nil,
    "P2: no_epg + empty upcoming still shows channel + note")
check(ass_gap0:find("Next in", 1, true) == nil, "P2: no upcoming -> no countdown bar")

-- a normal live card is unchanged: programme title + channel subline both present
local ass_ok = card.build_card({
    kind = "livetv", channel = "5 HD", title = "Happy Campers",
    subtitle = "Episode 1", overview = "Caravan capers.",
    start = 1785063600, stop = 1785067200,
    upcoming = { { title = "The Next Show", start = 1785067200 } },
})
check(ass_ok:find("Happy Campers", 1, true) ~= nil, "P2: normal card still shows the programme title")
check(ass_ok:find("5 HD", 1, true) ~= nil, "P2: normal card still shows the channel")
check(ass_ok:find("[No program information]", 1, true) == nil, "P2: normal card has no 'no program' note")

print(string.rep("-", 48))
if fails == 0 then print("ALL PASS") else print(fails .. " FAILURE(S)"); os.exit(1) end
