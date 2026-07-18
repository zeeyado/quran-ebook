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

-- D-R2-8 (owner 2026-07-16): the in-Reader hop stack. Surface-CHANGING
-- hops (ayah → tafsir, tafsir → ayah — spec.kind differs) push the
-- current spec; ← pops it back IN PLACE; ◀ ▶ stepping (same kind)
-- REPLACES, so back never replays every stepped ayah; the titlebar ✕
-- (and any close) clears the stack. With no hops, ← keeps its original
-- meaning (spec.back_label / Close — the stack bottom).
M._spec = nil        -- spec of the surface currently on screen
M._stack = {}        -- specs ← returns to, oldest first (capped)
M._navigating = false -- true while a pop re-shows (suppresses the push)

local function activeViewer()
    local v = M._viewer
    if v and v._qr_active then return v end
end

--- Back-button label for a stacked surface: its title, clipped at a
-- codepoint boundary so mixed Arabic titles never split mid-character.
local function backLabel(sp)
    local t = (sp and sp.title) or _("Back")
    if #t > 30 then
        local cut = 28
        while cut > 1 and t:byte(cut)
                and t:byte(cut) >= 0x80 and t:byte(cut) < 0xC0 do
            cut = cut - 1
        end
        t = t:sub(1, cut - 1) .. "…"
    end
    return t
end

--- Build the button row for spec. getv() resolves the viewer at tap
-- time (it may not exist yet at build time). ◀ ▶ do NOT close — the
-- flows they trigger land back in M.show, which updates in place.
-- Extra buttons close the viewer first unless keep_reader (flows that
-- stay on the Reader surface: Tafsir, Switch); bridges out of the
-- Reader (Explore) keep the default close.
-- inv: effective paging inversion for this surface — the ◀ ▶ pair
-- follows it (owner 2026-07-16: on an Arabic asbab screen "left button
-- is still previous?"): when inverted, the LEFT button moves FORWARD,
-- exactly like the popup's RTL nav pair (◁ = next). Decided at build
-- time — every navigation rebuilds the row, so a mode change lands on
-- the next step (taps/swipes stay event-time).
local function buildRow(spec, getv, inv)
    local UIManager = require("ui/uimanager")
    local function closeViewer()
        local v = getv()
        if M._viewer == v then M._viewer = nil end
        M._stack = {}
        M._spec = nil
        if v then
            v._qr_active = nil
            UIManager:close(v)
        end
    end
    -- ← : pop the hop stack in place; close only when there is nothing
    -- to pop (the original semantics — back_label callers are the
    -- stack bottom). The row is rebuilt on every show, so the label
    -- always names the current hop target.
    local back_text, back_cb
    if #M._stack > 0 then
        back_text = "← " .. backLabel(M._stack[#M._stack])
        back_cb = function()
            local top = table.remove(M._stack)
            if not top then return closeViewer() end
            M._navigating = true
            local ok, err = pcall(M.show, top)
            M._navigating = false
            if not ok then
                logger.warn("quran.koplugin: back-pop failed:", err)
                closeViewer()
            end
        end
    else
        -- stack bottom: name what closing reveals (koassistant X-ray
        -- idiom, owner 2026-07-16). Callers over the browser pass
        -- their own back_label; the Reader's default context is the
        -- book beneath.
        back_text = spec.back_label or ("← " .. _("Book"))
        back_cb = closeViewer
    end
    local row = {
        {
            id = "qr_back",
            text = back_text,
            callback = back_cb,
        },
    }
    if spec.prev or spec.next then
        -- a dead direction stays visible but disabled (stable layout);
        -- it must never close the viewer (mushaf/group boundary)
        local left_cb, right_cb = spec.prev, spec.next
        if inv then left_cb, right_cb = spec.next, spec.prev end
        table.insert(row, { id = "qr_prev", text = "◀", enabled = left_cb ~= nil,
            callback = function()
                if left_cb then left_cb() end
            end })
        table.insert(row, { id = "qr_next", text = "▶", enabled = right_cb ~= nil,
            callback = function()
                if right_cb then right_cb() end
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
-- R3-F24 (owner batch 4): plain directional names — "standard"/
-- "mushaf-style" read as contrived; what they MEAN is the direction.
M.PAGING_MODES = {
    { value = "auto", label = _("Match book"), short = _("match book"),
      help = _("Follows KOReader's 'Invert page turn taps and swipes' setting, so the plugin pages the same way as the book.") },
    { value = "standard", label = _("Left to right — forward on the right"),
      short = _("left to right"),
      help = _("Tap the right half, swipe left, or use ▶ for the next page/entry. Like an English book.") },
    { value = "inverted", label = _("Right to left — forward on the left"),
      short = _("right to left"),
      help = _("Tap the left half, swipe right, or use ◀ for the next page/entry. Like the mushaf.") },
    { value = "content", label = _("Follow content"),
      short = _("follow content"),
      help = _("Each screen decides by its own text: Arabic-led screens (ayah text, Arabic tafsirs) page right to left, English-led screens (Lane entries, browser lists) page left to right.") },
}

-- Persistence is main.lua's job (plugin settings live there) — it
-- installs _save_paging when it loads this module. Quick toggles and
-- the settings radio both go through setPagingMode.
M._save_paging = nil

function M.setPagingMode(value)
    M.paging_mode = value
    if M._save_paging then M._save_paging(value) end
end

-- D-R3-9 alignment half, folded to ONE knob (owner 2026-07-18 part 2:
-- "it should just be one setting, it cycles"): paragraph direction and
-- justification are a single plugin-wide text-layout state, persisted
-- via main.lua's _save_view hook (same idiom as _save_paging).
-- "auto" = each paragraph classified by its own text (the TextViewer
-- default); "rtl"/"ltr" force every paragraph one way — the manual
-- override for mixed surfaces the classifier gets wrong (English-led
-- entries that OPEN with an Arabic headword, Arabic-led i'rab with
-- English glosses); "justify" = justified edges with automatic
-- direction. Embedded opposite-direction runs still shape correctly
-- (bidi) in every mode.
M.LAYOUT_MODES = {
    { value = "auto", label = _("automatic") },
    { value = "rtl", label = _("right to left") },
    { value = "ltr", label = _("left to right") },
    { value = "justify", label = _("justified") },
}
M.text_layout = "auto"
M._save_view = nil

function M.setTextLayout(value)
    M.text_layout = value
    if M._save_view then M._save_view() end
end

--- The single knob: advance to the next mode, wrapping. Returns the
-- new mode value.
function M.cycleTextLayout()
    for i, m in ipairs(M.LAYOUT_MODES) do
        if m.value == M.text_layout then
            M.setTextLayout(M.LAYOUT_MODES[i % #M.LAYOUT_MODES + 1].value)
            return M.text_layout
        end
    end
    M.setTextLayout(M.LAYOUT_MODES[1].value)
    return M.text_layout
end

--- Label for the current layout (menu summaries).
function M.layoutLabel()
    for _i, m in ipairs(M.LAYOUT_MODES) do
        if m.value == M.text_layout then return m.label end
    end
    return M.LAYOUT_MODES[1].label
end

--- Stamp the module view settings onto a viewer — the three fields
-- TextViewer forwards to ScrollTextWidget on init/reinit.
function M.applyViewSettings(viewer)
    viewer.justified = M.text_layout == "justify"
    if M.text_layout == "rtl" or M.text_layout == "ltr" then
        viewer.auto_para_direction = false
        viewer.para_direction_rtl = M.text_layout == "rtl"
    else
        viewer.auto_para_direction = true
        viewer.para_direction_rtl = nil
    end
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
-- "auto" (match book) must read the LIVE ReaderView, not the global
-- setting: KOReader keeps inverse_reading_order per-book (the sidecar
-- overrides G_reader_settings, readerview.lua onReadSettings), so a
-- book inverted individually — the common case for these RTL EPUBs —
-- was invisible to the global read (F26, owner 2026-07-18).
function M.pagingInverted(content_rtl)
    if M.paging_mode == "inverted" then return true end
    if M.paging_mode == "standard" then return false end
    if M.paging_mode == "content" then return content_rtl == true end
    local ok, inv = pcall(function()
        local ok_ui, ReaderUI = pcall(require, "apps/reader/readerui")
        local view = ok_ui and ReaderUI.instance and ReaderUI.instance.view
        if view and view.inverse_reading_order ~= nil then
            return view.inverse_reading_order == true
        end
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

--- Short label for the current mode (menu summaries).
function M.pagingModeLabel()
    for _i, m in ipairs(M.PAGING_MODES) do
        if m.value == M.paging_mode then return m.short or m.label end
    end
    return M.PAGING_MODES[1].short or M.PAGING_MODES[1].label
end

--- The viewer hamburger, page-relevant (owner 2026-07-16: the stock
-- view options must stay first-class, not hide behind another button):
-- font size + monospace mirror upstream onShowMenu; the stock justify
-- row folds into the one cycling Text-layout knob; plus ONE paging row
-- since these surfaces page. wirePagingMenu falls back to the stock
-- menu wholesale if these TextViewer internals ever drift.
function M.showViewMenu(viewer)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    assert(viewer.text_font_size and viewer.reinit,
        "TextViewer view-option fields missing")
    local anchor = function()
        local btn = viewer.titlebar and viewer.titlebar.left_button
        return btn and btn.image and btn.image.dimen
    end
    local dialog
    local buttons = {
        {{
            text_func = function()
                return _("Font size: ") .. viewer.text_font_size
            end,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text = _("Font size"),
                    value = viewer.text_font_size,
                    value_min = 12,
                    value_max = 30,
                    default_value = viewer.monospace_font and 16 or 20,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        viewer.text_font_size = spin.value
                        viewer:reinit()
                    end,
                })
            end,
        }},
        {{
            text = _("Monospace font"),
            checked_func = function() return viewer.monospace_font end,
            align = "left",
            callback = function()
                viewer.monospace_font = not viewer.monospace_font
                viewer:reinit()
            end,
        }},
        {{
            text_func = function()
                return _("Text layout: ") .. M.layoutLabel()
            end,
            align = "left",
            callback = function()
                -- the single knob (owner: "one setting, it cycles"):
                -- advance, apply live, re-show the menu so the label
                -- reflects the new mode for the next tap
                M.cycleTextLayout()
                M.applyViewSettings(viewer)
                viewer:reinit()
                UIManager:close(dialog)
                M.showViewMenu(viewer)
            end,
        }},
        {{
            text_func = function()
                return _("Paging direction: ") .. M.pagingModeLabel()
            end,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                M.showPagingMenu(anchor)
            end,
        }},
    }
    dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        buttons = buttons,
        anchor = anchor,
    }
    UIManager:show(dialog)
    return dialog
end

--- Rebuild the viewer's title-bar hamburger page-relevant (view menu
-- above). No-op on KOReader versions whose TextViewer has no hamburger
-- — the settings-menu radio still covers those.
function M.wirePagingMenu(viewer)
    if viewer._qr_paging_menu then return end
    local orig_show_menu = viewer.onShowMenu
    if not orig_show_menu then return end
    viewer._qr_paging_menu = true
    viewer.onShowMenu = function(self_v)
        local ok = pcall(M.showViewMenu, self_v)
        if not ok then return orig_show_menu(self_v) end
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
    -- effective direction for this surface: declaration wins, undeclared
    -- content is classified from the rendered text (same inputs the
    -- tap/swipe wiring uses — buttons and gestures can never disagree)
    local content_rtl = spec.content_rtl
    if content_rtl == nil then content_rtl = M.textDirectionRTL(spec.text) end
    local inv = M.pagingInverted(content_rtl)
    local live = activeViewer()
    -- hop-stack bookkeeping (D-R2-8): a different-kind surface over a
    -- live viewer is a HOP — push what's on screen so ← can return to
    -- it; same kind = stepping = replace. Pops re-show stacked specs
    -- through this same path with the push suppressed.
    if live and not M._navigating and M._spec
            and spec.kind ~= M._spec.kind then
        table.insert(M._stack, M._spec)
        while #M._stack > 10 do table.remove(M._stack, 1) end
        -- info-level: one line per hop — the ground truth for any
        -- "back button didn't stack" report (owner 2026-07-17: a
        -- two-viewer session that no repro could recreate)
        logger.info("quran.koplugin: hop push:",
            tostring(M._spec.kind), "->", tostring(spec.kind),
            "stack:", #M._stack)
    end
    if not live then
        M._stack = {}
        logger.info("quran.koplugin: reader fresh surface:",
            tostring(spec.kind))
    end
    M._spec = spec
    if live then
        live.title = spec.title
        live.text = spec.text
        live._qr_content_rtl = spec.content_rtl
        live.buttons_table = { buildRow(spec, function() return live end, inv) }
        live:init(true)
        wireScroll(live, spec)
        M.wireTouchPaging(live)
        if live.frame and live.frame.dimen then
            -- "ui" (non-flashing region refresh), not stock reinit's
            -- "partial": navigation steps flashed the whole frame incl.
            -- the button row (owner 2026-07-17 polish note); KOReader's
            -- periodic full refresh clears any e-ink ghosting
            UIManager:setDirty("all", "ui", live.frame.dimen)
        end
        return live
    end

    local TextViewer = require("ui/widget/textviewer")
    local Device = require("device")
    local Screen = Device.screen

    -- The persisted text-layout knob rides in at construction
    -- (TextViewer:new runs init immediately)
    local forced = M.text_layout == "rtl" or M.text_layout == "ltr"
    local viewer
    viewer = TextViewer:new{
        title = spec.title,
        text = spec.text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        justified = M.text_layout == "justify",
        auto_para_direction = not forced,
        para_direction_rtl = forced and M.text_layout == "rtl" or nil,
        buttons_table = { buildRow(spec, function() return viewer end, inv) },
    }
    viewer._qr_active = true
    -- clear the module handle AND the hop stack however the viewer
    -- dies (titlebar ✕, tap-outside, back key, our own buttons)
    local orig_close_widget = viewer.onCloseWidget
    viewer.onCloseWidget = function(v)
        if M._viewer == v then M._viewer = nil end
        M._stack = {}
        M._spec = nil
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
    -- the user's roster (enable/disable + order settings) — every
    -- enabled translation renders, each under its bold name header
    local translations = qt.enabledTranslations
        and qt.enabledTranslations(quran, conn, surah, ayah)
        or qt.translations(conn, surah, ayah)

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

    -- KFGQPC → display-normalized (QPC trio renders as wrong/%-looking
    -- marks in the TextViewer's UI fonts; quran:displayArabic = the
    -- word-dict 1.1c mapping)
    local arabic = quran.displayArabic
        and quran:displayArabic(entry.text) or entry.text
    M.show{
        kind = "ayah",  -- hop-stack surface identity (D-R2-8)
        title = string.format("%s %d:%d", name, surah, ayah),
        text = M.renderAyahText(meta, arabic, translations),
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
            -- R3-F11: the entry's baked-in header duplicates the title
            if quran._stripEntryHeader then
                def = quran:_stripEntryHeader(def)
            end
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
            -- per-DICT hop identity (owner 2026-07-17: a translation
            -- dict → tafsir transition must hop, not replace): ◀ ▶ and
            -- gap-skip stepping stay within one dict = replace; Switch
            -- or any cross-dict move = push, ← returns to the previous
            -- dict by name
            kind = "dict:" .. dict,
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
        if def and quran._stripEntryHeader then
            def = quran:_stripEntryHeader(def)  -- R3-F11
        end
        local body = def and quran:_htmlToText(def)
            or _("(No overview entry for this surah.)")
        M.show{
            kind = "dict:" .. dict,  -- per-dict identity (D-R2-8)
            title = _("Overview") .. " · " .. name,
            text = body,
            back_label = opts.back_label,
        }
    end)
    return true
end

logger.dbg("quran.koplugin: quran_reader loaded")

return M
