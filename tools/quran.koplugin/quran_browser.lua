--[[--
quran_browser.lua — v1.12 hub: the Quran browser window (the "app" shell).

Navigation engine — one full-screen Menu widget + manual nav_stack +
switchItemTable + paths-array back arrow — adapted from the owner's GPLv3
koassistant.koplugin X-ray browser (navigateForward/navigateBack idiom).
Sections v1: Current position / Surahs / Juz / Library & assets (the P2
asset manager, in quran_assets.lua), with a stub for Roots (lands with
the lane.sqlite extract, P3). All content opens through the existing
dictionary-popup plumbing in quran_actions.lua; the browser closes itself
first so the popup sits over the book. GPL-3.0.
]]

local Device = require("device")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local Browser = {}

-- ---------------------------------------------------------------------
-- Navigation engine (X-ray browser idiom)
-- ---------------------------------------------------------------------

function Browser:navigateForward(title, items, focus_idx)
    if not self.menu then return end
    table.insert(self.nav_stack, {
        title = self.current_title,
        items = self.menu.item_table,
    })
    self.current_title = title
    table.insert(self.menu.paths, true)  -- enables the back arrow
    self.menu:switchItemTable(title, items, focus_idx)
end

function Browser:navigateBack()
    if not self.menu then return end
    if #self.nav_stack == 0 then
        UIManager:close(self.menu)
        return
    end
    local prev = table.remove(self.nav_stack)
    self.current_title = prev.title
    table.remove(self.menu.paths)
    self.menu:switchItemTable(prev.title, prev.items, -1)
end

function Browser:close()
    if self.menu then
        UIManager:close(self.menu)
    end
end

-- Close the browser, then run an action (dict popups must sit over the
-- book, not over the browser).
function Browser:closeThen(fn)
    return function()
        self:close()
        fn()
    end
end

local function notifyWarn(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = text })
end

-- Lazy-load a sibling module; cached on the plugin instance like the
-- browser module itself in quran_actions.lua.
local function loadSibling(quran, cache_key, filename)
    if quran[cache_key] then return quran[cache_key] end
    local ok, mod = pcall(dofile, (quran.path or "") .. "/" .. filename)
    if ok and type(mod) == "table" then
        quran[cache_key] = mod
        return mod
    end
    logger.info("quran.koplugin: failed to load " .. filename .. ":", mod)
end

function Browser:assetsModule()
    return loadSibling(self.quran, "_assets_mod", "quran_assets.lua")
end

function Browser:rootsModule()
    return loadSibling(self.quran, "_roots_mod", "quran_roots.lua")
end

function Browser:qulModule()
    return loadSibling(self.quran, "_qul_mod", "quran_qul.lua")
end

-- ---------------------------------------------------------------------
-- Jumps (reading-position navigation)
-- ---------------------------------------------------------------------

-- Go to a resolved page (with a location-stack entry so the device's
-- back gesture returns to the previous position).
function Browser:gotoPage(page)
    local quran = self.quran
    if not page then
        notifyWarn(_("Could not locate that position in this book."))
        return
    end
    local Event = require("ui/event")
    if quran.ui and quran.ui.link and quran.ui.link.addCurrentLocationToStack then
        quran.ui.link:addCurrentLocationToStack()
    end
    self:close()
    quran.ui:handleEvent(Event:new("GotoPage", page))
end

-- Juz boundary S:A starts visually at the END marker of the previous
-- ayah (same convention as the hizb boundary resolution in main.lua).
-- Anchor pages resolve through actions.resolveAnchorPage (fragment-
-- prefixed ids — plain "#ayah-…" never resolves in EPUBs).
function Browser:gotoAyah(surah, ayah)
    local page
    if ayah and ayah > 1 then
        page = self.actions.resolveAnchorPage(self.quran, surah, ayah - 1)
    else
        page = self.actions.resolveAnchorPage(self.quran, surah, nil)
    end
    self:gotoPage(page)
end

-- ---------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------

function Browser:buildPositionItems(surah, ayah)
    local quran, actions = self.quran, self.actions
    local items = {}
    local res = actions.detectResources(quran)
    for _idx, name in ipairs(res.tafsir) do
        table.insert(items, {
            text = _("Tafsir") .. ": " .. name,
            callback = self:closeThen(function() actions.openAyahIn(quran, name) end),
        })
    end
    if res.asbab then
        table.insert(items, {
            text = _("Asbab al-Nuzul"),
            callback = self:closeThen(function() actions.openAyahIn(quran, res.asbab) end),
        })
    end
    if res.irab then
        table.insert(items, {
            text = _("I'rab"),
            callback = self:closeThen(function() actions.openAyahIn(quran, res.irab) end),
        })
    end
    table.insert(items, {
        text = _("All resources"),
        callback = self:closeThen(function() actions.openAyahLookup(quran) end),
    })
    table.insert(items, {
        text = _("Surah overview"),
        separator = true,
        callback = self:closeThen(function() quran:openSurahOverviewPopup(surah) end),
    })
    -- QUL connections for this ayah (counts shown; Hafs numbering)
    local qul = self:qulModule()
    local conn = qul and ayah and select(1, qul.ensureDb(quran))
    if conn then
        local hafs_a = quran._warshToHafs and quran:_warshToHafs(surah, ayah) or ayah
        local counts = qul.countsFor(conn, surah, hafs_a)
        if counts then
            local function connItem(n, label, fn)
                if n and n > 0 then
                    table.insert(items, {
                        text = label,
                        mandatory = tostring(n),
                        callback = function() fn(self, surah, hafs_a) end,
                    })
                end
            end
            connItem(counts.similar, _("Similar ayahs"), qul.showSimilar)
            connItem(counts.themes, _("Themes here"), qul.showThemesFor)
            connItem(counts.topics, _("Topics here"), qul.showTopicsFor)
            connItem(counts.phrases, _("Repeated phrases"), qul.showMutashabihat)
        end
    end
    table.insert(items, {
        text = _("Pick another ayah in this surah"),
        callback = function() self:showAyahList(surah) end,
    })
    return items
end

function Browser:showPosition()
    local quran, actions = self.quran, self.actions
    local doc = quran.ui and quran.ui.document
    local pageno = doc and doc.getCurrentPage and doc:getCurrentPage()
    local surah, ayah = nil, nil
    if pageno then
        surah, ayah = actions.findAyahForPage(quran, pageno)
    end
    if not surah then
        notifyWarn(_("Could not determine the current position."))
        return
    end
    local name = quran:surahName(surah) or ("Surah " .. surah)
    local title = ayah and string.format("%s %d:%d", name, surah, ayah) or name
    self:navigateForward(title, self:buildPositionItems(surah, ayah))
end

function Browser:showAyahList(surah)
    local quran = self.quran
    local count = quran:bookAyahCount(surah) or 0
    local name = quran:surahName(surah) or ("Surah " .. surah)
    local items = {}
    for a = 1, count do
        local ayah = a
        table.insert(items, {
            text = string.format("%s %d:%d", name, surah, ayah),
            callback = self:closeThen(function()
                quran:openAyahPopup(surah, quran:_warshToHafs(surah, ayah))
            end),
        })
    end
    self:navigateForward(name, items)
end

function Browser:buildSurahItems(surah)
    local quran = self.quran
    local name = quran:surahName(surah) or ("Surah " .. surah)
    local items = {
        {
            text = _("Go to surah"),
            callback = function() self:gotoAyah(surah, 1) end,
        },
        {
            text = _("Surah overview"),
            callback = self:closeThen(function() quran:openSurahOverviewPopup(surah) end),
        },
        {
            text = _("Ayahs") .. " (" .. tostring(quran:bookAyahCount(surah) or "?") .. ")",
            callback = function() self:showAyahList(surah) end,
        },
    }
    return items, name
end

function Browser:showSurahList(focus_idx)
    local quran = self.quran
    local items = {}
    for s = 1, 114 do
        local surah = s
        local name = quran:surahName(s) or ("Surah " .. s)
        local arabic = quran.surahNameArabic and quran:surahNameArabic(s) or nil
        local label = string.format("%d. %s", s, name)
        if arabic then
            label = label .. "  " .. arabic
        end
        table.insert(items, {
            text = label,
            mandatory = tostring(quran:bookAyahCount(s) or ""),
            callback = function()
                local sub_items, sub_title = self:buildSurahItems(surah)
                self:navigateForward(sub_title, sub_items)
            end,
        })
    end
    self:navigateForward(_("Surahs"), items, focus_idx)
end

function Browser:showJuzList()
    local quran = self.quran
    local items = {}
    for j = 1, 30 do
        local surah, ayah = quran:juzBoundary(j)
        if not surah then break end
        local sname = quran:surahName(surah) or tostring(surah)
        table.insert(items, {
            text = string.format("%s %d", _("Juz"), j),
            mandatory = string.format("%s %d:%d", sname, surah, ayah),
            callback = function()
                -- Boundaries are Hafs-numbered; Warsh books carry
                -- Warsh-numbered anchors (same conversion as hizb).
                local a = ayah > 1 and quran:_hafsToWarsh(surah, ayah) or 1
                self:gotoAyah(surah, a)
            end,
        })
    end
    self:navigateForward(_("Juz"), items)
end

function Browser:buildRootItems()
    local quran, actions = self.quran, self.actions
    local items = {}

    -- Current position header item (resolved fresh each build)
    local pos_label = _("Current position")
    local doc = quran.ui and quran.ui.document
    local pageno = doc and doc.getCurrentPage and doc:getCurrentPage()
    if pageno then
        local surah, ayah = actions.findAyahForPage(quran, pageno)
        if surah then
            local name = quran:surahName(surah) or ("Surah " .. surah)
            pos_label = ayah and string.format("%s %d:%d", name, surah, ayah) or name
        end
    end
    table.insert(items, {
        text = _("Current position") .. ":  " .. pos_label,
        callback = function() self:showPosition() end,
    })
    table.insert(items, {
        text = _("Surahs"),
        mandatory = "114",
        callback = function() self:showSurahList() end,
    })
    table.insert(items, {
        text = _("Juz"),
        mandatory = "30",
        separator = true,
        callback = function() self:showJuzList() end,
    })
    table.insert(items, {
        text = _("Topics"),
        callback = function()
            local qul = self:qulModule()
            if qul then
                qul.showTopicsRoot(self)
            else
                notifyWarn(_("The QUL module failed to load."))
            end
        end,
    })
    table.insert(items, {
        text = _("Themes"),
        callback = function()
            local qul = self:qulModule()
            if qul then
                qul.showThemesBrowse(self)
            else
                notifyWarn(_("The QUL module failed to load."))
            end
        end,
    })
    table.insert(items, {
        text = _("Root explorer"),
        callback = function()
            local roots = self:rootsModule()
            if roots then
                roots.showRoots(self)
            else
                notifyWarn(_("The root explorer failed to load."))
            end
        end,
    })
    table.insert(items, {
        text = _("Library & assets"),
        callback = function()
            local assets = self:assetsModule()
            if assets then
                assets.showLibrary(self)
            else
                notifyWarn(_("The asset manager failed to load."))
            end
        end,
    })
    return items
end

-- ---------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------

local M = {}

--- Show the browser. quran = plugin instance; actions = quran_actions
-- module; land = optional callback(Browser) run after the menu is shown,
-- to navigate straight to an inner screen (e.g. the popup's Root button
-- lands on that root, with back returning to the browser's main menu).
function M.show(quran, actions, land)
    if Browser.menu then
        UIManager:close(Browser.menu)
    end
    Browser.quran = quran
    Browser.actions = actions
    Browser.nav_stack = {}
    Browser.current_title = _("Quran")

    Browser.menu = Menu:new{
        title = Browser.current_title,
        item_table = Browser:buildRootItems(),
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        onReturn = function()
            Browser:navigateBack()
        end,
        -- NOTE: no close_callback — Menu:onMenuSelect fires it after every
        -- item tap (X-ray browser lesson); cleanup lives in onCloseWidget.
    }
    local orig_onCloseWidget = Browser.menu.onCloseWidget
    Browser.menu.onCloseWidget = function(menu_self)
        Browser.menu = nil
        Browser.nav_stack = {}
        Browser.quran = nil
        Browser.actions = nil
        if orig_onCloseWidget then
            return orig_onCloseWidget(menu_self)
        end
    end
    UIManager:show(Browser.menu)
    logger.dbg("quran.koplugin: browser opened")
    if land then
        land(Browser)
    end
end

return M
