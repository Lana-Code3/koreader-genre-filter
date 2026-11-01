--[[--
Pure-Lua boolean matching for genre/tag filtering.

No KOReader dependencies, so it can be unit-tested with any Lua 5.1/LuaJIT.

Terminology:
  * "keywords" is the metadata field KOReader fills from EPUB dc:subject,
    Calibre tags, PDF keywords, etc. Several tags are stored in one string.
  * Matching is case-insensitive. Hyphens, underscores and runs of whitespace
    are treated as a single space ("Sci-Fi" == "sci fi" == "Sci  Fi").

Match modes (per term, against each individual tag):
  * "exact"     the tag must equal the term         ("romance" = "romance")
  * "word"      the term must appear as whole words ("romance" in "contemporary romance",
                but not in "romanced" or "promance")
  * "substring" the term may appear anywhere        ("rom" in "romance")
--]]--

local Matcher = {}

local function defaultLower(s)
    return s:lower()
end

--- Normalize one tag/term: lowercase, unify separators, trim.
function Matcher.normalize(s, lower)
    s = (lower or defaultLower)(s or "")
    s = s:gsub("[%s%-_]+", " ")
    s = s:gsub("^ ", "")
    s = s:gsub(" $", "")
    return s
end

--- Split a user string or a keywords field into tags.
-- Separators: comma, semicolon, pipe, newline.
-- @return terms  array of normalized, de-duplicated strings
-- @return labels array of the trimmed original spellings (same order/length)
function Matcher.parseList(str, lower)
    local terms, labels, seen = {}, {}, {}
    if type(str) ~= "string" or str == "" then
        return terms, labels
    end
    for piece in (str .. ","):gmatch("([^,;|\r\n]*)[,;|\r\n]") do
        local label = piece:gsub("^%s+", ""):gsub("%s+$", "")
        local term = Matcher.normalize(label, lower)
        if term ~= "" and not seen[term] then
            seen[term] = true
            table.insert(terms, term)
            table.insert(labels, label)
        end
    end
    return terms, labels
end

local function isBoundary(s, pos)
    -- pos outside the string (start/end) or a space counts as a word boundary
    return pos < 1 or pos > #s or s:sub(pos, pos) == " "
end

--- Does a single normalized tag match a single normalized term?
function Matcher.termMatches(tag, term, mode)
    if mode == "exact" then
        return tag == term
    end
    if mode == "substring" then
        return tag:find(term, 1, true) ~= nil
    end
    -- "word" (default)
    local init = 1
    while true do
        local s, e = tag:find(term, init, true)
        if not s then
            return false
        end
        if isBoundary(tag, s - 1) and isBoundary(tag, e + 1) then
            return true
        end
        init = s + 1
    end
end

local function anyTagMatches(tags, term, mode)
    for _, tag in ipairs(tags) do
        if Matcher.termMatches(tag, term, mode) then
            return true
        end
    end
    return false
end

--- Apply include/exclude logic to one book.
-- @param tags     array of normalized tags of the book
-- @param includes array of normalized include terms (may be empty)
-- @param excludes array of normalized exclude terms (may be empty)
-- @param opts     { mode = "word"|"exact"|"substring", require_all = bool }
-- @return boolean true if the book should be kept
function Matcher.matches(tags, includes, excludes, opts)
    opts = opts or {}
    local mode = opts.mode or "word"

    -- Exclusion is strict: a single excluded tag removes the book.
    for _, term in ipairs(excludes) do
        if anyTagMatches(tags, term, mode) then
            return false
        end
    end

    if #includes == 0 then
        return true
    end

    if opts.require_all then
        for _, term in ipairs(includes) do
            if not anyTagMatches(tags, term, mode) then
                return false
            end
        end
        return true
    end

    for _, term in ipairs(includes) do
        if anyTagMatches(tags, term, mode) then
            return true
        end
    end
    return false
end

--- Split free text into search words. "Quoted phrases" stay together.
-- @return array of lowercase words/phrases
function Matcher.parseWords(str, lower)
    local words = {}
    if type(str) ~= "string" or str == "" then
        return words
    end
    str = (lower or defaultLower)(str)
    str = str:gsub('"([^"]*)"', function(phrase)
        phrase = phrase:gsub("%s+", " ")
        phrase = phrase:gsub("^ ", "")
        phrase = phrase:gsub(" $", "")
        if phrase ~= "" then
            table.insert(words, phrase)
        end
        return " "
    end)
    for word in str:gmatch("%S+") do
        table.insert(words, word)
    end
    return words
end

--- True if every word/phrase occurs somewhere in `text` (case-insensitive).
function Matcher.textMatches(text, words, lower)
    if #words == 0 then
        return true
    end
    text = (lower or defaultLower)(text or "")
    text = text:gsub("%s+", " ")
    for _, word in ipairs(words) do
        if not text:find(word, 1, true) then
            return false
        end
    end
    return true
end

return Matcher
