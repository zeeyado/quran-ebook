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

print("ALL HELPER TESTS PASS")
