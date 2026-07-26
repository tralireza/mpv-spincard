-- spincard/tvheadend — live-TV data fetchers for a Tvheadend server: resolve the
-- played stream to a channel UUID, fetch its current + upcoming EPG programmes,
-- and read the tuner's signal/SNR/bitrate telemetry. Pure fetch — returns cards /
-- reading tables via callbacks; the lifecycle glue that pushes results into the
-- card (live_refresh / live_signal_refresh) stays in main.lua. Needs opts
-- (tvheadend_url / live_upcoming) via tvheadend.init(opts); curl_json + urlencode
-- come from util. The signal-meter COLOUR (tier_color) lives in util (render side).

local mp   = require "mp"
local msg  = require "mp.msg"
local util = require "util"
local curl_json, urlencode = util.curl_json, util.urlencode

local M = {}

local opts = {}
function M.init(o) opts = o end

-- EPG: stream -> channel -> current programme ------------------------------
-- The stream URL carries a numeric channelid; TVH's own /playlist/channels maps
-- that id -> channel uuid (the tvg-id), so we key off the URL (robust). A
-- /stream/channel/<uuid> URL is used directly; the channel name (mpv's
-- media-title) is the last-resort fallback.

local tvh_map = nil -- { id2uuid = {channelid -> uuid}, name2uuid = {name -> uuid} }

-- Fetch + parse TVH's M3U playlist once: pairs of an #EXTINF (tvg-id + name)
-- line and the following /stream/channelid/<N> URL.
local function tvh_get_map(cb)
    if tvh_map then return cb(tvh_map) end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "curl", "-sL", "--max-time", "10", opts.tvheadend_url .. "/playlist/channels" },
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            msg.warn("tvheadend playlist fetch failed"); return cb(nil)
        end
        local m = { id2uuid = {}, name2uuid = {} }
        local uuid, name
        for line in res.stdout:gmatch("[^\r\n]+") do
            local u = line:match('tvg%-id="([^"]+)"')
            if u then
                uuid = u
                name = line:match(",%s*(.-)%s*$")
                if name then name = name:gsub("^%b{}%s*", "") end -- strip {.} / {@} markers
            else
                local cid = line:match("/stream/channelid/(%d+)")
                if cid and uuid then
                    m.id2uuid[cid] = uuid
                    if name and name ~= "" then m.name2uuid[name:lower()] = uuid end
                    uuid, name = nil, nil
                end
            end
        end
        tvh_map = m
        cb(m)
    end)
end

-- Path (or media-title) -> channel uuid, else nil.
local function tvh_resolve(path, chan_name, cb)
    local direct = path:match("/stream/channel/([%x][%x%-]+)") -- URL is already a uuid
    if direct then return cb(direct) end
    tvh_get_map(function(m)
        if not m then return cb(nil) end
        local cid = path:match("/stream/channelid/(%d+)")
        if cid and m.id2uuid[cid] then return cb(m.id2uuid[cid]) end
        if chan_name and chan_name ~= "" then -- fall back to the channel name
            local uuid = m.name2uuid[chan_name:lower()]
            if not uuid then -- ignore a trailing HD/UHD/FHD marker on either side
                local base = chan_name:lower():gsub("%s+[uf]?hd$", "")
                for nm, u in pairs(m.name2uuid) do
                    if nm:gsub("%s+[uf]?hd$", "") == base then uuid = u; break end
                end
            end
            return cb(uuid)
        end
        cb(nil)
    end)
end

-- Resolve the channel -> its current programme card (or nil). The EPG grid is
-- ordered by start and forward-filtered (current + future), so entries[1] is
-- USUALLY the programme on now — but NOT when the guide has a gap over the current
-- time, in which case entries[1] is the next (future) programme. Trusting it there
-- shows a not-yet-aired programme dressed up as "now" (the bug). So SCAN for the
-- entry that actually COVERS now (start <= now < stop); if none does there is no
-- current programme -> return a `no_epg` card (channel + upcoming only). `upcoming`
-- is always the future programmes (start > now), whether or not one is on air.
function M.tvh_fetch(path, chan_name, cb)
    tvh_resolve(path, chan_name, function(uuid)
        if not uuid then return cb(nil) end
        local want = math.max(0, math.floor(tonumber(opts.live_upcoming) or 0))
        curl_json(string.format("%s/api/epg/events/grid?channel=%s&limit=%d",
            opts.tvheadend_url, urlencode(uuid), want + 1), function(e)
            if not (e and e.entries) then return cb(nil) end -- fetch/parse failed: keep the prior card
            local entries = e.entries
            local now = os.time()
            local cur -- the programme actually on now (nil = an EPG gap over `now`)
            for _, ev in ipairs(entries) do
                local s, st = tonumber(ev.start), tonumber(ev.stop)
                if s and st and s <= now and now < st then cur = ev; break end
            end
            local upcoming = {} -- the future programmes (start > now), capped at `want`
            for _, ev in ipairs(entries) do
                if #upcoming >= want then break end
                local s = tonumber(ev.start)
                if s and s > now and ev.title and ev.title ~= "" then
                    upcoming[#upcoming + 1] = { title = ev.title, start = s }
                end
            end
            local channel = (cur and cur.channelName)
                or (entries[1] and entries[1].channelName) or chan_name
            if not cur then -- EPG gap: no programme covers now -> channel + upcoming only
                return cb({
                    kind = "livetv", source = "TVheadend",
                    channel = channel, no_epg = true, upcoming = upcoming,
                })
            end
            cb({
                kind = "livetv", source = "TVheadend",
                channel = channel,
                title = cur.title,
                subtitle = (cur.subtitle and cur.subtitle ~= "") and cur.subtitle or cur.episodeOnscreen,
                overview = cur.summary or cur.description,
                start = tonumber(cur.start), stop = tonumber(cur.stop),
                upcoming = upcoming,
            })
        end)
    end)
end

-- Tuner signal / SNR / bitrate --------------------------------------------
-- Signal/SNR live on the DVB *input*; the channel lives on the *subscription*;
-- they join by the input name being the prefix of the subscription's service.
-- Values are scale-tagged: 1 = relative (0..65535 → %), 2 = decibel (milli-dB →
-- dB/dBm), 0 = unknown. Bitrate is the per-channel subscription rate.

-- Convert a scaled Tvheadend value: returns (value, is_percent) or nil.
local function tvh_scaled(v, scale)
    v, scale = tonumber(v), tonumber(scale)
    if not v or not scale or scale == 0 then return nil end
    if scale == 1 then return v / 65535 * 100, true end -- relative %
    if scale == 2 then return v / 1000, false end       -- decibel (milli-dB)
    return nil
end

-- Per-metric quality level 1..4: % (relative), dB (SNR), dBm (signal strength).
-- Rough DVB-S ballparks — they drive the meter fill + colour only.
local function level_pct(p) return (p >= 80 and 4) or (p >= 60 and 3) or (p >= 40 and 2) or 1 end
local function level_db(d)  return (d >= 12 and 4) or (d >= 9 and 3) or (d >= 6 and 2) or 1 end
local function level_dbm(s) return (s >= -45 and 4) or (s >= -55 and 3) or (s >= -65 and 2) or 1 end

-- Normalise a TVH channel label: drop TVH's leading space + a {.}/{@} marker,
-- lowercase, tolerate a trailing HD/UHD/FHD marker (matches tvh_resolve).
local function chan_norm(s)
    s = tostring(s or ""):gsub("^%s*", ""):gsub("^%b{}%s*", ""):lower()
    return (s:gsub("%s+[uf]?hd$", ""))
end

-- Mux (transponder) parameters, fetched once and memoised: name -> {delsys,
-- freq (kHz), symrate (sym/s), mod, fec, pol}. The mux name equals the first
-- token of an input's `stream` field (e.g. "11641H in Astra 28.2E" -> "11641H").
local tvh_muxes = nil
local function tvh_get_muxes(cb)
    if tvh_muxes then return cb(tvh_muxes) end
    curl_json(opts.tvheadend_url .. "/api/mpegts/mux/grid?limit=1000", function(d)
        local m = {}
        if d and d.entries then
            for _, e in ipairs(d.entries) do
                if e.name and e.delsys then -- DVB muxes carry delsys; IPTV ones don't
                    m[e.name] = { delsys = e.delsys, freq = tonumber(e.frequency),
                        symrate = tonumber(e.symbolrate), mod = e.modulation,
                        fec = e.fec, pol = e.polarisation }
                end
            end
        end
        tvh_muxes = m
        cb(m)
    end)
end

function M.tvh_signal(chan_name, cb)
    local want = chan_norm(chan_name)
    curl_json(opts.tvheadend_url .. "/api/status/subscriptions", function(subs)
        local list = subs and subs.entries
        if not list then return cb(nil) end
        -- Pick our subscription: prefer client=="libmpv"; disambiguate by name
        -- only when more than one exists. Any named match is a last resort.
        local mpvsubs, namematch = {}, nil
        for _, s in ipairs(list) do
            if s.service and s.service ~= "" then
                if s.client == "libmpv" then mpvsubs[#mpvsubs + 1] = s end
                if chan_norm(s.channel) == want then namematch = namematch or s end
            end
        end
        local chosen
        if #mpvsubs == 1 then
            chosen = mpvsubs[1]
        elseif #mpvsubs > 1 then
            for _, s in ipairs(mpvsubs) do if chan_norm(s.channel) == want then chosen = s; break end end
            chosen = chosen or mpvsubs[1]
        else
            chosen = namematch
        end
        if not chosen then return cb(nil) end
        local service = chosen.service
        local function pos(v) v = tonumber(v); return (v and v > 0) and v or nil end
        local rate = pos(chosen.out) or pos(chosen["in"]) -- bytes/s (prefer delivered); ignore 0/absent

        curl_json(opts.tvheadend_url .. "/api/status/inputs", function(inps)
            local ilist = inps and inps.entries
            if not ilist then return cb(nil) end
            -- Join by plain-string prefix (input name has Lua magic chars).
            local inp
            for _, it in ipairs(ilist) do
                local nm = it.input
                if nm and nm ~= "" and service:sub(1, #nm) == nm
                    and service:sub(#nm + 1, #nm + 1) == "/" then
                    inp = it; break
                end
            end
            if not inp then -- fallback: exactly one active input (one tuner in use)
                local active = {}
                for _, it in ipairs(ilist) do
                    if (tonumber(it.subs) or 0) >= 1 then active[#active + 1] = it end
                end
                if #active == 1 then inp = active[1] end
            end
            if not inp then return cb(nil) end

            local rd = { ber = tonumber(inp.ber) or 0, unc = tonumber(inp.unc) or 0 }
            rd.clean = (rd.ber == 0 and rd.unc == 0)
            local sv, sp = tvh_scaled(inp.signal, inp.signal_scale)
            if sv then
                rd.sig, rd.sig_unit = sv, (sp and "%" or "dBm")
                rd.sig_level = sp and level_pct(sv) or level_dbm(sv)
            end
            local nv, np = tvh_scaled(inp.snr, inp.snr_scale)
            if nv then
                rd.snr, rd.snr_unit = nv, (np and "%" or "dB")
                rd.snr_level = np and level_pct(nv) or level_db(nv)
            end
            if not rd.sig and not rd.snr then return cb(nil) end -- no RF telemetry (scale 0)
            if rate then rd.mbps = rate * 8 / 1e6 end
            local muxname = (inp.stream or ""):match("^(%S+)") -- e.g. "11641H"
            if muxname then
                if tvh_muxes then rd.mux = tvh_muxes[muxname]
                else tvh_get_muxes(function() end) end -- warm the cache for the next poll
            end
            cb(rd)
        end)
    end)
end

return M
