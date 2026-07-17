--[[--
The compact AYAH CARD (design D-R2-9, owner direction 2026-07-17): a
sleek launcher popup for an ayah's connections and reading — the
default ayah long-press surface. ENTRY-POINT-AWARE: when the pressed
ayah is marked by an enabled marking layer (D-R2-5), the card LEADS
with that layer's content — the similar verses / the themes / the
repeated phrases sit right there — instead of the generic row set.
Every row opens an EXISTING surface (Reader, browser screens): the
card renders no content of its own.
--]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

--- Lead layer for the pressed ayah: the enabled marking layer that
-- explains why the user pressed a MARKED ayah. Priority: similar >
-- mutashabihat > themes. nil when unmarked or marking is off.
function M.leadFor(quran, surah, book_ayah)
    local marks = quran._marksModule and quran:_marksModule()
    if not marks then return nil end
    local page_marks = marks.marksForPage(quran)
    if not (page_marks and page_marks.surah == surah) then return nil end
    local layers = page_marks.ayahs[book_ayah]
    if not layers then return nil end
    local has = {}
    for _i, l in ipairs(layers) do has[l] = true end
    if has.similar then return "similar" end
    if has.mutashabihat then return "mutashabihat" end
    if has.themes then return "themes" end
end

--- Show the card for surah:hafs (ayah in the Hafs data key space, D8).
-- opts.lead forces a landing; otherwise the marking layers decide.
-- Returns true, or false when no launcher context exists (caller falls
-- back to the resources popup).
function M.show(quran, surah, hafs, opts)
    opts = opts or {}
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local actions = quran._actionsModule and quran:_actionsModule()
    if not (actions and actions.showBrowser) then return false end
    local qul = quran._qulModule and quran:_qulModule()
    local conn = qul and qul.ensureDb and qul.ensureDb(quran)
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

    -- entry-point lead: marks are keyed book-space on the page cache
    local book_ayah = hafs
    if quran._hafsToWarshStart then
        book_ayah = quran:_hafsToWarshStart(surah, hafs) or hafs
    end
    local lead = opts.lead or M.leadFor(quran, surah, book_ayah)
    local sim_min = (qul and qul.similarMinScore
        and qul.similarMinScore(quran)) or 80
    local counts = (conn and qul.countsFor
        and qul.countsFor(conn, surah, hafs, sim_min)) or {}

    -- ------------------------------------------------------------------
    -- Lead section: the relevant content right there (full-width rows)
    -- ------------------------------------------------------------------
    if lead == "similar" and conn then
        local sims = qul.similarFor(conn, surah, hafs, sim_min)
        for i = 1, math.min(#sims, 4) do
            local p = sims[i]
            local pname = quran.surahName and quran:surahName(p.surah)
                or tostring(p.surah)
            table.insert(buttons, { {
                text = string.format("≈ %s %d:%d", pname, p.surah, p.ayah),
                align = "left",
                font_bold = false,
                callback = close_then(function()
                    if not (reader and reader.showAyah
                            and reader.showAyah(quran, p.surah, p.ayah,
                                { explore = true })) then
                        quran:openBrowserAtAyah(p.surah, p.ayah)
                    end
                end),
            } })
        end
        if #sims > 4 then
            table.insert(buttons, { {
                text = string.format("≈ %s (%d) →", _("All similar"), #sims),
                align = "left",
                font_bold = false,
                callback = inBrowser(function(browser, q2)
                    q2.showSimilar(browser, surah, hafs)
                end),
            } })
        end
    elseif lead == "themes" and conn then
        for _i, t in ipairs(qul.themesFor(conn, surah, hafs)) do
            local label = t.theme or ""
            if #label > 44 then label = label:sub(1, 42) .. "…" end
            table.insert(buttons, { {
                text = "☰ " .. label,
                align = "left",
                font_bold = false,
                callback = inBrowser(function(browser, q2)
                    q2.showThemesFor(browser, surah, hafs)
                end),
            } })
        end
    elseif lead == "mutashabihat" and conn then
        table.insert(buttons, { {
            text = string.format("⧉ %s (%d) →", _("Repeated phrases"),
                counts.phrases or 0),
            align = "left",
            font_bold = false,
            callback = inBrowser(function(browser, q2)
                q2.showMutashabihat(browser, surah, hafs)
            end),
        } })
    end

    -- ------------------------------------------------------------------
    -- Reading rows (only what is actually available)
    -- ------------------------------------------------------------------
    if text_conn and reader and reader.showAyah then
        addButton({
            text = _("Read"),
            callback = close_then(function()
                reader.showAyah(quran, surah, hafs, { explore = true })
            end),
        })
    end
    if quran.canReaderTafsir and quran:canReaderTafsir() then
        addButton({
            text = _("Tafsir"),
            callback = close_then(function()
                quran:openTafsirReader(surah, hafs, { explore = true })
            end),
        })
    end
    -- Grammar (R3-F9): ayah-keyed like tafsir — same Reader route
    local res = actions.detectResources and actions.detectResources(quran)
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
    -- 2-per-row grid (the quick panel's idiom); only the trailing
    -- Close row stands alone

    -- ------------------------------------------------------------------
    -- Connection rows with live counts (the lead's own row is skipped —
    -- its content already sits on top); zero counts stay visible but
    -- disabled, so the card's shape is stable page to page
    -- ------------------------------------------------------------------
    if conn then
        local function connButton(n, label, fn)
            addButton({
                text = string.format("%s (%d)", label, n or 0),
                enabled = (n or 0) > 0,
                callback = inBrowser(fn),
            })
        end
        if lead ~= "similar" then
            connButton(counts.similar, _("Similar"), function(b, q2)
                q2.showSimilar(b, surah, hafs)
            end)
        end
        if lead ~= "themes" then
            connButton(counts.themes, _("Themes"), function(b, q2)
                q2.showThemesFor(b, surah, hafs)
            end)
        end
        if lead ~= "mutashabihat" then
            connButton(counts.phrases, _("Phrases"), function(b, q2)
                q2.showMutashabihat(b, surah, hafs)
            end)
        end
        connButton(counts.topics, _("Topics"), function(b, q2)
            q2.showTopicsFor(b, surah, hafs)
        end)
    end

    -- ------------------------------------------------------------------
    -- Tail: the full ayah page joins the grid; Close stands alone
    -- (R3-F13 — a single can only be the grid's last cell when the
    -- button count is odd)
    -- ------------------------------------------------------------------
    addButton({
        text = _("Ayah page") .. " →",
        callback = close_then(function()
            quran:openBrowserAtAyah(surah, hafs)
        end),
    })
    flushRow()
    table.insert(buttons, { {
        text = _("Close"),
        font_bold = false,
        callback = function() UIManager:close(dialog) end,
    } })

    dialog = ButtonDialog:new{
        title = string.format("%s %d:%d", name, surah, hafs),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
    logger.dbg("quran.koplugin: ayah card", surah, hafs,
        "lead:", tostring(lead))
    return true
end

logger.dbg("quran.koplugin: quran_ayahpopup loaded")

return M
