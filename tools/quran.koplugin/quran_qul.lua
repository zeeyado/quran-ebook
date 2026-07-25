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
        return nil, _("QUL data package not installed — get it from Library & assets in the Quran Explorer.")
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

function M.themeCount(conn)
    local r = rows(conn, "SELECT count(*) FROM theme")[1]
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

-- F28 (owner 2026-07-18): the topic/theme sub-searches were raw LIKE
-- over the stored strings — Arabic queries only hit the exact stored
-- form (harakat and hamza variants missed). Fold BOTH sides with
-- quran_norm.norm — the ONE normalizer (Python↔Lua lockstep) — and
-- match Lua-side: the tables are small (≈2.5k topics / 1k themes,
-- search is submit-based, and the A–Z screen already full-scans with
-- counts). norm lowercases ASCII too, so English matching stays
-- LIKE-equivalent. No quran handle reaches these conn-keyed helpers,
-- so quran_norm is self-loaded from this file's own directory.
local _norm_mod
local function searchFold(s)
    if _norm_mod == nil then
        local dir = debug.getinfo(1, "S").source
            :match("^@(.*)[/\\][^/\\]+$")
        local ok, mod = pcall(dofile, (dir or "") .. "/quran_norm.lua")
        _norm_mod = (ok and type(mod) == "table") and mod or false
        if not _norm_mod then
            logger.info("quran.koplugin: quran_norm load failed for search fold:", mod)
        end
    end
    if _norm_mod and _norm_mod.norm then return _norm_mod.norm(s) end
    return type(s) == "string" and s:lower() or ""
end

--- Substring search over topic names (English + Arabic), both sides
-- normalized (no FTS in the qul package by design).
function M.searchTopics(conn, q, limit)
    local nq = searchFold(q)
    if nq == "" then return {} end
    limit = limit or 50
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name, arabic_name, ]] .. TOPIC_COUNTS_SQL .. [[
        FROM topic ORDER BY name]])) do
        local name, ar = r[2], r[3]
        if searchFold(name):find(nq, 1, true)
                or (ar and searchFold(ar):find(nq, 1, true)) then
            table.insert(out, { topic_id = tonumber(r[1]), name = name,
                arabic_name = ar, n_children = tonumber(r[4]),
                n_ayahs = tonumber(r[5]) })
            if #out >= limit then break end
        end
    end
    return out
end

--- Substring search over theme texts, both sides normalized.
function M.searchThemes(conn, q, limit)
    local nq = searchFold(q)
    if nq == "" then return {} end
    limit = limit or 20
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT theme, surah, ayah_from, ayah_to FROM theme
        ORDER BY surah, ayah_from]])) do
        if searchFold(r[1]):find(nq, 1, true) then
            table.insert(out, { theme = r[1], surah = tonumber(r[2]),
                ayah_from = tonumber(r[3]), ayah_to = tonumber(r[4]) })
            if #out >= limit then break end
        end
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

--- The similar-ayah strength floor (owner 2026-07-16/17: the data is
-- QUL's matching-ayah WORDING dataset with a score — weak word-overlap
-- pairs like 79:19↔79:44 at score 60 read as noise). "Strict" = 80.
function M.similarMinScore(quran)
    return (quran and quran.settings
        and quran.settings:readSetting("similar_min_score", 80)) or 80
end

function M.similarFor(conn, surah, ayah, min_score)
    -- query BOTH sides of a pair, so an m_-side ayah (e.g. 79:19) shows
    -- its counterpart too (owner repro 2026-07-17: marked as similar,
    -- browser showed nothing). Some pairs exist in both directions with
    -- ASYMMETRIC scores — dedupe keeping the higher-scored row (the
    -- list is score-ordered, so first wins).
    min_score = min_score or 0
    local out = {}
    local seen = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT m_surah, m_ayah, score, coverage FROM similar
        WHERE surah = ?1 AND ayah = ?2 AND score >= ?3
        UNION
        SELECT surah, ayah, score, coverage FROM similar
        WHERE m_surah = ?1 AND m_ayah = ?2 AND score >= ?3
        ORDER BY score DESC]], { surah, ayah, min_score })) do
        local s2, a2 = tonumber(r[1]), tonumber(r[2])
        local k = s2 .. ":" .. a2
        if not seen[k] then
            seen[k] = true
            table.insert(out, { surah = s2, ayah = a2,
                score = tonumber(r[3]), coverage = tonumber(r[4]) })
        end
    end
    return out
end

function M.phrasesFor(conn, surah, ayah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT DISTINCT pg.group_id, pg.count, pg.ayahs,
            pg.src_surah, pg.src_ayah, pg.src_from, pg.src_to
        FROM phrase_occ po
        JOIN phrase_group pg ON pg.group_id = po.group_id
        WHERE po.surah = ? AND po.ayah = ? ORDER BY pg.count DESC]], { surah, ayah })) do
        table.insert(out, { group_id = tonumber(r[1]), count = tonumber(r[2]),
            n_ayahs = tonumber(r[3]),
            src_surah = tonumber(r[4]), src_ayah = tonumber(r[5]),
            src_from = tonumber(r[6]), src_to = tonumber(r[7]) })
    end
    return out
end

--- The phrase itself, extracted from the Hafs text by the group's
-- source word positions (R3-F22, owner batch 4: "see the phrase
-- immediately in the browser"). Pure word-slice: the QUL positions are
-- 1-based inclusive over whitespace-split words (verified against
-- 2:255 w14–19 and 2:29 w5–7). Returns nil without the text package.
function M.phraseText(quran, g)
    if not (g and g.src_surah and g.src_from and g.src_to) then return end
    local qt = quran._textModule and quran:_textModule()
    local tconn = qt and qt.ensureDb and qt.ensureDb(quran)
    local row = tconn and qt.ayah
        and qt.ayah(tconn, "hafs", g.src_surah, g.src_ayah)
    local txt = row and row.text
    if not txt then return end
    local words = {}
    for w in txt:gmatch("%S+") do table.insert(words, w) end
    if g.src_to > #words then return end
    return table.concat(words, " ", g.src_from, g.src_to)
end

--- Pure: 1-based inclusive word slice over the whitespace-split word
-- axis (the QUL position convention — see phraseText). nil when the
-- range falls outside the text.
function M.sliceWords(text, from, to)
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    if not (from and to) or from < 1 or to > #words or from > to then
        return nil
    end
    return table.concat(words, " ", from, to)
end

--- Pure: mark 1-based [from,to] word runs with «…» — the shared-wording
-- inline highlight (D-R3-14 display half; TextViewer has no rich text,
-- so the marks ARE the highlight). Out-of-range runs are skipped; the
-- text is otherwise unchanged.
function M.markWords(text, runs)
    if not (runs and #runs > 0) then return text end
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    for _i, r in ipairs(runs) do
        local a, b = r[1], r[2]
        if a and b and a >= 1 and b <= #words and a <= b then
            words[a] = "«" .. words[a]
            words[b] = words[b] .. "»"
        end
    end
    return table.concat(words, " ")
end

--- Pure: a windowed extract around [from,to] — pad words of context
-- each side, ellipses where trimmed, the run marked «…». Shows a
-- phrase IN its ayah without pulling in the whole ayah (2:255-sized
-- rows would drown the list).
function M.contextWindow(text, from, to, pad)
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    if not (from and to) or from < 1 or to > #words or from > to then
        return nil
    end
    pad = pad or 3
    local a = math.max(1, from - pad)
    local b = math.min(#words, to + pad)
    local out = {}
    if a > 1 then out[#out + 1] = "…" end
    for i = a, b do
        local w = words[i]
        if i == from then w = "«" .. w end
        if i == to then w = w .. "»" end
        out[#out + 1] = w
    end
    if b < #words then out[#out + 1] = "…" end
    return table.concat(out, " ")
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

-- ---------------------------------------------------------------------
-- Surah-scoped connection queries (the surah HUB — owner 2026-07-17
-- batch 5: every layer reachable from a surah, "high availability")
-- ---------------------------------------------------------------------

--- Topics attached anywhere in this surah, A–Z with counts.
function M.topicsForSurah(conn, surah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name, arabic_name, ]] .. TOPIC_COUNTS_SQL .. [[
        FROM topic WHERE topic_id IN
            (SELECT DISTINCT topic_id FROM topic_ayah WHERE surah = ?)
        ORDER BY name]], { surah })) do
        table.insert(out, { topic_id = tonumber(r[1]), name = r[2],
            arabic_name = r[3], n_ayahs = tonumber(r[4]) })
    end
    return out
end

function M.topicsForSurahCount(conn, surah)
    local r = rows(conn,
        "SELECT count(DISTINCT topic_id) FROM topic_ayah WHERE surah = ?",
        { surah })[1]
    return r and tonumber(r[1]) or 0
end

--- Ayahs of this surah that carry similar-ayah pairs (either side,
-- floor applied), with pair counts.
function M.similarBySurah(conn, surah, min_score)
    min_score = min_score or 0
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT ayah, count(*) FROM (
            SELECT ayah FROM similar
            WHERE surah = ?1 AND score >= ?2
            UNION ALL
            SELECT m_ayah AS ayah FROM similar
            WHERE m_surah = ?1 AND m_ayah IS NOT NULL AND score >= ?2
        ) GROUP BY ayah ORDER BY ayah]], { surah, min_score })) do
        table.insert(out, { ayah = tonumber(r[1]), n = tonumber(r[2]) })
    end
    return out
end

--- Phrase groups with an occurrence in this surah (count-ordered).
function M.phrasesInSurah(conn, surah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT DISTINCT pg.group_id, pg.count, pg.ayahs,
            pg.src_surah, pg.src_ayah, pg.src_from, pg.src_to
        FROM phrase_occ po
        JOIN phrase_group pg ON pg.group_id = po.group_id
        WHERE po.surah = ? ORDER BY pg.count DESC]], { surah })) do
        table.insert(out, { group_id = tonumber(r[1]), count = tonumber(r[2]),
            n_ayahs = tonumber(r[3]),
            src_surah = tonumber(r[4]), src_ayah = tonumber(r[5]),
            src_from = tonumber(r[6]), src_to = tonumber(r[7]) })
    end
    return out
end

-- Per-ayah connection counts for the position screen (one cheap query).
function M.countsFor(conn, surah, ayah, min_score)
    min_score = min_score or 0
    local r = rows(conn, [[
        SELECT
          (SELECT count(*) FROM (
            SELECT m_surah, m_ayah FROM similar
            WHERE surah = ?1 AND ayah = ?2 AND score >= ?3
            UNION
            SELECT surah, ayah FROM similar
            WHERE m_surah = ?1 AND m_ayah = ?2 AND score >= ?3)),
          (SELECT count(*) FROM theme WHERE surah = ?1 AND ?2 BETWEEN ayah_from AND ayah_to),
          (SELECT count(*) FROM topic_ayah WHERE surah = ?1 AND ayah = ?2),
          (SELECT count(DISTINCT group_id) FROM phrase_occ WHERE surah = ?1 AND ayah = ?2)
    ]], { surah, ayah, min_score })[1]
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

-- Text-package accessors shared by the dense similar/phrase surfaces
-- (owner 2026-07-18 part 2). All nil-safe without the package.
local function textConn(quran)
    local qt = quran._textModule and quran:_textModule()
    local tconn = qt and qt.ensureDb and qt.ensureDb(quran)
    return qt, tconn
end

local function ayahArabic(qt, tconn, s, a)
    local row = tconn and qt.ayah and qt.ayah(tconn, "hafs", s, a)
    return row and row.text or nil
end

--- FIRST translation of the user's roster for S:A (enable/disable +
-- order settings); clipped at a word boundary when maxlen is given,
-- full text otherwise.
local function transPreview(quran, qt, tconn, s, a, maxlen)
    if not (qt and tconn) then return end
    local rows_t = qt.enabledTranslations
        and qt.enabledTranslations(quran, tconn, s, a)
        or (qt.translations and qt.translations(tconn, s, a))
    local t = rows_t and rows_t[1] and rows_t[1].text
    if not t then return end
    if maxlen and #t > maxlen then
        t = t:sub(1, maxlen - 2):gsub("%s+%S*$", "") .. "…"
    end
    return t
end

--- Pure: the dense pair-view spec (D-R4-6 — owner: "maximum info in an
-- organized way: the percent, a good view of the overlap, the
-- surah/ayah"). d = { kind = "wording"|"meaning", score,
--   a = { surah, ayah, name, text, translation }, b = { … },
--   a_runs/b_runs = 1-based word runs marking each side's shared
--   wording, a_cov/b_cov = % of that ayah's words matched, n_words,
--   common_roots }. Returns { title, text } for the Reader surface.
function M.similarPairSpec(d)
    local function locus(x)
        local n = (x.name and x.name ~= "") and (x.name .. " ") or ""
        return string.format("%s%d:%d", n, x.surah, x.ayah)
    end
    local meta
    if d.kind == "meaning" then
        meta = _("Related in meaning") .. " — QurSim"
            .. ((d.score or 1) >= 2 and (" · " .. _("strong")) or "")
        if d.common_roots and d.common_roots > 0 then
            meta = meta .. " · " .. d.common_roots .. " "
                .. _("shared roots")
        end
    elseif d.kind == "phrase" then
        -- mutashabihat comparison (owner 2026-07-18: occurrences
        -- should compare "more directly", like the similar pair view)
        meta = string.format("%s ×%d", _("Repeated phrase"), d.count or 0)
        if (d.a_runs and #d.a_runs > 0) or (d.b_runs and #d.b_runs > 0) then
            meta = meta .. "\n" .. _("The phrase is marked « »")
        end
    else
        -- "matched", not "shared": QUL's matcher tolerates inflection
        -- (1:6 ٱهۡدِنَا matches 37:118 وَهَدَيۡنَٰهُمَا) — the marks
        -- are near-verbatim runs, not byte-identical wording
        meta = string.format("%s — %d%%", _("Matched wording"), d.score or 0)
        if d.n_words and d.n_words > 0 then
            meta = meta .. string.format(" · %d %s", d.n_words,
                _("matched words"))
        end
        local cov = {}
        if d.a_cov then
            cov[#cov + 1] = string.format("%d%% %s %d:%d",
                d.a_cov, _("of"), d.a.surah, d.a.ayah)
        end
        if d.b_cov then
            cov[#cov + 1] = string.format("%d%% %s %d:%d",
                d.b_cov, _("of"), d.b.surah, d.b.ayah)
        end
        if #cov > 0 then
            meta = meta .. " (" .. table.concat(cov, " · ") .. ")"
        end
        if (d.a_runs and #d.a_runs > 0) or (d.b_runs and #d.b_runs > 0) then
            meta = meta .. "\n" .. _("Matched wording is marked « »")
        end
    end
    local function section(x, runs)
        local parts = { locus(x) }
        if x.text then parts[#parts + 1] = M.markWords(x.text, runs) end
        if x.translation then parts[#parts + 1] = x.translation end
        return table.concat(parts, "\n\n")
    end
    return {
        title = string.format("%s %d:%d ↔ %d:%d",
            d.kind == "phrase" and _("Repeated phrase") or _("Similar ayahs"),
            d.a.surah, d.a.ayah, d.b.surah, d.b.ayah),
        text = meta .. "\n\n" .. section(d.a, d.a_runs)
            .. "\n\n———\n\n" .. section(d.b, d.b_runs),
    }
end

--- The unified pair view (owner: Similar/phrases are browser-only
-- full-screen — both ayahs, Arabic AND translation, the % and the
-- overlap, on one screen). Reader surface over the browser; ◀ ▶ step
-- the origin's pair list; Open buttons land on either ayah page.
-- origin = { surah, ayah }; list[idx] carries kind/score/coverage/
-- common_roots from showSimilar's unified list.
function M.showSimilarPair(browser, origin, list, idx)
    local quran = browser.quran
    local m = list[idx]
    local reader = quran._readerModule and quran:_readerModule()
    if not (reader and reader.show) then
        ayahDialog(browser, m.surah, m.ayah)
        return
    end
    local qt, tconn = textConn(quran)
    local function disp(s)
        return (s and quran.displayArabic) and quran:displayArabic(s) or s
    end
    local cx = browser.connectionsModule and browser:connectionsModule()
    local okc, cconn = pcall(function()
        return cx and cx.ensureDb
            and (select(1, cx.ensureDb(quran))) or nil
    end)
    cconn = okc and cconn or nil
    local fwd, rev
    if m.kind ~= "meaning" and cconn and cx.phraseSpans then
        fwd = cx.phraseSpans(cconn, origin.surah, origin.ayah,
            m.surah, m.ayah)
        rev = cx.phraseSpans(cconn, m.surah, m.ayah,
            origin.surah, origin.ayah)
    end
    local function side(s, a)
        return {
            surah = s, ayah = a,
            name = quran.surahName and quran:surahName(s) or nil,
            text = qt and disp(ayahArabic(qt, tconn, s, a)) or nil,
            translation = qt and transPreview(quran, qt, tconn, s, a) or nil,
        }
    end
    local spec = M.similarPairSpec{
        kind = m.kind or "wording",
        score = m.score,
        common_roots = m.common_roots,
        a = side(origin.surah, origin.ayah),
        b = side(m.surah, m.ayah),
        a_runs = rev and rev.match_words or nil,
        b_runs = fwd and fwd.match_words or nil,
        a_cov = rev and rev.coverage or nil,
        b_cov = fwd and fwd.coverage or nil,
        n_words = (fwd and fwd.matched_words_count)
            or (rev and rev.matched_words_count) or nil,
    }
    reader.show{
        kind = "simpair",  -- one hop identity: ◀ ▶ stepping replaces
        title = spec.title,
        text = spec.text,
        content_rtl = true,
        back_label = "← " .. _("Similar ayahs"),
        prev = idx > 1 and function()
            M.showSimilarPair(browser, origin, list, idx - 1)
        end or nil,
        next = idx < #list and function()
            M.showSimilarPair(browser, origin, list, idx + 1)
        end or nil,
        extra_buttons = {
            {
                id = "qsp_open_a",
                text = string.format("%s %d:%d", _("Open"),
                    origin.surah, origin.ayah),
                callback = function()
                    browser:showAyahPage(origin.surah, origin.ayah)
                end,
            },
            {
                id = "qsp_open_b",
                text = string.format("%s %d:%d", _("Open"),
                    m.surah, m.ayah),
                callback = function()
                    browser:showAyahPage(m.surah, m.ayah)
                end,
            },
        },
    }
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

--- Mutashabihat pair view (owner 2026-07-18: phrase occurrences should
-- compare "more directly, like the similar ayah one" — not bare-jump
-- to the ayah page): a = the ANCHOR occurrence (the ayah the list was
-- reached from, else the group's source), b = the tapped occurrence;
-- the phrase «» marked in both, full translations, ◀ ▶ step the other
-- occurrences keeping the anchor fixed, Open buttons land the ayah
-- pages.
function M.showPhrasePair(browser, count, occ, a_idx, idx)
    local quran = browser.quran
    local b = occ[idx]
    local reader = quran._readerModule and quran:_readerModule()
    if not (reader and reader.show) then
        ayahDialog(browser, b.surah, b.ayah)
        return
    end
    local qt, tconn = textConn(quran)
    local function disp(s)
        return (s and quran.displayArabic) and quran:displayArabic(s) or s
    end
    local function side(o)
        return {
            surah = o.surah, ayah = o.ayah,
            name = quran.surahName and quran:surahName(o.surah) or nil,
            text = qt and disp(ayahArabic(qt, tconn, o.surah, o.ayah)) or nil,
            translation = qt
                and transPreview(quran, qt, tconn, o.surah, o.ayah) or nil,
        }
    end
    local function runs(o)
        return (o.w_from and o.w_to) and { { o.w_from, o.w_to } } or nil
    end
    local a = occ[a_idx]
    local spec = M.similarPairSpec{
        kind = "phrase", count = count,
        a = side(a), b = side(b),
        a_runs = runs(a), b_runs = runs(b),
    }
    local function step(dir)
        local j = idx + dir
        if j == a_idx then j = j + dir end
        if not occ[j] then return nil end
        return function()
            M.showPhrasePair(browser, count, occ, a_idx, j)
        end
    end
    reader.show{
        kind = "phrpair",  -- one hop identity: ◀ ▶ stepping replaces
        title = spec.title,
        text = spec.text,
        content_rtl = true,
        back_label = "← " .. _("Occurrences"),
        prev = step(-1),
        next = step(1),
        extra_buttons = {
            {
                id = "qpp_open_a",
                text = string.format("%s %d:%d", _("Open"),
                    a.surah, a.ayah),
                callback = function()
                    browser:showAyahPage(a.surah, a.ayah)
                end,
            },
            {
                id = "qpp_open_b",
                text = string.format("%s %d:%d", _("Open"),
                    b.surah, b.ayah),
                callback = function()
                    browser:showAyahPage(b.surah, b.ayah)
                end,
            },
        },
    }
end

--- Phrase-group row (R3-F22): the phrase itself (Hafs word-slice,
-- display-normalized) with ×count; opens the group's occurrence list —
-- each occurrence shown IN its ayah (context window, phrase marked
-- «…») with a translation preview (owner 2026-07-18 part 2: "all the
-- content in there"). Occurrence taps open the comparison pair view
-- (anchor ↔ tapped). origin (optional) = the ayah the caller's screen
-- is scoped to — it becomes the comparison anchor. Shared by the
-- per-ayah and per-surah (hub) phrase screens.
local function phraseGroupItem(browser, conn, g, origin)
    local quran = browser.quran
    local gid = g.group_id
    local ptext = M.phraseText(quran, g)
    local function disp(s)
        return (s and quran.displayArabic) and quran:displayArabic(s) or s
    end
    return {
        text = ptext and disp(ptext) or string.format("%s ×%d (%d %s)",
            _("Phrase"), g.count or 0, g.n_ayahs or 0, _("ayahs")),
        mandatory = ptext and ("×" .. (g.count or 0)) or nil,
        callback = function()
            local occ = M.phraseOccurrences(conn, gid)
            local qt, tconn = textConn(quran)
            -- the comparison anchor: the scoped ayah, else the source
            local function findOcc(s2, a2)
                for j, o in ipairs(occ) do
                    if o.surah == s2 and o.ayah == a2 then return j end
                end
            end
            local a_idx = (origin and findOcc(origin.surah, origin.ayah))
                or findOcc(g.src_surah, g.src_ayah) or 1
            local oitems = {}
            for _j, o in ipairs(occ) do
                local name = quran.surahName and quran:surahName(o.surah)
                    or tostring(o.surah)
                local ctx
                if qt and o.w_from and o.w_to then
                    local raw = ayahArabic(qt, tconn, o.surah, o.ayah)
                    ctx = raw
                        and disp(M.contextWindow(raw, o.w_from, o.w_to, 3))
                end
                local pv = qt and transPreview(quran, qt, tconn, o.surah, o.ayah, 70)
                local text = ctx
                    or string.format("%s %d:%d", name, o.surah, o.ayah)
                if pv then text = text .. " — " .. pv end
                local b_idx = _j
                table.insert(oitems, {
                    text = text,
                    mandatory = string.format("%d:%d", o.surah, o.ayah),
                    callback = function()
                        -- tapping the anchor itself compares it with
                        -- the first OTHER occurrence
                        local bi = b_idx
                        if bi == a_idx then bi = a_idx == 1 and 2 or 1 end
                        if occ[bi] then
                            M.showPhrasePair(browser, g.count or #occ,
                                occ, a_idx, bi)
                        else
                            ayahDialog(browser, o.surah, o.ayah)
                        end
                    end,
                })
            end
            browser:navigateForward(
                string.format("%s ×%d", ptext and disp(ptext)
                    or _("Occurrences"), g.count or #occ),
                oitems, nil, { multiline = true })
        end,
    }
end

function M.showSimilar(browser, surah, ayah)
    -- One "Similar ayahs" surface, two labeled layers (DA-5 honesty —
    -- never silently merged): QUL wording matches (this package) and
    -- QurSim semantic pairs (the connections package, Ibn Kathir
    -- citations). Either package alone still renders its layer.
    local conn = select(1, M.ensureDb(browser.quran))
    local list = conn and M.similarFor(conn, surah, ayah,
        M.similarMinScore(browser.quran)) or {}
    local cx = browser.connectionsModule and browser:connectionsModule()
    local okc, cconn = pcall(function()
        return cx and cx.ensureDb
            and (select(1, cx.ensureDb(browser.quran))) or nil
    end)
    cconn = okc and cconn or nil
    local sem = cconn and cx.diffPairs(
        cx.semanticFor(cconn, surah, ayah,
            cx.semanticFloor(browser.quran)), list) or {}
    if #list == 0 and #sem == 0 then
        notifyWarn(_("No similar ayahs recorded here."))
        return
    end
    local quran = browser.quran
    -- Dense rows (owner 2026-07-18 part 2 — "so many rounds without…
    -- a proper view of the overlap"): locus + % + the shared wording
    -- ITSELF (span-sliced from whichever direction the connections
    -- package stores) + translation preview, two-line rows; the tap
    -- lands on the unified PAIR view (M.showSimilarPair), not a bare
    -- ayah jump. D-R3-14's display half, closed.
    local qt, tconn = textConn(quran)
    local function disp(s)
        return (s and quran.displayArabic) and quran:displayArabic(s) or s
    end
    local plist = {}
    for _i, m in ipairs(list) do
        m.kind = "wording"
        table.insert(plist, m)
    end
    for _i, m in ipairs(sem) do
        m.kind = "meaning"
        table.insert(plist, m)
    end
    -- widest stored run, clipped to 8 words — the row-level glimpse
    local function snippet(m)
        if m.kind ~= "wording" or not (cconn and cx and cx.phraseSpans) then
            return
        end
        local fwd = cx.phraseSpans(cconn, surah, ayah, m.surah, m.ayah)
        local rev = cx.phraseSpans(cconn, m.surah, m.ayah, surah, ayah)
        local src, runs
        if fwd and fwd.match_words[1] then
            src = ayahArabic(qt, tconn, m.surah, m.ayah)
            runs = fwd.match_words
        elseif rev and rev.match_words[1] then
            src = ayahArabic(qt, tconn, surah, ayah)
            runs = rev.match_words
        end
        if not src then return end
        local best
        for _j, r in ipairs(runs) do
            if not best or (r[2] - r[1]) > (best[2] - best[1]) then
                best = r
            end
        end
        local to = math.min(best[2], best[1] + 7)
        local s = M.sliceWords(src, best[1], to)
        if not s then return end
        if to < best[2] then s = s .. " …" end
        return disp(s)
    end
    local items = {}
    for i, m in ipairs(plist) do
        local name = quran.surahName and quran:surahName(m.surah)
            or tostring(m.surah)
        local locus = string.format("%s %d:%d", name, m.surah, m.ayah)
        local ov = snippet(m)
        local pv = transPreview(quran, qt, tconn, m.surah, m.ayah, 90)
        local text = locus
        if ov then text = text .. "  «" .. ov .. "»" end
        if pv then text = text .. " — " .. pv end
        local mand
        if m.kind == "meaning" then
            -- the semantic layer: wording % gives way to a "meaning"
            -- tag (strong = QurSim degree 2)
            mand = (m.score or 1) >= 2
                and _("meaning · strong") or _("meaning")
        else
            mand = string.format("%d%%", m.score or 0)
        end
        local idx = i
        table.insert(items, {
            text = text,
            mandatory = mand,
            callback = function()
                M.showSimilarPair(browser,
                    { surah = surah, ayah = ayah }, plist, idx)
            end,
        })
    end
    -- the wording/meaning divider (pairs never repeat across layers)
    if #sem > 0 and #list > 0 then
        items[#list].separator = true
    end
    browser:navigateForward(string.format("%s %d:%d", _("Similar ayahs"), surah, ayah), items,
        nil, { multiline = true })
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
    -- D-R3-6: theme titles untruncated (two-line rows)
    browser:navigateForward(title, items, nil, { multiline = true })
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
            local rows = qt.enabledTranslations
                and qt.enabledTranslations(quran, tconn, s, a)
                or qt.translations(tconn, s, a)
            return rows and rows[1] and rows[1].text
        end
    end
    reader.show{
        kind = "themes",  -- hop-stack surface identity (D-R2-8)
        title = title,
        text = M.renderThemesFlow(title, list, fetch),
        -- D-R3-8 hybrid: browser-launched stack bottom = bare arrow
        back_label = browser.backLabel and browser:backLabel() or "←",
    }
end

--- All themes in ONE screen (D-R3-6 collapse, owner 2026-07-17: the
-- surah-list → theme-list hop is gone). Each surah with themes leads
-- with its bolded "Read as one page →" flow row, followed by that
-- surah's themes as untruncated two-line rows.
function M.showThemesBrowse(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local quran = browser.quran
    local items = {}
    for s = 1, 114 do
        local list = M.themesBySurah(conn, s)
        if #list > 0 then
            local name = quran.surahName and quran:surahName(s)
                or ("Surah " .. s)
            local flow_list = list
            table.insert(items, {
                text = string.format("%d. %s — %s \226\134\146", s, name,
                    _("Read as one page")),
                bold = true,
                callback = function()
                    M.showThemesFlow(browser, flow_list,
                        _("Themes") .. " \194\183 " .. name)
                end,
            })
            for _i, t in ipairs(list) do
                local theme = t
                local range = t.ayah_from == t.ayah_to
                    and tostring(t.ayah_from)
                    or (t.ayah_from .. "\226\128\147" .. t.ayah_to)
                table.insert(items, {
                    text = t.theme,
                    mandatory = t.surah .. ":" .. range,
                    callback = function() M.showTheme(browser, theme) end,
                })
            end
        end
    end
    browser:navigateForward(_("Themes"), items, nil, { multiline = true })
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
            -- D-R3-6: this row kind means "topic attached INSIDE this
            -- passage's range" — labeled distinctly from a topic
            -- screen's "Related:" rows (same ≈ glyph used to mean both)
            text = _("In this passage") .. ": " .. tp.name,
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
                -- R3-F12: the Reader idiom, not a raw TextViewer — the
                -- ← button names the screen beneath and the hop stack
                -- applies (the raw viewer was the "have to close the
                -- window to go back" outlier)
                local reader = browser.quran._readerModule
                    and browser.quran:_readerModule()
                if reader and reader.show then
                    reader.show{
                        kind = "topic",
                        title = t.name,
                        text = M.renderTopicText(t),
                        -- D-R3-8 hybrid: browser-launched stack bottom
                        -- shows the bare arrow (the browser is beneath)
                        back_label = browser.backLabel and browser:backLabel()
                            or "←",
                    }
                    return
                end
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
            -- D-R3-6: QUL sideways link, no range guarantee — "Related:"
            text = _("Related") .. ": " .. rt.name,
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
    local items = {}
    for _i, g in ipairs(groups) do
        table.insert(items,
            phraseGroupItem(browser, conn, g, { surah = surah, ayah = ayah }))
    end
    browser:navigateForward(
        string.format("%s %d:%d", _("Repeated phrases (mutashabihat)"),
            surah, ayah), items,
        nil, { multiline = true })
end

-- ---------------------------------------------------------------------
-- Surah HUB screens (owner 2026-07-17 batch 5): the surah page links
-- every layer — themes, topics, similar ayahs, repeated phrases —
-- scoped to that surah.
-- ---------------------------------------------------------------------

function M.showTopicsForSurah(browser, surah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local list = M.topicsForSurah(conn, surah)
    if #list == 0 then
        notifyWarn(_("No topics recorded in this surah."))
        return
    end
    local items = {}
    for _i, t in ipairs(list) do
        table.insert(items, topicItem(browser, t))
    end
    local name = browser.quran.surahName
        and browser.quran:surahName(surah) or tostring(surah)
    browser:navigateForward(_("Topics") .. " \194\183 " .. name, items)
end

function M.showSimilarBySurah(browser, surah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local quran = browser.quran
    local list = M.similarBySurah(conn, surah, M.similarMinScore(quran))
    if #list == 0 then
        notifyWarn(_("No similar ayahs recorded in this surah."))
        return
    end
    local name = quran.surahName and quran:surahName(surah)
        or tostring(surah)
    local items = {}
    for _i, e in ipairs(list) do
        local a = e.ayah
        table.insert(items, {
            text = string.format("%s %d:%d", name, surah, a),
            mandatory = tostring(e.n),
            callback = function() M.showSimilar(browser, surah, a) end,
        })
    end
    browser:navigateForward(_("Similar ayahs") .. " \194\183 " .. name, items)
end

function M.showPhrasesInSurah(browser, surah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local groups = M.phrasesInSurah(conn, surah)
    if #groups == 0 then
        notifyWarn(_("No repeated phrases recorded in this surah."))
        return
    end
    local items = {}
    for _i, g in ipairs(groups) do
        table.insert(items, phraseGroupItem(browser, conn, g))
    end
    local name = browser.quran.surahName
        and browser.quran:surahName(surah) or tostring(surah)
    browser:navigateForward(_("Repeated phrases (mutashabihat)") .. " \194\183 " .. name,
        items, nil, { multiline = true })
end

return M
