--[[--
quran_assets.lua — v1.12 hub: Library & assets (the asset manager).

Fetches two manifests from the GitHub release assets:
  dicts.json    (scripts/package_release.py — plugin + dictionary ZIPs)
  catalog.json  (scripts/gen_catalog.py — the released EPUB variants)
and drives the install/update screens inside the Quran browser.

Download + extract follow KOReader's own in-box dictionary downloader
(readerdictionary.lua): NetworkMgr gate, in-process http with socketutil
timeouts, Device:unpackArchive. Integrity: sha256 (ffi/sha2) checked
against the manifest before anything is moved into place. Book identity
follows the catalog contract: variant id = filename stem, with
old_filename as the pre-sweep fallback. GPL-3.0.
]]

local logger = require("logger")
local _ = require("gettext")

local RELEASE_BASE = "https://github.com/zeeyado/quran-ebook/releases/latest/download"
local MANIFEST_URL = RELEASE_BASE .. "/dicts.json"
local CATALOG_URL = RELEASE_BASE .. "/catalog.json"

local M = {}

-- ---------------------------------------------------------------------
-- Pure helpers (unit-tested in scripts/dev_checks/check_plugin_helpers.lua)
-- ---------------------------------------------------------------------

-- Release versions are "MAJOR.MINOR" (package_release.py grammar); numeric
-- part-wise compare so "1.10" > "1.9".
function M.versionNewer(candidate, current)
    local c1, c2 = tostring(candidate or ""):match("^(%d+)%.(%d+)")
    local u1, u2 = tostring(current or ""):match("^(%d+)%.(%d+)")
    if not c1 then return false end
    if not u1 then return true end
    c1, c2, u1, u2 = tonumber(c1), tonumber(c2), tonumber(u1), tonumber(u2)
    if c1 ~= u1 then return c1 > u1 end
    return c2 > u2
end

-- Merge the manifest's dict list with what is on disk and what this
-- manager previously recorded. installed_map: {name -> dir holding the
-- .ifo}; recorded: {name -> {version = "1.1"}} (nil for dicts installed
-- by hand, before the manager existed).
-- Returns a name-sorted list of {entry, dir, state, installed_version}
-- with state: "absent" | "current" | "update" | "unknown".
function M.mergeDictState(manifest_dicts, installed_map, recorded)
    local out = {}
    for _i, d in ipairs(manifest_dicts or {}) do
        local dir = installed_map and installed_map[d.name]
        local rec = recorded and recorded[d.name]
        local have = rec and rec.version
        local state
        if not dir then
            state = "absent"
        elseif not have then
            state = "unknown"
        elseif M.versionNewer(d.version, have) then
            state = "update"
        else
            state = "current"
        end
        table.insert(out, {
            entry = d, dir = dir, state = state, installed_version = have,
        })
    end
    table.sort(out, function(a, b) return a.entry.name < b.entry.name end)
    return out
end

-- Group catalog variants into browsable buckets: riwayah/orthography
-- qualifier + layout label ("Bilingual", "Warsh · Bilingual", …).
function M.groupVariants(variants)
    local groups, order = {}, {}
    for _i, v in ipairs(variants or {}) do
        local ax = v.axes or {}
        local bits = {}
        if ax.riwayah and ax.riwayah ~= "hafs" then
            table.insert(bits, (ax.riwayah:gsub("^%l", string.upper)))
        end
        if ax.orthography == "indopak" then
            table.insert(bits, "IndoPak")
        end
        table.insert(bits, ax.layout_label or ax.layout or "Other")
        local label = table.concat(bits, " · ")
        if not groups[label] then
            groups[label] = {}
            table.insert(order, label)
        end
        table.insert(groups[label], v)
    end
    table.sort(order)
    local out = {}
    for _i, label in ipairs(order) do
        table.sort(groups[label], function(a, b)
            return (a.title_en or a.id) < (b.title_en or b.id)
        end)
        table.insert(out, { label = label, variants = groups[label] })
    end
    return out
end

-- Match a local EPUB filename against the catalog: current name first,
-- then the pre-sweep name (catalog carries old_filename for exactly this).
function M.matchVariantForFile(variants, filename)
    for _i, v in ipairs(variants or {}) do
        if v.filename == filename or v.old_filename == filename then
            return v
        end
    end
end

function M.friendlySize(bytes)
    if type(bytes) ~= "number" then return "" end
    if bytes >= 1024 * 1024 then
        return string.format("%.0f MB", bytes / (1024 * 1024))
    end
    return string.format("%.0f KB", bytes / 1024)
end

-- ---------------------------------------------------------------------
-- Small UI utilities (lazy requires: the module must stay loadable in
-- the dev-check harness with only logger/gettext stubbed)
-- ---------------------------------------------------------------------

local function notify(text, warn)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = text,
        icon = warn and "notice-warning" or nil,
    })
end

-- Paint a progress message, run the blocking task, close the message.
-- fn returns (result) or (nil, err); a thrown error becomes (nil, msg).
local function withInfo(text, fn)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local info = InfoMessage:new{ text = text }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok, r1, r2 = pcall(fn)
    UIManager:close(info)
    if not ok then
        logger.info("quran.koplugin: assets task failed:", r1)
        return nil, tostring(r1)
    end
    return r1, r2
end

local function askRestart(text)
    local UIManager = require("ui/uimanager")
    if UIManager.askForRestart then
        UIManager:askForRestart(text .. "\n" .. _("Restart KOReader now?"))
    else
        notify(text .. "\n" .. _("Restart KOReader to activate it."))
    end
end

-- ---------------------------------------------------------------------
-- Network + integrity
-- ---------------------------------------------------------------------

local function fetchToSink(url, sink)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local http = require("socket.http")
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, http.request{
        url = url,
        sink = sink,
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.info("quran.koplugin: fetch failed:", url, status or code)
        return nil, tostring(status or code or "connection failed")
    end
    return true
end

function M.fetchJSON(url)
    local ltn12 = require("ltn12")
    local JSON = require("json")
    local chunks = {}
    local ok, err = fetchToSink(url, ltn12.sink.table(chunks))
    if not ok then return nil, err end
    local decoded, data = pcall(JSON.decode, table.concat(chunks))
    if not decoded or type(data) ~= "table" then
        return nil, _("invalid manifest")
    end
    return data
end

local function downloadFile(url, dest)
    local ltn12 = require("ltn12")
    local f = io.open(dest, "w")
    if not f then
        return nil, _("Cannot write to:") .. " " .. dest
    end
    local ok, err = fetchToSink(url, ltn12.sink.file(f))
    if not ok then
        os.remove(dest)
        return nil, err
    end
    return true
end

function M.sha256File(path)
    local sha2 = require("ffi/sha2")
    local f = io.open(path, "rb")
    if not f then return nil end
    local append = sha2.sha256()
    while true do
        local chunk = f:read(256 * 1024)
        if not chunk then break end
        append(chunk)
    end
    f:close()
    return append()
end

-- Download entry.url to dest and verify entry.sha256 (when present).
local function verifiedDownload(entry, dest)
    local ok, err = downloadFile(entry.url, dest)
    if not ok then return nil, err end
    if entry.sha256 then
        if M.sha256File(dest) ~= entry.sha256 then
            os.remove(dest)
            return nil, _("Checksum mismatch — the download was corrupted. Please try again.")
        end
    end
    return true
end

-- ---------------------------------------------------------------------
-- Local state: installed dicts, recorded versions, book folders
-- ---------------------------------------------------------------------

local function dictDataDir()
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/data/dict"
end

-- Map dict name -> directory holding its .ifo (recursive scan; manual
-- installs may sit in nested subfolders mirroring output/).
function M.findInstalledDicts(root)
    local lfs = require("libs/libkoreader-lfs")
    local found = {}
    local function scan(dir, depth)
        if depth > 4 then return end
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local path = dir .. "/" .. entry
                if lfs.attributes(path, "mode") == "directory" then
                    scan(path, depth + 1)
                elseif entry:match("%.ifo$") then
                    found[entry:sub(1, -5)] = dir
                end
            end
        end
    end
    pcall(scan, root or dictDataDir(), 0)
    return found
end

local function assetSettings()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/quran_assets.lua")
end

-- kind: "dicts" | "data"
local function recordInstall(kind, name, version)
    local s = assetSettings()
    local rec = s:readSetting(kind) or {}
    rec[name] = { version = version }
    s:saveSetting(kind, rec)
    s:flush()
end

-- Data packages (dicts.json "data" array) install here; quran_roots.lua
-- looks for its lane-vN.sqlite in the same place.
local function dataInstallDir()
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/data/quran"
end

-- Presence probes for manually-installed data packages (file pattern in
-- the install dir), and friendly labels — keyed by manifest name.
local DATA_PROBES = {
    quran_lane = "^lane%-v%d+%.sqlite$",
    quran_qul = "^qul%-v%d+%.sqlite$",
    quran_text = "^text%-v%d+%.sqlite$",
    quran_morphology = "^morphology%-v%d+%.sqlite$",
    quran_connections = "^connections%-v%d+%.sqlite$",
    quran_masaq = "^masaq%-v%d+%.sqlite$",
}
local DATA_LABELS = {
    quran_lane = _("Root explorer data (Lane's Lexicon)"),
    quran_qul = _("QUL connections (themes, topics, similar ayahs)"),
    quran_text = _("Quran text & translation (reader, search)"),
    quran_morphology = _("Word morphology (occurrences, senses, totals)"),
    quran_connections = _("Figures, stories & related ayahs"),
    quran_masaq = _("Word-by-word i'rab (MASAQ · CC BY-NC)"),
}

function M.findInstalledData(root)
    local lfs = require("libs/libkoreader-lfs")
    local found = {}
    local dir = root or dataInstallDir()
    if lfs.attributes(dir, "mode") ~= "directory" then return found end
    pcall(function()
        for entry in lfs.dir(dir) do
            for name, pat in pairs(DATA_PROBES) do
                if entry:match(pat) then
                    found[name] = dir
                end
            end
        end
    end)
    return found
end

-- Downloaded books land in <home>/Quran.
local function booksDir()
    local base = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if not base then
        local ok, fmutil = pcall(require, "apps/filemanager/filemanagerutil")
        base = ok and fmutil.getDefaultDir() or "."
    end
    return base .. "/Quran"
end

-- Set of EPUB filenames present in the books folder and next to the
-- currently open book: {filename -> dir}.
local function findInstalledBooks(quran)
    local lfs = require("libs/libkoreader-lfs")
    local found = {}
    local dirs = { booksDir() }
    local cur = quran.ui and quran.ui.document and quran.ui.document.file
    if cur then
        table.insert(dirs, (cur:match("^(.*)/[^/]+$")))
    end
    for _i, dir in ipairs(dirs) do
        if dir and lfs.attributes(dir, "mode") == "directory" then
            pcall(function()
                for entry in lfs.dir(dir) do
                    if entry:match("%.epub$") then
                        found[entry] = dir
                    end
                end
            end)
        end
    end
    return found
end

-- ---------------------------------------------------------------------
-- Manifest/catalog fetch (session-cached; Refresh clears)
-- ---------------------------------------------------------------------

local function ensureFetched(cache_key, url, label, cb)
    if M[cache_key] then return cb(M[cache_key]) end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local data, err = withInfo(label, function()
            return M.fetchJSON(url)
        end)
        if not data then
            notify(_("Could not fetch the catalog:") .. "\n" .. (err or "?"), true)
            return
        end
        M[cache_key] = data
        cb(data)
    end)
end

local function ensureManifest(cb)
    ensureFetched("_manifest", MANIFEST_URL, _("Fetching dictionary catalog…"), cb)
end

local function ensureCatalog(cb)
    ensureFetched("_catalog", CATALOG_URL, _("Fetching book catalog…"), cb)
end

-- ---------------------------------------------------------------------
-- Dictionaries: install / update
-- ---------------------------------------------------------------------

local function installDict(item, after)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Device = require("device")
        local util = require("util")
        local entry = item.entry
        -- Update in place wherever the dict already lives; new installs
        -- get their own folder. The ZIP carries a "<name>/" root that
        -- unpackArchive strips.
        local target = item.dir or (dictDataDir() .. "/" .. entry.name)
        local tmp = dictDataDir() .. "/" .. entry.filename
        local ok, err = withInfo(
            _("Downloading") .. " " .. entry.name .. " (" .. M.friendlySize(entry.size) .. ")…",
            function()
                local dok, derr = verifiedDownload(entry, tmp)
                if not dok then return nil, derr end
                util.makePath(target)
                local uok, uerr = Device:unpackArchive(tmp, target, true)
                if not uok then return nil, tostring(uerr) end
                return true
            end)
        os.remove(tmp)
        if not ok then
            notify(err or _("Install failed."), true)
            return
        end
        recordInstall("dicts", entry.name, entry.version)
        logger.info("quran.koplugin: installed dict", entry.name, "v" .. entry.version, "->", target)
        if after then after() end
        askRestart(_("Dictionary installed:") .. " " .. (entry.bookname or entry.name) .. "\n"
            .. _("It appears in dictionary lookups after a restart."))
    end)
end

local function buildDictItems(browser, man)
    local merged = M.mergeDictState(
        man.dicts, M.findInstalledDicts(), assetSettings():readSetting("dicts"))
    local items = {}
    for _i, it in ipairs(merged) do
        local e = it.entry
        local mandatory
        if it.state == "update" then
            mandatory = "v" .. (it.installed_version or "?") .. " → v" .. e.version
        elseif it.state == "unknown" then
            mandatory = _("installed")
        elseif it.state == "current" then
            mandatory = "v" .. e.version
        else
            mandatory = "v" .. e.version .. " · " .. M.friendlySize(e.size)
        end
        table.insert(items, {
            text = (it.state ~= "absent" and "✓ " or "") .. (e.bookname or e.name),
            mandatory = mandatory,
            callback = function() M.showDictDialog(browser, it) end,
        })
    end
    return items
end

local function rerenderDicts(browser)
    if not (browser.menu and M._manifest) then return end
    browser.menu:switchItemTable(_("Dictionaries"), buildDictItems(browser, M._manifest))
end

function M.showDictDialog(browser, it)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local e = it.entry
    local action
    if it.state == "absent" then
        action = _("Install") .. " v" .. e.version .. " (" .. M.friendlySize(e.size) .. ")"
    elseif it.state == "update" then
        action = _("Update to") .. " v" .. e.version .. " (" .. M.friendlySize(e.size) .. ")"
    else
        action = _("Reinstall") .. " v" .. e.version .. " (" .. M.friendlySize(e.size) .. ")"
    end
    local dialog
    dialog = ButtonDialog:new{
        title = (e.bookname or e.name) .. "\n" .. e.filename,
        buttons = {
            {{
                text = action,
                callback = function()
                    UIManager:close(dialog)
                    installDict(it, function() rerenderDicts(browser) end)
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

function M.showDicts(browser)
    ensureManifest(function(man)
        browser:navigateForward(_("Dictionaries"), buildDictItems(browser, man))
    end)
end

-- ---------------------------------------------------------------------
-- Data packages (non-StarDict payloads, e.g. the root-explorer extract)
-- ---------------------------------------------------------------------

local function installData(item, after)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Device = require("device")
        local util = require("util")
        local entry = item.entry
        local target = dataInstallDir()
        local tmp = target .. "/" .. entry.filename
        local ok, err = withInfo(
            _("Downloading") .. " " .. entry.name .. " (" .. M.friendlySize(entry.size) .. ")…",
            function()
                util.makePath(target)
                local dok, derr = verifiedDownload(entry, tmp)
                if not dok then return nil, derr end
                local uok, uerr = Device:unpackArchive(tmp, target, true)
                if not uok then return nil, tostring(uerr) end
                return true
            end)
        os.remove(tmp)
        if not ok then
            notify(err or _("Install failed."), true)
            return
        end
        recordInstall("data", entry.name, entry.version)
        logger.info("quran.koplugin: installed data package", entry.name, "v" .. entry.version)
        if after then after() end
        notify(_("Installed:") .. " " .. (DATA_LABELS[entry.name] or entry.name)
            .. "\n" .. _("Ready to use — no restart needed."))
    end)
end

local function buildDataItems(browser, man)
    local merged = M.mergeDictState(
        man.data, M.findInstalledData(), assetSettings():readSetting("data"))
    local items = {}
    for _i, it in ipairs(merged) do
        local e = it.entry
        local mandatory
        if it.state == "update" then
            mandatory = "v" .. (it.installed_version or "?") .. " → v" .. e.version
        elseif it.state == "unknown" then
            mandatory = _("installed")
        elseif it.state == "current" then
            mandatory = "v" .. e.version
        else
            mandatory = "v" .. e.version .. " · " .. M.friendlySize(e.size)
        end
        table.insert(items, {
            text = (it.state ~= "absent" and "✓ " or "") .. (DATA_LABELS[e.name] or e.name),
            mandatory = mandatory,
            callback = function() M.showDataDialog(browser, it) end,
        })
    end
    return items
end

local function rerenderData(browser)
    if not (browser.menu and M._manifest) then return end
    browser.menu:switchItemTable(_("Data packages"), buildDataItems(browser, M._manifest))
end

function M.showDataDialog(browser, it)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local e = it.entry
    local verb = it.state == "absent" and _("Install")
        or (it.state == "update" and _("Update to") or _("Reinstall"))
    local dialog
    dialog = ButtonDialog:new{
        title = (DATA_LABELS[e.name] or e.name) .. "\n" .. e.filename,
        buttons = {
            {{
                text = verb .. " v" .. e.version .. " (" .. M.friendlySize(e.size) .. ")",
                callback = function()
                    UIManager:close(dialog)
                    installData(it, function() rerenderData(browser) end)
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

function M.showData(browser)
    ensureManifest(function(man)
        if not (man.data and #man.data > 0) then
            notify(_("The catalog lists no data packages yet."))
            return
        end
        browser:navigateForward(_("Data packages"), buildDataItems(browser, man))
    end)
end

-- ---------------------------------------------------------------------
-- Books: browse / download / update the open book in place
-- ---------------------------------------------------------------------

local function downloadBook(variant, dest, after)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local util = require("util")
        util.makePath((dest:match("^(.*)/[^/]+$")))
        local tmp = dest .. ".part"
        local ok, err = withInfo(
            _("Downloading book") .. " (" .. M.friendlySize(variant.size) .. ")…",
            function()
                return verifiedDownload(variant, tmp)
            end)
        if not ok then
            os.remove(tmp)
            notify(err or _("Download failed."), true)
            return
        end
        local rok, rerr = os.rename(tmp, dest)
        if not rok then
            os.remove(tmp)
            notify(tostring(rerr), true)
            return
        end
        logger.info("quran.koplugin: downloaded book", variant.id, "->", dest)
        if after then after() end
    end)
end

function M.showBookDialog(browser, v, installed_dir)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local dialog
    local function doDownload()
        UIManager:close(dialog)
        local dest = booksDir() .. "/" .. v.filename
        local lfs = require("libs/libkoreader-lfs")
        local go = function()
            downloadBook(v, dest, function()
                notify(_("Book saved to:") .. "\n" .. dest)
            end)
        end
        if lfs.attributes(dest, "mode") == "file" then
            UIManager:show(ConfirmBox:new{
                text = _("This book already exists in the Quran folder. Overwrite it?"),
                ok_text = _("Overwrite"),
                ok_callback = go,
            })
        else
            go()
        end
    end
    local status_line = v.status ~= "stable" and (" · " .. v.status) or ""
    dialog = ButtonDialog:new{
        title = (v.title and (v.title .. "\n") or "")
            .. (v.title_en or v.id)
            .. "\n" .. M.friendlySize(v.size) .. status_line
            .. (installed_dir and ("\n" .. _("Installed in:") .. " " .. installed_dir) or ""),
        buttons = {
            {{
                text = installed_dir and _("Download again") or _("Download"),
                callback = doDownload,
            }},
            {{
                text = _("Close"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

function M.showBookGroup(browser, group)
    local installed = findInstalledBooks(browser.quran)
    local items = {}
    for _i, v in ipairs(group.variants) do
        local dir = installed[v.filename]
            or (v.old_filename and installed[v.old_filename])
        local mandatory = M.friendlySize(v.size)
        if v.status and v.status ~= "stable" then
            mandatory = v.status .. " · " .. mandatory
        end
        table.insert(items, {
            text = (dir and "✓ " or "") .. (v.title_en or v.id),
            mandatory = mandatory,
            callback = function() M.showBookDialog(browser, v, dir) end,
        })
    end
    browser:navigateForward(group.label, items)
end

-- Update-in-place for the currently open book only (one sha256 — cheap
-- and the sidecar/annotations stay with the unchanged path).
function M.checkThisBook(browser, catalog)
    local quran = browser.quran
    local file = quran.ui and quran.ui.document and quran.ui.document.file
    if not file then
        notify(_("No open book."), true)
        return
    end
    local filename = file:match("([^/]+)$")
    local v = M.matchVariantForFile(catalog.variants, filename)
    if not v then
        notify(_("This book is not in the release catalog (renamed file or custom build)."))
        return
    end
    if not v.sha256 then
        notify(_("The catalog has no published build for this variant yet."))
        return
    end
    local local_sha = withInfo(_("Checking this book…"), function()
        return M.sha256File(file)
    end)
    if local_sha == v.sha256 then
        notify(_("This book is up to date."))
        return
    end
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = (v.title_en or v.id) .. "\n\n"
            .. _("An updated build is available") .. " (" .. M.friendlySize(v.size) .. ").\n"
            .. _("Replace this book in place? Annotations stay; the reading position may shift."),
        ok_text = _("Update"),
        ok_callback = function()
            downloadBook(v, file, function()
                notify(_("Book updated. Reopen it to load the new build."))
            end)
        end,
    })
end

function M.showBooks(browser)
    ensureCatalog(function(cat)
        local items = {
            {
                text = _("This book: check for update"),
                separator = true,
                callback = function() M.checkThisBook(browser, cat) end,
            },
        }
        for _i, group in ipairs(M.groupVariants(cat.variants)) do
            table.insert(items, {
                text = group.label,
                mandatory = tostring(#group.variants),
                callback = function() M.showBookGroup(browser, group) end,
            })
        end
        browser:navigateForward(_("Books"), items)
    end)
end

-- ---------------------------------------------------------------------
-- Plugin self-update
-- ---------------------------------------------------------------------

function M.pluginVersion(path)
    local ok, meta = pcall(dofile, (path or "") .. "/_meta.lua")
    if ok and type(meta) == "table" then return meta.version end
end

local function installPlugin(browser, p)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Device = require("device")
        local ffiutil = require("ffi/util")
        local quran = browser.quran
        local root = quran.path:match("^(.*)/[^/]+$")
        -- Neither name ends in ".koplugin", so KOReader never loads them.
        local staging = root .. "/quran.koplugin.new"
        local backup = root .. "/quran.koplugin.bak"
        local tmp = root .. "/" .. p.filename
        local ok, err = withInfo(_("Downloading plugin") .. " v" .. p.version .. "…", function()
            local dok, derr = verifiedDownload(p, tmp)
            if not dok then return nil, derr end
            pcall(ffiutil.purgeDir, staging)
            local uok, uerr = Device:unpackArchive(tmp, staging, true)
            if not uok then return nil, tostring(uerr) end
            if M.pluginVersion(staging) ~= p.version then
                return nil, _("The extracted plugin is not the expected version.")
            end
            return true
        end)
        os.remove(tmp)
        if not ok then
            pcall(ffiutil.purgeDir, staging)
            notify(err or _("Update failed."), true)
            return
        end
        pcall(ffiutil.purgeDir, backup)
        if not os.rename(quran.path, backup) then
            pcall(ffiutil.purgeDir, staging)
            notify(_("Could not move the old plugin out of the way."), true)
            return
        end
        if not os.rename(staging, quran.path) then
            os.rename(backup, quran.path)
            notify(_("Update failed; the previous version was restored."), true)
            return
        end
        logger.info("quran.koplugin: plugin updated to v" .. p.version)
        askRestart(_("Plugin updated to") .. " v" .. p.version .. ".")
    end)
end

function M.checkPluginUpdate(browser)
    ensureManifest(function(man)
        local p = man.plugin
        if not p then
            notify(_("The manifest has no plugin entry."), true)
            return
        end
        local quran = browser.quran
        local cur = M.pluginVersion(quran.path)
        if not M.versionNewer(p.version, cur) then
            notify(_("The plugin is up to date") .. " (v" .. (cur or "?") .. ").")
            return
        end
        -- Dev installs (the repo symlink, or a git checkout) must never
        -- be overwritten by the updater.
        local lfs = require("libs/libkoreader-lfs")
        if (lfs.symlinkattributes and lfs.symlinkattributes(quran.path, "mode") == "link")
            or lfs.attributes(quran.path .. "/.git", "mode") == "directory" then
            notify("v" .. p.version .. " " .. _("is available, but this is a development install (symlink or git checkout) — update from the repository."), true)
            return
        end
        local UIManager = require("ui/uimanager")
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("Update Quran plugin") .. " v" .. (cur or "?") .. " → v" .. p.version
                .. " (" .. M.friendlySize(p.size) .. ")?",
            ok_text = _("Update"),
            ok_callback = function() installPlugin(browser, p) end,
        })
    end)
end

-- ---------------------------------------------------------------------
-- Entry screen
-- ---------------------------------------------------------------------

function M.showLibrary(browser)
    local items = {
        {
            text = _("Dictionaries & resources"),
            callback = function() M.showDicts(browser) end,
        },
        {
            text = _("Data packages"),
            callback = function() M.showData(browser) end,
        },
        {
            text = _("Books (EPUB downloads)"),
            callback = function() M.showBooks(browser) end,
        },
        {
            -- relocated from the quick panel (design D7: panel = launcher)
            text = _("Restore book data"),
            callback = function()
                if browser.quran and browser.quran.restoreBookData then
                    browser.quran:restoreBookData()
                end
            end,
        },
        {
            text = _("Check for plugin update"),
            separator = true,
            callback = function() M.checkPluginUpdate(browser) end,
        },
        {
            text = _("Refresh catalogs"),
            callback = function()
                M._manifest = nil
                M._catalog = nil
                notify(_("Catalogs cleared — they will be re-fetched on next use."))
            end,
        },
    }
    browser:navigateForward(_("Library & assets"), items)
end

return M
