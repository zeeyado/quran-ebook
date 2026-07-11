--[[--
quran_actions.lua — v1.12 hub layer 1: Dispatcher actions + quick panel.

Loaded by main.lua via dofile (same pattern as warshalign.lua/renamemap.lua);
every function takes the Quran plugin instance and calls back into its
methods — no plugin state lives here. The ButtonDialog panel shell and the
dynamic Dispatcher registration idiom are adapted from the owner's GPLv3
koassistant.koplugin fork (lineage: omer-faruq/assistant.koplugin); this
plugin is GPL-3.0 (repo LICENSE).
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local M = {}

local CHECK = "\226\156\147 "  -- U+2713 check mark + space

-- ---------------------------------------------------------------------
-- Dispatcher registration (gestures / profiles / quick menu)
-- ---------------------------------------------------------------------

local registered = false

function M.registerDispatcherActions()
    -- Dispatcher state is process-global; plugin init runs per document.
    if registered then return end
    registered = true
    Dispatcher:registerAction("quran_quick_panel", {
        category = "none", event = "QuranQuickPanel",
        title = _("Quran: quick panel"), reader = true, separator = true,
    })
    Dispatcher:registerAction("quran_ayah_lookup", {
        category = "none", event = "QuranAyahLookup",
        title = _("Quran: current ayah lookup"), reader = true,
    })
    Dispatcher:registerAction("quran_surah_overview", {
        category = "none", event = "QuranSurahOverview",
        title = _("Quran: surah overview"), reader = true,
    })
    Dispatcher:registerAction("quran_toggle_header", {
        category = "none", event = "QuranToggleHeader",
        title = _("Quran: toggle header bar"), reader = true,
    })
    Dispatcher:registerAction("quran_toggle_juz_footer", {
        category = "none", event = "QuranToggleJuzFooter",
        title = _("Quran: toggle juz in footer"), reader = true,
    })
    logger.dbg("quran.koplugin: dispatcher actions registered")
end

-- ---------------------------------------------------------------------
-- Current-position resolution (page -> surah:ayah, book-space numbering)
-- ---------------------------------------------------------------------

-- Page where ayah A of surah S starts visually: the END marker of A-1
-- (id="ayah-S-(A-1)"); A=1 starts at the surah header (id="surah-S").
-- Same anchor convention as the hizb boundary resolution in main.lua.
local function ayahStartPage(doc, surah, ayah)
    local xp = ayah > 1 and string.format("#ayah-%d-%d", surah, ayah - 1)
        or string.format("#surah-%d", surah)
    local ok, page = pcall(doc.getPageFromXPointer, doc, xp)
    if ok and page and page > 0 then return page end
    return nil
end

--- Resolve the ayah at the top of the given page.
-- Returns surah, ayah (both book-space) — ayah may be nil when the book
-- carries no per-ayah anchors (pre-v0.11 EPUBs).
function M.findAyahForPage(quran, pageno)
    if not quran.ui or not quran.ui.document then return nil end
    local doc = quran.ui.document
    if doc.info and doc.info.has_pages then return nil end
    local surah = quran:_findSurahForPage(pageno)
    if not surah then return nil end
    local count = quran:bookAyahCount(surah)
    if not count or count < 1 then return surah, nil end
    -- Anchor availability probe (surah header anchor).
    if not ayahStartPage(doc, surah, 1) then return surah, nil end
    -- Binary search: last ayah that starts on or before this page.
    local lo, hi, best = 1, count, 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local page = ayahStartPage(doc, surah, mid)
        if page and page <= pageno then
            best = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return surah, best
end

local function currentPosition(quran)
    local doc = quran.ui and quran.ui.document
    if not doc or not doc.getCurrentPage then return nil end
    local pageno = doc:getCurrentPage()
    if not pageno then return nil end
    return M.findAyahForPage(quran, pageno)
end

local function notify(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text })
end

-- ---------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------

--- Open the ayah-keyed dictionary popup (tafsir/grammar/asbab/...) for the
-- current position. Dictionaries are Hafs-keyed; Warsh books carry
-- Warsh-numbered anchors, so convert before the lookup.
function M.openAyahLookup(quran)
    local surah, ayah = currentPosition(quran)
    if not surah then
        notify(_("Could not determine the current position."))
        return
    end
    local hafs_ayah = quran:_warshToHafs(surah, ayah or 1)
    quran:openAyahPopup(surah, hafs_ayah)
end

--- Open the surah-overview popup for the current surah.
function M.openSurahOverview(quran)
    local surah = currentPosition(quran)
    if not surah then
        notify(_("Could not determine the current surah."))
        return
    end
    quran:openSurahOverviewPopup(surah)
end

--- Toggle the header overlay bar (mirrors the menu toggle).
function M.toggleHeader(quran)
    local on = quran.settings:isTrue("show_header_overlay")
    quran.settings:saveSetting("show_header_overlay", not on)
    quran._header_overlay_enabled = not on
    if on then
        quran:_restoreHeaderMargin()
    else
        quran:_applyHeaderMargin()
    end
    quran.settings:flush()
    if quran.ui and quran.ui.view then
        UIManager:setDirty(quran.ui.view, "ui")
    end
end

--- Toggle the juz line in the status-bar footer (mirrors the menu toggle).
function M.toggleJuzFooter(quran)
    local Event = require("ui/event")
    local on = quran.settings:nilOrTrue("show_juz_in_footer")
    quran.settings:saveSetting("show_juz_in_footer", not on)
    quran.settings:flush()
    UIManager:broadcastEvent(Event:new("UpdateFooter", true))
end

-- ---------------------------------------------------------------------
-- The quick panel
-- ---------------------------------------------------------------------

function M.showQuickPanel(quran)
    local ButtonDialog = require("ui/widget/buttondialog")
    if not quran._is_quran_book then
        notify(_("Open a Quran book to use the quick panel."))
        return
    end

    local surah, ayah = currentPosition(quran)
    local title = _("Quran quick panel")
    if surah then
        local name = quran:surahName(surah) or ("Surah " .. surah)
        if ayah then
            title = string.format("%s  %d:%d", name, surah, ayah)
        else
            title = name
        end
        local juz = quran:_getCurrentJuz()
        if juz then
            title = title .. "  \194\183  " .. _("Juz") .. " " .. juz
        end
    end

    local dialog
    local function close_then(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local function toggle_then(fn)
        return function()
            fn()
            UIManager:close(dialog)
            M.showQuickPanel(quran)  -- rebuild with fresh checkmarks
        end
    end
    local function mark(on, label)
        return (on and CHECK or "") .. label
    end

    local buttons = {
        {
            {
                text = _("Ayah: tafsir & resources"),
                callback = close_then(function() M.openAyahLookup(quran) end),
            },
            {
                text = _("Surah overview"),
                callback = close_then(function() M.openSurahOverview(quran) end),
            },
        },
        {
            {
                text = mark(quran.settings:isTrue("show_header_overlay"), _("Header bar")),
                callback = toggle_then(function() M.toggleHeader(quran) end),
            },
            {
                text = mark(quran.settings:nilOrTrue("show_juz_in_footer"), _("Juz in footer")),
                callback = toggle_then(function() M.toggleJuzFooter(quran) end),
            },
        },
        {
            {
                text = _("Restore book data after update"),
                callback = close_then(function() quran:restoreBookData() end),
            },
        },
        {
            -- v1.12 P2/P3 stubs — enabled as those modules land.
            { text = _("Library & assets") .. "  (soon)", enabled = false },
            { text = _("Root explorer") .. "  (soon)", enabled = false },
        },
    }

    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return M
