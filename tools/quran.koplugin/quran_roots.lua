--[[--
quran_roots.lua — v1.12 hub: the root explorer (Lane + morphology).

Data: lane-vN.sqlite — the per-root extract of the quran-explorer KB
(Perseus TEI of Lane's Lexicon, public domain) — and morphology-vN.sqlite
(D-R2-1 B2: per-occurrence spine — QAC/QuranMorph lemma witnesses, EQTB
glosses, honest per-root totals, per-word Lane-headword sense map).
Both installed to <koreader>/data/quran/ by the asset manager
("quran_lane" / "quran_morphology" data packages) or dropped next to the
plugin for development. Opened read-only via KOReader's lua-ljsqlite3.

Contracts (respected here): docs/lane_handover_2026-07.md —
suspect/is_xref rows excluded, root_id trusted, quran_freq ranks, seq
preserves Lane's article order — and docs/morphology_handover_2026-07.md:
group by form_key (NEVER lemma_eqtb), hide confidence='low' sense rows,
word_headword ids target the lane build shipped WITH the extract (the
meta.created pairing gate below), missing rows are honest misses (fall
back, never synthesize). Screens follow D-R2-1 B1–B4. GPL-3.0.
]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

M.SCHEMA_VERSION = "1"

-- ---------------------------------------------------------------------
-- Pure helpers (unit-tested in scripts/dev_checks/check_plugin_helpers.lua)
-- ---------------------------------------------------------------------

-- Word-dict entries carry "root: \u{200E}ع-ذ-ب" (build_dictionary.py,
-- format_root dashes + LRM). Returns the bare unspaced root ("عذب") the
-- extract's root.arabic column uses, or nil.
function M.parseRootFromDefinition(def)
    if not def then return end
    local seg = def:match("root:%s*([^<\n]+)")
    if not seg then return end
    seg = seg:gsub("\226\128\142", "")     -- strip LRM
    seg = seg:match("^%s*(%S+)")           -- first token (stops at " · ")
    if not seg then return end
    seg = seg:gsub("%-", "")
    if seg == "" then return end
    return seg
end

-- Word-dict entries open with "<!-- ref:S:A:W -->" (build_dictionary.py
-- instance refs; multi-instance entries comma-join, the first ref is the
-- entry's identity). Returns the morphology spine word_id
-- (s*1e6 + a*1e3 + w) of the first ref, or nil.
function M.parseRefWordId(def)
    if not def then return end
    local s, a, w = def:match("<!%-%- ref:(%d+):(%d+):(%d+)")
    if not s then return end
    return tonumber(s) * 1000000 + tonumber(a) * 1000 + tonumber(w)
end

-- Display convention: dashes between radicals (matches the dict popup).
function M.dashRoot(root)
    if not root or root:find("-", 1, true) then return root end
    local letters = {}
    for ch in root:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(letters, ch)
    end
    return table.concat(letters, "-")
end

-- One row shape for every root list (frequency landing, letter list,
-- search results): dashed root, then the dominant word's cleaned first
-- sense. r = { arabic, gloss, top_freq, n }.
function M.rootItemText(r)
    local text = M.dashRoot(r.arabic)
    if r.gloss and r.gloss ~= "" then
        text = text .. " — " .. r.gloss
    end
    return text
end

-- Right column: the measured per-root total when the morphology package
-- supplies one (root.word_count — the honest spine count that retires
-- the lane-only workaround), else the dominant word's per-lemma count
-- (lane-v1 has no true totals — summing headword freqs double-counts
-- lemmas shared across headwords, see D-R2-1). Roots outside the Quran
-- fall back to their Lane entry count.
function M.rootItemMandatory(r)
    if (r.total or 0) > 0 then
        return "×" .. r.total
    end
    if (r.top_freq or 0) > 0 then
        return "×" .. r.top_freq
    end
    return r.n and tostring(r.n) or nil
end

-- Decorate root-list rows with honest totals from the morphology
-- package's map (totalsMap) and, for frequency-ranked lists, re-rank by
-- them — the measured counts replace the max-headword-freq ordering
-- workaround. No-op without the map. Pure; unit-tested.
function M.applyTotals(list, map, resort)
    if not map then return list end
    for _i, r in ipairs(list) do
        local t = map[r.arabic]
        r.total = t and t.words or nil
    end
    if resort then
        table.sort(list, function(a, b)
            local ta, tb = a.total or 0, b.total or 0
            if ta ~= tb then return ta > tb end
            local fa, fb = a.top_freq or 0, b.top_freq or 0
            if fa ~= fb then return fa > fb end
            return a.arabic < b.arabic
        end)
    end
    return list
end

-- Mark the top-3 headwords by quran_freq (the popup's ranking) inside a
-- seq-ordered list: sets .top3 = true on those rows. freq-0 rows never
-- rank. Returns the same list.
function M.markTop3(headwords)
    local order = {}
    for i, h in ipairs(headwords) do
        if (tonumber(h.quran_freq) or 0) > 0 then
            table.insert(order, i)
        end
    end
    table.sort(order, function(a, b)
        local fa = tonumber(headwords[a].quran_freq) or 0
        local fb = tonumber(headwords[b].quran_freq) or 0
        if fa ~= fb then return fa > fb end
        return (tonumber(headwords[a].seq) or 0) < (tonumber(headwords[b].seq) or 0)
    end)
    for rank = 1, math.min(3, #order) do
        headwords[order[rank]].top3 = true
    end
    return headwords
end

-- ---------------------------------------------------------------------
-- Database access
-- ---------------------------------------------------------------------

-- Locate lane-vN.sqlite: asset-manager install dir first, then the
-- plugin dir (dev convenience; gitignored there).
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
                if entry:match("^lane%-v%d+%.sqlite$") then
                    return dir .. "/" .. entry
                end
            end
        end
    end
end

-- Open (and cache) the extract; validates meta.schema_version.
-- Returns conn or nil, err.
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
        return nil, _("Could not open the root database.")
    end
    local ver_ok, ver = pcall(function()
        local stmt = conn:prepare("SELECT value FROM meta WHERE key='schema_version'")
        local row = stmt:step()
        stmt:close()
        return row and tostring(row[1])
    end)
    if not ver_ok or ver ~= M.SCHEMA_VERSION then
        pcall(function() conn:close() end)
        return nil, _("Root database has an unsupported format — update the plugin or the data package.")
    end
    M._conn = conn
    M._db_path = path
    logger.info("quran.koplugin: opened root db", path)
    return conn
end

function M.ensureDb(quran)
    local path = M._db_path or M.findDb(quran)
    if not path then
        return nil, _("Root data package not installed — get it from Library & assets in the Quran Explorer.")
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
        logger.info("quran.koplugin: root query failed:", err)
    end
    return out
end

-- ---------------------------------------------------------------------
-- Morphology package (morphology-vN.sqlite — D-R2-1 B2)
-- ---------------------------------------------------------------------

M.MORPH_SCHEMA_VERSION = "1"

function M.findMorphDb(quran)
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
                if entry:match("^morphology%-v%d+%.sqlite$") then
                    return dir .. "/" .. entry
                end
            end
        end
    end
end

function M.openMorphPath(path)
    if M._morph_conn and M._morph_path == path then
        return M._morph_conn
    end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then
        return nil, _("SQLite support not available in this KOReader build.")
    end
    local open_ok, conn = pcall(SQ3.open, path, "ro")
    if not open_ok or not conn then
        return nil, _("Could not open the morphology database.")
    end
    local ver_ok, ver = pcall(function()
        local stmt = conn:prepare("SELECT value FROM meta WHERE key='schema_version'")
        local row = stmt:step()
        stmt:close()
        return row and tostring(row[1])
    end)
    if not ver_ok or ver ~= M.MORPH_SCHEMA_VERSION then
        pcall(function() conn:close() end)
        return nil, _("Morphology database has an unsupported format — update the plugin or the data package.")
    end
    M._morph_conn = conn
    M._morph_path = path
    logger.info("quran.koplugin: opened morphology db", path)
    return conn
end

--- The morphology connection, or nil (the package is optional — every
-- consumer degrades to lane-only behavior without it).
function M.ensureMorphDb(quran)
    local path = M._morph_path or M.findMorphDb(quran)
    if not path then return nil end
    return M.openMorphPath(path)
end

--- Pairing gate (contract): word_headword.lexicon_entry_id targets the
-- lane build shipped WITH the extract — both packages carry the same
-- meta.created stamp. On mismatch the sense-targeted landing is
-- disabled (ids can't be trusted); occurrence lists and totals carry no
-- lane ids and stay available.
function M.pairOk(quran)
    if M._pair_ok ~= nil then return M._pair_ok end
    local lane = M.ensureDb(quran)
    local morph = M.ensureMorphDb(quran)
    if not (lane and morph) then return false end
    local function created(conn)
        local r = rows(conn, "SELECT value FROM meta WHERE key='created'")[1]
        return r and tostring(r[1])
    end
    local lc, mc = created(lane), created(morph)
    M._pair_ok = lc ~= nil and lc == mc
    if not M._pair_ok then
        logger.info("quran.koplugin: lane/morphology packages from different builds ("
            .. tostring(lc) .. " vs " .. tostring(mc)
            .. ") — sense-targeted landing disabled; update both packages together")
    end
    return M._pair_ok
end

--- Honest per-root totals, one 1,642-row fetch cached per session:
-- map[arabic] = { words, forms, ayahs }.
function M.totalsMap(quran)
    if M._totals then return M._totals end
    local conn = M.ensureMorphDb(quran)
    if not conn then return nil end
    local map = {}
    for _i, r in ipairs(rows(conn,
            "SELECT arabic, word_count, form_count, ayah_count FROM root")) do
        map[tostring(r[1])] = {
            words = tonumber(r[2]), forms = tonumber(r[3]),
            ayahs = tonumber(r[4]),
        }
    end
    M._totals = map
    return map
end

--- The tapped word's own Lane sense (entry-point-aware landing):
-- word_headword row for (word_id, root), confidence 'low' hidden per
-- contract. Returns { lexicon_entry_id, seq, headword, confidence } or
-- nil — a miss is honest (caller falls back to the plain root screen).
function M.wordHeadword(quran, word_id, root_arabic)
    local conn = M.ensureMorphDb(quran)
    if not conn then return end
    local r = rows(conn, [[
        SELECT wh.lexicon_entry_id, wh.headword_seq, wh.headword, wh.confidence
        FROM word_headword wh JOIN root rt ON rt.root_id = wh.root_id
        WHERE wh.word_id = ? AND rt.arabic = ?
          AND wh.confidence != 'low']],
        { word_id, root_arabic })[1]
    if not r then return end
    return {
        lexicon_entry_id = tonumber(r[1]), seq = tonumber(r[2]),
        headword = tostring(r[3]), confidence = tostring(r[4]),
    }
end

--- B2: every occurrence of a root grouped by form_key (the tag-aware
-- grouping lemma — never lemma_eqtb, contract), groups ranked by count
-- then first appearance, occurrences in mushaf order inside each.
-- Returns ordered groups { key, count, occ = { { surah, ayah, word,
-- form_text, gloss } … } }, total — or nil without the package.
function M.occurrencesByForm(quran, root_arabic)
    local conn = M.ensureMorphDb(quran)
    if not conn then return nil end
    local groups, order, total = {}, {}, 0
    for _i, r in ipairs(rows(conn, [[
        SELECT o.form_key, o.form_text, o.surah, o.ayah, o.word_pos, o.gloss
        FROM occurrence o JOIN root rt ON rt.root_id = o.root_id
        WHERE rt.arabic = ? ORDER BY o.ordinal]], { root_arabic })) do
        local key = r[1] and tostring(r[1]) or ""
        local g = groups[key]
        if not g then
            g = { key = key, count = 0, occ = {}, first = #order + 1 }
            groups[key] = g
            table.insert(order, g)
        end
        g.count = g.count + 1
        total = total + 1
        table.insert(g.occ, {
            surah = tonumber(r[3]), ayah = tonumber(r[4]),
            word = tonumber(r[5]),
            form_text = r[2] and tostring(r[2]) or "",
            gloss = r[6] and tostring(r[6]) or "",
        })
    end
    table.sort(order, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.first < b.first
    end)
    return order, total
end

-- Correlated pick of a root's dominant gloss: the highest-freq usable
-- headword that has a cleaned first sense; Lane's article order breaks
-- ties. Shared by every root-list query below (~20 ms across all 1,252
-- covered roots — root_id is indexed).
local GLOSS_SQL = [[
        (SELECT substr(le2.definition_short, 1, 120)
           FROM lexicon_entry le2
           JOIN lane_headword lh2 ON lh2.lexicon_entry_id = le2.id
          WHERE le2.root_id = r.id AND lh2.suspect = 0 AND lh2.is_xref = 0
            AND le2.definition_short IS NOT NULL
            AND le2.definition_short != ''
          ORDER BY lh2.quran_freq DESC, lh2.seq LIMIT 1)]]

local function rootRow(r)
    return {
        arabic = r[1], n = tonumber(r[2]),
        top_freq = tonumber(r[3]) or 0, gloss = r[4],
    }
end

--- Substring match over covered roots (global search). Dashes/spaces in
-- the query are stripped ("ع-ذ-ب" and "عذب" both match). Quran-frequent
-- roots first (the round's frequency-first ranking), then alphabetic.
function M.searchRoots(conn, q, limit)
    local bare = q:gsub("[%s%-]+", "")
    if bare == "" then return {} end
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT r.arabic, count(*), max(lh.quran_freq), ]] .. GLOSS_SQL .. [[
        FROM root r
        JOIN lexicon_entry le ON le.root_id = r.id
        JOIN lane_headword lh ON lh.lexicon_entry_id = le.id
        WHERE r.arabic LIKE ? AND lh.suspect = 0 AND lh.is_xref = 0
        GROUP BY r.id
        ORDER BY max(lh.quran_freq) DESC, r.arabic LIMIT ?]],
        { "%" .. bare .. "%", limit or 10 })) do
        table.insert(out, rootRow(r))
    end
    return out
end

--- The frequency-first landing list (D-R2-1 B1): every covered root
-- that occurs in the Quran, ranked by its dominant word's count.
function M.topRoots(conn)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT r.arabic, count(*), max(lh.quran_freq), ]] .. GLOSS_SQL .. [[
        FROM root r
        JOIN lexicon_entry le ON le.root_id = r.id
        JOIN lane_headword lh ON lh.lexicon_entry_id = le.id
        WHERE lh.suspect = 0 AND lh.is_xref = 0
        GROUP BY r.id
        HAVING max(lh.quran_freq) > 0
        ORDER BY max(lh.quran_freq) DESC, r.arabic]])) do
        table.insert(out, rootRow(r))
    end
    return out
end

-- First letters of covered roots, with root counts.
function M.letters(conn)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT substr(r.arabic, 1, 1) AS letter, count(DISTINCT r.id)
        FROM root r
        WHERE EXISTS (SELECT 1 FROM lexicon_entry le WHERE le.root_id = r.id)
        GROUP BY letter ORDER BY letter]])) do
        table.insert(out, { letter = r[1], n = tonumber(r[2]) })
    end
    return out
end

-- Covered roots starting with a letter — the secondary, alphabetic path
-- (order stays alphabetic; rows carry the shared gloss/freq shape).
function M.rootsByLetter(conn, letter)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT r.arabic, count(*), max(lh.quran_freq), ]] .. GLOSS_SQL .. [[
        FROM root r
        JOIN lexicon_entry le ON le.root_id = r.id
        JOIN lane_headword lh ON lh.lexicon_entry_id = le.id
        WHERE substr(r.arabic, 1, 1) = ? AND lh.suspect = 0 AND lh.is_xref = 0
        GROUP BY r.id ORDER BY r.arabic]], { letter })) do
        table.insert(out, rootRow(r))
    end
    return out
end

-- The breadth list: usable headwords in Lane's article order (seq).
function M.headwords(conn, root_arabic)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT le.id, le.headword, le.definition_short,
               lh.seq, lh.quran_freq, lh.form_no, lh.n_subsenses
        FROM lexicon_entry le
        JOIN lane_headword lh ON lh.lexicon_entry_id = le.id
        WHERE le.root_id = (SELECT id FROM root WHERE arabic = ?)
          AND lh.suspect = 0 AND lh.is_xref = 0
        ORDER BY lh.seq]], { root_arabic })) do
        table.insert(out, {
            id = tonumber(r[1]), headword = r[2], gloss = r[3],
            seq = tonumber(r[4]), quran_freq = tonumber(r[5]),
            form_no = r[6], n_subsenses = tonumber(r[7]),
        })
    end
    return M.markTop3(out)
end

-- Full entry: definition text + structured sub-senses + source apparatus.
function M.entry(conn, entry_id)
    local r = rows(conn, [[
        SELECT le.headword, le.definition, le.definition_short,
               lh.clauses_json, lh.sigla_json,
               lh.quran_freq, lh.form_no, lh.confidence
        FROM lexicon_entry le
        JOIN lane_headword lh ON lh.lexicon_entry_id = le.id
        WHERE le.id = ?]], { entry_id })[1]
    if not r then return end
    -- json needs lpeg (present in KOReader, not in the bare dev-check
    -- harness) — degrade to definition-only rendering without it
    local ok_json, JSON = pcall(require, "json")
    local function decode(s)
        if not (ok_json and s) then return end
        local ok, v = pcall(JSON.decode, s)
        if ok and type(v) == "table" then return v end
    end
    local sigla_names = {}
    for _i, s in ipairs(rows(conn, "SELECT code, name FROM lane_siglum")) do
        sigla_names[s[1]] = s[2]
    end
    return {
        headword = r[1], definition = r[2], definition_short = r[3],
        clauses = decode(r[4]), sigla = decode(r[5]),
        quran_freq = tonumber(r[6]), form_no = r[7], confidence = r[8],
        sigla_names = sigla_names,
    }
end

-- TextBoxWidget "poor text formatting": text starting with PTF_HEADER may
-- carry bold runs between PTF_BOLD_START/END (invisible otherwise).
local PTF_HEADER = "\u{FFF1}"
local PTF_B = "\u{FFF2}"
local PTF_E = "\u{FFF3}"

-- Render the full-entry text shown in the viewer (pure; tested).
-- Progressive disclosure (owner 2026-07-12: the raw Lane text reads
-- "very disorganized"): the CLEANED first sense leads, then the numbered
-- sense map (only when the entry has several — one clause just repeats
-- the opening), then Lane's complete text with its source apparatus
-- under a labeled section, sources legend last. Section labels are
-- PTF-bolded; plain content is unchanged.
function M.renderEntryText(e, root)
    local parts = {}
    local meta_bits = {}
    if e.quran_freq and e.quran_freq > 0 then
        table.insert(meta_bits, "×" .. e.quran_freq .. " " .. _("in the Quran"))
    end
    if e.form_no and e.form_no ~= "" then
        table.insert(meta_bits, _("verb form") .. " " .. e.form_no)
    end
    if root then
        table.insert(meta_bits, _("root") .. " " .. M.dashRoot(root))
    end
    if #meta_bits > 0 then
        table.insert(parts, PTF_B .. table.concat(meta_bits, " · ") .. PTF_E)
    end
    local short = e.definition_short
    if short and short ~= "" then
        table.insert(parts, short)
    end
    if e.clauses and #e.clauses > 1 then
        local lines = { PTF_B .. _("Senses:") .. PTF_E }
        for _i, c in ipairs(e.clauses) do
            local marker = c.marker and (c.marker .. ". ") or "– "
            table.insert(lines, PTF_B .. marker .. PTF_E .. (c.text or ""))
        end
        table.insert(parts, table.concat(lines, "\n\n"))
    end
    if e.definition and e.definition ~= "" then
        if (short and short ~= "") or (e.clauses and #e.clauses > 1) then
            table.insert(parts, PTF_B .. _("Full entry (Lane):") .. PTF_E
                .. "\n" .. e.definition)
        else
            table.insert(parts, e.definition)
        end
    end
    if e.sigla and #e.sigla > 0 then
        local lines = {}
        for _i, code in ipairs(e.sigla) do
            local name = e.sigla_names and e.sigla_names[code]
            table.insert(lines, name and (code .. " = " .. name) or code)
        end
        table.insert(parts, PTF_B .. _("Sources:") .. PTF_E .. " "
            .. table.concat(lines, " · "))
    end
    return PTF_HEADER .. table.concat(parts, "\n\n")
end

-- ---------------------------------------------------------------------
-- Screens (inside the Quran browser)
-- ---------------------------------------------------------------------

local function notifyWarn(text)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = text })
end

-- Menu row for a root list entry (landing / letter / search screens).
function M.rootItem(browser, r)
    local root = r.arabic
    return {
        text = M.rootItemText(r),
        mandatory = M.rootItemMandatory(r),
        callback = function() M.showRoot(browser, root) end,
    }
end

--- The explorer landing (D-R2-1 B1, frequency-first): search + the
-- alphabet up top as paths, then every Quran-occurring root ranked by
-- its dominant word's count — the browsable "top roots" list itself.
function M.showRoots(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then
        notifyWarn(err)
        return
    end
    local items = {}
    table.insert(items, {
        text = _("Search roots"),
        callback = function()
            browser:promptSearch(_("Search roots"), function(q)
                M.showSearch(browser, q)
            end)
        end,
    })
    local letters = M.letters(conn)
    local n_roots = 0
    for _i, l in ipairs(letters) do n_roots = n_roots + l.n end
    table.insert(items, {
        text = _("Browse by letter"),
        mandatory = tostring(n_roots),
        separator = true,
        callback = function() M.showLetters(browser, letters) end,
    })
    -- measured totals rank when the morphology package is present
    for _i, r in ipairs(M.applyTotals(M.topRoots(conn),
            M.totalsMap(browser.quran), true)) do
        table.insert(items, M.rootItem(browser, r))
    end
    browser:navigateForward(_("Roots"), items)
end

-- The alphabet path (secondary since the frequency landing, B1).
function M.showLetters(browser, letters)
    local conn = M.ensureDb(browser.quran)
    if not conn then return end
    local items = {}
    for _i, l in ipairs(letters or M.letters(conn)) do
        local letter = l.letter
        table.insert(items, {
            text = letter,
            mandatory = tostring(l.n),
            callback = function() M.showLetter(browser, letter) end,
        })
    end
    browser:navigateForward(_("By letter"), items)
end

function M.showLetter(browser, letter)
    local conn = M.ensureDb(browser.quran)
    if not conn then return end
    local items = {}
    -- alphabetic path keeps its order; totals decorate the right column
    for _i, r in ipairs(M.applyTotals(M.rootsByLetter(conn, letter),
            M.totalsMap(browser.quran), false)) do
        table.insert(items, M.rootItem(browser, r))
    end
    browser:navigateForward(letter, items)
end

function M.showSearch(browser, q)
    local conn = M.ensureDb(browser.quran)
    if not conn then return end
    local res = M.searchRoots(conn, q, 50)
    if #res == 0 then
        notifyWarn(_("No roots match:") .. " " .. q)
        return
    end
    local items = {}
    for _i, r in ipairs(M.applyTotals(res, M.totalsMap(browser.quran), true)) do
        table.insert(items, M.rootItem(browser, r))
    end
    browser:navigateForward(_("Roots") .. ": " .. q, items)
end

-- Headword menu row (entity summary + Lane article list share it).
local function headwordItem(browser, root, hws, idx, starred)
    local h = hws[idx]
    local star = (starred and h.top3) and "★ " or ""
    local text = star .. (h.headword or "?")
    if h.gloss and h.gloss ~= "" then
        text = text .. " — " .. h.gloss
    end
    local mand = h.quran_freq and h.quran_freq > 0 and ("×" .. h.quran_freq) or ""
    if h.form_no and h.form_no ~= "" then
        mand = mand ~= "" and (mand .. " · " .. h.form_no) or h.form_no
    end
    return {
        text = text,
        mandatory = mand,
        callback = function()
            M.showEntry(browser, h.id, root, { list = hws, index = idx })
        end,
    }
end

-- Entity-screen summary: indexes of the lead headwords, frequency-first
-- (top3 by freq desc; a freq-0 root leads with its first glossed entry —
-- Lane opens articles with the base verb). Glossless entries never lead
-- while a glossed one exists — the summary is there to be READ (e.g.
-- ربب's رُبَ carries the ×975 signal but no short sense; it stays in the
-- article list). Pure; unit-tested.
function M.summaryIndexes(hws)
    local starred, glossed = {}, {}
    for i, h in ipairs(hws) do
        if h.top3 then
            table.insert(starred, i)
            if h.gloss and h.gloss ~= "" then table.insert(glossed, i) end
        end
    end
    local pick = #glossed > 0 and glossed or starred
    table.sort(pick, function(a, b)
        local fa = tonumber(hws[a].quran_freq) or 0
        local fb = tonumber(hws[b].quran_freq) or 0
        if fa ~= fb then return fa > fb end
        return a < b
    end)
    if #pick > 0 then return pick end
    for i, h in ipairs(hws) do
        if h.gloss and h.gloss ~= "" then return { i } end
    end
    return { 1 }
end

--- Root entity screen (D-R2-1 B3/B4 + B2): glanceable summary up top —
-- the frequency-ranked senses a word-popup arrival came to read — then
-- the study rows (Lane article, form-grouped Occurrences with the
-- measured totals). A word-popup arrival with morphology data leads
-- with THE TAPPED WORD's own Lane sense (opts.word_id → word_headword,
-- pairing-gated — the عِظَٰمٗا fix: bones, not the root's dominant
-- "great"). Single-entry roots still open the entry direct when the
-- screen would add nothing (no occurrence data). Related-roots stays
-- data-gated (zero cross-root xrefs in lane-v1; DA-2).
function M.showRoot(browser, root, opts)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then
        notifyWarn(err)
        return
    end
    local hws = M.headwords(conn, root)
    if #hws == 0 then
        notifyWarn(_("No Lane entry for this root."))
        return
    end
    local totals = M.totalsMap(browser.quran)
    totals = totals and totals[root]
    if #hws == 1 and not totals then
        M.showEntry(browser, hws[1].id, root)
        return
    end
    local lead
    if opts and opts.word_id and M.pairOk(browser.quran) then
        lead = M.wordHeadword(browser.quran, opts.word_id, root)
    end
    local items = {}
    if lead then
        local idx
        for i, h in ipairs(hws) do
            if h.id == lead.lexicon_entry_id then idx = i break end
        end
        local text = _("This word:") .. " " .. lead.headword
        local gloss = idx and hws[idx].gloss
        if gloss and gloss ~= "" then
            text = text .. " — " .. gloss
        end
        table.insert(items, {
            text = text,
            bold = true,
            callback = function()
                M.showEntry(browser, lead.lexicon_entry_id, root,
                    idx and { list = hws, index = idx } or nil)
            end,
        })
    end
    for _i, idx in ipairs(M.summaryIndexes(hws)) do
        -- the lead already shows this sense — don't repeat it
        if not (lead and hws[idx].id == lead.lexicon_entry_id) then
            table.insert(items, headwordItem(browser, root, hws, idx, true))
        end
    end
    items[#items].separator = true
    table.insert(items, {
        text = _("Lane article"),
        mandatory = tostring(#hws),
        callback = function() M.showLaneList(browser, root, hws) end,
    })
    if totals then
        table.insert(items, {
            text = _("Occurrences"),
            mandatory = string.format("×%d · %d %s",
                totals.words, totals.forms, _("forms")),
            callback = function() M.showOccurrences(browser, root) end,
        })
    end
    browser:navigateForward(M.dashRoot(root), items)
end

--- Build the occurrences item list (pure over the grouped data +
-- expanded set — harness-pinned). Collapsed by default (owner ask
-- 2026-07-18): form rows ("▸/▾ form_key ×N") lead so the main forms
-- scan on one screen; a tapped form's occurrences unfold beneath it
-- in place (same row shape as the always-open mockup: inflected
-- surface + gloss, S:A:W right). expanded is keyed by GROUP (table
-- identity — display keys can collide on the empty-form_key
-- fallback); disp = Arabic display normalization (QPC trio → wrong
-- tanween / %-looking marks in UI fonts), toggle(g, idx) rebuilds.
function M.occurrenceItems(order, expanded, disp, toggle, open_ayah)
    local items = {}
    for _i, g in ipairs(order) do
        local open = expanded[g]
        local hidx = #items + 1
        table.insert(items, {
            text = (open and "▾ " or "▸ ")
                .. disp(g.key ~= "" and g.key or g.occ[1].form_text),
            mandatory = "×" .. g.count,
            bold = true,
            callback = function() toggle(g, hidx) end,
        })
        if open then
            for _j, o in ipairs(g.occ) do
                local text = disp(o.form_text)
                if o.gloss ~= "" then
                    text = text .. " — " .. o.gloss
                end
                table.insert(items, {
                    text = text,
                    mandatory = string.format("%d:%d:%d",
                        o.surah, o.ayah, o.word),
                    callback = function()
                        open_ayah(o.surah, o.ayah)
                    end,
                })
            end
        end
    end
    return items
end

--- B2 occurrences screen (reference mockup = the owner's Al Quran shot,
-- design doc §Batch 6; collapsed-by-default per the owner ask
-- 2026-07-18): form rows toggle their occurrences in place
-- (Browser:refreshScreen — no nav_stack churn, ← leaves in one tap).
function M.showOccurrences(browser, root)
    local order, total = M.occurrencesByForm(browser.quran, root)
    if not order or #order == 0 then
        notifyWarn(_("No occurrence data for this root."))
        return
    end
    local quran = browser.quran
    local function disp(s)
        return (quran and quran.displayArabic)
            and quran:displayArabic(s) or s
    end
    local expanded = {}
    local build
    local function toggle(g, hidx)
        expanded[g] = not expanded[g] or nil
        if browser.refreshScreen then
            browser:refreshScreen(build(), hidx)
        end
    end
    local function openAyah(s, a) browser:showAyahPage(s, a) end
    build = function()
        return M.occurrenceItems(order, expanded, disp, toggle, openAyah)
    end
    browser:navigateForward(
        string.format("%s — ×%d", M.dashRoot(root), total),
        build(), nil, { multiline = true })
end

--- The complete Lane article: every usable headword in Lane's own order
-- (seq), stars marking the popup's top-3.
function M.showLaneList(browser, root, hws)
    if not hws then
        local conn = M.ensureDb(browser.quran)
        if not conn then return end
        hws = M.headwords(conn, root)
    end
    local items = {}
    for i in ipairs(hws) do
        table.insert(items, headwordItem(browser, root, hws, i, true))
    end
    browser:navigateForward(_("Lane") .. ": " .. M.dashRoot(root), items)
end

-- Full-entry viewer, X-ray-browser style: full screen over the (still
-- open) browser list, ← back into the list, ◀ ▶ through the root's
-- headwords with an (i/N) title, page-turn keys at the scroll
-- boundaries stepping to the previous/next entry. ◀ ▶ UPDATE the open
-- viewer in place via TextViewer:init(true) — the stock in-place
-- rebuild — instead of close/reopen (koassistant X-ray standard).
-- nav: { list = headwords array, index = position } or nil.
M._entry_viewer = nil

function M.showEntry(browser, entry_id, root, nav)
    local conn = M.ensureDb(browser.quran)
    if not conn then return end
    local e = M.entry(conn, entry_id)
    if not e then
        notifyWarn(_("Entry not found."))
        return
    end
    local UIManager = require("ui/uimanager")

    local viewer  -- resolved below (reused or created); callbacks close over it
    local title = e.headword or M.dashRoot(root)
    local row = {
        {
            id = "qx_back",
            text = "← " .. M.dashRoot(root),
            callback = function()
                if M._entry_viewer == viewer then M._entry_viewer = nil end
                if viewer then
                    viewer._qx_active = nil
                    UIManager:close(viewer)
                end
            end,
        },
    }
    local navigatePrev, navigateNext
    if nav and nav.list and #nav.list > 1 then
        local total = #nav.list
        title = string.format("(%d/%d) %s", nav.index, total, title)
        navigatePrev = function()
            local i = nav.index > 1 and nav.index - 1 or total
            M.showEntry(browser, nav.list[i].id, root, { list = nav.list, index = i })
        end
        navigateNext = function()
            local i = nav.index < total and nav.index + 1 or 1
            M.showEntry(browser, nav.list[i].id, root, { list = nav.list, index = i })
        end
        -- the pair follows the paging policy like the Reader's (left =
        -- forward when inverted); entries are English-led (content_rtl
        -- false), so only the explicit inverted/auto modes flip it
        local rd = browser.quran and browser.quran._readerModule
            and browser.quran:_readerModule()
        local left_cb, right_cb = navigatePrev, navigateNext
        if rd and rd.pagingInverted and rd.pagingInverted(false) then
            left_cb, right_cb = navigateNext, navigatePrev
        end
        table.insert(row, { id = "qx_prev", text = "◀", callback = left_cb })
        table.insert(row, { id = "qx_next", text = "▶", callback = right_cb })
    else
        table.insert(row, {
            id = "qx_top",
            text = "⇱",
            callback = function()
                -- scroll_widget = post-2026-07 KOReader field name,
                -- scroll_text_w = older (shared Reader shim rationale)
                local sw = viewer
                    and (viewer.scroll_widget or viewer.scroll_text_w)
                if sw then sw:scrollToTop() end
            end,
        })
        table.insert(row, {
            id = "qx_bottom",
            text = "⇲",
            callback = function()
                local sw = viewer
                    and (viewer.scroll_widget or viewer.scroll_text_w)
                if sw then sw:scrollToBottom() end
            end,
        })
    end

    -- Page-turn keys past the scroll boundaries step through the
    -- headwords (X-ray browser idiom: onScrollUp/Down return nil at the
    -- boundary). Re-wired after every in-place update — init(true)
    -- recreates the scroll widget. Tap/swipe paging direction is the
    -- shared Reader's job (wireTouchPaging — honors the paging mode).
    local function wireTouch()
        local reader = browser.quran and browser.quran._readerModule
            and browser.quran:_readerModule()
        if viewer and reader and reader.wireTouchPaging then
            -- Lane entries are English-led (forced-LTR rendering below)
            -- — declare it for the "follow content" paging mode rather
            -- than letting the Arabic headword sway the classifier.
            viewer._qr_content_rtl = false
            reader.wireTouchPaging(viewer)
            if reader.wirePagingMenu then
                reader.wirePagingMenu(viewer)
            end
        end
    end
    local function wireScroll()
        wireTouch()
        local stw = viewer
            and (viewer.scroll_widget or viewer.scroll_text_w)
        if not (navigatePrev and stw) then return end
        local orig_up = stw.onScrollUp
        stw.onScrollUp = function(self_w)
            local handled = orig_up and orig_up(self_w)
            if handled then return handled end
            navigatePrev()
            return true
        end
        local orig_down = stw.onScrollDown
        stw.onScrollDown = function(self_w)
            local handled = orig_down and orig_down(self_w)
            if handled then return handled end
            navigateNext()
            return true
        end
    end

    local live = M._entry_viewer
    if live and live._qx_active then
        viewer = live
        viewer.title = title
        viewer.text = M.renderEntryText(e, root)
        viewer.buttons_table = { row }
        -- Newer KOReader's key handlers consult page_turn_callback_*
        -- first-class; refresh per entry (nil when there's no nav list)
        viewer.page_turn_callback_prev = navigatePrev
        viewer.page_turn_callback_next = navigateNext
        viewer:init(true)
        wireScroll()
        if viewer.frame and viewer.frame.dimen then
            -- "ui" not "partial": same navigation-polish rationale as
            -- the Reader's in-place update (quran_reader M.show)
            UIManager:setDirty("all", "ui", viewer.frame.dimen)
        end
        return
    end

    local TextViewer = require("ui/widget/textviewer")
    local Device = require("device")
    local Screen = Device.screen
    viewer = TextViewer:new{
        title = title,
        text = M.renderEntryText(e, root),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        justified = false,
        -- Lane entries are English-dominant but OPEN with the Arabic
        -- headword — auto para direction would classify them RTL and
        -- right-align the English. Force LTR paragraphs; embedded
        -- Arabic runs still shape/order correctly (bidi).
        auto_para_direction = false,
        para_direction_rtl = false,
        buttons_table = { row },
        -- Newer KOReader (2026-06+): first-class boundary fall-through
        -- for page-turn keys; wireScroll's instance hook consumes the
        -- boundary first where it wires (nil without a nav list)
        page_turn_callback_prev = navigatePrev,
        page_turn_callback_next = navigateNext,
    }
    viewer._qx_active = true
    local orig_close_widget = viewer.onCloseWidget
    viewer.onCloseWidget = function(v)
        if M._entry_viewer == v then M._entry_viewer = nil end
        v._qx_active = nil
        if orig_close_widget then return orig_close_widget(v) end
    end
    M._entry_viewer = viewer
    wireScroll()
    UIManager:show(viewer)
end

return M
