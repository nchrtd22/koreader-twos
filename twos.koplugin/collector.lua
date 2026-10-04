--[[--
Collects highlights from the current document or from reading history,
and converts them into NewTwos "thing" items.

Mirrors the data extraction patterns of plugins/exporter.koplugin/clip.lua.
@module koplugin.twos.collector
--]]--

local BookList = require("ui/widget/booklist")
local ReadHistory = require("readhistory")

local Collector = {}

function Collector:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Parse a KOReader datetime "YYYY-MM-DD HH:MM:SS" into a Unix timestamp.
-- @return number|nil
function Collector:parseDateTime(datetime)
    if not datetime then return nil end
    local Y, M, D, h, m, s = datetime:match("(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)")
    if not Y then return nil end
    return os.time{ year = tonumber(Y), month = tonumber(M), day = tonumber(D),
                    hour = tonumber(h), min = tonumber(m), sec = tonumber(s) }
end

--- Extract title and author from a file path and doc_props.
function Collector:getTitleAuthor(filepath, props)
    local doc_name = filepath:match(".*/(.+)") or filepath
    local title, author = self:parseTitleFromPath(doc_name)
    if props then
        if props.title and props.title ~= "" then title = props.title end
        if props.authors and props.authors ~= "" then author = props.authors end
    end
    return title, author
end

--- Best-effort parse of "Title (Author)" / "Title - Author" / bare filename.
-- The dash form requires spaces around the dash, so hyphenated titles
-- ("Twenty-Thousand Leagues") are not split into a bogus author.
-- @return title string, author string|nil
function Collector:parseTitleFromPath(name)
    name = name:gsub("%.[^.]+$", "")
    local title, author = name:match("^(.-)%s*%(([^)]+)%)$")
    if title then return title, author end
    title, author = name:match("^(.-)%s+%-%s+(.+)$")
    if title then return title, author end
    return name, nil
end

--- Read modern unified annotations into the entries list.
function Collector:parseAnnotations(annotations, entries)
    for __, item in ipairs(annotations) do
        if item.text and item.text ~= "" then
            entries[#entries + 1] = {
                page    = item.pageref or item.pageno,
                time    = self:parseDateTime(item.datetime),
                text    = item.text,
                note    = item.note,
                chapter = item.chapter,
            }
        end
    end
end

--- Read legacy highlight/bookmarks tables into the entries list.
function Collector:parseHighlight(highlights, bookmarks, entries)
    local note_by_time = {}
    if bookmarks then
        for __, bm in ipairs(bookmarks) do
            if bm.datetime then
                note_by_time[bm.datetime] = bm.notes or bm.text
            end
        end
    end
    for page, highlights_on_page in pairs(highlights) do
        if type(highlights_on_page) == "table" then
            for __, hl in ipairs(highlights_on_page) do
                if hl.text and hl.text ~= "" then
                    entries[#entries + 1] = {
                        page = tonumber(page) or page,
                        time = self:parseDateTime(hl.datetime),
                        text = hl.text,
                        note = hl.datetime and note_by_time[hl.datetime] or nil,
                        chapter = nil,
                    }
                end
            end
        end
    end
end

--- Collect highlights from the currently open document.
-- @return book table|nil (with .entries array)
function Collector:fromCurrentDoc()
    if not self.ui or not self.ui.document then return nil end
    local file = self.ui.document.file
    local props = self.ui.doc_props
    local title, author = self:getTitleAuthor(file, props)
    local book = {
        file    = file,
        title   = title,
        author  = author,
        pages   = self.ui.document.info and self.ui.document.info.pages or nil,
        entries = {},
    }
    if self.ui.annotation and self.ui.annotation.annotations then
        self:parseAnnotations(self.ui.annotation.annotations, book.entries)
    end
    return book
end

--- Collect highlights from a single book file (via sidecar settings).
-- @return book table|nil
function Collector:fromBookFile(doc_path)
    local doc_settings = BookList.getDocSettings(doc_path)
    if not doc_settings then return nil end

    local annotations = doc_settings:readSetting("annotations")
    local highlights, bookmarks
    if annotations == nil then
        highlights = doc_settings:readSetting("highlight")
        if highlights == nil then return nil end
        bookmarks = doc_settings:readSetting("bookmarks")
    end

    local props = doc_settings:readSetting("doc_props")
    local title, author = self:getTitleAuthor(doc_path, props)
    local book = {
        file    = doc_path,
        title   = title,
        author  = author,
        pages   = doc_settings:readSetting("doc_pages"),
        entries = {},
    }
    if annotations then
        self:parseAnnotations(annotations, book.entries)
    else
        self:parseHighlight(highlights, bookmarks, book.entries)
    end
    return book
end

--- Collect highlights from all books in reading history.
-- @return array of book tables (only those with at least one highlight)
function Collector:fromHistory()
    local books = {}
    for __, item in ipairs(ReadHistory.hist) do
        if not item.dim and BookList.hasBookBeenOpened(item.file) then
            local book = self:fromBookFile(item.file)
            if book and #book.entries > 0 then
                books[#books + 1] = book
            end
        end
    end
    return books
end

--- Convert a book's entries into NewTwos bulk-create item objects.
-- @param book table from fromCurrentDoc/fromHistory
-- @param settings table with as_quote, backdate
-- @return array of thing objects
function Collector:toTwosItems(book, settings)
    local items = {}
    for __, entry in ipairs(book.entries) do
        local created
        if settings.backdate and entry.time then
            created = os.date("!%Y-%m-%dT%TZ", entry.time)
        end
        local has_note = entry.note and entry.note ~= ""
        local highlight_tags = { "highlights" }
        if has_note then
            highlight_tags[#highlight_tags + 1] = "booknotes"
        end
        local highlight_item = {
            text   = entry.text,
            type   = "note",
            tags   = highlight_tags,
            tabs   = 0,
        }
        if settings.as_quote then
            highlight_item.quote = true
        end
        if created then
            highlight_item.created = created
        end
        items[#items + 1] = highlight_item

        if has_note then
            local note_item = {
                text   = entry.note,
                type   = "note",
                tags   = { "booknotes" },
                tabs   = 1,
                quote  = false,
            }
            if created then
                note_item.created = created
            end
            items[#items + 1] = note_item
        end
    end
    return items
end

return Collector
