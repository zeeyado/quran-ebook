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

-- CREngine renames every EPUB id at import (ldomDocumentFragmentWriter::
-- convertId): DOM id = "_doc_fragment_<N>_ <id>" with N = the 0-based
-- spine index and a LITERAL SPACE before the original id. Plain
-- "#ayah-S-A" therefore resolves nowhere in fragment-built docs — this
-- was the root cause of the "always last/first ayah" detection bug
-- (diagnosed 2026-07-12 via headless cre probe; unresolvable xpointers
-- come back from getPageFromXPointer as page 1, and from
-- compareXPointers as nil). The prefix for the CURRENTLY VIEWED
-- fragment falls out of the view-top xpointer:
-- "/body/DocFragment[79]/…" → "_doc_fragment_78_ ".
function M.fragPrefix(xp)
    local f = xp and xp:match("^/body/DocFragment%[(%d+)%]")
    if f then
        return "_doc_fragment_" .. (tonumber(f) - 1) .. "_ "
    end
end

local function anchorXP(surah, ayah, prefix)
    return "#" .. (prefix or "") .. string.format("ayah-%d-%d", surah, ayah)
end

-- Fallback resolver: page-number comparison. Kept for engines/documents
-- where compareXPointers rejects fragment ids; known-imperfect (CRE's
-- lazy-pagination clamp can misplace far anchors — the parked hizb bug).
-- Unresolvable ids return page 1 (not 0), so page <= 1 counts as a miss:
-- no real ayah anchor sits on page 1 (front matter precedes surah 1).
local function findByPage(doc, surah, count, pageno, prefix)
    local function anchorPage(a)
        local ok, page = pcall(doc.getPageFromXPointer, doc,
            anchorXP(surah, a, prefix))
        if ok and page and page > 1 then return page end
        if prefix then
            -- engines that never prefixed (single-file docs)
            ok, page = pcall(doc.getPageFromXPointer, doc, anchorXP(surah, a))
            if ok and page and page > 1 then return page end
        end
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
-- sound (~9 comparisons for Al-Baqarah). The anchor id sits either on
-- the ayah's own opening block (ayah layouts) or on its inline end
-- marker (flow layouts — see M.anchorConvention); under BOTH conventions
-- the first anchor at-or-after the view top is the ayah visible there.
function M.findAyahForPage(quran, pageno)
    if not quran.ui or not quran.ui.document then return nil end
    local doc = quran.ui.document
    if doc.info and doc.info.has_pages then return nil end
    local surah = quran:_findSurahForPage(pageno)
    if not surah then return nil end
    local count = quran:bookAyahCount(surah)
    if not count or count < 1 then return surah, nil end

    local prefix
    if doc.compareXPointers and doc.getXPointer then
        local cur = doc:getXPointer()
        if cur then
            -- Containment first: serialize the rendered block that holds
            -- the view top (getHTMLFromXPointer + from_final_parent). In
            -- ayah-by-ayah layouts that block IS an ayah: the arabic
            -- paragraph carries id="ayah-S-A", the translation paragraph
            -- carries <span class="ayah-ref">S:A</span> — either is the
            -- exact answer. Without this the DOM search below lands one
            -- ayah late there (the view top text node compares strictly
            -- after its own paragraph's start anchor — the owner's
            -- "second ayah" report). Inline layouts have neither marker
            -- on the containing block — clean fall-through.
            if doc.getHTMLFromXPointer then
                local okh, html = pcall(doc.getHTMLFromXPointer, doc,
                    cur, 0, true)
                if okh and html then
                    local hs, ha = html:match('id="ayah%-(%d+)%-(%d+)"')
                    if not hs then
                        hs, ha = html:match('class="ayah%-ref">(%d+):(%d+)<')
                    end
                    if hs then
                        logger.info("quran.koplugin: findAyah containment",
                            hs, ha)
                        return tonumber(hs), tonumber(ha)
                    end
                end
            end
            -- The current surah's anchors live in the fragment we are
            -- looking at — its prefix comes straight from the view top.
            prefix = M.fragPrefix(cur)
            -- compareXPointers(a, b): 1 = b after a; 0 = same; -1 = b
            -- before a; nil = invalid xpointer (then fall back to pages).
            local c1 = doc:compareXPointers(anchorXP(surah, 1, prefix), cur)
            local clast = doc:compareXPointers(anchorXP(surah, count, prefix), cur)
            logger.info("quran.koplugin: findAyah dom-path surah", surah,
                "count", count, "prefix", tostring(prefix),
                "c1", tostring(c1), "clast", tostring(clast),
                "cur", tostring(cur))
            if c1 ~= nil then
                if c1 ~= 1 then
                    return surah, 1  -- view top at/before the first anchor
                end
                if clast == 1 then
                    -- Even the LAST anchor compares before the view top:
                    -- past the surah's final ayah (its end matter) — the
                    -- last ayah is what's on screen.
                    return surah, count
                end
                local lo, hi, best = 2, count, count
                while lo <= hi do
                    local mid = math.floor((lo + hi) / 2)
                    local c = doc:compareXPointers(anchorXP(surah, mid, prefix), cur)
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

    return surah, findByPage(doc, surah, count, pageno, prefix)
end

--- Resolve the page of an anchor anywhere in the book — jump targets for
-- the browser (surah header when ayah is nil, otherwise the ayah's end
-- marker). Tries the plain id first (non-fragment engines), then the
-- fragment-prefixed form: chapters are contiguous in the spine, so the
-- fragment offset derived from the current position (current fragment −
-- current surah) is exact; a small scan covers other front-matter
-- layouts. Ids are unique per source file, so a wrong offset can never
-- resolve to a false positive. The found offset is cached on the plugin
-- instance. Returns a page number or nil.
function M.resolveAnchorPage(quran, surah, ayah)
    local _ref, page = M.resolveAnchorRef(quran, surah, ayah)
    return page
end

--- Like resolveAnchorPage, but also returns the anchor REF ("#…id")
-- that resolved — usable with other xpointer APIs (the convention probe
-- feeds it to getHTMLFromXPointer). Returns ref, page — or nil.
function M.resolveAnchorRef(quran, surah, ayah)
    local doc = quran.ui and quran.ui.document
    if not doc or not doc.getPageFromXPointer then return nil end
    local id = ayah and string.format("ayah-%d-%d", surah, ayah)
        or string.format("surah-%d", surah)
    local function try(xp)
        local ok, page = pcall(doc.getPageFromXPointer, doc, xp)
        -- unresolvable ids come back as page 1 — treat as a miss (no
        -- real anchor sits on page 1; front matter precedes surah 1)
        if ok and page and page > 1 then return page end
    end
    local ref = "#" .. id
    local page = try(ref)
    if page then return ref, page end
    local offsets = {}
    if quran._frag_offset then
        table.insert(offsets, quran._frag_offset)
    end
    local ok, cur = pcall(doc.getXPointer, doc)
    local f = ok and cur and cur:match("^/body/DocFragment%[(%d+)%]")
    if f and doc.getCurrentPage and quran._findSurahForPage then
        local cur_surah = quran:_findSurahForPage(doc:getCurrentPage())
        if cur_surah then
            table.insert(offsets, tonumber(f) - cur_surah)
        end
    end
    for off = 0, 8 do
        table.insert(offsets, off)
    end
    local seen = {}
    for _i, off in ipairs(offsets) do
        if not seen[off] then
            seen[off] = true
            ref = "#_doc_fragment_" .. (surah + off - 1) .. "_ " .. id
            page = try(ref)
            if page then
                quran._frag_offset = off
                logger.info("quran.koplugin: anchor", id, "resolved page",
                    page, "frag offset", off)
                return ref, page
            end
        end
    end
    logger.info("quran.koplugin: anchor", id, "unresolved (no offset matched)")
    return nil
end

--- Which convention this book's ayah anchors follow (static probe, no
-- jumping; cached per book on the plugin instance):
--   "start" — the id sits on the ayah's own opening block (ayah-by-ayah
--             and word layouts: <p id="ayah-S-A">…) → "go to ayah A"
--             must resolve anchor A itself;
--   "end"   — the id is the inline end-of-ayah marker inside a flowing
--             paragraph (flow layouts) → the start of A is the END of
--             A−1, so jumps resolve anchor A−1 (the historical rule).
-- Probe: serialize the anchor's containing block; when the block's
-- opening tag carries the anchor id, the anchor opens its ayah.
function M.anchorConvention(quran)
    if quran._anchor_conv then return quran._anchor_conv end
    local doc = quran.ui and quran.ui.document
    if not doc or not doc.getHTMLFromXPointer then return "end" end
    for _i, probe in ipairs({ { 2, 2 }, { 1, 1 } }) do
        local ref, _page = M.resolveAnchorRef(quran, probe[1], probe[2])
        if ref then
            local okh, html = pcall(doc.getHTMLFromXPointer, doc, ref, 0, true)
            if okh and html and html ~= "" then
                local id_pat = string.format('ayah%%-%d%%-%d"', probe[1], probe[2])
                local conv = html:match('^%s*<%w+[^>]-id="[^"]*' .. id_pat)
                    and "start" or "end"
                quran._anchor_conv = conv
                logger.info("quran.koplugin: anchor convention", conv)
                return conv
            end
        end
    end
    return "end"  -- unknown: keep the historical rule; retry next call
end

--- Book-space ayah range visible on the current page: first = the
-- detected top ayah, last = the last ayah whose anchor still sits on
-- this page (an anchor here means that ayah starts or ends here, i.e.
-- is visible — correct for both anchor conventions). The primary path
-- compares anchors against the NEXT page's start xpointer in DOM order —
-- immune to CRE's lazy-pagination clamp, which makes page-number
-- comparison (the fallback) overshoot near the render frontier (same
-- reason findAyahForPage prefers DOM order). Returns surah, first,
-- last — first/last nil for anchorless books.
function M.visibleAyahRange(quran)
    local doc = quran.ui and quran.ui.document
    local pageno = doc and doc.getCurrentPage and doc:getCurrentPage()
    if not pageno then return nil end
    local surah, first = M.findAyahForPage(quran, pageno)
    if not surah then return nil end
    if not first then return surah end
    local last = first
    local count = quran.bookAyahCount and quran:bookAyahCount(surah) or 0
    local hi = math.min(first + 40, count)

    -- DOM-order path: anchor before the next page's start → on this page
    if doc.getPageXPointer and doc.compareXPointers and doc.getXPointer then
        local okn, next_xp = pcall(doc.getPageXPointer, doc, pageno + 1)
        local okc, cur = pcall(doc.getXPointer, doc)
        local prefix = okc and cur and M.fragPrefix(cur) or nil
        if okn and next_xp then
            local dom_ok = true
            for a = first + 1, hi do
                local ref = anchorXP(surah, a, prefix)
                local okx, cmp = pcall(doc.compareXPointers, doc, ref, next_xp)
                if not okx or not cmp then
                    dom_ok = a > first + 1  -- engine rejected the ref: only
                    break                   -- trust what already compared
                end
                if cmp <= 0 then break end  -- anchor at/after next page start
                last = a
            end
            if dom_ok then return surah, first, last end
            last = first
        end
    end

    -- Fallback: page-number comparison (may overshoot at the frontier)
    for a = first + 1, hi do
        local p = M.resolveAnchorPage(quran, surah, a)
        if not p or p > pageno then break end
        last = a
    end
    return surah, first, last
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

    -- Legacy tafsir picker (pre-rawSdcv KOReader: popup flow only)
    local function pickTafsirPopup()
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
    end

    -- One tap reads tafsir in the full-screen Reader (preferred tafsir /
    -- single installed / picker that saves the choice); falls back to the
    -- popup flow on KOReader versions without the headless fetch.
    local function readTafsir(dict_name)
        local surah, ayah = currentPosition(quran)
        if not surah then
            notifyWarn(_("Could not determine the current position."))
            return
        end
        local hafs_ayah = quran:_warshToHafs(surah, ayah or 1)
        -- explore: the panel path has the book beneath, not the browser,
        -- so the Reader offers its bridge into the unified ayah page
        local opened = quran.openTafsirReader
            and quran:openTafsirReader(surah, hafs_ayah,
                { dict = dict_name, explore = true })
        if not opened then
            if dict_name or #res.tafsir == 1 then
                M.openAyahIn(quran, dict_name or res.tafsir[1])
            else
                pickTafsirPopup()
            end
        end
    end

    local preferred = quran.settings
        and quran.settings:readSetting("preferred_tafsir") or nil
    local preferred_installed = false
    for _, name in ipairs(res.tafsir) do
        if name == preferred then preferred_installed = true end
    end
    if #res.tafsir == 1 then
        addButton({
            text = _("Tafsir"),
            callback = close_then(function() readTafsir(res.tafsir[1]) end),
            hold_callback = function() notifyWarn(res.tafsir[1]) end,
        })
    elseif #res.tafsir > 1 then
        addButton({
            -- one tap = preferred tafsir when set; "…" marks the picker
            text = _("Tafsir") .. (preferred_installed and "" or "\226\128\166"),
            callback = close_then(function()
                readTafsir(preferred_installed and preferred or nil)
            end),
            hold_callback = close_then(function()
                -- hold reoffers the choice (updates the default)
                local surah, ayah = currentPosition(quran)
                if surah and quran._showTafsirPicker
                        and quran.canReaderTafsir and quran:canReaderTafsir() then
                    quran:_showTafsirPicker(surah,
                        quran:_warshToHafs(surah, ayah or 1),
                        { explore = true })
                else
                    pickTafsirPopup()
                end
            end),
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
