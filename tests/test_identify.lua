-- Standalone unit test for identify.lua (pure Lua, no mpv deps).
--   run:  luajit tests/test_identify.lua   (from the repo root)
package.path = "scripts/spincard/?.lua;" .. package.path
local I = require("identify")

local fails = 0
local function check(name, got, want)
    if got ~= want then
        fails = fails + 1
        print(string.format("FAIL %s\n     got:  %s\n     want: %s", name, tostring(got), tostring(want)))
    else
        print("ok   " .. name)
    end
end

-- Explicit SxxEyy is definitive (any path)
local a = I.identify("/zhd/TV/Breaking.Bad/Season.1/Breaking.Bad.S01E01.Pilot.mkv")
check("SxxEyy kind", a.kind, "tv")
check("SxxEyy season", a.season, 1)
check("SxxEyy episode", a.episode, 1)

-- NxNN ("x" separator) is NOT the format → no season/episode; not TV off a folder
local b = I.identify("/media/Some.Show.3x07.mkv")
check("NxNN not tv", b.kind ~= "tv", true)
check("NxNN no season", b.season, nil)
-- a /TV/ folder still classifies as TV (show-level), but 3x07 yields no season
local b2 = I.identify("/zhd/TV/Some.Show/Some.Show.3x07.mkv")
check("TV-folder kind", b2.kind, "tv")
check("TV-folder no season (3x07 ignored)", b2.season, nil)
-- single-digit s1e1 is NOT the format (S & E need 2+ digits)
local b3 = I.identify("/media/Some.Show.s1e1.mkv")
check("s1e1 not tv", b3.kind ~= "tv", true)
-- two-digit season + episode is the format
local b4 = I.identify("/zhd/TV/Show/Show.S12E34.mkv")
check("S12E34 kind", b4.kind, "tv")
check("S12E34 season", b4.season, 12)
check("S12E34 episode", b4.episode, 34)

-- BUG (fixed): an NxNN embedded IN A WORD must NOT be read as S/E — keep as-is.
-- tmp.A72x7t.mp4 was wrongly read as S72E07 (72x7 bounded by letters a/t).
local c = I.identify("/tmp/tmp.A72x7t.mp4")
check("embedded NxNN not tv", c.kind, "unknown")
check("embedded NxNN no season", c.season, nil)
check("embedded NxNN keeps raw name", c.display, "tmp.A72x7t.mp4")

-- A resolution must never become S/E
local d = I.identify("/zhd/Movies/Some.Film.2020.1920x1080.mkv")
check("resolution not tv", d.kind, "movie")
check("resolution no season", d.season, nil)

print(string.rep("-", 40))
if fails == 0 then print("ALL PASS") else print(fails .. " FAILURE(S)"); os.exit(1) end
