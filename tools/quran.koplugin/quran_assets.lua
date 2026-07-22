--[[--
quran_assets.lua — v1.12 hub: Library & assets (the asset manager).

Fetches two manifests from the GitHub release assets:
  dicts.json    (scripts/package_release.py — plugin + dictionary ZIPs)
  catalog.json  (scripts/gen_catalog.py — the released EPUB variants)
and drives the install/update screens inside the Quran browser.

Download + extract follow KOReader's own in-box dictionary downloader
(readerdictionary.lua): NetworkMgr gate, in-process http with socketutil
timeouts, unpackArchive (Device method, ffi/archiver fallback when the
device build lacks it). Integrity: sha256 (ffi/sha2) checked
against the manifest before anything is moved into place. Book identity
follows the catalog contract: variant id = filename stem, with
old_filename as the pre-sweep fallback.

Asset source: "official" (releases/latest/download) or "test" (the
rolling test-build pre-release — unvalidated CI builds, for beta
testing; a pre-release can never be `latest`, so it needs an explicit
switch). Manifests embed absolute official URLs, so every fetched URL
is re-based through M.resolveUrl. GPL-3.0.
]]

local logger = require("logger")
local _ = require("gettext")

local OFFICIAL_BASE = "https://github.com/zeeyado/quran-ebook/releases/latest/download"
local TEST_BASE = "https://github.com/zeeyado/quran-ebook/releases/download/test-build"

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

-- ---- Shared facet taxonomy (owner presentation pass 2026-07-20) ------
-- The catalog is the single source: languages map (code -> {en, native}),
-- stamped shelf labels (axes.layout_shelf / script_shelf), and the
-- translator-first entry-title formula — identical to scripts/gen_opds.py
-- so the plugin's Books screens and the OPDS feeds present the SAME tree.

-- Language code of the variant's language entry way; nil for bare Arabic.
-- Glosses-only wbw surfaces under its GLOSS language.
function M.variantLang(v)
    local a = v.axes or {}
    local layer = a.translation or a.tafsir_as_text
    return (layer and layer.language) or a.gloss_language
end

-- "English · native" shelf title; collapses when identical/unknown.
function M.langShelfTitle(code, langs)
    local L = langs and langs[code]
    local en = (L and L.en) or code
    local native = L and L.native
    if not native or native == "" or native == en then return en end
    return en .. " · " .. native
end

-- Split a variant into its identity NAME (translator/edition, or nil for
-- bare Arabic) and the ordered FACETS list (language, script, layout, gloss,
-- tafsir); entryTitle joins them with " · ". omit: "lang" | "layout" |
-- "script" | nil — a shelf entry never repeats the axis its shelf fixes
-- (nil = the full neutral title). MUST stay identical to gen_catalog.py
-- _title_en (neutral) and gen_opds.py _entry_title (scoped).
local ORTHO_LABELS = { uthmani = "Uthmani", indopak = "IndoPak" }

--- Canonical book title (owner formula 2026-07-22): LANGUAGE-first, always
--- complete —
---   <Language | "Arabic"> · <translator/tafsir> · <riwayah> · <script> · <layout>
--- + gloss/tafsir-popup tails. Riwayah + script always show (even the Hafs ·
--- Uthmani default). omit drops the shelf's fixed axis.
function M.entryTitle(v, langs, omit)
    local a = v.axes or {}
    local layer = a.translation or a.tafsir_as_text
    local parts = {}
    -- 1. language (translation/gloss language) — or "Arabic" for bare Arabic
    if omit ~= "lang" then
        local code = (layer and layer.language) or a.gloss_language
        if code then
            local L = langs and langs[code]
            table.insert(parts, (L and L.en) or code)
        else
            table.insert(parts, _("Arabic"))
        end
    end
    -- 2. translator / tafsir edition name
    if layer and layer.name then table.insert(parts, layer.name) end
    -- 3. riwayah + script (always present, unless the shelf fixes script)
    if omit ~= "script" then
        if a.riwayah then table.insert(parts, (a.riwayah:gsub("^%l", string.upper))) end
        local ortho = ORTHO_LABELS[a.orthography]
        if ortho then table.insert(parts, ortho) end
    end
    -- 4. layout / type
    local glosses_only = a.gloss_language and not layer
    if omit ~= "layout" then
        local layout = a.layout_label or ""
        if glosses_only then layout = layout .. " · glosses only" end
        -- a named popup tafsir replaces the generic layout mention
        if a.tafsir_name then layout = layout:gsub(" %+ tafsir popup", "") end
        if layout ~= "" then table.insert(parts, layout) end
    elseif glosses_only then
        table.insert(parts, "glosses only")
    end
    -- 5. gloss language (only when it differs from the translation)
    if layer and a.gloss_language and a.gloss_language ~= layer.language then
        local L = langs and langs[a.gloss_language]
        table.insert(parts, ((L and L.en) or a.gloss_language) .. " glosses")
    end
    -- 6. named popup tafsir
    if a.tafsir_name then table.insert(parts, a.tafsir_name .. " popup") end
    if #parts == 0 then return v.id or "?" end
    return table.concat(parts, " · ")
end

-- Language shelves, sorted by English title (parity with languages.xml).
function M.groupByLanguage(variants, langs)
    local by = {}
    for _i, v in ipairs(variants or {}) do
        local c = M.variantLang(v)
        if c then
            if not by[c] then
                by[c] = { code = c, label = M.langShelfTitle(c, langs),
                          variants = {} }
            end
            table.insert(by[c].variants, v)
        end
    end
    local out = {}
    for _c, g in pairs(by) do table.insert(out, g) end
    table.sort(out, function(x, y) return x.label:lower() < y.label:lower() end)
    return out
end

-- Shelves from a stamped label field ("layout_shelf" | "script_shelf"),
-- alphabetical (parity with layouts.xml/scripts.xml). Degrades to the
-- raw axes when an older catalog lacks the stamp.
function M.groupByShelf(variants, field)
    local by, order = {}, {}
    for _i, v in ipairs(variants or {}) do
        local a = v.axes or {}
        local label = a[field]
        if not label then
            label = (field == "layout_shelf") and (a.layout_label or "?")
                or ((a.riwayah or "?") .. " · " .. (a.orthography or "?"))
        end
        if not by[label] then
            by[label] = {}
            table.insert(order, label)
        end
        table.insert(by[label], v)
    end
    table.sort(order, function(x, y) return x:lower() < y:lower() end)
    local out = {}
    for _i, label in ipairs(order) do
        table.insert(out, { label = label, variants = by[label] })
    end
    return out
end

-- Match a local EPUB filename against the catalog: current name first,
-- then the pre-sweep name (catalog carries old_filename for exactly this).
function M.matchVariantForFile(variants, filename)
    -- Exact current-name match wins over an old_filename match, so a live
    -- edition whose filename happens to equal some OTHER variant's pre-sweep
    -- name is never mis-flagged as outdated (owner review 2026-07-22).
    for _i, v in ipairs(variants or {}) do
        if v.filename == filename then return v end
    end
    for _i, v in ipairs(variants or {}) do
        if v.old_filename == filename then return v end
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

-- Prepare a URL for the active asset source: trim stray whitespace and
-- newlines (input dialogs and hand-edited manifests carry them — a
-- trailing newline makes GitHub answer 400 Bad Request), and in "test"
-- mode re-base official-release URLs onto the test-build pre-release
-- (dicts.json/catalog.json embed absolute releases/latest paths).
function M.resolveUrl(url, source)
    url = tostring(url or ""):match("^%s*(.-)%s*$")
    if source == "test" and url:sub(1, #OFFICIAL_BASE) == OFFICIAL_BASE then
        url = TEST_BASE .. url:sub(#OFFICIAL_BASE + 1)
    end
    return url
end

-- ---------------------------------------------------------------------
-- Network + integrity
-- ---------------------------------------------------------------------

local function fetchToSink(url, sink)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local http = require("socket.http")
    url = M.resolveUrl(url, M.assetSource())
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

-- KOReader's bundled JSON decodes null to a FUNCTION sentinel (truthy!) —
-- "axes": {"translation": null} would otherwise index like a real layer.
-- JSON can't encode functions, so any function value IS a null: drop it.
function M.scrubNulls(t)
    if type(t) ~= "table" then return t end
    for k, v in pairs(t) do
        if type(v) == "function" then
            t[k] = nil
        elseif type(v) == "table" then
            M.scrubNulls(v)
        end
    end
    return t
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
    return M.scrubNulls(data)
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
-- Archive extraction: Device:unpackArchive with a plugin-local fallback
-- ---------------------------------------------------------------------
-- Device:unpackArchive has no API-stability guarantee and has been
-- reshaped repeatedly upstream; on some device builds (an older/stale or
-- forked KOReader) the method is simply absent — the symptom that
-- motivated this helper was "attempt to call method 'unpackArchive' (a
-- nil value)" on Android and Kobo while macOS worked. When the Device
-- method is missing we fall back to a faithful port of its algorithm
-- driving ffi/archiver's Archiver.Reader directly — the same primitive
-- Device:unpackArchive itself wraps, present on every platform that
-- boots KOReader at all (generic/device.lua does an unconditional
-- top-level require("ffi/archiver"); libarchive is statically linked
-- into the Android/Kobo monolibtic builds). Contract mirrors the Device
-- method, including removing `archive` on success (each call site's own
-- os.remove(tmp) afterward is then a harmless no-op on a gone file).
local function unpackArchive(archive, extract_to, with_stripped_root)
    local Device = require("device")
    if type(Device.unpackArchive) == "function" then
        return Device:unpackArchive(archive, extract_to, with_stripped_root)
    end

    -- Device method absent on this build — record the version for triage
    -- and extract via ffi/archiver directly (ported from device.lua).
    local rev
    pcall(function() rev = require("version"):getCurrentRevision() end)
    logger.info("quran.koplugin: Device:unpackArchive absent (KOReader",
        tostring(rev), ") — using ffi/archiver fallback")
    local aok, Archiver = pcall(require, "ffi/archiver")
    if not aok or not Archiver or not Archiver.Reader then
        return false, _("Extracting the archive failed: this KOReader build has no archive support.")
    end
    local arc = Archiver.Reader:new()
    local ok = arc:open(archive)
    if ok then
        for entry in arc:iterate() do
            local dest_path = entry.path
            if with_stripped_root then
                local __, tail = dest_path:match("([^/]*)/*(.*)")
                if tail then
                    -- Non-root: strip one level.
                    dest_path = tail
                elseif entry.mode == "directory" then
                    -- Root directory: ignore.
                    goto continue
                else -- luacheck: ignore 542
                    -- Root non-directory: don't strip.
                end
            end
            if not arc:extractToPath(entry.path, extract_to .. "/" .. dest_path) then
                break
            end
            ::continue::
        end
        ok = not arc.err
    end
    if not ok then
        local err = tostring(arc.err)
        arc:close()
        return false, _("Extracting the archive failed:") .. "\n\n(" .. err .. ")"
    end
    arc:close()
    os.remove(archive)
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

local function escPat(s)
    return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0"))
end

-- Uninstall a StarDict: delete the whole `<name>.*` fileset in its dir
-- (`.ifo/.dict[.dz]/.idx/.syn`) PLUS the stale `<name>.idx.oft` offset
-- cache KOReader builds beside it. Prunes the folder only when it is the
-- dict's own install dir (`.../<name>`) and now empty — never a shared or
-- nested manual-install folder holding other dictionaries. Returns the
-- number of files removed.
function M.removeDictFiles(name, dir)
    local lfs = require("libs/libkoreader-lfs")
    if not (name and dir) or lfs.attributes(dir, "mode") ~= "directory" then
        return 0
    end
    local prefix = "^" .. escPat(name) .. "%."   -- "<name>." — a literal dot
    local removed = 0
    pcall(function()
        for entry in lfs.dir(dir) do
            if entry:match(prefix) then
                if os.remove(dir .. "/" .. entry) then removed = removed + 1 end
            end
        end
    end)
    if dir:match("/" .. escPat(name) .. "$") then
        pcall(function() lfs.rmdir(dir) end)   -- no-op unless empty
    end
    return removed
end

local function assetSettings()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/quran_assets.lua")
end

-- Active asset source: "official" | "test" (persisted; default official).
function M.assetSource()
    return assetSettings():readSetting("asset_source") == "test" and "test" or "official"
end

function M.setAssetSource(src)
    local s = assetSettings()
    s:saveSetting("asset_source", src == "test" and "test" or "official")
    s:flush()
    -- session-cached catalogs belong to the previous source
    M._manifest, M._catalog = nil, nil
end

local function assetBase()
    return M.assetSource() == "test" and TEST_BASE or OFFICIAL_BASE
end

-- kind: "dicts" | "data"
local function recordInstall(kind, name, version)
    local s = assetSettings()
    local rec = s:readSetting(kind) or {}
    rec[name] = { version = version }
    s:saveSetting(kind, rec)
    s:flush()
end

-- Drop the install record so the asset reverts to "absent" (uninstall).
local function forgetInstall(kind, name)
    local s = assetSettings()
    local rec = s:readSetting(kind)
    if rec and rec[name] ~= nil then
        rec[name] = nil
        s:saveSetting(kind, rec)
        s:flush()
    end
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

-- Uninstall a data package: delete every file in its dir matching the
-- package's probe pattern (e.g. all `lane-v*.sqlite`, superseded versions
-- included). Returns the number of files removed.
function M.removeDataFiles(name, dir)
    local lfs = require("libs/libkoreader-lfs")
    local pat = DATA_PROBES[name]
    if not (pat and dir) or lfs.attributes(dir, "mode") ~= "directory" then
        return 0
    end
    local removed = 0
    pcall(function()
        for entry in lfs.dir(dir) do
            if entry:match(pat) then
                if os.remove(dir .. "/" .. entry) then removed = removed + 1 end
            end
        end
    end)
    return removed
end

-- Downloaded books land in the configured books folder — the SAME
-- setting the book picker uses (Quran:_booksFolder() in main.lua is the
-- single source of truth). Previously this hardcoded <home>/Quran and
-- ignored the setting, so downloads always landed in <home>/Quran even
-- when the user had pointed the plugin elsewhere. Falls back to the
-- KOReader home dir, then the file manager's default dir, then ".", only
-- when _booksFolder() yields nothing (no setting AND no home configured).
local function booksDir(quran)
    local set = quran and quran._booksFolder and quran:_booksFolder()
    if set and set ~= "" then return set end
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
    local dirs = { booksDir(quran) }
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
-- Manifest/catalog fetch — session cache + a DISK cache for the books
-- catalog, so My books shows full titles every session with NO re-fetch.
-- (The dicts/data manifest stays session-only: its versions drive the
-- install/update state, which must not go stale.) Refresh clears both.
-- ---------------------------------------------------------------------

-- Dedicated LuaSettings store for the persisted catalog (kept out of the
-- main quran_assets settings so it never bloats them).
local function assetCacheStore()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/quran_asset_cache.lua")
end

local function cacheKeyFor(cache_key)   -- "_catalog" -> "catalog_official"
    return cache_key:gsub("^_", "") .. "_" .. M.assetSource()
end

function M.readAssetCache(cache_key)
    local ok, store = pcall(assetCacheStore)
    if not ok or not store then return nil end
    local data = store:readSetting(cacheKeyFor(cache_key))
    return (type(data) == "table") and data or nil
end

function M.writeAssetCache(cache_key, data)
    local ok, store = pcall(assetCacheStore)
    if not ok or not store then return end
    store:saveSetting(cacheKeyFor(cache_key), data)
    store:flush()
end

function M.clearAssetCache()
    local ok, store = pcall(assetCacheStore)
    if not ok or not store then return end
    for _i, k in ipairs({ "catalog", "manifest" }) do
        store:delSetting(k .. "_official")
        store:delSetting(k .. "_test")
    end
    store:flush()
end

-- Catalog for a LOCAL list (My books): session cache, else the disk cache —
-- never the network. nil only when it has genuinely never been fetched.
function M.cachedCatalog()
    if not M._catalog then M._catalog = M.readAssetCache("_catalog") end
    return M._catalog
end

local function ensureFetched(cache_key, url, label, cb, force)
    -- only the books catalog persists to disk (see the section note)
    local persist = (cache_key == "_catalog")
    if not force then
        if M[cache_key] then return cb(M[cache_key]) end
        if persist then
            local disk = M.readAssetCache(cache_key)
            if disk then M[cache_key] = disk; return cb(disk) end
        end
    end
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
        if persist then M.writeAssetCache(cache_key, data) end
        cb(data)
    end)
end

local function ensureManifest(cb)
    ensureFetched("_manifest", assetBase() .. "/dicts.json", _("Fetching dictionary catalog…"), cb)
end

-- force=true bypasses both caches for a fresh check (the update checker).
local function ensureCatalog(cb, force)
    ensureFetched("_catalog", assetBase() .. "/catalog.json", _("Fetching book catalog…"), cb, force)
end

-- ---------------------------------------------------------------------
-- Dictionaries: install / update
-- ---------------------------------------------------------------------

local function installDict(item, after)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
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
                local uok, uerr = unpackArchive(tmp, target, true)
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

local function uninstallDict(browser, it)
    local e = it.entry
    local removed = M.removeDictFiles(e.name, it.dir)
    forgetInstall("dicts", e.name)
    logger.info("quran.koplugin: uninstalled dict", e.name,
        "(" .. removed .. " files)", "from", tostring(it.dir))
    rerenderDicts(browser)
    askRestart(_("Dictionary removed:") .. " " .. (e.bookname or e.name) .. "\n"
        .. _("It leaves dictionary lookups after a restart."))
end

function M.showDictDialog(browser, it)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
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
    local buttons = {
        {{
            text = action,
            callback = function()
                UIManager:close(dialog)
                installDict(it, function() rerenderDicts(browser) end)
            end,
        }},
    }
    if it.state ~= "absent" then
        table.insert(buttons, {{
            text = _("Uninstall"),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Remove this dictionary from the device?") .. "\n"
                        .. (e.bookname or e.name),
                    ok_text = _("Uninstall"),
                    ok_callback = function() uninstallDict(browser, it) end,
                })
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    }})
    dialog = ButtonDialog:new{
        title = (e.bookname or e.name) .. "\n" .. e.filename,
        buttons = buttons,
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
                local uok, uerr = unpackArchive(tmp, target, true)
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

-- Q4 reframe: the "Content & features" screen = the feature-named data
-- packages, then a "Dictionaries (N)" drill-in into the large,
-- content-named dictionary list (kept behind a door, not flattened).
local function buildContentItems(browser, man)
    local items = buildDataItems(browser, man)
    local n = (man and man.dicts) and #man.dicts or 0
    if n > 0 then
        if #items > 0 then items[#items].separator = true end
        table.insert(items, {
            text = _("Dictionaries") .. " (" .. n .. ")",
            callback = function() M.showDicts(browser) end,
        })
    end
    return items
end

local function rerenderData(browser)
    if not (browser.menu and M._manifest) then return end
    browser.menu:switchItemTable(_("Content & features"), buildContentItems(browser, M._manifest))
end

local function uninstallData(browser, it)
    local e = it.entry
    local removed = M.removeDataFiles(e.name, it.dir)
    forgetInstall("data", e.name)
    logger.info("quran.koplugin: uninstalled data package", e.name,
        "(" .. removed .. " files)", "from", tostring(it.dir))
    rerenderData(browser)
    notify(_("Removed:") .. " " .. (DATA_LABELS[e.name] or e.name)
        .. "\n" .. _("The feature stops using it after a restart."))
end

function M.showDataDialog(browser, it)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local e = it.entry
    local verb = it.state == "absent" and _("Install")
        or (it.state == "update" and _("Update to") or _("Reinstall"))
    local dialog
    local buttons = {
        {{
            text = verb .. " v" .. e.version .. " (" .. M.friendlySize(e.size) .. ")",
            callback = function()
                UIManager:close(dialog)
                installData(it, function() rerenderData(browser) end)
            end,
        }},
    }
    if it.state ~= "absent" then
        table.insert(buttons, {{
            text = _("Uninstall"),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Remove this data package from the device?") .. "\n"
                        .. (DATA_LABELS[e.name] or e.name),
                    ok_text = _("Uninstall"),
                    ok_callback = function() uninstallData(browser, it) end,
                })
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    }})
    dialog = ButtonDialog:new{
        title = (DATA_LABELS[e.name] or e.name) .. "\n" .. e.filename,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M.showData(browser)
    ensureManifest(function(man)
        local has_data = man.data and #man.data > 0
        local has_dicts = man.dicts and #man.dicts > 0
        if not (has_data or has_dicts) then
            notify(_("The catalog lists no content packages yet."))
            return
        end
        browser:navigateForward(_("Content & features"), buildContentItems(browser, man))
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
    local cat = M.cachedCatalog()
    local langs = cat and cat.languages or {}
    local function doDownload()
        UIManager:close(dialog)
        local dest = booksDir(browser.quran) .. "/" .. v.filename
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
            .. (M.entryTitle(v, langs, nil) or v.id)
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

-- Variant rows for one shelf: ✓ installed marker, context-scoped titles
-- (omit = the axis the shelf fixes), sorted by the rendered title —
-- exactly the order the OPDS shelf shows.
local function variantItems(browser, variants, langs, omit)
    local installed = findInstalledBooks(browser.quran)
    local rows = {}
    for _i, v in ipairs(variants) do table.insert(rows, v) end
    table.sort(rows, function(x, y)
        return M.entryTitle(x, langs, omit):lower()
            < M.entryTitle(y, langs, omit):lower()
    end)
    local items = {}
    for _i, v in ipairs(rows) do
        local dir = installed[v.filename]
            or (v.old_filename and installed[v.old_filename])
        local mandatory = M.friendlySize(v.size)
        if v.status and v.status ~= "stable" then
            mandatory = v.status .. " · " .. mandatory
        end
        -- The canonical dot-joined title; the screen is pushed multiline so a
        -- long title soft-wraps over two lines instead of clipping against
        -- the size column (a guaranteed line split needs a custom MenuItem —
        -- Phase 4, with covers).
        local text = (dir and "✓ " or "") .. M.entryTitle(v, langs, omit)
        table.insert(items, {
            text = text,
            mandatory = mandatory,
            callback = function() M.showBookDialog(browser, v, dir) end,
        })
    end
    return items
end

-- A facet row that opens a shelf list, each shelf opening its variants.
local function shelfFacetItem(browser, label, groups, langs, omit)
    return {
        text = label,
        mandatory = tostring(#groups),
        callback = function()
            local sub = {}
            for _i, g in ipairs(groups) do
                table.insert(sub, {
                    text = g.label,
                    mandatory = tostring(#g.variants),
                    callback = function()
                        browser:navigateForward(g.label,
                            variantItems(browser, g.variants, langs, omit),
                            nil, { multiline = true })
                    end,
                })
            end
            browser:navigateForward(label, sub)
        end,
    }
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
        text = (M.entryTitle(v, catalog.languages or {}, nil) or v.id) .. "\n\n"
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

-- Books root = the same facet tree as the OPDS catalog (owner 2026-07-20:
-- full parity; the old flat riwayah·layout groups are gone).
function M.showBooks(browser)
    ensureCatalog(function(cat)
        local langs = cat.languages or {}
        local vs = cat.variants or {}
        local arabic, tafsir = {}, {}
        for _i, v in ipairs(vs) do
            local a = v.axes or {}
            if not M.variantLang(v) then table.insert(arabic, v) end
            if a.tafsir or a.tafsir_as_text then table.insert(tafsir, v) end
        end
        local items = {
            -- (the per-open-book "check for update" moved to My books →
            -- "Check all books for updates", a library-wide check)
            shelfFacetItem(browser, _("By language"),
                M.groupByLanguage(vs, langs), langs, "lang"),
            shelfFacetItem(browser, _("By layout"),
                M.groupByShelf(vs, "layout_shelf"), langs, "layout"),
            shelfFacetItem(browser, _("By script"),
                M.groupByShelf(vs, "script_shelf"), langs, "script"),
            {
                text = _("Arabic only"),
                mandatory = tostring(#arabic),
                callback = function()
                    browser:navigateForward(_("Arabic only"),
                        variantItems(browser, arabic, langs, nil),
                        nil, { multiline = true })
                end,
            },
            {
                text = _("With tafsir"),
                mandatory = tostring(#tafsir),
                callback = function()
                    browser:navigateForward(_("With tafsir"),
                        variantItems(browser, tafsir, langs, nil),
                        nil, { multiline = true })
                end,
            },
        }
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
            local uok, uerr = unpackArchive(tmp, staging, true)
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

-- ---------------------------------------------------------------------
-- My books: the inventory of Quran editions you actually have (Phase 1 =
-- list + open; manage actions + migration land next). Scope = the
-- configured books folder only (owner 2026-07-22: test copies kept
-- elsewhere stay out). Full metadata across two lines, no clipping.
-- ---------------------------------------------------------------------

-- EPUBs in the configured books folder: filename -> dir. Distinct from
-- findInstalledBooks, which also folds in the open book's own directory
-- for the catalog's ✓ marker; the inventory is folder-scoped.
local function scanBooksFolder(quran)
    local lfs = require("libs/libkoreader-lfs")
    local dir = booksDir(quran)
    local found = {}
    if dir and lfs.attributes(dir, "mode") == "directory" then
        pcall(function()
            for entry in lfs.dir(dir) do
                if entry:match("%.epub$") then found[entry] = dir end
            end
        end)
    end
    return found
end

-- Last-opened timestamps from KOReader's reading history: path -> time.
local function historyTimes()
    local map = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory and ReadHistory.hist then
        for _i, item in ipairs(ReadHistory.hist) do
            if item.file and item.time
                    and (not map[item.file] or item.time > map[item.file]) then
                map[item.file] = item.time
            end
        end
    end
    return map
end

-- Reading progress (0..1), or nil if the book was never opened (no
-- sidecar). Read-only.
local function bookProgress(path)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings or not DocSettings.hasSidecarFile then return nil end
    if not DocSettings:hasSidecarFile(path) then return nil end
    local pct
    pcall(function()
        local ds = DocSettings:open(path)
        pct = ds and ds:readSetting("percent_finished")
    end)
    return pct
end

-- Classify ONE installed EPUB against the catalog (pure — no IO): the two
-- display lines + outdated status. installed = the folder's filename->dir
-- set (to see whether the up-to-date twin is already present). variants/
-- langs may be nil (offline): the row degrades to a filename title.
function M.classifyBook(filename, installed, variants, langs)
    local v = variants and M.matchVariantForFile(variants, filename) or nil
    local rec = { filename = filename, variant = v }
    if v then
        -- Compute the title from axes with the plugin's own entryTitle (byte-
        -- identical to the catalog's title_en) rather than reading the
        -- stamped title_en — so a format change shows in My books WITHOUT a
        -- catalog republish; the catalog/OPDS regen is only for external
        -- feeds (owner 2026-07-22).
        rec.title = M.entryTitle(v, langs or {}, nil)
        rec.size = v.size
        -- old-scheme file (its name is the variant's pre-sweep name): the
        -- up-to-date edition is v.filename, possibly already downloaded.
        if v.old_filename == filename and v.filename ~= filename then
            rec.outdated = true
            rec.new_name = v.filename
            rec.new_present = (installed and installed[v.filename]) ~= nil
        end
    else
        rec.title = filename:gsub("%.epub$", "")
    end
    return rec
end

-- The inventory: every EPUB in the books folder, classified + dated +
-- progressed, sorted most-recently-opened first (never-opened last, by
-- title). catalog may be nil (offline) -> filename titles, no status.
function M.bookInventory(quran, catalog)
    local ffiutil = require("ffi/util")
    local installed = scanBooksFolder(quran)
    local variants = catalog and catalog.variants or nil
    local langs = catalog and catalog.languages or {}
    local times = historyTimes()
    local recs = {}
    for filename, dir in pairs(installed) do
        local rec = M.classifyBook(filename, installed, variants, langs)
        rec.dir = dir
        -- Canonicalize: KOReader keys reading history + docsettings by the
        -- realpath'd path, so a symlinked/relative books folder would
        -- otherwise miss last-opened + progress (owner API review 2026-07-22).
        local raw = dir .. "/" .. filename
        rec.path = ffiutil.realpath(raw) or raw
        rec.last_opened = times[rec.path]
        rec.percent = bookProgress(rec.path)
        recs[#recs + 1] = rec
    end
    table.sort(recs, function(a, b)
        local ta, tb = a.last_opened, b.last_opened
        if ta and tb then return ta > tb end
        if (ta ~= nil) ~= (tb ~= nil) then return ta ~= nil end  -- opened first
        return (a.title or ""):lower() < (b.title or ""):lower()
    end)
    return recs
end

-- Check EVERY recognized book in the library against the catalog: a
-- filename-scheme update (old_filename → the renamed edition) or a content
-- update (the file's sha256 differs from the published build). On-demand,
-- reports a summary (owner 2026-07-22 — replaces the per-open-book check).
-- The actual update/migrate flow is the next pass; for now it points you to
-- Get books.
function M.checkAllUpdates(browser)
    ensureCatalog(function(cat)   -- force=true below: a check must be fresh
        local recs = M.bookInventory(browser.quran, cat)
        local renamed, content = {}, {}
        withInfo(_("Checking your books for updates…"), function()
            for _i, r in ipairs(recs) do
                if r.outdated then
                    table.insert(renamed, r.title)
                elseif r.variant and r.variant.sha256 then
                    local local_sha = M.sha256File(r.path)
                    if local_sha and local_sha ~= r.variant.sha256 then
                        table.insert(content, r.title)
                    end
                end
            end
        end)
        local n = #renamed + #content
        if n == 0 then
            notify(_("All your books are up to date."))
            return
        end
        local lines = { _("Updates available") .. " (" .. n .. "):", "" }
        for _i, t in ipairs(renamed) do
            table.insert(lines, "\226\128\162 " .. t .. " (" .. _("renamed edition") .. ")")
        end
        for _i, t in ipairs(content) do
            table.insert(lines, "\226\128\162 " .. t)
        end
        table.insert(lines, "")
        table.insert(lines, _("Re-download the newer build from Get books (one-tap updating lands in the next pass)."))
        notify(table.concat(lines, "\n"))
    end, true)
end

-- Rows for the My books screen (exposed for the dev-check harness; factored
-- so the offline "fetch catalog" action can rebuild the screen in place).
function M.myBooksItems(browser)
    local cat = M.cachedCatalog()   -- session OR disk cache; never the network
    local recs = M.bookInventory(browser.quran, cat)
    local items = {}
    -- Top actions (owner 2026-07-22): get more, and a library-wide update
    -- check (replaces the old per-open-book "check for update").
    table.insert(items, {
        text = _("Get more books") .. " \226\134\146",   -- →
        callback = function() M.showBooks(browser) end,
    })
    table.insert(items, {
        text = _("Check all books for updates"),
        callback = function() M.checkAllUpdates(browser) end,
    })
    if not cat then
        table.insert(items, {
            text = _("Fetch catalog for full titles"),
            mandatory = "\226\134\187",   -- ↻
            callback = function()
                ensureCatalog(function()
                    browser:refreshScreen(M.myBooksItems(browser))
                end)
            end,
        })
    end
    local outdated = 0
    for _i, r in ipairs(recs) do if r.outdated then outdated = outdated + 1 end end
    if outdated > 0 then
        table.insert(items, {
            text = "\226\154\160 " .. _("Updates available") .. ": " .. outdated,  -- ⚠
            dim = true,
            separator = true,
        })
    else
        items[#items].separator = true   -- rule under the action rows
    end
    for _i, r in ipairs(recs) do
        table.insert(items, {
            text = r.title,       -- the canonical dot-joined title (wraps if long)
            mandatory = r.outdated and "\226\154\160" or nil,   -- ⚠ = update available
            -- closeThen RETURNS the callback (close browser, then open the
            -- book) — assign it directly; wrapping it in another function
            -- discarded the returned closure and tapping did nothing.
            callback = browser:closeThen(function()
                local ok, ReaderUI = pcall(require, "apps/reader/readerui")
                if ok and ReaderUI and ReaderUI.showReader then
                    ReaderUI:showReader(r.path)
                end
            end),
        })
    end
    if #recs == 0 then
        table.insert(items, {
            text = _("No Quran books in your books folder yet."),
            dim = true,
        })
    end
    return items
end

function M.showMyBooks(browser)
    browser:navigateForward(_("My books"), M.myBooksItems(browser), nil,
        { multiline = true })
end

local function buildLibraryItems(browser)
    return {
        {
            -- Your Quran editions: the inventory (open, and — next phases —
            -- manage/update/delete). Get books is the install catalog.
            text = _("My books"),
            separator = true,
            callback = function() M.showMyBooks(browser) end,
        },
        {
            -- Q4 reframe: dicts + data packages are one user concept.
            -- The 6 feature-named data packages sit at the top of this
            -- screen; the large, content-named dictionary list lives
            -- behind a "Dictionaries (N)" drill-in appended there.
            text = _("Content & features"),
            callback = function() M.showData(browser) end,
        },
        {
            text = _("Get books"),
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
                M.clearAssetCache()   -- drop the persisted books catalog too
                notify(_("Catalogs cleared — they will be re-fetched on next use."))
            end,
        },
        {
            text = _("Asset source"),
            mandatory = M.assetSource() == "test" and _("test build") or _("official"),
            callback = function() M.showSourceDialog(browser) end,
        },
    }
end

-- Official releases vs the rolling test-build pre-release (beta channel).
function M.showSourceDialog(browser)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local cur = M.assetSource()
    local dialog
    local function pick(src)
        UIManager:close(dialog)
        if src == cur then return end
        M.setAssetSource(src)
        notify(src == "test"
            and _("Downloads now come from the rolling test build — unvalidated CI assets, for testing only.")
            or _("Downloads now come from official releases."))
        browser:refreshScreen(buildLibraryItems(browser))
    end
    dialog = ButtonDialog:new{
        title = _("Where dictionaries, data packages and books are downloaded from. The test build is the newest unreleased CI build — unvalidated, for beta testing only."),
        buttons = {
            {{
                text = (cur == "official" and "✓ " or "") .. _("Official releases"),
                callback = function() pick("official") end,
            }},
            {{
                text = (cur == "test" and "✓ " or "") .. _("Test build (unvalidated)"),
                callback = function() pick("test") end,
            }},
            {{
                text = _("Close"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

function M.showLibrary(browser)
    browser:navigateForward(_("Library & assets"), buildLibraryItems(browser))
end

return M
