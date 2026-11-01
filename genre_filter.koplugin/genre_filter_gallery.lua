--[[--
Two-column cover gallery for the Genre filter results.

Each cell shows: large cover | title, author(s), reading status, tags.
It plugs into CoverBrowser's generic CoverMenu (which handles background
cover extraction and page drawing) the same way CoverBrowser's own
ListMenu / MosaicMenu do, by providing `_recalculateDimen` and
`_updateItemsBuildUI` plus an item widget with an `update()` method.

This file is loaded lazily with dofile() by main.lua (CoverBrowser's modules
are not on package.path at plugin-load time), and receives them as `deps`:
  deps.BookInfoManager  CoverBrowser's metadata/cover cache
  deps.Matcher          genre_filter_matcher module
  deps.getKoboStatus    function(path) -> { status, percent } | nil (Kobo reader status)
--]]--

return function(deps)
    local BookInfoManager = deps.BookInfoManager
    local Matcher = deps.Matcher

    local BD = require("ui/bidi")
    local Blitbuffer = require("ffi/blitbuffer")
    local BookList = require("ui/widget/booklist")
    local Device = require("device")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local LineWidget = require("ui/widget/linewidget")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local UnderlineContainer = require("ui/widget/container/underlinecontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local util = require("util")
    local getMenuText = require("ui/widget/menu").getMenuText

    local Screen = Device.screen

    ----------------------------------------------------------------------
    -- One cell of the gallery
    ----------------------------------------------------------------------

    local GalleryItem = InputContainer:extend{
        entry = nil,
        text = nil,
        show_parent = nil,
        dimen = nil,
        menu = nil,
        init_done = false,
        bookinfo_found = false,
        cover_specs = nil,
    }

    function GalleryItem:init()
        self.filepath = self.entry.file or self.entry.path

        self.ges_events = {
            TapSelect = {
                GestureRange:new{ ges = "tap", range = self.dimen },
            },
            HoldSelect = {
                GestureRange:new{ ges = "hold", range = self.dimen },
            },
        }

        self.underline_h = 1
        self._underline_container = UnderlineContainer:new{
            vertical_align = "top",
            padding = 0,
            dimen = Geom:new{ w = self.width, h = self.height },
            linesize = self.underline_h,
        }
        self[1] = self._underline_container

        self:update()
        self.init_done = true
    end

    -- Tags for display, e.g. "Romance, Drama". nil when the book has none.
    local function tagsText(keywords)
        local _terms, labels = Matcher.parseList(keywords, util.stringLower)
        if #labels == 0 then
            return nil
        end
        return table.concat(labels, ", ")
    end

    function GalleryItem:update()
        local dimen = Geom:new{ w = self.width, h = self.height - 2 * self.underline_h }
        local pad = Screen:scaleBySize(8)
        local border_size = Size.border.thin
        local inner_h = dimen.h - 2 * pad
        local min_text_h = Screen:scaleBySize(44)

        -- Large cover: as tall as the cell allows, at most ~42% of its width.
        local max_img_h = inner_h - 2 * border_size
        local max_img_w = math.floor(dimen.w * 0.42) - 2 * border_size
        local cover_specs = { max_cover_w = max_img_w, max_cover_h = max_img_h }
        self.menu.cover_specs = cover_specs -- lets the menu batch-extract covers at this size

        local widget

        local bookinfo = BookInfoManager:getBookInfo(self.filepath, true)
        if bookinfo then
            if bookinfo.cover_fetched then
                if bookinfo.has_cover and not self.menu.no_refresh_covers then
                    if BookInfoManager.isCachedCoverInvalid(bookinfo, cover_specs) then
                        -- cached thumbnail too small for this size: force a new extraction
                        if bookinfo.cover_bb then
                            bookinfo.cover_bb:free()
                        end
                        bookinfo = nil
                    end
                end
            else
                bookinfo = nil -- cover not fetched yet: do as if not found
            end
        end

        local book_info = self.menu.getBookInfo(self.filepath)
        self.been_opened = book_info.been_opened

        if bookinfo then
            self.bookinfo_found = true
            local cover_bb_used = false

            -- Cover (or a placeholder box when the book has none)
            local wleft
            if bookinfo.has_cover and not bookinfo.ignore_cover then
                cover_bb_used = true
                local _cw, _ch, scale_factor = BookInfoManager.getCachedCoverSize(
                    bookinfo.cover_w, bookinfo.cover_h, max_img_w, max_img_h)
                local wimage = ImageWidget:new{
                    image = bookinfo.cover_bb,
                    scale_factor = scale_factor,
                }
                wimage:_render()
                local image_size = wimage:getSize()
                wleft = FrameContainer:new{
                    width = image_size.w + 2 * border_size,
                    height = image_size.h + 2 * border_size,
                    margin = 0,
                    padding = 0,
                    bordersize = border_size,
                    wimage,
                }
                self.menu._has_cover_images = true
                self._has_cover_image = true
            else
                local fake_w = math.floor(max_img_h * 0.66)
                wleft = FrameContainer:new{
                    width = fake_w + 2 * border_size,
                    height = max_img_h + 2 * border_size,
                    margin = 0,
                    padding = 0,
                    bordersize = border_size,
                    TextWidget:new{
                        text = "⛶",
                        face = Font:getFace("cfont", 24),
                    },
                }
            end
            if bookinfo.cover_bb and not cover_bb_used then
                bookinfo.cover_bb:free()
            end
            local wleft_w = wleft:getSize().w

            -- Text column: title, authors, status, tags
            local text_w = dimen.w - wleft_w - 3 * pad
            local title, authors, keywords
            if not bookinfo.ignore_meta then
                title, authors, keywords = bookinfo.title, bookinfo.authors, bookinfo.keywords
            end
            if not title or title == "" then
                title = filemanagerutil.splitFileNameType(self.filepath)
            end
            if authors then
                authors = authors:gsub("\n", ", ")
            end

            local vg = VerticalGroup:new{ align = "left" }
            local used = 0
            local function add(w, gap)
                table.insert(vg, w)
                used = used + w:getSize().h
                if gap then
                    table.insert(vg, VerticalSpan:new{ width = gap })
                    used = used + gap
                end
            end
            local gap = Screen:scaleBySize(4)

            add(TextBoxWidget:new{
                text = BD.auto(title),
                face = Font:getFace("cfont", 20),
                bold = true,
                width = text_w,
                height = math.max(min_text_h, math.floor(inner_h * 0.32)),
                height_adjust = true,
                height_overflow_show_ellipsis = true,
            }, gap)

            if authors and authors ~= "" then
                add(TextBoxWidget:new{
                    text = BD.auto(authors),
                    face = Font:getFace("cfont", 16),
                    width = text_w,
                    height = math.max(min_text_h, math.floor(inner_h * 0.16)),
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                }, gap)
            end

            -- Reading status: KOReader's own and/or Kobo's native reader's
            -- (books read in the Kobo reader have no KOReader status).
            local kr_status = book_info.been_opened and book_info.status or nil
            local kobo = deps.getKoboStatus and deps.getKoboStatus(self.filepath) or nil
            local kobo_status = kobo and kobo.status or nil
            local status_key
            for _i, key in ipairs({ "complete", "reading", "abandoned" }) do
                if kr_status == key or kobo_status == key then
                    status_key = key
                    break
                end
            end
            if status_key then
                local status = BookList.getBookStatusString(status_key, false, true)
                if status then
                    if status_key == "reading" then
                        local percent
                        if kr_status == "reading" and book_info.percent_finished then
                            percent = book_info.percent_finished * 100
                        elseif kobo_status == "reading" and kobo.percent then
                            percent = kobo.percent
                        end
                        if percent then
                            status = status .. " · " .. math.floor(percent + 0.5) .. "%"
                        end
                    end
                    add(TextWidget:new{
                        text = status,
                        face = Font:getFace("cfont", 14),
                        max_width = text_w,
                    }, gap)
                end
            end

            -- Tags always shown, using whatever height is left
            local tags = tagsText(keywords)
            if tags then
                local remaining = inner_h - used
                if remaining >= Screen:scaleBySize(22) then
                    add(TextBoxWidget:new{
                        text = BD.auto(tags),
                        face = Font:getFace("cfont", 14),
                        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                        width = text_w,
                        height = remaining,
                        height_adjust = true,
                        height_overflow_show_ellipsis = true,
                    })
                end
            end

            widget = LeftContainer:new{
                dimen = dimen:copy(),
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = pad },
                    wleft,
                    HorizontalSpan:new{ width = pad },
                    vg,
                },
            }
        else
            -- Not in the cache yet: show the filename now, CoverMenu extracts
            -- the info in the background and calls update() again.
            self.bookinfo_found = false
            self.cover_specs = cover_specs
            widget = LeftContainer:new{
                dimen = dimen:copy(),
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = pad },
                    TextBoxWidget:new{
                        text = BD.filename(self.text) .. " …",
                        face = Font:getFace("cfont", 18),
                        width = dimen.w - 2 * pad,
                        height = inner_h,
                        height_adjust = true,
                        height_overflow_show_ellipsis = true,
                    },
                },
            }
        end

        if self._underline_container[1] then
            self._underline_container[1]:free()
        end
        self._underline_container[1] = VerticalGroup:new{
            VerticalSpan:new{ width = self.underline_h },
            widget,
        }
    end

    function GalleryItem:paintTo(bb, x, y)
        InputContainer.paintTo(self, bb, x, y)
    end

    function GalleryItem:onFocus()
        self._underline_container.color = Blitbuffer.COLOR_BLACK
        return true
    end

    function GalleryItem:onUnfocus()
        self._underline_container.color = Blitbuffer.COLOR_WHITE
        return true
    end

    function GalleryItem:onTapSelect()
        self.menu:onMenuSelect(self.entry)
        return true
    end

    function GalleryItem:onHoldSelect()
        self.menu:onMenuHold(self.entry)
        return true
    end

    ----------------------------------------------------------------------
    -- Menu methods (installed on a BookList instance by main.lua)
    -- `self` is the menu. Set menu.gallery_cols / menu.gallery_rows first.
    ----------------------------------------------------------------------

    local Gallery = {}

    function Gallery:_recalculateDimen()
        self.portrait_mode = Screen:getWidth() <= Screen:getHeight()
        self.others_height = 0
        if self.title_bar then
            if not self.is_borderless then
                self.others_height = self.others_height + 2
            end
            if not self.no_title then
                self.others_height = self.others_height + self.title_bar.dimen.h
            end
            if self.page_info then
                self.others_height = self.others_height + self.page_info:getSize().h
            end
        end
        local available_height = self.inner_dimen.h - self.others_height - Size.line.thin

        local cols = self.gallery_cols or 2
        local rows = self.gallery_rows or 3
        self.nb_cols = cols
        self.perpage = cols * rows

        self.page_num = math.ceil(#self.item_table / self.perpage)
        if self.page_num > 0 and self.page > self.page_num then
            self.page = self.page_num
        end

        self.item_height = math.floor(available_height / rows) - Size.line.thin
        self.item_width = math.floor(self.inner_dimen.w / cols)
        self.item_dimen = Geom:new{
            x = 0, y = 0,
            w = self.item_width,
            h = self.item_height,
        }
    end

    function Gallery:_updateItemsBuildUI()
        local line_widget = LineWidget:new{
            dimen = Geom:new{ w = self.width or self.screen_w, h = Size.line.thin },
            background = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.item_group, line_widget)

        local idx_offset = (self.page - 1) * self.perpage
        local select_number
        local cur_row, line_layout
        local function closeRow()
            if cur_row then
                table.insert(self.item_group, cur_row)
                table.insert(self.item_group, line_widget)
                table.insert(self.layout, line_layout)
            end
        end

        for idx = 1, self.perpage do
            local index = idx_offset + idx
            local entry = self.item_table[index]
            if entry == nil then break end
            entry.idx = index
            if index == self.itemnumber then -- focused item
                select_number = idx
            end

            if idx % self.nb_cols == 1 or self.nb_cols == 1 then -- new row
                closeRow()
                cur_row = HorizontalGroup:new{ align = "top" }
                line_layout = {}
            end

            local item_tmp = GalleryItem:new{
                height = self.item_height,
                width = self.item_width,
                entry = entry,
                text = getMenuText(entry),
                show_parent = self.show_parent,
                dimen = self.item_dimen:copy(),
                menu = self,
            }
            table.insert(cur_row, item_tmp)
            table.insert(line_layout, item_tmp) -- for the focus manager

            if not item_tmp.bookinfo_found then
                table.insert(self.items_to_update, item_tmp)
            end
        end
        closeRow()
        return select_number
    end

    return Gallery
end
