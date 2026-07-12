-- Standalone unit test for the v1.11 helpers, extracted live from main.lua
-- so the tested code cannot drift from the shipped code.
local src = io.open("tools/quran.koplugin/main.lua"):read("*a")

local function extract(from_pat, to_pat)
    local i = src:find(from_pat, 1, true)
    assert(i, "start not found: " .. from_pat)
    local j = src:find(to_pat, i, true)
    assert(j, "end not found: " .. to_pat)
    return src:sub(i, j - 1)
end

-- SURAH_NAMES_ARABIC table + name map + helpers
local chunk = extract("local SURAH_NAMES_ARABIC = {", "-- Ayah counts per surah")
    .. extract("--- Normalize Arabic for surah-name matching",
               "-- ---------------------------------------------------------------------------")
    .. extract("local function markerPuaCodepoint(s)", "--- Read QCF word info")
    .. "\nreturn { norm = normalizeArabicName, map = SURAH_AR_NAME_TO_NUM, marker = markerPuaCodepoint }\n"

local f = assert(loadstring(chunk))
local M = f()

local function eq(got, want, label)
    if got ~= want then
        error(string.format("FAIL %s: got %s want %s", label, tostring(got), tostring(want)))
    end
    print("ok  " .. label)
end

-- normalizeArabicName / map
eq(M.map[M.norm("البقرة")], 2, "bare name")
eq(M.map[M.norm("سورة البقرة")], 2, "with surat prefix")
eq(M.map[M.norm("ٱلْبَقَرَة")], 2, "vocalized wasla form")
eq(M.map[M.norm("الأنعام")], 6, "hamza form direct")
eq(M.map[M.norm("الانعام")], 6, "bare-alef variant")
eq(M.map[M.norm("يس")], 36, "ya-sin")
eq(M.map[M.norm("كتاب")], nil, "ordinary word no match")
eq(M.map[M.norm("عمران")], 3, "multi-word name: single word")
eq(M.map[M.norm("آل عمران")], 3, "multi-word name: full")

-- _warshToHafs / _hafsToWarsh (extracted live; _warshMap shimmed)
local wchunk = "local Quran = {}\nfunction Quran:_warshMap() return self._test_map end\n"
    .. extract("--- Map a book ayah number to the Hafs number",
               "--- Ayah-count table for dict-popup navigation")
    .. "\nreturn Quran\n"
local W = assert(loadstring(wchunk))()
-- toy surah: Warsh merges Hafs 2+3 into Warsh ayah 2 (row[w] = first Hafs)
local inst = { _riwayah = "warsh", _test_map = { [103] = {1, 2, 4} },
               _warshMap = W._warshMap, _warshToHafs = W._warshToHafs,
               _hafsToWarsh = W._hafsToWarsh }
eq(inst:_hafsToWarsh(103, 1), 1, "h2w before merge")
eq(inst:_hafsToWarsh(103, 2), 2, "h2w exact match")
eq(inst:_hafsToWarsh(103, 3), 2, "h2w mid-merge (exact search would miss)")
eq(inst:_hafsToWarsh(103, 4), 3, "h2w after merge")
eq(inst:_hafsToWarsh(104, 7), 7, "h2w non-divergent surah identity")
inst._riwayah = "hafs"
eq(inst:_hafsToWarsh(103, 3), 3, "h2w hafs book identity")
inst._riwayah = "warsh"

-- real-data invariant: for every divergent surah in warshalign.lua, every
-- Hafs ayah between two boundaries maps back to the covering Warsh ayah
local real = dofile("tools/quran.koplugin/warshalign.lua")
inst._test_map = real
local pairs_checked = 0
for s, row in pairs(real) do
    for w = 1, #row do
        local last_h = (w < #row) and (row[w + 1] - 1) or row[w]
        for h = row[w], last_h do
            if inst:_hafsToWarsh(s, h) ~= w then
                error(string.format("FAIL real map: surah %d hafs %d -> %d want %d",
                    s, h, inst:_hafsToWarsh(s, h), w))
            end
            pairs_checked = pairs_checked + 1
        end
    end
end
print("ok  real warshalign roundtrip (" .. pairs_checked .. " ayah mappings)")

-- _renameMap / _migrateSidecarsInDir (extracted live; KOReader modules stubbed)
local fake_fs  -- set per scenario: { [path] = "file" }, sidecars: { [epub_path] = true }
local fake_sidecars, update_calls
package.preload["docsettings"] = function()
    return {
        hasSidecarFile = function(_, path) return fake_sidecars[path] or false end,
        updateLocation = function(old, new, copy)
            table.insert(update_calls, { old = old, new = new, copy = copy })
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        dir = function(_)
            local names = {}
            for p in pairs(fake_fs) do names[#names + 1] = p:match("[^/]+$") end
            table.sort(names)
            local i = 0
            return function() i = i + 1; return names[i] end
        end,
        attributes = function(path, what)
            if what == "mode" then return fake_fs[path] end
        end,
    }
end
local mchunk = "local logger = { info = function() end, dbg = function() end }\n"
    .. "local Quran = {}\n"
    .. extract("--- Lazy inverse rename map",
               "--- On opening a renamed book")
    .. "\nreturn Quran\n"
local MIG = assert(loadstring(mchunk))()
local real_map = dofile("tools/quran.koplugin/renamemap.lua")
local OLD, NEW = next(real_map)  -- any real pair
local D = "/books"
local function run(scenario)
    fake_fs, fake_sidecars, update_calls = scenario.fs, scenario.sdr, {}
    local inst = { path = "tools/quran.koplugin",
                   _renameMap = MIG._renameMap,
                   _migrateSidecarsInDir = MIG._migrateSidecarsInDir }
    local migrated, found = inst:_migrateSidecarsInDir(D, scenario.skip)
    return migrated, found, update_calls
end
-- 1: old epub still present -> COPY
local m, f, calls = run{
    fs = { [D.."/"..NEW..".epub"] = "file", [D.."/"..OLD..".epub"] = "file" },
    sdr = { [D.."/"..OLD..".epub"] = true } }
eq(m, 1, "migrate: old-present migrated")
eq(calls[1].copy, true, "migrate: old-present copies")
-- 2: old epub gone -> MOVE
m, f, calls = run{
    fs = { [D.."/"..NEW..".epub"] = "file" },
    sdr = { [D.."/"..OLD..".epub"] = true } }
eq(m, 1, "migrate: old-gone migrated")
eq(calls[1].copy, false, "migrate: old-gone moves")
-- 3: new sidecar already exists -> never overwritten
m, f, calls = run{
    fs = { [D.."/"..NEW..".epub"] = "file" },
    sdr = { [D.."/"..OLD..".epub"] = true, [D.."/"..NEW..".epub"] = true } }
eq(m, 0, "migrate: existing data never overwritten")
-- 4: open book skipped
m, f, calls = run{
    fs = { [D.."/"..NEW..".epub"] = "file" },
    sdr = { [D.."/"..OLD..".epub"] = true },
    skip = D.."/"..NEW..".epub" }
eq(m, 0, "migrate: open book skipped")
-- 5: unrelated epub ignored
m, f, calls = run{
    fs = { [D.."/some_other_book.epub"] = "file" },
    sdr = {} }
eq(m, 0, "migrate: unrelated book ignored")

-- markerPuaCodepoint
eq(M.marker("\239\148\135"), 0xF507, "bare medallion F507")
-- NBSP + waqf 06DF + PUA-waqf F652 + medallion F507 (the 2:8 cluster)
eq(M.marker("\194\160\219\159\239\153\146\239\148\135\194\160"), 0xF507, "2:8 full cluster")
-- unnumbered basmala ornament F61E only
eq(M.marker("\219\159\239\152\158"), 0, "ornament-only marker")
-- word with attached PUA mark must NOT be hijacked
eq(M.marker("\216\168\216\167\239\153\146"), nil, "word with attached PUA")
-- plain word, Farsi yeh (IndoPak letter)
eq(M.marker("\219\140\216\179"), nil, "farsi-yeh word")
-- empty / digits
eq(M.marker(""), nil, "empty")
eq(M.marker("123"), nil, "ascii digits")

-- quran_actions.findAyahForPage (module loaded whole with KOReader stubs;
-- binary search over synthetic ayah-anchor pages)
package.preload["dispatcher"] = function()
    return { registerAction = function() end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end,
             setDirty = function() end, broadcastEvent = function() end }
end
package.preload["gettext"] = function()
    return function(s) return s end
end
package.preload["logger"] = package.preload["logger"] or function()
    return { dbg = function() end, info = function() end, warn = function() end }
end
local QA = dofile("tools/quran.koplugin/quran_actions.lua")

-- Fake book: surah 2 with 286 ayahs, 5 per page — ayah A's own anchor
-- ("#ayah-2-A") resolves to page 10 + floor((A-1)/5).
local fake_doc = {
    info = {},
    getPageFromXPointer = function(_, xp)
        local a = tonumber(xp:match("^#ayah%-2%-(%d+)$"))
        if a and a >= 1 and a <= 286 then
            return 10 + math.floor((a - 1) / 5)
        end
        return nil
    end,
}
local fake_quran = {
    ui = { document = fake_doc },
    bookAyahCount = function(_, s) return s == 2 and 286 or nil end,
    _findSurahForPage = function(_, _) return 2 end,
}

local s, a = QA.findAyahForPage(fake_quran, 10)
eq(s, 2, "findAyah: surah on first page")
eq(a, 1, "findAyah: first page -> ayah 1")
s, a = QA.findAyahForPage(fake_quran, 11)
eq(a, 6, "findAyah: page 11 -> ayah 6 (first anchor on page)")
s, a = QA.findAyahForPage(fake_quran, 10 + math.floor(280 / 5))
eq(a, 281, "findAyah: page of 281-285 -> ayah 281")
s, a = QA.findAyahForPage(fake_quran, 9999)
eq(a, nil, "findAyah: beyond end defaults to nil (ayah 1), not last")

-- Regression (owner repro 77:33 page reported as 77:50): anchors beyond
-- CREngine's lazy-pagination frontier resolve CLAMPED to the frontier
-- page. Surah of 50 ayahs, 5/page, true page(A) = 94 + ceil(A/5); frontier
-- at page 101 clamps every later anchor to 101. Reading page 101 (true
-- ayahs 31-35) must yield 31, not 50.
local clamp_doc = {
    info = {},
    getPageFromXPointer = function(_, xp)
        local a = tonumber(xp:match("^#ayah%-77%-(%d+)$"))
        if not a or a < 1 or a > 50 then return nil end
        local page = 94 + math.ceil(a / 5)
        if page > 101 then page = 101 end  -- lazy-pagination clamp
        return page
    end,
}
local clamp_quran = {
    ui = { document = clamp_doc },
    bookAyahCount = function(_, s) return s == 77 and 50 or nil end,
    _findSurahForPage = function(_, _) return 77 end,
}
s, a = QA.findAyahForPage(clamp_quran, 101)
eq(s, 77, "findAyah: clamp regression surah")
eq(a, 31, "findAyah: clamped far anchors do not hijack (31, not 50)")

-- Book without anchors: surah resolves, ayah gracefully nil
local no_anchor_quran = {
    ui = { document = { info = {}, getPageFromXPointer = function() return nil end } },
    bookAyahCount = function(_, s) return 286 end,
    _findSurahForPage = function(_, _) return 2 end,
}
s, a = QA.findAyahForPage(no_anchor_quran, 10)
eq(s, 2, "findAyah: anchorless book still returns surah")
eq(a, nil, "findAyah: anchorless book returns nil ayah")

-- DOM-order path (primary): compareXPointers resolution — immune to the
-- pagination clamp that made the page path report the surah's LAST ayah
-- (owner repro: 77:33 page detected as 77:50). Anchor value = ayah number;
-- the current position sits between anchors as a fraction.
local function mk_dom_doc(cur_val)
    return {
        info = {},
        getXPointer = function() return "CUR" end,
        compareXPointers = function(_, a, b)
            local function val(xp)
                if xp == "CUR" then return cur_val end
                return tonumber(xp:match("^#ayah%-77%-(%d+)$"))
            end
            local va, vb = val(a), val(b)
            if not va or not vb then return nil end
            if vb > va then return 1 elseif vb < va then return -1 else return 0 end
        end,
        getPageFromXPointer = function()
            error("DOM path available: page fallback must not run")
        end,
    }
end
local function mk_dom_quran(cur_val)
    return {
        ui = { document = mk_dom_doc(cur_val) },
        bookAyahCount = function(_, s) return s == 77 and 50 or nil end,
        _findSurahForPage = function(_, _) return 77 end,
    }
end
s, a = QA.findAyahForPage(mk_dom_quran(32.7), 580)
eq(s, 77, "findAyah DOM: surah")
eq(a, 33, "findAyah DOM: owner repro -> 33 (view top mid-33, before its end anchor)")
s, a = QA.findAyahForPage(mk_dom_quran(0.5), 580)
eq(a, 1, "findAyah DOM: view top before first anchor -> ayah 1")
s, a = QA.findAyahForPage(mk_dom_quran(50), 580)
eq(a, 50, "findAyah DOM: exactly at last anchor -> ayah 50")
s, a = QA.findAyahForPage(mk_dom_quran(99), 580)
eq(a, nil, "findAyah DOM: past all anchors defaults to nil (ayah 1), not last")

-- classifyDict / detectResources (resource auto-detection)
eq(QA.classifyDict("Tafsir Ibn Kathir (English)"), "tafsir", "classify: ibn kathir")
eq(QA.classifyDict("Tazkirul Quran (Wahiduddin Khan, English)"), "tafsir", "classify: tazkirul")
eq(QA.classifyDict("Fi Zilal al-Quran (Qutb, Urdu)"), "tafsir", "classify: fi zilal")
eq(QA.classifyDict("Asbab al-Nuzul — Al-Wahidi (أسباب النزول للواحدي)"), "asbab", "classify: asbab")
eq(QA.classifyDict("Quran I'rab"), "irab", "classify: irab")
eq(QA.classifyDict("Quran Grammar (Lite)"), "grammar", "classify: grammar lite")
eq(QA.classifyDict("Quran Word-by-Word (QPC Uthmani Hafs)"), "word", "classify: word dict")
eq(QA.classifyDict("Quran Surah Overview (English)"), "overview", "classify: overview")
eq(QA.classifyDict("Oxford English Dictionary"), nil, "classify: non-quran dict ignored")

local det_quran = { ui = { dictionary = { enabled_dict_names = {
    "Tafsir al-Muyassar (المیسر)", "Tafsir Ibn Kathir (English)",
    "Asbab al-Nuzul — Al-Wahidi (أسباب النزول للواحدي)",
    "Quran I'rab", "Quran Word-by-Word (QPC Uthmani Hafs)",
    "Oxford English Dictionary",
} } } }
local det = QA.detectResources(det_quran)
eq(#det.tafsir, 2, "detect: two tafsirs bucketed")
eq(det.asbab ~= nil, true, "detect: asbab found")
eq(det.irab, "Quran I'rab", "detect: irab found")
eq(det.overview, nil, "detect: overview absent")

-- quran_browser: item construction + navigation (Menu/Screen stubbed)
package.preload["ui/widget/menu"] = function()
    return {
        new = function(_, spec)
            local m = {
                title = spec.title,
                item_table = spec.item_table,
                paths = {},
                switch_log = {},
            }
            m.switchItemTable = function(self2, title, items, focus)
                self2.title = title
                self2.item_table = items
                table.insert(self2.switch_log, { title = title, n = #items })
            end
            return m
        end,
    }
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 800 end,
                        getHeight = function() return 1200 end } }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, spec) return spec end }
end
local UIM = require("ui/uimanager")
local _shown
UIM.show = function(_, w) _shown = w end
UIM.close = function(_, _) end

local QB = dofile("tools/quran.koplugin/quran_browser.lua")
local bq = {
    _is_quran_book = true,
    ui = { document = mk_dom_doc(32.7), dictionary = { enabled_dict_names = {
        "Tafsir al-Muyassar (المیسر)", "Quran I'rab",
    } } },
    bookAyahCount = function(_, s) return s == 77 and 50 or 20 end,
    _findSurahForPage = function(_, _) return 77 end,
    _warshToHafs = function(_, s, a) return a end,
    _hafsToWarsh = function(_, s, a) return a end,
    surahName = function(_, s) return "Surah" .. s end,
    surahNameArabic = function(_, s) return "AR" .. s end,
    juzBoundary = function(_, j) return (j <= 30) and 2 or nil, 100 + j end,
    openAyahPopup = function() end,
    openSurahOverviewPopup = function() end,
}
bq.ui.document.getCurrentPage = function() return 580 end

QB.show(bq, QA)
eq(_shown ~= nil, true, "browser: menu shown")
local root = _shown.item_table
eq(#root, 5, "browser: 5 root items")
eq(root[1].text:find("Surah77 77:33", 1, true) ~= nil, true,
    "browser: root shows detected position")
root[2].callback()  -- Surahs
eq(_shown.switch_log[1].n, 114, "browser: surah list has 114 items")
_shown.item_table[10].callback()  -- surah 10 screen
eq(_shown.switch_log[2].n, 3, "browser: surah screen has 3 items")
QB.show(bq, QA)  -- fresh instance
_shown.item_table[3].callback()  -- Juz
eq(_shown.switch_log[1].n, 30, "browser: juz list has 30 items")
QB.show(bq, QA)
_shown.item_table[1].callback()  -- Current position screen
local pos_items = _shown.item_table
eq(pos_items[1].text:find("Muyassar", 1, true) ~= nil, true,
    "browser: position screen lists installed tafsir")
eq(#pos_items, 5, "browser: position screen item count (tafsir+irab+all+overview+pick)")

-- quran_assets: pure helpers (network/fs paths not exercised here)
local QAS = dofile("tools/quran.koplugin/quran_assets.lua")

eq(QAS.versionNewer("1.10", "1.9"), true, "assets: 1.10 newer than 1.9")
eq(QAS.versionNewer("1.9", "1.10"), false, "assets: 1.9 not newer than 1.10")
eq(QAS.versionNewer("1.4", "1.4"), false, "assets: equal versions not newer")
eq(QAS.versionNewer("2.0", "1.99"), true, "assets: major beats minor")
eq(QAS.versionNewer("1.1", nil), true, "assets: any version newer than unknown")
eq(QAS.versionNewer(nil, "1.0"), false, "assets: nil candidate never newer")

local merged = QAS.mergeDictState(
    {
        { name = "quran_b", version = "1.1" },
        { name = "quran_a", version = "1.1" },
        { name = "quran_c", version = "1.0" },
        { name = "quran_d", version = "1.2" },
    },
    { quran_a = "/dict/a", quran_b = "/dict/b", quran_d = "/dict/d" },
    { quran_a = { version = "1.0" }, quran_d = { version = "1.2" } })
eq(#merged, 4, "assets: merge covers all manifest dicts")
eq(merged[1].entry.name, "quran_a", "assets: merge sorted by name")
eq(merged[1].state, "update", "assets: recorded older version -> update")
eq(merged[2].state, "unknown", "assets: manual install (no record) -> unknown")
eq(merged[3].state, "absent", "assets: not installed -> absent")
eq(merged[4].state, "current", "assets: recorded same version -> current")

local groups = QAS.groupVariants({
    { id = "v1", title_en = "B variant",
      axes = { riwayah = "hafs", layout_label = "Bilingual" } },
    { id = "v2", title_en = "A variant",
      axes = { riwayah = "hafs", layout_label = "Bilingual" } },
    { id = "v3", title_en = "W variant",
      axes = { riwayah = "warsh", layout_label = "Bilingual" } },
    { id = "v4", title_en = "I variant",
      axes = { riwayah = "hafs", orthography = "indopak", layout_label = "Arabic" } },
})
eq(#groups, 3, "assets: three variant groups")
eq(groups[1].label, "Bilingual", "assets: groups sorted alphabetically")
eq(groups[2].label, "IndoPak · Arabic", "assets: indopak qualifier in label")
eq(groups[3].label, "Warsh · Bilingual", "assets: riwayah qualifier in label")
eq(groups[1].variants[1].id, "v2", "assets: variants sorted by title_en inside group")

local cat_variants = {
    { id = "x", filename = "new_name.epub", old_filename = "old_name.epub" },
    { id = "y", filename = "other.epub", old_filename = nil },
}
eq(QAS.matchVariantForFile(cat_variants, "new_name.epub").id, "x",
    "assets: match by current filename")
eq(QAS.matchVariantForFile(cat_variants, "old_name.epub").id, "x",
    "assets: match by pre-sweep filename")
eq(QAS.matchVariantForFile(cat_variants, "unknown.epub"), nil,
    "assets: unmatched file -> nil")

eq(QAS.friendlySize(5124365), "5 MB", "assets: MB formatting")
eq(QAS.friendlySize(2048), "2 KB", "assets: KB formatting")
eq(QAS.friendlySize(nil), "", "assets: nil size -> empty")

-- Browser integration: the Library root item opens the assets screen
bq.path = "tools/quran.koplugin"
QB.show(bq, QA)
_shown.item_table[5].callback()  -- Library & assets
eq(_shown.switch_log[1].title, "Library & assets", "assets: library screen opens")
eq(_shown.switch_log[1].n, 5, "assets: library screen has 5 items (incl. data packages)")

-- _displayedRange / _ayahNavTarget: tafsir group navigation (extracted live)
local gchunk = "local Quran = {}\n"
    .. extract("--- Read the group-range comment",
               "--- Build the custom button layout")
    .. "\nreturn Quran\n"
local G = assert(loadstring(gchunk))()
local gq = {
    _displayedRange = G._displayedRange,
    _ayahNavTarget = G._ayahNavTarget,
    _ayahCounts = function()
        return { [1] = 7, [2] = 286, [3] = 200, [113] = 5, [114] = 6 }
    end,
}
local function popup(surah, ayah, def)
    return {
        _quran_surah = surah, _quran_ayah = ayah,
        results = { { definition = "unrelated" }, { definition = def } },
        dict_index = 2,
    }
end

local rs, r1, r2 = gq:_displayedRange(popup(2, 5, "<!-- range:2:1-29 -->\n<p>tafsir</p>"))
eq(rs, 2, "range: surah parsed")
eq(r1, 1, "range: start parsed")
eq(r2, 29, "range: end parsed")
eq(gq:_displayedRange(popup(2, 5, "<p>no comment</p>")), nil, "range: absent -> nil")

local s, a = gq:_ayahNavTarget(popup(2, 5, "<!-- range:2:1-29 -->x"), 1)
eq(s .. ":" .. a, "2:30", "groupnav: next skips past group end")
s, a = gq:_ayahNavTarget(popup(2, 29, "<!-- range:2:1-29 -->x"), 1)
eq(s .. ":" .. a, "2:30", "groupnav: next from group's last ayah")
s, a = gq:_ayahNavTarget(popup(2, 5, "<!-- range:2:1-29 -->x"), -1)
eq(s .. ":" .. a, "1:7", "groupnav: prev skips before group start (surah rollover)")
s, a = gq:_ayahNavTarget(popup(2, 30, "<!-- range:2:30-30 -->x"), -1)
eq(s .. ":" .. a, "2:29", "groupnav: degenerate range steps single ayah")
s, a = gq:_ayahNavTarget(popup(2, 5, "<p>plain dict</p>"), 1)
eq(s .. ":" .. a, "2:6", "groupnav: no comment -> single-ayah step")
s, a = gq:_ayahNavTarget(popup(2, 5, "<!-- range:3:1-29 -->x"), 1)
eq(s .. ":" .. a, "2:6", "groupnav: range from another surah ignored")
s, a = gq:_ayahNavTarget(popup(2, 280, "<!-- range:2:280-286 -->x"), 1)
eq(s .. ":" .. a, "3:1", "groupnav: group reaching surah end rolls to next surah")
eq(gq:_ayahNavTarget(popup(114, 6, "<!-- range:114:6-6 -->x"), 1), nil,
    "groupnav: nil past end of mushaf")
eq(gq:_ayahNavTarget(popup(1, 1, "<!-- range:1:1-1 -->x"), -1), nil,
    "groupnav: nil before start of mushaf")

-- quran_roots: pure helpers
local QR = dofile("tools/quran.koplugin/quran_roots.lua")

eq(QR.parseRootFromDefinition('lemma: \226\128\142x \194\183 root: \226\128\142\216\185-\216\176-\216\168</span>'),
    "عذب", "roots: parse root after lemma (LRM + dashes stripped)")
eq(QR.parseRootFromDefinition("root: ت-ر-ب\n"), "ترب", "roots: parse without LRM")
eq(QR.parseRootFromDefinition("<p>no root line</p>"), nil, "roots: absent -> nil")
eq(QR.dashRoot("عذب"), "ع-ذ-ب", "roots: dashRoot inserts dashes")
eq(QR.dashRoot("ع-ذ-ب"), "ع-ذ-ب", "roots: dashRoot keeps dashed input")

local hws = QR.markTop3({
    { seq = 1, quran_freq = 0 },
    { seq = 2, quran_freq = 43 },
    { seq = 3, quran_freq = 322 },
    { seq = 4, quran_freq = 43 },
    { seq = 5, quran_freq = 1 },
})
eq(hws[3].top3, true, "roots: top3 marks highest freq")
eq(hws[2].top3, true, "roots: top3 tie broken by seq (earlier wins)")
eq(hws[4].top3, true, "roots: top3 third slot")
eq(hws[5].top3, nil, "roots: fourth-ranked not marked")
eq(hws[1].top3, nil, "roots: freq-0 never marked")

local rendered = QR.renderEntryText({
    definition = "Punishment.",
    quran_freq = 322,
    form_no = "2",
    clauses = { { marker = "1", text = "first sense" } },
    sigla = { "S", "ZZ" },
    sigla_names = { S = "aṣ-Ṣiḥāḥ" },
}, "عذب")
eq(rendered:find("×322", 1, true) ~= nil, true, "roots: render includes freq")
eq(rendered:find("Punishment.", 1, true) ~= nil, true, "roots: render includes definition")
eq(rendered:find("1. first sense", 1, true) ~= nil, true, "roots: render includes sub-senses")
eq(rendered:find("S = aṣ-Ṣiḥāḥ", 1, true) ~= nil, true, "roots: render decodes sigla")
eq(rendered:find("ZZ", 1, true) ~= nil, true, "roots: unknown siglum kept as code")

-- quran_roots: real-DB round trip against the actual extract (skipped
-- when the extract or KOReader's sqlite binding isn't available here)
local lane_db = "data/lane-v1.sqlite"
local have_db = io.open(lane_db)
if have_db then have_db:close() end
package.path = "/Applications/KOReader.app/Contents/koreader/common/?.lua;"
    .. "/Applications/KOReader.app/Contents/koreader/?.lua;" .. package.path
package.cpath = "/Applications/KOReader.app/Contents/koreader/common/?.so;" .. package.cpath
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
    ffi.loadlib = ffi.loadlib or function(name) return ffi.load(name) end
end
local sq3_ok = ffi_ok and pcall(require, "lua-ljsqlite3/init")
if have_db and sq3_ok then
    -- findDb goes through the stubbed lfs: teach the fake fs the layout
    fake_fs = { ["data"] = "directory", ["data/lane-v1.sqlite"] = "file" }
    eq(QR.findDb({ path = "data" }), lane_db, "roots-db: findDb via plugin-dir fallback")
    local conn, oerr = QR.openPath(lane_db)
    eq(conn ~= nil, true, "roots-db: opens with schema check (" .. tostring(oerr) .. ")")
    local letters = QR.letters(conn)
    eq(#letters > 20, true, "roots-db: letters populated")
    local covered = 0
    for _i, l in ipairs(letters) do covered = covered + l.n end
    eq(covered, 1631, "roots-db: 1631 covered roots across letters")
    local ain_roots = QR.rootsByLetter(conn, "ع")
    local found_adhb = false
    for _i, r in ipairs(ain_roots) do
        if r.arabic == "عذب" then found_adhb = true end
    end
    eq(found_adhb, true, "roots-db: عذب listed under ع")
    local hw = QR.headwords(conn, "عذب")
    eq(#hw > 5, true, "roots-db: عذب has multiple headwords")
    local top
    for _i, h in ipairs(hw) do
        if h.top3 and (not top or h.quran_freq > top.quran_freq) then top = h end
    end
    eq(top and top.headword, "عَذَابٌ", "roots-db: punishment family ranks first")
    eq(top and top.quran_freq, 322, "roots-db: frequency signal intact")
    local e = QR.entry(conn, top.id)
    eq(e and e.definition:find("Punishment", 1, true) ~= nil, true,
        "roots-db: full entry text present")
else
    print("skip roots-db tests (extract or sqlite binding unavailable)")
end

print("ALL HELPER TESTS PASS")
