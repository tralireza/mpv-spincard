-- identify.lua — turn a full media path into a movie/TV identity.
--
-- Pure Lua (no mpv deps) so it can be unit-tested standalone:
--   luajit -e 'local I=dofile("identify.lua"); print(require"..."...)'
--
-- Returns a table:
--   TV      -> { kind="tv",      query=<show>,  display=<Show>, season=N, episode=N, cachekey=... }
--   movie   -> { kind="movie",   query=<title>, display=<Title>, year=YYYY|nil,     cachekey=... }
--   unknown -> { kind="unknown", display=<full file name>, cachekey=..., promote=<movie identity> }
-- query is lowercased/cleaned (for the TMDB search); display is title-cased (for
-- the offline fallback card); TMDB's own title replaces display once fetched.
--
-- "unknown" is returned when the path carries NO confident content-type signal
-- (not under a Movies/Films or TV folder, and no SxxEyy/NxNN marker). We refuse
-- to guess a type in that case: its display is the raw file name (unmangled, with
-- extension) and it is NOT enriched. main.lua may still promote it to `promote`
-- (its best-effort movie identity) when any image file (artwork, or a stray
-- jpg/png) sits next to the media, since that marks a catalogued movie/TV item.

local M = {}

-- Scene/release noise tokens (Lua patterns, lowercase). Order-independent.
local NOISE = {
    "2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd",
    "hdr10%+?", "hdr", "dolby", "vision", "dv", "sdr", "10bit", "8bit",
    "hevc", "avc", "x264", "x265", "h264", "h265", "av1", "xvid", "divx",
    "web%-dl", "webdl", "webrip", "web", "bluray", "blu%-ray", "bdrip",
    "brrip", "bdremux", "dvdrip", "dvd", "hdtv", "hdrip", "remux",
    "proper", "repack", "extended", "unrated", "uncut", "directors",
    "imax", "remastered", "limited", "complete", "internal",
    "aac", "ac3", "eac3", "dts%-hd", "dtshd", "dts", "truehd", "atmos",
    "flac", "mp3",
    -- audio channel layouts: identify() turns '.'/'_' into spaces before
    -- strip_noise runs, so match the split form (e.g. "5.1" -> "5 1").
    "ddp5%s1", "ddp", "dd5%s1", "dd", "5%s1", "7%s1", "2%s0",
    "amzn", "nf", "dsnp", "hmax", "atvp", "pcok", "multi", "dual",
}

local function trim(s)
    return (s:gsub("^[%s%-_%.]+", ""):gsub("[%s%-_%.]+$", ""))
end

local function collapse(s)
    return (s:gsub("%s+", " "))
end

local function strip_noise(s)
    s = " " .. s .. " "
    for _, p in ipairs(NOISE) do
        -- run twice to catch adjacent tokens sharing a separator
        s = s:gsub("%s" .. p .. "%s", " ")
        s = s:gsub("%s" .. p .. "%s", " ")
    end
    s = s:gsub("[%[%]%(%){}]", " ") -- drop stray brackets/parens
    return trim(collapse(s))
end

local function titlecase(s)
    return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end
M.titlecase = titlecase

-- Strip a trailing video extension (2-4 alpha-led chars), never a bare ".2020".
local function strip_ext(fname)
    return (fname:gsub("%.%a%w?%w?%w?$", ""))
end

-- Find the last plausible film year (1900-2099) with non-digit boundaries.
local function find_year(s)
    local ypos, yval, from = nil, nil, 1
    while true do
        local a, b, cap = s:find("(%d%d%d%d)", from)
        if not a then break end
        local n = tonumber(cap)
        local before = (a > 1) and s:sub(a - 1, a - 1) or " "
        local after = (b < #s) and s:sub(b + 1, b + 1) or " "
        if n >= 1900 and n <= 2099
            and not before:match("%d") and not after:match("%d") then
            ypos, yval = a, cap
        end
        from = b + 1
    end
    return ypos, yval
end

function M.identify(path)
    path = path or ""
    local fname = path:match("[^/\\]+$") or path
    local parent = path:match("([^/\\]+)[/\\][^/\\]+$")
    local s = strip_ext(fname):gsub("[%._]", " "):lower()

    -- Library path hints (e.g. /zhd/Movies vs /zhd/TV). A folder that names the
    -- content type is a confident signal all on its own.
    local lpath = path:lower()
    local is_movie_path = lpath:find("/movies?/") ~= nil or lpath:find("/films?/") ~= nil
    local is_tv_path = lpath:find("/tv/") ~= nil or lpath:find("/tv[ _%-]?shows?/") ~= nil
        or lpath:find("/series/") ~= nil

    -- ---- TV: the ONLY season/episode marker is the universal de-facto SxxEyy —
    --         literal S and E, each followed by ALWAYS TWO digits (S01E01, S12E34).
    --         Anything else — an "x" separator (NxNN), a single digit (s1e1), or a
    --         stray number in a word (a72x7t) — is NOT the format and is left as-is
    --         (so tmp.A72x7t.mp4 is never read as S72E07). A /TV/ folder still
    --         classifies the file as a (show-level) TV item, just with no S/E. ------
    local cut, season, episode = nil, nil, nil
    local i1, _, se, ep = s:find("s(%d%d)e(%d%d)")
    if i1 then
        cut, season, episode = i1, tonumber(se), tonumber(ep)
    end

    if cut or is_tv_path then
        local show = strip_noise(cut and s:sub(1, cut - 1) or s)
        if show == "" and parent then
            show = strip_noise(parent:gsub("[%._]", " "):lower())
        end
        return {
            kind = "tv",
            query = show,
            display = titlecase(show),
            season = season,
            episode = episode,
            cachekey = string.format("tv_%s_s%02d_e%02d",
                (show:gsub("%s", "_")), season or 0, episode or 0),
        }
    end

    -- ---- Movie: title (year). Built even when unconfident so main.lua can
    --      promote an unknown card to it if artwork side-files turn up. --------
    local ypos, yval = find_year(s)
    local title
    if ypos then
        title = strip_noise(s:sub(1, ypos - 1))
    else
        title = strip_noise(s)
    end
    -- If the filename gave us nothing useful, fall back to the parent dir
    -- (e.g. ".../Arrival (2016)/movie.mkv").
    if (title == "" or #title < 2) and parent then
        local p = parent:gsub("[%._]", " "):lower()
        local pp, py = find_year(p)
        if not yval then yval = py end
        title = strip_noise(pp and p:sub(1, pp - 1) or p)
    end

    local movie = {
        kind = "movie",
        query = title,
        display = titlecase(title),
        year = yval and tonumber(yval) or nil,
        cachekey = string.format("movie_%s_%s",
            (title:gsub("%s", "_")), yval or "na"),
    }

    -- A Movies/Films folder is a confident movie signal; return it outright.
    if is_movie_path then return movie end

    -- ---- Unknown: nothing confident about the type. Don't guess — surface the
    --      raw file name (with extension) and let main.lua promote to `movie`
    --      only if an image (artwork or any jpg/png) is found beside it. -------
    return {
        kind = "unknown",
        query = title,                 -- best-effort, used only after promotion
        display = fname,               -- the full file name, unmangled
        cachekey = "file_" .. (fname:lower():gsub("[^%w%-_]", "_")),
        promote = movie,
    }
end

return M
