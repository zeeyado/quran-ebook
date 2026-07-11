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

-- Page of ayah A's own anchor (id="ayah-S-A"). The anchor's placement
-- differs by layout — inline books put it on the ayah's END marker,
-- ayah-by-ayah/WBW books on the ayah's own block — but in BOTH cases the
-- first anchor at/after the top of a page belongs to the ayah visible
-- there, which is all findAyahForPage needs.
local function ayahAnchorPage(doc, surah, ayah)
    local xp = string.format("#ayah-%d-%d", surah, ayah)
    local ok, page = pcall(doc.getPageFromXPointer, doc, xp)
    if ok and page and page > 0 then return page end
    return nil
end

--- Resolve the ayah at the top of the given page.
-- Returns surah, ayah (both book-space) — ayah may be nil when the book
-- carries no per-ayah anchors (pre-v0.11 EPUBs).
--
-- Deliberately a LINEAR scan with early exit, not a binary search:
-- CREngine resolves anchors beyond its lazy-pagination frontier to a
-- clamped page (the parked hizb bug), which breaks the monotonicity a
-- binary search needs — near the end of a freshly-opened book it walked
-- to the surah's LAST ayah (owner repro: 77:33 page reported as 77:50).
-- Scanning from ayah 1 hits the true first anchor >= pageno before any
-- clamped far anchor can matter; worst case is one surah's ayah count
-- (<= 286) of cheap anchor resolutions, on an explicit button press.
function M.findAyahForPage(quran, pageno)
    if not quran.ui or not quran.ui.document then return nil end
    local doc = quran.ui.document
    if doc.info and doc.info.has_pages then return nil end
    local surah = quran:_findSurahForPage(pageno)
    if not surah then return nil end
    local count = quran:bookAyahCount(surah)
    if not count or count < 1 then return surah, nil end
    if not ayahAnchorPage(doc, surah, 1) then
        return surah, nil  -- anchorless (pre-v0.11) book
    end
    for a = 1, count do
        local page = ayahAnchorPage(doc, surah, a)
        if page and page >= pageno then
            return surah, a
        end
    end
    -- Every anchor resolves before this page: past the surah's last ayah
    -- (e.g. surah ends mid-page) — report the last ayah.
    return surah, count
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
-- Installed-resource detection (the "app-like" layer: the panel offers
-- exactly what the user has installed, each opening directly)
-- ---------------------------------------------------------------------

--- Classify a StarDict bookname into a Quran resource kind.
-- Ayah-keyed kinds (panel-openable): tafsir, asbab, irab, overview.
-- Word-keyed kinds (surface via word long-press, not the panel): word,
-- grammar. Unknown/non-Quran dicts return nil.
function M.classifyDict(name)
    if not name then return nil end
    if name:find("Word%-by%-Word") then return "word" end
    if name == "Quran Grammar" or name == "Quran Grammar (Lite)" then return "grammar" end
    if name:find("I'rab", 1, true) then return "irab" end
    if name:find("Asbab", 1, true) then return "asbab" end
    if name:find("Surah Overview", 1, true) then return "overview" end
    if name:find("Tafsir", 1, true) or name:find("Tafseer", 1, true)
        or name:find("Bayan ul Quran", 1, true)
        or name:find("Fi Zilal", 1, true)
        or name:find("Ma'ariful", 1, true)
        or name:find("Tazkir", 1, true) then
        return "tafsir"
    end
    return nil
end

--- Scan the enabled dictionaries and bucket the Quran resources.
-- Returns { tafsir = {name, ...}, asbab = name?, irab = name?, ... }.
function M.detectResources(quran)
    local dict = quran.ui and quran.ui.dictionary
    local names = dict and dict.enabled_dict_names or {}
    local res = { tafsir = {} }
    for _, name in ipairs(names) do
        local kind = M.classifyDict(name)
        if kind == "tafsir" then
            table.insert(res.tafsir, name)
        elseif kind then
            res[kind] = name
        end
    end
    return res
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

--- Open the current ayah directly in ONE dictionary (panel resource
-- buttons). Sets the one-shot result filter consumed by the showDict
-- patch in main.lua; if that dictionary has no entry for the ayah (e.g.
-- sparse asbab), the popup falls back to all matching resources.
function M.openAyahIn(quran, dict_name)
    local surah, ayah = currentPosition(quran)
    if not surah then
        notify(_("Could not determine the current position."))
        return
    end
    local hafs_ayah = quran:_warshToHafs(surah, ayah or 1)
    quran._dict_filter_name = dict_name
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

    -- Resource rows: exactly what's installed, each opening directly on
    -- the current ayah (auto-detected from the enabled dictionaries).
    local res = M.detectResources(quran)
    local resource_btns = {}
    if #res.tafsir == 1 then
        table.insert(resource_btns, {
            text = _("Tafsir"),
            callback = close_then(function() M.openAyahIn(quran, res.tafsir[1]) end),
        })
    elseif #res.tafsir > 1 then
        table.insert(resource_btns, {
            text = _("Tafsir") .. "\226\128\166",  -- ellipsis
            callback = function()
                UIManager:close(dialog)
                local rows = {}
                for _, name in ipairs(res.tafsir) do
                    table.insert(rows, { {
                        text = name,
                        callback = function()
                            UIManager:close(quran._tafsir_picker)
                            M.openAyahIn(quran, name)
                        end,
                    } })
                end
                quran._tafsir_picker = ButtonDialog:new{
                    title = _("Tafsir for the current ayah"),
                    title_align = "center",
                    buttons = rows,
                }
                UIManager:show(quran._tafsir_picker)
            end,
        })
    end
    if res.asbab then
        table.insert(resource_btns, {
            text = _("Asbab al-Nuzul"),
            callback = close_then(function() M.openAyahIn(quran, res.asbab) end),
        })
    end
    if res.irab then
        table.insert(resource_btns, {
            text = _("I'rab"),
            callback = close_then(function() M.openAyahIn(quran, res.irab) end),
        })
    end

    local buttons = {}
    -- Pack resource buttons 2 per row
    for i = 1, #resource_btns, 2 do
        table.insert(buttons, { resource_btns[i], resource_btns[i + 1] })
    end
    table.insert(buttons, {
        {
            text = _("All resources"),
            callback = close_then(function() M.openAyahLookup(quran) end),
        },
        {
            text = _("Surah overview"),
            callback = close_then(function() M.openSurahOverview(quran) end),
        },
    })
    local tail_rows = {
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
    for _, row in ipairs(tail_rows) do
        table.insert(buttons, row)
    end

    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return M
