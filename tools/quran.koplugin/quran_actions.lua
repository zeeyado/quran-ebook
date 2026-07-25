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
    -- GENERAL like the browser (⑤C): the panel has a bookless launcher
    -- shape now, so it is assignable in the file manager too.
    Dispatcher:registerAction("quran_quick_panel", {
        category = "none", event = "QuranQuickPanel",
        title = _("Quran: quick panel"), general = true, separator = true,
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
    -- GENERAL section (owner 2026-07-18, koassistant pattern): the
    -- browser is bookless-capable, so it lives in the gesture
    -- manager's General list — assignable in BOTH the file browser
    -- and the reader (reader+filemanager flags put it in the
    -- context-specific sections instead; the FM one didn't surface).
    Dispatcher:registerAction("quran_browser", {
        category = "none", event = "QuranBrowser",
        -- F31: user-facing surface name is "Explorer" (owner 2026-07-25);
        -- action ids/events keep the browser name.
        title = _("Quran: explorer"), general = true,
    })
    logger.dbg("quran.koplugin: dispatcher actions registered")
end

--- Open the Quran browser window (lazy dofile, cached on the instance).
-- land: optional callback(Browser) forwarded to the browser to open an
-- inner screen directly (e.g. the word popup's Root button).
function M.showBrowser(quran, land)
    -- D-R3-19: BOOKLESS (the FileManager instance — no document at
    -- all) is welcome: browse/search/Library work without a book and
    -- go-to routes through the preferred-book seam. Only a NON-Quran
    -- BOOK refuses (gestures stay inert in other books).
    local bookless = not (quran.ui and quran.ui.document)
    if not quran._is_quran_book and not bookless then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("The Quran Explorer is only available in a Quran book."),
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
-- Returns { tafsir = {name, ...}, grammar = name?, grammar_all = {...},
-- asbab = name?, irab = name?, ... }. res.grammar is RESOLVED (owner G3
-- decision 2026-07-18): the "preferred_grammar" setting wins when that
-- dict is installed; otherwise the fullest analysis ("Quran Grammar" =
-- combined) beats Lite — never the silent last-enumerated-wins it was.
function M.detectResources(quran)
    local dict = quran.ui and quran.ui.dictionary
    local names = dict and dict.enabled_dict_names or {}
    local res = { tafsir = {}, grammar_all = {} }
    for _, name in ipairs(names) do
        local kind = M.classifyDict(name)
        if kind == "tafsir" then
            table.insert(res.tafsir, name)
        elseif kind == "grammar" then
            table.insert(res.grammar_all, name)
        elseif kind then
            res[kind] = name
        end
    end
    if #res.grammar_all > 0 then
        local preferred = quran.settings
            and quran.settings:readSetting("preferred_grammar")
        for _, name in ipairs(res.grammar_all) do
            if name == preferred then res.grammar = name break end
        end
        if not res.grammar then
            for _, name in ipairs(res.grammar_all) do
                if name == "Quran Grammar" then res.grammar = name break end
            end
        end
        res.grammar = res.grammar or res.grammar_all[1]
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
    quran._dict_first_name = dict_name
    quran:openAyahPopup(surah, hafs_ayah)
end

--- Open the surah-overview popup for the current surah.
function M.openSurahOverview(quran)
    local surah = currentPosition(quran)
    if not surah then
        notifyWarn(_("Could not determine the current surah."))
        return
    end
    -- Unified reading system (owner 2026-07-12): every sustained surface
    -- opens in the full-screen Reader when the headless fetch exists;
    -- the popup stays the pre-rawSdcv fallback. D-R3-2: Simple mode /
    -- a per-item override routes straight to the popup.
    local use_reader = not (quran._openTargetFor
        and quran:_openTargetFor("overview") == "popup")
    local res = M.detectResources(quran)
    local reader = quran._readerModule and quran:_readerModule()
    local opened = use_reader and reader and reader.showOverview
        and res.overview
        and quran.canReaderTafsir and quran:canReaderTafsir()
        and reader.showOverview(quran, surah, { dict = res.overview })
    if not opened then
        quran:openSurahOverviewPopup(surah)
    end
end

--- Toggle the header overlay bar (mirrors the menu toggle).
function M.toggleHeader(quran)
    local on = quran.settings:isTrue("show_header_overlay")
    quran.settings:saveSetting("show_header_overlay", not on)
    quran._header_overlay_enabled = not on
    quran.settings:flush()
    if not on and quran._nudgeHeaderMargin then
        quran:_nudgeHeaderMargin()  -- ND-6: raise-to-5 on switch-on only
    end
    if quran.ui and quran.ui.view then
        UIManager:setDirty(quran.ui.view, "ui")
    end
end

--- Toggle the juz line in the status-bar footer (mirrors the menu toggle).
function M.toggleJuzFooter(quran)
    local on = quran.settings:nilOrTrue("show_juz_in_footer")
    quran.settings:saveSetting("show_juz_in_footer", not on)
    quran.settings:flush()
    -- The status-bar content func is registered for the whole book (see
    -- onReaderReady), so toggling the juz item just flips the setting and
    -- repaints the footer — no register/unregister, no reopen needed.
    quran:_refreshFooter()
end

-- ---------------------------------------------------------------------
-- The quick panel — a koassistant-style Quick Settings panel: a
-- TitledButtonDialog (gear icon + close X in the title bar) whose 2-per-row
-- grid is built from an ORDERED, per-item ENABLE-able registry. The gear
-- opens "Panel items" (a fullscreen sort/enable/disable organizer) and
-- "Align buttons" (left ↔ centered), exactly like koassistant's QS panel.
-- ---------------------------------------------------------------------

local CHECK_PREFIX = "\226\156\147 "   -- "✓ " (organizer + chip prefix)
local ARROW_UP = "\226\134\145"        -- ↑
local ARROW_DOWN = "\226\134\147"      -- ↓

-- TitledButtonDialog: a ButtonDialog-shaped popup with a TitleBar carrying a
-- left gear icon and a right close-X (ported from the owner's koassistant
-- fork so both plugins' panels feel the same). Built lazily on first open
-- (needs the widget stack) and cached; the harness overrides
-- M._panelDialogClass to capture the spec instead.
local TitledButtonDialog
local function buildTitledButtonDialogClass()
    local FocusManager = require("ui/widget/focusmanager")
    local ButtonTable = require("ui/widget/buttontable")
    local TitleBar = require("ui/widget/titlebar")
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local Size = require("ui/size")
    local Font = require("ui/font")
    local util = require("util")
    local Device = require("device")
    local Screen = Device.screen

    local Dlg = FocusManager:extend{}

    function Dlg:init()
        if not self.width then
            self.width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
        end
        if Device:hasKeys() then
            local back_group = util.tableDeepCopy(Device.input.group.Back)
            if Device:hasFewKeys() then
                table.insert(back_group, "Left")
            else
                table.insert(back_group, "Menu")
            end
            self.key_events.Close = { { back_group } }
        end
        if Device:isTouchDevice() then
            self.ges_events.TapClose = {
                GestureRange:new{ ges = "tap",
                    range = Geom:new{ x = 0, y = 0,
                        w = Screen:getWidth(), h = Screen:getHeight() } },
            }
        end
        local content_width = self.width - 2 * Size.border.window - 2 * Size.padding.button
        self.button_table = ButtonTable:new{
            buttons = self.buttons, width = content_width, show_parent = self,
        }
        local bt_width = self.button_table:getSize().w
        self.title_bar = TitleBar:new{
            width = bt_width, title = self.title or "",
            title_face = Font:getFace("infofont"),
            left_icon = self.left_icon or "appbar.settings",
            left_icon_tap_callback = self.left_icon_tap_callback or function() end,
            close_callback = function() self:onClose() end,
            with_bottom_line = true, bottom_line_color = Blitbuffer.COLOR_GRAY,
            show_parent = self,
        }
        local titlebar = self.title_bar
        local max_height = Screen:getHeight() - 2 * Size.padding.buttontable
            - 2 * Size.margin.default - titlebar:getSize().h
        local content
        if self.button_table:getSize().h > max_height then
            local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
            local VerticalSpan = require("ui/widget/verticalspan")
            self.button_table:setupGridScrollBehaviour()
            local grid = self.button_table:getStepScrollGrid()
            local row_h = grid[1].bottom + 1 - grid[1].top
            max_height = row_h * math.floor(max_height / row_h)
            self.cropping_widget = ScrollableContainer:new{
                dimen = Geom:new{ w = bt_width + ScrollableContainer:getScrollbarWidth(),
                    h = max_height },
                show_parent = self, step_scroll_grid = grid, self.button_table,
            }
            content = VerticalGroup:new{
                VerticalSpan:new{ width = Size.padding.buttontable },
                self.cropping_widget,
                VerticalSpan:new{ width = Size.padding.buttontable },
            }
        else
            content = self.button_table
        end
        self.movable = MovableContainer:new{
            FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
                radius = Size.radius.window, padding = Size.padding.button,
                padding_top = 0, padding_bottom = 0,
                VerticalGroup:new{ titlebar, content },
            },
        }
        self.layout = self.button_table.layout
        self.button_table.layout = nil
        self[1] = CenterContainer:new{ dimen = Screen:getSize(), self.movable }
    end
    function Dlg:onShow()
        UIManager:setDirty(self, function() return "ui", self.movable.dimen end)
    end
    function Dlg:onCloseWidget()
        UIManager:setDirty(nil, function() return "flashui", self.movable.dimen end)
    end
    function Dlg:onClose()
        if self.close_callback then self.close_callback() end
        UIManager:close(self)
        return true
    end
    function Dlg:onTapClose(_arg, ges)
        if ges.pos:notIntersectWith(self.movable.dimen) then self:onClose() end
        return true
    end
    function Dlg:paintTo(...)
        FocusManager.paintTo(self, ...)
        self.dimen = self.movable.dimen
    end
    return Dlg
end

--- The panel dialog class (cached). Overridden by the harness to a
--- spec-capturing stub. quran is unused at runtime (module-level cache).
function M._panelDialogClass(_quran)
    if not TitledButtonDialog then
        TitledButtonDialog = buildTitledButtonDialogClass()
    end
    return TitledButtonDialog
end

-- Canonical panel item order. Book and bookless items share one list; each
-- item's available(ctx) decides where it actually renders. Mark layers are
-- spliced in from the marks module so the order can't drift from LAYERS.
local PANEL_ORDER_HEAD = {
    "open_book", "this_surah", "surah_overview", "search", "browser",
    "library_assets", "header_bar", "juz_footer", "minimal_popups",
}
local PANEL_ORDER_TAIL = { "theme_headings", "more_settings" }

function M._panelDefaultOrder(quran)
    local order = {}
    for _, id in ipairs(PANEL_ORDER_HEAD) do order[#order + 1] = id end
    local marks = quran._marksModule and quran:_marksModule()
    if marks and marks.LAYERS then
        for _, l in ipairs(marks.LAYERS) do order[#order + 1] = "mark_" .. l.key end
    end
    for _, id in ipairs(PANEL_ORDER_TAIL) do order[#order + 1] = id end
    return order
end

-- Stored order reconciled with the current default: keep known ids in the
-- stored sequence, append any new defaults, drop ids no longer defined.
function M._panelOrder(quran)
    local default = M._panelDefaultOrder(quran)
    local stored = quran.settings and quran.settings:readSetting("quran_panel_order")
    if type(stored) ~= "table" then return default end
    local known = {}
    for _, id in ipairs(default) do known[id] = true end
    local seen, order = {}, {}
    for _, id in ipairs(stored) do
        if known[id] and not seen[id] then order[#order + 1] = id; seen[id] = true end
    end
    for _, id in ipairs(default) do
        if not seen[id] then order[#order + 1] = id; seen[id] = true end
    end
    return order
end

function M._panelEnabled(quran, id)
    return quran.settings:nilOrTrue("quran_panel_show_" .. id)
end

function M._panelToggleEnabled(quran, id)
    quran.settings:saveSetting("quran_panel_show_" .. id, not M._panelEnabled(quran, id))
    quran.settings:flush()
end

function M._panelMove(quran, id, dir)
    local order = M._panelOrder(quran)
    for i, x in ipairs(order) do
        if x == id then
            local j = (dir == "up") and (i - 1) or (i + 1)
            if j >= 1 and j <= #order then
                order[i], order[j] = order[j], order[i]
                quran.settings:saveSetting("quran_panel_order", order)
                quran.settings:flush()
            end
            return
        end
    end
end

-- Default LEFT-aligned, like koassistant's QS panel (toggle -> centered).
function M._panelLeftAlign(quran)
    return quran.settings:nilOrTrue("quran_panel_left_align")
end

function M._panelResetItems(quran)
    quran.settings:delSetting("quran_panel_order")
    for _, id in ipairs(M._panelDefaultOrder(quran)) do
        quran.settings:delSetting("quran_panel_show_" .. id)
    end
    quran.settings:flush()
end

-- id -> { label, available(ctx), build(quran, ctx, H) -> button-def or nil }.
-- Rebuilt per open (cheap); mark specs read their labels from the marks
-- module. H = { close_then, toggle_then, chip, notifyWarn, currentPosition }.
function M._panelRegistry(quran)
    local reg = {}
    local function inBook(ctx) return not ctx.bookless end
    local function always() return true end
    local function needsQul(ctx) return not ctx.bookless and ctx.has_qul end

    reg.open_book = { label = _("Open Quran book"),
        available = function(ctx) return ctx.bookless end,
        build = function(q, _ctx, H)
            return { text = _("Open Quran book") .. " \226\134\146",
                callback = H.close_then(function()
                    if q.openBookAt then q:openBookAt() end
                end),
                hold_callback = function()
                    H.notifyWarn(_("Open your preferred Quran book — connections and go-to land there."))
                end }
        end }

    reg.this_surah = { label = _("This surah"), available = inBook,
        build = function(q, _ctx, H)
            return { text = _("This surah") .. " \226\134\146",
                callback = H.close_then(function()
                    local s = H.currentPosition(q)
                    M.showBrowser(q, function(browser)
                        if s then
                            local sub_items, sub_title = browser:buildSurahItems(s)
                            browser:navigateForward(sub_title, sub_items)
                        end
                    end)
                end),
                hold_callback = function()
                    H.notifyWarn(_("This surah in the Explorer — go to it, overview, ayah list."))
                end }
        end }

    -- Row text "Read surah overview" (owner 2026-07-25, rides F31): the
    -- panel row is an action; the settings-list label stays the noun.
    reg.surah_overview = { label = _("Surah overview"), available = inBook,
        build = function(q, _ctx, H)
            return { text = _("Read surah overview"),
                callback = H.close_then(function() M.openSurahOverview(q) end) }
        end }

    reg.search = { label = _("Search"), available = always,
        build = function(q, _ctx, H)
            return { text = _("Search"),
                callback = H.close_then(function()
                    M.showBrowser(q, function(browser) browser:showGlobalSearch() end)
                end) }
        end }

    reg.browser = { label = _("Explorer"), available = always,
        build = function(q, _ctx, H)
            return { text = _("Explorer"),
                callback = H.close_then(function() M.showBrowser(q) end),
                hold_callback = function()
                    H.notifyWarn(_("Browse surahs, juz, topics, resources, and search in one window."))
                end }
        end }

    reg.library_assets = { label = _("Library & assets"),
        available = function(ctx) return ctx.bookless end,
        build = function(q, _ctx, H)
            return { text = _("Library & assets"),
                callback = H.close_then(function()
                    M.showBrowser(q, function(browser)
                        local assets = browser:assetsModule()
                        if assets then assets.showLibrary(browser) end
                    end)
                end),
                hold_callback = function()
                    H.notifyWarn(_("Install dictionaries, data packages, and Quran books."))
                end }
        end }

    reg.header_bar = { label = _("Header bar"), available = inBook,
        build = function(q, _ctx, H)
            return { text = H.chip(q.settings:isTrue("show_header_overlay"), _("Header bar")),
                callback = H.toggle_then(function() M.toggleHeader(q) end) }
        end }

    reg.juz_footer = { label = _("Juz in footer"), available = inBook,
        build = function(q, _ctx, H)
            return { text = H.chip(q.settings:nilOrTrue("show_juz_in_footer"), _("Juz in footer")),
                callback = H.toggle_then(function() M.toggleJuzFooter(q) end) }
        end }

    reg.minimal_popups = { label = _("Minimal popups"), available = inBook,
        build = function(q, _ctx, H)
            return { text = H.chip(q.settings:isTrue("quran_simple_mode"), _("Minimal popups")),
                callback = H.toggle_then(function()
                    q.settings:saveSetting("quran_simple_mode",
                        not q.settings:isTrue("quran_simple_mode"))
                    q.settings:flush()
                end),
                hold_callback = function()
                    H.notifyWarn(_("Minimal popups: ayah resources open in the quick dictionary popup by default instead of full-screen reading windows. Everything stays reachable."))
                end }
        end }

    reg.theme_headings = { label = _("Theme headings"), available = needsQul,
        build = function(q, _ctx, H)
            local bands = q._bandsModule and q:_bandsModule()
            if not bands then return nil end
            return { text = H.chip(bands.enabled(q), _("Theme headings")),
                callback = H.toggle_then(function()
                    local ok, err = bands.setEnabled(q, not bands.enabled(q))
                    if not ok and err then H.notifyWarn(err) end
                end),
                hold_callback = function()
                    H.notifyWarn(_("Theme headings between ayah groups, Clear-Quran style (re-renders the book when toggled)."))
                end }
        end }

    reg.more_settings = { label = _("More settings…"), available = always,
        build = function(q, _ctx, H)
            return { text = _("More settings…"),
                callback = H.close_then(function()
                    if q.showSettingsMenu then q:showSettingsMenu() end
                end),
                hold_callback = function()
                    H.notifyWarn(_("All Quran Helper settings — same menu as the top menu bar entry."))
                end }
        end }

    -- Mark layers (labels from the marks module; render only with qul).
    local marks = quran._marksModule and quran:_marksModule()
    if marks and marks.LAYERS then
        for _li, l in ipairs(marks.LAYERS) do
            local key = l.key
            local label = _("Mark") .. " " .. l.label:lower()
            reg["mark_" .. key] = { label = label, available = needsQul,
                build = function(q, _ctx, H)
                    return { text = H.chip(marks.enabled(q, key), label),
                        callback = H.toggle_then(function()
                            marks.setEnabled(q, key, not marks.enabled(q, key))
                        end) }
                end }
        end
    end

    return reg
end

function M.showQuickPanel(quran)
    -- ⑤C: bookless (the FileManager instance) gets a launcher shape; only a
    -- non-Quran BOOK refuses (inert there, like gestures).
    local bookless = not (quran.ui and quran.ui.document)
    if not quran._is_quran_book and not bookless then
        notifyWarn(_("Quick panel is only available in a Quran book."))
        return
    end

    local ctx = { bookless = bookless }
    local surah, ayah
    if not bookless then
        surah, ayah = currentPosition(quran)
        ctx.surah, ctx.ayah = surah, ayah
        local qul = quran._qulModule and quran:_qulModule()
        ctx.has_qul = (qul and qul.ensureDb and qul.ensureDb(quran)) and true or false
    end

    local title = _("Quran quick panel")
    if surah then
        local name = quran:surahName(surah) or ("Surah " .. surah)
        if ayah then
            title = string.format("%s  %d:%d", name, surah, ayah)
        else
            title = name
        end
        local juz = quran:_getCurrentJuz()
        if juz then title = title .. MIDDOT .. _("Juz") .. " " .. juz end
    end

    local dialog
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
            M.showQuickPanel(quran)   -- reopen with fresh chip states
        end
    end
    local function chip(on, label) return (on and CHECK or "") .. label end
    local H = { close_then = close_then, toggle_then = toggle_then, chip = chip,
        notifyWarn = notifyWarn, currentPosition = currentPosition }

    local left_align = M._panelLeftAlign(quran)
    local reg = M._panelRegistry(quran)
    local flat = {}
    for _, id in ipairs(M._panelOrder(quran)) do
        local spec = reg[id]
        if spec and spec.available(ctx) and M._panelEnabled(quran, id) then
            local btn = spec.build(quran, ctx, H)
            if btn then
                btn.font_bold = false
                if left_align then btn.align = "left" end
                flat[#flat + 1] = btn
            end
        end
    end
    -- Everything hidden/unavailable -> keep a single door to settings.
    if #flat == 0 then
        flat[1] = { text = _("More settings…"), font_bold = false,
            align = left_align and "left" or nil,
            callback = close_then(function()
                if quran.showSettingsMenu then quran:showSettingsMenu() end
            end) }
    end

    -- 2-per-row grid; center a lone last cell when left-aligned (koassistant).
    local buttons = {}
    for i = 1, #flat, 2 do
        if flat[i + 1] then buttons[#buttons + 1] = { flat[i], flat[i + 1] }
        else buttons[#buttons + 1] = { flat[i] } end
    end
    if left_align and #buttons > 0 and #buttons[#buttons] == 1 then
        buttons[#buttons][1].align = "center"
    end

    local Dlg = M._panelDialogClass(quran)
    if Dlg then
        dialog = Dlg:new{
            title = title,
            buttons = buttons,
            left_icon_tap_callback = function() M._showPanelGear(quran, dialog, ctx) end,
            close_callback = function() quran._quick_panel_dialog = nil end,
        }
    else
        -- Defensive fallback (widget stack unavailable): plain centered dialog.
        local ButtonDialog = require("ui/widget/buttondialog")
        dialog = ButtonDialog:new{ title = title, title_align = "center",
            buttons = buttons,
            tap_close_callback = function() quran._quick_panel_dialog = nil end }
    end
    quran._quick_panel_dialog = dialog
    UIManager:show(dialog)
end

--- Gear menu (anchored under the title-bar gear): the organizer + align.
function M._showPanelGear(quran, dialog, ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local left_align = M._panelLeftAlign(quran)
    local gear
    gear = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function()
            return dialog.title_bar.left_button.image.dimen, true
        end,
        buttons = {
            {{ text = _("Panel items"), align = "left", callback = function()
                UIManager:close(gear)
                UIManager:close(dialog)
                quran._quick_panel_dialog = nil
                M._showPanelOrganizer(quran, function() M.showQuickPanel(quran) end)
            end }},
            {{ text = left_align and (_("Align buttons") .. " " .. "\226\156\147")
                        or _("Align buttons"),
               align = "left", callback = function()
                UIManager:close(gear)
                quran.settings:saveSetting("quran_panel_left_align", not left_align)
                quran.settings:flush()
                UIManager:close(dialog)
                quran._quick_panel_dialog = nil
                M.showQuickPanel(quran)
            end }},
        },
    }
    UIManager:show(gear)
end

--- Organizer rows: dim help line + one row per item ("✓/  " + [pos] + label).
-- Tap toggles visibility; hold reorders. Shows ALL items (both contexts), so
-- ordering is unambiguous — availability only gates the panel itself.
function M._panelMenuItems(quran, reg, bold_id)
    local items = { { text = _("✓ = shown   ·   Tap = toggle   ·   Hold = move   ·   \226\152\176 = reset"),
        dim = true, callback = function() end } }
    local count = 0
    for pos, id in ipairs(M._panelOrder(quran)) do
        local spec = reg[id]
        local on = M._panelEnabled(quran, id)
        if on then count = count + 1 end
        items[#items + 1] = {
            text = (on and CHECK_PREFIX or "  ") .. "[" .. pos .. "] " .. (spec and spec.label or id),
            item_id = id, position = pos, bold = (id == bold_id),
            callback = function()
                M._panelToggleEnabled(quran, id)
                UIManager:nextTick(function() M._refreshPanelOrganizer(quran, reg) end)
            end,
        }
    end
    return items, count
end

function M._refreshPanelOrganizer(quran, reg, bold_id)
    local menu = quran._panel_organizer
    if not menu then return end
    local items, count = M._panelMenuItems(quran, reg, bold_id)
    menu:switchItemTable(_("Quick panel items") .. " (" .. count .. ")", items, -1)
end

-- Hold options: persistent ↑/↓ to reorder (koassistant's showOrderItemOptions).
function M._showPanelOrderOptions(quran, reg, id, index)
    local order = M._panelOrder(quran)
    local total = #order
    if total <= 1 then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local function reshow()
        M._refreshPanelOrganizer(quran, reg, id)
        for i, x in ipairs(M._panelOrder(quran)) do
            if x == id then M._showPanelOrderOptions(quran, reg, id, i); break end
        end
    end
    dlg = ButtonDialog:new{
        shrink_unneeded_width = true,
        buttons = { {
            { text = ARROW_UP, enabled = index > 1, callback = function()
                M._panelMove(quran, id, "up")
                UIManager:close(dlg)
                reshow()
            end },
            { text = ARROW_DOWN, enabled = index < total, callback = function()
                M._panelMove(quran, id, "down")
                UIManager:close(dlg)
                reshow()
            end },
        } },
        tap_close_callback = function() M._refreshPanelOrganizer(quran, reg) end,
    }
    UIManager:show(dlg)
end

--- The fullscreen sort/enable/disable organizer for the panel items.
function M._showPanelOrganizer(quran, on_close)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    local reg = M._panelRegistry(quran)
    local items, count = M._panelMenuItems(quran, reg)
    local menu
    menu = Menu:new{
        title = _("Quick panel items") .. " (" .. count .. ")",
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local ButtonDialog = require("ui/widget/buttondialog")
            local reset_dialog
            reset_dialog = ButtonDialog:new{
                shrink_unneeded_width = true,
                buttons = { {
                    { text = _("Reset to defaults"), align = "left", callback = function()
                        UIManager:close(reset_dialog)
                        M._panelResetItems(quran)
                        M._refreshPanelOrganizer(quran, reg)
                    end },
                } },
            }
            UIManager:show(reset_dialog)
        end,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = on_close,
    }
    menu.onMenuSelect = function(_self, item)
        if item and item.callback then item.callback() end
        return true
    end
    menu.onMenuHold = function(_self, item)
        if item and item.item_id then
            M._refreshPanelOrganizer(quran, reg, item.item_id)  -- bold the held row
            M._showPanelOrderOptions(quran, reg, item.item_id, item.position)
        end
        return true
    end
    quran._panel_organizer = menu
    UIManager:show(menu)
end

return M
