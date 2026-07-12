--[[--
quran_roots.lua — v1.12 hub: the root explorer (Lane layer).

Data: lane-vN.sqlite — the per-root extract of the quran-explorer KB
(Perseus TEI of Lane's Lexicon, public domain), installed to
<koreader>/data/quran/ by the asset manager ("quran_lane" data package)
or dropped next to the plugin for development. Opened read-only via
KOReader's bundled lua-ljsqlite3.

Contract + quality flags (respected here): quran-ebook
docs/lane_handover_2026-07.md — suspect/is_xref rows are excluded,
root_id is trusted as shipped, quran_freq ranks, seq preserves Lane's
article order. Screens follow plugin_root_explorer_plan.md P1: letters →
roots → headword breadth list → full entry text. GPL-3.0.
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

-- Display convention: dashes between radicals (matches the dict popup).
function M.dashRoot(root)
    if not root or root:find("-", 1, true) then return root end
    local letters = {}
    for ch in root:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(letters, ch)
    end
    return table.concat(letters, "-")
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
        return nil, _("Root data package not installed — get it from Library & assets in the Quran browser.")
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

-- Covered roots starting with a letter, with usable-headword counts.
function M.rootsByLetter(conn, letter)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT r.arabic, count(*)
        FROM root r
        JOIN lexicon_entry le ON le.root_id = r.id
        JOIN lane_headword lh ON lh.lexicon_entry_id = le.id
        WHERE substr(r.arabic, 1, 1) = ? AND lh.suspect = 0 AND lh.is_xref = 0
        GROUP BY r.id ORDER BY r.arabic]], { letter })) do
        table.insert(out, { arabic = r[1], n = tonumber(r[2]) })
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
        SELECT le.headword, le.definition, lh.clauses_json, lh.sigla_json,
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
        headword = r[1], definition = r[2],
        clauses = decode(r[3]), sigla = decode(r[4]),
        quran_freq = tonumber(r[5]), form_no = r[6], confidence = r[7],
        sigla_names = sigla_names,
    }
end

-- Render the full-entry text shown in the viewer (pure; tested).
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
        table.insert(parts, table.concat(meta_bits, " · "))
    end
    table.insert(parts, e.definition or "")
    if e.clauses and #e.clauses > 0 then
        local lines = { _("Sub-senses:") }
        for _i, c in ipairs(e.clauses) do
            local marker = c.marker and (c.marker .. ". ") or "– "
            table.insert(lines, marker .. (c.text or ""))
        end
        table.insert(parts, table.concat(lines, "\n"))
    end
    if e.sigla and #e.sigla > 0 then
        local lines = {}
        for _i, code in ipairs(e.sigla) do
            local name = e.sigla_names and e.sigla_names[code]
            table.insert(lines, name and (code .. " = " .. name) or code)
        end
        table.insert(parts, _("Sources:") .. " " .. table.concat(lines, " · "))
    end
    return table.concat(parts, "\n\n")
end

-- ---------------------------------------------------------------------
-- Screens (inside the Quran browser)
-- ---------------------------------------------------------------------

local function notifyWarn(text)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = text })
end

function M.showRoots(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then
        notifyWarn(err)
        return
    end
    local items = {}
    for _i, l in ipairs(M.letters(conn)) do
        local letter = l.letter
        table.insert(items, {
            text = letter,
            mandatory = tostring(l.n),
            callback = function() M.showLetter(browser, letter) end,
        })
    end
    browser:navigateForward(_("Roots"), items)
end

function M.showLetter(browser, letter)
    local conn = M.ensureDb(browser.quran)
    if not conn then return end
    local items = {}
    for _i, r in ipairs(M.rootsByLetter(conn, letter)) do
        local root = r.arabic
        table.insert(items, {
            text = M.dashRoot(root),
            mandatory = tostring(r.n),
            callback = function() M.showRoot(browser, root) end,
        })
    end
    browser:navigateForward(letter, items)
end

function M.showRoot(browser, root)
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
    local items = {}
    for _i, h in ipairs(hws) do
        local star = h.top3 and "★ " or ""
        local text = star .. (h.headword or "?")
        if h.gloss and h.gloss ~= "" then
            text = text .. " — " .. h.gloss
        end
        local mand = h.quran_freq and h.quran_freq > 0 and ("×" .. h.quran_freq) or ""
        if h.form_no and h.form_no ~= "" then
            mand = mand ~= "" and (mand .. " · " .. h.form_no) or h.form_no
        end
        table.insert(items, {
            text = text,
            mandatory = mand,
            callback = function() M.showEntry(browser, h.id, root) end,
        })
    end
    browser:navigateForward(M.dashRoot(root), items)
end

function M.showEntry(browser, entry_id, root)
    local conn = M.ensureDb(browser.quran)
    if not conn then return end
    local e = M.entry(conn, entry_id)
    if not e then
        notifyWarn(_("Entry not found."))
        return
    end
    local UIManager = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = e.headword or M.dashRoot(root),
        text = M.renderEntryText(e, root),
        justified = false,
    })
end

return M
