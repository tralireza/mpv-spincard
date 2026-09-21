-- Regression test: overlapping casthead_prepare calls in ONE file load.
--   run:  luajit tests/test_casthead_race.lua   (from the repo root)
--
-- main.lua fires fire_casthead twice per load (once at file-load, once from the
-- do_tmdb callback), so a stale cached card carrying cast starts two prepares.
-- Three invariants:
--   * an IDENTICAL re-request for the same load is skipped outright (no second
--     ffmpeg, no duplicate downloads);
--   * a genuinely different request supersedes, and the superseded one must NOT
--     report back — prepare_heads reads count==0 as "no faces decoded", clears
--     casthead_active and re-renders, putting the card's text cast back for good
--     (the winner never re-sets the flag, it is only set on entry);
--   * a real failure still reports 0, so that path keeps working.

local noop = setmetatable({}, { __index = function() return function() end end })

local utils_stub = setmetatable({
    file_info = function() return { size = 4 * 182 * 1692, is_dir = false } end,
}, { __index = function() return function() end end })

-- Captured ffmpeg/curl jobs, so the test controls completion order.
local jobs = {}
local mp_stub = setmetatable({
    command_native_async = function(t, cb) jobs[#jobs + 1] = { t = t, cb = cb }; return true end,
    get_property = function() return "testpid" end,
    get_osd_size = function() return 1920, 1080 end,
    command_native = function() return true end,
}, { __index = function() return function() end end })

package.preload["mp"] = function() return mp_stub end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return utils_stub end
package.path = "scripts/spincard/?.lua;" .. package.path

local real_execute = os.execute
os.execute = function() return true end
local images = require("images")
os.execute = real_execute

images.init({
    casthead_style = "scroll", casthead_max = 10, cast_headshots = true,
}, { logo_rect = function() end, card_rect = function() end, visible = function() return true end })

local fails = 0
local function check(name, got, want)
    if got ~= want then
        fails = fails + 1
        print(string.format("FAIL %s\n     got:  %s\n     want: %s", name, tostring(got), tostring(want)))
    else
        print("ok   " .. name)
    end
end

local function mkcast(tag, n)
    local c = {}
    for i = 1, n do c[i] = { name = "Actor " .. i, role = "Role " .. i, profile = "/" .. tag .. i .. ".jpg" } end
    return c
end

local outfile = function(job) return job.t.args[#job.t.args] end -- ffmpeg: output is last
local function argafter(job, flag) -- curl: the temp path follows -o
    for i, a in ipairs(job.t.args) do if a == flag then return job.t.args[i + 1] end end
end

local castA, castB = mkcast("a", 9), mkcast("b", 9)
local GEN = 7 -- the SAME file generation for both calls, as main.lua passes

-- ---- Identical re-request is skipped -----------------------------------------
jobs = {}
local g1, g2 = "NOT CALLED", "NOT CALLED"
images.casthead_prepare(castA, GEN, function(n) g1 = n end)
check("first prepare runs", #jobs, 1)
images.casthead_prepare(castA, GEN, function(n) g2 = n end)
check("identical re-request starts no second ffmpeg", #jobs, 1)
check("identical re-request does not call back", g2, "NOT CALLED")
jobs[1].cb(true, { status = 0 })
check("the live prepare still reports", g1, 9)

-- Still skipped after it completed successfully.
local g3 = "NOT CALLED"
images.casthead_prepare(castA, GEN, function(n) g3 = n end)
check("identical request after success is still skipped", #jobs, 1)
check("  ...and stays silent", g3, "NOT CALLED")

-- ---- A DIFFERENT cast supersedes ---------------------------------------------
jobs = {}
local s1, s2 = "NOT CALLED", "NOT CALLED"
images.casthead_prepare(castA, GEN + 1, function(n) s1 = n end)
images.casthead_prepare(castB, GEN + 1, function(n) s2 = n end)
check("a different profile set does start a second ffmpeg", #jobs, 2)
check("concurrent prepares must not share an output file",
    outfile(jobs[1]) ~= outfile(jobs[2]), true)
jobs[2].cb(true, { status = 0 })
check("current prepare reports its faces", s2, 9)
jobs[1].cb(true, { status = 0 })
check("superseded prepare stays silent", s1, "NOT CALLED")

-- Superseded finishing FIRST must also stay silent.
jobs = {}
local s3, s4 = "NOT CALLED", "NOT CALLED"
images.casthead_prepare(castA, GEN + 2, function(n) s3 = n end)
images.casthead_prepare(castB, GEN + 2, function(n) s4 = n end)
jobs[1].cb(true, { status = 0 })
check("superseded stays silent when it finishes first", s3, "NOT CALLED")
jobs[2].cb(true, { status = 0 })
check("current prepare still reports", s4, 9)

-- ---- Real failures still report 0, and permit a retry ------------------------
jobs = {}
local f1 = "NOT CALLED"
images.casthead_prepare(castA, GEN + 3, function(n) f1 = n end)
jobs[1].cb(true, { status = 1 }) -- ffmpeg failed
check("real failure reports 0", f1, 0)

local f2 = "NOT CALLED"
images.casthead_prepare(castA, GEN + 3, function(n) f2 = n end)
check("an identical retry IS allowed after a failure", #jobs, 2)
jobs[2].cb(true, { status = 0 })
check("  ...and the retry reports", f2, 9)

local f3 = "NOT CALLED"
images.casthead_prepare({ { name = "No Profile" } }, GEN + 4, function(n) f3 = n end)
check("no profiles reports 0", f3, 0)

-- ---- Concurrent fetches of one image need separate temps ---------------------
-- Defence, not a measured failure: two concurrent fetches of one image would
-- share <dest>.<pid>.part and both rename it, publishing a half-written file
-- into the PERSISTENT cache.
jobs = {}
utils_stub.file_info = function() return nil end -- force a cache miss so curl runs
images.fetch_image("/same.jpg", "w185", "cast", function() end)
images.fetch_image("/same.jpg", "w185", "cast", function() end)
check("two concurrent fetches of one image were issued", #jobs, 2)
check("concurrent fetches must not share a temp file",
    argafter(jobs[1], "-o") ~= argafter(jobs[2], "-o"), true)
check("both fetches target the same final URL", outfile(jobs[1]), outfile(jobs[2]))

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
