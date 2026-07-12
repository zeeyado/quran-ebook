--[[--
quran_qul.lua — v1.12 hub: QUL connections (themes, topics, similar
ayahs, mutashabihat phrases).

Data: qul-vN.sqlite (built by tools/build_qul_data.py from QUL bulk
resources — qul.tarteel.ai; attribution in the meta table), installed to
<koreader>/data/quran/ by the asset manager ("quran_qul" data package)
or dropped next to the plugin for development.

All stored numbering is Hafs (QUL's space). Callers pass Hafs surah:ayah
for queries; jumps convert back to book space (Warsh) at the boundary,
same as the juz machinery. GPL-3.0.
]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

M.SCHEMA_VERSION = "1"

-- ---------------------------------------------------------------------
-- Pure helpers (unit-tested)
-- ---------------------------------------------------------------------

-- Topic descriptions are HTML with embedded <topic data-id=…> links and
-- entities. Flatten to plain text for the viewer.
function M.stripHtml(s)
    if not s then return "" end
    s = s:gsub("<[^>]->", "")
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    s = s:gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Viewer text for a topic (PTF bold meta line, like the Lane entries).
local PTF_HEADER = "\u{FFF1}"
local PTF_B = "\u{FFF2}"
local PTF_E = "\u{FFF3}"

function M.renderTopicText(t)
    local parts = {}
    local meta_bits = {}
    if t.arabic_name and t.arabic_name ~= "" then
        table.insert(meta_bits, t.arabic_name)
    end
    if t.n_ayahs and t.n_ayahs > 0 then
        table.insert(meta_bits, "×" .. t.n_ayahs .. " " .. _("ayahs"))
    end
    if #meta_bits > 0 then
        table.insert(parts, PTF_B .. table.concat(meta_bits, " · ") .. PTF_E)
    end
    local desc = M.stripHtml(t.description)
    if desc ~= "" then
        table.insert(parts, desc)
    end
    if t.wiki_link and t.wiki_link ~= "" then
        table.insert(parts, PTF_B .. _("Wikipedia:") .. PTF_E .. " " .. t.wiki_link)
    end
    if #parts == 0 then
        table.insert(parts, _("No description."))
    end
    return PTF_HEADER .. table.concat(parts, "\n\n")
end

-- ---------------------------------------------------------------------
-- Database access (same shape as quran_roots.lua)
-- ---------------------------------------------------------------------

function M.findDb(quran)
    local lfs = require("libs/libkoreader-lfs")
    local dirs = {}
    local ok, DataStorage = pcall(require, "datastorage")
    if ok then
        table.insert(dirs, DataStorage:getDataDir() .. "/data/quran")
    end
    if quran and quran.path then
        table.insert(dirs, quran.path)
    end
    for _i, dir in ipairs(dirs) do
        if lfs.attributes(dir, "mode") == "directory" then
            for entry in lfs.dir(dir) do
                if entry:match("^qul%-v%d+%.sqlite$") then
                    return dir .. "/" .. entry
                end
            end
        end
    end
end

function M.openPath(path)
    if M._conn and M._db_path == path then
        return M._conn
    end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then
        return nil, _("SQLite support not available in this KOReader build.")
    end
    local open_ok, conn = pcall(SQ3.open, path, "ro")
    if not open_ok or not conn then
        return nil, _("Could not open the QUL database.")
    end
    local ver_ok, ver = pcall(function()
        local stmt = conn:prepare("SELECT value FROM meta WHERE key='schema_version'")
        local row = stmt:step()
        stmt:close()
        return row and tostring(row[1])
    end)
    if not ver_ok or ver ~= M.SCHEMA_VERSION then
        pcall(function() conn:close() end)
        return nil, _("QUL database has an unsupported format — update the plugin or the data package.")
    end
    M._conn = conn
    M._db_path = path
    logger.info("quran.koplugin: opened qul db", path)
    return conn
end

function M.ensureDb(quran)
    local path = M._db_path or M.findDb(quran)
    if not path then
        return nil, _("QUL data package not installed — get it from Library & assets in the Quran browser.")
    end
    return M.openPath(path)
end

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
        logger.info("quran.koplugin: qul query failed:", err)
    end
    return out
end

function M.themesFor(conn, surah, ayah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT theme, surah, ayah_from, ayah_to FROM theme
        WHERE surah = ? AND ? BETWEEN ayah_from AND ayah_to
        ORDER BY ayah_from]], { surah, ayah })) do
        table.insert(out, { theme = r[1], surah = tonumber(r[2]),
            ayah_from = tonumber(r[3]), ayah_to = tonumber(r[4]) })
    end
    return out
end

function M.themesBySurah(conn, surah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT theme, surah, ayah_from, ayah_to FROM theme
        WHERE surah = ? ORDER BY ayah_from]], { surah })) do
        table.insert(out, { theme = r[1], surah = tonumber(r[2]),
            ayah_from = tonumber(r[3]), ayah_to = tonumber(r[4]) })
    end
    return out
end

function M.topicsFor(conn, surah, ayah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT t.topic_id, t.name, t.arabic_name FROM topic_ayah ta
        JOIN topic t ON t.topic_id = ta.topic_id
        WHERE ta.surah = ? AND ta.ayah = ? ORDER BY t.name]], { surah, ayah })) do
        table.insert(out, { topic_id = tonumber(r[1]), name = r[2], arabic_name = r[3] })
    end
    return out
end

function M.topic(conn, topic_id)
    local r = rows(conn, [[
        SELECT topic_id, name, arabic_name, description, wiki_link,
               related_topics,
               (SELECT count(*) FROM topic_ayah WHERE topic_id = topic.topic_id)
        FROM topic WHERE topic_id = ?]], { topic_id })[1]
    if not r then return end
    return { topic_id = tonumber(r[1]), name = r[2], arabic_name = r[3],
        description = r[4], wiki_link = r[5], related_topics = r[6],
        n_ayahs = tonumber(r[7]) }
end

-- Child + ayah counts per node (counts on every tree row — the bare
-- 3-name landing read as "almost no topics")
local TOPIC_COUNTS_SQL = [[
        (SELECT count(*) FROM topic c
         WHERE c.thematic_parent_id = topic.topic_id
            OR c.ontology_parent_id = topic.topic_id),
        (SELECT count(*) FROM topic_ayah ta WHERE ta.topic_id = topic.topic_id)]]

function M.topicChildren(conn, topic_id)
    local out, seen = {}, {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name, ]] .. TOPIC_COUNTS_SQL .. [[ FROM topic
        WHERE thematic_parent_id = ? OR ontology_parent_id = ?
        ORDER BY name]], { topic_id, topic_id })) do
        local id = tonumber(r[1])
        if not seen[id] then
            seen[id] = true
            table.insert(out, { topic_id = id, name = r[2],
                n_children = tonumber(r[3]), n_ayahs = tonumber(r[4]) })
        end
    end
    return out
end

--- The topic's parents (thematic and/or ontology), with counts. A topic
-- reached sideways — search, A–Z, an ayah page — needs a way UP the
-- tree, not just down (connections idiom, owner 2026-07-12).
function M.topicParents(conn, topic_id)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name, ]] .. TOPIC_COUNTS_SQL .. [[ FROM topic
        WHERE topic_id IN (
            SELECT thematic_parent_id FROM topic WHERE topic_id = ?
            UNION
            SELECT ontology_parent_id FROM topic WHERE topic_id = ?)
        ORDER BY name]], { topic_id, topic_id })) do
        table.insert(out, { topic_id = tonumber(r[1]), name = r[2],
            n_children = tonumber(r[3]), n_ayahs = tonumber(r[4]) })
    end
    return out
end

--- QUL's cross-topic links ("related_topics" ids), with counts. Sparse
-- upstream (17 of 2,512 topics carry them) but free to surface — the
-- dynamic-xray "linked items" idiom; richer link data (concepts,
-- characters, semantic pairs) is an explorer-side extract away.
function M.relatedTopics(conn, t)
    local ids, marks = {}, {}
    for id in tostring(t.related_topics or ""):gmatch("%d+") do
        table.insert(ids, tonumber(id))
        table.insert(marks, "?")
    end
    if #ids == 0 then return {} end
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name, ]] .. TOPIC_COUNTS_SQL .. [[ FROM topic
        WHERE topic_id IN (]] .. table.concat(marks, ",") .. [[)
        ORDER BY name]], ids)) do
        table.insert(out, { topic_id = tonumber(r[1]), name = r[2],
            n_children = tonumber(r[3]), n_ayahs = tonumber(r[4]) })
    end
    return out
end

--- Topics attached to ayahs inside a theme's range (the shipped-data
-- tier of the connections direction: theme → topics-in-range).
function M.themeTopics(conn, surah, ayah_from, ayah_to)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT DISTINCT topic.topic_id, topic.name, ]] .. TOPIC_COUNTS_SQL .. [[
        FROM topic_ayah ta
        JOIN topic ON topic.topic_id = ta.topic_id
        WHERE ta.surah = ? AND ta.ayah BETWEEN ? AND ?
        ORDER BY topic.name]], { surah, ayah_from, ayah_to })) do
        table.insert(out, { topic_id = tonumber(r[1]), name = r[2],
            n_children = tonumber(r[3]), n_ayahs = tonumber(r[4]) })
    end
    return out
end

function M.topicRoots(conn)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name, ]] .. TOPIC_COUNTS_SQL .. [[ FROM topic
        WHERE thematic = 1 AND thematic_parent_id IS NULL
        ORDER BY name]])) do
        table.insert(out, { topic_id = tonumber(r[1]), name = r[2],
            n_children = tonumber(r[3]), n_ayahs = tonumber(r[4]) })
    end
    return out
end

function M.topicCount(conn)
    local r = rows(conn, "SELECT count(*) FROM topic")[1]
    return r and tonumber(r[1]) or 0
end

--- Every topic, A–Z, with ayah counts (the flat browse behind the tree).
function M.allTopics(conn)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name, arabic_name, ]] .. TOPIC_COUNTS_SQL .. [[
        FROM topic ORDER BY name]])) do
        table.insert(out, { topic_id = tonumber(r[1]), name = r[2],
            arabic_name = r[3], n_children = tonumber(r[4]),
            n_ayahs = tonumber(r[5]) })
    end
    return out
end

--- Substring search over topic names (English + Arabic; LIKE is enough
-- for 2.5k rows — no FTS in the qul package by design).
function M.searchTopics(conn, q, limit)
    local like = "%" .. q .. "%"
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name, arabic_name, ]] .. TOPIC_COUNTS_SQL .. [[
        FROM topic WHERE name LIKE ? OR arabic_name LIKE ?
        ORDER BY name LIMIT ?]], { like, like, limit or 50 })) do
        table.insert(out, { topic_id = tonumber(r[1]), name = r[2],
            arabic_name = r[3], n_children = tonumber(r[4]),
            n_ayahs = tonumber(r[5]) })
    end
    return out
end

--- Substring search over theme texts.
function M.searchThemes(conn, q, limit)
    local like = "%" .. q .. "%"
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT theme, surah, ayah_from, ayah_to FROM theme
        WHERE theme LIKE ? ORDER BY surah, ayah_from LIMIT ?]],
        { like, limit or 20 })) do
        table.insert(out, { theme = r[1], surah = tonumber(r[2]),
            ayah_from = tonumber(r[3]), ayah_to = tonumber(r[4]) })
    end
    return out
end

function M.topicAyahs(conn, topic_id)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT surah, ayah FROM topic_ayah WHERE topic_id = ?
        ORDER BY surah, ayah]], { topic_id })) do
        table.insert(out, { surah = tonumber(r[1]), ayah = tonumber(r[2]) })
    end
    return out
end

function M.similarFor(conn, surah, ayah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT m_surah, m_ayah, score, coverage FROM similar
        WHERE surah = ? AND ayah = ? ORDER BY score DESC]], { surah, ayah })) do
        table.insert(out, { surah = tonumber(r[1]), ayah = tonumber(r[2]),
            score = tonumber(r[3]), coverage = tonumber(r[4]) })
    end
    return out
end

function M.phrasesFor(conn, surah, ayah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT DISTINCT pg.group_id, pg.count, pg.ayahs FROM phrase_occ po
        JOIN phrase_group pg ON pg.group_id = po.group_id
        WHERE po.surah = ? AND po.ayah = ? ORDER BY pg.count DESC]], { surah, ayah })) do
        table.insert(out, { group_id = tonumber(r[1]), count = tonumber(r[2]),
            n_ayahs = tonumber(r[3]) })
    end
    return out
end

function M.phraseOccurrences(conn, group_id)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT surah, ayah, w_from, w_to FROM phrase_occ
        WHERE group_id = ? ORDER BY surah, ayah]], { group_id })) do
        table.insert(out, { surah = tonumber(r[1]), ayah = tonumber(r[2]),
            w_from = tonumber(r[3]), w_to = tonumber(r[4]) })
    end
    return out
end

-- Per-ayah connection counts for the position screen (one cheap query).
function M.countsFor(conn, surah, ayah)
    local r = rows(conn, [[
        SELECT
          (SELECT count(*) FROM similar WHERE surah = ?1 AND ayah = ?2),
          (SELECT count(*) FROM theme WHERE surah = ?1 AND ?2 BETWEEN ayah_from AND ayah_to),
          (SELECT count(*) FROM topic_ayah WHERE surah = ?1 AND ayah = ?2),
          (SELECT count(DISTINCT group_id) FROM phrase_occ WHERE surah = ?1 AND ayah = ?2)
    ]], { surah, ayah })[1]
    if not r then return nil end
    return { similar = tonumber(r[1]), themes = tonumber(r[2]),
        topics = tonumber(r[3]), phrases = tonumber(r[4]) }
end

-- ---------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------

local function notifyWarn(text)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = text })
end

-- Every ayah reference navigates to the unified ayah page (design D4 —
-- the ButtonDialog jump/read chooser this replaced is retired).
local function ayahDialog(browser, surah, ayah, _subtitle)
    browser:showAyahPage(surah, ayah)
end

-- "12 ▸ · ×147": children first (browsing signal), ayah count second
local function topicCounts(t)
    local bits = {}
    if t.n_children and t.n_children > 0 then
        table.insert(bits, t.n_children .. " ▸")
    end
    if t.n_ayahs and t.n_ayahs > 0 then
        table.insert(bits, "×" .. t.n_ayahs)
    end
    if #bits > 0 then return table.concat(bits, " · ") end
end

local function topicItem(browser, t)
    local label = t.name
    if t.arabic_name and t.arabic_name ~= "" then
        label = label .. "  " .. t.arabic_name
    end
    return {
        text = label,
        mandatory = topicCounts(t),
        callback = function() M.showTopic(browser, t.topic_id) end,
    }
end

function M.showSimilar(browser, surah, ayah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local list = M.similarFor(conn, surah, ayah)
    if #list == 0 then
        notifyWarn(_("No similar ayahs recorded here."))
        return
    end
    local quran = browser.quran
    local items = {}
    for _i, m in ipairs(list) do
        local name = quran.surahName and quran:surahName(m.surah) or tostring(m.surah)
        table.insert(items, {
            text = string.format("%s %d:%d", name, m.surah, m.ayah),
            mandatory = string.format("%d%%", m.score or 0),
            callback = function()
                ayahDialog(browser, m.surah, m.ayah,
                    string.format(_("similarity %d%% · coverage %d%%"),
                        m.score or 0, m.coverage or 0))
            end,
        })
    end
    browser:navigateForward(string.format("%s %d:%d", _("Similar to"), surah, ayah), items)
end

function M.showThemesFor(browser, surah, ayah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local list = M.themesFor(conn, surah, ayah)
    if #list == 0 then
        notifyWarn(_("No theme recorded here."))
        return
    end
    M.showThemeItems(browser, list,
        _("Themes") .. string.format(" %d:%d", surah, ayah), { flow = true })
end

function M.showThemeItems(browser, list, title, opts)
    local items = {}
    -- Themes-as-flow entry (owner 2026-07-12): the same themes readable
    -- as ONE continuous document instead of tap-per-theme
    if opts and opts.flow and #list > 0 then
        table.insert(items, {
            text = _("Read as one page") .. " \226\134\146",
            separator = true,
            callback = function() M.showThemesFlow(browser, list, title) end,
        })
    end
    for _i, t in ipairs(list) do
        local theme = t
        local range = t.ayah_from == t.ayah_to
            and tostring(t.ayah_from)
            or (t.ayah_from .. "–" .. t.ayah_to)
        table.insert(items, {
            text = t.theme,
            mandatory = t.surah .. ":" .. range,
            callback = function() M.showTheme(browser, theme) end,
        })
    end
    browser:navigateForward(title, items)
end

--- Render the themes flow (pure; tested): each theme a bolded
-- "S:from–to · title" heading, followed — when a translation fetch is
-- available (quran_text package) — by that range's translation, one
-- numbered paragraph per ayah. The koassistant "argument development"
-- idiom: the surah's thematic progression read scrolled, not tapped.
-- Without the package it degrades to a headings-only outline.
function M.renderThemesFlow(title, list, fetch_translation)
    local parts = { PTF_B .. title .. " (" .. #list .. ")" .. PTF_E }
    for _i, t in ipairs(list) do
        local range = t.ayah_from == t.ayah_to
            and tostring(t.ayah_from)
            or (t.ayah_from .. "\226\128\147" .. t.ayah_to)
        local sect = { PTF_B .. t.surah .. ":" .. range .. " \194\183 "
            .. t.theme .. PTF_E }
        if fetch_translation then
            for a = t.ayah_from, t.ayah_to do
                local tr = fetch_translation(t.surah, a)
                if tr then
                    table.insert(sect, a .. ". " .. tr)
                end
            end
        end
        table.insert(parts, table.concat(sect, "\n"))
    end
    return PTF_HEADER .. table.concat(parts, "\n\n")
end

--- Open a theme list as one continuous Reader document (design D2: the
-- shared Reader is the surface for sustained reading; design D9: the
-- browser beneath does not move).
function M.showThemesFlow(browser, list, title)
    local quran = browser.quran
    local reader = quran._readerModule and quran:_readerModule()
    if not (reader and reader.show) then return end
    local fetch
    local qt = quran._textModule and quran:_textModule()
    local tconn = qt and qt.ensureDb and qt.ensureDb(quran)
    if tconn then
        fetch = function(s, a)
            local rows = qt.translations(tconn, s, a)
            return rows and rows[1] and rows[1].text
        end
    end
    reader.show{
        title = title,
        text = M.renderThemesFlow(title, list, fetch),
    }
end

function M.showThemesBrowse(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local quran = browser.quran
    local items = {}
    for s = 1, 114 do
        local surah = s
        local name = quran.surahName and quran:surahName(s) or ("Surah " .. s)
        table.insert(items, {
            text = string.format("%d. %s", s, name),
            callback = function()
                local list = M.themesBySurah(conn, surah)
                if #list == 0 then
                    notifyWarn(_("No themes recorded for this surah."))
                    return
                end
                M.showThemeItems(browser, list, _("Themes") .. " · " .. name,
                    { flow = true })
            end,
        })
    end
    browser:navigateForward(_("Themes"), items)
end

--- Theme screen (connections-first entity screen, owner 2026-07-12):
-- the passage's actions, the topics attached inside its range (the
-- shipped-data tier of the connections direction), then the ayahs.
-- t = a theme row { theme, surah, ayah_from, ayah_to }.
function M.showTheme(browser, t)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local quran = browser.quran
    local range = t.ayah_from == t.ayah_to and tostring(t.ayah_from)
        or (t.ayah_from .. "\226\128\147" .. t.ayah_to)
    local title = t.surah .. ":" .. range .. " \194\183 " .. t.theme
    local items = {}
    table.insert(items, {
        text = _("Read this passage"),
        callback = function() M.showThemesFlow(browser, { t }, title) end,
    })
    table.insert(items, {
        text = _("Go to this passage in the book"),
        separator = true,
        callback = function()
            -- FIRST covering book ayah (split-aware), like the UAP's Go-to
            local book_a = t.ayah_from > 1
                and (quran._hafsToWarshStart
                    and quran:_hafsToWarshStart(t.surah, t.ayah_from)
                    or quran:_hafsToWarsh(t.surah, t.ayah_from))
                or t.ayah_from
            browser:gotoAyah(t.surah, book_a)
        end,
    })
    local topics = M.themeTopics(conn, t.surah, t.ayah_from, t.ayah_to)
    for _i, tp in ipairs(topics) do
        local tid = tp.topic_id
        table.insert(items, {
            text = "\226\137\136 " .. tp.name,
            mandatory = topicCounts(tp),
            callback = function() M.showTopic(browser, tid) end,
        })
    end
    if #topics > 0 then items[#items].separator = true end
    for a = t.ayah_from, t.ayah_to do
        local aa = a
        local name = quran.surahName and quran:surahName(t.surah)
            or tostring(t.surah)
        table.insert(items, {
            text = string.format("%s %d:%d", name, t.surah, aa),
            callback = function()
                ayahDialog(browser, t.surah, aa, t.theme)
            end,
        })
    end
    browser:navigateForward(title, items)
end

function M.showTopic(browser, topic_id)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local t = M.topic(conn, topic_id)
    if not t then
        notifyWarn(_("Topic not found."))
        return
    end
    local items = {}
    if (t.description and t.description ~= "") or (t.wiki_link and t.wiki_link ~= "") then
        table.insert(items, {
            text = _("About") .. ": " .. t.name,
            callback = function()
                local UIManager = require("ui/uimanager")
                local TextViewer = require("ui/widget/textviewer")
                local Device = require("device")
                UIManager:show(TextViewer:new{
                    title = t.name,
                    text = M.renderTopicText(t),
                    width = Device.screen:getWidth(),
                    height = Device.screen:getHeight(),
                    justified = false,
                })
            end,
        })
    end
    -- Connections (dynamic-xray linked-items idiom): up the tree, down
    -- it, and QUL's sideways links — each row browses in, ← backs out
    for _i, p in ipairs(M.topicParents(conn, topic_id)) do
        local pid = p.topic_id
        table.insert(items, {
            text = "↑ " .. p.name,
            mandatory = topicCounts(p),
            callback = function() M.showTopic(browser, pid) end,
        })
    end
    for _i, c in ipairs(M.topicChildren(conn, topic_id)) do
        local cid = c.topic_id
        table.insert(items, {
            text = "▸ " .. c.name,
            mandatory = topicCounts(c),
            callback = function() M.showTopic(browser, cid) end,
        })
    end
    for _i, rt in ipairs(M.relatedTopics(conn, t)) do
        local rid = rt.topic_id
        table.insert(items, {
            text = "≈ " .. rt.name,
            mandatory = topicCounts(rt),
            callback = function() M.showTopic(browser, rid) end,
        })
    end
    if #items > 0 then items[#items].separator = true end
    local quran = browser.quran
    for _i, sa in ipairs(M.topicAyahs(conn, topic_id)) do
        local name = quran.surahName and quran:surahName(sa.surah) or tostring(sa.surah)
        table.insert(items, {
            text = string.format("%s %d:%d", name, sa.surah, sa.ayah),
            callback = function()
                ayahDialog(browser, sa.surah, sa.ayah, t.name)
            end,
        })
    end
    if #items == 0 then
        notifyWarn(_("Nothing recorded under this topic."))
        return
    end
    browser:navigateForward(t.name, items)
end

function M.showTopicsFor(browser, surah, ayah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local list = M.topicsFor(conn, surah, ayah)
    if #list == 0 then
        notifyWarn(_("No topics recorded here."))
        return
    end
    local items = {}
    for _i, t in ipairs(list) do
        local tid = t.topic_id
        local text = t.name
        if t.arabic_name and t.arabic_name ~= "" then
            text = text .. "  " .. t.arabic_name
        end
        table.insert(items, {
            text = text,
            callback = function() M.showTopic(browser, tid) end,
        })
    end
    browser:navigateForward(_("Topics") .. string.format(" %d:%d", surah, ayah), items)
end

function M.showAllTopics(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local items = {}
    for _i, t in ipairs(M.allTopics(conn)) do
        table.insert(items, topicItem(browser, t))
    end
    browser:navigateForward(_("All topics"), items)
end

function M.showTopicSearch(browser, q)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local list = M.searchTopics(conn, q, 100)
    if #list == 0 then
        notifyWarn(_("No topics match:") .. " " .. q)
        return
    end
    local items = {}
    for _i, t in ipairs(list) do
        table.insert(items, topicItem(browser, t))
    end
    browser:navigateForward(_("Topics") .. ": " .. q, items)
end

-- Topics landing (design D5): search-first + flat A–Z + the counted
-- thematic tree (which alone read as "almost no topics")
function M.showTopicsRoot(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local items = {
        {
            text = _("Search topics"),
            callback = function()
                browser:promptSearch(_("Search topics"), function(q)
                    M.showTopicSearch(browser, q)
                end)
            end,
        },
        {
            text = _("All topics (A–Z)"),
            mandatory = tostring(M.topicCount(conn)),
            separator = true,
            callback = function() M.showAllTopics(browser) end,
        },
    }
    for _i, t in ipairs(M.topicRoots(conn)) do
        table.insert(items, topicItem(browser, t))
    end
    if #items == 2 then
        notifyWarn(_("No topic tree in the data package."))
        return
    end
    browser:navigateForward(_("Topics"), items)
end

function M.showMutashabihat(browser, surah, ayah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local groups = M.phrasesFor(conn, surah, ayah)
    if #groups == 0 then
        notifyWarn(_("No repeated phrases recorded here."))
        return
    end
    local quran = browser.quran
    local items = {}
    for _i, g in ipairs(groups) do
        local gid = g.group_id
        table.insert(items, {
            text = string.format("%s ×%d (%d %s)",
                _("Phrase"), g.count or 0, g.n_ayahs or 0, _("ayahs")),
            callback = function()
                local occ = M.phraseOccurrences(conn, gid)
                local oitems = {}
                for _j, o in ipairs(occ) do
                    local name = quran.surahName and quran:surahName(o.surah)
                        or tostring(o.surah)
                    local mand = (o.w_from and o.w_to)
                        and (_("words") .. " " .. o.w_from .. "–" .. o.w_to) or ""
                    table.insert(oitems, {
                        text = string.format("%s %d:%d", name, o.surah, o.ayah),
                        mandatory = mand,
                        callback = function()
                            ayahDialog(browser, o.surah, o.ayah)
                        end,
                    })
                end
                browser:navigateForward(_("Occurrences"), oitems)
            end,
        })
    end
    browser:navigateForward(
        string.format("%s %d:%d", _("Repeated phrases"), surah, ayah), items)
end

return M
