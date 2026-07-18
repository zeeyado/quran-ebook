--[[--
quran_bands.lua — theme heading bands (design D-R3-1; GitHub issue #3).

The QUL ayah-theme headings (qul-v1 `theme` table, loaded verbatim from
QUL's ayah-themes.db) injected BETWEEN ayahs of the open book at
runtime: CSS generated content applied through KOReader's style-tweak
machinery — no EPUB rebuild. Visual target = the published Clear
Quran's thematic subheadings (owner 2026-07-17): numbered per surah,
italic, centered, accent-colored over the ayah group (e-ink renders
the color as a distinct gray).

Mechanism (proven live + adversarially verified 2026-07-17; design doc
D-R3-1): crengine renders ::before content as real DOM nodes, and its
#id selector natively matches the `_doc_fragment_N_ ayah-S-A` renamed
ids, so `p#ayah-2-45::before` needs no prefix bookkeeping. One
plugin-owned <DataDir>/styletweaks/quran_theme_bands.css serves every
Quran book (ayah ids are variant-invariant); ReaderStyleTweak re-reads
css_path on every apply, but its ID REGISTRY is built at ReaderUI init
— first-session enables inject the tweak entry into tweaks_by_id
directly. The CSS is emitted BYTE-DETERMINISTICALLY (sorted, no
timestamps): the render cache keys a stylesheet hash, and any churn =
full re-parse every open (the Android slow-open failure class).

Layout gate: bands place cleanly only where the ayah id sits on the
block `<p class="ayah-text">` (ayah-inline / bilingual templates —
the primary reading books). Inline/QCF variants carry ids on inline
spans; the per-ayah `p#…` rules simply never match there (harmless
no-op). GPL-3.0.
]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

M.TWEAK_ID = "quran_theme_bands.css"

-- ---------------------------------------------------------------------
-- Pure CSS generation (unit-tested)
-- ---------------------------------------------------------------------

-- CSS string-literal escape for content: "...". crengine's content
-- parser handles quoted strings with backslash escapes; newlines in
-- titles (none expected) fold to spaces.
function M.cssEscape(s)
    s = tostring(s or "")
    s = s:gsub("[\r\n]+", " ")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    return s
end

-- The shared band look. Content stays unset here — crengine generates
-- nothing for a contentless ::before, so this rule alone is inert.
-- direction:ltr keeps Latin headings unshuffled inside RTL paragraphs
-- (verified live); the accent color grayscales to a distinct gray on
-- e-ink (never dismiss color — owner rule).
M.BLOCK_RULE = 'p.ayah-text::before { display: block; direction: ltr; '
    .. 'text-align: center; font-style: italic; font-size: 0.72em; '
    .. 'margin: 0.55em 0 0.3em; color: #A05A00; }'

--- Deterministic stylesheet for a theme list. themes = array of
-- { surah, ayah_from, theme } PRE-SORTED by (surah, ayah_from, theme).
-- Multiple themes starting on one ayah merge into one band (" · ") —
-- same-specificity CSS rules would otherwise just last-win. Headings
-- are numbered within their surah like the Clear Quran's "2) …".
function M.generateCss(themes)
    local lines = {
        "/* Quran theme headings (quran.koplugin, generated deterministically",
        "   from the qul data package's QUL ayah-theme table — do not edit;",
        "   the plugin rewrites this file). Design D-R3-1 / issue #3. */",
        M.BLOCK_RULE,
    }
    local by_key, order = {}, {}
    local surah_counts = {}
    for _i, t in ipairs(themes) do
        local key = t.surah .. "-" .. t.ayah_from
        if not by_key[key] then
            surah_counts[t.surah] = (surah_counts[t.surah] or 0) + 1
            by_key[key] = {
                n = surah_counts[t.surah],
                titles = {},
            }
            table.insert(order, key)
        end
        table.insert(by_key[key].titles, t.theme)
    end
    for _i, key in ipairs(order) do
        local e = by_key[key]
        local text = string.format("%d) %s", e.n,
            table.concat(e.titles, " · "))
        table.insert(lines, string.format(
            'p#ayah-%s::before { content: "%s"; }',
            key, M.cssEscape(text)))
    end
    return table.concat(lines, "\n") .. "\n"
end

-- ---------------------------------------------------------------------
-- Data + file
-- ---------------------------------------------------------------------

--- All theme starts from the qul package, in deterministic order.
function M.allThemes(conn)
    local out = {}
    local ok, err = pcall(function()
        local stmt = conn:prepare([[
            SELECT surah, ayah_from, theme FROM theme
            ORDER BY surah, ayah_from, theme]])
        while true do
            local row = stmt:step()
            if not row then break end
            table.insert(out, {
                surah = tonumber(row[1]),
                ayah_from = tonumber(row[2]),
                theme = row[3],
            })
        end
        stmt:close()
    end)
    if not ok then
        logger.info("quran.koplugin: bands theme query failed:", err)
    end
    return out
end

function M.cssPath()
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/styletweaks/" .. M.TWEAK_ID
end

--- Write the stylesheet if its bytes differ (determinism makes the
-- comparison exact; unchanged bytes = unchanged stylesheet hash = the
-- render cache stays valid). Returns the path, or nil when no qul
-- data is available.
function M.ensureCssFile(quran)
    local qul = quran._qulModule and quran:_qulModule()
    local conn = qul and qul.ensureDb and qul.ensureDb(quran)
    if not conn then return nil end
    local themes = M.allThemes(conn)
    if #themes == 0 then return nil end
    local css = M.generateCss(themes)
    local path = M.cssPath()
    local f = io.open(path, "r")
    if f then
        local cur = f:read("*all")
        f:close()
        if cur == css then return path end
    else
        local lfs = require("libs/libkoreader-lfs")
        local dir = path:gsub("/[^/]+$", "")
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
    end
    local wf, werr = io.open(path, "w")
    if not wf then
        logger.info("quran.koplugin: bands css write failed:", werr)
        return nil
    end
    wf:write(css)
    wf:close()
    logger.info("quran.koplugin: bands css written:", path)
    return path
end

-- ---------------------------------------------------------------------
-- Style-tweak toggle (per-book, persisted in the sidecar like any
-- user style tweak)
-- ---------------------------------------------------------------------

local function styletweak(quran)
    return quran.ui and quran.ui.styletweak
end

function M.enabled(quran)
    local st = styletweak(quran)
    return (st and st.doc_tweaks and st.doc_tweaks[M.TWEAK_ID] == true)
        or false
end

--- Toggle the bands for the OPEN book. Applies immediately (one full
-- re-render); persists via the style-tweaks sidecar table, so later
-- opens apply pre-render at no extra cost. Returns true, or nil+msg.
function M.setEnabled(quran, on)
    local st = styletweak(quran)
    if not (st and st.doc_tweaks) then
        return nil, _("Style tweaks are not available here.")
    end
    if on then
        -- Warsh guard (variant audit 2026-07-18): the shared CSS keys
        -- p#ayah-S-A by HAFS numbering, but a Warsh book's ids are
        -- Warsh-numbered — bands would misplace in the 50 divergent
        -- surahs. Refuse until a Warsh-numbered stylesheet variant
        -- exists (would need _hafsToWarshStart over ayah_from).
        if quran._riwayah == "warsh" then
            return nil, _("Theme headings are not available on Warsh books yet (ayah numbering differs).")
        end
        local path = M.ensureCssFile(quran)
        if not path then
            return nil, _("Theme headings need the qul data package (Library & assets).")
        end
        if st.enabled == false then
            return nil, _("Enable KOReader's Style tweaks first (top menu).")
        end
        -- first-session registration: the user-tweak registry is built
        -- at ReaderUI init, before this file could have existed
        if st.tweaks_by_id and not st.tweaks_by_id[M.TWEAK_ID] then
            st.tweaks_by_id[M.TWEAK_ID] = {
                id = M.TWEAK_ID,
                title = _("Quran theme headings"),
                priority = 10,
                css_path = path,
            }
        end
        st.doc_tweaks[M.TWEAK_ID] = true
    else
        st.doc_tweaks[M.TWEAK_ID] = nil
    end
    local Notification = require("ui/widget/notification")
    local UIManager = require("ui/uimanager")
    UIManager:show(Notification:new{
        text = on and _("Applying theme headings (re-renders the book)…")
            or _("Removing theme headings…"),
    })
    st:updateCssText(true)
    return true
end

logger.dbg("quran.koplugin: quran_bands loaded")

return M
