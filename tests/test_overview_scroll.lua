-- Overview scroll modes: verify smooth (continuous px glide, clipped window) vs line
-- (one-line jump) vs static (fits => no scroll). No mpv/network.
--   run:  luajit tests/test_overview_scroll.lua
local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function() return setmetatable({}, { __index = function() return function() return nil end end }) end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return { parse_json = function() end, format_json = function() end } end
package.path = "scripts/spincard/?.lua;" .. package.path
local card = require("card")

local OVIDX = 0
local base = {
    pos_x = 22, pos_y = 22, anchor = "bottom", overview_lines = 4, overview_scroll = true,
    show_tech = false, cast_scroll = false, cast_max = 0, card_max_height = 0,
    overview_scroll_px = 1,
}
local deps = {
    anim_fade = function() return 1 end, cur_signal = function() return nil end,
    cast_idx = function() return 0 end, overview_idx = function() return OVIDX end,
    upnext_idx = function() return 0 end, casthead_active = function() return false end,
    tech = function() return {} end,
}
local function opts_with(o2) local o = {}; for k, v in pairs(base) do o[k] = v end; for k, v in pairs(o2 or {}) do o[k] = v end; return o end
local LONG = ("A sprawling synopsis sentence that wraps across many many lines when it is "
    .. "rendered into the card body area so the window definitely needs to scroll. "):rep(5)

local function ass(mode, idx, overview)
    OVIDX = idx
    card.init(opts_with({ overview_scroll_mode = mode }), deps)
    return (card.build_card({ kind = "movie", title = "X", year = "2020", overview = overview }))
end
-- overview lines are the ONLY C8C8C8 events; collect their \pos y coords
local function ov_ys(a)
    local ys = {}
    for pre, y in a:gmatch("\\pos%((%-?%d+),(%-?%d+)%)[^}]-1c&HC8C8C8&") do ys[#ys + 1] = tonumber(y) end
    -- the pattern above requires \pos BEFORE the colour; try both orders
    if #ys == 0 then
        for y in a:gmatch("1c&HC8C8C8&[^}]-\\pos%(%-?%d+,(%-?%d+)%)") do ys[#ys + 1] = tonumber(y) end
    end
    return ys
end
local function count(s, needle) local n = 0; for _ in s:gmatch(needle) do n = n + 1 end; return n end
local function min(t) local m; for _, v in ipairs(t) do if not m or v < m then m = v end end; return m end

local fails = 0
local function check(c, msg) if c then print("  PASS  " .. msg) else fails = fails + 1; print("  FAIL  " .. msg) end end

print("smooth mode (long overview):")
local sm0, sm10 = ass("smooth", 0, LONG), ass("smooth", 10, LONG)
check(count(sm0, "1c&HC8C8C8&") > 0, "draws overview lines")
check(count(sm0, "\\clip%(") >= 1, "smooth overview is clipped to a window")
check(min(ov_ys(sm10)) < min(ov_ys(sm0)), "top overview line glides UP as idx grows (10px)")
-- exact: at idx=10,px=1 the first visible line sits 10px above its idx=0 position
check(min(ov_ys(sm0)) - min(ov_ys(sm10)) == 10, "glide is exactly idx*px (10px) up")

print("line mode (long overview):")
local ln0 = ass("line", 0, LONG)
check(count(ln0, "1c&HC8C8C8&") == 4, "draws exactly overview_lines (4) lines")
-- line mode overview events carry no per-line \clip (plain line() text runs)
local ln_clips = select(2, ln0:gsub("\\clip%(", "")) -- total clips in the whole card
local sm_clips = select(2, sm0:gsub("\\clip%(", ""))
check(sm_clips > ln_clips, "smooth adds a clip that line mode does not")

print("static (short overview fits the window):")
local short = "One short line. Two short line."
local st = ass("smooth", 0, short)
check(count(st, "1c&HC8C8C8&") >= 1, "draws the short overview")
check(count(st, "\\clip%(") == 0 or not st:find("C8C8C8.-\\clip"), "no scroll clip when it fits")

print("cycle ends with the last line at the bottom (never blanks); per-cycle top-hold:")
do
    -- delay unset (hold=0): over a full cycle the window always shows lines — we scroll only
    -- until the end reaches the window bottom, NOT off the top, so it never blanks. No crash.
    local minc = 99
    for i = 0, 500 do
        local c = count(ass("smooth", i, LONG), "1c&HC8C8C8&")
        if c < minc then minc = c end
    end
    check(minc >= 1, "window never blanks over a full cycle (end stops at the bottom)")

    -- per-cycle top-hold: delay=1, interval=0.1 => hold=10 ticks held flat at the top,
    -- honoured on the first pass and (via the modulo) at every restart.
    local function assh(idx)
        OVIDX = idx
        card.init(opts_with({ overview_scroll_mode = "smooth", overview_scroll_delay = 1, overview_scroll_interval = 0.1 }), deps)
        return (card.build_card({ kind = "movie", title = "X", year = "2020", overview = LONG }))
    end
    local y5, y9, y15 = ov_ys(assh(5)), ov_ys(assh(9)), ov_ys(assh(15))
    check(min(y5) == min(y9), "top held flat during the delay (idx 5 == idx 9)")
    check(min(y15) < min(y5), "glide resumes after the hold (idx 15 moved up)")

    -- symmetric END-hold: mark the last synopsis line and track its y; at the end the last
    -- line sits at the window bottom (its max y) and is HELD there for ~hold ticks (not one).
    local MARKED = LONG .. " ZLASTZ"
    local function last_y(idx)
        OVIDX = idx
        card.init(opts_with({ overview_scroll_mode = "smooth", overview_scroll_delay = 1, overview_scroll_interval = 0.1 }), deps)
        local a = card.build_card({ kind = "movie", title = "X", year = "2020", overview = MARKED })
        local y = a:match("\\pos%(%-?%d+,(%-?%d+)%)[^{]-ZLASTZ")
        return y and tonumber(y)
    end
    local maxy, maxcount = nil, 0
    for i = 0, 800 do
        local y = last_y(i)
        if y then
            if not maxy or y > maxy then maxy, maxcount = y, 1
            elseif y == maxy then maxcount = maxcount + 1 end
        end
    end
    check(maxcount >= 5, "end window HELD for the delay (last line rests at the bottom, not flashed)")
end

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
