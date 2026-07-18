--[[--
quran_masaq.lua — word-by-word i'rab from the MASAQ layer (DA-7
batch 2; H3 ask + extract 2026-07-18).

Data: masaq-vN.sqlite (explorer-side kb/export/masaq_extract.py),
installed to <koreader>/data/quran/ ("quran_masaq" data package) or
dropped next to the plugin for development.

LICENSE: the data is CC BY-NC 3.0 (Sawalha et al., MASAQ, Mendeley
Data v6 — attribution carried in the package meta). It ships as an
ISOLATED package and is never merged into the StarDict dicts or any
other artifact (the rest of the release stays liberally licensed).

Shape: MASAQ's OWN segmentation — `token_id` groups sub-word
segments; 51 rows span merged grammatical units via
word_id..word_id_end; `Other_i3rab` rows are IMPLIED elements (form
NULL). Keys are spine-stable (word_id = s*1e6 + a*1e3 + w, Hafs).
All rows research-status candidate. Plugin code GPL-3.0.
]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

M.SCHEMA_VERSION = "1"

-- ---------------------------------------------------------------------
-- Pure helpers (unit-tested)
-- ---------------------------------------------------------------------

--- Group an ayah's token rows (already ordered by id) into words:
-- { word_id, pos, surface, role, gloss, n_segments, has_implied,
--   word_id_end }. Surface = concatenated segment forms; role = the
-- first Stem segment's syntactic_role (else the first non-nil one).
function M.assembleWords(tokens)
    local out, by_word = {}, {}
    for _i, t in ipairs(tokens) do
        local w = by_word[t.word_id]
        if not w then
            w = { word_id = t.word_id, pos = t.word_id % 1000,
                surface = "", role = nil, gloss = nil, n_segments = 0,
                has_implied = false, word_id_end = t.word_id_end }
            by_word[t.word_id] = w
            table.insert(out, w)
        end
        w.n_segments = w.n_segments + 1
        if t.morph_type == "Other_i3rab" then
            w.has_implied = true
        elseif t.form then
            w.surface = w.surface .. t.form
        end
        if t.syntactic_role and (not w.role
                or (t.morph_type == "Stem" and not w.role_is_stem)) then
            w.role = t.syntactic_role
            w.role_is_stem = t.morph_type == "Stem"
        end
        w.gloss = w.gloss or t.gloss
        w.word_id_end = w.word_id_end or t.word_id_end
    end
    return out
end

-- Viewer text (PTF bold segments, the Lane/topic idiom)
local PTF_HEADER = "\u{FFF1}"
local PTF_B = "\u{FFF2}"
local PTF_E = "\u{FFF3}"

local MORPH_TYPE_LABELS = {
    Stem = _("stem"), Prefix = _("prefix"), Suffix = _("suffix"),
    Other_i3rab = _("implied"),
}

--- One segment as a display block. legend = M.legend(conn) map.
local function segmentText(t, legend)
    local function tag(kind, value)
        local e = value and legend and legend[kind] and legend[kind][value]
        if not e then return value end
        local bits = {}
        if e.ar and e.ar ~= "" then table.insert(bits, e.ar) end
        if e.en and e.en ~= "" then table.insert(bits, e.en) end
        return table.concat(bits, " — ")
    end
    local head
    if t.morph_type == "Other_i3rab" then
        head = "(" .. _("implied") .. ")"
    else
        head = t.form or ""
        local ml = MORPH_TYPE_LABELS[t.morph_type] or t.morph_type
        head = head .. "  ·  " .. ml
        if t.morph_tag then head = head .. " · " .. t.morph_tag end
    end
    local lines = { PTF_B .. head .. PTF_E }
    if t.syntactic_role then
        table.insert(lines, tag("role", t.syntactic_role))
    end
    local case_bits = {}
    if t.case_mood then table.insert(case_bits, tag("case_mood", t.case_mood)) end
    if t.case_marker then
        table.insert(case_bits, tag("case_marker", t.case_marker))
    end
    if t.inv_decl then table.insert(case_bits, tag("inv_decl", t.inv_decl)) end
    if #case_bits > 0 then
        table.insert(lines, table.concat(case_bits, " · "))
    end
    if t.possessive then
        table.insert(lines, tag("possessive", t.possessive))
    end
    local clause_bits = {}
    if t.phrasal_function then
        table.insert(clause_bits,
            _("clause function:") .. " " .. tag("phrasal_function", t.phrasal_function))
    end
    if t.phrase then
        table.insert(clause_bits,
            _("clause type:") .. " " .. tag("phrase", t.phrase))
    end
    if #clause_bits > 0 then
        table.insert(lines, table.concat(clause_bits, " · "))
    end
    return table.concat(lines, "\n")
end

--- Full word view: headline (surface · gloss), then each segment.
function M.renderWord(tokens, legend, surface)
    local parts = {}
    local head_bits = {}
    if surface and surface ~= "" then table.insert(head_bits, surface) end
    local gloss
    for _i, t in ipairs(tokens) do
        gloss = gloss or t.gloss
    end
    if gloss then table.insert(head_bits, gloss) end
    if #head_bits > 0 then
        table.insert(parts, PTF_B .. table.concat(head_bits, "  ·  ") .. PTF_E)
    end
    for _i, t in ipairs(tokens) do
        table.insert(parts, segmentText(t, legend))
    end
    table.insert(parts, PTF_B .. _("Source:") .. PTF_E .. " "
        .. _("MASAQ (Sawalha et al., CC BY-NC 3.0) — research-candidate data"))
    return PTF_HEADER .. table.concat(parts, "\n\n")
end

-- ---------------------------------------------------------------------
-- Database access (same shape as quran_connections.lua)
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
                if entry:match("^masaq%-v%d+%.sqlite$") then
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
        return nil, _("Could not open the MASAQ database.")
    end
    local ver_ok, ver = pcall(function()
        local stmt = conn:prepare("SELECT value FROM meta WHERE key='schema_version'")
        local row = stmt:step()
        stmt:close()
        return row and tostring(row[1])
    end)
    if not ver_ok or ver ~= M.SCHEMA_VERSION then
        pcall(function() conn:close() end)
        return nil, _("MASAQ database has an unsupported format — update the plugin or the data package.")
    end
    M._conn = conn
    M._db_path = path
    logger.info("quran.koplugin: opened masaq db", path)
    return conn
end

function M.ensureDb(quran)
    local path = M._db_path or M.findDb(quran)
    if not path then
        return nil, _("MASAQ data package not installed — get it from Library & assets in the Quran browser.")
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
        logger.info("quran.koplugin: masaq query failed:", err)
    end
    return out
end

local TOKEN_COLS = [[id, token_id, word_id, word_id_end, seg_no, form,
    morph_tag, morph_type, syntactic_role, case_mood, case_marker,
    inv_decl, possessive, phrase, phrasal_function, gloss]]

local function tokenRow(r)
    return { id = tonumber(r[1]), token_id = tonumber(r[2]),
        word_id = tonumber(r[3]),
        word_id_end = r[4] and tonumber(r[4]) or nil,
        seg_no = tonumber(r[5]), form = r[6], morph_tag = r[7],
        morph_type = r[8], syntactic_role = r[9], case_mood = r[10],
        case_marker = r[11], inv_decl = r[12], possessive = r[13],
        phrase = r[14], phrasal_function = r[15], gloss = r[16] }
end

--- All segments of one word, incl. merged-unit span rows covering it.
function M.tokensForWord(conn, word_id)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT ]] .. TOKEN_COLS .. [[ FROM masaq_token
        WHERE word_id = ?1
           OR (word_id_end IS NOT NULL AND ?1 BETWEEN word_id AND word_id_end)
        ORDER BY id]], { word_id })) do
        table.insert(out, tokenRow(r))
    end
    return out
end

--- All of an ayah's token rows, reading order.
function M.tokensForAyah(conn, surah, ayah)
    local base = surah * 1e6 + ayah * 1e3
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT ]] .. TOKEN_COLS .. [[ FROM masaq_token
        WHERE word_id BETWEEN ? AND ? ORDER BY id]],
        { base, base + 999 })) do
        table.insert(out, tokenRow(r))
    end
    return out
end

--- Per-surah ayah coverage: { {ayah, n_words}, ... } in ayah order.
-- (Browse parity round, owner 2026-07-18: MASAQ gets the same
-- surah→ayah browse shape as the grammar/i'rab corpora.)
function M.ayahsCovered(conn, surah)
    local base = surah * 1e6
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT (word_id / 1000) % 1000 AS ayah, COUNT(DISTINCT word_id)
        FROM masaq_token WHERE word_id BETWEEN ? AND ?
        GROUP BY 1 ORDER BY 1]], { base, base + 999999 })) do
        table.insert(out, { ayah = tonumber(r[1]), n_words = tonumber(r[2]) })
    end
    return out
end

--- Corpus-wide surah coverage: surah -> distinct-word count.
function M.surahWordCounts(conn)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT word_id / 1000000, COUNT(DISTINCT word_id)
        FROM masaq_token GROUP BY 1]])) do
        out[tonumber(r[1])] = tonumber(r[2])
    end
    return out
end

--- Tag legend, cached per connection: kind -> tag -> {ar, en}.
function M.legend(conn)
    if M._legend_conn == conn and M._legend then
        return M._legend
    end
    local out = {}
    for _i, r in ipairs(rows(conn,
        "SELECT kind, tag, desc_ar, desc_en FROM masaq_tag")) do
        local kind = r[1]
        out[kind] = out[kind] or {}
        out[kind][r[2]] = { ar = r[3], en = r[4] }
    end
    M._legend_conn = conn
    M._legend = out
    return out
end

-- ---------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------

local function notifyWarn(text)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = text })
end

--- The ayah's words, one row each (surface + gloss, role in the count
-- column); tap = the full segment view in the Reader.
function M.showAyah(browser, surah, ayah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local tokens = M.tokensForAyah(conn, surah, ayah)
    if #tokens == 0 then
        notifyWarn(_("No word grammar recorded for this ayah."))
        return
    end
    local legend = M.legend(conn)
    local words = M.assembleWords(tokens)
    local items = {}
    for _i, w in ipairs(words) do
        local word = w
        local text = w.pos .. ". " .. w.surface
        if w.gloss and w.gloss ~= "" then
            text = text .. " — " .. w.gloss
        end
        local role = w.role and legend.role and legend.role[w.role]
        table.insert(items, {
            text = text,
            mandatory = role and role.ar or w.role,
            callback = function() M.showWord(browser, word) end,
        })
    end
    local name = browser.quran.surahName
        and browser.quran:surahName(surah) or tostring(surah)
    browser:navigateForward(
        string.format("%s · %s %d:%d", _("Word grammar"), name, surah, ayah),
        items, nil, { multiline = true })
end

--- One surah's ayahs with word counts; tap = the word list.
function M.showSurah(browser, surah)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local name = browser.quran.surahName
        and browser.quran:surahName(surah) or tostring(surah)
    local items = {}
    for _i, a in ipairs(M.ayahsCovered(conn, surah)) do
        local ayah = a.ayah
        table.insert(items, {
            text = string.format("%d:%d", surah, ayah),
            mandatory = tostring(a.n_words),
            callback = function() M.showAyah(browser, surah, ayah) end,
        })
    end
    if #items == 0 then
        notifyWarn(_("No word grammar recorded for this surah."))
        return
    end
    browser:navigateForward(
        _("Word grammar (MASAQ)") .. " \194\183 " .. name, items)
end

--- Root browse entry: all surahs with word counts.
function M.showBrowse(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local counts = M.surahWordCounts(conn)
    local items = {}
    for s = 1, 114 do
        local surah = s
        local name = browser.quran.surahName
            and browser.quran:surahName(s) or tostring(s)
        table.insert(items, {
            text = string.format("%d. %s", s, name),
            mandatory = counts[s] and tostring(counts[s]) or nil,
            dim = not counts[s] or nil,
            callback = function() M.showSurah(browser, surah) end,
        })
    end
    browser:navigateForward(_("Word grammar (MASAQ)"), items)
end

--- One word's full i'rab (Reader surface; the browser stays beneath).
function M.showWord(browser, w)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local tokens = M.tokensForWord(conn, w.word_id)
    if #tokens == 0 then
        notifyWarn(_("No word grammar recorded for this word."))
        return
    end
    local reader = browser.quran._readerModule
        and browser.quran:_readerModule()
    if not (reader and reader.show) then return end
    local s, a = math.floor(w.word_id / 1e6), math.floor(w.word_id / 1e3) % 1000
    reader.show{
        kind = "masaq",
        title = string.format("%s — %d:%d", w.surface ~= "" and w.surface
            or _("Word grammar"), s, a),
        text = M.renderWord(tokens, M.legend(conn), w.surface),
        back_label = browser.backLabel and browser:backLabel() or "←",
    }
end

return M
