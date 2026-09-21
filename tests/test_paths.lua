-- util's path helpers, on BOTH platform branches.
--   run:  luajit tests/test_paths.lua   (from the repo root)
--
-- util picks its separator from package.config at load time, so the Windows
-- branch is covered by overriding it and re-requiring — the only way to reach it
-- from macOS/Linux, and without it that half would ship untested.
-- util.path() = always native (paths we build); util.join() = keep the
-- discovered dir's own style.

local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mp"] = function() return noop end
package.preload["mp.msg"] = function() return noop end
package.preload["mp.utils"] = function() return noop end
package.path = "scripts/spincard/?.lua;" .. package.path

local real_config, real_getenv = package.config, os.getenv

local function load_util(sep)
    package.config = sep .. "\n;\n?\n!\n-\n" -- first char IS the platform separator
    package.loaded["util"] = nil
    return require("util")
end

local fails = 0
local function check(name, got, want)
    if got ~= want then
        fails = fails + 1
        print(string.format("FAIL %s\n     got:  %s\n     want: %s", name, tostring(got), tostring(want)))
    else
        print("ok   " .. name)
    end
end

-- ---- POSIX branch -----------------------------------------------------------
local u = load_util("/")
check("posix: WIN false",  u.WIN, false)
check("posix: SEP",        u.SEP, "/")
check("posix: path()",     u.path("a", "b", "c"), "a/b/c")
check("posix: cache dir",  u.path("/home/me", ".cache", "spincard", "img"),
    "/home/me/.cache/spincard/img")
check("posix: join",       u.join("/m/Movies", "poster.jpg"), "/m/Movies/poster.jpg")
check("posix: join, no separator in dir", u.join(".", "poster.jpg"), "./poster.jpg")
local pd, pb = u.split_path("/m/A/B.mkv")
check("posix: split dir",  pd, "/m/A")
check("posix: split base", pb, "B")
check("posix: root file",  (u.split_path("/movie.mkv")), "/")
check("posix: parent_dir", u.parent_dir("/tv/Show/Season 01"), "/tv/Show")

-- ---- Windows branch ---------------------------------------------------------
local w = load_util("\\")
check("win: WIN true", w.WIN, true)
check("win: SEP",      w.SEP, "\\")
check("win: path()",   w.path("C:", "Users", "me", ".cache"), "C:\\Users\\me\\.cache")
check("win: cache dir", w.path("C:\\Users\\me", ".cache", "spincard", "img"),
    "C:\\Users\\me\\.cache\\spincard\\img")
check("win: join keeps backslash", w.join("D:\\Movies\\Foo", "poster.jpg"),
    "D:\\Movies\\Foo\\poster.jpg")
-- Not forced to "\": the mixed "Z:/Movies\poster.jpg" works but reads as a bug.
check("win: join keeps forward slash when the dir uses it",
    w.join("Z:/Movies", "poster.jpg"), "Z:/Movies/poster.jpg")
check("win: join on a bare drive uses the native separator",
    w.join("Z:", "poster.jpg"), "Z:\\poster.jpg")

-- The exact path from the reported Windows log.
local wd, wb = w.split_path("Z:\\Movies\\Mayday (2026)\\Mayday (2026).mp4")
check("win: split dir",  wd, "Z:\\Movies\\Mayday (2026)")
check("win: split base", wb, "Mayday (2026)")
check("win: parent_dir", w.parent_dir("Z:\\Movies\\Mayday (2026)"), "Z:\\Movies")
check("win: drive letter is not a URL", w.is_url("Z:/Movies/x.mkv"), false)
check("win: unc-ish path is not a URL", w.is_url("\\\\nas\\Movies\\x.mkv"), false)
check("http IS a url", w.is_url("http://127.0.0.1:9981/stream/channel/abc"), true)

-- ---- Environment fallbacks (read at CALL time, so no reload needed) ---------
os.getenv = function(k) return ({ TMPDIR = "/var/folders/xy/T/" })[k] end
check("tmpdir: strips macOS trailing slash", w.tmpdir(), "/var/folders/xy/T")
os.getenv = function(k) return ({ TEMP = "C:\\Users\\me\\AppData\\Local\\Temp" })[k] end
check("tmpdir: falls back to TEMP", w.tmpdir(), "C:\\Users\\me\\AppData\\Local\\Temp")
os.getenv = function(k) return ({ TMP = "C:\\Temp\\" })[k] end
check("tmpdir: falls back to TMP, strips backslash", w.tmpdir(), "C:\\Temp")
os.getenv = function() return nil end
check("tmpdir: last resort", w.tmpdir(), "/tmp")
os.getenv = function(k) return ({ USERPROFILE = "C:\\Users\\me" })[k] end
check("home: falls back to USERPROFILE", w.home(), "C:\\Users\\me")
os.getenv = function(k) return ({ HOME = "/home/me", USERPROFILE = "C:\\Users\\me" })[k] end
check("home: HOME wins when both are set", w.home(), "/home/me")
os.getenv = real_getenv

package.config = real_config
print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
