-- spincard — identify the playing file from its full path and show a
-- metadata card. Identity comes from identify.lua; enrichment from TMDB (via a
-- curl subprocess, per Docs/MpvLuaMetadataApiProvider.md), cached on disk.
--
-- Degrades gracefully: with no API key or no network it shows a card built from
-- the parsed filename + mpv's own local properties.
--
-- Target: mpv on i7 (Linux). Config in ~/.mpv (see README).

local mp      = require "mp"
local msg     = require "mp.msg"
local utils   = require "mp.utils"
local options = require "mp.options"

-- Load the sibling identify module from this script's directory.
local sd = mp.get_script_directory()
if sd then package.path = sd .. "/?.lua;" .. package.path end
local identify = require("identify").identify
-- Functional modules split out of this file (Phase 1+2 of the split):
--   util      — pure helpers, text metrics, pill colours, curl_json
--   cache     — disk cache, rating TTL cache, .nfo supplement policy
--   sidecar   — local .nfo/artwork discovery (requires nfo)
--   tmdb      — TMDB search + details/credits fetchers
--   tvheadend — live-TV EPG + tuner-signal fetchers
local util      = require("util")
local cache     = require("cache")
local sidecar   = require("sidecar")
local tmdb      = require("tmdb")
local omdb      = require("omdb")
local tvheadend = require("tvheadend")
local images    = require("images")
local layout    = require("layout")
local tech      = require("tech")
local card      = require("card")

-- Options (override in ~/.mpv/script-opts/spincard.conf) -------------
local opts = {
    auto_show = true,      -- show the card automatically when a file loads
    show_on_pause = false, -- pop the card while paused, hide on resume (opt-in)
    duration  = 7,         -- auto-show-on-open timeout (0 = stay until toggled)
    toggle_timeout = 17,   -- toggle-key auto-close timeout (0 = stay until toggled)
    key       = "",        -- default toggle key ("" = bind via input.conf)
    pos_x     = 40,
    pos_y     = 40,     -- margin from the top OR bottom edge (see anchor)
    anchor    = "bottom", -- "bottom" (hug bottom, grow up) or "top"
    enrich    = true,      -- look up online metadata (needs api_key)
    api_key   = "",        -- TMDB API key; empty => filename-only card
    language  = "en-US",   -- TMDB response language
    rating_ttl = 3600,     -- refresh rating from TMDB when the cached value is older than this (s); 0 = off
    omdb_api_key = "",     -- OMDb API key for the IMDb rating; empty => IMDb source off (shown alongside TMDB when both keys set)
    imdb_votes = true,     -- show the IMDb vote count next to the rating (e.g. 8.1 (1.2M))
    tvheadend_url = "",    -- e.g. http://127.0.0.1:9981 — live-TV EPG source ("" = off)
    live_upcoming = 7,     -- live TV: how many upcoming programmes to keep for "Up next" (0 = none)
    live_upcoming_lines = 3, -- live TV: "Up next" visible window (rows); scrolls through the pool if more
    live_upcoming_secs = 1.5, -- live TV: seconds per 1-line "Up next" scroll step (0 = don't scroll); top hold stays ~live_upcoming_delay
    live_upcoming_delay = 3, -- live TV: hold the first "Up next" window this many seconds before scrolling
    live_signal   = true,  -- live TV: show tuner signal strength / SNR meter (needs tvheadend_url)
    live_signal_interval = 3, -- live TV: seconds between signal polls while the card is visible (0 = read once on show)
    signal_dbm_max = -40.6, -- live TV: dBm that fills the signal meter (tuner's max; meter spans 50 dB below it)
    show_poster   = true,  -- render the local poster image (needs ffmpeg)
    poster_height = 0.42,  -- poster height as a fraction of the video height
    poster_max_width = 0.30, -- cap poster width as a fraction of OSD width — reins in wide 16:9 TV episode thumbs so they clear the card (0 = no cap)
    poster_margin = 0.02,  -- gap from the top-right corner (fraction of height; 0 = flush)
    show_tech     = true,  -- local file details (codec/HDR/audio/subs/chapters/…)
    show_fanart    = true, -- dimmed fanart.jpg backdrop (needs ffmpeg)
    fanart_opacity = 0.25, -- static backdrop opacity 0..1 (higher = more visible/darker)
    fanart_pause_only = true, -- only show the fanart while playback is PAUSED (and the card is up); hide on unpause
    show_banner    = true, -- wide banner.jpg top-left (opaque JPEG, no alpha)
    banner_height  = 0.10,  -- banner height as a fraction of the video height
    show_logo      = true,  -- clearlogo.png title art, top-left (transparent PNG)
    logo_height    = 0.12,  -- logo height as a fraction of the video height
    logo_autocrop  = true,  -- crop the clearlogo's transparent margins so its slot maps to real artwork
    show_disc      = true,  -- 3/4 disc.png nestled at the card's top-left corner
    disc_size      = 0.22,  -- disc diameter as a fraction of the video height
    disc_spin      = true,  -- spin the disc while the card is showing
    disc_spin_secs = 5,     -- seconds per full rotation (higher = slower; 5 just reads nicer)
    disc_spin_frames = 96,  -- rotation frames (more = smoother; larger temp file)
    cast_max      = 5,      -- max cast entries shown/cycled (also the scroll pool size)
    cast_scroll   = true,   -- scroll the cast (else pack ≤2 rows); style set by cast_scroll_dir
    cast_scroll_dir = "horizontal", -- "horizontal" (1-line glide ticker) | "vertical" (2×2 grid)
    cast_scroll_px = 3,     -- horizontal glide: px advanced per tick (speed)
    cast_scroll_interval = 0.1, -- horizontal glide: seconds per tick (smoothness)
    cast_scroll_secs = 2.5, -- vertical grid: seconds between row steps (0 = don't advance)
    cast_lines    = 2,      -- cast grid rows (vertical style)
    cast_cols     = 2,      -- cast entries per row, vertical style (2nd col starts at card middle)
    cast_fs       = 22,     -- cast font size
    cast_bold     = true,   -- cast in bold
    overview_scroll = false,-- scroll the synopsis through a fixed overview_lines window
    overview_scroll_secs = 1,-- seconds between synopsis scroll steps (0 = don't advance)
    overview_scroll_delay = 3,-- seconds to hold the first synopsis window before scrolling (read the opening line)
    overview_lines = 3,     -- synopsis viewport height (lines)
    nfo_supplement = true,  -- fill a local .nfo's MISSING fields (cast/genres/…) from TMDB (needs api_key)
    region        = "",     -- certification region (e.g. GB, US); "" => derive from `language`
}
options.read_options(opts, "spincard")

-- Wire the split-out modules to the runtime options, then bind the functions this
-- file still calls to plain locals so every existing call site stays unchanged.
cache.init(opts); tmdb.init(opts); omdb.init(opts); tvheadend.init(opts)
-- (util's display/text helpers are used by card.lua/tech.lua directly now, not here)
local cache_get, cache_put = cache.cache_get, cache.cache_put
local rating_get, rating_put, rating_stale = cache.rating_get, cache.rating_put, cache.rating_stale
local imdb_rating_get, imdb_rating_put = cache.imdb_rating_get, cache.imdb_rating_put
local nfo_missing, fill_missing, pick_supplement =
    cache.nfo_missing, cache.fill_missing, cache.pick_supplement
local file_exists, read_local, find_poster, count_season_episodes, dir_has_image =
    sidecar.file_exists, sidecar.read_local, sidecar.find_poster,
    sidecar.count_season_episodes, sidecar.dir_has_image
local tmdb_fetch, tmdb_details = tmdb.tmdb_fetch, tmdb.tmdb_details
local omdb_fetch_rating = omdb.fetch_rating
local tvh_fetch, tvh_signal = tvheadend.tvh_fetch, tvheadend.tvh_signal

local RES_X, RES_Y = layout.RES_X, layout.RES_Y
local CARD_VER = 2 -- disk-card schema; a cached card below this is refetched once
                   -- so pre-v2 caches (no cast/genres/…) auto-upgrade on next play

local overlay = mp.create_osd_overlay("ass-events")
overlay.res_x = RES_X
overlay.res_y = RES_Y

local visible, hide_timer, cur_card = false, nil, nil
local content_ok = false -- true only while a real video (not image/audio) plays
local live_ctx = nil     -- { path, chan } while a Tvheadend live stream plays
local cur_signal = nil   -- latest live-TV tuner reading (or nil); read directly by build_card
local signal_timer = nil -- periodic signal poll while the live card is visible
local signal_inflight = false -- guards overlapping polls (two chained curls per poll)
local logo_rect = nil    -- clearlogo slot in 1280x720 coords, set by build_card
local card_rect = nil    -- card box rect in 1280x720 coords, set by build_card
local anim_fade, refresh_timer = 1, nil -- anim_fade stays 1 (fades disabled)
local cast_scroll_idx, cast_scroll_timer = 0, nil -- cast marquee window offset + timer
local overview_scroll_idx, overview_scroll_timer = 0, nil -- synopsis marquee offset + timer
local upnext_scroll_idx, upnext_scroll_timer = 0, nil -- live-TV "Up next" marquee offset + timer
local current_gen = 0
local render, show, hide, toggle   -- forward declarations
local gather_tech = tech.gather_tech -- reads live mpv props → tech table (tech.lua)
local cur_tech = nil -- memoised gather_tech() for the current file (static mid-playback); reset on file-loaded

-- build_card lives in card.lua; it reads this file's mutable card state via getter
-- closures and returns (assdata, logo_rect, card_rect) which render() assigns back.
card.init(opts, {
    anim_fade    = function() return anim_fade end,
    cur_signal   = function() return cur_signal end,
    cast_idx     = function() return cast_scroll_idx end,
    overview_idx = function() return overview_scroll_idx end,
    upnext_idx   = function() return upnext_scroll_idx end,
    tech         = function() if cur_tech == nil then cur_tech = gather_tech() end return cur_tech end,
})

-- Image pipeline (poster/fanart/banner/clearlogo/disc) lives in images.lua. It
-- needs the card rects (computed by build_card) + visibility as getter closures —
-- declared here so they close over the module-state locals above — and file_exists
-- via sidecar. Tables are rebound so on_file_loaded can poke .ready/.src/.file, and
-- the functions are rebound so every existing call site reads unchanged.
images.init(opts, {
    logo_rect = function() return logo_rect end,
    card_rect = function() return card_rect end,
    visible   = function() return visible end,
})
local poster, fanart, banner, clearlogo, disc =
    images.poster, images.fanart, images.banner, images.clearlogo, images.disc
local LOGO_GAP = images.LOGO_GAP
local poster_decode, poster_hide, poster_show =
    images.poster_decode, images.poster_hide, images.poster_show
local find_fanart, fanart_decode, fanart_hide, fanart_show =
    images.find_fanart, images.fanart_decode, images.fanart_hide, images.fanart_show
local find_banner, banner_decode, banner_hide, banner_show =
    images.find_banner, images.banner_decode, images.banner_hide, images.banner_show
local find_clearlogo, find_disc, clearlogo_decode =
    images.find_clearlogo, images.find_disc, images.clearlogo_decode
local disc_decode, disc_show, disc_spin_start, disc_spin_stop =
    images.disc_decode, images.disc_show, images.disc_spin_start, images.disc_spin_stop
local img_remove, place_logo = images.img_remove, images.place_logo

-- Fanart is (by default) a PAUSED-only backdrop: shown only while the card is up
-- AND playback is paused, and hidden the moment it resumes. This gates every
-- fanart_show() call site; a `pause` observer (below) toggles it live. Set
-- fanart_pause_only=no to restore "show whenever the card shows".
local function fanart_paused_ok()
    return (not opts.fanart_pause_only) or mp.get_property_bool("pause")
end




-- Re-read the current programme from the EPG for the live channel. Called each
-- time the card is shown, so it stays current across programme boundaries (the
-- EPG is otherwise only fetched on channel change).
local function live_refresh()
    if not live_ctx then return end
    local ctx, gen = live_ctx, current_gen
    tvh_fetch(ctx.path, ctx.chan, function(card)
        if card and gen == current_gen and live_ctx == ctx then
            cur_card = card
            if visible then render() end
        end
    end)
end

-- Poll the tuner signal for the live channel and update cur_signal (kept apart
-- from cur_card so the EPG refresh's wholesale `cur_card = card` can't wipe it).
-- Guarded like live_refresh, plus an in-flight flag so a slow poll (two chained
-- curls) can't stack under the periodic timer / short interval.
local function live_signal_refresh()
    if not (live_ctx and opts.live_signal) then return end
    if signal_inflight then return end
    signal_inflight = true
    local ctx, gen = live_ctx, current_gen
    tvh_signal(ctx.chan, function(rd)
        signal_inflight = false -- cb always fires exactly once (all paths), so this clears every time
        if gen ~= current_gen or live_ctx ~= ctx or not opts.live_signal then return end
        cur_signal = rd
        if visible then render() end
    end)
end

-- Render --------------------------------------------------------------------



-- render(light): rebuild + push the ASS overlay. `light` (the marquee ticks) skips
-- the logo/disc overlay-add re-issues — their geometry doesn't change between full
-- renders, so re-adding those bitmaps every 0.1s is wasted overlay churn (the disc's
-- own spin timer animates it independently; a full render() at 1Hz re-asserts both).
render = function(light)
    if not cur_card then return end
    local data, lr, cr = card.build_card(cur_card)
    overlay.data = data
    logo_rect, card_rect = lr, cr -- images' place_logo/disc_show read these via getters
    overlay.hidden = false
    overlay:update()
    if not light then
        place_logo()
        disc_show()
    end
end

hide = function()
    if hide_timer then hide_timer:kill(); hide_timer = nil end
    if refresh_timer then refresh_timer:kill(); refresh_timer = nil end
    if cast_scroll_timer then cast_scroll_timer:kill(); cast_scroll_timer = nil end
    if overview_scroll_timer then overview_scroll_timer:kill(); overview_scroll_timer = nil end
    if upnext_scroll_timer then upnext_scroll_timer:kill(); upnext_scroll_timer = nil end
    if signal_timer then signal_timer:kill(); signal_timer = nil end
    overlay:remove()
    fanart_hide()
    poster_hide()
    banner_hide()
    img_remove(clearlogo)
    disc_spin_stop()
    img_remove(disc)
    visible = false
    msg.verbose("hide")
end

-- show(timeout): auto-hide after `timeout`s (nil/0 = stay until toggled).
show = function(timeout)
    if not content_ok then return end
    visible = true
    if live_ctx then live_refresh() end -- re-read the EPG each time the card appears
    render()
    if fanart_paused_ok() then fanart_show() end -- paused-only gate (see fanart_pause_only)
    -- Defer the image overlay-add draws off the toggle key handler: on card open
    -- this burst runs on mpv's playback thread and can stall audio for a moment.
    -- Guard on `visible` — a quick open→close (hide() clears these overlays) could
    -- otherwise let this deferred pass re-add an orphan onto an already-hidden card.
    mp.add_timeout(0, function()
        if not visible then return end
        poster_show()
        banner_show()
        disc_spin_start()
    end)

    -- live tuner signal: kill-before-create (show() is re-entered without hide()
    -- on channel change / live→file), an immediate reading, then poll on its own
    -- cadence. Recreated only for a live card with the feature on.
    if signal_timer then signal_timer:kill(); signal_timer = nil end
    if live_ctx and opts.live_signal then
        live_signal_refresh()
        local iv = tonumber(opts.live_signal_interval) or 0
        if iv > 0 then
            signal_timer = mp.add_periodic_timer(iv, function()
                if visible then live_signal_refresh() end
            end)
        end
    end

    -- live-refresh the progress bar / ETA while the card is visible
    if refresh_timer then refresh_timer:kill() end
    refresh_timer = mp.add_periodic_timer(1, function() if visible then render() end end)

    -- cast marquee: advance the idx on its own cadence (build_card reads the idx).
    -- Horizontal glide steps fast (cast_scroll_interval); vertical grid steps a row
    -- every cast_scroll_secs. Timer-driven (not ASS \move) so it animates while paused.
    if cast_scroll_timer then cast_scroll_timer:kill(); cast_scroll_timer = nil end
    cast_scroll_idx = 0
    if opts.cast_scroll then
        local cs = (tostring(opts.cast_scroll_dir or "horizontal"):lower() == "vertical")
            and (tonumber(opts.cast_scroll_secs) or 0)
            or (tonumber(opts.cast_scroll_interval) or 0)
        if cs > 0 then
            cast_scroll_timer = mp.add_periodic_timer(cs, function()
                if visible then cast_scroll_idx = cast_scroll_idx + 1; render(true) end
            end)
        end
    end

    -- synopsis marquee: hold the first window for overview_scroll_delay (so the
    -- opening line is readable) before advancing one wrapped line every
    -- overview_scroll_secs. The initial one-shot timeout hands off to the periodic
    -- timer (reusing overview_scroll_timer so hide() kills whichever is live).
    if overview_scroll_timer then overview_scroll_timer:kill(); overview_scroll_timer = nil end
    overview_scroll_idx = 0
    if opts.overview_scroll then
        local ov = tonumber(opts.overview_scroll_secs) or 0
        if ov > 0 then
            local delay = math.max(0, tonumber(opts.overview_scroll_delay) or 0)
            local function step()
                if visible then overview_scroll_idx = overview_scroll_idx + 1; render(true) end
            end
            if delay > 0 then
                overview_scroll_timer = mp.add_timeout(delay, function()
                    step()
                    overview_scroll_timer = mp.add_periodic_timer(ov, step)
                end)
            else
                overview_scroll_timer = mp.add_periodic_timer(ov, step)
            end
        end
    end

    -- live-TV "Up next" marquee: just tick the index every live_upcoming_secs; the
    -- sawtooth in card.build_card maps it to a hold-scroll-hold-restart window (the
    -- live_upcoming_delay holds at both ends live there, so no delay handoff here).
    if upnext_scroll_timer then upnext_scroll_timer:kill(); upnext_scroll_timer = nil end
    upnext_scroll_idx = 0
    if live_ctx then
        local us = tonumber(opts.live_upcoming_secs) or 0
        if us > 0 then
            upnext_scroll_timer = mp.add_periodic_timer(us, function()
                if visible then upnext_scroll_idx = upnext_scroll_idx + 1; render(true) end
            end)
        end
    end

    if hide_timer then hide_timer:kill(); hide_timer = nil end
    if timeout and timeout > 0 then hide_timer = mp.add_timeout(timeout, hide) end
    msg.verbose(string.format("show (timeout=%s)", tostring(timeout or 0)))
end

toggle = function()
    if visible then hide() else show(opts.toggle_timeout) end
end

-- Orchestration -------------------------------------------------------------


-- True only for a real movie/episode video (not an image, album art, or audio).
local function is_video_playback()
    return mp.get_property("current-tracks/video/codec") ~= nil
        and mp.get_property_native("current-tracks/video/image") ~= true
end

local function on_file_loaded()
    current_gen = current_gen + 1
    local gen = current_gen
    cur_signal = nil -- new file: drop any prior tuner reading (a fresh channel re-polls)
    cur_tech = nil   -- new file: re-read tech (resolution/codecs/…) on the next render
    content_ok = is_video_playback()
    if not content_ok then live_ctx = nil; hide(); return end -- no card for images / audio
    local path = mp.get_property("path") or mp.get_property("filename") or ""

    -- Live TV via Tvheadend EPG (takes priority over file identification).
    if opts.tvheadend_url ~= "" and path:find("/stream/channel") then
        -- No library artwork for a live stream: clear anything from a prior file.
        img_remove(clearlogo); img_remove(disc); disc_spin_stop()
        poster_hide(); fanart_hide(); banner_hide()
        poster.ready, fanart.ready, banner.ready, clearlogo.ready, disc.ready =
            false, false, false, false, false
        logo_rect, card_rect = nil, nil
        live_ctx = { path = path, chan = mp.get_property("media-title") or "" }
        cur_card = { kind = "livetv", title = "Live TV", source = "TVheadend" }
        if opts.auto_show then show(opts.duration) end -- show() reloads the EPG
        return
    end
    live_ctx = nil -- a normal file: leave live-TV mode

    local id = identify(path)
    local poster_path = find_poster(path, id)
    local logo_path = opts.show_logo and find_clearlogo(path, id) or nil
    local disc_path = opts.show_disc and find_disc(path, id) or nil
    local fanart_path = opts.show_fanart and find_fanart(path, id) or nil
    local banner_path = opts.show_banner and find_banner(path, id) or nil

    -- Confidence promotion: identify() returns kind="unknown" when the path
    -- carries no content-type signal (no Movies/Films or TV folder, no SxxEyy).
    -- Any image (artwork or a stray jpg/png) beside the media marks it as a
    -- catalogued movie/TV item, so promote the unknown to its best-effort movie
    -- identity and let TMDB enrich it. Only a bare video with NO image alongside
    -- stays a raw-filename card (no type guess, no remote query). The poster/movie
    -- candidate sets are kind-independent, so no re-scan is needed after promotion.
    if id.kind == "unknown" and id.promote
        and (poster_path or logo_path or disc_path or fanart_path or banner_path
            or dir_has_image(path)) then
        id = id.promote
    end
    local ep_total = (id.kind == "tv") and count_season_episodes(path, id.season) or nil

    local function merged(m)
        local c = {}
        for k, v in pairs(m) do c[k] = v end
        c.poster = c.poster or poster_path
        c.ep_total = c.ep_total or ep_total
        c.has_logo = c.has_logo or (logo_path ~= nil)
        c.has_disc = c.has_disc or (disc_path ~= nil)
        return c
    end

    -- Pick the metadata source: local .nfo (primary) -> cache -> filename.
    local do_tmdb = false
    local localc = read_local(path)
    if localc then
        localc.season = localc.season or id.season
        localc.episode = localc.episode or id.episode
        localc.title = localc.title or id.display -- episode .nfo without <showtitle>: use the path-derived show name
        cur_card = merged(localc)
        msg.verbose("local .nfo: '" .. tostring(localc.title) .. "'"
            .. (poster_path and " [poster]" or ""))
    else
        local cached = cache_get(id.cachekey)
        cur_card = merged(cached or {
            kind = id.kind, title = id.display, year = id.year,
            season = id.season, episode = id.episode, source = "file",
        })
        if cached then cur_card.rating_src = "TMDB" end
        -- refetch when there's no cache, or the cache predates the current schema
        -- (so old sparse cards pick up cast/genres/studio/… once).
        local stale_cache = cached and (tonumber(cached._v) or 1) < CARD_VER
        do_tmdb = (not cached or stale_cache)
            and opts.enrich and opts.api_key ~= "" and id.kind ~= "unknown"
        msg.verbose(string.format("identified %s: '%s'%s%s", id.kind, id.query or id.display or "",
            id.season and string.format(" S%02dE%02d", id.season, id.episode) or "",
            poster_path and " [poster]" or ""))
    end

    -- Supplement a local .nfo that is MISSING fields (cast/genres/…) from TMDB:
    -- fill-only (never overwrites the .nfo), cached under a separate extra/<key>.
    -- ID-first (the .nfo's <uniqueid> tmdb id), else the same title/year search.
    local do_supp = false
    if localc and opts.enrich and opts.api_key ~= "" and id.kind ~= "unknown"
        and opts.nfo_supplement and nfo_missing(localc) then
        local extra = cache_get("extra/" .. id.cachekey)
        if extra then fill_missing(cur_card, extra) else do_supp = true end
    end

    -- Rating is a dynamic property: show the freshest cached rating now
    -- (overriding the source rating), and refetch on load when missing/stale.
    -- do_tmdb already returns a rating, so only fetch rating-only when it won't.
    local do_rating = false
    if opts.enrich and opts.api_key ~= "" and (tonumber(opts.rating_ttl) or 0) > 0
        and id.kind ~= "unknown" then
        local rv, rt = rating_get(id.cachekey)
        if rv then cur_card.rating, cur_card.rating_src = rv, "TMDB" end
        if not do_tmdb and rating_stale(rt) then do_rating = true end
    end

    -- IMDb rating (via OMDb): an independent dynamic property shown ALONGSIDE the
    -- TMDB one. Show the freshest cached value now; refetch on load when missing or
    -- stale. Gated on omdb_api_key only (not api_key), so a card with no TMDB key
    -- still gets an IMDb rating. Fired below once an IMDb id (or title) is in hand.
    local do_imdb = false
    if opts.enrich and opts.omdb_api_key ~= "" and (tonumber(opts.rating_ttl) or 0) > 0
        and id.kind ~= "unknown" then
        local iv, it, ivotes = imdb_rating_get(id.cachekey)
        if iv then cur_card.rating_imdb, cur_card.rating_imdb_votes = iv, ivotes end
        if rating_stale(it) then do_imdb = true end
    end
    local imdb_fired = false
    local function apply_imdb(g, res)
        if not res then return end
        imdb_rating_put(id.cachekey, res.rating, res.votes) -- authoritative cache (before the gen guard)
        if g ~= current_gen then return end
        cur_card.rating_imdb, cur_card.rating_imdb_votes = res.rating, res.votes
        if visible then render() end
    end
    local function fire_imdb(g)
        if imdb_fired then return end
        imdb_fired = true
        omdb_fetch_rating({
            imdb_id = cur_card.imdb_id,
            -- a TMDB tconst for TV is the SERIES id (needs Season/Episode); a .nfo
            -- tconst is already episode/movie-level, so query it by id directly.
            series  = (id.kind == "tv") and cur_card.imdb_id ~= nil and cur_card.source == "TMDB",
            title   = cur_card.title or id.query or id.display,
            year    = cur_card.year or id.year,
            kind    = id.kind, season = id.season, episode = id.episode,
        }, function(res) apply_imdb(g, res) end)
    end

    -- Poster image: decode the local jpg (once per poster), show when ready.
    poster_hide()
    if opts.show_poster and poster_path then
        if not (poster.ready and poster.src == poster_path) then
            poster.ready = false
            poster_decode(poster_path, function(ok)
                if ok and gen == current_gen and visible then poster_show() end
            end)
        end
    else
        poster.ready = false
    end

    -- Fanart backdrop: decode the dimmed jpg (once per fanart), show when ready.
    fanart_hide()
    if fanart_path then
        if not (fanart.ready and fanart.src == fanart_path) then
            fanart.ready = false
            fanart_decode(fanart_path, function(ok)
                if ok and gen == current_gen and visible and fanart_paused_ok() then fanart_show() end
            end)
        end
    else
        fanart.ready = false
    end

    -- Banner: decode the wide title jpg (once per banner), show when ready.
    banner_hide()
    if banner_path then
        if not (banner.ready and banner.src == banner_path) then
            banner.ready = false
            banner_decode(banner_path, function(ok)
                if ok and gen == current_gen and visible then banner_show() end
            end)
        end
    else
        banner.ready = false
    end

    -- Clearlogo (transparent title art, top-left).
    img_remove(clearlogo)
    if logo_path then
        if not (clearlogo.ready and clearlogo.src == logo_path) then
            clearlogo.ready = false
            clearlogo_decode(logo_path, function(ok)
                if ok and gen == current_gen and visible then render() end
            end)
        end
    else
        clearlogo.ready = false
    end

    -- Disc art (3/4, nestled at the card's top-left corner; optional spin).
    img_remove(disc)
    disc_spin_stop()
    disc.spin_idx = 0
    if disc_path then
        if not (disc.ready and disc.src == disc_path) then
            disc.ready = false
            disc_decode(disc_path, function(ok)
                if ok and gen == current_gen and visible then disc_show(); disc_spin_start() end
            end)
        end
    else
        disc.ready = false
    end

    if opts.auto_show then show(opts.duration) end

    -- Fire the IMDb rating lookup: now if we already hold a tconst (.nfo/cache) or
    -- there's no TMDB body fetch to wait on (title fallback); otherwise the do_tmdb
    -- callback chains it once external_ids supplies the tconst.
    if do_imdb then
        if cur_card.imdb_id then fire_imdb(gen)
        elseif not do_tmdb then fire_imdb(gen) end
    end

    if do_tmdb then
        tmdb_fetch(id, function(card)
            if not card then return end
            card._v = CARD_VER
            cache_put(id.cachekey, card)
            rating_put(id.cachekey, card.rating) -- seed the dynamic rating cache
            if gen ~= current_gen then return end
            cur_card = merged(card)
            cur_card.rating_src = "TMDB"
            if do_imdb then fire_imdb(gen) end -- now cur_card.imdb_id (external_ids) is set, else title
            if visible then render() end
        end)
    else
        if do_supp then
            -- local .nfo present but missing fields: fetch, cache ONLY the gap
            -- fields under extra/<key>, and fill-only into the card (never
            -- overwriting authoritative .nfo values). When we also owe a rating
            -- refresh, use the search path (episode-accurate rating + body in one
            -- chain) and let it cover do_rating; otherwise prefer the precise
            -- id-based details call.
            local want_rating = do_rating
            local finish = function(src)
                if not src then return end
                local extra = pick_supplement(src, localc)
                cache_put("extra/" .. id.cachekey, extra) -- before the gen guard
                local r = want_rating and tonumber(src.rating) or nil
                if r and r > 0 then rating_put(id.cachekey, r) end
                if gen ~= current_gen then return end
                fill_missing(cur_card, extra)
                if r and r > 0 then cur_card.rating, cur_card.rating_src = r, "TMDB" end
                if visible then render() end
            end
            if localc.tmdb_id and not want_rating then
                tmdb_details(localc.kind or id.kind, localc.tmdb_id, finish)
            else
                tmdb_fetch(id, finish)
            end
            do_rating = false -- the supplement fetch also handled the rating
        end
        if do_rating then
            -- rating-only refresh (local .nfo card, or a stale cache hit): update
            -- just the rating, leaving the authoritative source card intact.
            tmdb_fetch(id, function(card)
                local r = card and tonumber(card.rating)
                if not r or r <= 0 then return end
                rating_put(id.cachekey, r)
                if gen ~= current_gen then return end
                cur_card.rating, cur_card.rating_src = r, "TMDB"
                if visible then render() end
            end)
        end
    end
end

-- Wiring --------------------------------------------------------------------

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", hide)
mp.register_event("shutdown", function()
    os.remove(poster.file)
    os.remove(fanart.file)
    os.remove(banner.file)
    os.remove(clearlogo.file)
    os.remove(disc.file)
end)

-- Single pause observer: (1) with show_on_pause, pop the card on pause (sticky) and
-- hide it on resume; (2) while the card is up, reveal the fanart backdrop on pause /
-- hide on resume (when fanart_pause_only) and stop/restart the disc spin. (Merged
-- from two separate pause observers — same order, so behaviour is unchanged.)
mp.observe_property("pause", "bool", function(_, paused)
    if paused == nil then return end
    if opts.show_on_pause then
        if paused then
            if not visible then show(0) end
        elseif visible then
            hide()
        end
    end
    if visible then
        if opts.fanart_pause_only then
            if paused then fanart_show() else fanart_hide() end
        end
        if paused then disc_spin_stop() else disc_spin_start() end
    end
end)

local bind_key = (opts.key ~= "") and opts.key or nil
mp.add_key_binding(bind_key, "toggle", toggle)

-- The VO/OSD often isn't ready when a poster finishes decoding at playback
-- start, so overlay-add would use a zero size and skip. Re-show once the OSD
-- size is known (also repositions on window resize).
mp.observe_property("osd-width", "number", function(_, w)
    if w and w > 0 and visible then
        if fanart.ready and fanart_paused_ok() then fanart_show() end
        if poster.ready then poster_show() end
        if banner.ready then banner_show() end
        if clearlogo.ready then place_logo() end
        if disc.ready then disc_show() end
    end
end)

msg.verbose("spincard loaded (identify + tmdb)")
