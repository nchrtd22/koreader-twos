--[[--
Export highlights to NewTwos via the public API.

Each book becomes a NewTwos list (named after the book title); each
highlight becomes a "thing" of type note, styled as a blockquote, uploaded
in bulk with skip_duplicates so re-runs are safe.

API docs: https://writethingsdown.com/api/v1/openapi.json
@module koplugin.twos
--]]--

local DataStorage   = require("datastorage")
local Dispatcher    = require("dispatcher")
local ConfirmBox    = require("ui/widget/confirmbox")
local InfoMessage   = require("ui/widget/infomessage")
local InputDialog   = require("ui/widget/inputdialog")
local LuaSettings   = require("luasettings")
local NetworkMgr    = require("ui/network/manager")
local Notification  = require("ui/widget/notification")
local UIManager     = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger        = require("logger")
local T             = require("ffi/util").template
local _             = require("gettext")

local TwosAPI     = require("twosapi")
local Collector   = require("collector")

local Twos = WidgetContainer:extend{
    name = "twos",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/twos.lua",
}

Twos.default_settings = {
    api_key       = nil,
    emoji         = "📖",
    as_quote      = true,
    backdate      = true,
}

function Twos:init()
    self:loadSettings()
    self.collector = Collector:new{ ui = self.ui }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Twos:loadSettings()
    if not Twos.settings_obj then
        Twos.settings_obj = LuaSettings:open(self.settings_file)
    end
    self.settings = Twos.settings_obj:readSetting("settings", {})
    for k, v in pairs(Twos.default_settings) do
        if self.settings[k] == nil then
            self.settings[k] = v
        end
    end
end

function Twos:onFlushSettings()
    if self.updated then
        Twos.settings_obj:saveSetting("settings", self.settings)
        Twos.settings_obj:flush()
        self.updated = nil
    end
end

function Twos:onDispatcherRegisterActions()
    Dispatcher:registerAction("twos_export_now",
        { category = "none", event = "TwosExportNow",
          title = _("Export current book to NewTwos"), reader = true })
    Dispatcher:registerAction("twos_export_all",
        { category = "none", event = "TwosExportAll",
          title = _("Export all books to NewTwos"), reader = true, filemanager = true })
end

function Twos:hasApiKey()
    return self.settings.api_key and self.settings.api_key ~= ""
end

function Twos:addToMainMenu(menu_items)
    menu_items.twos_export = {
        text = _("Export to NewTwos"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Export this book's highlights"),
                enabled_func = function()
                    return self:hasApiKey()
                        and self.ui.document ~= nil
                        and self.ui.annotation ~= nil
                        and self.ui.annotation:hasAnnotations()
                end,
                callback = function() self:exportCurrentBook(true) end,
            },
            {
                text = _("Export all books' highlights"),
                enabled_func = function() return self:hasApiKey() end,
                callback = function() self:exportAllBooks(true) end,
                separator = true,
            },
            {
                text = _("Test connection"),
                enabled_func = function() return self:hasApiKey() end,
                callback = function() self:testConnection() end,
                separator = true,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Set API key"),
                        keep_menu_open = true,
                        help_text = _("Create a key in NewTwos: Settings → API Keys. Required scopes: write:lists, write:things, search, read:lists."),
                        callback = function()
                            local dlg
                            dlg = InputDialog:new{
                                title = _("NewTwos API key"),
                                input = self.settings.api_key or "",
                                text_type = "password",
                                description = _("Create a key in NewTwos: Settings → API Keys. Required scopes: write:lists, write:things, search, read:lists."),
                                buttons = {
                                    { { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
                                      { text = _("Set"), callback = function()
                                          self.settings.api_key = dlg:getInputText()
                                          self.updated = true
                                          UIManager:close(dlg)
                                      end } },
                                },
                            }
                            UIManager:show(dlg)
                            dlg:onShowKeyboard()
                        end,
                    },
                    {
                        text_func = function()
                            local current = self.settings.emoji or "📖"
                            local label = _("None")
                            if current ~= "" then
                                for __, entry in ipairs({
                                    { "📖", _("Open book") },
                                    { "📕", _("Book") },
                                    { "📚", _("Books") },
                                    { "📝", _("Memo") },
                                    { "🔖", _("Bookmark") },
                                    { "✏️", _("Pencil") },
                                }) do
                                    if entry[1] == current then
                                        label = entry[2]
                                        break
                                    end
                                end
                            end
                            return T(_("List emoji (%1)"), label)
                        end,
                        sub_item_table = (function()
                            local emojis = {
                                { "📖", _("Open book") },
                                { "📕", _("Book") },
                                { "📚", _("Books") },
                                { "📝", _("Memo") },
                                { "🔖", _("Bookmark") },
                                { "✏️", _("Pencil") },
                            }
                            local items = {}
                            for __, entry in ipairs(emojis) do
                                local emoji, label = entry[1], entry[2]
                                items[#items + 1] = {
                                    text = label,
                                    checked_func = function()
                                        return self.settings.emoji == emoji
                                    end,
                                    check_callback_updates_menu = true,
                                    callback = function()
                                        self.settings.emoji = emoji
                                        self.updated = true
                                    end,
                                }
                            end
                            items[#items + 1] = {
                                text = _("None"),
                                checked_func = function()
                                    return self.settings.emoji == ""
                                end,
                                check_callback_updates_menu = true,
                                callback = function()
                                    self.settings.emoji = ""
                                    self.updated = true
                                end,
                                separator = true,
                            }
                            return items
                        end)(),
                    },
                    {
                        text = _("Style highlights as quotes"),
                        checked_func = function() return self.settings.as_quote end,
                        check_callback_updates_menu = true,
                        callback = function()
                            self.settings.as_quote = not self.settings.as_quote
                            self.updated = true
                        end,
                        separator = true,
                    },
                    {
                        text = _("Backdate to highlight time"),
                        checked_func = function() return self.settings.backdate end,
                        check_callback_updates_menu = true,
                        callback = function()
                            self.settings.backdate = not self.settings.backdate
                            self.updated = true
                        end,
                        separator = true,
                    },
                    {
                        text = _("Clear API key"),
                        callback = function()
                            UIManager:show(ConfirmBox:new{
                                text = _("Clear the stored NewTwos API key?"),
                                ok_text = _("Clear"),
                                ok_callback = function()
                                    self.settings.api_key = nil
                                    self.updated = true
                                    Notification:notify(_("API key cleared"))
                                end,
                            })
                        end,
                    },
                },
            },
        },
    }
end

function Twos:testConnection()
    if not self:hasApiKey() then
        UIManager:show(InfoMessage:new{ text = _("Please set an API key first."), timeout = 3 })
        return
    end
    if NetworkMgr:willRerunWhenOnline(function() self:testConnection() end) then return end
    UIManager:show(InfoMessage:new{ text = _("Testing connection…"), timeout = 1 })
    UIManager:nextTick(function()
        local api = TwosAPI:new{ api_key = self.settings.api_key }
        local p_ok, ok, info = pcall(function()
            return api:testConnection()
        end)
        if not p_ok then
            logger.warn("Twos testConnection crashed:", ok)
            UIManager:show(InfoMessage:new{
                text = _("Connection failed: unexpected error (see logs)"),
            })
            return
        end
        if ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Connected. Found %1 tags."), info or 0),
                timeout = 3,
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Connection failed: %1"), info or "unknown error"),
            })
        end
    end)
end

function Twos:exportCurrentBook(interactive)
    if not self:hasApiKey() then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Please set an API key first."), timeout = 3 })
        end
        return
    end
    if not self.ui.annotation or not self.ui.annotation:hasAnnotations() then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("No highlights in this book."), timeout = 3 })
        end
        return
    end
    self.ui.annotation:updatePageNumbers(true)
    if NetworkMgr:willRerunWhenOnline(function() self:exportCurrentBook(interactive) end) then return end
    local book = self.collector:fromCurrentDoc()
    if not book or #book.entries == 0 then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("No highlights in this book."), timeout = 3 })
        end
        return
    end
    UIManager:show(InfoMessage:new{ text = _("Sending highlights to NewTwos…"), timeout = 1 })
    UIManager:nextTick(function()
        self:sendBooks({ book }, interactive)
    end)
end

function Twos:exportAllBooks(interactive)
    if not self:hasApiKey() then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Please set an API key first."), timeout = 3 })
        end
        return
    end
    if NetworkMgr:willRerunWhenOnline(function() self:exportAllBooks(interactive) end) then return end
    local books = self.collector:fromHistory()

    -- Merge in the currently open document's live annotations, which may
    -- not have been flushed to the sidecar file on disk yet.
    if self.ui and self.ui.document and self.ui.annotation then
        local current_file = self.ui.document.file
        local live_book = self.collector:fromCurrentDoc()
        if live_book and #live_book.entries > 0 then
            local found = false
            for __, book in ipairs(books) do
                if book.file == current_file then
                    book.entries = live_book.entries
                    found = true
                    break
                end
            end
            if not found then
                table.insert(books, 1, live_book)
            end
        end
    end

    if #books == 0 then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("No books with highlights found in history."), timeout = 3 })
        end
        return
    end
    UIManager:show(InfoMessage:new{ text = _("Sending highlights to NewTwos…"), timeout = 1 })
    UIManager:nextTick(function()
        self:sendBooks(books, interactive)
    end)
end

function Twos:sendBooks(books, interactive)
    local api = TwosAPI:new{ api_key = self.settings.api_key }
    local results = {}
    local total_created, total_skipped = 0, 0

    local p_ok, p_err = pcall(function()
        for __, book in ipairs(books) do
            if api.rate_limited then break end
            local list_title = book.title
            if book.author and book.author ~= "" then
                list_title = book.title .. " - " .. book.author
            end
            local list_id, err = api:findOrCreateList(list_title, self.settings.emoji or "")
            if not list_id then
                results[#results + 1] = T(_("Failed on '%1': %2"), book.title, err or "unknown error")
            else
                local items = self.collector:toTwosItems(book, self.settings)
                if #items == 0 then
                    results[#results + 1] = T(_("%1: no highlights"), book.title)
                else
                    local ok, created, skipped, serr = api:bulkCreateThings(list_id, items, true)
                    if ok then
                        total_created = total_created + (created or 0)
                        total_skipped = total_skipped + (skipped or 0)
                        results[#results + 1] = T(_("%1: %2 sent, %3 skipped"),
                            book.title, created or 0, skipped or 0)
                    else
                        results[#results + 1] = T(_("Failed on '%1': %2"),
                            book.title, serr or "unknown error")
                    end
                end
            end
        end
    end)

    if not p_ok then
        logger.warn("Twos sendBooks crashed:", p_err)
        results[#results + 1] = _("Unexpected error (see logs)")
    end

    local rate_limited = api.rate_limited

    local summary = T(_("Sent %1, skipped %2 across %3 book(s)."),
        total_created, total_skipped, #books)
    if rate_limited then
        summary = summary .. "\n" ..
            _("Stopped early: NewTwos rate limit (1000/hour). Please wait and retry.")
    end

    if interactive then
        UIManager:show(InfoMessage:new{
            text = summary .. "\n\n" .. table.concat(results, "\n"),
        })
    else
        Notification:notify(summary)
    end
end

function Twos:onTwosExportNow()
    self:exportCurrentBook(true)
end

function Twos:onTwosExportAll()
    self:exportAllBooks(true)
end

return Twos
