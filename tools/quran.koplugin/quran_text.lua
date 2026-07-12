--[[--
Quran text & translation access — reads the text-vN.sqlite data package
(built by quran-explorer kb/export/quran_text_extract.py, shipped as the
quran_text asset). Provides the ayah text the browser renders in-window
(unified ayah page, Reader) and, in the search wave, the FTS queries.

Tables (contract, schema_version 1): ayah(riwayah, surah, ayah, text,
text_plain, page, juz) — hafs + warsh, native numbering each; translation
(trans_id, surah, ayah, text) — Hafs numbering; trans_meta; ayah_fts /
trans_fts over pre-normalized text (see quran_norm.lua); meta.
--]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

M.SCHEMA_VERSION = "1"

-- ---------------------------------------------------------------------
-- Database access (same discovery/gate idiom as quran_roots/quran_qul)
-- ---------------------------------------------------------------------

-- Locate text-vN.sqlite: asset-manager install dir first, then the
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
                if entry:match("^text%-v%d+%.sqlite$") then
                    return dir .. "/" .. entry
                end
            end
        end
    end
end

-- Open (and cache) the package; validates meta.schema_version.
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
        return nil, _("Could not open the Quran text database.")
    end
    local ver_ok, ver = pcall(function()
        local stmt = conn:prepare("SELECT value FROM meta WHERE key='schema_version'")
        local row = stmt:step()
        stmt:close()
        return row and tostring(row[1])
    end)
    if not ver_ok or ver ~= M.SCHEMA_VERSION then
        pcall(function() conn:close() end)
        return nil, _("Quran text database has an unsupported format — update the plugin or the data package.")
    end
    M._conn = conn
    M._db_path = path
    logger.info("quran.koplugin: opened text db", path)
    return conn
end

function M.ensureDb(quran)
    local path = M._db_path or M.findDb(quran)
    if not path then
        return nil, _("Quran text package not installed — get it from Library & assets in the Quran browser.")
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
        logger.info("quran.koplugin: text query failed:", err)
    end
    return out
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

--- Ayah row for a riwayah (native numbering). Returns
-- { text, text_plain, page, juz } or nil.
function M.ayah(conn, riwayah, surah, ayah)
    local r = rows(conn, [[
        SELECT text, text_plain, page, juz FROM ayah
        WHERE riwayah = ? AND surah = ? AND ayah = ?]],
        { riwayah, surah, ayah })[1]
    if not r then return end
    return {
        text = r[1],
        text_plain = r[2] ~= nil and tostring(r[2]) or nil,
        page = tonumber(r[3]),
        juz = tonumber(r[4]),
    }
end

--- FTS over the normalized Hafs ayah text. fts_query must already be
-- normalized with quran_norm.norm — norm output contains no quotes or
-- FTS operators, so it is safe to pass bare (terms AND together).
-- Returns { surah, ayah, text } rows (text = plain imlaei, for display).
function M.searchAyahText(conn, fts_query, limit)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT f.surah, f.ayah, a.text_plain
        FROM ayah_fts f
        JOIN ayah a ON a.riwayah = 'hafs'
            AND a.surah = f.surah AND a.ayah = f.ayah
        WHERE ayah_fts MATCH ? ORDER BY rank LIMIT ?]],
        { fts_query, limit or 20 })) do
        table.insert(out, { surah = tonumber(r[1]), ayah = tonumber(r[2]),
            text = r[3] and tostring(r[3]) or "" })
    end
    return out
end

--- FTS over the normalized translation text (same query contract).
function M.searchTranslation(conn, fts_query, limit)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT f.surah, f.ayah, f.trans_id, t.text
        FROM trans_fts f
        JOIN translation t ON t.trans_id = f.trans_id
            AND t.surah = f.surah AND t.ayah = f.ayah
        WHERE trans_fts MATCH ? ORDER BY rank LIMIT ?]],
        { fts_query, limit or 20 })) do
        table.insert(out, { surah = tonumber(r[1]), ayah = tonumber(r[2]),
            trans_id = tostring(r[3]), text = tostring(r[4]) })
    end
    return out
end

--- All shipped translations of a (Hafs-numbered) ayah, with source names.
function M.translations(conn, surah, ayah)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT t.trans_id, m.name, m.lang, t.text
        FROM translation t JOIN trans_meta m ON m.trans_id = t.trans_id
        WHERE t.surah = ? AND t.ayah = ? ORDER BY t.trans_id]],
        { surah, ayah })) do
        table.insert(out, {
            trans_id = tostring(r[1]), name = tostring(r[2]),
            lang = tostring(r[3]), text = tostring(r[4]),
        })
    end
    return out
end

return M
