--[[--
Dynamic in-book marking (design D-R2-5; owner calls 2026-07-16): a
paint-time VIEW OVERLAY, never annotations — nothing persisted, nothing
in the user's bookmark/annotation lists, zero re-render. Three layers
over the qul package (Hafs-keyed, invariant D8):

  mutashabihat  ayahs carrying a repeated-phrase occurrence (phrase_occ)
  themes        ayahs where a theme span STARTS (theme.ayah_from)
  similar       ayahs in a similar-ayah pair (similar, either side)

Per page: visible book-space ayah range (quran_actions.visibleAyahRange,
clamp-immune) → each enabled layer's marked ayahs (SQL over the range,
book↔Hafs mapped for Warsh) → ayah anchor pair per the book's anchor
convention → word boxes via getWordBoxesFromPositions (the KOReader
highlight call — verified live in the D-R2-5 spike) → grayscale styles
(lighten / underline / margin bar). Toggles live in the quick panel;
per-layer styles in the settings menu (owner judges them in the
emulator — C3 answer). Similar-pairs upgrade path: the explorer QurSim
extract can replace the qul `similar` table when it lands.
--]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

M.LAYERS = {
    { key = "mutashabihat", label = _("Mutashabihat"),
      default_style = "lighten" },
    { key = "themes", label = _("Theme starts"),
      default_style = "gutter" },
    { key = "similar", label = _("Similar ayahs"),
      default_style = "underline" },
}

M.STYLES = {
    { key = "lighten", label = _("Gray highlight") },
    { key = "underline", label = _("Underline") },
    { key = "gutter", label = _("Margin bar") },
}

-- ---------------------------------------------------------------------
-- Settings (all layers OFF by default; toggling repaints)
-- ---------------------------------------------------------------------

function M.enabled(quran, layer_key)
    return quran.settings:isTrue("marks_" .. layer_key)
end

function M.setEnabled(quran, layer_key, on)
    quran.settings:saveSetting("marks_" .. layer_key, on and true or false)
    quran.settings:flush()
    M.invalidate(quran)
end

function M.anyEnabled(quran)
    for _i, l in ipairs(M.LAYERS) do
        if M.enabled(quran, l.key) then return true end
    end
    return false
end

function M.styleFor(quran, layer_key)
    local default
    for _i, l in ipairs(M.LAYERS) do
        if l.key == layer_key then default = l.default_style end
    end
    return quran.settings:readSetting("marks_style_" .. layer_key, default)
end

function M.setStyle(quran, layer_key, style_key)
    quran.settings:saveSetting("marks_style_" .. layer_key, style_key)
    quran.settings:flush()
    M.invalidate(quran)
end

M._gen = 0

--- Drop the page cache and repaint (layer/style change).
function M.invalidate(quran)
    M._gen = M._gen + 1
    if quran then
        quran._marks_cache_key = nil
        quran._marks_cache = nil
    end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager then UIManager:setDirty("all", "ui") end
end

-- ---------------------------------------------------------------------
-- Layer queries (same stmt idiom as quran_qul's rows())
-- ---------------------------------------------------------------------

local function rows(conn, sql, bind)
    local out = {}
    local ok, err = pcall(function()
        local stmt = conn:prepare(sql)
        for i, v in ipairs(bind or {}) do
            stmt:bind1(i, v)
        end
        while true do
            local row = stmt:step()
            if not row then break end
            table.insert(out, row)
        end
        stmt:close()
    end)
    if not ok then
        logger.info("quran.koplugin: marks query failed:", err)
    end
    return out
end

--- Hafs-ayah set (keys = ayah numbers) for one layer within
-- [h1, h2] of surah. Pure given a connection — harness-tested against
-- the real qul build.
function M.layerAyahs(conn, layer_key, surah, h1, h2, min_score)
    local set = {}
    local sql, bind
    if layer_key == "mutashabihat" then
        sql = [[SELECT DISTINCT ayah FROM phrase_occ
                WHERE surah = ? AND ayah BETWEEN ? AND ?]]
        bind = { surah, h1, h2 }
    elseif layer_key == "themes" then
        sql = [[SELECT DISTINCT ayah_from FROM theme
                WHERE surah = ? AND ayah_from BETWEEN ? AND ?]]
        bind = { surah, h1, h2 }
    elseif layer_key == "similar" then
        -- the extract stores one direction per pair — an ayah is marked
        -- when it sits on EITHER side; min_score = the similar-ayah
        -- strength floor (weak word-overlap pairs stay unmarked)
        sql = [[SELECT ayah FROM similar
                WHERE surah = ?1 AND ayah BETWEEN ?2 AND ?3
                  AND score >= ?4
                UNION
                SELECT m_ayah FROM similar
                WHERE m_surah = ?1 AND m_ayah BETWEEN ?2 AND ?3
                  AND score >= ?4]]
        bind = { surah, h1, h2, min_score or 0 }
    else
        return set
    end
    for _i, r in ipairs(rows(conn, sql, bind)) do
        set[tonumber(r[1])] = true
    end
    return set
end

-- ---------------------------------------------------------------------
-- Page resolution (cached per page + settings generation)
-- ---------------------------------------------------------------------

--- Marked BOOK-space ayahs on the current page. Returns
-- { surah = s, ayahs = { [book_ayah] = {layer_key, …} }, boxes = {} }
-- or nil when nothing is marked / resolvable. Box resolution is lazy
-- (drawMarks fills marks.boxes on first paint of the page).
function M.marksForPage(quran)
    local doc = quran.ui and quran.ui.document
    if not (doc and doc.getCurrentPage) then return nil end
    -- cache check FIRST — the paint hook re-enters here on every
    -- refresh, so nothing below (module loads, db scans, SQL) may run
    -- for an already-resolved page (review 2026-07-16)
    local pageno = doc:getCurrentPage()
    local okx, xp = pcall(doc.getXPointer, doc)
    local key = tostring(pageno) .. "|" .. tostring(okx and xp or "")
        .. "|" .. M._gen
    if quran._marks_cache_key == key then return quran._marks_cache end

    local out = nil
    -- a missing qul package is memoized per settings generation —
    -- otherwise every page turn would re-run findDb's directory scans;
    -- toggling a layer (invalidate → gen++) retries once
    if quran._marks_no_db ~= M._gen then
        local actions = quran._actionsModule and quran:_actionsModule()
        local qul = quran._qulModule and quran:_qulModule()
        local conn = actions and actions.visibleAyahRange
            and qul and qul.ensureDb and qul.ensureDb(quran)
        if not conn then
            quran._marks_no_db = M._gen
        else
            local surah, first, last = actions.visibleAyahRange(quran)
            if surah and first and last then
                local function toHafs(a)
                    if quran._warshToHafs then
                        return quran:_warshToHafs(surah, a)
                    end
                    return a
                end
                local h1, h2 = toHafs(first), toHafs(last)
                local sim_min = (qul.similarMinScore
                    and qul.similarMinScore(quran)) or 80
                for _i, l in ipairs(M.LAYERS) do
                    if M.enabled(quran, l.key) then
                        local hset = M.layerAyahs(conn, l.key, surah,
                            h1, h2, sim_min)
                        for a = first, last do
                            if hset[toHafs(a)] then
                                out = out
                                    or { surah = surah, ayahs = {}, boxes = {} }
                                out.ayahs[a] = out.ayahs[a] or {}
                                table.insert(out.ayahs[a], l.key)
                            end
                        end
                    end
                end
            end
        end
    end
    quran._marks_cache_key = key
    quran._marks_cache = out
    return out
end

-- ---------------------------------------------------------------------
-- Box resolution + painting
-- ---------------------------------------------------------------------

--- Screen word-boxes for BOOK ayah a (nil when an anchor is missing —
-- edge ayahs of anchorless spans degrade silently, never crash).
-- Two engines: the live app's CreDocument wrapper exposes
-- getScreenBoxesFromPositions (Geom {x,y,w,h} — normalized here back
-- to {x0,y0,x1,y1}); the raw cre doc (harness) exposes
-- getWordBoxesFromPositions directly.
function M.ayahBoxes(quran, surah, a)
    local doc = quran.ui and quran.ui.document
    if not (doc and (doc.getScreenBoxesFromPositions
            or doc.getWordBoxesFromPositions)) then return nil end
    local actions = quran._actionsModule and quran:_actionsModule()
    if not (actions and actions.resolveAnchorRef) then return nil end
    local conv = actions.anchorConvention
        and actions.anchorConvention(quran) or "end"
    local ref0, ref1
    if conv == "start" then
        -- the ayah's own anchor opens it; the next anchor (or the next
        -- surah header) closes it. Known degrade: 114:6 — the mushaf's
        -- final ayah — has no closing anchor on start-anchored books
        -- and stays unmarked (one ayah, accepted; review 2026-07-16)
        ref0 = actions.resolveAnchorRef(quran, surah, a)
        ref1 = actions.resolveAnchorRef(quran, surah, a + 1)
        if not ref1 and surah < 114 then
            ref1 = actions.resolveAnchorRef(quran, surah + 1, nil)
        end
    else
        -- end-anchored (flow layouts): the previous ayah's end marker
        -- opens it; its own marker closes it
        if a > 1 then
            ref0 = actions.resolveAnchorRef(quran, surah, a - 1)
        else
            ref0 = actions.resolveAnchorRef(quran, surah, nil)
        end
        ref1 = actions.resolveAnchorRef(quran, surah, a)
    end
    if not (ref0 and ref1) then return nil end
    if doc.getScreenBoxesFromPositions then
        local ok, geoms = pcall(doc.getScreenBoxesFromPositions, doc,
            ref0, ref1, true)
        if ok and type(geoms) == "table" then
            local boxes = {}
            for _i, g in ipairs(geoms) do
                if g.w and g.w > 0 and g.h and g.h > 0 then
                    table.insert(boxes, { x0 = g.x, y0 = g.y,
                        x1 = g.x + g.w, y1 = g.y + g.h })
                end
            end
            if #boxes > 0 then return boxes end
        end
        return nil
    end
    local ok, boxes = pcall(doc.getWordBoxesFromPositions, doc,
        ref0, ref1, true)
    if ok and type(boxes) == "table" and #boxes > 0 then return boxes end
end

--- Merge boxes into per-line bands (for the gutter style). Merges
-- until stable — a tall box can bridge two previously-separate bands
-- (review 2026-07-16). Exposed for the harness.
function M.lineBands(boxes)
    local bands = {}
    for _i, b in ipairs(boxes) do
        table.insert(bands, { y0 = b.y0, y1 = b.y1 })
    end
    local merged = true
    while merged do
        merged = false
        for i = 1, #bands - 1 do
            for j = i + 1, #bands do
                if bands[i].y0 <= bands[j].y1
                        and bands[i].y1 >= bands[j].y0 then
                    bands[i].y0 = math.min(bands[i].y0, bands[j].y0)
                    bands[i].y1 = math.max(bands[i].y1, bands[j].y1)
                    table.remove(bands, j)
                    merged = true
                    break
                end
            end
            if merged then break end
        end
    end
    return bands
end

--- Paint one style over one ayah's boxes. Grayscale-native ops only.
function M.paintBoxes(bb, x, y, boxes, style)
    local Blitbuffer = require("ffi/blitbuffer")
    if style == "underline" then
        for _i, b in ipairs(boxes) do
            local w = b.x1 - b.x0
            if w > 0 then
                bb:paintRect(x + b.x0, y + b.y1 - 1, w, 2,
                    Blitbuffer.COLOR_DARK_GRAY)
            end
        end
    elseif style == "gutter" then
        for _j, band in ipairs(M.lineBands(boxes)) do
            local h = band.y1 - band.y0
            if h > 0 then
                bb:paintRect(x + 2, y + band.y0, 4, h,
                    Blitbuffer.COLOR_DARK_GRAY)
            end
        end
    else -- lighten (default)
        for _i, b in ipairs(boxes) do
            local w, h = b.x1 - b.x0, b.y1 - b.y0
            if w > 0 and h > 0 then
                bb:lightenRect(x + b.x0, y + b.y0, w, h)
            end
        end
    end
end

--- Paint-hook body — runs inside the view paintTo wrapper (main.lua),
-- after the page render. Must NEVER break the render loop: everything
-- is pcall-guarded and cache-backed.
function M.drawMarks(quran, bb, x, y)
    local ok, err = pcall(function()
        -- paged mode only: in CRE scroll mode the view xpointer moves
        -- with every scroll (cache thrash) and word boxes are relative
        -- to a page frame the scroll view doesn't honor
        local view = quran.ui and quran.ui.view
        if view and view.view_mode == "scroll" then return end
        local marks = M.marksForPage(quran)
        if not marks then return end
        for a, layer_keys in pairs(marks.ayahs) do
            if marks.boxes[a] == nil then
                marks.boxes[a] = M.ayahBoxes(quran, marks.surah, a) or false
            end
            local boxes = marks.boxes[a]
            if boxes then
                for _i, lk in ipairs(layer_keys) do
                    M.paintBoxes(bb, x, y, boxes, M.styleFor(quran, lk))
                end
            end
        end
    end)
    if not ok then
        logger.info("quran.koplugin: marks draw failed:", err)
    end
end

logger.dbg("quran.koplugin: quran_marks loaded")

return M
