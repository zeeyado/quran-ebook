--[[--
The shared full-screen Reader (design D2, 2026-07): ONE TextViewer-with-nav
surface for every sustained reading act — ayah text + translation (from the
quran_text package), tafsir (fetched headlessly from StarDict via
rawSdcv — the browser NEVER spawns the dict popup, design D3), and future
entity pages. Generalizes the root explorer's showEntry idiom: full screen
over whatever is beneath (browser Menu or the book — neither moves, design
D9), ← closes back, ◀ ▶ navigate, page-turn keys past the scroll
boundaries step ◀/▶.
--]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

local PTF_HEADER = "\u{FFF1}"
local PTF_B = "\u{FFF2}"
local PTF_E = "\u{FFF3}"

local function notifyInfo(text)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text })
end

-- ---------------------------------------------------------------------
-- Pure helpers (tested in scripts/dev_checks/check_plugin_helpers.lua)
-- ---------------------------------------------------------------------

--- Step one ayah in Hafs space with surah rollover.
-- Returns surah, ayah — or nil at the ends of the mushaf.
function M.stepAyah(counts, surah, ayah, dir)
    local a = ayah + dir
    local s = surah
    if a > (counts[s] or 0) then
        s = s + 1
        a = 1
    elseif a < 1 then
        s = s - 1
        a = counts[s] or 1
    end
    if s >= 1 and s <= 114 then
        return s, a
    end
end

--- Next/prev ayah for tafsir navigation, skipping the displayed entry's
-- group range (same policy as the popup's group nav: the skip follows
-- the displayed entry only). rs/r1/r2 = the entry's range comment (may
-- be nil). Hafs space; nil at the ends of the mushaf.
function M.tafsirNavTarget(counts, surah, ayah, rs, r1, r2, dir)
    local a = ayah
    if rs == surah then
        if dir > 0 and r2 and r2 >= a then
            a = r2
        elseif dir < 0 and r1 and r1 <= a then
            a = r1
        end
    end
    return M.stepAyah(counts, surah, a, dir)
end

--- Render the ayah-reader body (pure). arabic = KFGQPC text; meta_bits =
-- list of strings for the bold header line; translations = quran_text
-- rows. All sections PTF-formatted.
function M.renderAyahText(meta_bits, arabic, translations)
    local parts = {}
    if meta_bits and #meta_bits > 0 then
        table.insert(parts, PTF_B .. table.concat(meta_bits, " · ") .. PTF_E)
    end
    if arabic and arabic ~= "" then
        table.insert(parts, arabic)
    end
    for _i, t in ipairs(translations or {}) do
        table.insert(parts, PTF_B .. t.name .. PTF_E .. "\n" .. t.text)
    end
    return PTF_HEADER .. table.concat(parts, "\n\n")
end

--- Parse the group-range comment out of a raw StarDict definition
-- (before any HTML stripping). Returns rs, r1, r2 or nil.
function M.parseRange(def)
    if not def then return end
    local s, a1, a2 = def:match("<!%-%- range:(%d+):(%d+)%-(%d+) %-%->")
    if s then return tonumber(s), tonumber(a1), tonumber(a2) end
end

-- ---------------------------------------------------------------------
-- The generic Reader widget
-- ---------------------------------------------------------------------

-- The one active Reader viewer (module state). While it is on screen,
-- every M.show call UPDATES it in place — title, text, buttons — via
-- TextViewer:init(true) + one partial repaint (the stock in-place
-- rebuild; cf. upstream TextViewer:reinit). No close/reopen flash when
-- flowing ◀ ▶ between ayahs/entries or hopping Ayah ⇄ Tafsir
-- (koassistant X-ray viewer standard; owner 2026-07-12).
M._viewer = nil

local function activeViewer()
    local v = M._viewer
    if v and v._qr_active then return v end
end

--- Build the button row for spec. getv() resolves the viewer at tap
-- time (it may not exist yet at build time). ◀ ▶ do NOT close — the
-- flows they trigger land back in M.show, which updates in place.
-- Extra buttons close the viewer first unless keep_reader (flows that
-- stay on the Reader surface: Tafsir, Switch); bridges out of the
-- Reader (Explore) keep the default close.
local function buildRow(spec, getv)
    local UIManager = require("ui/uimanager")
    local function closeViewer()
        local v = getv()
        if M._viewer == v then M._viewer = nil end
        if v then
            v._qr_active = nil
            UIManager:close(v)
        end
    end
    local row = {
        {
            id = "qr_back",
            text = spec.back_label or ("← " .. _("Close")),
            callback = closeViewer,
        },
    }
    if spec.prev or spec.next then
        -- a dead direction stays visible but disabled (stable layout);
        -- it must never close the viewer (mushaf/group boundary)
        table.insert(row, { id = "qr_prev", text = "◀", enabled = spec.prev ~= nil,
            callback = function()
                if spec.prev then spec.prev() end
            end })
        table.insert(row, { id = "qr_next", text = "▶", enabled = spec.next ~= nil,
            callback = function()
                if spec.next then spec.next() end
            end })
    end
    for _i, b in ipairs(spec.extra_buttons or {}) do
        local cb = b.callback
        local keep = b.keep_reader
        table.insert(row, {
            id = b.id,
            text = b.text,
            callback = function()
                if not keep then closeViewer() end
                if cb then cb() end
            end,
        })
    end
    return row
end

-- Page-turn keys past the scroll boundaries step ◀ / ▶ (X-ray idiom:
-- onScrollUp/Down return nil at the boundary). Only wired for live
-- directions — over-scrolling at a dead boundary is a no-op. Re-run
-- after every in-place update: init(true) recreates the scroll widget.
local function wireScroll(viewer, spec)
    local stw = viewer.scroll_text_w
    if not stw then return end
    if spec.prev then
        local orig_up = stw.onScrollUp
        stw.onScrollUp = function(self_w)
            local handled = orig_up and orig_up(self_w)
            if handled then return handled end
            spec.prev()
            return true
        end
    end
    if spec.next then
        local orig_down = stw.onScrollDown
        stw.onScrollDown = function(self_w)
            local handled = orig_down and orig_down(self_w)
            if handled then return handled end
            spec.next()
            return true
        end
    end
end

--- Show a full-screen reading surface. spec:
--   title        viewer title
--   text         PTF-formatted body
--   back_label   first button ("← …"); closes the viewer (whatever was
--                beneath — book or browser — is untouched, design D9)
--   prev/next    optional callbacks: ◀ ▶ buttons + page-turn keys past
--                the scroll boundaries
--   extra_buttons optional list appended to the button row (fields:
--                text, callback, keep_reader, id)
-- Reuses the active Reader viewer in place when there is one.
-- Returns the viewer widget.
function M.show(spec)
    local UIManager = require("ui/uimanager")
    local live = activeViewer()
    if live then
        live.title = spec.title
        live.text = spec.text
        live.buttons_table = { buildRow(spec, function() return live end) }
        live:init(true)
        wireScroll(live, spec)
        if live.frame and live.frame.dimen then
            UIManager:setDirty("all", "partial", live.frame.dimen)
        end
        return live
    end

    local TextViewer = require("ui/widget/textviewer")
    local Device = require("device")
    local Screen = Device.screen

    local viewer
    viewer = TextViewer:new{
        title = spec.title,
        text = spec.text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        justified = false,
        buttons_table = { buildRow(spec, function() return viewer end) },
    }
    viewer._qr_active = true
    -- clear the module handle however the viewer dies (tap-outside,
    -- back key, our own buttons)
    local orig_close_widget = viewer.onCloseWidget
    viewer.onCloseWidget = function(v)
        if M._viewer == v then M._viewer = nil end
        v._qr_active = nil
        if orig_close_widget then return orig_close_widget(v) end
    end
    M._viewer = viewer
    wireScroll(viewer, spec)
    UIManager:show(viewer)
    return viewer
end

-- ---------------------------------------------------------------------
-- Ayah reader (quran_text package; Hafs-canonical display — connection
-- data is Hafs-keyed by invariant D8)
-- ---------------------------------------------------------------------

--- Read S:A (Hafs numbering) in the Reader: Arabic text + translations,
-- ◀ ▶ stepping through ayahs. Returns true, or false when the text
-- package isn't installed (caller decides the fallback).
function M.showAyah(quran, surah, ayah, opts)
    opts = opts or {}
    local qt = quran._textModule and quran:_textModule()
    if not qt then return false end
    local conn = qt.ensureDb(quran)
    if not conn then
        if not quran._text_hint_shown then
            quran._text_hint_shown = true
            notifyInfo(_("Tip: install the Quran text package (Library & assets) to read inside the browser."))
        end
        return false
    end
    local entry = qt.ayah(conn, "hafs", surah, ayah)
    if not entry then return false end
    local translations = qt.translations(conn, surah, ayah)

    local name = quran.surahName and quran:surahName(surah) or tostring(surah)
    -- Display is Hafs-canonical (invariant D8) — say so on non-Hafs books
    -- rather than letting the text/page/juz silently disagree with them.
    local key = string.format("%d:%d", surah, ayah)
    if quran._riwayah and quran._riwayah ~= "hafs" then
        key = key .. " (" .. _("Hafs") .. ")"
    end
    local meta = { key }
    if entry.juz then table.insert(meta, _("Juz") .. " " .. entry.juz) end
    if entry.page then table.insert(meta, _("Page") .. " " .. entry.page) end
    local counts = quran._hafsCounts and quran:_hafsCounts() or {}

    local extra = {}
    if quran.canReaderTafsir and quran:canReaderTafsir() then
        table.insert(extra, {
            id = "qr_tafsir",
            text = _("Tafsir"),
            keep_reader = true,  -- flows to the tafsir surface in place
            callback = function()
                quran:openTafsirReader(surah, ayah, { explore = opts.explore })
            end,
        })
    end
    -- Bridge into the browser's unified ayah page — only when the caller
    -- doesn't already have the browser beneath (opts.explore; design D9:
    -- never stack a second browser window)
    if opts.explore and quran.openBrowserAtAyah then
        table.insert(extra, {
            id = "qr_explore",
            text = _("Explore"),
            callback = function()
                quran:openBrowserAtAyah(surah, ayah)
            end,
        })
    end

    M.show{
        title = string.format("%s %d:%d", name, surah, ayah),
        text = M.renderAyahText(meta, entry.text, translations),
        back_label = opts.back_label,
        prev = (function()
            local ps, pa = M.stepAyah(counts, surah, ayah, -1)
            if ps then return function() M.showAyah(quran, ps, pa, opts) end end
        end)(),
        next = (function()
            local ns, na = M.stepAyah(counts, surah, ayah, 1)
            if ns then return function() M.showAyah(quran, ns, na, opts) end end
        end)(),
        extra_buttons = extra,
    }
    return true
end

-- ---------------------------------------------------------------------
-- Tafsir reader (StarDict text via the headless rawSdcv fetch — the
-- enabling primitive; no dict popup involved)
-- ---------------------------------------------------------------------

--- Read a tafsir entry for S:A (Hafs numbering) full-screen. opts.dict
-- names the tafsir dictionary (resolved by main.lua's openTafsirReader,
-- which owns the preferred-tafsir setting and the picker); opts.explore
-- adds the browser bridge button (see showAyah).
-- Runs its fetch inside Trapper (rawSdcv uses dismissablePopen).
function M.showTafsir(quran, surah, ayah, opts)
    opts = opts or {}
    local dict = opts.dict
    if not dict then return false end
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        -- the dicts index "Al-Baqarah 255"-style headwords, not "2:255" —
        -- the key convention lives in main.lua next to the popup path
        local keys = quran._ayahDictKeys and quran:_ayahDictKeys(surah, ayah)
            or { string.format("%d:%d", surah, ayah) }
        local def = quran:_rawDefinition(dict, keys)
        -- Coverage gap hit while STEPPING (sparse tafsirs/asbab): flow on
        -- to this dict's next covered ayah instead of a placeholder.
        -- Direct opens (no step_dir) keep the placeholder — "no entry
        -- here" is the honest answer then.
        if not def and opts.step_dir and quran._firstAyahWithEntry then
            local ns, na = quran:_firstAyahWithEntry(dict, surah, ayah,
                opts.step_dir, 100)
            if ns and not (ns == surah and na == ayah) then
                surah, ayah = ns, na
                keys = quran._ayahDictKeys and quran:_ayahDictKeys(surah, ayah)
                    or { string.format("%d:%d", surah, ayah) }
                def = quran:_rawDefinition(dict, keys)
            end
        end
        local rs, r1, r2 = M.parseRange(def)
        local body
        if def then
            body = quran:_htmlToText(def)
        else
            body = _("(No entry for this ayah in this tafsir.)")
        end
        local name = quran.surahName and quran:surahName(surah) or tostring(surah)
        local span = (rs == surah and r1 and r2 and r2 > r1)
            and string.format("%d:%d–%d", surah, r1, r2)
            or string.format("%d:%d", surah, ayah)
        local counts = quran._hafsCounts and quran:_hafsCounts() or {}
        local function step(dir)
            local ns, na = M.tafsirNavTarget(counts, surah, ayah, rs, r1, r2, dir)
            if ns then
                return function()
                    local o = {}
                    for k, v in pairs(opts) do o[k] = v end
                    o.step_dir = dir  -- lets the fetch skip coverage gaps
                    M.showTafsir(quran, ns, na, o)
                end
            end
        end
        local extra = { {
            id = "qr_switch",
            text = _("Switch"),
            keep_reader = true,  -- picker shows over the Reader; the pick
                                 -- updates it in place (cancel keeps it)
            callback = function()
                quran:_showTafsirPicker(surah, ayah, opts)
            end,
        } }
        if opts.explore and quran.openBrowserAtAyah then
            table.insert(extra, {
                id = "qr_explore",
                text = _("Explore"),
                callback = function()
                    quran:openBrowserAtAyah(surah, ayah)
                end,
            })
        end
        M.show{
            title = string.format("%s · %s %s", dict, name, span),
            text = body,
            back_label = opts.back_label,
            prev = step(-1),
            next = step(1),
            extra_buttons = extra,
        }
    end)
    return true
end

--- Surah overview in the Reader (headless fetch from the overview
-- dictionary, which is keyed by the English surah name). Returns true,
-- or false when unavailable (caller falls back to the popup flow).
function M.showOverview(quran, surah, opts)
    opts = opts or {}
    local dict = opts.dict
    if not dict then return false end
    local name = quran.surahName and quran:surahName(surah)
    if not name then return false end
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local def = quran:_rawDefinition(dict, name)
        local body = def and quran:_htmlToText(def)
            or _("(No overview entry for this surah.)")
        M.show{
            title = _("Overview") .. " · " .. name,
            text = body,
            back_label = opts.back_label,
        }
    end)
    return true
end

logger.dbg("quran.koplugin: quran_reader loaded")

return M
