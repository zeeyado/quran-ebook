--[[--
The compact AYAH CARD (design D-R2-9; STABLE shape per D-R3-5, owner
2026-07-17): a sleek launcher popup for an ayah's connections and
reading — the default ayah long-press surface. The card presents the
SAME way whether or not the ayah is marked: the four counted
connection rows always, same order, same names (marked state is shown
only by the in-book mark itself). Connection rows land the per-kind
browser LIST screen, never a single connection directly — siblings
are never lost (D-R3-12). Every row opens an EXISTING surface
(Reader, browser screens): the card renders no content of its own.
--]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

--- Show the card for surah:hafs (ayah in the Hafs data key space, D8).
-- Returns true, or false when no launcher context exists (caller falls
-- back to the resources popup).
function M.show(quran, surah, hafs)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local actions = quran._actionsModule and quran:_actionsModule()
    if not (actions and actions.showBrowser) then return false end
    local qul = quran._qulModule and quran:_qulModule()
    local conn = qul and qul.ensureDb and qul.ensureDb(quran)
    -- DA-7 connections package (characters / stories / semantic pairs)
    local cx = quran._connectionsModule and quran:_connectionsModule()
    local cxconn = cx and cx.ensureDb and cx.ensureDb(quran)
    local reader = quran._readerModule and quran:_readerModule()
    local qt = quran._textModule and quran:_textModule()
    local text_conn = qt and qt.ensureDb and qt.ensureDb(quran)

    local name = quran.surahName and quran:surahName(surah)
        or tostring(surah)

    local dialog
    local buttons = {}
    local row = {}
    -- the quick panel's grid idiom: 2 per row, flush when full
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
            fn()
        end
    end
    -- land a browser screen (the card is a launcher — design D-R2-9)
    local function inBrowser(fn)
        return close_then(function()
            actions.showBrowser(quran, function(browser)
                local q2 = browser.qulModule and browser:qulModule()
                if q2 then fn(browser, q2) end
            end)
        end)
    end

    local sim_min = (qul and qul.similarMinScore
        and qul.similarMinScore(quran)) or 80
    local counts = (conn and qul.countsFor
        and qul.countsFor(conn, surah, hafs, sim_min)) or {}
    -- semantic pairs beyond the wording list join the Similar count
    -- (the union shown by qul.showSimilar's two labeled sections)
    local sem_extra = 0
    if cxconn then
        local wording = (conn and qul.similarFor
            and qul.similarFor(conn, surah, hafs, sim_min)) or {}
        sem_extra = #cx.diffPairs(
            cx.semanticFor(cxconn, surah, hafs, cx.semanticFloor(quran)),
            wording)
    end

    -- ------------------------------------------------------------------
    -- Reading rows (only what is actually available)
    -- ------------------------------------------------------------------
    if text_conn and reader and reader.showAyah then
        addButton({
            text = _("Translations"),
            callback = close_then(function()
                reader.showAyah(quran, surah, hafs, { explore = true })
            end),
        })
    end
    -- R3-F16: like Grammar, Tafsir only when a tafsir dict is actually
    -- installed — openTafsirReader returns false with none, so the row
    -- was a dead button on fresh installs (found in the live F14 shot)
    local res = actions.detectResources and actions.detectResources(quran)
    if res and res.tafsir and res.tafsir[1]
            and quran.canReaderTafsir and quran:canReaderTafsir() then
        addButton({
            text = _("Tafsir"),
            callback = close_then(function()
                quran:openTafsirReader(surah, hafs, { explore = true })
            end),
        })
    end
    -- Grammar (R3-F9): ayah-keyed like tafsir — same Reader route
    if res and res.grammar and quran.canReaderTafsir
            and quran:canReaderTafsir() then
        addButton({
            text = _("Grammar"),
            callback = close_then(function()
                quran:openTafsirReader(surah, hafs,
                    { dict = res.grammar, explore = true })
            end),
        })
    end
    -- R3-F13: NO flush between button sections — one continuous
    -- 2-per-row grid (the quick panel's idiom); Close joins as the
    -- grid's final cell (R3-F14)

    -- ------------------------------------------------------------------
    -- Connection rows with live counts — the four rows ALWAYS, same
    -- order, same names (stable card, D-R3-5); each lands the per-kind
    -- browser list, so siblings are never lost (D-R3-12). Zero counts
    -- stay visible but disabled: the card's shape is stable page to page
    -- ------------------------------------------------------------------
    local function connButton(n, label, fn)
        addButton({
            text = string.format("%s (%d)", label, n or 0),
            enabled = (n or 0) > 0,
            callback = inBrowser(fn),
        })
    end
    if conn then
        connButton((counts.similar or 0) + sem_extra, _("Similar ayahs"),
            function(b, q2)
                q2.showSimilar(b, surah, hafs)
            end)
        connButton(counts.themes, _("Themes"), function(b, q2)
            q2.showThemesFor(b, surah, hafs)
        end)
        connButton(counts.phrases, _("Repeated phrases"), function(b, q2)
            q2.showMutashabihat(b, surah, hafs)
        end)
        connButton(counts.topics, _("Topics"), function(b, q2)
            q2.showTopicsFor(b, surah, hafs)
        end)
    elseif cxconn then
        -- no qul package: the semantic tier still feeds the same
        -- Similar surface (qul.showSimilar renders both layers)
        connButton(sem_extra, _("Similar ayahs"), function(b, q2)
            q2.showSimilar(b, surah, hafs)
        end)
    end
    -- DA-7 rows: same stable-counted idiom, landing browser LISTS
    if cxconn then
        local function cxButton(n, label, fn)
            addButton({
                text = string.format("%s (%d)", label, n or 0),
                enabled = (n or 0) > 0,
                callback = close_then(function()
                    actions.showBrowser(quran, function(browser)
                        local c2 = browser.connectionsModule
                            and browser:connectionsModule()
                        if c2 then fn(browser, c2) end
                    end)
                end),
            })
        end
        cxButton(#cx.figuresAt(cxconn, surah, hafs), _("Characters"),
            function(b, c2) c2.showFiguresAt(b, surah, hafs) end)
        cxButton(#cx.unitsContaining(cxconn, surah, hafs), _("Story context"),
            function(b, c2) c2.showStoryContext(b, surah, hafs) end)
    end

    -- ------------------------------------------------------------------
    -- Tail: Ayah page AND Close both join the grid (R3-F14 — Close is
    -- the last cell; a full-width single can only be the LAST row,
    -- when the total button count is odd)
    -- ------------------------------------------------------------------
    addButton({
        text = _("Ayah page") .. " →",
        callback = close_then(function()
            quran:openBrowserAtAyah(surah, hafs)
        end),
    })
    addButton({
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    })
    flushRow()

    dialog = ButtonDialog:new{
        title = string.format("%s %d:%d", name, surah, hafs),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
    logger.dbg("quran.koplugin: ayah card", surah, hafs)
    return true
end

logger.dbg("quran.koplugin: quran_ayahpopup loaded")

return M
