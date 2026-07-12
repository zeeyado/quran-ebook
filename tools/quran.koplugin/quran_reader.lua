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

--- Show a full-screen reading surface. spec:
--   title        viewer title
--   text         PTF-formatted body
--   back_label   first button ("← …"); closes the viewer (whatever was
--                beneath — book or browser — is untouched, design D9)
--   prev/next    optional callbacks: ◀ ▶ buttons + page-turn keys past
--                the scroll boundaries
--   extra_buttons optional list appended to the button row
-- Returns the viewer widget.
function M.show(spec)
    local UIManager = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    local Device = require("device")
    local Screen = Device.screen

    local viewer
    local row = {
        {
            text = spec.back_label or ("← " .. _("Close")),
            callback = function() UIManager:close(viewer) end,
        },
    }
    if spec.prev or spec.next then
        table.insert(row, { text = "◀", callback = function()
            UIManager:close(viewer)
            if spec.prev then spec.prev() end
        end })
        table.insert(row, { text = "▶", callback = function()
            UIManager:close(viewer)
            if spec.next then spec.next() end
        end })
    end
    for _i, b in ipairs(spec.extra_buttons or {}) do
        b.close_viewer = nil
        local cb = b.callback
        b.callback = function()
            UIManager:close(viewer)
            if cb then cb() end
        end
        table.insert(row, b)
    end

    viewer = TextViewer:new{
        title = spec.title,
        text = spec.text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        justified = false,
        buttons_table = { row },
    }
    -- Page-turn keys past the scroll boundaries step ◀ / ▶ (X-ray idiom:
    -- onScrollUp/Down return nil at the boundary).
    if (spec.prev or spec.next) and viewer.scroll_text_w then
        local stw = viewer.scroll_text_w
        local orig_up = stw.onScrollUp
        stw.onScrollUp = function(self_w)
            local handled = orig_up and orig_up(self_w)
            if handled then return handled end
            UIManager:close(viewer)
            if spec.prev then spec.prev() end
            return true
        end
        local orig_down = stw.onScrollDown
        stw.onScrollDown = function(self_w)
            local handled = orig_down and orig_down(self_w)
            if handled then return handled end
            UIManager:close(viewer)
            if spec.next then spec.next() end
            return true
        end
    end
    local UIManager2 = require("ui/uimanager")
    UIManager2:show(viewer)
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
    local meta = { string.format("%d:%d", surah, ayah),
        _("Juz") .. " " .. entry.juz, _("Page") .. " " .. entry.page }
    local counts = quran._hafsCounts and quran:_hafsCounts() or {}

    local extra
    if quran.canReaderTafsir and quran:canReaderTafsir() then
        extra = { {
            text = _("Tafsir"),
            callback = function()
                quran:openTafsirReader(surah, ayah)
            end,
        } }
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
-- which owns the preferred-tafsir setting and the picker).
-- Runs its fetch inside Trapper (rawSdcv uses dismissablePopen).
function M.showTafsir(quran, surah, ayah, opts)
    opts = opts or {}
    local dict = opts.dict
    if not dict then return false end
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local def = quran:_rawDefinition(dict, string.format("%d:%d", surah, ayah))
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
                return function() M.showTafsir(quran, ns, na, opts) end
            end
        end
        M.show{
            title = string.format("%s · %s %s", dict, name, span),
            text = body,
            back_label = opts.back_label,
            prev = step(-1),
            next = step(1),
            extra_buttons = { {
                text = _("Switch"),
                callback = function()
                    quran:_showTafsirPicker(surah, ayah)
                end,
            } },
        }
    end)
    return true
end

logger.dbg("quran.koplugin: quran_reader loaded")

return M
