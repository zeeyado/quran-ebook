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

-- _hafsToWarshStart: jumps land on the FIRST covering Warsh ayah
inst._hafsToWarshStart = W._hafsToWarshStart
inst._test_map = { [105] = { 1, 2, 2, 4 } }  -- warsh 2+3 split hafs 2..3
eq(inst:_hafsToWarsh(105, 2), 3, "h2w-start: plain inverse gives the LAST segment")
eq(inst:_hafsToWarshStart(105, 2), 2, "h2w-start: split lands on the first segment")
eq(inst:_hafsToWarshStart(105, 3), 3, "h2w-start: mid-merge covering ayah unchanged")
eq(inst:_hafsToWarshStart(105, 4), 4, "h2w-start: exact non-split unchanged")
inst._riwayah = "hafs"
eq(inst:_hafsToWarshStart(105, 2), 2, "h2w-start: hafs book identity")
inst._riwayah = "warsh"

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

-- visibleAyahRange: anchor arithmetic on the 5-per-page fake
fake_doc.getCurrentPage = function() return 11 end
local vs, vf, vl = QA.visibleAyahRange(fake_quran)
eq(vs .. ":" .. vf .. "\226\128\147" .. vl, "2:6\226\128\14710",
    "range: page 11 shows ayahs 6-10")
fake_doc.getCurrentPage = function() return 10 end
vs, vf, vl = QA.visibleAyahRange(fake_quran)
eq(vf .. "-" .. vl, "1-5", "range: first page shows ayahs 1-5")
fake_doc.getCurrentPage = nil

-- anchorConvention: static probe of the anchor's containing block
local conv_doc_start = {
    info = {},
    getPageFromXPointer = function(_, xp)
        if xp:find("ayah%-2%-2") then return 42 end
    end,
    getHTMLFromXPointer = function()
        return '<p class="ayah-text bilin " id="_doc_fragment_3_ ayah-2-2">TEXT</p>'
    end,
}
local conv_q = { ui = { document = conv_doc_start } }
eq(QA.anchorConvention(conv_q), "start", "conv: id on the ayah block -> start")
eq(conv_q._anchor_conv, "start", "conv: probe result cached")
local conv_doc_end = {
    info = {},
    getPageFromXPointer = function(_, xp)
        if xp:find("ayah%-2%-2") then return 42 end
    end,
    getHTMLFromXPointer = function()
        return '<p class="flow">text <a class="ayah-mark"'
            .. ' id="_doc_fragment_3_ ayah-2-2"></a> more</p>'
    end,
}
eq(QA.anchorConvention({ ui = { document = conv_doc_end } }), "end",
    "conv: inline end-marker -> end")
eq(QA.anchorConvention({ ui = { document = { info = {} } } }), "end",
    "conv: unprobeable engine defaults to end")

-- visibleAyahRange DOM path: immune to the lazy-pagination clamp that
-- makes page-number comparison overshoot (anchors past the frontier all
-- report the frontier page)
local dom_range_doc = {
    info = {},
    getCurrentPage = function() return 101 end,
    getXPointer = function() return "/body/DocFragment[78]/x" end,
    getPageXPointer = function(_, p) return "PAGE" .. p end,
    compareXPointers = function(_, x1, x2)
        local function v(x)
            local pg = x:match("^PAGE(%d+)$")
            if pg then return (tonumber(pg) - 95) * 5 + 0.5 end
            return tonumber(x:match("ayah%-77%-(%d+)$"))
        end
        local v1, v2 = v(x1), v(x2)
        if not v1 or not v2 then return nil end
        if v2 > v1 then return 1 elseif v2 < v1 then return -1 else return 0 end
    end,
    getPageFromXPointer = function(_, xp)  -- clamp: later anchors stick at 101
        local aa = tonumber(xp:match("ayah%-77%-(%d+)"))
        if not aa or aa < 1 or aa > 50 then return nil end
        local page = 94 + math.ceil(aa / 5)
        return page > 101 and 101 or page
    end,
}
local dom_range_quran = {
    ui = { document = dom_range_doc },
    bookAyahCount = function(_, s2) return s2 == 77 and 50 or nil end,
    _findSurahForPage = function(_, _) return 77 end,
}
vs, vf, vl = QA.visibleAyahRange(dom_range_quran)
eq(vs, 77, "range-dom: surah")
eq(vf, 31, "range-dom: first from detection")
eq(vl, 35, "range-dom: DOM comparison stops at the page boundary (page clamp would say 50)")
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
eq(a, 50, "findAyah DOM: past all anchors (surah end matter) -> last ayah")

-- Fragment-prefixed ids (the 2026-07-12 root cause: CREngine renames
-- every EPUB id to "_doc_fragment_<N>_ <id>", N = 0-based spine index)
eq(QA.fragPrefix("/body/DocFragment[79]/body/p[65]/text().0"),
    "_doc_fragment_78_ ", "fragPrefix: parsed from view xpointer")
eq(QA.fragPrefix("CUR"), nil, "fragPrefix: nil for non-fragment xpointer")
eq(QA.fragPrefix(nil), nil, "fragPrefix: nil input")

-- Engine-faithful fake: ONLY prefixed anchors resolve (plain forms
-- return nil, like the real engine's compareXPointers)
local FRAG_CUR = "/body/DocFragment[79]/body/p[60]/span/text().0"
local function mk_frag_doc(cur_val)
    return {
        info = {},
        getXPointer = function() return FRAG_CUR end,
        compareXPointers = function(_, x, y)
            local function val(xp)
                if xp == FRAG_CUR then return cur_val end
                return tonumber(xp:match("^#_doc_fragment_78_ ayah%-77%-(%d+)$"))
            end
            local vx, vy = val(x), val(y)
            if not vx or not vy then return nil end
            if vy > vx then return 1 elseif vy < vx then return -1 else return 0 end
        end,
        getPageFromXPointer = function()
            error("DOM path available: page fallback must not run")
        end,
    }
end
local frag_quran = {
    ui = { document = mk_frag_doc(32.7) },
    bookAyahCount = function(_, ss) return ss == 77 and 50 or nil end,
    _findSurahForPage = function(_, _) return 77 end,
}
s, a = QA.findAyahForPage(frag_quran, 2378)
eq(s, 77, "findAyah frag: surah")
eq(a, 33, "findAyah frag: prefixed anchors resolve (owner repro fixed)")

-- Containment precedence: ayah-by-ayah layouts mark the view-top block
-- (arabic paragraph id / translation ayah-ref) — that exact answer must
-- win over the DOM search, which lands one ayah late there (the view
-- top text node compares strictly after its own paragraph's anchor)
local function mk_contain_quran(cur_val, block_html)
    local d = mk_frag_doc(cur_val)
    d.getHTMLFromXPointer = function(_, _, _, _) return block_html end
    return {
        ui = { document = d },
        bookAyahCount = function(_, ss) return ss == 77 and 50 or nil end,
        _findSurahForPage = function(_, _) return 77 end,
    }
end
s, a = QA.findAyahForPage(mk_contain_quran(31.5,
    '<p class="ayah-text bilin" id="ayah-77-31"><span>…</span></p>'), 2378)
eq(a, 31, "findAyah containment: arabic paragraph id wins (off-by-one fixed)")
s, a = QA.findAyahForPage(mk_contain_quran(31.5,
    '<p class="translation" lang="en"><span class="ayah-ref">77:30</span> text</p>'), 2378)
eq(a, 30, "findAyah containment: translation ayah-ref wins")
s, a = QA.findAyahForPage(mk_contain_quran(32.7,
    "<p>inline flow, no ayah marker on the block</p>"), 2378)
eq(a, 33, "findAyah containment: unmarked block -> DOM search fallback")

-- resolveAnchorPage: jump targets via plain, then offset-derived prefix
local resolve_doc = {
    getPageFromXPointer = function(_, xp)
        if xp == "#_doc_fragment_78_ surah-77" then return 2372 end
        if xp == "#_doc_fragment_78_ ayah-77-32" then return 2377 end
        return 1  -- engine returns 1 for unresolvable ids
    end,
    getXPointer = function() return FRAG_CUR end,
    getCurrentPage = function() return 2378 end,
}
local resolve_quran = {
    ui = { document = resolve_doc },
    _findSurahForPage = function(_, _) return 77 end,
}
eq(QA.resolveAnchorPage(resolve_quran, 77, nil), 2372,
    "resolve: surah header via derived fragment offset")
eq(resolve_quran._frag_offset, 2, "resolve: offset cached (79 - 77)")
eq(QA.resolveAnchorPage(resolve_quran, 77, 32), 2377,
    "resolve: ayah end-marker via cached offset")
eq(QA.resolveAnchorPage(resolve_quran, 78, nil), nil,
    "resolve: unresolvable id -> nil, never page 1")
local plain_doc_quran = {
    ui = { document = {
        getPageFromXPointer = function(_, xp)
            return xp == "#surah-3" and 42 or 1
        end,
    } },
}
eq(QA.resolveAnchorPage(plain_doc_quran, 3, nil), 42,
    "resolve: plain id works for non-fragment engines")

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
local _shown, _show_count
_show_count = 0
UIM.show = function(_, w)
    _shown = w
    _show_count = _show_count + 1
end
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
eq(#root, 8, "browser: 8 root items (incl. Search + Topics + Themes)")
eq(root[1].text:find("Surah77 77:33", 1, true) ~= nil, true,
    "browser: root shows detected position")
eq(root[2].text, "Search", "browser: global search row")
root[3].callback()  -- Surahs
eq(_shown.switch_log[1].n, 114, "browser: surah list has 114 items")
_shown.item_table[10].callback()  -- surah 10 screen
eq(_shown.switch_log[2].n, 3, "browser: surah screen has 3 items")
QB.show(bq, QA)  -- fresh instance
_shown.item_table[4].callback()  -- Juz
eq(_shown.switch_log[1].n, 30, "browser: juz list has 30 items")
QB.show(bq, QA)
_shown.item_table[1].callback()  -- Current position → unified ayah page
local pos_items = _shown.item_table
eq(_shown.title, "Surah77 77:33", "uap: position lands on the ayah page")
eq(pos_items[1].text, "Read (text & translation)", "uap: read row first")
eq(pos_items[2].text, "Go to this ayah in the book", "uap: goto row")
eq(pos_items[3].text, "Tafsir", "uap: tafsir row from installed dicts")
eq(pos_items[4].text, "I'rab", "uap: irab row")
eq(#pos_items, 6, "uap: 6 items (no asbab, no qul db here)")

-- gotoAyah convention routing through the UAP "Go to" row
package.preload["ui/event"] = function()
    return { new = function(_, ...) return {} end }
end
package.loaded["ui/event"] = nil
local jump_log = {}
local QA_start = setmetatable({
    anchorConvention = function() return "start" end,
    resolveAnchorPage = function(_q, js, ja)
        table.insert(jump_log, js .. ":" .. tostring(ja))
        return 99
    end,
}, { __index = QA })
local bq_jump = {
    _is_quran_book = true,
    ui = { document = mk_dom_doc(32.7), handleEvent = function() end,
           dictionary = { enabled_dict_names = {} } },
    bookAyahCount = function(_, s2) return s2 == 77 and 50 or 20 end,
    _findSurahForPage = function(_, _) return 77 end,
    _warshToHafs = function(_, _s2, a2) return a2 end,
    _hafsToWarsh = function(_, _s2, a2) return a2 end,
    surahName = function(_, s2) return "Surah" .. s2 end,
    surahNameArabic = function(_, s2) return "AR" .. s2 end,
    juzBoundary = function(_, j) return (j <= 30) and 2 or nil, 100 + j end,
    openAyahPopup = function() end,
    openSurahOverviewPopup = function() end,
}
bq_jump.ui.document.getCurrentPage = function() return 580 end
QB.show(bq_jump, QA_start)
_shown.item_table[1].callback()          -- ayah page (range loop logs too)
jump_log = {}
_shown.item_table[2].callback()          -- Go to this ayah
eq(jump_log[1], "77:33", "uap-goto: start-anchored book resolves anchor A")
local QA_end = setmetatable({
    anchorConvention = function() return "end" end,
    resolveAnchorPage = function(_q, js, ja)
        table.insert(jump_log, js .. ":" .. tostring(ja))
        return 99
    end,
}, { __index = QA })
QB.show(bq_jump, QA_end)
_shown.item_table[1].callback()
jump_log = {}
_shown.item_table[2].callback()
eq(jump_log[1], "77:32", "uap-goto: end-anchored book resolves anchor A-1")

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
_shown.item_table[8].callback()  -- Library & assets (last root item)
eq(_shown.switch_log[1].title, "Library & assets", "assets: library screen opens")
eq(_shown.switch_log[1].n, 6, "assets: library screen has 6 items (incl. data packages + relocated Restore)")

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

-- _firstAyahWithEntry: ONE batched sdcv probe finds the displayed dict's
-- next covered ayah (the popup/Reader gap-skip that stops the silent
-- dictionary switch on sparse tafsirs)
local probe_words, probe_dicts
local pq = {
    _hafsCounts = function()
        return { [1] = 7, [2] = 286, [113] = 5, [114] = 6 }
    end,
    _ayahDictKeys = function(_, s, a) return { "K" .. s .. ":" .. a } end,
    _firstAyahWithEntry = G._firstAyahWithEntry,
    ui = { dictionary = { rawSdcv = function(_, words, dicts)
        probe_words, probe_dicts = words, dicts
        local out = {}
        for i, w in ipairs(words) do
            out[i] = (w == "K2:9" or w == "K2:3") and { { definition = "D" } } or {}
        end
        return false, out
    end } },
}
local fs, fa = pq:_firstAyahWithEntry("Tazkirul Quran", 2, 6, 1, 10)
eq(fs .. ":" .. fa, "2:9", "gapskip: forward probe finds the next covered ayah")
eq(probe_dicts[1], "Tazkirul Quran", "gapskip: probe filtered to the displayed dict")
eq(#probe_words, 10, "gapskip: one batched call over the whole walk")
fs, fa = pq:_firstAyahWithEntry("Tazkirul Quran", 2, 6, -1, 10)
eq(fs .. ":" .. fa, "2:3", "gapskip: backward probe")
pq.ui.dictionary.rawSdcv = function(_, words)
    local out = {}
    for i, w in ipairs(words) do
        out[i] = (w == "K114:1") and { { definition = "D" } } or {}
    end
    return false, out
end
fs, fa = pq:_firstAyahWithEntry("T", 113, 4, 1, 10)
eq(fs .. ":" .. fa, "114:1", "gapskip: the walk rolls into the next surah")
pq.ui.dictionary.rawSdcv = function(_, words)
    local out = {}
    for i = 1, #words do out[i] = {} end
    return false, out
end
eq(pq:_firstAyahWithEntry("T", 2, 6, 1, 5), nil,
    "gapskip: nothing covered within the walk -> nil (caller keeps plain step)")
pq.ui.dictionary.rawSdcv = function() return true, nil end
eq(pq:_firstAyahWithEntry("T", 2, 6, 1, 5), nil, "gapskip: cancelled -> nil")

-- _applyHeaderMargin (extracted live): the post-render margin raise and
-- the every-open re-render LOOP GUARD (Android report 2026-07-12: every
-- open re-parsed because the raised margin never persisted)
local mchunk = "local _ = function(s) return s end\n"
    .. "local Event = { new = function(_, n, v) return { name = n, value = v } end }\n"
    .. "local logger = { info = function() end, dbg = function() end }\n"
    .. "local Quran = {}\n"
    .. extract("function Quran:_applyHeaderMargin()",
               "--- Undo _applyHeaderMargin")
    .. "\nreturn Quran\n"
local MH = assert(loadstring(mchunk))()
local m_fired, m_marker, m_notice
local mq = {
    _is_quran_book = true,
    settings = {
        nilOrTrue = function() return true end,
        isTrue = function() return m_notice == true end,
        saveSetting = function(_, _k, v) m_notice = v end,
        flush = function() end,
    },
    _headerMarginNeeded = function() return 24 end,
    ui = {
        document = { configurable = { t_page_margin = 10 } },
        doc_settings = {
            readSetting = function() return m_marker end,
            saveSetting = function(_, _k, v) m_marker = v end,
        },
        handleEvent = function(_, ev) m_fired = ev end,
    },
    _applyHeaderMargin = MH._applyHeaderMargin,
}
mq:_applyHeaderMargin()
eq(m_fired and m_fired.value, 24, "hdr-margin: first open raises to needed")
eq(m_marker, 10, "hdr-margin: pre-bump margin remembered")
m_fired = nil
mq.ui.document.configurable.t_page_margin = 24
mq:_applyHeaderMargin()
eq(m_fired, nil, "hdr-margin: persisted margin -> no event, no re-render")
m_fired = nil
mq.ui.document.configurable.t_page_margin = 10
local m_shows = _show_count
mq:_applyHeaderMargin()
eq(m_fired, nil, "hdr-margin: non-persisting margin -> loop guard, no re-raise")
mq:_applyHeaderMargin()
eq(m_fired, nil, "hdr-margin: guard holds on every later open")
eq(_show_count, m_shows + 1, "hdr-margin: warned exactly once EVER (persisted flag"
    .. " — a session-local flag reset per Android process restart)")
eq(m_notice, true, "hdr-margin: notice flag saved to plugin settings")

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
    definition = "Punishment. (S, O.) Long apparatus text.",
    definition_short = "Punishment, cleaned.",
    quran_freq = 322,
    form_no = "2",
    clauses = { { marker = "1", text = "first sense" },
                { marker = "2", text = "second sense" } },
    sigla = { "S", "ZZ" },
    sigla_names = { S = "aṣ-Ṣiḥāḥ" },
}, "عذب")
eq(rendered:find("×322", 1, true) ~= nil, true, "roots: render includes freq")
eq(rendered:find("Punishment, cleaned.", 1, true) ~= nil, true,
    "roots: cleaned first sense leads")
eq(rendered:find("Punishment, cleaned.", 1, true)
    < rendered:find("Long apparatus", 1, true), true,
    "roots: full text comes after the summary")
eq(rendered:find("\239\191\1782. \239\191\179second sense", 1, true) ~= nil, true,
    "roots: multi-clause entries get the numbered sense map (bolded markers)")
eq(rendered:find("\239\191\178Full entry %(Lane%):") ~= nil, true,
    "roots: full text under a labeled section")
eq(rendered:find("S = aṣ-Ṣiḥāḥ", 1, true) ~= nil, true, "roots: render decodes sigla")
eq(rendered:find("ZZ", 1, true) ~= nil, true, "roots: unknown siglum kept as code")
eq(rendered:sub(1, 3), "\239\191\177", "roots: render starts with PTF header")
eq(rendered:find("\239\191\178Senses:") ~= nil, true, "roots: section labels PTF-bolded")
-- one clause = a repeat of the opening -> no sense map, definition plain
local single = QR.renderEntryText({
    definition = "Only text.",
    clauses = { { marker = "1", text = "Only text." } },
}, nil)
eq(single:find("Senses:", 1, true), nil, "roots: single clause skips the sense map")
eq(single:find("Full entry", 1, true), nil,
    "roots: no summary -> definition stays unlabeled")
eq(single:find("Only text.", 1, true) ~= nil, true, "roots: definition still rendered")

-- _registerRootDictButton: the ≥2026.05 word-popup button (extracted live;
-- exercises show_func/callback with the REAL root parser)
local regchunk = "local _ = function(s) return s end\nlocal Quran = {}\n"
    .. extract("--- Register the word-popup Root-explorer button",
               "--- Detect whether the current book is a quran-ebook EPUB")
    .. "\nreturn Quran\n"
local REG = assert(loadstring(regchunk))()
local captured_spec, opened_root, closed
local regq = {
    _is_quran_book = true,
    _rootsModule = function() return QR end,
    _registerRootDictButton = REG._registerRootDictButton,
    openRootExplorer = function(_, root) opened_root = root end,
    ui = { dictionary = { addToDictButtons = function(_, spec) captured_spec = spec end } },
}
regq:_registerRootDictButton()
eq(captured_spec ~= nil and captured_spec.id, "quran_root_explorer",
    "rootbtn: spec registered via official API")
eq(captured_spec.conditional, true, "rootbtn: conditional row")
local root_def = "x · root: \226\128\142\216\185-\216\176-\216\168</span>"
local word_popup = {
    results = { { definition = "plain dict entry" }, { definition = root_def } },
    dict_index = 2,
    onClose = function() closed = true end,
}
eq(captured_spec.show_func(word_popup), true, "rootbtn: shows when a result has a root")
eq(captured_spec.show_func({ results = { { definition = "nothing here" } }, dict_index = 1 }),
    false, "rootbtn: hidden without a root line")
regq._is_quran_book = false
eq(captured_spec.show_func(word_popup), false, "rootbtn: hidden outside quran books")
regq._is_quran_book = true
captured_spec.callback(word_popup)
eq(closed, true, "rootbtn: callback closes the popup")
eq(opened_root, "عذب", "rootbtn: callback opens the displayed result's root")

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

    -- Entry viewer: X-ray-style ◀ ▶ navigation through the headword list
    package.preload["ui/widget/textviewer"] = function()
        return { new = function(_, spec)
            -- in-place updates call viewer:init(true) + read frame.dimen
            spec.init = function() end
            spec.frame = { dimen = {} }
            return spec
        end }
    end
    package.loaded["ui/widget/textviewer"] = nil
    local ebrowser = { quran = { path = "data" } }
    QR.showEntry(ebrowser, hw[1].id, "عذب", { list = hw, index = 1 })
    local v1 = _shown
    local shows_before_step = _show_count
    eq(v1.title:find("^%(1/") ~= nil, true, "roots-viewer: (i/N) position in title")
    eq(#v1.buttons_table[1], 3, "roots-viewer: back + prev/next buttons")
    eq(v1.buttons_table[1][1].text:find("ع%-ذ%-ب") ~= nil, true,
        "roots-viewer: back button names the root")
    v1.buttons_table[1][3].callback()  -- ▶ next
    eq(_shown.title:find("^%(2/") ~= nil, true, "roots-viewer: next opens sibling entry")
    eq(_shown == v1 and _show_count == shows_before_step, true,
        "roots-viewer: ◀ ▶ update IN PLACE (no close/reopen)")
    eq(_shown.text:sub(1, 3), "\239\191\177", "roots-viewer: entry text is PTF-formatted")
    eq(_shown.para_direction_rtl, false,
        "roots-viewer: English-dominant entries render LTR")
    -- release the module handle so later blocks open fresh viewers
    v1.buttons_table[1][1].callback()  -- ← back closes
    eq(QR._entry_viewer, nil, "roots-viewer: back releases the in-place handle")
else
    print("skip roots-db tests (extract or sqlite binding unavailable)")
end

-- quran_qul: pure helpers
local QQ = dofile("tools/quran.koplugin/quran_qul.lua")
eq(QQ.stripHtml('<b>Allah</b> (<span class="ar">الله</span>) is the name in the <topic data-id="61">Quran</topic>.'),
    "Allah (الله) is the name in the Quran.", "qul: stripHtml flattens tags")
eq(QQ.stripHtml("a &amp; b &lt;c&gt;  d"), "a & b <c> d", "qul: stripHtml decodes entities")
eq(QQ.stripHtml(nil), "", "qul: stripHtml nil-safe")
local topic_text = QQ.renderTopicText({
    name = "Allah", arabic_name = "الله", n_ayahs = 147,
    description = "<b>Allah</b> is…", wiki_link = "en.wikipedia.org/wiki/Allah",
})
eq(topic_text:sub(1, 3), "\239\191\177", "qul: topic text PTF-formatted")
eq(topic_text:find("×147", 1, true) ~= nil, true, "qul: topic meta includes ayah count")
eq(topic_text:find("Allah is…", 1, true) ~= nil, true, "qul: topic description flattened")

-- quran_qul: real-DB round trip (skipped when the build or sqlite missing)
local qul_db = "output/qul_data/qul-v1.sqlite"
local have_qul = io.open(qul_db)
if have_qul then have_qul:close() end
if have_qul and sq3_ok then
    local qconn, qerr = QQ.openPath(qul_db)
    eq(qconn ~= nil, true, "qul-db: opens with schema check (" .. tostring(qerr) .. ")")
    local th = QQ.themesFor(qconn, 2, 7)
    eq(#th, 1, "qul-db: one theme covers 2:7 (deduped)")
    eq(th[1].theme:find("Warning", 1, true) ~= nil, true, "qul-db: theme text")
    local sim = QQ.similarFor(qconn, 1, 1)
    eq(sim[1].surah .. ":" .. sim[1].ayah, "27:30", "qul-db: top similar for 1:1")
    eq(sim[1].score, 80, "qul-db: similarity score")
    local tps = QQ.topicsFor(qconn, 1, 1)
    local has_allah = false
    for _i, t in ipairs(tps) do
        if t.name == "Allah" then has_allah = true end
    end
    eq(has_allah, true, "qul-db: 1:1 topics include Allah")
    eq(#QQ.topicRoots(qconn), 3, "qul-db: three thematic roots")
    local ph = QQ.phrasesFor(qconn, 2, 23)
    eq(#ph, 2, "qul-db: 2:23 in two phrase groups")
    eq(#QQ.phraseOccurrences(qconn, ph[1].group_id) > 60, true,
        "qul-db: group occurrences listed")
    local counts = QQ.countsFor(qconn, 2, 23)
    eq(counts.similar, 1, "qul-db: countsFor similar")
    eq(counts.phrases, 2, "qul-db: countsFor phrases")

    -- Browser integration: the unified ayah page gains the connection
    -- items (77:33 has 1 theme + 5 topics; similar/phrases are 0 and
    -- hidden). Seed the instance cache so the browser reuses the opened
    -- module.
    bq._qul_mod = QQ
    local uap_read
    bq._readerModule = function()
        return { showAyah = function(_q, s2, a2)
            uap_read = s2 .. ":" .. a2
            return true
        end }
    end
    QB.show(bq, QA)
    _shown.item_table[1].callback()  -- Current position → unified ayah page
    local pos2 = _shown.item_table
    eq(#pos2, 8, "qul-uap: 6 base items + themes + topics")
    local labels = {}
    for _i, it in ipairs(pos2) do labels[#labels + 1] = it.text end
    local joined = table.concat(labels, "|")
    eq(joined:find("Themes here", 1, true) ~= nil, true, "qul-uap: themes item present")
    eq(joined:find("Topics here", 1, true) ~= nil, true, "qul-uap: topics item present")
    pos2[1].callback()  -- Read (text & translation) → in-browser Reader
    eq(uap_read, "77:33", "qul-uap: Read routes to the Reader in-browser")

    -- Wave S: topic counts, flat browse, LIKE search (real qul db)
    eq(QQ.topicCount(qconn), 2512, "qul-s: topic count")
    local all_t = QQ.allTopics(qconn)
    eq(#all_t, 2512, "qul-s: allTopics complete")
    eq(all_t[1].name <= all_t[2].name, true, "qul-s: allTopics sorted")
    local troots = QQ.topicRoots(qconn)
    eq(#troots, 3, "qul-s: three tree roots")
    eq(troots[1].n_children and troots[1].n_children > 0, true,
        "qul-s: tree roots carry child counts")
    local hits = QQ.searchTopics(qconn, "Allah", 50)
    eq(#hits > 0, true, "qul-s: topic search finds Allah")
    local th_hits = QQ.searchThemes(qconn, "Warning", 10)
    eq(#th_hits > 0, true, "qul-s: theme search finds Warning")

    -- Topics landing: search-first + flat + counted tree (design D5)
    QB.show(bq, QA)
    _shown.item_table[5].callback()  -- Topics
    local topics_items = _shown.item_table
    eq(topics_items[1].text, "Search topics", "qul-s: topics landing search row")
    eq(topics_items[2].text, "All topics (A–Z)", "qul-s: flat browse row")
    eq(topics_items[2].mandatory, "2512", "qul-s: flat browse total count")
    eq(#topics_items, 5, "qul-s: 2 tools + 3 counted tree roots")
    eq(topics_items[3].mandatory ~= nil, true, "qul-s: tree root shows counts")

    -- qul v1.1: the upstream "Doctraine" typo is fixed at build time
    local root_names = {}
    for _i, tr in ipairs(troots) do root_names[tr.name] = true end
    eq(root_names["Doctrine"], true, "qul-v1.1: Doctrine root (typo fixed at build)")
    eq(root_names["Doctraine"], nil, "qul-v1.1: upstream typo absent")

    -- Topic connections (dynamic-xray linked-items idiom): up + sideways
    local mosque = QQ.topic(qconn, 63)
    eq(mosque.related_topics, "45,167,52", "qul-conn: related ids on the topic row")
    local rel = QQ.relatedTopics(qconn, mosque)
    eq(#rel, 3, "qul-conn: related topics resolved with counts")
    eq(rel[1].n_ayahs ~= nil, true, "qul-conn: related rows carry counts")
    eq(#QQ.relatedTopics(qconn, { related_topics = "" }), 0,
        "qul-conn: no links -> empty (most topics)")
    local dparents = QQ.topicParents(qconn, 1885)  -- "Basic tenets"
    eq(dparents[1] and dparents[1].name, "Doctrine",
        "qul-conn: parent row points up the tree")
    eq(#QQ.topicParents(qconn, 1882), 0, "qul-conn: tree roots have no parents")

    -- Theme screen (connections-first entity screen)
    local ttopics = QQ.themeTopics(qconn, 2, 6, 7)
    eq(#ttopics, 11, "qul-theme: topics attached within the range")
    eq(ttopics[1].n_ayahs ~= nil, true, "qul-theme: topic rows carry counts")
    local nav_t, nav_i
    local thbrowser = {
        quran = { surahName = function(_, s2) return "Surah" .. s2 end },
        navigateForward = function(_, ti, it) nav_t, nav_i = ti, it end,
    }
    QQ.showTheme(thbrowser, { theme = "Warning to disbelievers",
        surah = 2, ayah_from = 6, ayah_to = 7 })
    eq(nav_t:find("2:6\226\128\1477", 1, true) ~= nil, true,
        "qul-theme: title carries the range")
    eq(nav_i[1].text, "Read this passage", "qul-theme: flow action first")
    eq(nav_i[2].text, "Go to this passage in the book", "qul-theme: goto action")
    local n_conn, n_range_ayahs = 0, 0
    for _i, it in ipairs(nav_i) do
        if it.text:sub(1, 3) == "\226\137\136" then n_conn = n_conn + 1 end
        if it.text:find("^Surah2 2:%d+$") then n_range_ayahs = n_range_ayahs + 1 end
    end
    eq(n_conn, 11, "qul-theme: ≈ topic connection rows")
    eq(n_range_ayahs, 2, "qul-theme: one row per ayah in the range")
    -- theme LIST rows route to the theme screen now (not straight to UAP)
    QQ.showThemeItems(thbrowser,
        { { theme = "W", surah = 2, ayah_from = 6, ayah_to = 7 } }, "T", nil)
    nav_i[1].callback()
    eq(nav_t:find("2:6\226\128\1477", 1, true) ~= nil, true,
        "qul-theme: theme list row opens the theme screen")

    -- Themes-as-flow (Wave P): pure renderer
    local flow = QQ.renderThemesFlow("Themes · X", {
        { theme = "Alpha", surah = 2, ayah_from = 1, ayah_to = 2 },
        { theme = "Beta", surah = 2, ayah_from = 3, ayah_to = 3 },
    }, function(s2, a2) return "T" .. s2 .. ":" .. a2 end)
    eq(flow:sub(1, 3), "\239\191\177", "flow: PTF-formatted")
    eq(flow:find("2:1\226\128\1472 \194\183 Alpha", 1, true) ~= nil, true,
        "flow: bolded range heading")
    eq(flow:find("1. T2:1", 1, true) ~= nil, true, "flow: numbered translation paras")
    eq(flow:find("3. T2:3", 1, true) ~= nil, true, "flow: second theme's range rendered")
    local outline = QQ.renderThemesFlow("t", {
        { theme = "A", surah = 1, ayah_from = 1, ayah_to = 1 },
    }, nil)
    eq(outline:find("1%. "), nil, "flow: headings-only outline without the text package")

    -- Themes-as-flow: list row wiring + Reader handoff
    local nav_title2, nav_items2, flow_spec
    local fbrowser = {
        quran = {
            _readerModule = function()
                return { show = function(spec) flow_spec = spec end }
            end,
        },
        navigateForward = function(_, t2, i2) nav_title2, nav_items2 = t2, i2 end,
    }
    QQ.showThemeItems(fbrowser,
        { { theme = "Warning", surah = 2, ayah_from = 6, ayah_to = 7 } },
        "Themes 2:7", { flow = true })
    eq(nav_title2, "Themes 2:7", "flow: list still opens")
    eq(#nav_items2, 2, "flow: one flow row + one theme row")
    eq(nav_items2[1].text:find("Read as one page", 1, true) ~= nil, true,
        "flow: flow row prepended")
    nav_items2[1].callback()
    eq(flow_spec.title, "Themes 2:7", "flow: Reader title carries the scope")
    eq(flow_spec.text:find("2:6\226\128\1477 \194\183 Warning", 1, true) ~= nil, true,
        "flow: heading in the Reader body (outline mode: no text module)")
else
    print("skip qul-db tests (build output or sqlite binding unavailable)")
end

-- quran_norm: Python↔Lua parity on the shared norm() contract. The fixture
-- is REGENERATED by quran-explorer's kb/export/quran_text_extract.py on
-- every extract run — a parity failure here means the two implementations
-- drifted (fix the code or bump norm_version on both sides, never the
-- fixture by hand).
local QN = dofile("tools/quran.koplugin/quran_norm.lua")
eq(QN.NORM_VERSION, 1, "norm: contract version")
eq(QN.norm("\216\163\216\165\216\162\217\177"), "\216\167\216\167\216\167\216\167",
    "norm: alef variants fold")
eq(QN.norm("  ABC-123,  x  "), "abc x", "norm: ascii lower/punct/digits/ws")
eq(QN.norm(nil), "", "norm: nil-safe")
local fixture_ok, fixture = pcall(dofile, "scripts/dev_checks/norm_fixture.lua")
eq(fixture_ok and #fixture >= 15, true, "norm: fixture present")
if fixture_ok then
    for fi, f in ipairs(fixture) do
        eq(QN.norm(f.raw), f.norm, "norm: fixture parity #" .. fi)
    end
end

-- quran_text: real-DB round trip against the staged text package (skipped
-- when the extract copy or sqlite binding isn't available here)
local text_db = "data/text-v1.sqlite"
local have_text = io.open(text_db)
if have_text then have_text:close() end
if have_text and sq3_ok then
    local SQ3 = require("lua-ljsqlite3/init")
    local tconn = SQ3.open(text_db, "ro")
    eq(tostring(tconn:rowexec("SELECT value FROM meta WHERE key='schema_version'")),
        "1", "text-db: schema_version gate")
    eq(tostring(tconn:rowexec("SELECT value FROM meta WHERE key='norm_version'")),
        tostring(QN.NORM_VERSION), "text-db: norm_version matches quran_norm.lua")
    eq(tonumber(tconn:rowexec("SELECT count(*) FROM ayah WHERE riwayah='hafs'")),
        6236, "text-db: hafs ayah count")
    eq(tonumber(tconn:rowexec("SELECT count(*) FROM ayah WHERE riwayah='warsh'")),
        6214, "text-db: warsh ayah count")
    eq(tonumber(tconn:rowexec("SELECT count(*) FROM translation")),
        6236, "text-db: translation count")
    eq(tonumber(tconn:rowexec("SELECT max(page) FROM ayah")), 604,
        "text-db: page grid intact")
    local w11 = tconn:rowexec(
        "SELECT text FROM ayah WHERE riwayah='warsh' AND surah=1 AND ayah=1")
    eq(QN.norm(w11):find("\216\167\217\132\216\173\217\133\216\175", 1, true) ~= nil,
        true, "text-db: warsh 1:1 opens with al-hamd (native numbering)")
    -- FTS roundtrips, query normalized exactly as the plugin will
    -- (normalized text can contain no quotes — safe to inline)
    local aq = QN.norm("\216\168\217\144\216\179\219\161\217\133\217\144 "
        .. "\217\177\217\132\217\132\217\142\217\135\217\144")  -- بِسۡمِ ٱللَّهِ
    local nhit = tonumber(tconn:rowexec(
        "SELECT count(*) FROM ayah_fts WHERE ayah_fts MATCH '\"" .. aq
        .. "\"' AND surah=1 AND ayah=1"))
    eq(nhit, 1, "text-db: arabic FTS roundtrip via quran_norm")
    local ehit = tonumber(tconn:rowexec(
        "SELECT count(*) FROM trans_fts WHERE trans_fts MATCH "
        .. "'\"entirely merciful\"' AND surah=1 AND ayah=1"))
    eq(ehit, 1, "text-db: english FTS roundtrip")
    tconn:close()
else
    print("skip text-db tests (staged extract or sqlite binding unavailable)")
end

-- quran_reader: pure helpers (shared Reader surface, design D2)
package.preload["ui/widget/textviewer"] = function()
    return { new = function(_, spec)
        -- in-place updates call viewer:init(true) + read frame.dimen
        spec.init = function() end
        spec.frame = { dimen = {} }
        return spec
    end }
end
package.loaded["ui/widget/textviewer"] = nil
package.preload["ui/trapper"] = function()
    return { wrap = function(_, fn) return fn() end }
end
package.loaded["ui/trapper"] = nil
local QRD = dofile("tools/quran.koplugin/quran_reader.lua")
local C114 = { [1] = 7, [2] = 286, [113] = 5, [114] = 6 }
local ss, aa = QRD.stepAyah(C114, 1, 7, 1)
eq(ss .. ":" .. aa, "2:1", "reader: stepAyah surah rollover forward")
ss, aa = QRD.stepAyah(C114, 2, 1, -1)
eq(ss .. ":" .. aa, "1:7", "reader: stepAyah surah rollover backward")
eq(QRD.stepAyah(C114, 114, 6, 1), nil, "reader: stepAyah end of mushaf")
eq(QRD.stepAyah(C114, 1, 1, -1), nil, "reader: stepAyah start of mushaf")
ss, aa = QRD.tafsirNavTarget(C114, 2, 5, 2, 2, 7, 1)
eq(ss .. ":" .. aa, "2:8", "reader: tafsir nav skips group forward")
ss, aa = QRD.tafsirNavTarget(C114, 2, 5, 2, 2, 7, -1)
eq(ss .. ":" .. aa, "2:1", "reader: tafsir nav skips group backward")
ss, aa = QRD.tafsirNavTarget(C114, 2, 5, nil, nil, nil, 1)
eq(ss .. ":" .. aa, "2:6", "reader: tafsir nav plain step without range")
eq(QRD.parseRange("x<!-- range:2:2-7 -->y"), 2, "reader: parseRange surah")
local _rs, _r1, _r2 = QRD.parseRange("x<!-- range:2:2-7 -->y")
eq(_r1 .. "-" .. _r2, "2-7", "reader: parseRange bounds")
eq(QRD.parseRange("no comment"), nil, "reader: parseRange absent")
local body = QRD.renderAyahText({ "1:1", "Juz 1" }, "ARABIC", {
    { name = "Saheeh International", text = "In the name..." },
})
eq(body:sub(1, 3), "\239\191\177", "reader: ayah body PTF-formatted")
eq(body:find("ARABIC", 1, true) ~= nil, true, "reader: ayah body carries text")
eq(body:find("\239\191\178Saheeh International\239\191\179", 1, true) ~= nil,
    true, "reader: translation name bolded")

-- quran_reader: paging direction (Round-2 F3)
eq(QRD.paging_mode, "auto", "paging: default mode auto")
eq(QRD.pagingInverted(), false, "paging: auto without G_reader_settings -> standard")
G_reader_settings = { isTrue = function(_, k) return k == "inverse_reading_order" end }
eq(QRD.pagingInverted(), true, "paging: auto follows inverse_reading_order")
G_reader_settings = nil
QRD.paging_mode = "inverted"
eq(QRD.pagingInverted(), true, "paging: forced inverted")
QRD.paging_mode = "standard"
eq(QRD.pagingInverted(), false, "paging: forced standard")
QRD.paging_mode = "auto"
eq(QRD.tapScrollDir(true, false), "up", "paging: left tap = up")
eq(QRD.tapScrollDir(true, true), "down", "paging: left tap inverted = down")
eq(QRD.tapScrollDir(false, false), "down", "paging: right tap = down")
eq(QRD.swipeScrollDir("west", false), "down", "paging: west swipe = forward")
eq(QRD.swipeScrollDir("west", true), "up", "paging: west swipe inverted = back")
eq(QRD.swipeScrollDir("east", false), "up", "paging: east swipe = back")
eq(QRD.swipeScrollDir("north", false), nil, "paging: vertical swipe untouched")

-- wireTouchPaging: swipes route through the scroll handlers (gains the
-- boundary flow) and honor the mode at EVENT time; taps swap halves
-- when inverted
local tp_up, tp_down = 0, 0
local tp_viewer = {
    textw = { dimen = {} },
    scroll_text_w = {
        width = 800,
        onScrollUp = function() tp_up = tp_up + 1; return true end,
        onScrollDown = function() tp_down = tp_down + 1; return true end,
        onTapScrollText = function() end,
    },
    onSwipe = function()
        error("stock swipe must not be reached for horizontal swipes")
    end,
}
QRD.wireTouchPaging(tp_viewer)
local ges_w = { direction = "west",
                pos = { x = 700, intersectWith = function() return true end } }
tp_viewer:onSwipe(nil, ges_w)
eq(tp_down, 1, "paging-wire: west swipe scrolls down (forward)")
QRD.paging_mode = "inverted"
tp_viewer:onSwipe(nil, ges_w)
eq(tp_up, 1, "paging-wire: mode change applies to the open viewer (event-time)")
local tp_stw = tp_viewer.scroll_text_w
tp_stw:onTapScrollText(nil, { pos = { x = 10 } })
eq(tp_down, 2, "paging-wire: inverted left tap scrolls down")
QRD.paging_mode = "auto"
tp_stw:onTapScrollText(nil, { pos = { x = 10 } })
eq(tp_up, 2, "paging-wire: standard left tap scrolls up")

-- quran_reader: generic show() wiring (TextViewer stubbed above)
local nav_hits = {}
QRD.show{
    title = "T", text = "B",
    prev = function() nav_hits[#nav_hits + 1] = "prev" end,
    next = function() nav_hits[#nav_hits + 1] = "next" end,
    extra_buttons = { { text = "X", callback = function()
        nav_hits[#nav_hits + 1] = "extra"
    end } },
}
eq(_shown.title, "T", "reader-show: title")
local rrow = _shown.buttons_table[1]
eq(#rrow, 4, "reader-show: close + prev/next + extra buttons")
rrow[3].callback()
rrow[2].callback()
eq(QRD._viewer ~= nil, true, "reader-show: nav keeps the viewer live (in-place)")
rrow[4].callback()
eq(table.concat(nav_hits, ","), "next,prev,extra", "reader-show: callbacks wired")
eq(QRD._viewer, nil, "reader-show: plain extra button closes the viewer")

-- a second show while a viewer is live UPDATES it in place
QRD.show{ title = "T1", text = "B1" }
local live_viewer = _shown
local shows_before = _show_count
QRD.show{ title = "T2", text = "B2" }
eq(_shown == live_viewer and _show_count == shows_before, true,
    "reader-show: repeat show reuses the SAME viewer (no reopen)")
eq(live_viewer.title, "T2", "reader-show: in-place update swaps the title")
eq(live_viewer.text, "B2", "reader-show: in-place update swaps the text")
live_viewer.buttons_table[1][1].callback()  -- ← close
eq(QRD._viewer, nil, "reader-show: back releases the in-place handle")

-- quran_reader.showAyah: real text package round trip
if have_text and sq3_ok then
    fake_fs = { ["data"] = "directory", ["data/text-v1.sqlite"] = "file" }
    local QT = dofile("tools/quran.koplugin/quran_text.lua")
    eq(QT.findDb({ path = "data" }), text_db, "text-mod: findDb via plugin-dir fallback")
    local tconn2, terr = QT.openPath(text_db)
    eq(tconn2 ~= nil, true, "text-mod: opens with schema gate (" .. tostring(terr) .. ")")
    local a11 = QT.ayah(tconn2, "hafs", 1, 1)
    eq(a11 ~= nil and a11.juz, 1, "text-mod: 1:1 juz meta")
    eq(#QT.translations(tconn2, 1, 1), 1, "text-mod: one shipped translation")
    local rquran = {
        path = "data",
        surahName = function(_, s) return "Surah" .. s end,
        _hafsCounts = function() return C114 end,
        _textModule = function() return QT end,
        canReaderTafsir = function() return false end,
    }
    eq(QRD.showAyah(rquran, 1, 1), true, "reader-ayah: opens from the package")
    eq(_shown.title, "Surah1 1:1", "reader-ayah: title")
    eq(_shown.text:find("Saheeh International", 1, true) ~= nil, true,
        "reader-ayah: translation present")
    eq(_shown.text:find("In the name", 1, true) ~= nil, true,
        "reader-ayah: translation text present")
    eq(#_shown.buttons_table[1], 3, "reader-ayah: close + prev/next (no tafsir button)")
    eq(_shown.buttons_table[1][2].enabled, false,
        "reader-ayah: dead ◀ disabled at 1:1 (mushaf start)")
    eq(_shown.buttons_table[1][3].enabled, true, "reader-ayah: live ▶ enabled")
    _shown.buttons_table[1][2].callback()  -- dead ◀ must be a no-op
    eq(_shown.title, "Surah1 1:1", "reader-ayah: dead direction does not close/step")
    local ayah_viewer, ayah_shows = _shown, _show_count
    _shown.buttons_table[1][3].callback()  -- ▶
    eq(_shown.title, "Surah1 1:2", "reader-ayah: next steps to 1:2")
    eq(_shown == ayah_viewer and _show_count == ayah_shows, true,
        "reader-ayah: ▶ updates IN PLACE (no close/reopen)")
    eq(_shown.buttons_table[1][2].enabled, true,
        "reader-ayah: ◀ live again at 1:2")
    _shown.buttons_table[1][1].callback()  -- ← close before the next block
    local missing_quran = {
        path = "data",
        _textModule = function() return QT end,
    }
    fake_fs = { ["data"] = "directory" }
    QT._conn, QT._db_path = nil, nil
    eq(QRD.showAyah(missing_quran, 1, 1), false,
        "reader-ayah: false when package missing (caller falls back)")
    fake_fs = { ["data"] = "directory", ["data/text-v1.sqlite"] = "file" }
    QT._conn, QT._db_path = nil, nil

    -- opts.explore: browser bridge + Tafsir forwards the flag onward
    local a_explored, a_tafsir_opts
    rquran.openBrowserAtAyah = function(_, s, a) a_explored = s .. ":" .. a end
    rquran.canReaderTafsir = function() return true end
    rquran.openTafsirReader = function(_, _s, _a, o) a_tafsir_opts = o end
    QRD.showAyah(rquran, 2, 255, { explore = true })
    local arow = _shown.buttons_table[1]
    eq(#arow, 5, "reader-ayah: tafsir + explore buttons with opts.explore")
    eq(arow[5].text, "Explore", "reader-ayah: bridge labeled Explore")
    arow[5].callback()
    eq(a_explored, "2:255", "reader-ayah: bridge opens this ayah's page")
    QRD.showAyah(rquran, 2, 255, { explore = true })
    _shown.buttons_table[1][4].callback()  -- Tafsir
    eq(a_tafsir_opts.explore, true, "reader-ayah: tafsir button forwards explore")
    QRD.showAyah(rquran, 2, 255)
    eq(#_shown.buttons_table[1], 4, "reader-ayah: no bridge without the flag")
    rquran.canReaderTafsir = function() return false end
else
    print("skip reader-ayah tests (staged extract or sqlite binding unavailable)")
end

-- quran_reader.showTafsir: headless fetch + group-aware nav (fetch faked).
-- The fetch key comes from the instance's _ayahDictKeys (the dicts index
-- "Al-Baqarah 255"-style headwords, NOT "2:255" — the 2026-07 browser
-- tafsir bug); the fake convention here is "K<s>:<a>".
local tdefs = {
    ["K2:5"] = '<!-- range:2:2-7 --><b>Block</b> two to seven',
    ["K2:8"] = "Eight text",
    ["K2:12"] = "Twelve text",
}
local picker_hit, seen_keys, explored
local tquran = {
    surahName = function(_, s) return "Surah" .. s end,
    _hafsCounts = function() return C114 end,
    _ayahDictKeys = function(_, s, a) return { "K" .. s .. ":" .. a } end,
    _rawDefinition = function(_, _dict, keys)
        seen_keys = keys
        return tdefs[keys[1]]
    end,
    -- coverage probe fake: first ayah in tdefs walking dir
    _firstAyahWithEntry = function(_, _dict, s, a, dir, _max)
        for i = 0, 9 do
            local a2 = a + dir * i
            if tdefs["K" .. s .. ":" .. a2] then return s, a2 end
        end
    end,
    _htmlToText = function(_, h)
        return (h:gsub("<!%-%-.-%-%->", ""):gsub("<[^>]+>", ""))
    end,
    _showTafsirPicker = function(_, s, a) picker_hit = s .. ":" .. a end,
    openBrowserAtAyah = function(_, s, a) explored = s .. ":" .. a end,
}
eq(QRD.showTafsir(tquran, 2, 5, { dict = "Tafsir X" }), true, "reader-tafsir: opens")
eq(seen_keys[1], "K2:5", "reader-tafsir: fetch uses the instance's key convention")
eq(_shown.title, "Tafsir X · Surah2 2:2\226\128\1477", "reader-tafsir: range span title")
eq(_shown.text:find("Block two to seven", 1, true) ~= nil, true,
    "reader-tafsir: definition rendered")
local trow = _shown.buttons_table[1]
eq(#trow, 4, "reader-tafsir: close + prev/next + switch (no bridge from the browser)")
local tafsir_viewer, tafsir_shows = _shown, _show_count
trow[3].callback()  -- ▶ skips the 2:2-7 group
eq(_shown.title, "Tafsir X · Surah2 2:8", "reader-tafsir: next skips to 2:8")
eq(_shown.text, "Eight text", "reader-tafsir: next entry rendered")
eq(_shown == tafsir_viewer and _show_count == tafsir_shows, true,
    "reader-tafsir: group step updates IN PLACE (no close/reopen)")
_shown.buttons_table[1][3].callback()  -- ▶ from 2:8; 2:9–11 uncovered
eq(_shown.title, "Tafsir X · Surah2 2:12",
    "reader-tafsir: stepping skips this dict's coverage gap (no dict switch)")
eq(_shown.text, "Twelve text", "reader-tafsir: gap-skip renders the found entry")
QRD.showTafsir(tquran, 1, 3, { dict = "Tafsir X" })
eq(_shown.text:find("No entry", 1, true) ~= nil, true,
    "reader-tafsir: missing-entry placeholder")
_shown.buttons_table[1][4].callback()  -- Switch
eq(picker_hit, "1:3", "reader-tafsir: switch opens the picker")

-- opts.explore: the browser bridge appears and follows the CURRENT ayah
QRD.showTafsir(tquran, 2, 5, { dict = "Tafsir X", explore = true })
local xrow = _shown.buttons_table[1]
eq(#xrow, 5, "reader-tafsir: explore bridge present with opts.explore")
eq(xrow[5].text, "Explore", "reader-tafsir: bridge labeled Explore")
xrow[3].callback()  -- ▶ skips the group to 2:8 (opts carry explore along)
_shown.buttons_table[1][5].callback()
eq(explored, "2:8", "reader-tafsir: bridge opens the current ayah's page")

-- instances without _ayahDictKeys keep the legacy "%d:%d" fetch key
local tq2 = {
    surahName = tquran.surahName,
    _hafsCounts = tquran._hafsCounts,
    _rawDefinition = function(_, _dict, keys)
        return keys[1] == "1:2" and "legacy" or nil
    end,
    _htmlToText = tquran._htmlToText,
    _showTafsirPicker = function() end,
}
QRD.showTafsir(tq2, 1, 2, { dict = "T" })
eq(_shown.text, "legacy", "reader-tafsir: legacy key fallback without _ayahDictKeys")

-- openTafsirReader (extracted live): preferred-tafsir resolution
local ochunk = "local Quran = {}\n"
    .. extract("--- Open a tafsir for S:A (Hafs numbering)", "--- Tafsir picker:")
    .. "\nreturn Quran\n"
local OT = assert(loadstring(ochunk))()
local ot_calls, ot_picker = {}, nil
local oq
oq = {
    canReaderTafsir = function() return true end,
    _readerModule = function()
        return { showTafsir = function(_q, s, a, o)
            table.insert(ot_calls, o.dict .. "@" .. s .. ":" .. a)
            return true
        end }
    end,
    _installedTafsirs = function() return { "A", "B" } end,
    settings = { readSetting = function(_, _k) return oq._pref end },
    _showTafsirPicker = function(_, s, a) ot_picker = s .. ":" .. a end,
    openTafsirReader = OT.openTafsirReader,
}
eq(oq:openTafsirReader(2, 5), true, "tafsir-pref: multi + no preference handled")
eq(ot_picker, "2:5", "tafsir-pref: picker offered")
oq._pref = "B"
oq:openTafsirReader(2, 6)
eq(ot_calls[1], "B@2:6", "tafsir-pref: preferred setting wins")
oq._installedTafsirs = function() return { "A" } end
oq._pref = nil
oq:openTafsirReader(2, 7)
eq(ot_calls[2], "A@2:7", "tafsir-pref: single installed direct")
oq:openTafsirReader(2, 8, { dict = "Z" })
eq(ot_calls[3], "Z@2:8", "tafsir-pref: explicit dict wins")
oq.canReaderTafsir = function() return false end
eq(oq:openTafsirReader(2, 9), false,
    "tafsir-pref: no rawSdcv -> false (popup fallback)")

-- _ayahDictKeys + _rawDefinition (extracted live): the dict-key
-- convention and the one-call candidate-list fetch
local kchunk = "local SURAH_NAMES = { [2] = 'Al-Baqarah' }\nlocal Quran = {}\n"
    .. extract("--- Dictionary key candidates for S:A",
               "--- Whether the full-screen")
    .. "\nreturn Quran\n"
local K = assert(loadstring(kchunk))()
local kq = { _ayahDictKeys = K._ayahDictKeys, _rawDefinition = K._rawDefinition }
local dkeys = kq:_ayahDictKeys(2, 255)
eq(dkeys[1], "Al-Baqarah 255", "dictkeys: surah-name headword first (the indexed form)")
eq(dkeys[2], "002:255", "dictkeys: zero-padded numeric candidate second")
eq(kq:_ayahDictKeys(3, 5)[1], "003:005", "dictkeys: numeric only when name unknown")
local seen_words, seen_dicts
kq.ui = { dictionary = { rawSdcv = function(_, words, dicts, _fuzzy, _msg)
    seen_words, seen_dicts = words, dicts
    return false, { {}, { { definition = "" }, { definition = "HIT" } } }
end } }
eq(kq:_rawDefinition("Dict A", { "k1", "k2" }), "HIT",
    "rawdef: later candidate's non-empty definition wins")
eq(#seen_words, 2, "rawdef: all candidates in one sdcv call")
eq(seen_dicts[1], "Dict A", "rawdef: dict-name filter passed")
kq.ui.dictionary.rawSdcv = function() return true, nil end
eq(kq:_rawDefinition("Dict A", { "k" }), nil, "rawdef: cancelled -> nil")
kq.ui.dictionary.rawSdcv = function(_, words)
    seen_words = words
    return false, { { { definition = "D" } } }
end
eq(kq:_rawDefinition("Dict A", "solo"), "D", "rawdef: plain-string key accepted")
eq(seen_words[1], "solo", "rawdef: string key wrapped to a list")

-- Every qul ayah reference routes to the unified ayah page (design D4:
-- the jump/read ButtonDialog is retired)
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, spec) return spec end }
end
package.loaded["ui/widget/buttondialog"] = nil
if have_qul and sq3_ok then
    local dq = {
        surahName = function(_, s) return "Surah" .. s end,
        _qul_mod = nil, path = "data",
    }
    local QQ2 = dofile("tools/quran.koplugin/quran_qul.lua")
    local nav_items, uap_route
    local fb = {
        quran = dq,
        navigateForward = function(_, _title, items) nav_items = items end,
        showAyahPage = function(_, s, a) uap_route = s .. ":" .. a end,
    }
    local qconn2 = QQ2.openPath(qul_db)
    eq(qconn2 ~= nil, true, "uap-route: qul db reopened")
    QQ2.showSimilar(fb, 1, 1)
    eq(nav_items ~= nil and #nav_items > 0, true, "uap-route: similar items built")
    nav_items[1].callback()
    eq(uap_route, "27:30", "uap-route: similar item opens the unified ayah page")
else
    print("skip uap-route tests (qul build or sqlite binding unavailable)")
end

-- Global search (Wave S): FTS queries + the browser flow (text db real)
if have_text and sq3_ok then
    local SQ3s = require("lua-ljsqlite3/init")
    local sconn = SQ3s.open(text_db, "ro")
    local QNs = dofile("tools/quran.koplugin/quran_norm.lua")
    local QTs = dofile("tools/quran.koplugin/quran_text.lua")
    local fq = QNs.norm("\216\168\216\179\217\133 \216\167\217\132\217\132\217\135")  -- بسم الله
    local ah = QTs.searchAyahText(sconn, fq, 20)
    local has11 = false
    for _i, h in ipairs(ah) do
        if h.surah == 1 and h.ayah == 1 then has11 = true end
    end
    eq(has11, true, "search: arabic FTS finds 1:1")
    eq(ah[1].text ~= "", true, "search: ayah hit carries display text")
    local eh = QTs.searchTranslation(sconn, "entirely merciful", 20)
    local ehas11 = false
    for _i, h in ipairs(eh) do
        if h.surah == 1 and h.ayah == 1 then ehas11 = true end
    end
    eq(ehas11, true, "search: english FTS finds 1:1")
    sconn:close()

    -- browser flow: root Search → InputDialog → grouped results → UAP
    local search_input = { q = "" }
    package.preload["ui/widget/inputdialog"] = function()
        return { new = function(_, spec)
            spec.getInputText = function() return search_input.q end
            return spec
        end }
    end
    package.loaded["ui/widget/inputdialog"] = nil
    fake_fs = { ["data"] = "directory", ["data/text-v1.sqlite"] = "file" }
    local bq_search = {
        _is_quran_book = true,
        path = "data",
        ui = { document = mk_dom_doc(32.7), handleEvent = function() end,
               dictionary = { enabled_dict_names = {} } },
        bookAyahCount = function(_, s2) return s2 == 77 and 50 or 20 end,
        _findSurahForPage = function(_, _) return 77 end,
        _warshToHafs = function(_, _s2, a2) return a2 end,
        _hafsToWarsh = function(_, _s2, a2) return a2 end,
        surahName = function(_, s2) return "Surah" .. s2 end,
        surahNameArabic = function(_, s2) return "AR" .. s2 end,
        juzBoundary = function(_, j) return (j <= 30) and 2 or nil, 100 + j end,
        openAyahPopup = function() end,
        openSurahOverviewPopup = function() end,
    }
    bq_search.ui.document.getCurrentPage = function() return 580 end
    -- path="data" lets findDb locate the staged sqlite through the fake
    -- fs, but module siblings live in the plugin dir — pre-seed the
    -- loadSibling caches with real module instances
    bq_search._norm_mod = dofile("tools/quran.koplugin/quran_norm.lua")
    bq_search._text_mod = dofile("tools/quran.koplugin/quran_text.lua")
    QB.show(bq_search, QA)
    local menu_obj = _shown
    _shown.item_table[2].callback()  -- Search → InputDialog (stub)
    search_input.q = "entirely merciful"
    _shown.buttons[1][2].callback()  -- Search button
    local res_items = menu_obj.item_table
    eq(menu_obj.title:find("entirely merciful", 1, true) ~= nil, true,
        "search: results title carries the query")
    eq(res_items[1].text, "Search again", "search: retry row first")
    local first_hit
    for _i, it in ipairs(res_items) do
        if it.text:find("^1:1 ") then first_hit = it break end
    end
    eq(first_hit ~= nil, true, "search: 1:1 hit listed")
    first_hit.callback()
    eq(menu_obj.title, "Surah1 1:1", "search: hit routes to the unified ayah page")
else
    print("skip search tests (staged extract or sqlite binding unavailable)")
end

-- REAL-ENGINE integration: load the actual CREngine + a real built EPUB
-- and run the REAL detection/jump code against it (the 2026-07-12 anchor
-- root cause was only visible here — every pure-Lua fake had encoded the
-- wrong assumption that "#ayah-S-A" resolves).
local APP = "/Applications/KOReader.app/Contents/koreader"
local CRE_BOOK = "output/quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-sahih.epub"
local book_f = io.open(CRE_BOOK)
if book_f then book_f:close() end
package.cpath = APP .. "/?.so;" .. APP .. "/libs/?.so;" .. package.cpath
local cre_ok, cre = pcall(require, "libs/libkoreader-cre")
if book_f and cre_ok then
    cre.initCache("/tmp/quran_check_cr3cache", 1024 * 1024 * 32, true, 40)
    pcall(cre.initHyphDict, APP .. "/data/hyph/")
    pcall(cre.registerFont, APP .. "/fonts/noto/NotoSans-Regular.ttf")
    pcall(cre.registerFont, APP .. "/fonts/noto/NotoNaskhArabic-Regular.ttf")
    local doc = cre.newDocView(600, 800, 0)
    assert(doc:loadDocument(CRE_BOOK), "cre: loadDocument failed")
    doc:renderDocument()
    eq(QA.fragPrefix(doc:getXPointer()) ~= nil, true, "cre: view xpointer carries a fragment")
    local cq = {
        ui = { document = doc },
        bookAyahCount = function(_, ss) return ss == 77 and 50 or nil end,
        _findSurahForPage = function(_, _) return 77 end,
    }
    local p77 = QA.resolveAnchorPage(cq, 77, nil)
    eq(p77 ~= nil and p77 > 1, true, "cre: surah-77 header resolves to a real page")
    local p33 = QA.resolveAnchorPage(cq, 77, 33)
    eq(p33 ~= nil and p33 > p77, true, "cre: ayah end-marker resolves past the header")
    doc:gotoPage(p33)
    local ds, da = QA.findAyahForPage(cq, doc:getCurrentPage())
    eq(ds, 77, "cre: detection surah")
    eq(da ~= nil and da >= 28 and da <= 36, true,
        "cre: detected ayah near the viewed page (" .. tostring(da) .. "), not 1/50/nil")
    -- the containment path must fire on this layout (view-top block is
    -- an ayah paragraph carrying id= or ayah-ref)
    local okh, html = pcall(doc.getHTMLFromXPointer, doc, doc:getXPointer(), 0, true)
    local ch = okh and html and
        (html:match('id="ayah%-%d+%-%d+"') or html:match('class="ayah%-ref">%d+:%d+<'))
    eq(ch ~= nil, true, "cre: containment marker present on the view-top block")
    -- anchor convention: this ayah-inline book puts the id on the ayah's
    -- own <p> (probed 2026-07-12) — jumps must resolve anchor A itself
    eq(QA.anchorConvention(cq), "start", "cre: ayah-inline book is start-anchored")
    local p32 = QA.resolveAnchorPage(cq, 77, 32)
    eq(p32 ~= nil and p33 ~= nil and p32 <= p33, true,
        "cre: monotone anchors for the goto fix")
    -- visible range on the page we jumped to: starts at the detected ayah
    cq.bookAyahCount = function(_, ss) return ss == 77 and 50 or nil end
    local rs2, rf2, rl2 = QA.visibleAyahRange(cq)
    eq(rs2, 77, "cre: visible range surah")
    eq(rf2 ~= nil and rl2 ~= nil and rf2 <= rl2, true,
        "cre: visible range well-formed (" .. tostring(rf2) .. "-" .. tostring(rl2) .. ")")
    eq(rf2 == da, true, "cre: range starts at the detected ayah")
    doc:close()
else
    print("skip cre integration tests (app bundle or built EPUB unavailable)")
end

print("ALL HELPER TESTS PASS")
