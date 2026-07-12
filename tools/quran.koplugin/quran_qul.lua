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
               (SELECT count(*) FROM topic_ayah WHERE topic_id = topic.topic_id)
        FROM topic WHERE topic_id = ?]], { topic_id })[1]
    if not r then return end
    return { topic_id = tonumber(r[1]), name = r[2], arabic_name = r[3],
        description = r[4], wiki_link = r[5], n_ayahs = tonumber(r[6]) }
end

function M.topicChildren(conn, topic_id)
    local out, seen = {}, {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name FROM topic
        WHERE thematic_parent_id = ? OR ontology_parent_id = ?
        ORDER BY name]], { topic_id, topic_id })) do
        local id = tonumber(r[1])
        if not seen[id] then
            seen[id] = true
            table.insert(out, { topic_id = id, name = r[2] })
        end
    end
    return out
end

function M.topicRoots(conn)
    local out = {}
    for _i, r in ipairs(rows(conn, [[
        SELECT topic_id, name FROM topic
        WHERE thematic = 1 AND thematic_parent_id IS NULL
        ORDER BY name]])) do
        table.insert(out, { topic_id = tonumber(r[1]), name = r[2] })
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

-- Jump / read choice for a Hafs-numbered target ayah.
local function ayahDialog(browser, surah, ayah, subtitle)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local quran = browser.quran
    local name = quran.surahName and quran:surahName(surah) or tostring(surah)
    local dialog
    dialog = ButtonDialog:new{
        title = string.format("%s %d:%d", name, surah, ayah)
            .. (subtitle and ("\n" .. subtitle) or ""),
        buttons = {
            {{
                text = _("Go to ayah"),
                callback = function()
                    UIManager:close(dialog)
                    -- gotoAyah wants book-space numbering (juz pattern)
                    local a = ayah > 1 and quran:_hafsToWarsh(surah, ayah) or 1
                    browser:gotoAyah(surah, a)
                end,
            }},
            {{
                text = _("Read (popup)"),
                callback = function()
                    UIManager:close(dialog)
                    browser:closeThen(function()
                        quran:openAyahPopup(surah, ayah)
                    end)()
                end,
            }},
            {{
                text = _("Close"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
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
    M.showThemeItems(browser, list, _("Themes") .. string.format(" %d:%d", surah, ayah))
end

function M.showThemeItems(browser, list, title)
    local items = {}
    for _i, t in ipairs(list) do
        local range = t.ayah_from == t.ayah_to
            and tostring(t.ayah_from)
            or (t.ayah_from .. "–" .. t.ayah_to)
        table.insert(items, {
            text = t.theme,
            mandatory = t.surah .. ":" .. range,
            callback = function()
                ayahDialog(browser, t.surah, t.ayah_from,
                    t.theme .. " (" .. t.surah .. ":" .. range .. ")")
            end,
        })
    end
    browser:navigateForward(title, items)
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
                M.showThemeItems(browser, list, _("Themes") .. " · " .. name)
            end,
        })
    end
    browser:navigateForward(_("Themes"), items)
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
    for _i, c in ipairs(M.topicChildren(conn, topic_id)) do
        local cid = c.topic_id
        table.insert(items, {
            text = "▸ " .. c.name,
            mandatory = _("topic"),
            callback = function() M.showTopic(browser, cid) end,
        })
    end
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

function M.showTopicsRoot(browser)
    local conn, err = M.ensureDb(browser.quran)
    if not conn then notifyWarn(err) return end
    local items = {}
    for _i, t in ipairs(M.topicRoots(conn)) do
        local tid = t.topic_id
        table.insert(items, {
            text = t.name,
            callback = function() M.showTopic(browser, tid) end,
        })
    end
    if #items == 0 then
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
