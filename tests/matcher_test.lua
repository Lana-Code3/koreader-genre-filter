-- Unit tests for the pure-Lua matching logic. Run from the repository root:
--   lua tests/matcher_test.lua        (Lua 5.1 / LuaJIT)
package.path = "genre_filter.koplugin/?.lua;" .. package.path
local M = require("genre_filter_matcher")
local fails, n = 0, 0
local function check(name, got, want)
  n = n + 1
  if got ~= want then fails = fails + 1; print("FAIL", name, "got", tostring(got), "want", tostring(want)) end
end
local function book(kw) return (M.parseList(kw)) end
local function run(kw, inc, exc, opts)
  return M.matches(book(kw), (M.parseList(inc)), (M.parseList(exc)), opts)
end

-- parsing
local t, l = M.parseList("  Romance, Sci-Fi ;  drama\nRomance|  ")
check("parse count", #t, 3); check("parse t1", t[1], "romance"); check("parse t2", t[2], "sci fi")
check("parse label", l[2], "Sci-Fi"); check("dedupe", #M.parseList("a,A,a"), 1)
check("empty", #M.parseList(""), 0); check("nil", #M.parseList(nil), 0)

-- use case 1: include Romance, Drama | exclude Comedy
check("uc1 romance only", run("Romance", "Romance, Drama", "Comedy"), true)
check("uc1 drama only", run("Drama\nHistory", "Romance, Drama", "Comedy"), true)
check("uc1 romcom excluded", run("Romance\nComedy", "Romance, Drama", "Comedy"), false)
check("uc1 romantic comedy excluded (word)", run("Romance\nRomantic Comedy", "Romance, Drama", "Comedy"), false)
check("uc1 unrelated", run("Thriller", "Romance, Drama", "Comedy"), false)
-- use case 2: include Sci-Fi | exclude Fantasy, Horror
check("uc2 scifi", run("Science Fiction\nSci-Fi", "Sci-Fi", "Fantasy, Horror"), true)
check("uc2 sci fi spaced", run("sci fi", "Sci-Fi", "Fantasy, Horror"), true)
check("uc2 horror excluded", run("Sci-Fi, Horror", "Sci-Fi", "Fantasy, Horror"), false)
check("uc2 fantasy excluded", run("Sci-Fi; Fantasy", "Sci-Fi", "Fantasy, Horror"), false)
-- require_all
check("all: both", run("Romance, Drama", "Romance, Drama", "", {require_all=true}), true)
check("all: one missing", run("Romance", "Romance, Drama", "", {require_all=true}), false)
check("any: one enough", run("Romance", "Romance, Drama", ""), true)
-- exclude-only / include-only
check("exclude only keeps", run("Thriller", "", "Comedy"), true)
check("exclude only drops", run("Comedy", "", "Comedy"), false)
check("no tags + include", run("", "Romance", ""), false)
-- modes
check("word: partial word no", run("Romanced", "Romance", ""), false)
check("word: whole word in tag", run("Contemporary Romance", "Romance", ""), true)
check("word: prefix of word no", run("Smart", "art", ""), false)
check("word: repeated occurrence", run("Smart Art", "art", ""), true)
check("exact: no partial", run("Contemporary Romance", "Romance", "", {mode="exact"}), false)
check("exact: yes", run("Romance", "Romance", "", {mode="exact"}), true)
check("substring", run("Romanced", "roman", "", {mode="substring"}), true)

-- word search
local w = M.parseWords('Dragon "time  travel"  ')
check("words count", #w, 2); check("word1", w[1], "time travel"); check("word2", w[2], "dragon")
check("words empty", #M.parseWords(""), 0); check("words nil", #M.parseWords(nil), 0)
check("text all words", M.textMatches("A Dragon and the TIME  travel machine", M.parseWords('dragon "time travel"')), true)
check("text missing word", M.textMatches("A dragon story", M.parseWords("dragon wizard")), false)
check("text no words", M.textMatches("anything", {}), true)
print(string.format("%d checks, %d failures", n, fails))
os.exit(fails == 0 and 0 or 1)
