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

function Browser:navigateForward(title, items, focus_idx, opts)
    if not self.menu then return end
    table.insert(self.nav_stack, {
        title = self.current_title,
        items = self.menu.item_table,
        single_line = self.menu.single_line,
        items_max_lines = self.menu.items_max_lines,
    })
    self.current_title = title
    -- D-R3-6: long titles (themes) must not truncate — a screen can opt
    -- into two-line rows. items_max_lines is the Menu mechanism that
    -- actually delivers wrapped rows (variable item heights + its own
    -- pagination); bare single_line=false gets forced back to single
    -- line in MenuItem:init when the font outgrows the fixed slot.
    -- switchItemTable rebuilds items, navigateBack restores the frame.
    local multiline = opts and opts.multiline
    self.menu.single_line = not multiline
    self.menu.items_max_lines = multiline and 2 or nil
    table.insert(self.menu.paths, true)  -- enables the back arrow
    self.menu:switchItemTable(title, items, focus_idx)
end

--- Rebuild the CURRENT screen's items in place (expand/collapse
-- toggles) — no nav_stack push, so ← still leaves the screen in one
-- tap. focus_idx keeps the tapped row on the visible page.
function Browser:refreshScreen(items, focus_idx)
    if not self.menu then return end
    self.menu:switchItemTable(self.current_title, items, focus_idx)
end

function Browser:navigateBack()
    if not self.menu then return end
    if #self.nav_stack == 0 then
        UIManager:close(self.menu)
        return
    end
    local prev = table.remove(self.nav_stack)
    self.current_title = prev.title
    self.menu.single_line = prev.single_line
    self.menu.items_max_lines = prev.items_max_lines
    table.remove(self.menu.paths)
    self.menu:switchItemTable(prev.title, prev.items, -1)
end

-- The Reader back label for surfaces launched from the LIVE browser
-- screen: a BARE arrow (D-R3-8 hybrid, owner 2026-07-17) — the browser
-- screen sits visually right beneath, and live-title labels kept
-- drifting (three distinct bugs in round 3). Accurate labels remain on
-- the Reader's own hop stack, where they carry real information.
function Browser:backLabel()
    return "←"
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

function Browser:connectionsModule()
    return loadSibling(self.quran, "_connections_mod", "quran_connections.lua")
end

function Browser:masaqModule()
    return loadSibling(self.quran, "_masaq_mod", "quran_masaq.lua")
end

--- One-line text input (search boxes). on_query gets the raw string
-- (only called for non-blank input).
function Browser:promptSearch(title, on_query)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = "",
        buttons = { {
            {
                text = _("Cancel"), id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"), is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText()
                    UIManager:close(dialog)
                    if q and q:match("%S") then on_query(q) end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

-- UTF-8-safe prefix snippet for result rows.
local function snippet(s, n)
    s = (s or ""):gsub("%s+", " ")
    if #s <= n then return s end
    local cut = s:sub(1, n)
    cut = cut:gsub("[\128-\191]+$", "")     -- trailing continuation bytes
    cut = cut:gsub("[\194-\244]$", "")      -- dangling lead byte
    return cut .. "…"
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

-- Jump to the START of an ayah. The anchor to resolve depends on the
-- book's anchor convention (actions.anchorConvention, probed once):
-- ayah layouts put the id on the ayah's own block → resolve anchor A;
-- flow layouts put it on the inline END marker → the start of A is the
-- end of A−1, so resolve anchor A−1 (this used to be unconditional and
-- landed one ayah early in ayah-by-ayah books). Anchor pages resolve
-- through actions.resolveAnchorPage (fragment-prefixed ids — plain
-- "#ayah-…" never resolves in EPUBs).
function Browser:gotoAyah(surah, ayah)
    -- D-R3-19: bookless (FileManager entry) — route through the
    -- preferred-book seam. The ayah reaching here is effectively Hafs
    -- (bookless riwayah conversion at the call sites is identity);
    -- the pending jump re-converts on the OPENED book's instance.
    local quran = self.quran
    if not (quran.ui and quran.ui.document) then
        if quran.openBookAt then
            self:closeThen(function() quran:openBookAt(surah, ayah) end)()
        end
        return
    end
    local page
    if ayah and ayah > 1 then
        local conv = self.actions.anchorConvention
            and self.actions.anchorConvention(self.quran) or "end"
        page = self.actions.resolveAnchorPage(self.quran, surah,
            conv == "start" and ayah or (ayah - 1))
    else
        page = self.actions.resolveAnchorPage(self.quran, surah, nil)
    end
    self:gotoPage(page)
end

-- ---------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Global search (design D6): one box over ayah text + translation
-- (FTS5, quran_text package), topics + themes (LIKE, qul package), and
-- roots (LIKE, lane package). Absent packages are silently omitted;
-- every hit routes to its canonical screen (ayahs → the unified ayah
-- page). All references Hafs-canonical (D8).
-- ---------------------------------------------------------------------

function Browser:showGlobalSearch()
    self:promptSearch(_("Search Quran text, topics, themes, roots"),
        function(q) self:showSearchResults(q) end)
end

function Browser:showSearchResults(q)
    local quran = self.quran
    local items = {
        {
            text = _("Search again"),
            separator = true,
            callback = function() self:showGlobalSearch() end,
        },
    }
    local function endGroup()
        if #items > 1 then items[#items].separator = true end
    end

    -- Ayah text + translation (FTS5 over pre-normalized columns)
    local qn = loadSibling(quran, "_norm_mod", "quran_norm.lua")
    local qt = loadSibling(quran, "_text_mod", "quran_text.lua")
    local tconn = qt and select(1, qt.ensureDb(quran))
    if tconn and qn then
        local nq = qn.norm(q)
        if nq ~= "" then
            -- prefix-match the last term ("entire merc" still hits)
            local fts = nq:gsub("(%S+)$", "%1*")
            for _i, h in ipairs(qt.searchAyahText(tconn, fts, 20)) do
                table.insert(items, {
                    text = string.format("%d:%d  %s", h.surah, h.ayah,
                        snippet(h.text, 60)),
                    callback = function()
                        self:showAyahPage(h.surah, h.ayah)
                    end,
                })
            end
            endGroup()
            for _i, h in ipairs(qt.searchTranslation(tconn, fts, 20)) do
                table.insert(items, {
                    text = string.format("%d:%d  %s", h.surah, h.ayah,
                        snippet(h.text, 60)),
                    callback = function()
                        self:showAyahPage(h.surah, h.ayah)
                    end,
                })
            end
            endGroup()
        end
    end

    -- Topics + themes (qul package)
    local qul = self:qulModule()
    local qconn = qul and qul.searchTopics and select(1, qul.ensureDb(quran))
    if qconn then
        for _i, t in ipairs(qul.searchTopics(qconn, q, 20)) do
            local label = t.name
            if t.arabic_name and t.arabic_name ~= "" then
                label = label .. "  " .. t.arabic_name
            end
            table.insert(items, {
                text = _("Topic") .. ": " .. label,
                mandatory = t.n_ayahs and t.n_ayahs > 0
                    and ("×" .. t.n_ayahs) or nil,
                callback = function() qul.showTopic(self, t.topic_id) end,
            })
        end
        endGroup()
        for _i, th in ipairs(qul.searchThemes(qconn, q, 10)) do
            local theme = th
            table.insert(items, {
                text = _("Theme") .. ": " .. snippet(th.theme, 50),
                mandatory = string.format("%d:%d", th.surah, th.ayah_from),
                callback = function() qul.showTheme(self, theme) end,
            })
        end
        endGroup()
    end

    -- Roots (lane package)
    local roots = self:rootsModule()
    local rconn = roots and roots.searchRoots and select(1, roots.ensureDb(quran))
    if rconn then
        for _i, r in ipairs(roots.searchRoots(rconn, q, 10)) do
            table.insert(items, {
                text = _("Root") .. ": " .. roots.rootItemText(r),
                mandatory = roots.rootItemMandatory(r),
                callback = function() roots.showRoot(self, r.arabic) end,
            })
        end
    end

    if #items <= 1 then
        notifyWarn(_("No results for:") .. " " .. q)
        return
    end
    self:navigateForward(_("Search") .. ": " .. q, items)
end

-- The UNIFIED AYAH PAGE (design D4): the one canonical screen per S:A —
-- every ayah reference in the hub routes here; it is also the
-- Current-position landing. hafs_ayah is Hafs-numbered (the canonical
-- key of all connection data, invariant D8); jumps convert to book
-- numbering at the boundary. opts.range = {first, last} (book-space
-- visible range, position landing only) — shown in the title.
function Browser:showAyahPage(surah, hafs_ayah, opts)
    opts = opts or {}
    local quran, actions = self.quran, self.actions
    local name = quran:surahName(surah) or ("Surah " .. surah)
    local title
    if opts.range and opts.range[2] and opts.range[2] > opts.range[1] then
        title = string.format("%s %d:%d\226\128\147%d", name, surah,
            opts.range[1], opts.range[2])
    else
        title = string.format("%s %d:%d", name, surah, hafs_ayah)
    end

    local items = {}
    -- Reading surfaces (all in-browser; the dict popup stays an in-book
    -- long-press surface — design D3)
    table.insert(items, {
        text = _("Translations"),
        callback = function()
            local reader = quran._readerModule and quran:_readerModule()
            local ok = reader and reader.showAyah(quran, surah, hafs_ayah,
                { back_label = self:backLabel() })
            if not ok then
                self:closeThen(function()
                    quran:openAyahPopup(surah, hafs_ayah)
                end)()
            end
        end,
    })
    table.insert(items, {
        text = _("Go to this ayah in the book"),
        callback = function()
            -- FIRST covering book ayah (split-aware): landing must be the
            -- start of the Hafs ayah, not its last Warsh sub-ayah
            local book_a = hafs_ayah > 1
                and (quran._hafsToWarshStart
                    and quran:_hafsToWarshStart(surah, hafs_ayah)
                    or quran:_hafsToWarsh(surah, hafs_ayah))
                or hafs_ayah
            self:gotoAyah(surah, book_a)
        end,
    })
    local res = actions.detectResources(quran)
    -- R3-F19: a resource row with NO entry for this ayah is dimmed and
    -- answers with a toast instead of opening onto a "none" message
    -- (sparse corpora — asbab covers ~5% of ayahs). Coverage comes from
    -- the dict's own .idx (cached parse).
    local function dictCovers(dict_name)
        if not (dict_name and quran._dictAyahItems) then return true end
        local all = select(1, quran:_dictAyahItems(dict_name))
        if not all then return true end
        for _i, it in ipairs(all) do
            if it.surah == surah and it.a1 and hafs_ayah >= it.a1
                    and hafs_ayah <= (it.a2 or it.a1) then
                return true
            end
        end
        return false
    end
    -- fallback_name: the dict the LEGACY popup path filters to when the
    -- Reader is unavailable (pre-rawSdcv KOReader) and no explicit dict
    -- was given — preferred tafsir, else the single/first installed one
    local function dictItem(label, dict_name, fallback_name)
        local covered = dictCovers(dict_name or fallback_name)
        table.insert(items, {
            text = label,
            dim = not covered or nil,
            callback = covered and function()
                local opened = quran.openTafsirReader
                    and quran:openTafsirReader(surah, hafs_ayah, {
                        dict = dict_name,
                        back_label = self:backLabel(),
                    })
                if not opened then
                    -- pre-rawSdcv KOReader: popup flow
                    self:closeThen(function()
                        quran._dict_first_name = dict_name or fallback_name
                        quran:openAyahPopup(surah, hafs_ayah)
                    end)()
                end
            end or function()
                notifyWarn(string.format(
                    _("No %s entry recorded for this ayah."), label))
            end,
        })
    end
    if #res.tafsir > 0 then
        local preferred = quran.settings and quran.settings.readSetting
            and quran.settings:readSetting("preferred_tafsir") or nil
        local fallback_tafsir = res.tafsir[1]
        for _idx, nm in ipairs(res.tafsir) do
            if nm == preferred then fallback_tafsir = nm end
        end
        dictItem(_("Tafsir"), nil, fallback_tafsir)
    end
    if res.asbab then dictItem(_("Asbab al-Nuzul"), res.asbab) end
    if res.irab then dictItem(_("I'rab"), res.irab) end
    if res.grammar then dictItem(_("Grammar"), res.grammar) end
    -- MASAQ word-by-word i'rab (quran_masaq data package; isolated NC
    -- pack — never merged into the dicts). Row present only with the
    -- package installed, like the dict rows above.
    local masaq = self:masaqModule()
    local okm, mconn = pcall(function()
        return masaq and masaq.ensureDb
            and (select(1, masaq.ensureDb(quran))) or nil
    end)
    if okm and mconn then
        table.insert(items, {
            -- source tag in the row name (owner G2 decision 2026-07-18):
            -- "Grammar" above is the EQTB ayah walkthrough; this is
            -- MASAQ's independent per-word i'rab — say so at the entry
            text = _("Word grammar (MASAQ)"),
            callback = function()
                masaq.showAyah(self, surah, hafs_ayah)
            end,
        })
    end
    if #items > 0 then items[#items].separator = true end

    -- QUL connections (counts; zero-count rows DIMMED, not hidden —
    -- R3-F19 + the D-R3-5 stable-shape principle; D4's hiding retired)
    local qul = self:qulModule()
    local conn = qul and select(1, qul.ensureDb(quran))
    -- DA-7 connections package (characters/stories/semantic pairs);
    -- probes pcall-guarded like the root's
    local cx = self:connectionsModule()
    local okc, cconn = pcall(function()
        return cx and cx.ensureDb and (select(1, cx.ensureDb(quran))) or nil
    end)
    cconn = okc and cconn or nil
    -- semantic pairs NOT already in the wording-match list (the union
    -- is one "Similar ayahs" surface, sections labeled inside)
    local function semanticExtra(wording)
        if not cconn then return 0 end
        local sem = cx.semanticFor(cconn, surah, hafs_ayah,
            cx.semanticFloor(quran))
        return #cx.diffPairs(sem, wording)
    end
    local function connItem(n, label, fn)
        local live = n and n > 0
        table.insert(items, {
            text = label,
            mandatory = tostring(n or 0),
            dim = not live or nil,
            callback = live and function()
                fn(self, surah, hafs_ayah)
            end or function()
                notifyWarn(string.format(
                    _("No %s recorded for this ayah."),
                    label:lower()))
            end,
        })
    end
    if conn then
        local sim_min = qul.similarMinScore
            and qul.similarMinScore(self.quran) or 80
        local counts = qul.countsFor(conn, surah, hafs_ayah, sim_min)
        if counts then
            -- D-R3-4 canonical names + card row order (Similar ayahs /
            -- Themes / Repeated phrases / Topics)
            connItem(counts.similar + semanticExtra(
                qul.similarFor(conn, surah, hafs_ayah, sim_min)),
                _("Similar ayahs"), qul.showSimilar)
            connItem(counts.themes, _("Themes"), qul.showThemesFor)
            connItem(counts.phrases, _("Repeated phrases (mutashabihat)"),
                qul.showMutashabihat)
            connItem(counts.topics, _("Topics"), qul.showTopicsFor)
        end
    elseif cconn and qul then
        -- no qul package: the semantic tier still feeds the same
        -- Similar surface (qul.showSimilar renders both layers)
        connItem(semanticExtra({}), _("Similar ayahs"), qul.showSimilar)
    end
    if cconn then
        connItem(#cx.figuresAt(cconn, surah, hafs_ayah), _("Figures"),
            function(b, s2, a2) cx.showFiguresAt(b, s2, a2) end)
        connItem(#cx.unitsContaining(cconn, surah, hafs_ayah),
            _("Narrative context"),
            function(b, s2, a2) cx.showStoryContext(b, s2, a2) end)
    end
    if (conn or cconn) and #items > 0 then
        items[#items].separator = true
    end

    -- Surah context (overview renders in-browser when the Reader path is
    -- available; the popup remains the pre-rawSdcv fallback — and the
    -- D-R3-2 Simple-mode / per-item target when set)
    table.insert(items, {
        text = _("Surah overview"),
        callback = function()
            local use_reader = not (quran._openTargetFor
                and quran:_openTargetFor("overview") == "popup")
            local reader = quran._readerModule and quran:_readerModule()
            local opened = use_reader and reader and reader.showOverview
                and res.overview
                and quran.canReaderTafsir and quran:canReaderTafsir()
                and reader.showOverview(quran, surah,
                    { dict = res.overview, back_label = self:backLabel() })
            if not opened then
                self:closeThen(function()
                    quran:openSurahOverviewPopup(surah)
                end)()
            end
        end,
    })
    table.insert(items, {
        text = _("Other ayahs in this surah"),
        callback = function() self:showAyahList(surah) end,
    })
    self:navigateForward(title, items)
end

-- Current position lands on the unified ayah page for the first visible
-- ayah, titled with the full visible range (design D4 / issue 3).
function Browser:showPosition()
    local quran, actions = self.quran, self.actions
    local surah, first, last
    if actions.visibleAyahRange then
        surah, first, last = actions.visibleAyahRange(quran)
    end
    if not surah then
        notifyWarn(_("Could not determine the current position."))
        return
    end
    if not first then
        -- anchorless (pre-v0.11) book: surah-level page
        local sub_items, sub_title = self:buildSurahItems(surah)
        self:navigateForward(sub_title, sub_items)
        return
    end
    -- The hub is Hafs-canonical (D8): titles and labels use Hafs numbers
    -- so a tap never renumbers the ayah it opens.
    local hafs_first = quran._warshToHafs
        and quran:_warshToHafs(surah, first) or first
    local hafs_last = quran._warshToHafs
        and quran:_warshToHafs(surah, last) or last
    self:showAyahPage(surah, hafs_first, { range = { hafs_first, hafs_last } })
end

function Browser:showAyahList(surah)
    local quran = self.quran
    local count = quran:bookAyahCount(surah) or 0
    local name = quran:surahName(surah) or ("Surah " .. surah)
    local items = {}
    for a = 1, count do
        local hafs = quran:_warshToHafs(surah, a)
        -- Hafs label (matches the ayah page it opens); the book-native
        -- number rides along when the two diverge (Warsh books)
        table.insert(items, {
            text = string.format("%s %d:%d", name, surah, hafs),
            mandatory = (hafs ~= a) and tostring(a) or nil,
            callback = function()
                self:showAyahPage(surah, hafs)
            end,
        })
    end
    self:navigateForward(name, items)
end

--- The surah screen is a HUB (owner 2026-07-17 batch 5: "high
-- availability" — every layer reachable from the surah): position
-- rows, this surah's corpus entries (tafsir/asbab/grammar/i'rab), and
-- its connections (themes/topics/similar/repeated phrases), all with
-- counts, dimmed when empty (F19/F20 idiom). Narratives join when the
-- DA-7 connections extract lands.
function Browser:buildSurahItems(surah)
    local quran = self.quran
    local name = quran:surahName(surah) or ("Surah " .. surah)
    local res = self.actions.detectResources(quran)
    local items = {
        {
            text = _("Go to surah"),
            callback = function() self:gotoAyah(surah, 1) end,
        },
        {
            text = _("Surah overview"),
            dim = not res.overview or nil,
            -- R3-F18: the SAME unified route as the ayah page and the
            -- quick panel (this row predated the unified reading
            -- system and always opened the popup — with the panel on
            -- the Reader route the two felt opposite, owner batch 4)
            callback = function()
                if not res.overview then
                    notifyWarn(_("No surah-overview dictionary installed (Library & assets)."))
                    return
                end
                local use_reader = not (quran._openTargetFor
                    and quran:_openTargetFor("overview") == "popup")
                local reader = quran._readerModule and quran:_readerModule()
                local opened = use_reader and reader and reader.showOverview
                    and quran.canReaderTafsir and quran:canReaderTafsir()
                    and reader.showOverview(quran, surah,
                        { dict = res.overview, back_label = self:backLabel() })
                if not opened then
                    self:closeThen(function()
                        quran:openSurahOverviewPopup(surah)
                    end)()
                end
            end,
        },
        {
            -- R3-F20: known numbers sit in the count column
            text = _("Ayahs"),
            mandatory = tostring(quran:bookAyahCount(surah) or "?"),
            separator = true,
            callback = function() self:showAyahList(surah) end,
        },
    }

    -- This surah in each installed corpus (entry counts from the
    -- dict's own .idx; multi-tafsir opens a picker like the root row)
    local function corpusCount(dict_name)
        if not (dict_name and quran._dictAyahItems) then return nil end
        local by = select(2, quran:_dictAyahItems(dict_name))
        return by and (by[surah] or 0) or nil
    end
    if #res.tafsir > 0 then
        local n = #res.tafsir == 1 and corpusCount(res.tafsir[1]) or nil
        table.insert(items, {
            text = _("Tafsir"),
            mandatory = n and tostring(n) or tostring(#res.tafsir),
            dim = (n == 0) or nil,
            callback = function()
                if n == 0 then
                    notifyWarn(_("No Tafsir entry recorded for this surah."))
                    return
                end
                if #res.tafsir == 1 then
                    self:showDictSurah(res.tafsir[1], "tafsir", surah)
                    return
                end
                local titems = {}
                for _i, tname in ipairs(res.tafsir) do
                    table.insert(titems, {
                        text = tname,
                        callback = function()
                            self:showDictSurah(tname, "tafsir", surah)
                        end,
                    })
                end
                self:navigateForward(_("Tafsir") .. " \194\183 " .. name, titems)
            end,
        })
    end
    local function corpusRow(label, dict_name, kind)
        if not dict_name then return end
        local n = corpusCount(dict_name)
        table.insert(items, {
            text = label,
            mandatory = n and tostring(n) or nil,
            dim = (n == 0) or nil,
            callback = function()
                if n == 0 then
                    notifyWarn(string.format(
                        _("No %s entry recorded for this surah."), label))
                    return
                end
                self:showDictSurah(dict_name, kind, surah)
            end,
        })
    end
    corpusRow(_("Asbab al-Nuzul"), res.asbab, "asbab")
    if #items > 3 then items[#items].separator = true end

    -- Connections scoped to this surah (counts; dim-not-hidden). The
    -- qul probe is pcall-guarded like the root's.
    local qul = self:qulModule()
    local okq, conn = pcall(function()
        return qul and qul.ensureDb and (select(1, qul.ensureDb(quran)))
            or nil
    end)
    conn = okq and conn or nil
    local function connRow(label, n, fn)
        local live = conn and n and n > 0
        table.insert(items, {
            text = label,
            mandatory = conn and tostring(n or 0) or nil,
            dim = not live or nil,
            callback = live and function() fn() end or function()
                notifyWarn(conn
                    and string.format(
                        _("No %s recorded in this surah."), label:lower())
                    or _("Connections need the qul data package (Library & assets)."))
            end,
        })
    end
    local n_themes = conn and #qul.themesBySurah(conn, surah) or 0
    connRow(_("Themes"), n_themes, function()
        local list = qul.themesBySurah(conn, surah)
        qul.showThemeItems(self, list, _("Themes") .. " \194\183 " .. name,
            { flow = true })
    end)
    local n_topics = conn and qul.topicsForSurahCount
        and qul.topicsForSurahCount(conn, surah) or 0
    connRow(_("Topics"), n_topics, function()
        qul.showTopicsForSurah(self, surah)
    end)
    local n_similar = conn and qul.similarBySurah
        and #qul.similarBySurah(conn, surah,
            qul.similarMinScore and qul.similarMinScore(quran) or 80) or 0
    connRow(_("Similar ayahs"), n_similar, function()
        qul.showSimilarBySurah(self, surah)
    end)
    local n_phrases = conn and qul.phrasesInSurah
        and #qul.phrasesInSurah(conn, surah) or 0
    connRow(_("Repeated phrases (mutashabihat)"), n_phrases, function()
        qul.showPhrasesInSurah(self, surah)
    end)

    -- DA-7 connections package rows (the hub promise: narratives join
    -- when the extract lands — Figures and Stories scoped to this
    -- surah; same dim-not-dead idiom)
    local cx = self:connectionsModule()
    local okc, cconn = pcall(function()
        return cx and cx.ensureDb and (select(1, cx.ensureDb(quran)))
            or nil
    end)
    cconn = okc and cconn or nil
    local function cxRow(label, n, fn)
        local live = cconn and n and n > 0
        table.insert(items, {
            text = label,
            mandatory = cconn and tostring(n or 0) or nil,
            dim = not live or nil,
            callback = live and function() fn() end or function()
                notifyWarn(cconn
                    and string.format(
                        _("No %s recorded in this surah."), label:lower())
                    or _("Figures and narratives need the quran_connections data package (Library & assets)."))
            end,
        })
    end
    local n_figs = cconn and #cx.figuresInSurah(cconn, surah) or 0
    cxRow(_("Figures"), n_figs, function()
        cx.showFiguresInSurah(self, surah)
    end)
    local n_units = cconn and #cx.unitsInSurah(cconn, surah) or 0
    cxRow(_("Narratives"), n_units, function()
        cx.showStoriesInSurah(self, surah)
    end)
    items[#items].separator = true

    -- The linguistic trio closes the hub (D-R3-18: "grammar/i'rab much
    -- lower" — content discovery above, analysis layers beneath), with
    -- the MASAQ browse row joining for parity (owner 2026-07-18)
    corpusRow(_("Grammar"), res.grammar, "grammar")
    corpusRow(_("I'rab"), res.irab, "irab")
    do
        local masaq = self:masaqModule()
        local okm, mconn = pcall(function()
            return masaq and masaq.ensureDb
                and (select(1, masaq.ensureDb(quran))) or nil
        end)
        mconn = okm and mconn or nil
        local n = mconn and #masaq.ayahsCovered(mconn, surah) or nil
        table.insert(items, {
            text = _("Word grammar (MASAQ)"),
            mandatory = n and tostring(n) or nil,
            dim = not mconn or (n == 0) or nil,
            callback = function()
                if not (masaq and mconn) then
                    notifyWarn(_("Word grammar needs the quran_masaq data package (Library & assets)."))
                    return
                end
                if n == 0 then
                    notifyWarn(_("No word grammar recorded for this surah."))
                    return
                end
                masaq.showSurah(self, surah)
            end,
        })
    end

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

-- ---------------------------------------------------------------------
-- Content-first resource browsing (design D-R2-2 → D-R3-7a): every
-- installed ayah-keyed StarDict corpus (tafsirs, asbab, grammar, i'rab,
-- overviews) is browsable as ITEMS, independent of the current
-- position, from its own ROOT row (grammar is ayah-keyed like tafsir —
-- owner report R3-F8). Entries are enumerated from the dict's own .idx
-- (Quran:_dictAyahItems).
-- ---------------------------------------------------------------------

--- Browse one resource: overviews → surah rows straight into the
-- Reader; ayah-keyed corpora → surahs that HAVE entries (with counts).
function Browser:showDictBrowse(dict_name, kind)
    local quran = self.quran
    local all, by_surah = quran:_dictAyahItems(dict_name)
    if not all or #all == 0 then
        notifyWarn(_("Could not read this dictionary's index."))
        return
    end
    local items = {}
    if kind == "overview" then
        for _i, it in ipairs(all) do
            local name = quran:surahName(it.surah) or ("Surah " .. it.surah)
            table.insert(items, {
                text = string.format("%d. %s", it.surah, name),
                callback = function()
                    self:openResourceEntry(dict_name, kind, it)
                end,
            })
        end
    else
        for s = 1, 114 do
            local n = by_surah[s]
            if n and n > 0 then
                local name = quran:surahName(s) or ("Surah " .. s)
                table.insert(items, {
                    text = string.format("%d. %s", s, name),
                    mandatory = tostring(n),
                    callback = function()
                        self:showDictSurah(dict_name, kind, s)
                    end,
                })
            end
        end
    end
    self:navigateForward(dict_name, items)
end

--- One surah's entries in a resource: "2:6–7" range rows (a group's
-- row shows its covered range; per-ayah dicts get one row per ayah).
function Browser:showDictSurah(dict_name, kind, surah)
    local quran = self.quran
    local all = quran:_dictAyahItems(dict_name)
    local name = quran:surahName(surah) or ("Surah " .. surah)
    local items = {}
    for _i, it in ipairs(all or {}) do
        if it.surah == surah and it.a1 then
            local label = (it.a2 and it.a2 > it.a1)
                and string.format("%d:%d–%d", surah, it.a1, it.a2)
                or string.format("%d:%d", surah, it.a1)
            table.insert(items, {
                text = label,
                callback = function()
                    self:openResourceEntry(dict_name, kind, it)
                end,
            })
        end
    end
    self:navigateForward(name, items)
end

--- Open one enumerated entry in the Reader; pre-rawSdcv KOReader falls
-- back to the ayah popup filtered to this dict (one-shot filter, same
-- as the panel's direct-open). The browser stays beneath (design D9).
function Browser:openResourceEntry(dict_name, kind, it)
    local quran = self.quran
    if kind == "overview" then
        -- D-R3-2: Simple mode / per-item target can route to the popup
        local use_reader = not (quran._openTargetFor
            and quran:_openTargetFor("overview") == "popup")
        local reader = use_reader
            and quran.canReaderTafsir and quran:canReaderTafsir()
            and quran:_readerModule()
        if reader and reader.showOverview
            and reader.showOverview(quran, it.surah,
                { dict = dict_name, back_label = self:backLabel() }) then
            return
        end
    elseif quran:openTafsirReader(it.surah, it.a1,
            { dict = dict_name, back_label = self:backLabel() }) then
        return
    end
    quran._dict_first_name = dict_name
    quran:openAyahPopup(it.surah, it.a1 or 1)
end

function Browser:buildRootItems()
    local quran, actions = self.quran, self.actions
    local items = {}

    -- Current position header item (resolved fresh each build).
    -- D-R3-19: bookless (FileManager entry) the row becomes the
    -- preferred-book opener — everything else on the root works
    -- without a book.
    local doc = quran.ui and quran.ui.document
    if doc then
        local pos_label = _("Current position")
        local pageno = doc.getCurrentPage and doc:getCurrentPage()
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
    else
        table.insert(items, {
            text = _("Open Quran book"),
            callback = function()
                if quran.openBookAt then
                    self:closeThen(function() quran:openBookAt() end)()
                end
            end,
        })
    end
    table.insert(items, {
        text = _("Search"),
        callback = function() self:showGlobalSearch() end,
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
    -- R4 TYPED GROUPS (owner 2026-07-18 night — settles the D-R3-18
    -- "root ≈ 2 pages" judgment): the 11 study/corpus rows fold into
    -- three groups BY TYPE (not source) so the root fits one page.
    -- Each group screen keeps the rows exactly as they were — counts,
    -- dim-to-toast (F19/F20), D-R3-18 order — and the db probes now
    -- run on group open instead of on every root build.
    table.insert(items, {
        text = _("Language & roots"),
        callback = function()
            self:navigateForward(_("Language & roots"),
                self:buildLanguageItems())
        end,
    })
    table.insert(items, {
        text = _("Themes & connections"),
        callback = function()
            self:navigateForward(_("Themes & connections"),
                self:buildConnectionsItems())
        end,
    })
    table.insert(items, {
        text = _("Reading"),
        separator = true,
        callback = function()
            self:navigateForward(_("Reading"), self:buildReadingItems())
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


--- "Language & roots" group (R4 typed groups): the word/root study
-- tools — Root explorer + the linguistic corpora trio (D-R3-18 kept
-- their relative order; presence/dim semantics unchanged).
function Browser:buildLanguageItems()
    local quran, actions = self.quran, self.actions
    local items = {}
    local roots = self:rootsModule()
    local okr, lconn = pcall(function()
        return roots and roots.ensureDb
            and (select(1, roots.ensureDb(quran))) or nil
    end)
    lconn = okr and lconn or nil
    table.insert(items, {
        text = _("Root explorer"),
        dim = not lconn or nil,
        callback = function()
            if not (roots and lconn) then
                notifyWarn(_("The root explorer needs the quran_lane data package (Library & assets)."))
                return
            end
            roots.showRoots(self)
        end,
    })
    local res = actions.detectResources(quran)
    if res.grammar then
        table.insert(items, {
            text = _("Grammar"),
            callback = function()
                self:showDictBrowse(res.grammar, "grammar")
            end,
        })
    end
    if res.irab then
        table.insert(items, {
            text = _("I'rab"),
            callback = function() self:showDictBrowse(res.irab, "irab") end,
        })
    end
    -- MASAQ browse parity (owner 2026-07-18): same surah→ayah shape as
    -- the corpora above, from its own db (dim without the pack)
    local masaq = self:masaqModule()
    local okm, mconn = pcall(function()
        return masaq and masaq.ensureDb
            and (select(1, masaq.ensureDb(quran))) or nil
    end)
    mconn = okm and mconn or nil
    table.insert(items, {
        text = _("Word grammar (MASAQ)"),
        dim = not mconn or nil,
        callback = function()
            if not (masaq and mconn) then
                notifyWarn(_("Word grammar needs the quran_masaq data package (Library & assets)."))
                return
            end
            masaq.showBrowse(self)
        end,
    })
    return items
end

--- "Themes & connections" group (R4 typed groups): the content-
-- discovery layers — counts + dim-to-toast exactly as on the old root
-- (F19/F20).
function Browser:buildConnectionsItems()
    local quran = self.quran
    local items = {}
    local qul = self:qulModule()
    local okq, qconn = pcall(function()
        return qul and qul.ensureDb and (select(1, qul.ensureDb(quran)))
            or nil
    end)
    qconn = okq and qconn or nil
    table.insert(items, {
        text = _("Topics"),
        mandatory = qconn and qul.topicCount
            and tostring(qul.topicCount(qconn)) or nil,
        dim = not qconn or nil,
        callback = function()
            if not (qul and qconn) then
                notifyWarn(_("Topics need the qul data package (Library & assets)."))
                return
            end
            qul.showTopicsRoot(self)
        end,
    })
    table.insert(items, {
        text = _("Themes"),
        mandatory = qconn and qul.themeCount
            and tostring(qul.themeCount(qconn)) or nil,
        dim = not qconn or nil,
        callback = function()
            if not (qul and qconn) then
                notifyWarn(_("Themes need the qul data package (Library & assets)."))
                return
            end
            qul.showThemesBrowse(self)
        end,
    })
    -- DA-7 connections package: Figures + Narratives
    local cx = self:connectionsModule()
    local okc, cconn = pcall(function()
        return cx and cx.ensureDb and (select(1, cx.ensureDb(quran))) or nil
    end)
    cconn = okc and cconn or nil
    table.insert(items, {
        text = _("Figures"),
        mandatory = cconn and cx.figureCount
            and tostring(cx.figureCount(cconn)) or nil,
        dim = not cconn or nil,
        callback = function()
            if not (cx and cconn) then
                notifyWarn(_("Figures need the quran_connections data package (Library & assets)."))
                return
            end
            cx.showFigures(self)
        end,
    })
    table.insert(items, {
        text = _("Narratives"),
        mandatory = cconn and cx.storyCount
            and tostring(cx.storyCount(cconn)) or nil,
        dim = not cconn or nil,
        callback = function()
            if not (cx and cconn) then
                notifyWarn(_("Narratives need the quran_connections data package (Library & assets)."))
                return
            end
            cx.showStories(self)
        end,
    })
    return items
end

--- "Reading" group (R4 typed groups): the reading corpora — Tafsirs
-- picker-or-direct (D-R3-7a), Asbab, Surah overviews; rows present
-- when installed, as on the old root.
function Browser:buildReadingItems()
    local quran, actions = self.quran, self.actions
    local items = {}
    local res = actions.detectResources(quran)
    if #res.tafsir > 0 then
        table.insert(items, {
            text = _("Tafsirs"),
            mandatory = tostring(#res.tafsir),
            callback = function()
                if #res.tafsir == 1 then
                    self:showDictBrowse(res.tafsir[1], "tafsir")
                    return
                end
                local titems = {}
                for _i, name in ipairs(res.tafsir) do
                    table.insert(titems, {
                        text = name,
                        callback = function()
                            self:showDictBrowse(name, "tafsir")
                        end,
                    })
                end
                self:navigateForward(_("Tafsirs"), titems)
            end,
        })
    end
    if res.asbab then
        table.insert(items, {
            text = _("Asbab al-Nuzul"),
            callback = function() self:showDictBrowse(res.asbab, "asbab") end,
        })
    end
    if res.overview then
        table.insert(items, {
            text = _("Surah overviews"),
            callback = function()
                self:showDictBrowse(res.overview, "overview")
            end,
        })
    end
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
        -- R3-F21 (owner batch 4): the hamburger is a settings-led
        -- context menu — paging direction is ONE row that opens the
        -- paging submenu, not the menu itself (it led every screen,
        -- including ones where paging is beside the point)
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local q = Browser.quran
            local reader = q and q._readerModule and q:_readerModule()
            local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog")
            if not ok_bd then return end
            local anchor = function()
                local menu_self = Browser.menu
                local btn = menu_self and menu_self.title_bar
                    and menu_self.title_bar.left_button
                return btn and btn.image and btn.image.dimen
            end
            local dialog
            local rows = {}
            if q and q.showSettingsMenu then
                rows[#rows + 1] = {{
                    text = _("Quran Helper settings"),
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        q:showSettingsMenu()
                    end,
                }}
            end
            if reader and reader.showPagingMenu then
                local short = reader.pagingModeLabel
                    and reader.pagingModeLabel() or ""
                rows[#rows + 1] = {{
                    text = _("Paging direction") .. ": " .. short .. "…",
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        reader.showPagingMenu(anchor)
                    end,
                }}
            end
            if #rows == 0 then return end
            dialog = ButtonDialog:new{
                shrink_unneeded_width = true,
                buttons = rows,
                anchor = anchor,
            }
            UIManager:show(dialog)
        end,
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
    -- Direction unification (design D-R2-7): browser page-swipes follow
    -- the same paging policy as the Reader (the F3 setting, "match
    -- book" by default), decided at EVENT time. Only horizontal swipes
    -- flip — labeled buttons, chevrons, and stock key handling (device-
    -- level hardware inversion) stay untouched.
    if Browser.menu.onSwipe then
        local orig_onSwipe = Browser.menu.onSwipe
        Browser.menu.onSwipe = function(menu_self, arg, ges)
            if ges and (ges.direction == "west" or ges.direction == "east") then
                local q = Browser.quran
                local reader = q and q._readerModule and q:_readerModule()
                if reader and reader.pagingInverted and reader.pagingInverted() then
                    ges = setmetatable(
                        { direction = ges.direction == "west" and "east" or "west" },
                        { __index = ges })
                end
            end
            return orig_onSwipe(menu_self, arg, ges)
        end
    end
    UIManager:show(Browser.menu)
    logger.dbg("quran.koplugin: browser opened")
    if land then
        land(Browser)
    end
end

return M
