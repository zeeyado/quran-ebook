--[[--
quran_connections.lua — DA-7 connections: characters (figures), stories
(narrative units), and QurSim semantic similarity.

Data: connections-vN.sqlite (explorer-side kb/export/connections_extract.py;
H3 ask 2026-07-18), installed to <koreader>/data/quran/ by the asset
manager ("quran_connections" data package) or dropped next to the plugin
for development.

Keys are spine-stable: ayah_key = surah*1000 + ayah, word_id =
surah*1e6 + ayah*1e3 + pos (all Hafs, invariant D8) — no paired-build
requirement with any other package. All roster/unit rows are
research-candidate data (explorer A2 posture: label, don't filter) —
the entity About screens carry the label; lists stay clean.

Semantic similarity is DIRECTED (out-edge = the target is cited under
this ayah's tafsir in Ibn Kathir) and pre-filtered to score >= 1
(degree-0 rows are negative examples and never shipped). The strength
floor rides the existing similar-ayah setting: strict (default) shows
score 2 only, "all" shows 1–2. GPL-3.0.
]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

M.SCHEMA_VERSION = "1"

-- ---------------------------------------------------------------------
-- Pure helpers (unit-tested)
-- ---------------------------------------------------------------------

function M.keyToSA(key)
    if not key then return end
    local k = tonumber(key)
    if not k then return end
    return math.floor(k / 1000), k % 1000
end

-- Story-cycle display names (keys are the extract's slug vocabulary;
-- unknown keys degrade to a title-cased slug so a data update cannot
-- produce blank rows).
local STORY_LABELS = {
    ["adam-iblis"] = _("Adam & Iblis"),
    ["talut-jalut"] = _("Talut & Jalut"),
    ["ibrahim-cycle"] = _("Ibrahim"),
    ["maryam-cycle"] = _("Maryam"),
    ["banu-adam"] = _("The Two Sons of Adam"),
    ["nuh-flood"] = _("Nuh & the Flood"),
    ["yusuf"] = _("Yusuf"),
    ["kahf"] = _("Stories of Al-Kahf"),
    ["musa-early"] = _("Musa — early life"),
    ["sulayman-bilqis"] = _("Sulayman & Bilqis"),
    ["luqman-wisdom"] = _("Luqman"),
}

function M.storyLabel(key)
    if STORY_LABELS[key] then return STORY_LABELS[key] end
    local label = tostring(key or ""):gsub("-", " "):gsub("(%a)([%w]*)",
        function(a, b) return a:upper() .. b end)
    return label
end

--- Order units for display: top-level units by seq, each followed by
-- its children (by seq). Children carry .depth = 1 for indenting.
function M.sortUnits(units)
    local top, kids = {}, {}
    for _i, u in ipairs(units) do
        if u.parent_id then
            kids[u.parent_id] = kids[u.parent_id] or {}
            table.insert(kids[u.parent_id], u)
        else
            table.insert(top, u)
        end
    end
    local by_seq = function(a, b) return (a.seq or 0) < (b.seq or 0) end
    table.sort(top, by_seq)
    local out = {}
    for _i, u in ipairs(top) do
        u.depth = 0
        table.insert(out, u)
        local ch = kids[u.id]
        if ch then
            table.sort(ch, by_seq)
            for _j, c in ipairs(ch) do
                c.depth = 1
                table.insert(out, c)
            end
        end
    end
    -- orphans (parent filtered out of the input list) keep their place
    for pid, ch in pairs(kids) do
        local seen = false
        for _i, u in ipairs(out) do
            if u.id == pid then seen = true break end
        end
        if not seen then
            table.sort(ch, by_seq)
            for _j, c in ipairs(ch) do
                c.depth = 0
                table.insert(out, c)
            end
        end
    end
    return out
end

--- "S:from–to" (single-ayah spans collapse to "S:a").
function M.spanLabel(from_key, to_key)
    local s, a1 = M.keyToSA(from_key)
    local _s2, a2 = M.keyToSA(to_key)
    if not s then return "" end
    if not a2 or a2 == a1 then return s .. ":" .. a1 end
    return s .. ":" .. a1 .. "\226\128\147" .. a2
end

--- Parse a figure's quran_refs JSON ('["18:83","2:30-33"]') into
-- { {surah, a1, a2}, ... }. Refs are the CURATED anchor channel:
-- unnamed figures (imra'at al-'Aziz) and compound names QAC carries
-- no PN lemma for (Dhu al-Qarnayn) have refs INSTEAD of occurrences.
function M.parseRefs(s)
    local out = {}
    for ref in tostring(s or ""):gmatch('"([^"]+)"') do
        local su, a1, a2 = ref:match("^(%d+):(%d+)%-(%d+)$")
        if not su then
            su, a1 = ref:match("^(%d+):(%d+)$")
            a2 = a1
        end
        if su then
            table.insert(out, { tonumber(su), tonumber(a1), tonumber(a2) })
        end
    end
    return out
end

--- Semantic rows NOT already covered by a wording-match list (the two
-- layers share pairs like 2:255↔3:2; the union is shown once, sections
-- labeled — never silently merged).
function M.diffPairs(sem_list, wording_list)
    local seen = {}
    for _i, p in ipairs(wording_list or {}) do
        seen[p.surah .. ":" .. p.ayah] = true
    end
    local out = {}
    for _i, p in ipairs(sem_list or {}) do
        if not seen[p.surah .. ":" .. p.ayah] then
            table.insert(out, p)
        end
    end
    return out
end

--- Map the similar-ayah strength setting (QUL wording scores, floor 80
-- = strict) onto the semantic score axis: strict → strong citations
-- only (score 2), anything looser → all shipped pairs (1–2).
function M.semanticFloor(quran)
    local min = (quran and quran.settings
        and quran.settings:readSetting("similar_min_score", 80)) or 80
    return min >= 80 and 2 or 1
end

-- Viewer text (PTF bold segments, the Lane/topic idiom)
local PTF_HEADER = "\u{FFF1}"
local PTF_B = "\u{FFF2}"
local PTF_E = "\u{FFF3}"

local TYPE_LABELS = {
    prophet = _("prophet"), person = _("person"), angel = _("angel"),
    devil = _("devil"), group = _("group"),
}

function M.renderFigureText(f)
    local parts = {}
    local meta_bits = {}
    if f.name_ar and f.name_ar ~= "" then
        table.insert(meta_bits, f.name_ar)
    end
    if f.translit and f.translit ~= "" and f.translit ~= f.name_en then
        table.insert(meta_bits, f.translit)
    end
    if f.figure_type then
        table.insert(meta_bits, TYPE_LABELS[f.figure_type] or f.figure_type)
    end
    if #meta_bits > 0 then
        table.insert(parts, PTF_B .. table.concat(meta_bits, " · ") .. PTF_E)
    end
    if f.named_in_quran == 0 then
        local line = _("Not named in the Quran")
        if f.quranic_name and f.quranic_name ~= "" then
            line = line .. " — " .. _("Quranic designation:") .. " "
                .. f.quranic_name
        end
        if f.tradition_name and f.tradition_name ~= "" then
            line = line .. "\n" .. _("Known in tradition as:") .. " "
                .. f.tradition_name
        end
        table.insert(parts, line)
    elseif f.quranic_name and f.quranic_name ~= ""
            and f.quranic_name ~= f.name_ar then
        table.insert(parts, _("Quranic name:") .. " " .. f.quranic_name)
    end
    if f.summary and f.summary ~= "" then
        table.insert(parts, f.summary)
    end
    -- A2 label-don't-filter: the roster is research-candidate data;
    -- the label lives here (entity level), not on every list row
    table.insert(parts, PTF_B .. _("Data status:") .. PTF_E .. " "
        .. _("research candidate (curated roster, unverified)"))
    return PTF_HEADER .. table.concat(parts, "\n\n")
end

function M.renderUnitText(u)
    local parts = {}
    table.insert(parts, PTF_B .. M.spanLabel(u.from_ayah_key, u.to_ayah_key)
        .. " · " .. M.storyLabel(u.story) .. PTF_E)
    if u.summary and u.summary ~= "" then
        table.insert(parts, u.summary)
    end
    if u.boundary_basis and u.boundary_basis ~= "" then
        table.insert(parts, PTF_B .. _("Span basis:") .. PTF_E .. " "
            .. u.boundary_basis)
    end
    table.insert(parts, PTF_B .. _("Data status:") .. PTF_E .. " "
        .. _("research candidate (curated segmentation, unverified)"))
    return PTF_HEADER .. table.concat(parts, "\n\n")
end

-- ---------------------------------------------------------------------
-- Database access (same shape as quran_qul.lua)
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
                if entry:match("^connections%-v%d+%.sqlite$") then
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
        return nil, _("Could not open the connections database.")
    end
    local ver_ok, ver = pcall(function()
        local stmt = conn:prepare("SELECT value FROM meta WHERE key='schema_version'")
        local row = stmt:step()
        stmt:close()
        return row and tostring(row[1])
    end)
    if not ver_ok or ver ~= M.SCHEMA_VERSION then
        pcall(function() conn:close() end)
        return nil, _("Connections database has an unsupported format — update the plugin or the data package.")
    end
    M._conn = conn
    M._db_path = path
    logger.info("quran.koplugin: opened connections db", path)
    return conn
end

function M.ensureDb(quran)
    local path = M._db_path or M.findDb(quran)
    if not path then
        return nil, _("Connections data package not installed — get it from Library & assets in the Quran browser.")
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
        logger.info("quran.koplugin: connections query failed:", err)
    end
    return out
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

function M.figureCount(conn)
    local r = rows(conn, "SELECT count(*) FROM figure")[1]
    return r and tonumber(r[1]) or 0
end

function M.storyCount(conn)
    local r = rows(conn, "SELECT count(DISTINCT story) FROM narrative_unit")[1]
    return r and tonumber(r[1]) or 0
end

local FIGURE_COUNTS_SQL = [[
        (SELECT count(DISTINCT ayah_key) FROM figure_occurrence fo
         WHERE fo.figure_id = figure.id),
        (SELECT count(*) FROM narrative_figure nf
         WHERE nf.figure_id = figure.id)]]

--- Every figure, mention-frequency first (the root-explorer landing
-- principle), name second. n_ayahs = distinct ayahs with a name hit;
-- ref-anchored figures (no PN occurrences) count their curated refs.
function M.allFigures(conn)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT id, slug, name_en, name_ar, figure_type, named_in_quran,
               ]] .. FIGURE_COUNTS_SQL .. [[
        FROM figure ORDER BY 7 DESC, name_en]])) do
        table.insert(out, { id = tonumber(r[1]), slug = r[2], name_en = r[3],
            name_ar = r[4], figure_type = r[5],
            named_in_quran = tonumber(r[6]),
            n_ayahs = tonumber(r[7]), n_units = tonumber(r[8]) })
    end
    local ref_n = {}
    for _i, f in ipairs(M.refFigures(conn)) do
        local n = 0
        for _j, ref in ipairs(f.refs) do n = n + (ref[3] - ref[2] + 1) end
        ref_n[f.id] = n
    end
    for _i, f in ipairs(out) do
        if (f.n_ayahs or 0) == 0 and ref_n[f.id] then
            f.n_ayahs = ref_n[f.id]
            f.by_ref = true
        end
    end
    table.sort(out, function(a, b)
        if (a.n_ayahs or 0) ~= (b.n_ayahs or 0) then
            return (a.n_ayahs or 0) > (b.n_ayahs or 0)
        end
        return (a.name_en or "") < (b.name_en or "")
    end)
    return out
end

function M.figure(conn, id)
    local r = rows(conn, [[
        SELECT id, slug, name_en, name_ar, translit, figure_type,
               named_in_quran, quranic_name, tradition_name, quran_refs,
               aliases, summary, status, confidence,
               ]] .. FIGURE_COUNTS_SQL .. [[
        FROM figure WHERE id = ?]], { id })[1]
    if not r then return end
    return { id = tonumber(r[1]), slug = r[2], name_en = r[3], name_ar = r[4],
        translit = r[5], figure_type = r[6], named_in_quran = tonumber(r[7]),
        quranic_name = r[8], tradition_name = r[9], quran_refs = r[10],
        aliases = r[11], summary = r[12], status = r[13], confidence = r[14],
        n_ayahs = tonumber(r[15]), n_units = tonumber(r[16]) }
end

--- Ayahs where the figure is mentioned (mushaf order): name hits with
-- per-ayah counts, plus curated-ref ayahs (by_ref, no hit count).
function M.figureAyahs(conn, figure_id)
    local out, seen = {}, {}
    for _i, r in ipairs(rows(conn, [[
        SELECT ayah_key, count(*) FROM figure_occurrence
        WHERE figure_id = ? GROUP BY ayah_key ORDER BY ayah_key]],
        { figure_id })) do
        local s, a = M.keyToSA(r[1])
        seen[tonumber(r[1])] = true
        table.insert(out, { surah = s, ayah = a, n = tonumber(r[2]) })
    end
    for _i, f in ipairs(M.refFigures(conn)) do
        if f.id == figure_id then
            for _j, ref in ipairs(f.refs) do
                for a = ref[2], ref[3] do
                    local k = ref[1] * 1000 + a
                    if not seen[k] then
                        seen[k] = true
                        table.insert(out, { surah = ref[1], ayah = a,
                            n = 0, by_ref = true })
                    end
                end
            end
        end
    end
    table.sort(out, function(x, y)
        return x.surah * 1000 + x.ayah < y.surah * 1000 + y.ayah
    end)
    return out
end

--- Story units featuring the figure (with its role), story order.
function M.figureUnits(conn, figure_id)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT u.id, u.slug, u.title, u.story, u.seq, u.parent_id,
               u.from_ayah_key, u.to_ayah_key, nf.role
        FROM narrative_figure nf
        JOIN narrative_unit u ON u.id = nf.unit_id
        WHERE nf.figure_id = ?
        ORDER BY u.from_ayah_key]], { figure_id })) do
        table.insert(out, { id = tonumber(r[1]), slug = r[2], title = r[3],
            story = r[4], seq = tonumber(r[5]),
            parent_id = r[6] and tonumber(r[6]) or nil,
            from_ayah_key = tonumber(r[7]), to_ayah_key = tonumber(r[8]),
            role = r[9] })
    end
    return out
end

--- Figures sharing a story unit with this one (the ≈ related row),
-- most shared units first.
function M.relatedFigures(conn, figure_id)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT f.id, f.name_en, f.name_ar, count(*) AS shared
        FROM narrative_figure a
        JOIN narrative_figure b ON b.unit_id = a.unit_id
            AND b.figure_id != a.figure_id
        JOIN figure f ON f.id = b.figure_id
        WHERE a.figure_id = ?
        GROUP BY b.figure_id ORDER BY shared DESC, f.name_en]],
        { figure_id })) do
        table.insert(out, { id = tonumber(r[1]), name_en = r[2],
            name_ar = r[3], n_shared = tonumber(r[4]) })
    end
    return out
end

--- Story cycles (mushaf order of first appearance), with unit counts.
function M.stories(conn)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT story, count(*), min(from_ayah_key) FROM narrative_unit
        GROUP BY story ORDER BY 3]])) do
        table.insert(out, { story = r[1], n_units = tonumber(r[2]),
            first_key = tonumber(r[3]) })
    end
    return out
end

function M.unitsForStory(conn, story)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT id, slug, title, story, seq, parent_id,
               from_ayah_key, to_ayah_key FROM narrative_unit
        WHERE story = ?]], { story })) do
        table.insert(out, { id = tonumber(r[1]), slug = r[2], title = r[3],
            story = r[4], seq = tonumber(r[5]),
            parent_id = r[6] and tonumber(r[6]) or nil,
            from_ayah_key = tonumber(r[7]), to_ayah_key = tonumber(r[8]) })
    end
    return M.sortUnits(out)
end

function M.unit(conn, id)
    local r = rows(conn, [[
        SELECT id, slug, title, story, seq, parent_id, from_ayah_key,
               to_ayah_key, summary, boundary_basis, status
        FROM narrative_unit WHERE id = ?]], { id })[1]
    if not r then return end
    return { id = tonumber(r[1]), slug = r[2], title = r[3], story = r[4],
        seq = tonumber(r[5]), parent_id = r[6] and tonumber(r[6]) or nil,
        from_ayah_key = tonumber(r[7]), to_ayah_key = tonumber(r[8]),
        summary = r[9], boundary_basis = r[10], status = r[11] }
end

function M.unitChildren(conn, id)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT id, slug, title, story, seq, from_ayah_key, to_ayah_key
        FROM narrative_unit WHERE parent_id = ? ORDER BY seq]], { id })) do
        table.insert(out, { id = tonumber(r[1]), slug = r[2], title = r[3],
            story = r[4], seq = tonumber(r[5]),
            from_ayah_key = tonumber(r[6]), to_ayah_key = tonumber(r[7]) })
    end
    return out
end

function M.unitFigures(conn, unit_id)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT f.id, f.name_en, f.name_ar, nf.role
        FROM narrative_figure nf
        JOIN figure f ON f.id = nf.figure_id
        WHERE nf.unit_id = ?
        ORDER BY CASE nf.role
            WHEN 'protagonist' THEN 1 WHEN 'antagonist' THEN 2
            WHEN 'supporting' THEN 3 ELSE 4 END, f.name_en]],
        { unit_id })) do
        table.insert(out, { id = tonumber(r[1]), name_en = r[2],
            name_ar = r[3], role = r[4] })
    end
    return out
end

--- Units whose span contains the ayah, most specific (narrowest) first.
function M.unitsContaining(conn, surah, ayah)
    local key = surah * 1000 + ayah
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT id, slug, title, story, seq, parent_id, from_ayah_key,
               to_ayah_key FROM narrative_unit
        WHERE from_ayah_key <= ? AND to_ayah_key >= ?
        ORDER BY (to_ayah_key - from_ayah_key)]], { key, key })) do
        table.insert(out, { id = tonumber(r[1]), slug = r[2], title = r[3],
            story = r[4], seq = tonumber(r[5]),
            parent_id = r[6] and tonumber(r[6]) or nil,
            from_ayah_key = tonumber(r[7]), to_ayah_key = tonumber(r[8]) })
    end
    return out
end

--- Ref-anchored figures (quran_refs non-empty), parsed and cached per
-- connection — the channel that makes Dhu al-Qarnayn and the unnamed
-- figures reachable from ayah pages (they have no PN occurrences).
function M.refFigures(conn)
    if M._ref_cache_conn == conn and M._ref_cache then
        return M._ref_cache
    end
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT id, name_en, name_ar, quran_refs FROM figure
        WHERE quran_refs IS NOT NULL AND quran_refs != ''
          AND quran_refs != '[]']])) do
        table.insert(out, { id = tonumber(r[1]), name_en = r[2],
            name_ar = r[3], refs = M.parseRefs(r[4]) })
    end
    M._ref_cache_conn = conn
    M._ref_cache = out
    return out
end

--- Figures at this ayah: name hits (with counts) plus curated-ref
-- anchors (marked by_ref; a figure never appears twice).
function M.figuresAt(conn, surah, ayah)
    local key = surah * 1000 + ayah
    local out, seen = {}, {}
    for _i, r in ipairs(rows(conn, [[
        SELECT f.id, f.name_en, f.name_ar, count(*)
        FROM figure_occurrence fo
        JOIN figure f ON f.id = fo.figure_id
        WHERE fo.ayah_key = ?
        GROUP BY fo.figure_id ORDER BY 4 DESC, f.name_en]], { key })) do
        local id = tonumber(r[1])
        seen[id] = true
        table.insert(out, { id = id, name_en = r[2],
            name_ar = r[3], n = tonumber(r[4]) })
    end
    for _i, f in ipairs(M.refFigures(conn)) do
        if not seen[f.id] then
            for _j, ref in ipairs(f.refs) do
                if ref[1] == surah and ayah >= ref[2] and ayah <= ref[3] then
                    table.insert(out, { id = f.id, name_en = f.name_en,
                        name_ar = f.name_ar, n = 1, by_ref = true })
                    break
                end
            end
        end
    end
    return out
end

--- Figures anywhere in the surah (hub row): name-hit ayah counts,
-- plus ref-anchored figures' covered ayahs.
function M.figuresInSurah(conn, surah)
    local out, seen = {}, {}
    for _i, r in ipairs(rows(conn, [[
        SELECT f.id, f.name_en, f.name_ar,
               count(DISTINCT fo.ayah_key)
        FROM figure_occurrence fo
        JOIN figure f ON f.id = fo.figure_id
        WHERE fo.ayah_key BETWEEN ? AND ?
        GROUP BY fo.figure_id ORDER BY 4 DESC, f.name_en]],
        { surah * 1000, surah * 1000 + 999 })) do
        local id = tonumber(r[1])
        seen[id] = true
        table.insert(out, { id = id, name_en = r[2],
            name_ar = r[3], n_ayahs = tonumber(r[4]) })
    end
    for _i, f in ipairs(M.refFigures(conn)) do
        if not seen[f.id] then
            local n = 0
            for _j, ref in ipairs(f.refs) do
                if ref[1] == surah then
                    n = n + (ref[3] - ref[2] + 1)
                end
            end
            if n > 0 then
                table.insert(out, { id = f.id, name_en = f.name_en,
                    name_ar = f.name_ar, n_ayahs = n, by_ref = true })
            end
        end
    end
    return out
end

--- Units anchored in this surah (hub row), by position.
function M.unitsInSurah(conn, surah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT id, slug, title, story, seq, parent_id, from_ayah_key,
               to_ayah_key FROM narrative_unit
        WHERE from_ayah_key BETWEEN ? AND ?
        ORDER BY from_ayah_key, (to_ayah_key - from_ayah_key) DESC]],
        { surah * 1000, surah * 1000 + 999 })) do
        table.insert(out, { id = tonumber(r[1]), slug = r[2], title = r[3],
            story = r[4], seq = tonumber(r[5]),
            parent_id = r[6] and tonumber(r[6]) or nil,
            from_ayah_key = tonumber(r[7]), to_ayah_key = tonumber(r[8]) })
    end
    return out
end

--- Semantic pairs for an ayah, BOTH directions, deduped keeping the
-- higher score (same idiom as the wording-match list). min_score is on
-- the 1|2 axis (M.semanticFloor).
function M.semanticFor(conn, surah, ayah, min_score)
    local key = surah * 1000 + ayah
    min_score = min_score or 1
    local out, seen = {}, {}
    for _i, r in ipairs(rows(conn, [[
        SELECT to_ayah_key AS k, score, common_roots FROM similar_semantic
        WHERE from_ayah_key = ?1 AND score >= ?2
        UNION
        SELECT from_ayah_key AS k, score, common_roots FROM similar_semantic
        WHERE to_ayah_key = ?1 AND score >= ?2
        ORDER BY score DESC, k]], { key, min_score })) do
        local s, a = M.keyToSA(r[1])
        local dk = s .. ":" .. a
        if not seen[dk] then
            seen[dk] = true
            table.insert(out, { surah = s, ayah = a,
                score = tonumber(r[2]), common_roots = tonumber(r[3]) })
        end
    end
    return out
end

--- Phrase-pair word spans (D-R3-14 feed; match_words = 1-based
-- [start,end] ranges in the TO ayah of the pair as stored — the
-- from-side comes from the reverse row). No UI consumes this yet: the
-- overlap display is an open owner design call.
function M.phraseSpans(conn, from_surah, from_ayah, to_surah, to_ayah)
    local r = rows(conn, [[
        SELECT match_words, coverage, matched_words_count
        FROM similar_phrase_spans
        WHERE from_ayah_key = ? AND to_ayah_key = ?]],
        { from_surah * 1000 + from_ayah, to_surah * 1000 + to_ayah })[1]
    if not r then return end
    local spans = {}
    for a, b in tostring(r[1]):gmatch("%[(%d+),(%d+)%]") do
        table.insert(spans, { tonumber(a), tonumber(b) })
    end
    return { match_words = spans, coverage = tonumber(r[2]),
        matched_words_count = tonumber(r[3]) }
end

-- ---------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------

local function notifyWarn(text)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = text })
end

local function ayahDialog(browser, surah, ayah)
    browser:showAyahPage(surah, ayah)
end

local function showReaderText(browser, kind, title, text)
    local reader = browser.quran._readerModule
        and browser.quran:_readerModule()
    if reader and reader.show then
        reader.show{
            kind = kind,
            title = title,
            text = text,
            back_label = browser.backLabel and browser:backLabel() or "←",
        }
        return true
    end
end

local function figureLabel(f)
    local label = f.name_en
    if f.name_ar and f.name_ar ~= "" then
        label = label .. "  " .. f.name_ar
    end
    return label
end

--- Figures landing: every figure, name-hit frequency first (the
-- root-explorer landing principle; unnamed figures land at the tail
-- and open the same entity screen through their story units).
function M.showFigures(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local items = {}
    for _i, f in ipairs(M.allFigures(conn)) do
        local fid = f.id
        local mand = {}
        if f.n_ayahs and f.n_ayahs > 0 then
            table.insert(mand, "\195\151" .. f.n_ayahs)
        end
        if f.n_units and f.n_units > 0 then
            table.insert(mand, f.n_units .. " \226\150\184")
        end
        table.insert(items, {
            text = figureLabel(f),
            mandatory = #mand > 0 and table.concat(mand, " \194\183 ") or nil,
            callback = function() M.showFigure(browser, fid) end,
        })
    end
    browser:navigateForward(_("Figures"), items)
end

--- Figure entity screen (the topic/theme entity idiom): About first,
-- then the story units it appears in, its name occurrences, and the
-- figures it shares stories with.
function M.showFigure(browser, id)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local f = M.figure(conn, id)
    if not f then
        notifyWarn(_("Character not found."))
        return
    end
    local items = {}
    table.insert(items, {
        text = _("About") .. ": " .. f.name_en,
        callback = function()
            showReaderText(browser, "figure", f.name_en, M.renderFigureText(f))
        end,
    })
    local units = M.figureUnits(conn, id)
    for _i, u in ipairs(units) do
        local uid = u.id
        local text = u.title
        if u.role and u.role ~= "" then
            text = text .. " \194\183 " .. u.role
        end
        table.insert(items, {
            text = "\226\150\184 " .. text,
            mandatory = M.spanLabel(u.from_ayah_key, u.to_ayah_key),
            callback = function() M.showUnit(browser, uid) end,
        })
    end
    local ayahs = M.figureAyahs(conn, id)
    if #ayahs > 0 then
        table.insert(items, {
            text = _("Mentioned in ayahs"),
            mandatory = "\195\151" .. #ayahs,
            callback = function() M.showFigureAyahs(browser, f) end,
        })
    end
    for _i, rf in ipairs(M.relatedFigures(conn, id)) do
        local rid = rf.id
        table.insert(items, {
            text = "\226\137\136 " .. figureLabel(rf),
            mandatory = "\195\151" .. rf.n_shared,
            callback = function() M.showFigure(browser, rid) end,
        })
    end
    browser:navigateForward(f.name_en, items, nil, { multiline = true })
end

function M.showFigureAyahs(browser, f)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local quran = browser.quran
    local items = {}
    for _i, e in ipairs(M.figureAyahs(conn, f.id)) do
        local s, a = e.surah, e.ayah
        local name = quran.surahName and quran:surahName(s) or tostring(s)
        table.insert(items, {
            text = string.format("%s %d:%d", name, s, a),
            mandatory = e.n > 1 and ("\195\151" .. e.n) or nil,
            callback = function() ayahDialog(browser, s, a) end,
        })
    end
    browser:navigateForward(f.name_en .. " \194\183 " .. _("Mentioned in ayahs"),
        items)
end

--- Stories landing: the cycles, mushaf order.
function M.showStories(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local items = {}
    for _i, st in ipairs(M.stories(conn)) do
        local key = st.story
        table.insert(items, {
            text = M.storyLabel(key),
            mandatory = st.n_units .. " \226\150\184",
            callback = function() M.showStory(browser, key) end,
        })
    end
    browser:navigateForward(_("Narratives"), items)
end

--- One story cycle: its units in narrative order, episodes indented.
function M.showStory(browser, story)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local items = {}
    for _i, u in ipairs(M.unitsForStory(conn, story)) do
        local uid = u.id
        local prefix = (u.depth or 0) > 0 and "    \226\150\184 " or ""
        table.insert(items, {
            text = prefix .. u.title,
            mandatory = M.spanLabel(u.from_ayah_key, u.to_ayah_key),
            callback = function() M.showUnit(browser, uid) end,
        })
    end
    browser:navigateForward(M.storyLabel(story), items, nil,
        { multiline = true })
end

--- Story-unit screen: read the passage FIRST (D-R3-6), then position,
-- context (cycle/parent/episodes), the figures in it, and its ayahs.
function M.showUnit(browser, id)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local u = M.unit(conn, id)
    if not u then
        notifyWarn(_("Narrative passage not found."))
        return
    end
    local quran = browser.quran
    local surah, a_from = M.keyToSA(u.from_ayah_key)
    local _s2, a_to = M.keyToSA(u.to_ayah_key)
    local title = u.title
    local items = {}
    table.insert(items, {
        text = _("Read this passage"),
        callback = function()
            -- the themes-flow renderer is the passage reader (numbered
            -- per-ayah translation, headings); a unit is one pseudo-theme
            local qul = browser.qulModule and browser:qulModule()
            if qul and qul.showThemesFlow then
                qul.showThemesFlow(browser, { { theme = u.title,
                    surah = surah, ayah_from = a_from, ayah_to = a_to } },
                    title)
            else
                notifyWarn(_("Reading needs the qul module."))
            end
        end,
    })
    table.insert(items, {
        text = _("Go to this passage in the book"),
        callback = function()
            local book_a = a_from > 1
                and (quran._hafsToWarshStart
                    and quran:_hafsToWarshStart(surah, a_from)
                    or quran:_hafsToWarsh(surah, a_from))
                or a_from
            browser:gotoAyah(surah, book_a)
        end,
    })
    if (u.summary and u.summary ~= "")
            or (u.boundary_basis and u.boundary_basis ~= "") then
        table.insert(items, {
            text = _("About this passage"),
            callback = function()
                showReaderText(browser, "story", title, M.renderUnitText(u))
            end,
        })
    end
    local story_key = u.story
    table.insert(items, {
        text = "\226\134\145 " .. M.storyLabel(u.story),
        callback = function() M.showStory(browser, story_key) end,
    })
    if u.parent_id then
        local p = M.unit(conn, u.parent_id)
        if p then
            local pid = p.id
            table.insert(items, {
                text = "\226\134\145 " .. p.title,
                mandatory = M.spanLabel(p.from_ayah_key, p.to_ayah_key),
                callback = function() M.showUnit(browser, pid) end,
            })
        end
    end
    for _i, c in ipairs(M.unitChildren(conn, id)) do
        local cid = c.id
        table.insert(items, {
            text = "\226\150\184 " .. c.title,
            mandatory = M.spanLabel(c.from_ayah_key, c.to_ayah_key),
            callback = function() M.showUnit(browser, cid) end,
        })
    end
    for _i, fg in ipairs(M.unitFigures(conn, id)) do
        local fid = fg.id
        local text = figureLabel(fg)
        if fg.role and fg.role ~= "" then
            text = text .. " \194\183 " .. fg.role
        end
        table.insert(items, { text = text,
            callback = function() M.showFigure(browser, fid) end,
        })
    end
    if #items > 0 then items[#items].separator = true end
    local name = quran.surahName and quran:surahName(surah) or tostring(surah)
    for a = a_from, a_to do
        local aa = a
        table.insert(items, {
            text = string.format("%s %d:%d", name, surah, aa),
            callback = function() ayahDialog(browser, surah, aa) end,
        })
    end
    browser:navigateForward(title, items, nil, { multiline = true })
end

--- Ayah-scoped list screens (the counted rows land LISTS — D-R3-12)
function M.showFiguresAt(browser, surah, ayah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local list = M.figuresAt(conn, surah, ayah)
    if #list == 0 then
        notifyWarn(_("No figures recorded at this ayah."))
        return
    end
    local items = {}
    for _i, f in ipairs(list) do
        local fid = f.id
        table.insert(items, {
            text = figureLabel(f),
            mandatory = f.n > 1 and ("\195\151" .. f.n) or nil,
            callback = function() M.showFigure(browser, fid) end,
        })
    end
    browser:navigateForward(
        string.format("%s %d:%d", _("Figures"), surah, ayah), items)
end

function M.showStoryContext(browser, surah, ayah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local list = M.unitsContaining(conn, surah, ayah)
    if #list == 0 then
        notifyWarn(_("No narrative recorded at this ayah."))
        return
    end
    local items = {}
    for _i, u in ipairs(list) do
        local uid = u.id
        table.insert(items, {
            text = u.title .. " \194\183 " .. M.storyLabel(u.story),
            mandatory = M.spanLabel(u.from_ayah_key, u.to_ayah_key),
            callback = function() M.showUnit(browser, uid) end,
        })
    end
    browser:navigateForward(
        string.format("%s %d:%d", _("Narrative context"), surah, ayah), items,
        nil, { multiline = true })
end

--- Surah-hub list screens
function M.showFiguresInSurah(browser, surah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local list = M.figuresInSurah(conn, surah)
    if #list == 0 then
        notifyWarn(_("No figures recorded in this surah."))
        return
    end
    local items = {}
    for _i, f in ipairs(list) do
        local fid = f.id
        table.insert(items, {
            text = figureLabel(f),
            mandatory = "\195\151" .. f.n_ayahs,
            callback = function() M.showFigure(browser, fid) end,
        })
    end
    local name = browser.quran.surahName
        and browser.quran:surahName(surah) or tostring(surah)
    browser:navigateForward(_("Figures") .. " \194\183 " .. name, items)
end

function M.showStoriesInSurah(browser, surah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local list = M.unitsInSurah(conn, surah)
    if #list == 0 then
        notifyWarn(_("No narratives recorded in this surah."))
        return
    end
    local items = {}
    for _i, u in ipairs(list) do
        local uid = u.id
        table.insert(items, {
            text = u.title .. " \194\183 " .. M.storyLabel(u.story),
            mandatory = M.spanLabel(u.from_ayah_key, u.to_ayah_key),
            callback = function() M.showUnit(browser, uid) end,
        })
    end
    local name = browser.quran.surahName
        and browser.quran:surahName(surah) or tostring(surah)
    browser:navigateForward(_("Narratives") .. " \194\183 " .. name, items,
        nil, { multiline = true })
end

return M
