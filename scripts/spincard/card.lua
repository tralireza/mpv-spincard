-- spincard/card — build_card: assemble the entire now-playing card as one ASS
-- string (movie/TV + live-TV layouts, heading/rating/meta/overview/genres, the
-- cast + synopsis marquees, tech pills + shared progress_row, rounded box, and the
-- bottom-anchor grow-up). Pure render: reads opts + a snapshot of card state via
-- getter closures (deps: anim_fade / cur_signal / cast_idx / overview_idx) and
-- RETURNS (assdata, logo_rect, card_rect) so main can hand the rects to images
-- (clearlogo/disc placement). Requires util (formatters + text measure) and images
-- (the clearlogo state table + LOGO_GAP); tech data arrives via deps.tech(), which
-- main memoises (gather_tech is static mid-playback — no per-render prop reads).

local mp    = require "mp"
local util  = require "util"
local images = require("images")
local layout = require("layout")
local clearlogo, LOGO_GAP = images.clearlogo, images.LOGO_GAP

local ass_escape, fmt_duration, wrap = util.ass_escape, util.fmt_duration, util.wrap
local rrect, star_rating, fmt_date, res_label = util.rrect, util.star_rating, util.fmt_date, util.res_label
local pill_colors, fmt_metric, tier_color = util.pill_colors, util.fmt_metric, util.tier_color
local text_w, wrap_px, ellipsize_px = util.text_w, util.wrap_px, util.ellipsize_px
local fmt_votes = util.fmt_votes

local RES_X, RES_Y = layout.RES_X, layout.RES_Y

local M = {}
local opts, deps = {}, {}
function M.init(o, d) opts, deps = o, d end

-- Display fraction 0..1 for the bar fill (rough ranges — lit count only). Signal
-- dBm fills a 50 dB window whose top is the tuner's configured max (signal_dbm_max,
-- default the observed DS3000 ceiling); % maps directly; SNR dB ~ 0..20.
local function metric_frac(v, unit)
    local f
    if unit == "%" then f = v / 100
    elseif unit == "dBm" then
        local top = tonumber(opts.signal_dbm_max) or -40.6
        f = (v - (top - 50)) / 50
    else f = v / 20 end -- dB
    return math.max(0, math.min(1, f))
end

-- Parse a card_aspect spec into a width:height ratio (w/h) for the height ceiling, or
-- nil to disable the cap. Accepts "phi"/"golden" (φ ≈ 1.618), "W:H" (e.g. "16:9", "3:2",
-- "1.85:1"), a bare number (the W/H ratio, e.g. 1.85), or "off"/"none"/"0"/"" to turn the
-- ceiling off. Anything unrecognised falls back to 16:9. The ceiling height is then
-- CARD_W / ratio (a wider ratio => shorter card; φ ≈ 1.618 is taller than 16:9 = 1.778).
local function aspect_ratio(spec)
    if spec == nil then return 16 / 9 end
    spec = tostring(spec):lower():gsub("%s", "")
    if spec == "" or spec == "off" or spec == "none" or spec == "0" then return nil end
    if spec == "phi" or spec == "golden" then return layout.PHI end
    local w, h = spec:match("^(%d*%.?%d+):(%d*%.?%d+)$")
    if w then w, h = tonumber(w), tonumber(h); if w and h and h > 0 then return w / h end end
    local r = tonumber(spec)
    if r and r > 0 then return r end
    return 16 / 9
end

function M.build_card(c)
    if not c then return "" end
    -- snapshot the card state read below into plain locals (via deps getters) so the
    -- body stays verbatim; logo_rect/card_rect are computed here and returned.
    local anim_fade = deps.anim_fade()
    local cur_signal = deps.cur_signal()
    local cast_scroll_idx = deps.cast_idx()
    local overview_scroll_idx = deps.overview_idx()
    local upnext_scroll_idx = deps.upnext_idx()
    -- the cast-headshot strip (a desktop overlay) replaces the text cast when active;
    -- getter may be absent in a headless test stub, so guard it.
    local casthead_active = deps.casthead_active and deps.casthead_active()
    local logo_rect, card_rect
    local x, y, pad = opts.pos_x, opts.pos_y, layout.PAD
    -- the disc now nestles at the card's TOP-RIGHT corner (pokes out to the right),
    -- so the card no longer needs the old left-margin push for it.
    local bw, content, cy = layout.CARD_W, {}, y + pad
    local innerw = bw - 2 * pad
    -- Card height ceiling. An explicit card_max_height (virtual px) wins; otherwise it's
    -- derived from card_aspect (a width:height ratio, default 16:9) applied to the fixed
    -- width: CARD_W / ratio. A card taller than the ceiling trims its one elastic section
    -- (movie/TV synopsis window / live-TV "Next") so it fits; shorter cards are left
    -- as-is (no padding). nil => uncapped (card_aspect=off, no px override).
    local cap = tonumber(opts.card_max_height) or 0
    if cap <= 0 then
        local ratio = aspect_ratio(opts.card_aspect)
        cap = ratio and math.floor(layout.CARD_W / ratio + 0.5) or nil
    end
    -- text_w over-estimates the OSD sans (~0.6*fs/glyph vs the real ~0.5), so
    -- fitting text to exactly innerw stops ~a word early and leaves empty space on
    -- the right. Fit to this compensated width instead (~1.22x, the measured ratio)
    -- so lines reach the real card edge — typical prose stays in; a caps-heavy run
    -- may reach a touch further. Shared by heading(), the sub line, and the overview.
    local fitw = math.floor(innerw * 1.22)

    -- fade alpha for a given base alpha (00 = opaque), scaled by anim_fade (0..1)
    local function fa(base)
        local a = base + (1 - (anim_fade or 1)) * (255 - base)
        return string.format("%02X", math.max(0, math.min(255, math.floor(a + 0.5))))
    end

    -- A positioned, outlined text run (the card's text primitive). Shared by
    -- line()/put()/txt()/cell(); o = { alpha = <2-hex>, bold, ital } (alpha omitted
    -- => no \alpha tag). Returns the event string; callers append + advance cursors.
    -- o.an picks the ASS alignment/anchor (default 7 = top-left; pass 9 = top-RIGHT so
    -- libass right-aligns the text exactly at px — no text_w width estimate / gap).
    local function text_run(px, py, str, fs, color, o)
        local a = (o and o.alpha) and ("\\alpha&H" .. o.alpha .. "&") or ""
        return string.format(
            "{\\an%d\\pos(%d,%d)%s\\bord2\\shad1\\3c&H000000&\\1c&H%s&\\fs%d%s%s}%s",
            (o and o.an) or 7, math.floor(px), math.floor(py), a, color, fs,
            (o and o.bold) and "\\b1" or "", (o and o.ital) and "\\i1" or "", ass_escape(str))
    end

    -- A filled rounded-rect event (returns the string; caller appends to content/out).
    -- Shared by the pill backgrounds, the progress bar/track, and the card box fill.
    local function fill_rrect(px, py, w, h, r, color, alpha)
        return string.format(
            "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}%s{\\p0}",
            math.floor(px), math.floor(py), color, alpha, rrect(w, h, r))
    end

    local function line(str, fs, color, bold, ital)
        if not str or str == "" then return end
        content[#content + 1] = text_run(x + pad, cy, str, fs, color, { alpha = fa(0), bold = bold, ital = ital })
        cy = cy + math.floor(fs * 1.25)
    end

    -- progress row: a rounded bar (left) + a right-aligned caption on ONE line
    -- (bar width = innerw − caption − gap). Shared by the movie/TV percent-pos bar
    -- and the live-TV "now" bar; only pct + the caption text differ per caller.
    local function progress_row(pct, info)
        cy = cy + 12
        local barh, cfs, gap = 8, 17, 14
        local capw = text_w(info, cfs)
        local barw = math.max(60, innerw - capw - gap)
        local fillw = math.max(2, math.floor(barw * pct / 100))
        local bx = x + pad
        local bary = cy + math.floor((cfs - barh) / 2) -- centre the bar on the caption
        content[#content + 1] = fill_rrect(bx, bary, barw, barh, 4, "555555", fa(64))
        content[#content + 1] = fill_rrect(bx, bary, fillw, barh, 4, "00D7FF", fa(0))
        content[#content + 1] = text_run(bx + barw + gap, cy, info, cfs, "A0A0A0", { alpha = fa(0) })
        cy = cy + math.floor(cfs * 1.25)
    end

    -- White+bold heading fit to the card's inner width: keeps the `big` font when
    -- the text fits one line at that size, else drops to `small` (defaults to `big`
    -- = no shrink); then wraps to <=maxlines lines, or tail-ellipsises to ONE line
    -- when `ellip` is set (a long dotted "unknown" filename reads poorly wrapped).
    -- Shared by the movie/TV heading and the live-TV programme title so both fit
    -- the card the same way — the bare libass event auto-wraps only at the 1280px
    -- overlay width, so an unfitted long title/channel spills past the card.
    local function heading(str, big, small, maxlines, ellip)
        if not str or str == "" then return end
        small = small or big
        local fs = (text_w(str, big) > fitw) and small or big
        if ellip then
            line(ellipsize_px(str, fitw, fs), fs, "FFFFFF", true)
        else
            for _, hl in ipairs(wrap_px(str, fitw, fs, math.max(1, maxlines or 1))) do
                line(hl, fs, "FFFFFF", true)
            end
        end
    end

    -- Pill badge: a rounded bg rect (pw×ph, radius rad) at (bx,by) filled bg@16, plus
    -- a bold fs-label at (bx+padx, ty) in fg. Shared by the rating-source pill, the
    -- tech-spec pills and the transponder pills — each passes its own geometry (they
    -- differ in fs / pad / height / radius / width-estimate), so this unifies only the
    -- two ASS events (bg rrect + label), not the sizing/placement.
    local function pill_badge(p)
        content[#content + 1] = fill_rrect(p.bx, p.by, p.pw, p.ph, p.rad, p.bg, fa(16))
        content[#content + 1] = string.format(
            "{\\an7\\pos(%d,%d)\\alpha&H%s&\\bord0\\shad0\\1c&H%s&\\fs%d\\b1}%s",
            math.floor(p.bx + p.padx), math.floor(p.ty), fa(0), p.fg, p.fs, ass_escape(p.text))
    end

    -- Overview/synopsis block: pixel-wrap `text` to fitw at fs22 and emit up to
    -- `maxlines` grey lines; with `scroll`, wrap to ALL lines and show a maxlines
    -- window advanced by overview_scroll_idx (wraparound). Shared by the movie/TV and
    -- live-TV overview sites (caller adds any leading cy gap); live-TV passes
    -- scroll=false so both stay pixel-identical to the pre-refactor code.
    local function render_overview(text, maxlines, scroll)
        local ofs = 21 -- body tier (matches genre/cast/meta)
        local lineh = math.floor(ofs * 1.25)
        if not scroll then -- static: wrap to the window and draw
            for _, ln in ipairs(wrap_px(text, fitw, ofs, maxlines)) do line(ln, ofs, "C8C8C8") end
            return
        end
        local all = wrap_px(text, fitw, ofs, 999)
        local pool = #all
        if pool <= maxlines then -- fits the window: static, nothing to scroll
            for _, ln in ipairs(all) do line(ln, ofs, "C8C8C8") end
            return
        end
        if tostring(opts.overview_scroll_mode or "smooth"):lower() == "line" then
            -- legacy: jump a whole wrapped line every overview_scroll_secs (wrapping window)
            local start = overview_scroll_idx % pool
            for k = 0, maxlines - 1 do line(all[(start + k) % pool + 1], ofs, "C8C8C8") end
            return
        end
        -- smooth (default): a sawtooth glide with a HOLD at BOTH ends, each = overview_scroll
        -- _delay. Each cycle: HOLD the top window, glide up until the LAST line reaches the
        -- window BOTTOM (end fully shown — never blanks), HOLD the end window the same delay,
        -- then restart at the top. All in tick units (the timer bumps overview_scroll_idx
        -- every overview_scroll_interval). Each visible line is \pos'd at its exact glided y
        -- (the codebase avoids ASS \N — its line spacing drifts from lineh). Windowed: only
        -- the ~maxlines+1 lines in view are emitted.
        local winh = maxlines * lineh
        local px = math.max(0.05, tonumber(opts.overview_scroll_px) or 1) -- fractional ok (sub-1px/tick averages via floor)
        local dist = (pool - maxlines) * lineh     -- glide distance: top -> last line at the window bottom
        local interval = math.max(0.001, tonumber(opts.overview_scroll_interval) or 0.1)
        local hold = math.floor(math.max(0, tonumber(opts.overview_scroll_delay) or 0) / interval + 0.5) -- hold ticks (each end)
        local sticks = math.max(1, math.ceil(dist / px))       -- ticks to complete the glide
        local v = overview_scroll_idx % (hold + sticks + hold) -- top-hold + glide + end-hold
        local off
        if v < hold then off = 0                               -- hold at the top
        elseif v < hold + sticks then off = math.min(dist, (v - hold) * px) -- glide down
        else off = dist end                                    -- hold at the end (last line at the bottom)
        local clip = string.format("\\clip(%d,%d,%d,%d)",
            math.floor(x + pad), math.floor(cy),
            math.floor(x + pad + innerw), math.floor(cy + winh))
        local s = math.floor(off / lineh)          -- first (partly) visible line
        while true do
            local ytop = cy - off + s * lineh
            if ytop > cy + winh then break end
            if s >= 0 and s < pool then            -- a real line; past the last line = blank (no wrap, no gap)
                content[#content + 1] = string.format(
                    "{\\an7\\q2\\pos(%d,%d)%s\\alpha&H%s&\\bord2\\shad1\\3c&H000000&\\1c&HC8C8C8&\\fs%d}%s",
                    math.floor(x + pad), math.floor(ytop), clip, fa(0), ofs, ass_escape(all[s + 1]))
            end
            s = s + 1
        end
        cy = cy + winh
    end

    logo_rect = nil
    if c.kind == "livetv" then
        -- Live TV: programme title, channel + episode, plot, a live "now" bar.
        -- Every text line is fit to the card's inner width (innerw): the title via
        -- heading() (wraps to <=2 lines), the channel+subtitle line tail-ellipsised.
        -- Without this, long text (some EPGs stuff the whole synopsis into
        -- `subtitle`) is unbounded and spills past the card (see heading()).
        if c.no_epg then
            -- No EPG entry covers the current time (a guide gap): mirror the normal
            -- live layout but substitute the channel for the MISSING programme title.
            -- The channel goes in the title slot (heading) AND stays on its usual gold
            -- subline (00D7FF, BGR), and "[No program information]" drops into the synopsis slot. A
            -- countdown bar + the signal / transponder / "Next" list still render below.
            heading((c.channel and c.channel ~= "") and c.channel or "Live TV", 34, nil, 2) -- title slot -> channel (guard "")
            if c.channel and c.channel ~= "" then
                line(ellipsize_px(c.channel, fitw, 24), 24, "00D7FF")   -- channel stays on the subline
            end
            cy = cy + 6
            line("[No program information]", 21, "A0A0A0", false, true) -- synopsis slot
            -- Countdown "progress" bar to the next programme. We know `now` and the
            -- next entry's start, but NOT the gap's start (TVH's grid never returns the
            -- just-ended programme), so this is an imminence gauge over a 1h lookahead:
            -- it fills as the next programme nears (empty when it's far off), and the
            -- caption always shows the exact wait + its clock time. The 1 Hz refresh
            -- re-renders, so the countdown ticks down live.
            local nx = c.upcoming and c.upcoming[1]
            if nx and nx.start then
                local remaining = nx.start - os.time()
                if remaining > 0 then
                    local W = 3600 -- imminence window (TV slots run ~30-60 min)
                    local pct = math.max(0, math.min(100, (1 - remaining / W) * 100))
                    progress_row(pct, string.format("Next in %s   [%s]",
                        fmt_duration(remaining), os.date("%H:%M", nx.start)))
                end
            end
        else
            heading((c.title and c.title ~= "") and c.title or ((c.channel and c.channel ~= "") and c.channel or "Live TV"), 34, nil, 2)
            local sub = c.channel or ""
            if c.subtitle and c.subtitle ~= "" then
                sub = (sub ~= "" and (sub .. "   \226\128\162   ") or "") .. c.subtitle
            end
            if sub ~= "" then line(ellipsize_px(sub, fitw, 24), 24, "00D7FF") end
            if c.overview and c.overview ~= "" then
                cy = cy + 6
                render_overview(c.overview, 4, false)
            end
        end
        if c.start and c.stop and c.stop > c.start then
            local now = os.time()
            local pct = math.max(0, math.min(100, (now - c.start) / (c.stop - c.start) * 100))
            -- caption: elapsed / programme-duration  [ends HH:MM]
            local info = string.format("%s / %s   [%s]",
                fmt_duration(math.max(0, now - c.start)),
                fmt_duration(c.stop - c.start), os.date("%H:%M", c.stop))
            progress_row(pct, info)
        end
        -- live tuner signal meter: dBm • SNR as a segmented [████░░] gauge (filled
        -- = quality colour, empty = dim) • bitrate • a ✔/✗ health tick. One \pos'd
        -- event assembled from inline {\1c} colour spans (libass advances the pen;
        -- line() can't carry tags). Read from module-level cur_signal so the EPG
        -- refresh can't clobber it; whole row (incl. its gaps) is gated on it.
        -- signal meter row: labels/values as \pos'd text runs, the 8-step meters
        -- as crisp \p1 vector rectangles (same drawing mechanism as the card's
        -- rounded box / progress bars) for full-pixel smoothness. A left-to-right
        -- cursor `cx` places each piece — text widths estimated (text_w), meter
        -- widths exact. Each piece keeps its own \pos so the bottom-anchor shift
        -- still moves the whole row.
        if cur_signal then
            local sg = cur_signal
            cy = cy + 8
            local fs = 18
            local DIM, TXT = "A0A0A0", "C8C8C8" -- label / value (BGR)
            local cx, y0 = x + pad, cy
            local function put(str, color)
                content[#content + 1] = text_run(cx, y0, str, fs, color)
                cx = cx + text_w(str, fs)
            end
            local function sepc() cx = cx + 34 end -- fixed gap between groups (no bullet)

            -- 8-step vector meter (no frame): dim + lit bars, each a \p1 drawing at
            -- the same \pos (separate events don't share the pen).
            local NB, BW, G, H = 8, 6, 2, 14 -- bars, bar width, gap, height
            local WM = NB * BW + (NB - 1) * G
            local function meter(frac, level)
                local lit = math.max(0, math.min(NB, math.floor(frac * NB + 0.5)))
                local litp, dimp = {}, {}
                for i = 1, NB do
                    local h = math.floor(H * i / NB + 0.5)
                    local bx = (i - 1) * (BW + G)
                    local r = string.format("m %d %d l %d %d %d %d %d %d",
                        bx, H - h, bx + BW, H - h, bx + BW, H, bx, H)
                    if i <= lit then litp[#litp + 1] = r else dimp[#dimp + 1] = r end
                end
                local function draw(color, path)
                    content[#content + 1] = string.format(
                        "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\p1}%s{\\p0}",
                        math.floor(cx), math.floor(y0), color, path)
                end
                if #dimp > 0 then draw("555555", table.concat(dimp, " ")) end
                if #litp > 0 then draw(tier_color(level or 1), table.concat(litp, " ")) end
                cx = cx + WM + 6 -- trailing breathing room before the value
            end

            local wrote = false
            if sg.sig then
                put("Signal ", DIM); meter(metric_frac(sg.sig, sg.sig_unit), sg.sig_level)
                put(fmt_metric(sg.sig, sg.sig_unit), TXT); wrote = true
            end
            if sg.snr then
                if wrote then sepc() end
                put("SNR ", DIM); meter(metric_frac(sg.snr, sg.snr_unit), sg.snr_level)
                put(fmt_metric(sg.snr, sg.snr_unit), TXT); wrote = true
            end
            if sg.mbps then
                if wrote then sepc() end
                put(string.format("%.1f Mbps", sg.mbps), TXT); wrote = true
            end
            if wrote then sepc() end
            put(sg.clean and "\226\156\148" or "\226\156\151", sg.clean and "78C878" or "5050E0")
            cy = cy + math.floor(fs * 1.25)
        end
        -- transponder line: delivery system, polarisation and modulation as pill
        -- badges (tech-pill style); frequency + symbol rate as plain text between.
        if cur_signal and cur_signal.mux then
            local m = cur_signal.mux
            cy = cy + 8
            local tfs, y0 = 17, cy
            local cx = x + pad
            local function txt(s)
                content[#content + 1] = text_run(cx, y0, s, tfs, "8C8C8C")
                cx = cx + text_w(s, tfs)
            end
            local function pill(s, bg, fg)
                local padx, ph = 8, tfs + 8
                local pw = math.floor(text_w(s, tfs) + 2 * padx)
                pill_badge{ bx = cx, by = y0 - 4, ty = y0, pw = pw, ph = ph, rad = 7,
                    bg = bg, fg = fg, fs = tfs, padx = padx, text = s }
                cx = cx + pw + 8
            end
            local ACC = "00D7FF" -- card accent (gold, BGR): delivery system + modulation
            pill(m.delsys or "DVB-S", ACC, "000000")
            if m.freq then cx = cx + 2; txt(string.format("%d MHz", math.floor(m.freq / 1000 + 0.5))); cx = cx + 8 end
            -- polarisation colour-coded (BGR): V = blue, H = violet — distinct from the quality colours
            if m.pol then pill(m.pol, (m.pol == "V") and "F5963C" or "F082B4", "FFFFFF") end
            if m.symrate then cx = cx + 2; txt(string.format("%.1f MSym/s", m.symrate / 1e6)); cx = cx + 8 end
            if m.mod and m.mod ~= "" then
                local mod = (m.mod:gsub("PSK/8", "8PSK"))
                if m.fec and m.fec ~= "AUTO" and m.fec ~= "NONE" then mod = mod .. " " .. m.fec end
                pill(mod, ACC, "000000")
            end
            cy = y0 + tfs + 8
        end
        if c.upcoming and #c.upcoming > 0 then
            cy = cy + 6
            line("Next", 18, "00D7FF", true)
            -- Fit each row to the card's inner width rather than a fixed char
            -- count. The OSD sans font averages ~0.5*fs px per glyph (matches
            -- the overview wrap's 74 chars @ fs22); mpv exposes no text-measure
            -- API, so this is an estimate and wrap() still ellipsizes overruns.
            local fs = 18
            local budget = math.floor(innerw / (fs * 0.5))
            local function up_line(up)
                local pfx = up.start and (os.date("%H:%M", up.start) .. "   ") or ""
                local title = wrap(up.title, math.max(8, budget - #pfx), 1)[1] or up.title
                return pfx .. title
            end
            -- The imminent programme (c.upcoming[1]) is PINNED to the top row, drawn
            -- white + bold as a fixed reference. The rest of the pool scrolls UP one
            -- row every live_upcoming_secs through the remaining live_upcoming_lines-1
            -- rows (upnext_scroll_idx, stepped in show()); static if the rest fits.
            -- It does NOT cycle-wrap: a sawtooth that HOLDS the TOP window ~live_
            -- upcoming_delay every cycle (including each restart), scrolls 1..mx (mx =
            -- rest-sw, so the final rows show cleanly), holds the END for a single step
            -- (~live_upcoming_secs, i.e. 1s), then restarts at the top hold.
            local pool = #c.upcoming
            local win = math.max(1, tonumber(opts.live_upcoming_lines) or 3)
            if cap then
                -- Keep the card within the height ceiling by shedding the least-important
                -- (bottom-most) "Next" rows. Everything above here is height-bounded, so
                -- this is the only elastic section; each row is floor(18*1.25)=22 px and the
                -- block is the last thing drawn, so no further reserve is needed.
                local rows_fit = math.floor((cap - pad - (cy - y)) / (fs > 0 and math.floor(fs * 1.25) or 22))
                win = math.max(1, math.min(win, rows_fit))
            end
            line(up_line(c.upcoming[1]), fs, "FFFFFF", true) -- pinned imminent programme
            local rest, sw = pool - 1, win - 1               -- c.upcoming[2..pool]
            if rest > 0 and sw > 0 then
                if rest <= sw then
                    for i = 2, pool do line(up_line(c.upcoming[i]), fs, "8C8C8C") end
                else
                    local mx = rest - sw -- last start; window then shows the final rows
                    local secs = math.max(0.001, tonumber(opts.live_upcoming_secs) or 1)
                    local th = math.max(1, math.floor((tonumber(opts.live_upcoming_delay) or 0) / secs + 0.5)) -- top-hold steps
                    local v = upnext_scroll_idx % (th + mx)
                    local start = (v < th) and 0 or (v - th + 1) -- hold top th steps, then scroll 1..mx (end shows 1 step)
                    for k = 0, sw - 1 do line(up_line(c.upcoming[2 + start + k]), fs, "8C8C8C") end
                end
            end
        end
    else
    -- heading: text title, OR a reserved slot the clearlogo bitmap fills in
    if c.has_logo then
        cy = y + 8 -- logo hugs the card's top edge
        local band = math.floor(opts.logo_height * RES_Y)
        if clearlogo.ready and clearlogo.w and clearlogo.h and clearlogo.h > 0 then
            local w_at = clearlogo.w / clearlogo.h * band -- fit width to the card
            if w_at > innerw then band = math.floor(innerw * clearlogo.h / clearlogo.w) end
        end
        logo_rect = { x = x + pad, y = cy, h = band }
        cy = cy + band + LOGO_GAP -- clear the logo band (autocrop makes band == artwork)
        -- movie's year is folded into the meta line below (bold); TV/unknown keep it here
        if c.kind ~= "movie" and c.year and c.year ~= "" then line(tostring(c.year), 21, "B4B4B4") end
    else
        local head = c.title or "Unknown"
        if c.kind ~= "movie" and c.year and c.year ~= "" then head = head .. "  (" .. c.year .. ")" end
        -- Big 38px title, shrunk to 28px when it wouldn't fit one line, wrapped to
        -- <=3 lines. The "unknown" card's raw file name is kept to ONE line instead
        -- (tail-ellipsised at a separator — a long dotted name reads poorly wrapped).
        heading(head, 38, 28, 3, c.kind == "unknown")
    end

    -- tagline (italic)
    if c.tagline and c.tagline ~= "" then line(c.tagline, 21, "A0A0A0", false, true) end

    -- Two compact fields, inline vs own-line: credits (director/studio) go inline
    -- (parens on the TV subline / on the movie meta line); genres get their own line
    -- after the overview. (Genres and credits are swapped from the earlier layout.)
    local function genres_str(cc)
        local g = {}
        for i = 1, math.min(3, #cc.genres) do g[i] = cc.genres[i] end
        return table.concat(g, ", ")
    end
    -- Director • Studio, single-spaced bullet. Bare director name (no "Dir." label)
    -- on both the TV subline and the movie meta line.
    local function credit_str(cc)
        local cr = {}
        if cc.director and cc.director ~= "" then cr[#cr + 1] = cc.director end
        if cc.studio and cc.studio ~= "" then cr[#cr + 1] = cc.studio end
        return table.concat(cr, " \226\128\162 ") -- single-spaced bullet: <director> • <studio>
    end

    -- meta facts (aired · runtime · cert · box office · director/studio). Built here so the
    -- MOVIE meta line can sit ABOVE the rating (below the tagline) with the year folded in;
    -- TV reuses meta_str in its genre+meta row below the rating.
    local function fmt_money(n) -- compact box-office figure, e.g. $785M / $1.2B
        n = tonumber(n)
        if not n then return nil end
        if n >= 1e9 then return string.format("$%.1fB", n / 1e9) end
        if n >= 1e6 then return string.format("$%.0fM", n / 1e6) end
        if n >= 1e3 then return string.format("$%.0fK", n / 1e3) end
        return string.format("$%d", n)
    end
    local meta = {}
    do
        local aired = c.aired or c.air_date
        if aired and aired ~= "" then meta[#meta + 1] = "Aired " .. fmt_date(aired) end
        if c.runtime and tonumber(c.runtime) then meta[#meta + 1] = string.format("%d min", c.runtime) end
        if c.mpaa and c.mpaa ~= "" then meta[#meta + 1] = c.mpaa end
        local bo = fmt_money(c.boxoffice); if bo then meta[#meta + 1] = bo end
    end
    -- meta_str = aired · runtime · cert (· box) — used by the TV genre+meta row. The MOVIE
    -- meta line below builds its own LEFT/RIGHT clusters straight from `c` (not this list).
    local meta_str = (#meta > 0) and table.concat(meta, "   \226\128\162   ") or nil

    -- MOVIE/unknown: meta line ABOVE the rating, split into TWO clusters on ONE row, joined
    -- by a condensed " • " bullet. LEFT (\an7, inner-left): bold (YYYY) + runtime + BOLD
    -- director. RIGHT (\an9, right-aligned to the inner edge): cert + GOLD-BOLD box office +
    -- studio (grey otherwise). Year is bold-folded here (dropped from the heading). Both
    -- events share \bord2\shad1\3c styling; per-field colour/weight is set with inline tags,
    -- so widths are budgeted from PLAIN text (the director — the variable field — ellipsises).
    if c.kind ~= "tv" then
        local mfs, BULL = 21, " \226\128\162 "
        local GREY, GOLD = "B4B4B4", "18C5F5"
        local function bold(s) return "{\\b1}" .. ass_escape(s) .. "{\\b0}" end
        local yr = (c.kind == "movie" and c.year and c.year ~= "") and ("(" .. c.year .. ")") or nil
        local runtime_str = (c.runtime and tonumber(c.runtime)) and string.format("%d min", c.runtime) or nil
        local dir_str = (c.director and c.director ~= "") and c.director or nil
        -- RIGHT: cert (grey) • $box (gold+bold) • studio (grey). Rendered + plain in lockstep.
        local rparts, rplain = {}, {}
        if c.mpaa and c.mpaa ~= "" then rparts[#rparts + 1] = ass_escape(c.mpaa); rplain[#rplain + 1] = c.mpaa end
        local bo = fmt_money(c.boxoffice)
        if bo then rparts[#rparts + 1] = "{\\1c&H" .. GOLD .. "&}" .. bold(bo) .. "{\\1c&H" .. GREY .. "&}"; rplain[#rplain + 1] = bo end
        if c.studio and c.studio ~= "" then rparts[#rparts + 1] = ass_escape(c.studio); rplain[#rplain + 1] = c.studio end
        local right_body = (#rparts > 0) and table.concat(rparts, ass_escape(BULL)) or nil
        local rw = (#rplain > 0) and text_w(table.concat(rplain, BULL), mfs) or 0
        -- LEFT: bold year + runtime + bold director. Fixed (year+runtime) prefix, then the
        -- director ellipsised to the room before the right cluster — in fitw space (text_w
        -- over-estimates ~1.22x, fitw = innerw*1.22 → reserve the right cluster + a 24px gap).
        local lparts, lplain = {}, {}
        if yr then lparts[#lparts + 1] = bold(yr); lplain[#lplain + 1] = yr end
        if runtime_str then lparts[#lparts + 1] = ass_escape(runtime_str); lplain[#lplain + 1] = runtime_str end
        if dir_str then
            local usedw = (#lplain > 0) and text_w(table.concat(lplain, BULL) .. BULL, mfs) or 0
            dir_str = ellipsize_px(dir_str, math.max(40, fitw - rw - 24 - usedw), mfs)
            lparts[#lparts + 1] = bold(dir_str)
        end
        local left_body = (#lparts > 0) and table.concat(lparts, ass_escape(BULL)) or nil
        if left_body or right_body then
            if left_body then
                content[#content + 1] = string.format(
                    "{\\an7\\pos(%d,%d)\\alpha&H%s&\\bord2\\shad1\\3c&H000000&\\1c&H" .. GREY .. "&\\fs%d}%s",
                    math.floor(x + pad), math.floor(cy), fa(0), mfs, left_body)
            end
            if right_body then
                content[#content + 1] = string.format(
                    "{\\an9\\pos(%d,%d)\\alpha&H%s&\\bord2\\shad1\\3c&H000000&\\1c&H" .. GREY .. "&\\fs%d}%s",
                    math.floor(x + pad + innerw), math.floor(cy), fa(0), mfs, right_body)
            end
            cy = cy + math.floor(mfs * 1.25)
        end
    end

    -- TV: SxxEyy · Episode Title (Director · Studio) — bare director, no "Dir." label
    if c.kind == "tv" and c.season and c.episode then
        local sub = string.format("S%02dE%02d", c.season, c.episode)
        if c.ep_total and c.ep_total > 0 then sub = sub .. string.format(" (/%d)", c.ep_total) end
        if c.episode_title and c.episode_title ~= "" then sub = sub .. "   " .. c.episode_title end
        local cr = credit_str(c)
        if cr ~= "" then sub = sub .. "  (" .. cr .. ")" end
        line(ellipsize_px(sub, fitw, 24), 24, "00D7FF") -- subline tier (matches live-TV)
    end

    -- rating: colour-coded stars for the headline score, plus right-aligned source
    -- pills. IMDb is the headline when present (stars + score + IMDb pill), with TMDB
    -- shown as a secondary "TMDB 7.8" value pill beside it; a single source is the
    -- headline on its own (the TMDB-only path is unchanged from before).
    local imdb_s, tmdb_s = tonumber(c.rating_imdb), tonumber(c.rating)
    local hscore, hlabel, hvotes, ascore, alabel
    if imdb_s and imdb_s > 0 then
        hscore, hlabel, hvotes = imdb_s, "IMDb", c.rating_imdb_votes
        if tmdb_s and tmdb_s > 0 then ascore, alabel = tmdb_s, (c.rating_src or "TMDB") end
    elseif tmdb_s and tmdb_s > 0 then
        hscore, hlabel = tmdb_s, c.rating_src -- "TMDB", or nil for a bare .nfo rating (no pill)
    end
    if hscore then
        local stars, scolor = star_rating(hscore)
        local ry = cy
        local rtxt = string.format("%s  %.1f", stars, hscore)
        if opts.imdb_votes and hlabel == "IMDb" and hvotes then
            rtxt = rtxt .. "  (" .. (fmt_votes(hvotes) or "") .. ")"
        end
        -- source pills. Colours are BGR: TMDB brand blue (E4B401 = #01B4E4), IMDb gold
        -- (18C5F5 = #F5C518). The headline pill LEADS the row (before the rating +
        -- votes, so it labels the score); a secondary source pill (present only when
        -- both TMDB and IMDb are shown) is right-aligned to the card's inner edge.
        local pfs, ppadx = 15, 9
        local function pill_text(label, score) return score and string.format("%s %.1f", label, score) or label end
        local function pill_w(label, score) return math.floor(text_w(pill_text(label, score), pfs) + 2 * ppadx) end
        local function draw_pill(label, score, px)
            local bg, fg = "E4B401", "FFFFFF"
            if label == "IMDb" then bg, fg = "18C5F5", "000000" end
            pill_badge{ bx = px, by = ry + 2, ty = ry + 6, pw = pill_w(label, score), ph = 24, rad = 8,
                bg = bg, fg = fg, fs = pfs, padx = ppadx, text = pill_text(label, score) }
        end
        local tx = x + pad
        if hlabel and hlabel ~= "" then
            draw_pill(hlabel, nil, tx)          -- headline pill leads the row
            tx = tx + pill_w(hlabel, nil) + 12  -- the rating + votes text follows the pill
        end
        content[#content + 1] = text_run(tx, cy, rtxt, 23, scolor, { alpha = fa(0), bold = true })
        -- Secondary ratings clustered at the right edge in order TMDB -> RT -> MC:
        -- the blue TMDB value pill, then the best-effort OMDb critic pills (Rotten
        -- Tomatoes red, Metacritic green — fixed brand colours; the stars carry the
        -- score tier). Right-aligned as ONE group so the cluster ends at the card edge.
        local rtp, mcp = tonumber(c.rt), tonumber(c.mc)
        local right = {}
        if ascore then right[#right + 1] = { text = pill_text(alabel, ascore), bg = "E4B401", fg = "FFFFFF" } end
        if rtp then right[#right + 1] = { text = string.format("RT %d%%", math.floor(rtp + 0.5)), bg = "0A32FA", fg = "FFFFFF" } end
        if mcp then right[#right + 1] = { text = string.format("MC %d", math.floor(mcp + 0.5)), bg = "33CC66", fg = "000000" } end
        if #right > 0 then
            local gap, total, widths = 8, 0, {}
            for i, p in ipairs(right) do
                widths[i] = math.floor(text_w(p.text, pfs) + 2 * ppadx)
                total = total + widths[i] + (i > 1 and gap or 0)
            end
            local px = x + pad + innerw - total -- right-align the whole cluster
            for i, p in ipairs(right) do
                pill_badge{ bx = px, by = ry + 2, ty = ry + 6, pw = widths[i], ph = 24, rad = 8,
                    bg = p.bg, fg = p.fg, fs = pfs, padx = ppadx, text = p.text }
                px = px + widths[i] + gap
            end
        end
        cy = cy + math.floor(23 * 1.25)
    end

    -- genres (bold grey) + the OMDb award highlight (gold ★, leading clause; rare on TV).
    local gfs = 21
    local gstr = (c.genres and #c.genres > 0) and genres_str(c) or nil
    local astr = (c.awards and c.awards ~= "")
        and ("\226\152\133 " .. (c.awards:match("^[^.]+") or c.awards)) or nil

    local right_x = x + pad + innerw -- card inner right edge (right-align anchor for \an9)
    if c.kind == "tv" then
        -- TV: fold the meta line and the genre row into ONE dense row — genres LEFT (bold),
        -- the meta facts (aired/runtime/mpaa/…) RIGHT-aligned (grey) via \an9 (libass aligns
        -- exactly to the edge — no text_w gap), award (rare) a gold ★ at the far right.
        local aw = astr and text_w(astr, gfs) or 0 -- estimate: only spaces the meta left of an award
        if gstr then
            cy = cy + 4
            if astr then content[#content + 1] = text_run(right_x, cy, astr, gfs, "18C5F5", { alpha = fa(0), an = 9 }) end
            if meta_str then content[#content + 1] = text_run(right_x - (astr and (aw + 16) or 0), cy, meta_str, gfs, "B4B4B4", { alpha = fa(0), an = 9 }) end
            -- genres fill the left; ellipsise conservatively (text_w over-estimates → safe gap)
            local budget = innerw - (meta_str and text_w(meta_str, gfs) or 0) - (astr and (aw + 16) or 0) - 16
            content[#content + 1] = text_run(x + pad, cy, ellipsize_px(gstr, math.max(40, budget), gfs), gfs, "DCDCDC", { alpha = fa(0), bold = true })
            cy = cy + math.floor(gfs * 1.25)
        elseif meta_str or astr then -- no genres → meta stays LEFT (award right if present)
            cy = cy + 4
            if astr then content[#content + 1] = text_run(right_x, cy, astr, gfs, "18C5F5", { alpha = fa(0), an = 9 }) end
            if meta_str then content[#content + 1] = text_run(x + pad, cy, ellipsize_px(meta_str, astr and math.max(40, innerw - aw - 16) or fitw, gfs), gfs, "B4B4B4", { alpha = fa(0) }) end
            cy = cy + math.floor(gfs * 1.25)
        end
    else
        -- movie/unknown: just the genre (left) + award (right, gold ★) row — the meta line is
        -- drawn ABOVE the rating (with the year), so it's not repeated here. Award right-aligns
        -- via \an9; a lone award stays left.
        if gstr and astr then
            cy = cy + 4
            content[#content + 1] = text_run(right_x, cy, astr, gfs, "18C5F5", { alpha = fa(0), an = 9 }) -- award right
            content[#content + 1] = text_run(x + pad, cy,
                ellipsize_px(gstr, math.max(40, innerw - text_w(astr, gfs) - 16), gfs), gfs, "DCDCDC", { alpha = fa(0), bold = true })
            cy = cy + math.floor(gfs * 1.25)
        elseif gstr then
            cy = cy + 4
            content[#content + 1] = text_run(x + pad, cy, ellipsize_px(gstr, fitw, gfs), gfs, "DCDCDC", { alpha = fa(0), bold = true })
            cy = cy + math.floor(gfs * 1.25)
        elseif astr then
            cy = cy + 4
            content[#content + 1] = text_run(x + pad, cy, ellipsize_px(astr, fitw, gfs), gfs, "18C5F5", { alpha = fa(0) }) -- lone award: left
            cy = cy + math.floor(gfs * 1.25)
        end
    end

    -- overview / synopsis. Default: wrapped to overview_lines, static. With
    -- overview_scroll: a fixed overview_lines window over the FULL wrapped text,
    -- advanced one line every overview_scroll_secs (see show()), wrapping.
    -- Wrap by PIXELS to innerw (like the cast line) so lines fill the full card
    -- width to the right edge, not a rough 74-char guess.
    if c.overview and c.overview ~= "" then
        cy = cy + 6
        local olines = math.max(1, tonumber(opts.overview_lines) or 3)
        if cap then
            -- Trim the synopsis window to keep the card within the height ceiling. cy here
            -- already covers everything ABOVE (title/logo, tagline, subline, rating, meta,
            -- awards, genres); subtract a reserve for the sections drawn AFTER the overview
            -- so they aren't pushed below the box (cast, tech pills, tech line, progress).
            -- Reserve the progress row whenever show_tech even though it draws only mid-
            -- playback (percent-pos>0) — else it appearing a few seconds in would reflow
            -- the synopsis line count. The reserve is an UPPER bound: over-reserving only
            -- costs a synopsis line, under-reserving would overflow the footer.
            local reserve = 0
            if c.cast and #c.cast > 0 and not casthead_active then
                local clh = math.floor((tonumber(opts.cast_fs) or 21) * 1.25)
                local cdir = tostring(opts.cast_scroll_dir or "horizontal"):lower()
                if opts.cast_scroll and cdir ~= "vertical" then
                    reserve = reserve + 4 + clh                                      -- horizontal 1-line ticker
                elseif opts.cast_scroll then
                    reserve = reserve + 4 + clh * math.max(1, tonumber(opts.cast_lines) or 2) -- vertical grid
                else
                    reserve = reserve + 4 + clh * 2                                  -- packed <=2 rows
                end
            end
            if opts.show_tech then reserve = reserve + 34 + 28 + 33 end              -- tech pills + tech line + progress row
            local budget = cap - pad - (cy - y) - reserve
            olines = math.max(1, math.min(olines, math.floor(budget / 26)))         -- render_overview line = floor(21*1.25)=26
        end
        render_overview(c.overview, olines, opts.overview_scroll)
    end

    -- cast (amber, bold). Each entry is "Name (Role)" (role optional); entries may
    -- be {name, role} tables (TMDB / .nfo <role>) or bare name strings (older caches).
    -- Three layouts: cast_scroll on + cast_scroll_dir="horizontal" (default) → a
    -- single line gliding left; ="vertical" → a fixed cast_lines×cast_cols grid
    -- scrolled a row at a time; cast_scroll off → comma-packed onto ≤2 rows. The
    -- scrolling layouts read cast_scroll_idx (stepped on a timer in show()).
    if c.cast and #c.cast > 0 and not casthead_active then
        local fs = tonumber(opts.cast_fs) or 21
        local cbold = opts.cast_bold ~= false
        local nmax = math.max(1, tonumber(opts.cast_max) or 5)
        local entries = {}
        for i = 1, math.min(nmax, #c.cast) do
            local e = c.cast[i]
            local nm = (type(e) == "table") and e.name or e
            local role = (type(e) == "table") and e.role or nil
            if nm and nm ~= "" then
                local s = (role and role ~= "") and (nm .. " (" .. role .. ")") or nm
                entries[#entries + 1] = ellipsize_px(s, fitw, fs)
            end
        end
        local cdir = tostring(opts.cast_scroll_dir or "horizontal"):lower()
        if opts.cast_scroll and #entries > 0 and cdir ~= "vertical" then
            -- horizontal glide ticker (default): a comma-separated "Name (Role)"
            -- list clipped to ONE line and scrolled left cast_scroll_px per tick
            -- (cast_scroll_idx, stepped in show()). Seamless loop: two copies split
            -- by a gap, offset wrapped by the period width (fits => drawn static).
            cy = cy + 4
            local full = table.concat(entries, ", ")
            if text_w(full, fs) <= fitw then
                line(full, fs, "00D7FF", cbold) -- fits: static, no scroll (advances cy)
            else
                local lineh = math.floor(fs * 1.25)
                local px = math.max(1, tonumber(opts.cast_scroll_px) or 3)
                local gap = "     \226\128\162     " -- "   •   " spacer between copies
                local period = text_w(full .. gap, fs)
                local text = full .. gap .. full   -- 2nd copy keeps the window filled
                local off = (cast_scroll_idx * px) % period
                content[#content + 1] = string.format(
                    "{\\an7\\q2\\pos(%d,%d)\\clip(%d,%d,%d,%d)\\alpha&H%s&\\bord2\\shad1"
                        .. "\\3c&H000000&\\1c&H00D7FF&\\fs%d%s}%s",
                    math.floor(x + pad - off), math.floor(cy),
                    math.floor(x + pad), math.floor(cy),
                    math.floor(x + pad + innerw), math.floor(cy + lineh),
                    fa(0), fs, cbold and "\\b1" or "", ass_escape(text))
                cy = cy + lineh
            end
        elseif opts.cast_scroll and #entries > 0 then
            -- vertical style: fixed cast_lines × cast_cols grid, scrolled a row at a time
            cy = cy + 4
            local nlines = math.max(1, tonumber(opts.cast_lines) or 2)
            local ncols = math.max(1, tonumber(opts.cast_cols) or 2)
            local per, pool, gut = nlines * ncols, #entries, 16
            local colw = math.floor(innerw / ncols)
            local scroll = pool > per
            -- advance a whole row (ncols) per step so the grid reads as scrolling up
            local start = scroll and ((cast_scroll_idx * ncols) % pool) or 0
            -- draw one cell at column dx, current cy, without advancing cy
            local function cell(str, dx)
                str = ellipsize_px(str, colw - gut, fs)
                content[#content + 1] = text_run(x + pad + dx, cy, str, fs, "00D7FF", { alpha = fa(0), bold = cbold })
            end
            for r = 0, nlines - 1 do
                local drew = false
                for cix = 0, ncols - 1 do
                    local seq = r * ncols + cix
                    local e
                    if scroll then e = entries[(start + seq) % pool + 1]
                    elseif (seq + 1) <= pool then e = entries[seq + 1] end
                    if e then cell(e, cix * colw); drew = true end
                end
                if drew then cy = cy + math.floor(fs * 1.25) end
            end
        elseif #entries > 0 then
            cy = cy + 4
            local rows, cur = {}, ""
            for _, s in ipairs(entries) do
                local piece = (cur == "") and s or (cur .. ", " .. s)
                if cur ~= "" and text_w(piece, fs) > fitw then
                    rows[#rows + 1] = cur .. ","
                    cur = s
                    if #rows >= 2 then break end
                else
                    cur = piece
                end
            end
            if cur ~= "" and #rows < 2 then rows[#rows + 1] = cur end
            -- the last row must not end on a separator (a 5th entry that didn't
            -- fit leaves the 2nd row with a trailing comma) — strip it.
            if #rows > 0 then rows[#rows] = (rows[#rows]:gsub(",%s*$", "")) end
            for _, r in ipairs(rows) do line(r, fs, "00D7FF", cbold) end
        end
    end

    -- local file details — read live from mpv properties at render time
    if opts.show_tech then
        local tt = deps.tech()

        -- pill badges: resolution · HDR · video codec · audio codec · channels ·
        -- fps — each tier-coloured (gold/green/grey/dim) by pill_colors().
        local pills = {}
        local function add(kind, text)
            if not text then return end
            local bg, fg = pill_colors(kind, text)
            pills[#pills + 1] = { t = text, bg = bg, fg = fg }
        end
        add("res", res_label(tt.vwidth))
        add("hdr", tt.hdr)
        add("vcodec", tt.vcodec)
        add("acodec", tt.acodec)
        add("chan", tt.achan)
        add("fps", tt.fps and (tt.fps .. "FPS") or nil) -- e.g. "24FPS" / "23.976FPS" / "50FPS"
        if #pills > 0 then
            cy = cy + 8
            local ph, pfs, ppadx, pgap = 26, 16, 10, 8
            local px = x + pad
            for _, p in ipairs(pills) do
                local pw = math.floor(text_w(p.t, pfs) + 2 * ppadx) -- text_w, like the other pills
                pill_badge{ bx = px, by = cy, ty = cy + 5, pw = pw, ph = ph, rad = 8,
                    bg = p.bg, fg = p.fg, fs = pfs, padx = ppadx, text = p.t }
                px = px + pw + pgap
            end
            cy = cy + ph
        end

        -- bottom line: audio · subs · chapters · size (one line). Duration is
        -- omitted here — it's already the /total in the progress-bar caption. The
        -- long subs list is trimmed so chapters/size always survive at the end.
        local fs, SEP = 18, "  \226\128\162  "
        local head, tail = {}, {}
        if tt.audio then head[#head + 1] = "Audio: " .. tt.audio end
        if tt.chapters and tt.chapters > 0 then tail[#tail + 1] = string.format("%d chapters", tt.chapters) end
        if tt.size then tail[#tail + 1] = tt.size end
        local subs = tt.subs and ("Subs: " .. tt.subs) or nil
        local function join(sv)
            local p = {}
            for _, v in ipairs(head) do p[#p + 1] = v end
            if sv then p[#p + 1] = sv end
            for _, v in ipairs(tail) do p[#p + 1] = v end
            return table.concat(p, SEP)
        end
        local full = join(subs)
        if subs and text_w(full, fs) > fitw then
            local room = fitw - text_w(join(nil) .. SEP, fs)
            subs = ellipsize_px(subs, math.max(80, room), fs)
            full = join(subs)
        end
        if full ~= "" then cy = cy + 6; line(full, fs, "8C8C8C") end

        -- progress bar + caption on ONE line: bar left, "cur / total  [ends HH:MM]"
        -- caption to its right (drawn by the shared progress_row helper).
        local pct = mp.get_property_number("percent-pos")
        if pct and pct > 0.5 and pct < 99.5 then
            local rem, tp = mp.get_property_number("time-remaining"), mp.get_property_number("time-pos")
            local info = string.format("%d%%", math.floor(pct + 0.5))
            if tp and rem then
                info = fmt_duration(tp) .. " / " .. fmt_duration(tp + rem)
                    .. "   [" .. os.date("%H:%M", os.time() + math.floor(rem)) .. "]"
            end
            progress_row(pct, info)
        end
    end

    end -- close the livetv / movie-tv content branch

    local bh = (cy - y) + pad
    card_rect = { x = x, y = y, w = bw, h = bh }
    local out = {}
    -- drop shadow: the box shape offset down-right, drawn ONLY outside the box — a
    -- bottom+right lip, not a soft halo bleeding through the translucent fill on all
    -- four sides (which is what \shad did). The exclusion is a VECTOR \iclip of the
    -- card's ROUNDED shape (not its bounding rect): a rectangular iclip would also
    -- blank the shadow inside the box's rounded-corner triangles, which the card
    -- itself doesn't cover — so at the bottom-right (both offsets stack) a sliver of
    -- video showed through. Clipping to the exact rounded shape fills that gap.
    -- iclip coords are ABSOLUTE (not moved by \pos), so make_shadow rebuilds the
    -- whole event for a given top — the bottom-anchor shift below re-emits it rather
    -- than gsub-shifting (the numeric gsub can't move a vector-clip drawing).
    local sh = 6 -- shadow offset (px, down-right)
    -- Inset the exclusion `si` px INSIDE the card silhouette so the shadow tucks a
    -- hair under the card's edge. The fill and an inverse clip on the SAME path both
    -- anti-alias the shared boundary pixel, leaving it only partly covered — and the
    -- translucent fill then lets the video blaze through as a ~1px hairline all along
    -- the lip. Overlapping inward by `si` hides that seam behind the (near-opaque)
    -- card edge; the sliver of shadow now under the translucent fill is imperceptible.
    local si = 1 -- shadow-under-card inset (px)
    local function make_shadow(top)
        return string.format(
            "{\\an7\\pos(%d,%d)\\iclip(%s)\\bord0\\shad0\\1c&H000000&\\1a&H%s&\\p1}%s{\\p0}",
            x + sh, top + sh, rrect(bw - 2 * si, bh - 2 * si, 16 - si, x + si, top + si),
            fa(96), rrect(bw, bh, 16))
    end
    out[#out + 1] = make_shadow(y) -- out[1]: the shadow (regenerated on shift below)
    -- rounded card box (translucent) on top
    out[#out + 1] = fill_rrect(x, y, bw, bh, 16, "141414", fa(51))
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
            -- The shadow (out[1]) carries a VECTOR \iclip the numeric gsub below can't
            -- shift, so re-emit it at the shifted top instead of scanning it.
            out[1] = make_shadow(new_top)
            -- ONE gsub pass per remaining event shifts every y: \pos(x,y), and
            -- \clip/\iclip (x1,y1,x2,y2) — the only \tag(numbers) tokens in an event —
            -- so the clip rects track their \pos'd text (cast marquee). (Was three
            -- separate full-string scans per event.)
            for i = 2, #out do
                out[i] = out[i]:gsub("\\(%a+)%(([%-%d,]+)%)", function(tag, nums)
                    if tag == "pos" then
                        local px, py = nums:match("^(%-?%d+),(%-?%d+)$")
                        if py then return string.format("\\pos(%s,%d)", px, tonumber(py) + shift) end
                    elseif tag == "clip" or tag == "iclip" then
                        local x1, y1, x2, y2 = nums:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
                        if y2 then return string.format("\\%s(%s,%d,%s,%d)",
                            tag, x1, tonumber(y1) + shift, x2, tonumber(y2) + shift) end
                    end
                    -- any other \tag(nums) / unexpected arity: leave unchanged
                end)
            end
            if logo_rect then logo_rect.y = logo_rect.y + shift end
        end
    end
    return table.concat(out, "\n"), logo_rect, card_rect
end

return M
