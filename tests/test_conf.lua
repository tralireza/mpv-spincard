-- Guard for the SHIPPED sample conf and the README's conf blocks.
--   run:  luajit tests/test_conf.lua   (from the repo root)
--
-- mpv's conf format is stricter than it looks (DOCS/man/lua.rst: "Comment lines
-- can be started with # and stray spaces are not removed"). Everything after the
-- FIRST '=' is the value, verbatim. So all three of these are broken:
--     key=10  # why        -> value "10  # why"
--     pos_x=22  pos_y=22   -> pos_x = "22  pos_y=22", pos_y never set
--     key=yes              -> trailing spaces survive and break the compare
-- Numbers/bools then fail loudly (mpv logs, key keeps its code default); strings
-- are never converted, so they break silently. Both the sample conf and the
-- README had instances — the README's were paste-and-nothing-works bad.

local CONF = "script-opts/spincard.conf"
local MAIN = "scripts/spincard/main.lua"
local README = "README.md"

local fails = 0
local function fail(fmt, ...)
    fails = fails + 1
    print("FAIL " .. string.format(fmt, ...))
end

-- Keys declared in main.lua's `opts` table: `name = value,` at one indent level.
local m = assert(io.open(MAIN, "r"), "cannot open " .. MAIN)
local main = m:read("*a"); m:close()
local declared = {}
local optblock = assert(main:match("\nlocal opts%s*=%s*{(.-)\n}"),
    "could not locate main.lua's opts table")
for key in optblock:gmatch("\n%s*([%a_][%w_]*)%s*=") do declared[key] = true end
assert(next(declared), "parsed no option names out of main.lua")

local function check_setting(src, lineno, key, val)
    if val:find("#") then
        fail("%s:%d '%s' has a trailing '#' comment; it stays in the value -> %q",
            src, lineno, key, val)
    end
    -- A second "word=" after whitespace means another option was packed onto this
    -- line; only the first is ever set. (A URL query "?a=b" has no leading space.)
    if val:find("%s[%a_][%w_]*=") then
        fail("%s:%d '%s' looks like it packs more than one option on a line -> %q",
            src, lineno, key, val)
    end
    if val:match("^%s") or val:match("%s$") then
        fail("%s:%d '%s' has leading/trailing whitespace in its value -> %q",
            src, lineno, key, val)
    end
    if key:find("%s") then
        fail("%s:%d key '%s' has whitespace; read_options matches keys literally",
            src, lineno, key)
    end
    if not declared[key] then
        fail("%s:%d '%s' is not declared in main.lua's opts table", src, lineno, key)
    end
end

-- io.lines, mirroring read_options' own f:lines(). NOT a gmatch over the whole
-- file: "[^\n]*" also matches empty after every line, doubling the line numbers.
local function scan(src, only_fenced)
    local n, lineno, fence = 0, 0, nil
    for line in io.lines(src) do
        lineno = lineno + 1
        if line:sub(#line) == "\r" then line = line:sub(1, #line - 1) end
        local info = line:match("^```(%w*)")
        if only_fenced and info then
            fence = (fence == nil) and info or nil -- open (with lang) / close
        elseif line:find("#") ~= 1 then            -- read_options' own comment test
            -- In the README only plain/conf fences hold settings; skip ```sh etc.
            local in_conf = not only_fenced or (fence == "")
            local eq = in_conf and line:find("=") or nil
            if eq then
                n = n + 1
                check_setting(src, lineno, line:sub(1, eq - 1), line:sub(eq + 1))
            end
        end
    end
    return n
end

local n_conf = scan(CONF, false)
assert(n_conf > 20, "only parsed " .. n_conf .. " settings from " .. CONF)
local n_readme = scan(README, true)
assert(n_readme > 10, "only parsed " .. n_readme .. " settings from " .. README
    .. " — the README's conf block moved or the fence parser is wrong")

print(string.format("checked %d settings in %s + %d in %s, against %d declared opts",
    n_conf, CONF, n_readme, README,
    (function() local c = 0; for _ in pairs(declared) do c = c + 1 end; return c end)()))
print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
