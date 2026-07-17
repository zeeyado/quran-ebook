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
        text = _("Read (text & translation)"),
        callback = function()
            local reader = quran._readerModule and quran:_readerModule()
            -- name the SCREEN closing returns to (the live menu title,
            -- e.g. the ayah page), not a generic "Browser"
            local ok = reader and reader.showAyah(quran, surah, hafs_ayah,
                { back_label = "← " .. ((Browser.menu and Browser.menu.title)
                    or _("Browser")) })
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
    -- fallback_name: the dict the LEGACY popup path filters to when the
    -- Reader is unavailable (pre-rawSdcv KOReader) and no explicit dict
    -- was given — preferred tafsir, else the single/first installed one
    local function dictItem(label, dict_name, fallback_name)
        table.insert(items, {
            text = label,
            callback = function()
                local opened = quran.openTafsirReader
                    and quran:openTafsirReader(surah, hafs_ayah, {
                        dict = dict_name,
                        back_label = "← " .. ((Browser.menu
                            and Browser.menu.title) or _("Browser")),
                    })
                if not opened then
                    -- pre-rawSdcv KOReader: popup flow
                    self:closeThen(function()
                        quran._dict_filter_name = dict_name or fallback_name
                        quran:openAyahPopup(surah, hafs_ayah)
                    end)()
                end
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
    if #items > 0 then items[#items].separator = true end

    -- QUL connections (counts; zero-count rows hidden — design D4)
    local qul = self:qulModule()
    local conn = qul and select(1, qul.ensureDb(quran))
    if conn then
        local counts = qul.countsFor(conn, surah, hafs_ayah,
            qul.similarMinScore and qul.similarMinScore(self.quran) or 80)
        if counts then
            local function connItem(n, label, fn)
                if n and n > 0 then
                    table.insert(items, {
                        text = label,
                        mandatory = tostring(n),
                        callback = function() fn(self, surah, hafs_ayah) end,
                    })
                end
            end
            connItem(counts.similar, _("Similar ayahs"), qul.showSimilar)
            connItem(counts.themes, _("Themes here"), qul.showThemesFor)
            connItem(counts.topics, _("Topics here"), qul.showTopicsFor)
            connItem(counts.phrases, _("Repeated phrases"), qul.showMutashabihat)
            if #items > 0 then items[#items].separator = true end
        end
    end

    -- Surah context (overview renders in-browser when the Reader path is
    -- available; the popup remains the pre-rawSdcv fallback)
    table.insert(items, {
        text = _("Surah overview"),
        callback = function()
            local reader = quran._readerModule and quran:_readerModule()
            local opened = reader and reader.showOverview and res.overview
                and quran.canReaderTafsir and quran:canReaderTafsir()
                and reader.showOverview(quran, surah, { dict = res.overview })
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

-- ---------------------------------------------------------------------
-- Content-first resource browsing (design D-R2-2): every installed
-- ayah-keyed StarDict corpus (tafsirs, asbab, i'rab, overviews) is
-- browsable as ITEMS, independent of the current position. Entries are
-- enumerated from the dict's own .idx (Quran:_dictAyahItems).
-- ---------------------------------------------------------------------

--- Installed ayah-keyed resources as {name, kind} rows (browse order:
-- tafsirs, asbab, i'rab, overviews).
function Browser:resourceRows()
    local res = self.actions.detectResources(self.quran)
    local rows = {}
    for _i, name in ipairs(res.tafsir or {}) do
        table.insert(rows, { name = name, kind = "tafsir" })
    end
    if res.asbab then table.insert(rows, { name = res.asbab, kind = "asbab" }) end
    if res.irab then table.insert(rows, { name = res.irab, kind = "irab" }) end
    if res.overview then
        table.insert(rows, { name = res.overview, kind = "overview" })
    end
    return rows
end

function Browser:showResourcesList()
    local items = {}
    for _i, row in ipairs(self:resourceRows()) do
        table.insert(items, {
            text = row.name,
            callback = function() self:showDictBrowse(row.name, row.kind) end,
        })
    end
    if #items == 0 then
        notifyWarn(_("No Quran resources installed (see Library & assets)."))
        return
    end
    self:navigateForward(_("Resources"), items)
end

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
        local reader = quran.canReaderTafsir and quran:canReaderTafsir()
            and quran:_readerModule()
        if reader and reader.showOverview
            and reader.showOverview(quran, it.surah, { dict = dict_name }) then
            return
        end
    elseif quran:openTafsirReader(it.surah, it.a1, { dict = dict_name }) then
        return
    end
    quran._dict_filter_name = dict_name
    quran:openAyahPopup(it.surah, it.a1 or 1)
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
    local n_res = #self:resourceRows()
    if n_res > 0 then
        table.insert(items, {
            text = _("Resources"),
            mandatory = tostring(n_res),
            callback = function() self:showResourcesList() end,
        })
    end
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
        -- D-R2-7b: title-bar hamburger, page-relevant — the paging
        -- quick menu (browser lists page) plus a Settings shortcut
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local q = Browser.quran
            local reader = q and q._readerModule and q:_readerModule()
            if reader and reader.showPagingMenu then
                reader.showPagingMenu(function()
                    local menu_self = Browser.menu
                    local btn = menu_self and menu_self.title_bar
                        and menu_self.title_bar.left_button
                    return btn and btn.image and btn.image.dimen
                end, q.showSettingsMenu and {
                    {{
                        text = _("Quran Helper settings"),
                        align = "left",
                        callback = function()
                            local q2 = Browser.quran
                            if q2 and q2.showSettingsMenu then
                                q2:showSettingsMenu()
                            end
                        end,
                    }},
                } or nil)
            end
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
