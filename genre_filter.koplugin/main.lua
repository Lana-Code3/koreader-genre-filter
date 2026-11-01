--[[--
Genre filter search: boolean include/exclude search over book genres/tags.

Reads the "keywords" metadata of each book (EPUB dc:subject, Calibre tags, PDF
keywords...) through KOReader's own BookInfo / CoverBrowser metadata cache, and
shows matches either in the standard file-search results list or in a
two-column large-cover gallery (cover, title, author, status and tags per book).
Long-press a book for its synopsis.

@module koplugin.GenreFilter
--]]--

local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
local CheckButton = require("ui/widget/checkbutton")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local FileChooser = require("ui/widget/filechooser")
local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template
local Matcher = require("genre_filter_matcher") -- lives next to this file

local Screen = Device.screen

-- Folder of this plugin (needed to lazy-load the gallery module)
local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]*$")

local SETTINGS_KEY = "genre_filter"
local SYS_FOLDERS = { -- never descend into these
    ["/dev"] = true,
    ["/proc"] = true,
    ["/sys"] = true,
    ["/mnt/base-us"] = true,
}

-- Reading statuses as returned by BookList.getBookStatus()
local STATUS_ORDER = { "new", "reading", "abandoned", "complete" }

-- Result views. The cover views always have 2 columns; `rows` is the number
-- of rows per page, so fewer rows means bigger covers.
local VIEW_MODES = {
    { id = "list" },
    { id = "covers", rows = 4 },
    { id = "covers", rows = 3 },
    { id = "covers", rows = 2 },
}

local GenreFilter = WidgetContainer:extend{
    name = "genre_filter",
    is_doc_only = false,
}

------------------------------------------------------------------------------
-- Setup / menu
------------------------------------------------------------------------------

-- UI instance that works both in the file browser and in the reader.
local function getUI()
    return require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
end

-- Kobo status of the books in the current results (fullpath -> { status, percent }),
-- filled after each search; read by the gallery to show the status line.
local kobo_status_cache = {}

local function isOurResults()
    local hash = FileSearcher.search_hash
    return type(hash) == "string" and util.stringStartsWith(hash, "genre_filter:")
end

-- Enables the arrow button in the results footer (bottom left) and makes it
-- return to the filter page. Same mechanism the Collections list uses.
-- Must not capture a plugin instance: the menu can outlive it (e.g. "last results").
local function attachBackToFilterButton(menu)
    if #menu.paths == 0 then
        table.insert(menu.paths, true) -- non-empty paths enable the return arrow
    end
    menu.onReturn = function()
        local plugin = getUI().genre_filter
        if not plugin then
            return
        end
        if menu.close_callback then
            menu.close_callback()
        end
        plugin:onShowGenreFilter()
    end
end

-- Show tags and synopsis (book description) of a book.
local function showSynopsis(file)
    local ui = getUI()
    local props = ui.bookinfo:getDocProps(file, nil, true) or {}
    local _terms, labels = Matcher.parseList(props.keywords, util.stringLower)
    local parts = {}
    if props.authors and props.authors ~= "" then
        table.insert(parts, (props.authors:gsub("\n", ", ")))
    end
    if #labels > 0 then
        table.insert(parts, T(_("Tags: %1"), table.concat(labels, ", ")))
    else
        table.insert(parts, _("Tags: none"))
    end
    local description = props.description and util.htmlToPlainTextIfHtml(props.description)
    if description == nil or not description:match("%S") then
        description = _("No synopsis available.")
    end
    table.insert(parts, description)
    UIManager:show(TextViewer:new{
        title = props.title or filemanagerutil.splitFileNameType(file),
        text = table.concat(parts, "\n\n"),
    })
end

function GenreFilter:init()
    self:onDispatcherRegisterActions()
    -- Extra row in the long-press dialog of the standard results list.
    -- (Registered on the FileSearcher class, so it must not capture `self`.)
    local FileManager = require("apps/filemanager/filemanager")
    FileManager.addFileDialogButtons(FileSearcher, "genre_filter_synopsis", function(file, is_file)
        if not is_file or not isOurResults() then
            return nil -- only for results of this plugin
        end
        return {
            {
                text = _("Synopsis & tags"),
                callback = function()
                    local menu = FileSearcher.getMenuInstance()
                    if menu and menu.file_dialog then
                        UIManager:close(menu.file_dialog)
                    end
                    showSynopsis(file)
                end,
            },
        }
    end)
    -- Add the "back to filter" arrow to every standard results list of ours.
    if not FileSearcher._genre_filter_hooked then
        FileSearcher._genre_filter_hooked = true
        local orig_show = FileSearcher.onShowSearchResults
        FileSearcher.onShowSearchResults = function(searcher, not_cached)
            local ret = orig_show(searcher, not_cached)
            local menu = searcher.booklist_menu
            if menu and isOurResults() then
                attachBackToFilterButton(menu)
                menu:updateItems(1, true) -- refresh the footer so the arrow shows
            end
            return ret
        end
    end
    if not self.ui.document then -- same rule as the built-in File search
        self.ui.menu:registerToMainMenu(self)
    end
end

function GenreFilter:onDispatcherRegisterActions()
    Dispatcher:registerAction("genre_filter_search", {
        category = "none",
        event = "ShowGenreFilter",
        title = _("Genre filter search"),
        general = true,
    })
end

function GenreFilter:addToMainMenu(menu_items)
    menu_items.genre_filter_search = {
        text = _("Genre filter search"),
        sorting_hint = "search",
        help_text = _([[Find books by genre/tag.

Enter genres to include and genres to exclude, separated by commas. Books with any excluded genre are always left out.

Genres come from the book metadata (EPUB subjects, Calibre tags, keywords). Metadata must be indexed by the CoverBrowser plugin: open a folder once in the file browser or use "Extract and cache book information".]]),
        callback = function()
            self:onShowGenreFilter()
        end,
    }
end

------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------

function GenreFilter:getConfig()
    local cfg = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(cfg) ~= "table" then
        cfg = {}
    end
    if cfg.include == nil then cfg.include = "" end
    if cfg.exclude == nil then cfg.exclude = "" end
    if cfg.require_all == nil then cfg.require_all = false end
    if cfg.include_subfolders == nil then cfg.include_subfolders = true end
    if cfg.exact == nil then cfg.exact = false end
    if cfg.words == nil then cfg.words = "" end
    if cfg.words_in_description == nil then cfg.words_in_description = true end
    if type(cfg.statuses) ~= "table" then cfg.statuses = {} end
    if type(cfg.view_mode) ~= "number" or not VIEW_MODES[cfg.view_mode] then cfg.view_mode = 1 end
    return cfg
end

function GenreFilter:saveConfig(cfg)
    G_reader_settings:saveSetting(SETTINGS_KEY, cfg)
end

function GenreFilter:getHomeFolder()
    return G_reader_settings:readSetting("home_dir")
end

function GenreFilter:getCurrentFolder()
    return self.ui.file_chooser and self.ui.file_chooser.path or self.ui:getLastDirFile()
end

------------------------------------------------------------------------------
-- Library scanning (these run inside a subprocess: return plain data only)
------------------------------------------------------------------------------

-- Walks a folder tree like the built-in FileSearcher does and calls
-- on_file(filename, fullpath, attributes) for each supported book.
local function walk(root, include_subfolders, on_file)
    local scan_dirs = { root }
    while #scan_dirs > 0 do
        local new_dirs = {}
        for _, d in ipairs(scan_dirs) do
            local ok, iter, dir_obj = pcall(lfs.dir, d)
            if ok then
                for f in iter, dir_obj do
                    if f ~= "." and f ~= ".." then
                        local fullpath = d == "/" and ("/" .. f) or (d .. "/" .. f)
                        local attr = lfs.attributes(fullpath) or {}
                        if attr.mode == "directory" then
                            if include_subfolders and not SYS_FOLDERS[fullpath]
                                    and (FileChooser.show_hidden or not util.stringStartsWith(f, "."))
                                    and FileChooser:show_dir(f) then
                                table.insert(new_dirs, fullpath)
                            end
                        elseif attr.mode == "file" and not util.stringStartsWith(f, "._")
                                and (FileChooser.show_unsupported or DocumentRegistry:hasProvider(fullpath))
                                and FileChooser:show_file(f) then
                            on_file(f, fullpath, attr)
                        end
                    end
                end
            end
        end
        scan_dirs = new_dirs
    end
end

-- Reading status kept by Kobo's own reader (Nickel). Books read in the native
-- Kobo reader never get a KOReader sidecar file, so KOReader's own status is
-- always "new" for them; Kobo's library database knows the real status.
local KOBO_DB = "/mnt/onboard/.kobo/KoboReader.sqlite"
local KOBO_ROOT = "/mnt/onboard/"
local KOBO_STATUS = { [0] = "new", [1] = "reading", [2] = "complete" } -- ReadStatus column

-- Opens Kobo's database read-only.
-- @return lookup(fullpath) -> { status = "new"|"reading"|"complete"|nil, percent = number|nil } | nil
-- @return close()
-- Returns nothing if the database is not available (not a Kobo, file missing, ...).
local function openKoboStatusDB()
    if lfs.attributes(KOBO_DB, "mode") ~= "file" then
        return nil
    end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then
        return nil
    end
    local ok_open, conn = pcall(SQ3.open, KOBO_DB, "ro")
    if not ok_open or not conn then
        return nil
    end
    local ok_prep, stmt = pcall(conn.prepare, conn,
        "SELECT ReadStatus, ___PercentRead FROM content WHERE ContentID = ?")
    if not ok_prep or not stmt then
        pcall(conn.close, conn)
        return nil
    end
    local function lookup(fullpath)
        if fullpath:sub(1, #KOBO_ROOT) ~= KOBO_ROOT then
            return nil
        end
        -- sideloaded books are keyed by file URI, store-bought ones by their id
        local content_id = fullpath:match("^/mnt/onboard/%.kobo/kepub/([^/]+)$") or ("file://" .. fullpath)
        local ok_row, row = pcall(function()
            stmt:reset()
            stmt:bind(content_id)
            return stmt:step()
        end)
        if not ok_row or not row then
            return nil
        end
        return { status = KOBO_STATUS[tonumber(row[1])], percent = tonumber(row[2]) }
    end
    local function close()
        pcall(stmt.close, stmt)
        pcall(conn.close, conn)
    end
    return lookup, close
end

-- KOReader and Kobo statuses combined: a book counts as having every status
-- either reader reports, ignoring "new" when the other one knows better.
local function effectiveStatuses(koreader_status, kobo_status)
    local set = {}
    if koreader_status and koreader_status ~= "new" then set[koreader_status] = true end
    if kobo_status and kobo_status ~= "new" then set[kobo_status] = true end
    if next(set) == nil then set.new = true end
    return set
end

-- Metadata for a book without opening it (CoverBrowser cache, sidecar, custom metadata).
function GenreFilter:getProps(fullpath)
    return self.ui.bookinfo:getDocProps(fullpath, nil, true) or {}
end

local function hasMetadata(props)
    return props.keywords ~= nil or props.title ~= nil or props.authors ~= nil
end

-- @return files   array of { filename, fullpath, attributes }
-- @return skipped number of books whose metadata is not extracted yet
function GenreFilter:getMatches(path, params)
    local files, skipped = {}, 0
    local need_genres = #params.includes > 0 or #params.excludes > 0
    local need_words = #params.words > 0
    local need_status = params.statuses ~= nil and next(params.statuses) ~= nil
    local kobo_lookup, kobo_close = openKoboStatusDB()
    walk(path, params.include_subfolders, function(f, fullpath, attr)
        local kobo = kobo_lookup and kobo_lookup(fullpath) or nil
        if need_status then
            local set = effectiveStatuses(BookList.getBookStatus(fullpath), kobo and kobo.status)
            local wanted = false
            for status in pairs(params.statuses) do
                if set[status] then
                    wanted = true
                    break
                end
            end
            if not wanted then
                return
            end
        end
        if need_genres or need_words then
            local props = self:getProps(fullpath)
            if not hasMetadata(props) then
                skipped = skipped + 1
                return
            end
            if need_genres then
                local tags = Matcher.parseList(props.keywords, util.stringLower)
                if not Matcher.matches(tags, params.includes, params.excludes, params) then
                    return
                end
            end
            if need_words then
                local haystack = props.title or filemanagerutil.splitFileNameType(fullpath)
                if params.words_in_description and props.description then
                    haystack = haystack .. "\n" .. util.htmlToPlainTextIfHtml(props.description)
                end
                if not Matcher.textMatches(haystack, params.words, util.stringLower) then
                    return
                end
            end
        end
        -- 4th element: Kobo status for the results view (false when unknown)
        table.insert(files, { f, fullpath, attr, kobo or false })
    end)
    if kobo_close then
        kobo_close()
    end
    return files, skipped, kobo_lookup ~= nil
end

-- @return counts  { [normalized tag] = number of books }
-- @return names   { [normalized tag] = display spelling }
-- @return skipped number of books whose metadata is not extracted yet
function GenreFilter:collectTags(path, include_subfolders)
    local counts, names, skipped = {}, {}, 0
    walk(path, include_subfolders, function(_f, fullpath)
        local props = self:getProps(fullpath)
        if not hasMetadata(props) then
            skipped = skipped + 1
            return
        end
        local terms, labels = Matcher.parseList(props.keywords, util.stringLower)
        for i, term in ipairs(terms) do
            counts[term] = (counts[term] or 0) + 1
            if not names[term] then
                names[term] = labels[i]
            end
        end
    end)
    return counts, names, skipped
end

------------------------------------------------------------------------------
-- Search dialog
------------------------------------------------------------------------------

function GenreFilter:onShowGenreFilter()
    local cfg = self:getConfig()
    local dialog

    local function readInput()
        local fields = dialog:getFields()
        cfg.include = fields[1]
        cfg.exclude = fields[2]
        cfg.words = fields[3]
        self:saveConfig(cfg)
    end

    local function startSearch(path)
        readInput()
        local includes = Matcher.parseList(cfg.include, util.stringLower)
        local excludes = Matcher.parseList(cfg.exclude, util.stringLower)
        local words = Matcher.parseWords(cfg.words, util.stringLower)
        if #includes == 0 and #excludes == 0 and #words == 0 and #self:statusNames(cfg) == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Enter genres, words to look for, or choose a reading status."),
            })
            return
        end
        UIManager:close(dialog)
        local params = {
            includes = includes,
            excludes = excludes,
            words = words,
            words_in_description = cfg.words_in_description,
            require_all = cfg.require_all,
            include_subfolders = cfg.include_subfolders,
            mode = cfg.exact and "exact" or "word",
            include_label = cfg.include,
            exclude_label = cfg.exclude,
            words_label = cfg.words,
            statuses = cfg.statuses,
            status_names = self:statusNames(cfg),
            view_mode = cfg.view_mode,
        }
        Trapper:wrap(function()
            self:doSearch(path, params)
        end)
    end

    dialog = MultiInputDialog:new{
        title = _("Genre filter search"),
        fields = {
            {
                description = _("Include genres (comma-separated):"),
                text = cfg.include,
                hint = _("e.g. Romance, Drama"),
            },
            {
                description = _("Exclude genres (comma-separated):"),
                text = cfg.exclude,
                hint = _("e.g. Comedy"),
            },
            {
                description = _("Words in title or description (optional, all must match):"),
                text = cfg.words,
                hint = _("e.g. dragon \"time travel\""),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    -- push the keyboard down when not typing, pull it up again when needed
                    text = _("Keyboard"),
                    callback = function()
                        if dialog:isKeyboardVisible() then
                            dialog:onCloseKeyboard()
                        else
                            dialog:onShowKeyboard()
                        end
                    end,
                },
            },
            {
                {
                    text = _("Browse genres"),
                    callback = function()
                        readInput()
                        self:browseGenres(dialog, self:getHomeFolder() or self:getCurrentFolder())
                    end,
                },
                {
                    text = _("Options"),
                    callback = function()
                        self:showOptionsDialog(cfg)
                    end,
                },
            },
            {
                {
                    text = self:statusButtonText(cfg),
                    id = "gf_status",
                    callback = function()
                        self:showStatusDialog(cfg, function()
                            local btn = dialog.button_table:getButtonById("gf_status")
                            btn:setText(self:statusButtonText(cfg), btn.width)
                            btn:refresh()
                        end)
                    end,
                },
                {
                    text = self:viewButtonText(cfg),
                    id = "gf_view",
                    callback = function()
                        cfg.view_mode = cfg.view_mode % #VIEW_MODES + 1
                        local btn = dialog.button_table:getButtonById("gf_view")
                        btn:setText(self:viewButtonText(cfg), btn.width)
                        btn:refresh()
                    end,
                },
            },
            {
                {
                    text = _("Search home folder"),
                    enabled = G_reader_settings:has("home_dir"),
                    callback = function()
                        startSearch(self:getHomeFolder())
                    end,
                },
                {
                    -- same action as the Return key of the keyboard
                    text = _("Show results"),
                    is_enter_default = true,
                    callback = function()
                        startSearch(self:getCurrentFolder())
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

-- Toggles for the less-used search options.
function GenreFilter:showOptionsDialog(cfg)
    local options = {
        { key = "require_all", text = _("Require all included genres (default: any)") },
        { key = "exact", text = _("Exact tag names only (no partial words)") },
        { key = "words_in_description", text = _("Word search also looks in the description") },
        { key = "include_subfolders", text = _("Include subfolders") },
    }
    local opt_dialog
    local function show()
        local buttons = {}
        for _i, opt in ipairs(options) do
            table.insert(buttons, {
                {
                    text = (cfg[opt.key] and "[x] " or "[  ] ") .. opt.text,
                    callback = function()
                        cfg[opt.key] = not cfg[opt.key]
                        UIManager:close(opt_dialog)
                        show()
                    end,
                },
            })
        end
        table.insert(buttons, {
            {
                text = _("Done"),
                callback = function()
                    UIManager:close(opt_dialog)
                end,
            },
        })
        opt_dialog = ButtonDialog:new{
            title = _("Search options"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(opt_dialog)
    end
    show()
end

------------------------------------------------------------------------------
-- Search + results
------------------------------------------------------------------------------

function GenreFilter:buildQueryLabel(params)
    local parts = {}
    if params.include_label and params.include_label:match("%S") then
        table.insert(parts, T(_("Include: %1"), params.include_label))
    end
    if params.exclude_label and params.exclude_label:match("%S") then
        table.insert(parts, T(_("Exclude: %1"), params.exclude_label))
    end
    if params.words_label and params.words_label:match("%S") then
        table.insert(parts, T(_("Words: %1"), params.words_label))
    end
    if params.status_names and #params.status_names > 0 then
        table.insert(parts, T(_("Status: %1"), table.concat(params.status_names, ", ")))
    end
    return table.concat(parts, "  |  ")
end

-- Translated names of the selected reading statuses, in display order.
function GenreFilter:statusNames(cfg)
    local names = {}
    for _i, status in ipairs(STATUS_ORDER) do
        if cfg.statuses[status] then
            table.insert(names, BookList.getBookStatusString(status))
        end
    end
    return names
end

function GenreFilter:statusButtonText(cfg)
    local names = self:statusNames(cfg)
    if #names == 0 then
        return _("Status: any")
    elseif #names == 1 then
        return T(_("Status: %1"), names[1])
    end
    return T(_("Status: %1 selected"), #names)
end

function GenreFilter:viewButtonText(cfg)
    local mode = VIEW_MODES[cfg.view_mode] or VIEW_MODES[1]
    if mode.rows then
        return T(_("View: covers 2×%1"), mode.rows)
    end
    return _("View: list")
end

-- Multi-select list of reading statuses. `on_change` runs after every toggle.
function GenreFilter:showStatusDialog(cfg, on_change)
    local status_dialog
    local function show()
        local buttons = {}
        for _i, status in ipairs(STATUS_ORDER) do
            table.insert(buttons, {
                {
                    text = (cfg.statuses[status] and "[x] " or "[  ] ") .. BookList.getBookStatusString(status),
                    callback = function()
                        cfg.statuses[status] = not cfg.statuses[status] or nil
                        UIManager:close(status_dialog)
                        on_change()
                        show()
                    end,
                },
            })
        end
        table.insert(buttons, {
            {
                text = _("Clear"),
                callback = function()
                    cfg.statuses = {}
                    UIManager:close(status_dialog)
                    on_change()
                    show()
                end,
            },
            {
                text = _("Done"),
                callback = function()
                    UIManager:close(status_dialog)
                end,
            },
        })
        status_dialog = ButtonDialog:new{
            title = _("Only show books with status:"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(status_dialog)
    end
    show()
end

-- Must be called inside Trapper:wrap().
function GenreFilter:doSearch(path, params)
    local info = InfoMessage:new{ text = _("Searching… (tap to cancel)") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local completed, files, skipped, kobo_ok = Trapper:dismissableRunInSubprocess(function()
        return self:getMatches(path, params)
    end, info)
    if not completed then
        return
    end
    UIManager:close(info)
    files = files or {}
    skipped = skipped or 0

    local label = self:buildQueryLabel(params)
    if #files == 0 then
        self:showNoResults(path, label, skipped)
        return
    end

    -- Build list items exactly like the built-in file search does.
    local fc = self.ui.file_chooser or FileChooser:new{ ui = self.ui }
    local collate = fc:getCollate()
    kobo_status_cache = {}
    for i, v in ipairs(files) do
        local f, fullpath, attributes, kobo = unpack(v)
        if type(kobo) == "table" then
            kobo_status_cache[fullpath] = kobo
        end
        files[i] = fc:getListItem(nil, f, fullpath, attributes, collate)
    end
    local item_table = fc:genItemTable({}, files)

    -- Hand the results to the standard search-results list. This keeps the
    -- CoverBrowser display modes, tap-to-open and long-press book actions.
    FileSearcher.search_path = path
    FileSearcher.search_string = label
    FileSearcher.search_results = item_table
    FileSearcher.search_hash = "genre_filter:" .. label .. ":" .. tostring(os.time())
    self:showResults(params.view_mode)

    if skipped > 0 then
        self:offerExtraction(path, skipped)
    elseif next(params.statuses or {}) ~= nil and not kobo_ok then
        UIManager:show(InfoMessage:new{
            text = _("Kobo's reading-status database was not found, so only KOReader's own reading status was used."),
        })
    end
end

-- Display the results currently held by FileSearcher in the chosen view.
function GenreFilter:showResults(view_mode)
    local searcher = self.ui.filesearcher
    searcher.no_metadata_count = 0 -- we show our own notice instead
    local mode = VIEW_MODES[view_mode] or VIEW_MODES[1]
    if not (mode.rows and self:showCoverResults(mode.rows)) then
        searcher:onShowSearchResults(true)
        if mode.rows then
            UIManager:show(InfoMessage:new{
                text = _("The large-cover view needs the CoverBrowser plugin. Showing the normal list instead."),
            })
        end
    end
end


function GenreFilter:showNoResults(path, label, skipped)
    local text = T(_("No books match:\n%1"), label)
    if skipped > 0 then
        text = text .. "\n\n" .. self:skippedText(skipped)
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        icon = "notice-info",
        ok_text = _("Change filter"),
        ok_callback = function()
            self:onShowGenreFilter()
        end,
    })
end

function GenreFilter:skippedText(skipped)
    return T(N_("1 book was skipped: its metadata has not been extracted yet.",
        "%1 books were skipped: their metadata has not been extracted yet.", skipped), skipped)
end

function GenreFilter:offerExtraction(path, skipped)
    if self.ui.coverbrowser then
        UIManager:show(ConfirmBox:new{
            text = self:skippedText(skipped) .. "\n" .. _("Extract metadata now?"),
            ok_text = _("Extract"),
            ok_callback = function()
                local searcher = self.ui.filesearcher
                if searcher.booklist_menu then
                    searcher.booklist_menu.close_callback()
                end
                self.ui.coverbrowser:extractBooksInDirectory(path)
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            text = self:skippedText(skipped) .. "\n" ..
                _("Enable the CoverBrowser plugin to index metadata for your whole library."),
        })
    end
end

------------------------------------------------------------------------------
-- Large-cover results view
------------------------------------------------------------------------------

-- CoverBrowser's helper modules are only on package.path while that plugin
-- loads, so load them explicitly from its folder when needed.
function GenreFilter:requireFromCoverBrowser(name)
    if package.loaded[name] then
        return package.loaded[name]
    end
    local cb = self.ui.coverbrowser
    if not (cb and cb.path) then
        return nil
    end
    local old_path = package.path
    package.path = cb.path .. "/?.lua;" .. old_path
    local ok, mod = pcall(require, name)
    package.path = old_path
    return ok and mod or nil
end

-- Loads the gallery module (needs CoverBrowser's cover cache and CoverMenu).
-- @return gallery methods table, or nil if CoverBrowser is not available
function GenreFilter:getGallery()
    if self.gallery then
        return self.gallery
    end
    local BookInfoManager = self:requireFromCoverBrowser("bookinfomanager")
    local CoverMenu = self:requireFromCoverBrowser("covermenu")
    if not (BookInfoManager and CoverMenu) then
        return nil
    end
    local dir = PLUGIN_DIR or self.path
    local ok, factory = pcall(dofile, dir .. "/genre_filter_gallery.lua")
    if not ok or type(factory) ~= "function" then
        logger.warn("genre_filter: cannot load gallery module:", factory)
        return nil
    end
    local ok2, gallery = pcall(factory, {
        BookInfoManager = BookInfoManager,
        Matcher = Matcher,
        getKoboStatus = function(file) return kobo_status_cache[file] end,
    })
    if not ok2 then
        logger.warn("genre_filter: cannot build gallery:", gallery)
        return nil
    end
    self.gallery = gallery
    self.CoverMenu = CoverMenu
    return gallery
end

-- Long-press in the gallery: quick actions, with the full standard dialog behind "More".
function GenreFilter:onGalleryHold(menu, item)
    local searcher = self.ui.filesearcher
    local file = item.path
    if searcher.selected_files or not file or lfs.attributes(file) == nil then
        return true
    end
    local hold_dialog
    hold_dialog = ButtonDialog:new{
        title = item.text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Synopsis & tags"),
                    callback = function()
                        UIManager:close(hold_dialog)
                        showSynopsis(file)
                    end,
                },
                {
                    text = _("Open"),
                    callback = function()
                        UIManager:close(hold_dialog)
                        FileSearcher.onMenuSelect(menu, item)
                    end,
                },
            },
            {
                {
                    text = _("More actions…"),
                    callback = function()
                        UIManager:close(hold_dialog)
                        FileSearcher.onMenuHold(menu, item)
                    end,
                },
            },
        },
    }
    UIManager:show(hold_dialog)
    return true
end

-- Same as FileSearcher:onShowSearchResults(), but with our two-column cover
-- gallery (`rows` rows per page: fewer rows = bigger covers). Reuses the
-- FileSearcher handlers, so tap-to-open, select mode and the "More actions"
-- dialog behave exactly like the standard results list.
-- @return boolean true if the view was shown
function GenreFilter:showCoverResults(rows)
    local gallery = self:getGallery()
    if not gallery then
        return false
    end
    local CoverMenu = self.CoverMenu
    local searcher = self.ui.filesearcher
    local menu = BookList:new{
        name = "filesearcher", -- CoverBrowser/FileSearcher code keys off this name
        subtitle = T(_("Query: %1"), FileSearcher.search_string),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() searcher:setSelectMode() end,
        onMenuSelect = FileSearcher.onMenuSelect,
        onMenuHold = function(menu_self, item)
            return self:onGalleryHold(menu_self, item)
        end,
        ui = self.ui,
        _manager = searcher,
        _recreate_func = function() self:showCoverResults(rows) end,
        gallery_cols = 2,
        gallery_rows = rows,
    }
    searcher.booklist_menu = menu
    menu.close_callback = function()
        searcher:refreshFileManager()
        UIManager:close(menu)
        searcher.booklist_menu = nil
        if searcher.selected_files then
            searcher.selected_files = nil
            for _i, item in ipairs(FileSearcher.search_results) do
                item.dim = nil
            end
        end
    end

    -- Install the gallery layout (what CoverBrowser's display-mode hook does for its own modes).
    menu._coverbrowser_overridden = true -- stop the hook from re-applying the user's own mode
    menu.updateItems = CoverMenu.updateItems
    menu.onCloseWidget = CoverMenu.onCloseWidget
    menu._recalculateDimen = gallery._recalculateDimen
    menu._updateItemsBuildUI = gallery._updateItemsBuildUI
    attachBackToFilterButton(menu)

    searcher:updateItemTable(FileSearcher.search_results)
    UIManager:show(menu)
    return true
end

------------------------------------------------------------------------------
-- Genre browser: pick genres from the ones that actually exist in the library
------------------------------------------------------------------------------

function GenreFilter:browseGenres(dialog, path)
    Trapper:wrap(function()
        local info = InfoMessage:new{ text = _("Reading genres… (tap to cancel)") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local include_subfolders = self:getConfig().include_subfolders
        local completed, counts, names, skipped = Trapper:dismissableRunInSubprocess(function()
            return self:collectTags(path, include_subfolders)
        end, info)
        if not completed then
            return
        end
        UIManager:close(info)
        counts = counts or {}
        if next(counts) == nil then
            UIManager:show(InfoMessage:new{
                text = _("No genres found.") .. "\n" ..
                    (skipped and skipped > 0 and self:skippedText(skipped) or ""),
            })
            return
        end
        self:showGenreList(dialog, counts, names or {})
    end)
end

function GenreFilter:showGenreList(dialog, counts, names)
    local items = {}
    for key, count in pairs(counts) do
        table.insert(items, {
            key = key,
            label = names[key] or key,
            count = count,
            text = names[key] or key,
            mandatory = tostring(count),
        })
    end
    table.sort(items, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.key < b.key
    end)

    local menu

    local function termSet(field)
        local set = {}
        for _, term in ipairs((Matcher.parseList(field:getText(), util.stringLower))) do
            set[term] = true
        end
        return set
    end

    local function refreshMarks()
        local inc = termSet(dialog.input_fields[1])
        local exc = termSet(dialog.input_fields[2])
        for _, item in ipairs(items) do
            local mark = inc[item.key] and "[+] " or (exc[item.key] and "[-] " or "")
            item.text = mark .. item.label
        end
        menu:updateItems(1, true)
    end

    -- Toggle `item` in the given input field; returns true if it was added.
    local function toggleInField(field, item, remove_only)
        local terms, labels = Matcher.parseList(field:getText(), util.stringLower)
        local out, found = {}, false
        for i, term in ipairs(terms) do
            if term == item.key then
                found = true
            else
                table.insert(out, labels[i])
            end
        end
        local added = not found and not remove_only
        if added then
            table.insert(out, item.label)
        end
        field:setText(table.concat(out, ", "))
        return added
    end

    local function pick(target_idx, other_idx, item)
        local added = toggleInField(dialog.input_fields[target_idx], item)
        if added then -- a genre cannot be both included and excluded
            toggleInField(dialog.input_fields[other_idx], item, true)
        end
        refreshMarks()
    end

    dialog:onCloseKeyboard()
    menu = Menu:new{
        title = T(_("Genres (%1)"), #items),
        subtitle = _("Tap: include  |  Hold: exclude"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_menu, item)
            pick(1, 2, item)
            return true
        end,
        onMenuHold = function(_menu, item)
            pick(2, 1, item)
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
    refreshMarks()
end

return GenreFilter
