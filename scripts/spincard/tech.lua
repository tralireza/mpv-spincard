-- spincard/tech — read the playing file's technical details from mpv properties
-- (resolution, video/audio codecs, HDR, fps, container, size, chapters, and the
-- audio/subtitle language lists) into a flat table for build_card's tech block +
-- pills. Pure read of live mpv state; number/label formatters come from util.

local mp   = require "mp"
local msg  = require "mp.msg"
local util = require "util"
local fmt_duration, fmt_fps, human_size, chan_label =
    util.fmt_duration, util.fmt_fps, util.human_size, util.chan_label

local M = {}

function M.gather_tech()
    local t = {}
    local w, h = mp.get_property_number("width"), mp.get_property_number("height")
    if w and h then t.reso = string.format("%d\195\151%d", w, h) end -- W×H
    t.vwidth = w
    t.dur = fmt_duration(mp.get_property_number("duration"))

    local vc = mp.get_property("current-tracks/video/codec")
    if vc then t.vcodec = vc:upper() end

    local gamma = mp.get_property("video-params/gamma")
    if gamma == "pq" then t.hdr = "HDR10" elseif gamma == "hlg" then t.hdr = "HLG" end

    t.fps = fmt_fps(mp.get_property_number("container-fps")
        or mp.get_property_number("estimated-vf-fps"))

    local ext = (mp.get_property("path") or ""):match("%.([%a%d]+)$")
    if ext then t.container = ext:upper() end
    t.size = human_size(mp.get_property_number("file-size"))
    t.chapters = mp.get_property_number("chapters")

    -- Audio / subtitle languages (deduped by language, in order).
    local a_order, a_set, sel_lang, sel_ch, sel_codec = {}, {}, nil, nil, nil
    local s_order, s_set, s_forced = {}, {}, {}
    for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
        if tr.type == "audio" then
            local L = (tr.lang or "und"):upper()
            if tr.selected then
                sel_lang, sel_ch = L, chan_label(tr["demux-channel-count"])
                sel_codec = tr.codec and tr.codec:upper() or nil
            end
            if not a_set[L] then a_set[L] = true; a_order[#a_order + 1] = L end
        elseif tr.type == "sub" then
            local L = (tr.lang or "und"):upper()
            if not s_set[L] then s_set[L] = true; s_order[#s_order + 1] = L end
            if tr.forced then s_forced[L] = true end
        end
    end
    local a = {}
    for _, L in ipairs(a_order) do
        a[#a + 1] = (L == sel_lang and sel_ch) and (L .. " " .. sel_ch) or L
    end
    local s = {}
    for _, L in ipairs(s_order) do s[#s + 1] = s_forced[L] and (L .. "(f)") or L end

    local function join(list, max)
        if #list == 0 then return nil end
        local o = {}
        for i = 1, math.min(max, #list) do o[i] = list[i] end
        if #list > max then o[#o + 1] = "+" .. (#list - max) end
        return table.concat(o, ", ")
    end
    t.audio, t.subs = join(a, 4), join(s, 6)
    t.achan, t.acodec = sel_ch, sel_codec

    msg.verbose(string.format("tech: %s/%s %s %s %s | A:%s S:%s | chapters:%s %s",
        t.vcodec or "-", t.acodec or "-", t.hdr or "-", t.fps or "-", t.reso or "-",
        t.audio or "-", t.subs or "-", tostring(t.chapters or 0), t.size or "-"))
    return t
end

return M
