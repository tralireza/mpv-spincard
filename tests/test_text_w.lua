-- Ground-truth calibration test for util.text_w — the test whose absence let the
-- "unknown card title walks off the card" bug ship. Every other test measures the
-- estimator against its own output; this one pins it to a REAL libass render.
--   run:  luajit tests/test_text_w.lua   (from the repo root)
--
-- PROVENANCE of the expected widths below (local/calib-raw.json, not tracked):
--   host   i7, mpv v0.41.0-920-gdd5d17d32, window 1600x900 (PlayRes 1280x720)
--   font   osd-font unset -> "sans-serif" -> fc-match
--          /usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf (DejaVu Sans Book);
--          bold -> DejaVuSans-Bold.ttf
--   method `osd-overlay ... compute_bounds=true` (hidden=true) on the real OSD,
--          \bord0\shad0 ink width, cross-checked against the font file's advances
--   `reg`  = ink width rendered REGULAR, `bold` = the same string rendered \b1
-- Re-measure (and re-gold) if osd_font is ever set or the target box's
-- sans-serif resolves to another family — the tables are DejaVu-specific.
--
-- Two bands are asserted per case:
--   * relative: |err| <= 3 %   (the table's modelling accuracy)
--   * absolute: predicted >= real - ABS_BAND   (the residual the card's
--     `fitw = innerw - 12` reserve is sized to absorb; a sum of ADVANCES cannot
--     carry the ink bbox's antialias fringe / side bearings)

local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function() return setmetatable({}, { __index = function() return function() return nil end end }) end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return { parse_json = function() end, format_json = function() end } end
package.path = "scripts/spincard/?.lua;" .. package.path

local util = require("util")

local REL_BAND = 3.0 -- percent
local ABS_BAND = 12  -- px: must match card.lua's `fitw = innerw - 12` reserve

-- captured libass ink widths (virtual px at PlayRes 1280x720)
local GROUND = {
    { fs = 38, reg = 804,    bold = 907.2,  t = "01.Isle.of.Man.TT.2026x03.RST.Superbike.TT.mp4" },
    { fs = 28, reg = 599.2,  bold = 675.2,  t = "01.Isle.of.Man.TT.2026x03.RST.Superbike.TT.mp4" },
    { fs = 21, reg = 442.4,  bold = 500,    t = "01.Isle.of.Man.TT.2026x03.RST.Superbike.TT.mp4" },
    { fs = 38, reg = 1242.4, bold = 1390.4, t = "The.Grand.Budapest.Hotel.2014.2160p.UHD.BluRay.REMUX.HDR.HEVC.mkv" },
    { fs = 38, reg = 310.4,  bold = 345.6,  t = "Top Gun: Maverick" },
    { fs = 28, reg = 848,    bold = 956,    t = "a lowercase prose style sentence that behaves like ordinary body text" },
    { fs = 21, reg = 638.4,  bold = 720.8,  t = "a lowercase prose style sentence that behaves like ordinary body text" },
    { fs = 21, reg = 236,    bold = 265.6,  t = "Action, Adventure, Drama" },
    { fs = 24, reg = 348,    bold = 404,    t = "S01E04 - The Weight of the World" },
    { fs = 24, reg = 250.4,  bold = 295.2,  t = "The Weight of the World" },
    { fs = 38, reg = 560.8,  bold = 656,    t = "MMMMMMMMMMMMMMMMMMMM" },
    { fs = 38, reg = 184.8,  bold = 224,    t = "iiiiiiiiiiiiiiiiiiii" },
    { fs = 38, reg = 329.6,  bold = 363.2,  t = "WWWWWWWWWW" },
    { fs = 38, reg = 212.8,  bold = 229.6,  t = "0123456789" },
    { fs = 38, reg = 210.4,  bold = 249.6,  t = "...................." },
    { fs = 38, reg = 806.4,  bold = 912.8,  t = "The Lord of the Rings: The Fellowship of the Ring" },
    { fs = 38, reg = 975.2,  bold = 1088,   t = "Breaking.Bad.S05E14.Ozymandias.1080p.BluRay.x264.mkv" },
    { fs = 38, reg = 324,    bold = 363.2,  t = "Isle of Man TT 2026" },
    { fs = 21, reg = 381.6,  bold = 433.6,  t = "Christopher Nolan \226\128\162 Warner Bros. Pictures" },
    { fs = 21, reg = 297.6,  bold = 332,    t = "PG-13 \194\183 $722M \194\183 Skydance Media" },
    { fs = 21, reg = 315.2,  bold = 353.6,  t = "(2022) \194\183 131 min \194\183 Joseph Kosinski" },
}

local fails, worst_rel, worst_abs = 0, 0, 0
local function check(t, fs, real, bold)
    local pred = util.text_w(t, fs, bold)
    local rel  = (pred - real) / real * 100
    local abs_ = pred - real
    if math.abs(rel) > math.abs(worst_rel) then worst_rel = rel end
    if abs_ < worst_abs then worst_abs = abs_ end
    local ok = math.abs(rel) <= REL_BAND and abs_ >= -ABS_BAND
    if not ok then fails = fails + 1 end
    print(string.format("%s fs%-3d %-7s real %7.1f  pred %7.1f  %+6.2f%%  %+6.1fpx  %s",
        ok and "ok  " or "FAIL", fs, bold and "bold" or "regular", real, pred, rel, abs_, t:sub(1, 46)))
end

for _, g in ipairs(GROUND) do
    check(g.t, g.fs, g.reg, false)
    check(g.t, g.fs, g.bold, true)
end

-- The bold table must be a SEPARATE model, not the regular one scaled: a missed
-- \b1 flag at a call site is exactly the failure this whole change fixes, so make
-- sure bold actually differs (and always by more than a rounding wobble).
local function want(label, cond)
    print((cond and "ok   " or "FAIL ") .. label)
    if not cond then fails = fails + 1 end
end
local probe = "The Weight of the World"
want("bold measures wider than regular",
    util.text_w(probe, 21, true) > util.text_w(probe, 21) * 1.05)
-- fs scales linearly (callers rely on text_w(s,1)*fs == text_w(s,fs) — the fs=1
-- accumulate-then-multiply invariant in wrap_px / ellipsize_px)
want("text_w(s,1)*fs == text_w(s,fs) exactly",
    util.text_w(probe, 1) * 21 == util.text_w(probe, 21)
    and util.text_w(probe, 1, true) * 38 == util.text_w(probe, 38, true))
-- unknown glyphs must not measure zero (an unlisted char would silently shrink a budget)
want("unlisted ASCII / CJK glyphs get a non-zero fallback",
    util.text_w("\1\2", 10) > 0 and util.text_w("\228\184\173", 10) > 0)

-- Non-Latin fallback. These blocks have no per-glyph entries, so they ride the
-- block-aware p75 fallbacks. The invariant that matters is DIRECTIONAL: the estimate
-- must never come in UNDER the real DejaVu advance sum, because under-prediction is
-- what walks a title off the card. Reference widths are real DejaVu advances
-- (pillow getlength x 2048/2384, the same scaling libass applies), fs 38.
-- A flat 0.62 fallback under-predicted the all-caps Cyrillic row by 13%.
local NONLATIN = { -- { text, real_regular_px, real_bold_px }
    { "\208\169\208\149\208\148\208\160\208\158\208\149 \208\155\208\149\208\162\208\158", 249.0, 279.4 }, -- ЩЕДРОЕ ЛЕТО
    { "\208\152\208\180\208\184 \208\184 \209\129\208\188\208\190\209\130\209\128\208\184", 233.7, 255.8 }, -- Иди и смотри
    { "\206\159 \206\152\206\175\206\177\209\131\206\191\209\130", 154.2, 169.2 },                          -- Greek
    { "Am\195\169lie", 112.4, 125.9 },
}
for _, nl in ipairs(NONLATIN) do
    local s, rr, rb = nl[1], nl[2], nl[3]
    want(string.format("non-Latin never under-predicts: %s (reg %+.1f%%, bold %+.1f%%)",
            s:sub(1, 16), (util.text_w(s, 38) / rr - 1) * 100, (util.text_w(s, 38, true) / rb - 1) * 100),
        util.text_w(s, 38) >= rr and util.text_w(s, 38, true) >= rb)
end

print(string.rep("-", 40))
print(string.format("worst relative %+.2f%%   worst absolute %+.1f px   (bands: %.1f%% / %d px)",
    worst_rel, worst_abs, REL_BAND, ABS_BAND))
if fails == 0 then print("ALL PASS") else print(fails .. " FAILURE(S)"); os.exit(1) end
