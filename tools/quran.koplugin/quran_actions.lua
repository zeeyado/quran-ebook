--[[--
quran_actions.lua — v1.12 hub layer 1: Dispatcher actions + quick panel.

Loaded by main.lua via dofile (same pattern as warshalign.lua/renamemap.lua);
every function takes the Quran plugin instance and calls back into its
methods — no plugin state lives here except the open dialog handle.
Panel construction mirrors the owner's GPLv3 koassistant.koplugin fork
(onKOAssistantQuickActions: continuous 2-per-row grid — last row single
only when the count is odd — "✓ "-prefixed toggle chips that reopen the
panel, hold-for-description, Close row) so both plugins feel the same.
GPL-3.0.
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local M = {}

local CHECK = "\226\156\147 "          -- "✓ "
local MIDDOT = "  \194\183  "          -- " · "

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
    Dispatcher:registerAction("quran_browser", {
        category = "none", event = "QuranBrowser",
        title = _("Quran: browser"), reader = true,
    })
    logger.dbg("quran.koplugin: dispatcher actions registered")
end

--- Open the Quran browser window (lazy dofile, cached on the instance).
-- land: optional callback(Browser) forwarded to the browser to open an
-- inner screen directly (e.g. the word popup's Root button).
function M.showBrowser(quran, land)
    if not quran._is_quran_book then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("The Quran browser is only available in a Quran book."),
        })
        return
    end
    if quran._browser_mod == nil then
        local ok, mod = pcall(dofile, (quran.path or "") .. "/quran_browser.lua")
        quran._browser_mod = (ok and type(mod) == "table") and mod or false
        if not quran._browser_mod then
            logger.info("quran.koplugin: quran_browser.lua unavailable:", tostring(mod))
        end
    end
    if quran._browser_mod then
        quran._browser_mod.show(quran, M, land)
    end
end

-- ---------------------------------------------------------------------
-- Current-position resolution (page -> surah:ayah, book-space numbering)
-- ---------------------------------------------------------------------

local function anchorXP(surah, ayah)
    return string.format("#ayah-%d-%d", surah, ayah)
end

-- Fallback resolver: page-number comparison. Kept for engines/documents
-- where compareXPointers rejects fragment ids; known-imperfect (CRE's
-- lazy-pagination clamp can misplace far anchors — the parked hizb bug).
local function findByPage(doc, surah, count, pageno)
    local function anchorPage(a)
        local ok, page = pcall(doc.getPageFromXPointer, doc, anchorXP(surah, a))
        if ok and page and page > 0 then return page end
        return nil
    end
    local p1 = anchorPage(1)
    if not p1 then
        logger.info("quran.koplugin: findAyah page-path: no anchors")
        return nil  -- anchorless (pre-v0.11) book
    end
    for a = 1, count do
        local page = anchorPage(a)
        if page and page >= pageno then
            logger.info("quran.koplugin: findAyah page-path hit", a,
                "page", page, "cur", pageno, "p1", p1)
            return a
        end
    end
    -- Every anchor resolved before this page. Genuine only past the
    -- surah's last ayah; on-device it also fires spuriously (DEFERRED
    -- detection bug, owner 2026-07-11) — so default to ayah 1 (nil), the
    -- less-wrong end, rather than claiming the last ayah.
    logger.info("quran.koplugin: findAyah page-path exhausted; cur", pageno,
        "p1", p1, "plast", anchorPage(count))
    return nil
end

--- Resolve the ayah at the top of the current view.
-- Returns surah, ayah (both book-space) — ayah may be nil when the book
-- carries no per-ayah anchors (pre-v0.11 EPUBs).
--
-- Primary path is DOM-ORDER comparison (compareXPointers of each ayah
-- anchor against the current position xpointer): pagination-independent,
-- so CRE's lazy-pagination clamp — which made page-number comparison
-- report the surah's LAST ayah near the end of the book — cannot distort
-- it, and it is strictly monotone in ayah number, so binary search is
-- sound (~9 comparisons for Al-Baqarah). Both layouts anchor the id at
-- the ayah's text END (number span / end marker), so the first anchor
-- at-or-after the view top is exactly the ayah visible there.
function M.findAyahForPage(quran, pageno)
    if not quran.ui or not quran.ui.document then return nil end
    local doc = quran.ui.document
    if doc.info and doc.info.has_pages then return nil end
    local surah = quran:_findSurahForPage(pageno)
    if not surah then return nil end
    local count = quran:bookAyahCount(surah)
    if not count or count < 1 then return surah, nil end

    if doc.compareXPointers and doc.getXPointer then
        local cur = doc:getXPointer()
        if cur then
            -- compareXPointers(a, b): 1 = b after a; 0 = same; -1 = b
            -- before a; nil = invalid xpointer (then fall back to pages).
            local c1 = doc:compareXPointers(anchorXP(surah, 1), cur)
            local clast = doc:compareXPointers(anchorXP(surah, count), cur)
            -- One diagnostic line per press (DEFERRED detection bug —
            -- capture from a terminal run): path, cur xpointer, and the
            -- first/last anchor comparisons.
            logger.info("quran.koplugin: findAyah dom-path surah", surah,
                "count", count, "c1", tostring(c1), "clast", tostring(clast),
                "cur", tostring(cur))
            if c1 ~= nil then
                if c1 ~= 1 then
                    return surah, 1  -- view top at/before the first anchor
                end
                if clast == 1 then
                    -- Even the LAST anchor compares before the view top.
                    -- Genuine only past the surah's final ayah; on-device
                    -- this also fires spuriously (deferred bug) — default
                    -- to ayah 1 (nil) instead of claiming the last ayah.
                    return surah, nil
                end
                local lo, hi, best = 2, count, count
                while lo <= hi do
                    local mid = math.floor((lo + hi) / 2)
                    local c = doc:compareXPointers(anchorXP(surah, mid), cur)
                    if c == nil then
                        best = nil  -- invalid mid anchor: use the fallback
                        break
                    elseif c == 1 then
                        lo = mid + 1   -- anchor strictly before view top
                    else
                        best = mid
                        hi = mid - 1
                    end
                end
                if best then return surah, best end
            end
        end
    end

    return surah, findByPage(doc, surah, count, pageno)
end

local function currentPosition(quran)
    local doc = quran.ui and quran.ui.document
    if not doc or not doc.getCurrentPage then return nil end
    local pageno = doc:getCurrentPage()
    if not pageno then return nil end
    return M.findAyahForPage(quran, pageno)
end

local function notifyWarn(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = text })
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

--- Open the ayah-keyed dictionary popup (all matching resources) for the
-- current position. Dictionaries are Hafs-keyed; Warsh books carry
-- Warsh-numbered anchors, so convert before the lookup.
function M.openAyahLookup(quran)
    local surah, ayah = currentPosition(quran)
    if not surah then
        notifyWarn(_("Could not determine the current position."))
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
        notifyWarn(_("Could not determine the current position."))
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
        notifyWarn(_("Could not determine the current surah."))
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
-- The quick panel (visual conventions = koassistant's quick panels)
-- ---------------------------------------------------------------------

function M.showQuickPanel(quran)
    local ButtonDialog = require("ui/widget/buttondialog")
    if not quran._is_quran_book then
        notifyWarn(_("Quick panel is only available in a Quran book."))
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
            title = title .. MIDDOT .. _("Juz") .. " " .. juz
        end
    end

    local dialog
    local buttons = {}
    local row = {}

    -- koassistant grid idiom: 2 per row, flush when full
    local function addButton(btn)
        btn.font_bold = false
        table.insert(row, btn)
        if #row == 2 then
            table.insert(buttons, row)
            row = {}
        end
    end
    local function flushRow()
        if #row > 0 then
            table.insert(buttons, row)
            row = {}
        end
    end
    local function close_then(fn)
        return function()
            UIManager:close(dialog)
            quran._quick_panel_dialog = nil
            fn()
        end
    end
    local function toggle_then(fn)
        return function()
            fn()
            UIManager:close(dialog)
            quran._quick_panel_dialog = nil
            M.showQuickPanel(quran)  -- reopen with fresh chip states
        end
    end
    local function chip(on, label)
        return (on and CHECK or "") .. label
    end

    -- Resources for the current ayah: exactly what's installed
    local res = M.detectResources(quran)
    if #res.tafsir == 1 then
        addButton({
            text = _("Tafsir"),
            callback = close_then(function() M.openAyahIn(quran, res.tafsir[1]) end),
            hold_callback = function() notifyWarn(res.tafsir[1]) end,
        })
    elseif #res.tafsir > 1 then
        addButton({
            text = _("Tafsir") .. "\226\128\166",
            callback = function()
                UIManager:close(dialog)
                quran._quick_panel_dialog = nil
                local rows = {}
                for _, name in ipairs(res.tafsir) do
                    table.insert(rows, { {
                        text = name,
                        font_bold = false,
                        callback = function()
                            UIManager:close(quran._tafsir_picker)
                            quran._tafsir_picker = nil
                            M.openAyahIn(quran, name)
                        end,
                    } })
                end
                table.insert(rows, { {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(quran._tafsir_picker)
                        quran._tafsir_picker = nil
                        M.showQuickPanel(quran)
                    end,
                } })
                quran._tafsir_picker = ButtonDialog:new{
                    title = _("Tafsir for the current ayah"),
                    title_align = "center",
                    buttons = rows,
                    tap_close_callback = function()
                        quran._tafsir_picker = nil
                    end,
                }
                UIManager:show(quran._tafsir_picker)
            end,
        })
    end
    if res.asbab then
        addButton({
            text = _("Asbab al-Nuzul"),
            callback = close_then(function() M.openAyahIn(quran, res.asbab) end),
            hold_callback = function()
                notifyWarn(_("Occasion of revelation (only ayahs with a recorded occasion have entries)."))
            end,
        })
    end
    if res.irab then
        addButton({
            text = _("I'rab"),
            callback = close_then(function() M.openAyahIn(quran, res.irab) end),
            hold_callback = function() notifyWarn(_("Grammatical analysis of the full ayah.")) end,
        })
    end
    addButton({
        text = _("All resources"),
        callback = close_then(function() M.openAyahLookup(quran) end),
    })
    addButton({
        text = _("Surah overview"),
        callback = close_then(function() M.openSurahOverview(quran) end),
    })

    -- Display toggles (chips)
    addButton({
        text = chip(quran.settings:isTrue("show_header_overlay"), _("Header bar")),
        callback = toggle_then(function() M.toggleHeader(quran) end),
    })
    addButton({
        text = chip(quran.settings:nilOrTrue("show_juz_in_footer"), _("Juz in footer")),
        callback = toggle_then(function() M.toggleJuzFooter(quran) end),
    })

    -- Utilities
    addButton({
        text = _("Restore book data"),
        callback = close_then(function() quran:restoreBookData() end),
        hold_callback = function()
            notifyWarn(_("Copies reading data from old filenames to renamed books in this folder."))
        end,
    })
    -- v1.12 P2/P3 stubs — enabled as those modules land
    addButton({
        text = _("Browser"),
        callback = close_then(function() M.showBrowser(quran) end),
        hold_callback = function()
            notifyWarn(_("Browse surahs, juz, and the current ayah's resources in one window."))
        end,
    })
    addButton({ text = _("Library & assets"), enabled = false })
    flushRow()

    table.insert(buttons, { {
        text = _("Close"),
        callback = function()
            UIManager:close(dialog)
            quran._quick_panel_dialog = nil
        end,
    } })

    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
        tap_close_callback = function()
            quran._quick_panel_dialog = nil
        end,
    }
    quran._quick_panel_dialog = dialog
    UIManager:show(dialog)
end

return M
