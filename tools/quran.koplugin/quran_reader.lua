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

-- ---------------------------------------------------------------------
-- Paging direction (Round-2 F3, owner ask 2026-07-16: "set/match scroll
-- direction"). KOReader's "invert page turn taps and swipes"
-- (inverse_reading_order — the RTL-book idiom) never reaches widgets,
-- so the Reader paged opposite to the book for users who set it.
-- Hardware page-turn keys are already covered globally by KOReader's
-- device-level invert settings — ONLY taps and swipes are flipped here.
-- Mode is a plugin setting ("reader_paging_mode", wired in main.lua):
--   auto     follow the book (inverse_reading_order)   [default]
--   standard never inverted
--   inverted always inverted
--   content  follow what's on screen (D-R2-7b, owner 2026-07-16):
--            Arabic-led surfaces page like the mushaf, English-led
--            surfaces (Lane entries, browser lists) page standard
-- ---------------------------------------------------------------------
M.paging_mode = "auto"

-- One home for the mode set — the settings radio (main.lua) and the
-- title-bar quick menu below both render from it.
M.PAGING_MODES = {
    { value = "auto", label = _("Match book"),
      help = _("Follows KOReader's 'Invert page turn taps and swipes' setting, so the reading window pages the same way as the book.") },
    { value = "standard", label = _("Standard"),
      help = _("Tap right / swipe left = forward, everywhere.") },
    { value = "inverted", label = _("Inverted"),
      help = _("Tap left / swipe right = forward, everywhere.") },
    { value = "content", label = _("Follow content"),
      help = _("Pages by what's on screen: Arabic-led screens (ayah text) page like the mushaf, English-led screens (dictionary entries, browser lists) page standard.") },
}

-- Persistence is main.lua's job (plugin settings live there) — it
-- installs _save_paging when it loads this module. Quick toggles and
-- the settings radio both go through setPagingMode.
M._save_paging = nil

function M.setPagingMode(value)
    M.paging_mode = value
    if M._save_paging then M._save_paging(value) end
end

--- Pure: is a text Arabic-led? Majority vote of strong letters —
-- Arabic-block characters (U+0600–U+06FF: UTF-8 lead bytes 0xD8–0xDB,
-- which never occur as continuation bytes) vs ASCII letters. Ties and
-- empty text read as LTR.
function M.textDirectionRTL(text)
    if type(text) ~= "string" then return false end
    local ar, lat = 0, 0
    for i = 1, #text do
        local b = text:byte(i)
        if b >= 0xD8 and b <= 0xDB then
            ar = ar + 1
        elseif (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
            lat = lat + 1
        end
    end
    return ar > lat
end

--- Inversion decision. content_rtl only matters in "content" mode:
-- true = the surface's content is Arabic-led (page like the mushaf).
-- Callers without a content identity (browser lists) pass nothing and
-- page standard in that mode.
function M.pagingInverted(content_rtl)
    if M.paging_mode == "inverted" then return true end
    if M.paging_mode == "standard" then return false end
    if M.paging_mode == "content" then return content_rtl == true end
    local ok, inv = pcall(function()
        return G_reader_settings ~= nil
            and G_reader_settings:isTrue("inverse_reading_order")
    end)
    return (ok and inv) or false
end

--- Quick paging-direction menu (D-R2-7b: reachable from title-bar
-- hamburgers, not only the settings menu). Anchored ButtonDialog with
-- radio-marked rows; extra_rows are appended with their callbacks
-- wrapped to close the dialog first (the TextViewer wrap uses one to
-- keep the stock view options reachable).
function M.showPagingMenu(anchor, extra_rows)
    local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    if not ok_bd then return end
    local UIManager = require("ui/uimanager")
    local dialog
    local buttons = {}
    for _i, m in ipairs(M.PAGING_MODES) do
        buttons[#buttons + 1] = {{
            text = (M.paging_mode == m.value and "◉ " or "◯ ") .. m.label,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                M.setPagingMode(m.value)
            end,
        }}
    end
    for _i, row in ipairs(extra_rows or {}) do
        local wrapped = {}
        for _j, btn in ipairs(row) do
            local b2 = {}
            for k, v in pairs(btn) do b2[k] = v end
            local cb = btn.callback
            b2.callback = function()
                UIManager:close(dialog)
                if cb then cb() end
            end
            wrapped[#wrapped + 1] = b2
        end
        buttons[#buttons + 1] = wrapped
    end
    dialog = ButtonDialog:new{
        title = _("Paging direction"),
        shrink_unneeded_width = true,
        buttons = buttons,
        anchor = anchor,
    }
    UIManager:show(dialog)
    return dialog
end

--- Put the paging quick menu behind the viewer's title-bar hamburger,
-- with the stock view options (font size, justify, …) one row below.
-- No-op on KOReader versions whose TextViewer has no hamburger — the
-- settings-menu radio still covers those.
function M.wirePagingMenu(viewer)
    if viewer._qr_paging_menu then return end
    local orig_show_menu = viewer.onShowMenu
    if not orig_show_menu then return end
    viewer._qr_paging_menu = true
    viewer.onShowMenu = function(self_v)
        M.showPagingMenu(function()
            local btn = self_v.titlebar and self_v.titlebar.left_button
            return btn and btn.image and btn.image.dimen
        end, {
            {{
                text = _("View options…"),
                align = "left",
                callback = function() orig_show_menu(self_v) end,
            }},
        })
        return true
    end
end

--- Pure: tap half → scroll direction ("up"/"down"). Stock ScrollTextWidget
-- maps left half = up; inversion swaps.
function M.tapScrollDir(left_half, inverted)
    local up = left_half
    if inverted then up = not up end
    return up and "up" or "down"
end

--- Pure: horizontal swipe → scroll direction ("up"/"down"), nil for
-- non-horizontal. Stock TextViewer maps west = forward (down).
function M.swipeScrollDir(direction, inverted)
    if direction ~= "west" and direction ~= "east" then return nil end
    local fwd = direction == "west"
    if inverted then fwd = not fwd end
    return fwd and "down" or "up"
end

local function bdFlipHalf(left)
    local ok, BD = pcall(require, "ui/bidi")
    if ok and BD and BD.flipIfMirroredUILayout then
        return BD.flipIfMirroredUILayout(left)
    end
    return left
end

local function bdFlipDir(dir)
    local ok, BD = pcall(require, "ui/bidi")
    if ok and BD and BD.flipDirectionIfMirroredUILayout then
        return BD.flipDirectionIfMirroredUILayout(dir)
    end
    return dir
end

--- Route the viewer's taps and horizontal swipes through onScrollUp/Down
-- honoring the paging mode. Also gives swipes the boundary flow (stock
-- onSwipe calls scrollText directly, which dead-ends at the last page
-- instead of stepping ◀/▶). Inversion is decided at EVENT time, so a
-- mode change applies to an already-open viewer. Re-run after in-place
-- updates: init(true) recreates the scroll widget (the swipe override
-- lives on the viewer and survives, guarded by the _qr_orig memo).
function M.wireTouchPaging(viewer)
    -- "Follow content" input: surfaces may declare their direction
    -- (viewer._qr_content_rtl, from spec.content_rtl); undeclared
    -- content is classified from the rendered text. Runs on every
    -- re-wire, so in-place content swaps re-classify.
    if viewer._qr_content_rtl ~= nil then
        viewer._qr_rtl = viewer._qr_content_rtl
    else
        viewer._qr_rtl = M.textDirectionRTL(viewer.text)
    end
    local stw = viewer.scroll_text_w
    if stw and stw.onTapScrollText then
        stw.onTapScrollText = function(self_w, _arg, ges)
            if self_w.ignore_taps or self_w.editable then return false end
            local width
            local okd, Device = pcall(require, "device")
            if okd and Device and Device.screen then
                width = Device.screen:getWidth()
            else
                width = self_w.width or 0
            end
            local left = bdFlipHalf(ges.pos.x < width / 2)
            if M.tapScrollDir(left, M.pagingInverted(viewer._qr_rtl)) == "up" then
                return self_w:onScrollUp()
            end
            return self_w:onScrollDown()
        end
    end
    if not viewer._qr_orig_swipe then
        viewer._qr_orig_swipe = viewer.onSwipe
    end
    viewer.onSwipe = function(self_v, arg, ges)
        local dimen = self_v.textw and self_v.textw.dimen
        if dimen and ges.pos and ges.pos.intersectWith
                and ges.pos:intersectWith(dimen) then
            local dir = M.swipeScrollDir(bdFlipDir(ges.direction),
                                         M.pagingInverted(self_v._qr_rtl))
            if dir then
                local w = self_v.scroll_text_w
                if w then
                    if dir == "up" then w:onScrollUp() else w:onScrollDown() end
                end
                return true
            end
        end
        if self_v._qr_orig_swipe then
            return self_v._qr_orig_swipe(self_v, arg, ges)
        end
    end
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
        live._qr_content_rtl = spec.content_rtl
        live.buttons_table = { buildRow(spec, function() return live end) }
        live:init(true)
        wireScroll(live, spec)
        M.wireTouchPaging(live)
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
    viewer._qr_content_rtl = spec.content_rtl
    wireScroll(viewer, spec)
    M.wireTouchPaging(viewer)
    M.wirePagingMenu(viewer)
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
        -- the Quran-text surface pages like the mushaf in "follow
        -- content" mode even when translations outweigh the ayah
        content_rtl = true,
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
