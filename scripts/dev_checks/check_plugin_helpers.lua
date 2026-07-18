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
            m.swipe_log = {}
            m.onSwipe = function(self2, _arg, ges)
                table.insert(self2.swipe_log, ges.direction)
            end
            m.title_bar_left_icon = spec.title_bar_left_icon
            m.onLeftButtonTap = spec.onLeftButtonTap
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
eq(#root, 12, "browser: 12 root items (D-R3-7a corpus rows + DA-7 Figures/Stories)")
eq(root[1].text:find("Surah77 77:33", 1, true) ~= nil, true,
    "browser: root shows detected position")
eq(root[2].text, "Search", "browser: global search row")
root[3].callback()  -- Surahs
eq(_shown.switch_log[1].n, 114, "browser: surah list has 114 items")
_shown.item_table[10].callback()  -- surah 10 screen
eq(_shown.switch_log[2].n, 11,
    "browser: surah screen is the HUB (3 base + 2 corpus + 4 conn + 2 DA-7 rows)")
local hub = _shown.item_table
eq(hub[4].text, "Tafsir", "hub: this-surah tafsir row")
eq(hub[5].text, "I'rab", "hub: this-surah i'rab row")
eq(hub[6].text, "Themes", "hub: themes row")
eq(hub[7].text, "Topics", "hub: topics row")
eq(hub[8].text, "Similar ayahs", "hub: similar row")
eq(hub[9].text, "Repeated phrases (mutashabihat)", "hub: phrases row (long label in the browser)")
eq(hub[10].text, "Figures", "hub: DA-7 figures row")
eq(hub[11].text, "Narratives", "hub: DA-7 narratives row")
eq(hub[6].dim, true, "hub: conn rows dim without the qul package")
eq(hub[10].dim, true, "hub: DA-7 rows dim without the connections package")
-- R3-F18: the surah screen's overview row rides the unified route
-- (it always opened the popup before — opposite of the quick panel).
-- Resources are detected at BUILD time, so install the overview dict
-- BEFORE navigating to the screen.
eq(_shown.item_table[2].text, "Surah overview",
    "r3-f18: overview row on the surah screen")
eq(_shown.item_table[2].dim, true,
    "r3-f19: overview row dims without an overview dict")
eq(_shown.item_table[3].text, "Ayahs", "r3-f20: ayah count in the count column")
eq(_shown.item_table[3].mandatory, "20", "r3-f20: surah-screen ayah count value")
bq.ui.dictionary.enabled_dict_names = {
    "Tafsir al-Muyassar (المیسر)", "Quran I'rab", "Surah Overviews (X)",
}
bq.canReaderTafsir = function() return true end
local ov_opened
bq._readerModule = function()
    return { showOverview = function(_q, s2, o2)
        ov_opened = s2 .. "|" .. tostring(o2.back_label)
        return true
    end }
end
QB.show(bq, QA)
_shown.item_table[3].callback()   -- Surahs
_shown.item_table[10].callback()  -- surah 10 screen (overview installed)
local ov_row = _shown.item_table[2]
eq(ov_row.dim, nil, "r3-f18: overview row live with the dict installed")
ov_row.callback()
eq(ov_opened, "10|←",
    "r3-f18: overview opens on the Reader route with the bare arrow")
bq._openTargetFor = function(_, k)
    return k == "overview" and "popup" or "reader"
end
local ov_popup
bq.openSurahOverviewPopup = function(_, s2) ov_popup = s2 end
ov_row.callback()
eq(ov_popup, 10, "r3-f18: a popup target routes the row to the popup")
bq._openTargetFor = nil
bq.openSurahOverviewPopup = function() end
bq._readerModule = nil
bq.canReaderTafsir = nil
bq.ui.dictionary.enabled_dict_names = {
    "Tafsir al-Muyassar (المیسر)", "Quran I'rab",
}
QB.show(bq, QA)  -- fresh instance
_shown.item_table[4].callback()  -- Juz
eq(_shown.switch_log[1].n, 30, "browser: juz list has 30 items")
QB.show(bq, QA)
_shown.item_table[1].callback()  -- Current position → unified ayah page
local pos_items = _shown.item_table
eq(_shown.title, "Surah77 77:33", "uap: position lands on the ayah page")
eq(pos_items[1].text, "Translations", "uap: Translations row first (D-R3-3)")
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
_shown.item_table[#_shown.item_table].callback()  -- Library & assets (last root item)
eq(_shown.switch_log[1].title, "Library & assets", "assets: library screen opens")
eq(_shown.switch_log[1].n, 6, "assets: library screen has 6 items (incl. data packages + relocated Restore)")

-- D-R3-6 plumbing: a screen can opt into two-line rows; navigateBack
-- restores the previous screen's mode from the nav frame
do
QB.show(bq, QA, function(b)
    local was = b.menu.single_line
    b:navigateForward("ML", {}, nil, { multiline = true })
    eq(b.menu.single_line, false, "browser: multiline screen unsets single_line")
    eq(b.menu.items_max_lines, 2,
        "browser: multiline screen gets 2-line items (the mechanism that wraps)")
    b:navigateBack()
    eq(b.menu.single_line, was, "browser: back restores the single-line mode")
    eq(b.menu.items_max_lines, nil, "browser: back clears items_max_lines")
end)
end

-- Content-first resource browsing (D-R2-2 → D-R3-7a): per-corpus
-- root rows + drill-down flow
do
QB.show(bq, QA)
local taf_row, irab_row, res_leftover
for _i, it in ipairs(_shown.item_table) do
    if it.text == "Tafsirs" then taf_row = it end
    if it.text == "I'rab" then irab_row = it end
    if it.text == "Resources" then res_leftover = it end
end
eq(res_leftover, nil, "root-ia: no Resources dump row (D-R3-7a)")
eq(taf_row ~= nil, true, "root-ia: Tafsirs promoted to root")
eq(taf_row.mandatory, "1", "root-ia: Tafsirs row counts installed tafsirs")
eq(irab_row ~= nil, true, "root-ia: I'rab promoted to root")
bq._dictAyahItems = function(_, name)
    if name == "Tafsir al-Muyassar (المیسر)" then
        return { { surah = 2, a1 = 6, a2 = 7 }, { surah = 2, a1 = 8, a2 = 8 },
                 { surah = 3, a1 = 1, a2 = 4 } },
               { [2] = 2, [3] = 1 }
    end
    return nil
end
local res_opened = {}
bq.canReaderTafsir = function() return false end
bq.openTafsirReader = function(_, s2, a2, o2)
    table.insert(res_opened, s2 .. ":" .. a2 .. ":" .. tostring(o2.dict))
    return true
end
taf_row.callback()  -- single tafsir → straight into its surah list
eq(_shown.item_table[1].text, "2. Surah2",
    "root-ia: single tafsir goes straight to surahs-with-entries")
eq(_shown.item_table[1].mandatory, "2", "resources: per-surah entry count")
eq(#_shown.item_table, 2, "resources: only covered surahs listed")
_shown.item_table[1].callback()  -- surah 2 entries
eq(_shown.item_table[1].text, "2:6–7", "resources: group row shows covered range")
eq(_shown.item_table[2].text, "2:8", "resources: single-ayah row")
_shown.item_table[1].callback()  -- open the entry
eq(res_opened[1], "2:6:Tafsir al-Muyassar (المیسر)",
    "resources: entry opens the Reader at the group start with its dict")
-- two tafsirs: the root row counts them and opens a picker list
bq.ui.dictionary.enabled_dict_names = {
    "Tafsir al-Muyassar (المیسر)", "Tafsir Ibn Kathir (English)",
    "Quran I'rab",
}
QB.show(bq, QA)
for _i, it in ipairs(_shown.item_table) do
    if it.text == "Tafsirs" then taf_row = it end
end
eq(taf_row.mandatory, "2", "root-ia: Tafsirs counts both installed tafsirs")
taf_row.callback()
eq(#_shown.item_table, 2, "root-ia: multi-tafsir row opens the picker list")
eq(_shown.item_table[2].text, "Tafsir Ibn Kathir (English)",
    "root-ia: picker lists each tafsir")
bq.ui.dictionary.enabled_dict_names = {
    "Tafsir al-Muyassar (المیسر)", "Quran I'rab",
}
bq._dictAyahItems = nil
bq.openTafsirReader = nil
bq.canReaderTafsir = nil
end

-- D-R2-7: browser page-swipes follow the plugin paging policy
do
QB.show(bq, QA)
local inv = false
bq._readerModule = function()
    return { pagingInverted = function() return inv end }
end
_shown:onSwipe(nil, { direction = "west" })
eq(_shown.swipe_log[1], "west", "browser-paging: standard swipe passes through")
inv = true
_shown:onSwipe(nil, { direction = "west" })
eq(_shown.swipe_log[2], "east",
    "browser-paging: inverted policy flips horizontal page swipes")
_shown:onSwipe(nil, { direction = "south" })
eq(_shown.swipe_log[3], "south", "browser-paging: vertical swipes untouched")
bq._readerModule = nil
end

-- R3-F21 (was D-R2-7b): the browser hamburger is a settings-led
-- context menu; paging direction is ONE row that opens the submenu
do
QB.show(bq, QA)
eq(_shown.title_bar_left_icon, "appbar.menu",
    "browser-hamburger: left icon requested on the Menu title bar")
local ham_shown = false
bq._readerModule = function()
    return {
        showPagingMenu = function() ham_shown = true end,
        pagingModeLabel = function() return "match book" end,
    }
end
bq.showSettingsMenu = function() end
package.preload["ui/widget/buttondialog"] =
    package.preload["ui/widget/buttondialog"] or function()
        return { new = function(_, o) return o end }
    end
local root_menu = _shown
root_menu.onLeftButtonTap()
local ctx = _shown
eq(ctx ~= root_menu, true, "r3-f21: tap opens a context menu, not paging")
eq(ctx.buttons[1][1].text, "Quran Helper settings",
    "r3-f21: settings row leads the hamburger")
eq(ctx.buttons[2][1].text:find("Paging direction", 1, true), 1,
    "r3-f21: paging direction is one labeled row")
eq(ham_shown, false, "r3-f21: the paging menu is not the hamburger itself")
ctx.buttons[2][1].callback()
eq(ham_shown, true, "r3-f21: the paging row opens the paging quick menu")
bq._readerModule = nil
bq.showSettingsMenu = nil
end

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
        isTrue = function(_, k)
            if k == "show_header_overlay" then return true end
            return m_notice == true
        end,
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

-- onPreRenderDocument (margin round 2026-07-16): the margin is raised
-- BEFORE the initial render, every open, at zero re-render cost — the
-- loop-guard case (marker present + margin low again) re-raises instead
-- of warning, because pre-render raising is free
m_fired, m_marker, m_notice = nil, nil, nil
mq.ui.document.configurable.t_page_margin = 10
mq.onPreRenderDocument = MH.onPreRenderDocument
mq:onPreRenderDocument()
eq(m_fired and m_fired.value, 24, "pre-render: first open raises before render")
eq(m_marker, 10, "pre-render: pre-bump margin remembered")
m_fired = nil
mq.ui.document.configurable.t_page_margin = 10  -- global margin reapplied
mq:onPreRenderDocument()
eq(m_fired and m_fired.value, 24,
    "pre-render: marker present + low margin STILL raises (free pre-render;"
    .. " no loop guard needed)")
eq(m_marker, 10, "pre-render: original margin marker never overwritten")
m_fired = nil
mq.ui.document.configurable.t_page_margin = 24
mq:onPreRenderDocument()
eq(m_fired, nil, "pre-render: sufficient margin -> no-op")
local m_saved_flag = m_notice
eq(m_saved_flag, nil, "pre-render: never shows the notice")

-- spliceDictOrder (D-R2-4 dict-order slice): pure splice, extracted live
do
local schunk = extract(
        "local function spliceDictOrder(enabled, reordered, is_quran)",
        "--- Plugin-side popup dictionary ordering")
    .. "\nreturn spliceDictOrder\n"
local splice = assert(loadstring(schunk))()
local function is_q(name) return name:find("Q") ~= nil end
eq(table.concat(splice(
    { "Qa", "gnu", "Qb", "webster", "Qc" }, { "Qc", "Qa", "Qb" }, is_q), ","),
    "Qc,gnu,Qa,webster,Qb",
    "dict-order: quran subset spliced, others keep their positions")
eq(table.concat(splice({ "gnu", "webster" }, {}, is_q), ","),
    "gnu,webster", "dict-order: no quran dicts -> unchanged")
end

-- _divertAyahAction (D-R2-4a v2): action dispatch AFTER the popup
-- path's own surah/ayah resolution (v1 resolved independently at the
-- onLookupWord patch and could act on a STALE selection stash — opened
-- surah 83 instead of 80, then stopped diverting once the stash was
-- consumed; owner report 2026-07-16)
do
local dchunk = "local Quran = {}\n"
    .. extract("function Quran:_divertAyahAction",
               "--- Open a FRESH ayah-keyed dictionary popup")
    .. "\nreturn Quran\n"
local DV = assert(loadstring(dchunk))()
UIM.nextTick = function(_, fn) fn() end
local dv_log, dv_action, dv_can, dv_ayah_row, dv_cleared, dv_ap
local dvq
local function dv_reset(action)
    dv_log, dv_cleared = {}, 0
    dv_action = action
    dv_ap = true
    dvq = {
        _divertAyahAction = DV._divertAyahAction,
        settings = { readSetting = function(_, _k, d) return dv_action or d end },
        canReaderTafsir = function() return dv_can end,
        _installedTafsirs = function() return dv_can and { "T" } or {} end,
        openTafsirReader = function(_, s, a, o)
            table.insert(dv_log, "tafsir:" .. s .. ":" .. a .. ":" .. tostring(o.explore))
            return true
        end,
        openBrowserAtAyah = function(_, s, a)
            table.insert(dv_log, "uap:" .. s .. ":" .. a)
        end,
        _actionsModule = function() return { showBrowser = function() end } end,
        _ayahPopupModule = function()
            return dv_ap and { show = function(_q, s, a)
                table.insert(dv_log, "card:" .. s .. ":" .. a)
                return true
            end } or nil
        end,
        _textModule = function()
            return {
                ensureDb = function() return {} end,
                ayah = function() return dv_ayah_row end,
            }
        end,
        _readerModule = function()
            return { showAyah = function(_q, s, a, _o)
                table.insert(dv_log, "ayah:" .. s .. ":" .. a)
                return true
            end }
        end,
        ui = { highlight = { clear = function() dv_cleared = dv_cleared + 1 end } },
    }
end
dv_reset(nil)  -- default action = ayah card (D-R2-9)
eq(dvq:_divertAyahAction(80, 5), true, "divert2: DEFAULT diverts to the ayah card")
eq(dv_log[1], "card:80:5", "divert2: card receives the resolved ayah")
dv_reset("popup")
eq(dvq:_divertAyahAction(80, 5), nil, "divert2: explicit popup action -> no divert")
dv_reset("card"); dv_ap = false
eq(dvq:_divertAyahAction(80, 5), nil, "divert2: card unavailable -> popup fallback")
dv_reset("tafsir"); dv_can = true
eq(dvq:_divertAyahAction(80, 5), true, "divert2: tafsir action diverts")
eq(dv_log[1], "tafsir:80:5:true",
    "divert2: EXACT resolved surah/ayah + explore flag (no re-derivation)")
eq(dv_cleared, 1, "divert2: selection highlight cleared")
dv_reset("tafsir"); dv_can = false
eq(dvq:_divertAyahAction(80, 5), nil, "divert2: no Reader path -> popup fallback")
eq(#dv_log, 0, "divert2: nothing opened on fallback")
eq(dv_cleared, 0, "divert2: highlight untouched on fallback")
dv_reset("ayah_page")
eq(dvq:_divertAyahAction(80, 5), true, "divert2: ayah page action")
eq(dv_log[1], "uap:80:5", "divert2: browser lands on the resolved ayah")
dv_reset("translation"); dv_ayah_row = {}
eq(dvq:_divertAyahAction(80, 5), true, "divert2: translation action")
eq(dv_log[1], "ayah:80:5", "divert2: Reader shows the resolved ayah")
dv_reset("translation"); dv_ayah_row = nil
eq(dvq:_divertAyahAction(80, 5), nil,
    "divert2: ayah missing from the text package -> popup fallback")
end

-- _findSurahForPosition: DOM-order rewrite (owner repro 2026-07-16 —
-- clamped TOC pages credited surah 83/84 for presses in surah 80;
-- popup keyed "Al-Inshiqaq 31" and fuzzy-matched ayah 1)
do
local tchunk = "logger = { dbg = function() end }\n"
    .. "extractSurahInfo = function(t)\n"
    .. "    local n = t:match('(%d+)')\n"
    .. "    return n and tonumber(n) or nil, t\n"
    .. "end\n"
    .. "local Quran = {}\n"
    .. extract("function Quran:_findSurahForPosition(pos)",
               "--- Called during word selection")
    .. "\nreturn Quran\n"
local TS = assert(loadstring(tchunk))()
-- clamp simulation: every TOC page says 10 (the pagination frontier),
-- xpointers carry the true DOM order
local ts_entries = {
    { title = "80 Abasa", page = 10, xpointer = 1 },
    { title = "81 At-Takwir", page = 10, xpointer = 5 },
    { title = "83 Al-Mutaffifin", page = 10, xpointer = 8 },
}
local tsq = {
    _findSurahForPosition = TS._findSurahForPosition,
    ui = {
        toc = { fillToc = function() end, toc = ts_entries,
                cleanUpTocTitle = function(_, t) return t end },
        document = {
            compareXPointers = function(_, a, b)
                if a == b then return 0 end
                return b > a and 1 or -1
            end,
            getPageFromXPointer = function() return 10 end,
        },
    },
}
eq(tsq:_findSurahForPosition(3), 80,
    "surah-pos: DOM order immune to the page clamp (was 83)")
eq(tsq:_findSurahForPosition(9), 83,
    "surah-pos: later position resolves the later surah")
eq(tsq:_findSurahForPosition(1), 80,
    "surah-pos: press exactly at the surah header counts as inside it")
tsq.ui.document.compareXPointers = nil
eq(tsq:_findSurahForPosition(3), 83,
    "surah-pos: page-only fallback keeps working (clamped = old behavior)")
ts_entries[2].xpointer = nil  -- mixed: one entry page-only
tsq.ui.document.compareXPointers = function(_, a, b)
    if a == b then return 0 end
    return b > a and 1 or -1
end
eq(tsq:_findSurahForPosition(3), 81,
    "surah-pos: page-only entry may still over-credit under clamp"
    .. " (per-entry fallback, documented limit)")
eq(tsq:_findSurahForPosition(9), 83,
    "surah-pos: mixed toc, later press unaffected")
end

-- _findSurahForPage: current-page queries ride the DOM-order path
-- (owner repro 2026-07-16 №2: header/browser said Al-Buruj on
-- At-Takwir's first page — clamped TOC pages, exposed once F4's
-- pre-render margin removed the accidental post-load re-render)
do
local pchunk = "logger = { dbg = function() end }\n"
    .. "extractSurahInfo = function(t)\n"
    .. "    local n = t:match('(%d+)')\n"
    .. "    return n and tonumber(n) or nil, t\n"
    .. "end\n"
    .. "local Quran = {}\n"
    .. extract("function Quran:_findSurahForPosition(pos)",
               "--- Called during word selection")
    .. extract("function Quran:_findSurahForPage(pageno)",
               "--- Convert integer to Arabic-Indic")
    .. "\nreturn Quran\n"
local PS = assert(loadstring(pchunk))()
-- clamp simulation: reader is on At-Takwir (81), page 20; the TOC pages
-- of every later surah CLAMP to 20 (the pagination frontier), so the
-- page scan credits 85 — the DOM order must win for the current page
local ps_entries = {
    { title = "80 Abasa", page = 18, xpointer = 1 },
    { title = "81 At-Takwir", page = 20, xpointer = 5 },
    { title = "82 Al-Infitar", page = 20, xpointer = 8 },
    { title = "84 Al-Inshiqaq", page = 20, xpointer = 10 },
    { title = "85 Al-Buruj", page = 20, xpointer = 12 },
}
local psq = {
    _findSurahForPosition = PS._findSurahForPosition,
    _findSurahForPage = PS._findSurahForPage,
    ui = {
        toc = { fillToc = function() end, toc = ps_entries,
                cleanUpTocTitle = function(_, t) return t end },
        document = {
            getCurrentPage = function() return 20 end,
            getXPointer = function() return 6 end,  -- inside At-Takwir
            compareXPointers = function(_, a, b)
                if a == b then return 0 end
                return b > a and 1 or -1
            end,
            getPageFromXPointer = function() return 20 end,
        },
    },
}
eq(psq:_findSurahForPage(20), 81,
    "surah-page: current page rides DOM order (was 85 / Al-Buruj)")
eq(psq:_findSurahForPage(18), 80,
    "surah-page: non-current page keeps the page scan")
psq.ui.document.getXPointer = nil
eq(psq:_findSurahForPage(20), 85,
    "surah-page: no view xpointer -> page scan (documented clamp limit)")
ps_entries[5].page = 2        -- validateAndFixToc corruption
ps_entries[5].orig_page = 22  -- the real page, beyond the current one
eq(psq:_findSurahForPage(20), 84,
    "surah-page: orig_page beats a fixer-corrupted page in the scan")
end

-- Content-first enumeration (D-R2-2): StarDict .idx parser + ayah-key
-- grouping, extracted live from main.lua
do
local ichunk = extract("local SURAH_NAMES = {", "local SURAH_NAMES_ARABIC")
    .. extract("-- Reverse lookup: surah name -> surah number",
               "--- Normalize Arabic for surah-name matching")
    .. extract("local function parseStarDictIdx(data)",
               "--- Resolve an enabled dictionary bookname")
    .. "\nreturn { parse = parseStarDictIdx, keyinfo = ayahKeyInfo,"
    .. " group = groupAyahKeys }\n"
local IDX = assert(loadstring(ichunk))()

local function be32(n)
    return string.char(math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end
local function idxrec(word, off, size)
    return word .. "\0" .. be32(off) .. be32(size)
end
local idx_blob = idxrec("Al-Baqarah 6", 0, 10) .. idxrec("Al-Baqarah 7", 0, 10)
    .. idxrec("002:006", 0, 10)           -- legacy synonym key, same entry
    .. idxrec("Al-Baqarah 8", 10, 70000)  -- multi-byte size
    .. idxrec("Al-Fatihah", 80010, 4)     -- bare surah-name key (overview)
    .. idxrec("junk key", 99, 1)          -- foreign dict key
local recs = IDX.parse(idx_blob)
eq(#recs, 6, "idx: parses all records")
eq(recs[4].offset, 10, "idx: 32-bit BE offset")
eq(recs[4].size, 70000, "idx: 32-bit BE size crosses byte boundaries")
local is_, ia_ = IDX.keyinfo("Al-Baqarah 255")
eq(is_ .. ":" .. ia_, "2:255", "idx: surah-name ayah key")
is_, ia_ = IDX.keyinfo("002:006")
eq(is_ .. ":" .. ia_, "2:6", "idx: legacy zero-padded key")
is_, ia_ = IDX.keyinfo("Al-Fatihah")
eq(is_ .. ":" .. tostring(ia_), "1:nil", "idx: bare surah-name key")
eq(IDX.keyinfo("junk key"), nil, "idx: foreign key ignored")
local iditems, idby = IDX.group(recs)
eq(#iditems, 3, "idx: synonym + covered-ayah keys collapse to one item")
eq(iditems[1].surah, 1, "idx: mushaf order (bare-name item first)")
eq(iditems[2].a1 .. "-" .. iditems[2].a2, "6-7", "idx: group covered range")
eq(iditems[3].a1, 8, "idx: single-ayah item")
eq(idby[2], 2, "idx: per-surah item count")

-- real .idx round trips (gated on local availability)
local fidx = io.open("output/stardict/quran_qpc_en.idx", "rb")
if fidx then
    local blob = fidx:read("*a"); fidx:close()
    -- 71399 since the 2026-07-18 L2 lemma rebuild (+2 entry splits from
    -- labeled EQTB variants)
    eq(#IDX.parse(blob), 71399, "idx: real word-dict idx fully parsed")
end
local aidx = io.open((os.getenv("HOME") or "")
    .. "/Library/Application Support/koreader/data/dict/stardict/"
    .. "quran_asbab_wahidi.idx", "rb")
if aidx then
    local blob = aidx:read("*a"); aidx:close()
    local arecs = IDX.parse(blob)
    local aitems = IDX.group(arecs)
    eq(#arecs, 398, "idx-asbab: all 398 keys parsed (installed dict)")
    eq(#aitems, 329, "idx-asbab: 329 occasion groups")
    eq(aitems[1].surah, 1, "idx-asbab: first occasion in Al-Fatihah")
end
end

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

-- D-R2-1: shared root-list row shape (landing / letter / search)
eq(QR.rootItemText({ arabic = "عذب", gloss = "Punishment" }),
    "ع-ذ-ب — Punishment", "roots-row: dashed root + dominant gloss")
eq(QR.rootItemText({ arabic = "عذب" }), "ع-ذ-ب", "roots-row: glossless root bare")
eq(QR.rootItemMandatory({ top_freq = 322, n = 23 }), "×322",
    "roots-row: Quran count on the right")
eq(QR.rootItemMandatory({ top_freq = 0, n = 7 }), "7",
    "roots-row: freq-0 falls back to entry count")

-- D-R2-1: entity-screen summary lead (frequency-first over top3 marks)
local sum_hws = QR.markTop3({
    { seq = 1, quran_freq = 43, gloss = "sweet" },
    { seq = 2, quran_freq = 0, gloss = "" },
    { seq = 3, quran_freq = 322, gloss = "punishment" },
})
local lead = QR.summaryIndexes(sum_hws)
eq(#lead, 2, "roots-sum: only freq-carrying entries lead")
eq(lead[1], 3, "roots-sum: highest freq first (not seq order)")
eq(lead[2], 1, "roots-sum: second sense follows")
-- a glossless starred row (ربب's رُبَ) yields to glossed siblings
local lead_gl = QR.summaryIndexes(QR.markTop3({
    { seq = 1, quran_freq = 975, gloss = "He was its lord" },
    { seq = 2, quran_freq = 975, gloss = "" },
    { seq = 3, quran_freq = 975, gloss = "A lord, a possessor" },
}))
eq(#lead_gl, 2, "roots-sum: glossless starred row never leads")
eq(lead_gl[1], 1, "roots-sum: glossed rows keep freq/seq order")
local lead0 = QR.summaryIndexes({
    { seq = 1, quran_freq = 0 },
    { seq = 2, quran_freq = 0, gloss = "a tree" },
})
eq(#lead0, 1, "roots-sum: freq-0 root leads with one entry")
eq(lead0[1], 2, "roots-sum: first GLOSSED entry preferred")
eq(QR.summaryIndexes({ { seq = 1 } })[1], 1,
    "roots-sum: glossless article still leads with its first entry")

-- _registerRootDictButton: the ≥2026.05 word-popup button (extracted live;
-- exercises show_func/callback with the REAL root parser)
local regchunk = "local _ = function(s) return s end\nlocal Quran = {}\n"
    .. extract("--- Register the word-popup Root-explorer button",
               "--- Detect whether the current book is a quran-ebook EPUB")
    .. "\nreturn Quran\n"
local REG = assert(loadstring(regchunk))()
local captured_spec, opened_root, opened_wid, closed
local regq = {
    _is_quran_book = true,
    _rootsModule = function() return QR end,
    _registerRootDictButton = REG._registerRootDictButton,
    openRootExplorer = function(_, root, wid) opened_root, opened_wid = root, wid end,
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
eq(opened_wid, nil, "rootbtn: no instance ref → no word_id")

-- the instance ref rides along as the morphology word_id (B2 landing)
do
    eq(QR.parseRefWordId("<!-- ref:79:11:3 -->decayed …"), 79011003,
        "rootbtn: ref comment → spine word_id")
    eq(QR.parseRefWordId("<!-- ref:2:5:3,3:1:2 -->x"), 2005003,
        "rootbtn: multi-instance entry uses its first ref")
    eq(QR.parseRefWordId("no comment here"), nil, "rootbtn: refless def → nil")
    local ref_def = "<!-- ref:79:11:3 -->bones · root: \226\128\142\216\185-\216\184-\217\133</span>"
    captured_spec.callback({
        results = { { definition = ref_def } },
        dict_index = 1,
        onClose = function() end,
    })
    eq(opened_root, "عظم", "rootbtn: ref-carrying entry opens its root")
    eq(opened_wid, 79011003, "rootbtn: word_id threaded to the landing")

    -- applyTotals (pure): measured totals decorate + re-rank the row lists
    local at_rows = {
        { arabic = "b", top_freq = 90 },
        { arabic = "a", top_freq = 10 },
    }
    QR.applyTotals(at_rows, { a = { words = 500 }, b = { words = 20 } }, true)
    eq(at_rows[1].arabic, "a", "totals: measured count outranks lane freq")
    eq(QR.rootItemMandatory(at_rows[1]), "×500", "totals: honest ×count shown")
    eq(QR.rootItemMandatory({ top_freq = 7 }), "×7", "totals: lane fallback intact")
    QR.applyTotals(at_rows, nil, true)
    eq(at_rows[1].arabic, "a", "totals: nil map is a no-op")
end

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

    -- D-R2-1: frequency-first landing + root entity screen
    local top = QR.topRoots(conn)
    eq(#top, 1252, "roots-top: every Quran-occurring covered root listed")
    eq(top[1].arabic, "اله", "roots-top: dominant-word ranking leads with اله")
    eq(top[1].top_freq, 2699, "roots-top: honest per-lemma count (never summed)")
    eq(top[1].gloss and top[1].gloss ~= "" and true, true,
        "roots-top: rows carry the dominant gloss")
    local sr = QR.searchRoots(conn, "ع-ذ-ب", 10)
    eq(sr[1] and sr[1].arabic, "عذب", "roots-search: dashed query matches")
    eq(sr[1].top_freq, 322, "roots-search: rows carry freq")
    eq(sr[1].gloss ~= nil, true, "roots-search: rows carry gloss")
    local ain2 = QR.rootsByLetter(conn, "ع")
    local adhb_row
    for _i, r in ipairs(ain2) do
        if r.arabic == "عذب" then adhb_row = r end
    end
    eq(adhb_row and adhb_row.top_freq, 322, "roots-letter: rows carry freq")
    eq(adhb_row.gloss ~= nil, true, "roots-letter: rows carry gloss")

    local nav_rt, nav_ri
    local rbrowser = {
        quran = { path = "data" },
        navigateForward = function(_, t3, i3) nav_rt, nav_ri = t3, i3 end,
        promptSearch = function() end,
    }
    QR.showRoots(rbrowser)
    eq(nav_rt, "Roots", "roots-land: landing title")
    eq(nav_ri[1].text, "Search roots", "roots-land: search path first")
    eq(nav_ri[2].text, "Browse by letter", "roots-land: alphabet stays secondary")
    eq(nav_ri[2].mandatory, "1631", "roots-land: letter path counts all covered roots")
    eq(nav_ri[2].separator, true, "roots-land: paths separated from the ranking")
    eq(#nav_ri, 1254, "roots-land: 2 paths + 1252 ranked roots")
    eq(nav_ri[3].text:find("ا%-ل%-ه — ") ~= nil, true,
        "roots-land: top row = root + dominant gloss")
    eq(nav_ri[3].mandatory, "×2699", "roots-land: top row count")

    nav_ri[3].callback()  -- into the اله entity screen
    eq(nav_rt, "ا-ل-ه", "roots-entity: title is the root")
    eq(nav_ri[1].text:sub(1, #"★"), "★", "roots-entity: starred summary leads")
    eq(nav_ri[#nav_ri].text, "Lane article", "roots-entity: article row closes the screen")
    eq(nav_ri[#nav_ri].mandatory, "11", "roots-entity: article row carries entry count")
    eq(nav_ri[#nav_ri - 1].separator, true,
        "roots-entity: summary separated from the study rows")

    nav_ri[#nav_ri].callback()  -- into the full Lane article
    eq(nav_rt, "Lane: ا-ل-ه", "roots-article: title names the screen (back label)")
    eq(#nav_ri, 11, "roots-article: every usable headword, Lane's order")

    QR.showLetters(rbrowser)
    eq(nav_rt, "By letter", "roots-letters: distinct title (back label)")
    eq(#nav_ri > 20, true, "roots-letters: alphabet listed")
    QR.showSearch(rbrowser, "عذب")
    eq(nav_rt, "Roots: عذب", "roots-search-screen: title carries the query")
    eq(nav_ri[1].text:find("ع%-ذ%-ب — ") ~= nil, true,
        "roots-search-screen: shared row shape")

    -- single-entry root skips the entity screen, opens the entry itself
    local before_nav = nav_rt
    QR.showRoot(rbrowser, "بعثر")
    eq(nav_rt, before_nav, "roots-single: no list screen pushed")
    eq(_shown and _shown.title, "بَعْثَرَ",
        "roots-single: the article's one entry opens directly")
    _shown.buttons_table[1][1].callback()  -- ← releases the viewer handle
    eq(QR._entry_viewer, nil, "roots-single: viewer handle released")

    -- D-R2-1 B2: the morphology package — real-DB round trips over the
    -- PAIRED extracts (word_headword ids target this lane build)
    local morph_db = "data/morphology-v1.sqlite"
    local have_morph = io.open(morph_db)
    if have_morph then have_morph:close() end
    if have_morph then
        fake_fs = { ["data"] = "directory",
            ["data/lane-v1.sqlite"] = "file",
            ["data/morphology-v1.sqlite"] = "file" }
        eq(QR.findMorphDb({ path = "data" }), morph_db,
            "morph: findMorphDb via plugin-dir fallback")
        local mconn, merr = QR.openMorphPath(morph_db)
        eq(mconn ~= nil, true, "morph: opens with schema check (" .. tostring(merr) .. ")")
        local mq = { path = "data" }
        eq(QR.pairOk(mq), true, "morph: paired lane build accepted (meta.created)")
        local totals = QR.totalsMap(mq)
        eq(totals ~= nil and totals["نقر"].words, 4, "morph: honest نقر total")
        eq(totals["نقر"].forms, 3, "morph: نقر form count")
        eq(totals["اله"].words, 2851, "morph: honest اله total (measured, never summed)")

        -- the tapped word's own sense: عِظَٰمٗا 79:11:3 → عَظْمٌ "bone",
        -- NOT the root's dominant "great" (the original repro; mirrors
        -- the explorer-side validator canary)
        local wh = QR.wordHeadword(mq, 79011003, "عظم")
        eq(wh and wh.headword, "عَظْمٌ", "morph: 79:11:3 lands on bone")
        eq(wh and wh.seq, 7, "morph: article position preserved")
        local whe = QR.entry(conn, wh.lexicon_entry_id)
        eq(whe and whe.headword, "عَظْمٌ",
            "morph: word_headword id resolves in the PAIRED lane build")

        -- B2 grouping: the نقر reference mockup — count desc, ties by
        -- first appearance, mushaf order inside each form
        local order, total = QR.occurrencesByForm(mq, "نقر")
        eq(total, 4, "morph-occ: نقر total")
        eq(#order, 3, "morph-occ: 3 derived forms")
        eq(order[1].key, "نَقِير", "morph-occ: ×2 form ranks first")
        eq(order[1].count, 2, "morph-occ: form count")
        eq(order[2].key, "نُقِرَ", "morph-occ: ×1 ties by first appearance")
        eq(order[3].key, "ناقُور", "morph-occ: trumpet last")
        eq(string.format("%d:%d:%d", order[1].occ[1].surah,
            order[1].occ[1].ayah, order[1].occ[1].word), "4:53:10",
            "morph-occ: mushaf order inside the form")
        eq(order[3].occ[1].gloss, "the trumpet,", "morph-occ: per-occurrence gloss")

        -- entity screen: sense-targeted lead + occurrences row
        local mt, mi, mo, goto_s, goto_a
        local mb = {
            quran = mq,
            navigateForward = function(_, t4, i4, _f4, o4) mt, mi, mo = t4, i4, o4 end,
            promptSearch = function() end,
            showAyahPage = function(_, s4, a4) goto_s, goto_a = s4, a4 end,
        }
        QR.showRoot(mb, "عظم", { word_id = 79011003 })
        eq(mi[1].bold, true, "morph-entity: lead row bolded")
        eq(mi[1].text:find("عَظْمٌ", 1, true) ~= nil, true,
            "morph-entity: lead row = the tapped word's sense")
        eq(mi[#mi].text, "Occurrences", "morph-entity: occurrences row present")
        eq(mi[#mi].mandatory, "×128 · 6 forms", "morph-entity: measured totals shown")
        mi[#mi].callback()
        eq(mt, "ع-ظ-م — ×128", "morph-occ-screen: title carries the honest total")
        eq(mo and mo.multiline, true, "morph-occ-screen: two-line rows")
        eq(mi[1].bold, true, "morph-occ-screen: form header bolded")
        eq(mi[1].mandatory:sub(1, 2), "×", "morph-occ-screen: header carries ×count")
        local row_7911
        for _i2, it2 in ipairs(mi) do
            if it2.mandatory == "79:11:3" then row_7911 = it2 end
        end
        eq(row_7911 ~= nil, true, "morph-occ-screen: S:A:W on the right")
        row_7911.callback()
        eq(goto_s .. ":" .. goto_a, "79:11", "morph-occ-screen: tap opens the ayah page")

        -- honest ranking on the landing (measured totals replace max-freq)
        QR.showRoots(mb)
        eq(mi[3].mandatory, "×2851", "morph-land: top row shows the measured total")

        -- single-entry root WITH occurrence data now gets the entity
        -- screen (the occurrences row is worth one)
        QR.showRoot(mb, "بعثر")
        eq(mt, "ب-ع-ث-ر", "morph-single: entity screen pushed now")
        eq(mi[#mi].text, "Occurrences", "morph-single: occurrences reachable")
        eq(mi[#mi].mandatory, "×2 · 1 forms", "morph-single: totals")

        -- pairing gate: a mismatched build loses ONLY the sense lead
        QR._pair_ok = false
        QR.showRoot(mb, "عظم", { word_id = 79011003 })
        eq(mi[1].text:find("This word:", 1, true), nil,
            "morph-pair: mismatched builds → no sense lead")
        eq(mi[#mi].text, "Occurrences",
            "morph-pair: occurrences stay (no lane ids involved)")
        QR._pair_ok = true
    else
        print("skip morphology tests (extract not in data/)")
    end
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
    -- similarFor is now bidirectional (owner repro 2026-07-17): 1:1's
    -- list gains reverse-side pairs; 27:30 must still be present with
    -- its score, ordering by score across BOTH directions
    local sim = QQ.similarFor(qconn, 1, 1)
    local sim_hit, sim_sorted = nil, true
    for i, p in ipairs(sim) do
        if p.surah == 27 and p.ayah == 30 then sim_hit = p end
        if i > 1 and sim[i - 1].score < p.score then sim_sorted = false end
    end
    eq(sim_hit ~= nil, true, "qul-db: 27:30 among 1:1's similar pairs")
    eq(sim_hit and sim_hit.score, 80, "qul-db: similarity score")
    eq(sim_sorted, true, "qul-db: similar list ordered by score (both directions)")
    local tps = QQ.topicsFor(qconn, 1, 1)
    local has_allah = false
    for _i, t in ipairs(tps) do
        if t.name == "Allah" then has_allah = true end
    end
    eq(has_allah, true, "qul-db: 1:1 topics include Allah")
    eq(#QQ.topicRoots(qconn), 3, "qul-db: three thematic roots")
    local ph = QQ.phrasesFor(qconn, 2, 23)
    eq(#ph, 2, "qul-db: 2:23 in two phrase groups")
    eq(ph[1].src_surah ~= nil and ph[1].src_from ~= nil, true,
        "r3-f22: phrase groups carry source word positions")
    eq(#QQ.phraseOccurrences(qconn, ph[1].group_id) > 60, true,
        "qul-db: group occurrences listed")
    local counts = QQ.countsFor(qconn, 2, 23)
    eq(counts.similar, 1, "qul-db: countsFor similar")
    eq(counts.phrases, 2, "qul-db: countsFor phrases")

    -- R3-F22: the phrase itself from the Hafs text (word-slice by the
    -- group's source positions; verified against the real db offsets)
    local pt_q = {
        _textModule = function()
            return {
                ensureDb = function() return true end,
                ayah = function(_c, _r, s2, a2)
                    if s2 == 2 and a2 == 29 then
                        return { text = "w1 w2 w3 w4 alpha beta gamma w8" }
                    end
                end,
            }
        end,
    }
    eq(QQ.phraseText(pt_q, { src_surah = 2, src_ayah = 29,
        src_from = 5, src_to = 7 }), "alpha beta gamma",
        "r3-f22: phrase = word slice src_from..src_to")
    eq(QQ.phraseText(pt_q, { src_surah = 2, src_ayah = 29,
        src_from = 7, src_to = 99 }), nil,
        "r3-f22: out-of-range positions -> nil (fallback row)")
    eq(QQ.phraseText({}, { src_surah = 1, src_ayah = 1,
        src_from = 1, src_to = 1 }), nil,
        "r3-f22: no text package -> nil (opaque row survives)")

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
    eq(#pos2, 10, "qul-uap: 6 base items + all 4 conn rows (R3-F19: zero-count rows dimmed, not hidden)")
    local rows_by_text = {}
    for _i, it in ipairs(pos2) do rows_by_text[it.text] = it end
    eq(rows_by_text["Themes"] ~= nil, true, "qul-uap: themes item present")
    eq(rows_by_text["Topics"] ~= nil, true, "qul-uap: topics item present")
    eq(rows_by_text["Themes"].dim, nil, "qul-uap: live conn row not dimmed")
    eq(rows_by_text["Themes"].mandatory ~= nil, true,
        "qul-uap: conn rows carry counts (F20)")
    eq(rows_by_text["Similar ayahs"] ~= nil, true,
        "qul-uap: zero-count similar row present")
    eq(rows_by_text["Similar ayahs"].dim, true,
        "qul-uap: zero-count row dimmed (F19)")
    eq(rows_by_text["Repeated phrases (mutashabihat)"].dim, true,
        "qul-uap: zero-count phrases row dimmed (F19)")
    pos2[1].callback()  -- Translations → in-browser Reader
    eq(uap_read, "77:33", "qul-uap: Read routes to the Reader in-browser")

    -- surah HUB with the real db: connection rows counted and live
    QB.show(bq, QA)
    _shown.item_table[3].callback()  -- Surahs
    _shown.item_table[2].callback()  -- surah 2 screen
    local hub2 = {}
    for _i, it in ipairs(_shown.item_table) do hub2[it.text] = it end
    eq(hub2["Themes"].dim, nil, "hub: themes live with the qul package")
    eq(tonumber(hub2["Themes"].mandatory) > 0, true,
        "hub: surah-2 theme count")
    eq(tonumber(hub2["Topics"].mandatory) > 0, true,
        "hub: surah-2 topic count")
    eq(tonumber(hub2["Repeated phrases (mutashabihat)"].mandatory) > 0, true,
        "hub: surah-2 phrase-group count")
    hub2["Themes"].callback()
    eq(_shown.item_table[1].text:find("Read as one page", 1, true) ~= nil,
        true, "hub: themes row lands the per-surah theme list (flow first)")

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
    -- F28: both sides fold through quran_norm — the Quranic written
    -- form (wasla + shadda + fatha) must hit the stored bare الله,
    -- and English matching stays case-insensitive
    eq(#QQ.searchTopics(qconn, "ٱللَّه", 50) > 0, true,
        "qul-s: topic search folds Arabic orthography (F28)")
    eq(#QQ.searchTopics(qconn, "allah", 50) > 0, true,
        "qul-s: folded topic search keeps ASCII case-insensitivity")
    eq(#QQ.searchTopics(qconn, "zzz no such topic", 5), 0,
        "qul-s: folded search still misses honestly")

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
        if it.text:find("^In this passage: ") then n_conn = n_conn + 1 end
        if it.text:find("^Surah2 2:%d+$") then n_range_ayahs = n_range_ayahs + 1 end
    end
    eq(n_conn, 11, "qul-theme: 'In this passage:' topic rows (D-R3-6 labels)")
    eq(n_range_ayahs, 2, "qul-theme: one row per ayah in the range")
    -- D-R3-6: a topic screen's sideways links read "Related:" — the
    -- same ≈ glyph no longer means two different things
    QQ.showTopic(thbrowser, 63)  -- mosque: related ids 45,167,52
    local n_rel = 0
    for _i, it in ipairs(nav_i) do
        if it.text:find("^Related: ") then n_rel = n_rel + 1 end
    end
    eq(n_rel, 3, "qul-conn: related rows labeled 'Related:' (D-R3-6)")
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
    local nav_title2, nav_items2, nav_opts2, flow_spec
    local fbrowser = {
        quran = {
            _readerModule = function()
                return { show = function(spec) flow_spec = spec end }
            end,
        },
        navigateForward = function(_, t2, i2, _f2, o2)
            nav_title2, nav_items2, nav_opts2 = t2, i2, o2
        end,
    }
    QQ.showThemeItems(fbrowser,
        { { theme = "Warning", surah = 2, ayah_from = 6, ayah_to = 7 } },
        "Themes 2:7", { flow = true })
    eq(nav_title2, "Themes 2:7", "flow: list still opens")
    eq(nav_opts2 and nav_opts2.multiline, true,
        "flow: theme lists request two-line rows (D-R3-6)")
    eq(#nav_items2, 2, "flow: one flow row + one theme row")
    eq(nav_items2[1].text:find("Read as one page", 1, true) ~= nil, true,
        "flow: flow row prepended")
    nav_items2[1].callback()
    eq(flow_spec.title, "Themes 2:7", "flow: Reader title carries the scope")
    eq(flow_spec.back_label, "←",
        "flow: browser-launched stack bottom shows the bare arrow (D-R3-8)")
    eq(flow_spec.text:find("2:6\226\128\1477 \194\183 Warning", 1, true) ~= nil, true,
        "flow: heading in the Reader body (outline mode: no text module)")

    -- D-R3-6 collapse: Themes root = ONE screen (per-surah bolded flow
    -- row + that surah's themes; the intermediate surah list is gone)
    local cb_t, cb_i, cb_o
    local cbrowser = {
        quran = { surahName = function(_, s2) return "Surah" .. s2 end },
        navigateForward = function(_, t2, i2, _f2, o2)
            cb_t, cb_i, cb_o = t2, i2, o2
        end,
    }
    QQ.showThemesBrowse(cbrowser)
    eq(cb_t, "Themes", "themes-collapse: lands the single Themes screen")
    eq(cb_o and cb_o.multiline, true,
        "themes-collapse: two-line untruncated theme rows (D-R3-6)")
    eq(cb_i[1].bold, true, "themes-collapse: surah flow row bolded")
    eq(cb_i[1].text:find("^1%. Surah1 — Read as one page") ~= nil, true,
        "themes-collapse: surah leads with its read-as-one-page flow row")
    local n_flow, n_theme = 0, 0
    for _i, it in ipairs(cb_i) do
        if it.bold then n_flow = n_flow + 1 else n_theme = n_theme + 1 end
    end
    eq(n_theme, 1049, "themes-collapse: all 1,049 themes on the one screen")
    eq(n_flow > 0 and n_flow <= 114, true,
        "themes-collapse: one flow row per surah with themes")
    eq(cb_i[2].bold, nil, "themes-collapse: theme rows unbolded")
    eq(cb_i[2].mandatory:find("^1:") ~= nil, true,
        "themes-collapse: theme row carries its S:range")
else
    print("skip qul-db tests (build output or sqlite binding unavailable)")
end

-- quran_connections (DA-7): pure helpers, then a real-DB round trip
-- against the staged extract (data/connections-v1.sqlite).
-- (do-block scoped: the main chunk is at the LuaJIT 200-local limit)
do
local QC = dofile("tools/quran.koplugin/quran_connections.lua")
eq(select(1, QC.keyToSA(18083)), 18, "cx: keyToSA surah")
eq(select(2, QC.keyToSA(18083)), 83, "cx: keyToSA ayah")
eq(QC.storyLabel("kahf"), "Stories of Al-Kahf", "cx: known story label")
eq(QC.storyLabel("some-new-cycle"), "Some New Cycle",
    "cx: unknown story key degrades to title case")
eq(QC.spanLabel(18083, 18102), "18:83\226\128\147102", "cx: span label")
eq(QC.spanLabel(2246, 2246), "2:246", "cx: single-ayah span collapses")
local du = QC.diffPairs(
    { { surah = 3, ayah = 2 }, { surah = 13, ayah = 9 } },
    { { surah = 3, ayah = 2 } })
eq(#du, 1, "cx: diffPairs drops pairs already in the wording list")
eq(du[1].surah .. ":" .. du[1].ayah, "13:9", "cx: diffPairs keeps the rest")
eq(QC.semanticFloor({ settings = { readSetting = function() return 80 end } }),
    2, "cx: strict wording floor maps to strong-only semantic")
eq(QC.semanticFloor({ settings = { readSetting = function() return 0 end } }),
    1, "cx: 'all' wording floor shows every shipped pair")
eq(QC.semanticFloor(nil), 2, "cx: no settings defaults to strict")
local refs = QC.parseRefs('["18:83", "2:30-33", "junk"]')
eq(#refs, 2, "cx: parseRefs takes s:a and s:a-b, skips junk")
eq(refs[1][1] .. ":" .. refs[1][2] .. "-" .. refs[1][3], "18:83-83",
    "cx: single ref degenerate span")
eq(refs[2][3], 33, "cx: range ref end")
local sorted = QC.sortUnits({
    { id = 3, seq = 2, parent_id = 1, title = "ep2" },
    { id = 1, seq = 1, title = "peri" },
    { id = 2, seq = 1, parent_id = 1, title = "ep1" },
    { id = 4, seq = 2, title = "peri2" },
})
eq(sorted[1].id .. sorted[2].id .. sorted[3].id .. sorted[4].id, "1234",
    "cx: units sort top-level by seq with children nested after parents")
eq(sorted[2].depth, 1, "cx: children carry depth for indenting")
local ftext = QC.renderFigureText({ name_en = "Mother of Moses",
    name_ar = "أم موسى", figure_type = "person", named_in_quran = 0,
    quranic_name = "أُمِّ مُوسى", tradition_name = "Yūkābid",
    summary = "S." })
eq(ftext:find("Not named in the Quran", 1, true) ~= nil, true,
    "cx: unnamed figure states it plainly")
eq(ftext:find("Yūkābid", 1, true) ~= nil, true,
    "cx: tradition name rendered")
eq(ftext:find("research candidate", 1, true) ~= nil, true,
    "cx: A2 data-status label carried (label, don't filter)")

local cx_db = "data/connections-v1.sqlite"
local have_cx = io.open(cx_db)
if have_cx then have_cx:close() end
if have_cx and sq3_ok then
    fake_fs = { ["data"] = "directory",
        ["data/connections-v1.sqlite"] = "file" }
    eq(QC.findDb({ path = "data" }), cx_db, "cx-db: findDb via plugin-dir fallback")
    local cconn, cerr = QC.openPath(cx_db)
    eq(cconn ~= nil, true, "cx-db: opens with schema check (" .. tostring(cerr) .. ")")
    eq(QC.figureCount(cconn), 70, "cx-db: 70 figures")
    eq(QC.storyCount(cconn), 11, "cx-db: 11 story cycles")
    local figs = QC.allFigures(cconn)
    eq(#figs, 70, "cx-db: all figures listed")
    eq(figs[1].name_en, "Moses", "cx-db: frequency-first landing (Moses tops)")
    eq(figs[1].n_ayahs, 131, "cx-db: Moses named in 131 ayahs")
    local musa = QC.figure(cconn, figs[1].id)
    eq(musa.slug, "musa", "cx-db: figure fetch by id")
    eq(musa.figure_type, "prophet", "cx-db: figure type")
    eq(musa.status, "candidate", "cx-db: candidate status ships as a label")
    local mayahs = QC.figureAyahs(cconn, musa.id)
    eq(#mayahs, 131, "cx-db: figureAyahs distinct count")
    eq(mayahs[1].surah .. ":" .. mayahs[1].ayah, "2:51",
        "cx-db: first Musa mention 2:51 (mushaf order)")
    eq(#QC.figureUnits(cconn, musa.id), 3, "cx-db: Musa in 3 story units")
    local rel = QC.relatedFigures(cconn, musa.id)
    eq(#rel > 0, true, "cx-db: related figures via shared units")
    local sts = QC.stories(cconn)
    eq(#sts, 11, "cx-db: stories list")
    eq(sts[1].story, "adam-iblis", "cx-db: cycles in mushaf order (2:30 first)")
    local kahf = QC.unitsForStory(cconn, "kahf")
    eq(#kahf, 9, "cx-db: kahf cycle = 9 units")
    eq(kahf[1].depth, 0, "cx-db: pericopes lead")
    local dq
    for _i, u in ipairs(kahf) do
        if u.slug == "kahf-dhu-al-qarnayn" then dq = u end
    end
    eq(dq ~= nil, true, "cx-db: DQ pericope present")
    eq(QC.spanLabel(dq.from_ayah_key, dq.to_ayah_key), "18:83\226\128\147102",
        "cx-db: DQ span 18:83-102 (the Z7 canary)")
    eq(#QC.unitChildren(cconn, dq.id), 5, "cx-db: DQ has 5 episodes")
    local containing = QC.unitsContaining(cconn, 18, 86)
    eq(#containing, 2, "cx-db: 18:86 sits in 2 nested units")
    eq(containing[1].slug, "dq-west", "cx-db: narrowest unit first")
    local at = QC.figuresAt(cconn, 18, 86)
    eq(#at, 1, "cx-db: one figure at 18:86")
    eq(at[1].name_en:find("Qarnayn") ~= nil, true, "cx-db: Dhu al-Qarnayn")
    eq(at[1].by_ref, true,
        "cx-db: DQ reachable via curated refs (no PN occurrence exists)")
    local at12 = QC.figuresAt(cconn, 12, 26)
    local aziz_hit = false
    for _i, f2 in ipairs(at12) do
        if f2.name_en:find("Az", 1, true) then aziz_hit = aziz_hit or f2.by_ref end
    end
    eq(aziz_hit, true, "cx-db: ref SPAN covers 12:26 (al-Aziz 12:25-29)")
    local s12 = QC.figuresInSurah(cconn, 12)
    eq(s12[1].name_en, "Joseph", "cx-db: surah-12 characters led by Yusuf")
    eq(#QC.unitsInSurah(cconn, 18), 10, "cx-db: surah-18 story passages")
    -- semantic layer: score >= 1 only, both directions, strength floor
    local sem_strong = QC.semanticFor(cconn, 2, 255, 2)
    local kursi_3_2 = false
    for _i, p in ipairs(sem_strong) do
        if p.surah == 3 and p.ayah == 2 then kursi_3_2 = true end
        eq(p.score >= 2, true, "cx-db: strict floor keeps strong only")
    end
    eq(kursi_3_2, true, "cx-db: ayat-al-kursi ↔ 3:2 (the U2 canary)")
    local sem_all = QC.semanticFor(cconn, 2, 255, 1)
    eq(#sem_all, 23, "cx-db: floor 1 shows all shipped pairs (union, deduped)")
    local rev = QC.semanticFor(cconn, 3, 2, 1)
    local rev_hit = false
    for _i, p in ipairs(rev) do
        if p.surah == 2 and p.ayah == 255 then rev_hit = true end
    end
    eq(rev_hit, true, "cx-db: reverse direction reachable (3:2 sees 2:255)")
    -- phrase spans (D-R3-14 feed; semantics = ranges in the TO ayah)
    local ps = QC.phraseSpans(cconn, 1, 1, 27, 30)
    eq(ps ~= nil, true, "cx-db: phrase spans row present")
    eq(ps.match_words[1][1] .. "-" .. ps.match_words[1][2], "5-8",
        "cx-db: basmala words 5-8 of 27:30 (verified semantics)")
    eq(ps.coverage, 50, "cx-db: coverage = % of the TO ayah matched")
    eq(ps.matched_words_count, 4, "cx-db: matched word count")

    -- screens: Figures / Stories / figure entity / unit
    local nav_t, nav_i, nav_o
    local cxb = {
        quran = { path = "data",
            surahName = function(_, s2) return "Surah" .. s2 end },
        navigateForward = function(_, t2, i2, _f2, o2)
            nav_t, nav_i, nav_o = t2, i2, o2
        end,
        qulModule = function() return QQ end,
    }
    QC.showFigures(cxb)
    eq(nav_t, "Figures", "cx-screens: figures landing")
    eq(#nav_i, 70, "cx-screens: all 70 figures listed")
    eq(nav_i[1].text:find("Moses", 1, true) ~= nil, true,
        "cx-screens: Moses first (frequency-first)")
    eq(nav_i[1].mandatory:find("131", 1, true) ~= nil, true,
        "cx-screens: ayah count in the count column")
    QC.showStories(cxb)
    eq(nav_t, "Narratives", "cx-screens: narratives landing")
    eq(#nav_i, 11, "cx-screens: 11 cycles")
    QC.showStory(cxb, "kahf")
    eq(nav_t, "Stories of Al-Kahf", "cx-screens: story screen titled")
    eq(#nav_i, 9, "cx-screens: kahf units listed")
    local dq_row
    for _i, it in ipairs(nav_i) do
        if it.text:find("    ", 1, true) then dq_row = it break end
    end
    eq(dq_row ~= nil, true, "cx-screens: episodes indented under pericopes")
    QC.showFigure(cxb, musa.id)
    eq(nav_t, "Moses", "cx-screens: figure entity screen")
    eq(nav_i[1].text:find("About", 1, true) ~= nil, true,
        "cx-screens: About row first")
    eq(nav_o and nav_o.multiline, true, "cx-screens: entity rows two-line")
    QC.showUnit(cxb, dq.id)
    eq(nav_t == dq.title, true, "cx-screens: unit screen titled")
    eq(nav_i[1].text, "Read this passage",
        "cx-screens: read FIRST (D-R3-6)")
    eq(nav_i[2].text, "Go to this passage in the book",
        "cx-screens: position row second")
    local n_ayah_rows = 0
    for _i, it in ipairs(nav_i) do
        if it.text:find("^Surah18 18:") then n_ayah_rows = n_ayah_rows + 1 end
    end
    eq(n_ayah_rows, 20, "cx-screens: DQ span ayah rows 18:83-102")
    QC.showStoryContext(cxb, 18, 86)
    eq(nav_t:find("Narrative context", 1, true) ~= nil, true,
        "cx-screens: story-context list screen")
    eq(#nav_i, 2, "cx-screens: both nested units listed (D-R3-12 no sibling loss)")

    -- Similar surface union (qul wording + semantic sections): 2:255
    -- with the REAL qul db when staged, else semantic-only
    local sim_items, sim_title
    local simb = {
        quran = { path = "data", settings = {
                readSetting = function(_, _k, d) return d end },
            surahName = function(_, s2) return "Surah" .. s2 end },
        navigateForward = function(_, t2, i2, _f2, _o2)
            sim_title, sim_items = t2, i2
        end,
        connectionsModule = function() return QC end,
    }
    QQ._conn = nil
    QQ._db_path = nil
    QQ.showSimilar(simb, 2, 255)
    eq(sim_title:find("Similar ayahs", 1, true) ~= nil, true,
        "cx-similar: one Similar surface")
    local n_meaning = 0
    for _i, it in ipairs(sim_items) do
        if it.mandatory and tostring(it.mandatory):find("meaning", 1, true) then
            n_meaning = n_meaning + 1
        end
    end
    eq(n_meaning >= 10, true,
        "cx-similar: semantic rows labeled 'meaning' (strict floor = 10 strong)")
else
    print("skip cx-db tests (staged extract or sqlite binding unavailable)")
end
end

-- quran_masaq (DA-7 batch 2, NC isolated pack): pure helpers + real-DB
-- round trip against the staged extract (do-block: 200-local limit).
do
local QMQ = dofile("tools/quran.koplugin/quran_masaq.lua")
local aw = QMQ.assembleWords({
    { word_id = 1001001, morph_type = "Prefix", form = "ب",
      syntactic_role = "PREP", gloss = "g1" },
    { word_id = 1001001, morph_type = "Stem", form = "اسم",
      syntactic_role = "PREP_OBJ" },
    { word_id = 1001002, morph_type = "Other_i3rab",
      syntactic_role = "SUBJ" },
})
eq(#aw, 2, "masaq: assembleWords groups by word")
eq(aw[1].surface, "باسم", "masaq: surface concatenates segment forms")
eq(aw[1].role, "PREP_OBJ", "masaq: stem role wins over prefix role")
eq(aw[1].gloss, "g1", "masaq: gloss carried")
eq(aw[2].has_implied, true, "masaq: implied rows flagged, not concatenated")
eq(aw[2].surface, "", "masaq: implied-only word has no surface")
local rw = QMQ.renderWord({
    { morph_type = "Stem", form = "اسم", morph_tag = "NOUN",
      syntactic_role = "PREP_OBJ", case_mood = "GENITIVE", gloss = "name" },
    { morph_type = "Other_i3rab", syntactic_role = "SUBJ" },
}, { role = { PREP_OBJ = { ar = "مجرور", en = "Prep object" },
              SUBJ = { ar = "مبتدأ", en = "Subject" } },
    case_mood = { GENITIVE = { ar = "مجرور", en = "Genitive" } } }, "اسم")
eq(rw:find("implied", 1, true) ~= nil, true, "masaq: implied segment labeled")
eq(rw:find("مبتدأ", 1, true) ~= nil, true, "masaq: legend Arabic rendered")
eq(rw:find("CC BY-NC", 1, true) ~= nil, true,
    "masaq: NC attribution line carried on every word view")

local mq_db = "data/masaq-v1.sqlite"
local have_mq = io.open(mq_db)
if have_mq then have_mq:close() end
if have_mq and sq3_ok then
    fake_fs = { ["data"] = "directory", ["data/masaq-v1.sqlite"] = "file" }
    eq(QMQ.findDb({ path = "data" }), mq_db, "masaq-db: findDb via plugin dir")
    local mconn, merr = QMQ.openPath(mq_db)
    eq(mconn ~= nil, true, "masaq-db: opens with schema check (" .. tostring(merr) .. ")")
    local t111 = QMQ.tokensForWord(mconn, 1001001)
    eq(#t111, 2, "masaq-db: 1:1:1 has prefix + stem")
    eq(t111[1].form .. "/" .. t111[2].form, "ب/اسم", "masaq-db: canary forms")
    eq(t111[2].syntactic_role, "PREP_OBJ", "masaq-db: canary role")
    eq(t111[2].case_mood, "GENITIVE", "masaq-db: canary case")
    local span = QMQ.tokensForWord(mconn, 2144016)
    eq(#span, 3, "masaq-db: merged unit وحيثما reachable from its END word")
    eq(span[2].form, "حيث", "masaq-db: span segments in order")
    local a11 = QMQ.tokensForAyah(mconn, 1, 1)
    eq(#a11, 8, "masaq-db: 1:1 token rows")
    eq(#QMQ.assembleWords(a11), 4, "masaq-db: 1:1 = 4 words")
    eq(#QMQ.assembleWords(QMQ.tokensForAyah(mconn, 2, 255)), 50,
        "masaq-db: ayat al-kursi = 50 words")
    local lg = QMQ.legend(mconn)
    eq(lg.role and lg.role.SUBJ and lg.role.SUBJ.ar, "مبتدأ",
        "masaq-db: 73-role legend resolves (SUBJ)")
    eq(lg.case_marker ~= nil, true, "masaq-db: case-marker legend present")

    -- screen: word list for an ayah (rows = pos. surface — gloss)
    local mnav_t, mnav_i, mnav_o
    local mqb = {
        quran = { path = "data",
            surahName = function(_, s2) return "Surah" .. s2 end },
        navigateForward = function(_, t2, i2, _f2, o2)
            mnav_t, mnav_i, mnav_o = t2, i2, o2
        end,
    }
    QMQ.showAyah(mqb, 1, 1)
    eq(mnav_t:find("Word grammar", 1, true) ~= nil, true,
        "masaq-screens: ayah word list titled")
    eq(#mnav_i, 4, "masaq-screens: one row per word")
    eq(mnav_i[1].text:find("^1%. ") ~= nil, true,
        "masaq-screens: rows numbered by word position")
    eq(mnav_o and mnav_o.multiline, true, "masaq-screens: two-line rows")
    eq(type(mnav_i[1].mandatory), "string",
        "masaq-screens: role in the count column")
else
    print("skip masaq-db tests (staged extract or sqlite binding unavailable)")
end
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
-- F26: "match book" prefers the LIVE ReaderView (per-book sidecar
-- setting) over the global — a book inverted individually must invert
-- even when the global says standard, and vice versa
package.loaded["apps/reader/readerui"] =
    { instance = { view = { inverse_reading_order = false } } }
eq(QRD.pagingInverted(), false,
    "paging: auto follows the BOOK over the global (book standard wins)")
package.loaded["apps/reader/readerui"].instance.view.inverse_reading_order = true
G_reader_settings = nil
eq(QRD.pagingInverted(), true,
    "paging: auto follows the BOOK over the global (book inverted wins)")
package.loaded["apps/reader/readerui"] = nil
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

-- D-R2-7b: "follow content" mode — inversion input + text classifier
do
QRD.paging_mode = "content"
eq(QRD.pagingInverted(true), true, "paging: content mode, RTL content inverts")
eq(QRD.pagingInverted(false), false, "paging: content mode, LTR content standard")
eq(QRD.pagingInverted(), false,
    "paging: content mode, no content identity (browser) = standard")
QRD.paging_mode = "auto"
eq(QRD.pagingInverted(true), false, "paging: auto ignores the content argument")
eq(QRD.textDirectionRTL("بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ"), true,
    "content-dir: arabic text classifies RTL")
eq(QRD.textDirectionRTL("Lane: to stand, to rise; قام occurs in this form"),
    false, "content-dir: english-led text with arabic runs classifies LTR")
eq(QRD.textDirectionRTL(""), false, "content-dir: empty text reads LTR")
eq(QRD.textDirectionRTL(nil), false, "content-dir: nil text reads LTR")
eq(#QRD.PAGING_MODES, 4, "paging: four modes exposed for the menus")
eq(QRD.PAGING_MODES[4].value, "content", "paging: content mode listed last")
end

-- wireTouchPaging: swipes route through the scroll handlers (gains the
-- boundary flow) and honor the mode at EVENT time; taps swap halves
-- when inverted
do
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
end

-- follow-content wiring: classified at wire time, declaration wins,
-- honored at event time; setPagingMode persists via the main.lua hook
do
local cw_up, cw_down = 0, 0
local cw_viewer = {
    text = "قُلْ هُوَ اللَّهُ أَحَدٌ ۝ اللَّهُ الصَّمَدُ",
    textw = { dimen = {} },
    scroll_text_w = {
        width = 800,
        onScrollUp = function() cw_up = cw_up + 1; return true end,
        onScrollDown = function() cw_down = cw_down + 1; return true end,
        onTapScrollText = function() end,
    },
    onSwipe = function()
        error("stock swipe must not be reached for horizontal swipes")
    end,
}
QRD.wireTouchPaging(cw_viewer)
eq(cw_viewer._qr_rtl, true, "content-wire: undeclared arabic content classified RTL")
QRD.paging_mode = "content"
local cw_ges = { direction = "west",
                 pos = { x = 700, intersectWith = function() return true end } }
cw_viewer:onSwipe(nil, cw_ges)
eq(cw_up, 1, "content-wire: west swipe on RTL surface pages back (inverted)")
cw_viewer._qr_content_rtl = false
cw_viewer.text = "the viewer swaps to an english surface in place"
QRD.wireTouchPaging(cw_viewer)
eq(cw_viewer._qr_rtl, false, "content-wire: declared direction beats the classifier")
cw_viewer:onSwipe(nil, cw_ges)
eq(cw_down, 1, "content-wire: west swipe on declared-LTR surface pages forward")
QRD.paging_mode = "auto"

local cw_saved
QRD._save_paging = function(value) cw_saved = value end
QRD.setPagingMode("content")
eq(QRD.paging_mode, "content", "setPagingMode: module state updated")
eq(cw_saved, "content", "setPagingMode: persisted through the settings hook")
QRD._save_paging = nil
QRD.paging_mode = "auto"
end

-- title-bar quick menu (D-R2-7b): radio rows from PAGING_MODES; the
-- TextViewer hamburger wrap keeps the stock view options one row below
do
package.preload["ui/widget/buttondialog"] =
    package.preload["ui/widget/buttondialog"] or function()
        return { new = function(_, spec) return spec end }
    end
package.loaded["ui/widget/buttondialog"] = nil
local pm_dlg = QRD.showPagingMenu(nil)
eq(#pm_dlg.buttons, 4, "paging-menu: one row per mode")
eq(pm_dlg.buttons[1][1].text:find("◉", 1, true), 1,
    "paging-menu: current mode radio-marked")
eq(pm_dlg.buttons[2][1].text:find("◯", 1, true), 1,
    "paging-menu: other modes unmarked")
pm_dlg.buttons[4][1].callback()
eq(QRD.paging_mode, "content", "paging-menu: tapping a row sets the mode")
QRD.paging_mode = "auto"

local pm_orig = 0
local pm_viewer = {
    onShowMenu = function() pm_orig = pm_orig + 1 end,
    text_font_size = 20,
    reinit = function() end,
    justified = false,
    titlebar = { left_button = { image = { dimen = {} } } },
}
QRD.wirePagingMenu(pm_viewer)
eq(pm_viewer._qr_paging_menu, true, "paging-menu: hamburger wrapped")
pm_viewer:onShowMenu()
local vm = _shown
eq(#vm.buttons, 4, "view-menu: stock rows + one paging row")
eq(vm.buttons[1][1].text_func():find("Font size", 1, true), 1,
    "view-menu: stock options first-class (font size leads)")
vm.buttons[3][1].callback()
eq(pm_viewer.justified, true, "view-menu: justify toggles like stock")
eq(vm.buttons[4][1].text_func():find("Paging direction", 1, true), 1,
    "view-menu: paging row appended last")
vm.buttons[4][1].callback()
local pd = _shown
eq(#pd.buttons, 4, "view-menu: paging row opens the radio dialog")
pd.buttons[4][1].callback()
eq(QRD.paging_mode, "content", "view-menu: radio row sets the mode")
QRD.paging_mode = "auto"
eq(pm_orig, 0, "view-menu: stock menu untouched on the happy path")
local fb_viewer = { onShowMenu = function() pm_orig = pm_orig + 1 end }
QRD.wirePagingMenu(fb_viewer)
fb_viewer:onShowMenu()
eq(pm_orig, 1,
    "view-menu: missing TextViewer internals fall back to the stock menu")
local pm_bare = {}
QRD.wirePagingMenu(pm_bare)
eq(pm_bare.onShowMenu, nil,
    "paging-menu: no hamburger, no wrap (old KOReader)")
end

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

-- show(): spec.content_rtl declares the surface for follow-content paging
do
QRD.show{ title = "TA", text = "an english translation body", content_rtl = true }
eq(_shown._qr_rtl, true,
    "reader-show: spec.content_rtl overrides the classifier (ayah surface)")
QRD.show{ title = "TB", text = "plain english tafsir text" }
eq(_shown._qr_rtl, false,
    "reader-show: in-place swap without declaration re-classifies")
_shown.buttons_table[1][1].callback()  -- ← close
end

-- ◀ ▶ follow the effective direction (owner 2026-07-16: arabic asbab,
-- "left button is still previous?"): on an inverted surface the LEFT
-- button moves forward — the popup nav-pair convention
do
QRD.paging_mode = "content"
local ib_seq = {}
QRD.show{ title = "TR", text = "x", content_rtl = true,
    prev = function() ib_seq[#ib_seq + 1] = "prev" end,
    next = function() ib_seq[#ib_seq + 1] = "next" end }
local ib_row = _shown.buttons_table[1]
ib_row[2].callback()  -- ◀
ib_row[3].callback()  -- ▶
eq(table.concat(ib_seq, ","), "next,prev",
    "reader-buttons: inverted surface swaps the pair (◀ = forward)")
ib_seq = {}
QRD.show{ title = "TS", text = "english entry", content_rtl = false,
    prev = function() ib_seq[#ib_seq + 1] = "prev" end,
    next = function() ib_seq[#ib_seq + 1] = "next" end }
ib_row = _shown.buttons_table[1]
ib_row[2].callback()
ib_row[3].callback()
eq(table.concat(ib_seq, ","), "prev,next",
    "reader-buttons: LTR surface keeps the standard mapping")
QRD.show{ title = "TE", text = "y", content_rtl = true,
    next = function() end }
ib_row = _shown.buttons_table[1]
eq(ib_row[2].enabled, true,
    "reader-buttons: forward-only inverted surface keeps ◀ live")
eq(ib_row[3].enabled, false,
    "reader-buttons: ▶ disabled when the swapped direction is dead")
QRD.paging_mode = "auto"
_shown.buttons_table[1][1].callback()  -- ← close
end

-- D-R2-8: Reader hop stack — ← walks back through surface-changing
-- hops IN PLACE; same-kind stepping replaces; ✕/close clears
do
QRD.show{ title = "An-Nisa 4:34", text = "t", kind = "ayah" }
local hv = _shown
QRD.show{ title = "Ibn Kathir · An-Nisa 4:34", text = "tf", kind = "dict" }
eq(_shown == hv, true, "hop: tafsir over ayah stays in place")
eq(#QRD._stack, 1, "hop: surface change pushed the ayah view")
eq(_shown.buttons_table[1][1].text:find("An-Nisa 4:34", 1, true) ~= nil,
    true, "hop: back button names the hop target")
QRD.show{ title = "Ibn Kathir · An-Nisa 4:35", text = "tf2", kind = "dict" }
eq(#QRD._stack, 1, "hop: same-kind step replaces (no push)")
_shown.buttons_table[1][1].callback()  -- ← pops
eq(_shown == hv and QRD._viewer ~= nil, true,
    "hop: back pops in place (viewer still live)")
eq(_shown.title, "An-Nisa 4:34", "hop: ayah surface restored")
eq(#QRD._stack, 0, "hop: stack consumed")
eq(_shown.buttons_table[1][1].text:find("Book", 1, true) ~= nil, true,
    "hop: empty stack restores the stack-bottom label (Book default)")
_shown.buttons_table[1][1].callback()  -- ← again
eq(QRD._viewer, nil, "hop: empty-stack back closes (stack bottom)")
QRD.show{ title = "A", text = "1", kind = "ayah" }
QRD.show{ title = "B", text = "2", kind = "dict" }
eq(#QRD._stack, 1, "hop: fresh viewer, hop pushed again")
_shown:onCloseWidget()  -- titlebar ✕ / tap-outside path
eq(#QRD._stack == 0 and QRD._spec == nil, true,
    "hop: closing the viewer outright clears the stack")
-- dict → dict is a HOP (owner 2026-07-17: translation dict → tafsir
-- must return by name); stepping within ONE dict still replaces
QRD.show{ title = "Saheeh · 4:34", text = "s", kind = "dict:Saheeh" }
QRD.show{ title = "Ibn Kathir · 4:34", text = "k", kind = "dict:Kathir" }
eq(#QRD._stack, 1, "hop: cross-dict move pushes")
eq(_shown.buttons_table[1][1].text:find("Saheeh", 1, true) ~= nil, true,
    "hop: back names the previous dict surface")
QRD.show{ title = "Ibn Kathir · 4:35", text = "k2", kind = "dict:Kathir" }
eq(#QRD._stack, 1, "hop: same-dict stepping still replaces")
_shown:onCloseWidget()
end

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
    _shown.buttons_table[1][1].callback()  -- ← close

    -- D-R2-8 owner-flow repro (2026-07-17 report: tafsir back said
    -- "← Book"): the REAL chain — showAyah → the actual Tafsir button →
    -- openTafsirReader → showTafsir — must name the translation view
    local fq
    fq = {
        path = "data",
        surahName = function(_, s) return "Surah" .. s end,
        _hafsCounts = function() return C114 end,
        _textModule = function() return QT end,
        canReaderTafsir = function() return true end,
        _ayahDictKeys = function(_, s, a) return { "K" .. s .. ":" .. a } end,
        _rawDefinition = function() return "tafsir body text" end,
        _htmlToText = function(_, s) return s end,
        openTafsirReader = function(self_q, s, a, o)
            return QRD.showTafsir(self_q, s, a,
                { dict = "TDict", explore = o and o.explore })
        end,
    }
    QRD.showAyah(fq, 2, 255)
    eq(_shown.title, "Surah2 2:255", "hop-flow: translation view open")
    _shown.buttons_table[1][4].callback()  -- the real Tafsir button
    eq(_shown.title:find("TDict", 1, true) ~= nil, true,
        "hop-flow: tafsir opened in place over the translation view")
    eq(_shown.buttons_table[1][1].text:find("Surah2 2:255", 1, true) ~= nil,
        true, "hop-flow: tafsir back button NAMES the translation view")
    _shown.buttons_table[1][1].callback()  -- ← back
    eq(_shown.title, "Surah2 2:255", "hop-flow: back returns to translation")
    eq(_shown.buttons_table[1][1].text:find("Book", 1, true) ~= nil, true,
        "hop-flow: translation view back = stack bottom (Book)")
    _shown.buttons_table[1][1].callback()  -- close
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

-- D-R3-2: a "popup" open target routes to the filtered popup and
-- reports handled — the Reader is never touched
local ot_popup
oq.canReaderTafsir = function() return true end
oq._openTargetFor = function(_, _k) return oq._target or "reader" end
oq._actionsModule = function()
    return { classifyDict = function(_n) return "grammar" end }
end
oq.openAyahPopup = function(_, s, a) ot_popup = s .. ":" .. a end
oq._target = "popup"
eq(oq:openTafsirReader(3, 4, { dict = "Z" }), true,
    "d-r3-2: popup target handled by openTafsirReader")
eq(ot_popup, "3:4", "d-r3-2: the dict popup opened at the ayah")
eq(oq._dict_filter_name, "Z", "d-r3-2: popup filtered to the tapped dict")
eq(#ot_calls, 3, "d-r3-2: Reader untouched on the popup route")
-- popup route works even pre-rawSdcv (it never needed the fetch)
oq.canReaderTafsir = function() return false end
eq(oq:openTafsirReader(3, 5, { dict = "Z" }), true,
    "d-r3-2: popup route independent of rawSdcv")
oq._target = nil

-- D-R3-2 policy helpers (extracted live): mode default, per-item
-- override precedence, popup-button knobs
local tchunk = "local Quran = {}\n"
    .. extract("--- D-R3-2: effective open target",
               "--- Open a tafsir for S:A")
    .. "\nreturn Quran\n"
local TG = assert(loadstring(tchunk))()
local tset = {}
local tgq = {
    settings = {
        readSetting = function(_, k) return tset[k] end,
        isTrue = function(_, k) return tset[k] == true end,
        isFalse = function(_, k) return tset[k] == false end,
    },
    _openTargetFor = TG._openTargetFor,
    _popupButtonOn = TG._popupButtonOn,
}
eq(tgq:_openTargetFor("tafsir"), "reader",
    "d-r3-2: browser mode default = full screen")
tset.quran_simple_mode = true
eq(tgq:_openTargetFor("tafsir"), "popup", "d-r3-2: Simple mode -> popup")
tset.open_target_tafsir = "reader"
eq(tgq:_openTargetFor("tafsir"), "reader",
    "d-r3-2: per-item override beats the mode")
tset.quran_simple_mode = nil
tset.open_target_grammar = "popup"
eq(tgq:_openTargetFor("grammar"), "popup",
    "d-r3-2: popup override active in browser mode")
eq(tgq:_popupButtonOn("explore"), true, "d-r3-2: popup buttons default on")
tset.popup_btn_explore = false
eq(tgq:_popupButtonOn("explore"), false, "d-r3-2: per-button toggle wins")
tset.quran_simple_mode = true
eq(tgq:_popupButtonOn("readfull"), true,
    "r3-f17: Simple mode never strips popup buttons (defaults, not capability)")

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
    -- similarFor is bidirectional now — pin the ROUTING of the 27:30
    -- item, not its list position (reverse pairs may outrank it)
    local sim_item
    for _i, it in ipairs(nav_items) do
        if it.text and it.text:find("27:30", 1, true) then sim_item = it end
    end
    eq(sim_item ~= nil, true, "uap-route: the 27:30 pair is listed")
    sim_item.callback()
    eq(uap_route, "27:30", "uap-route: similar item opens the unified ayah page")
    -- R3 batch 4: rows preview the paired ayah's translation
    dq._textModule = function()
        return {
            ensureDb = function() return true end,
            translations = function(_c, s2, a2)
                return { { text = "Preview text for " .. s2 .. ":" .. a2 } }
            end,
        }
    end
    QQ2.showSimilar(fb, 1, 1)
    local prev_item
    for _i, it in ipairs(nav_items) do
        if it.text and it.text:find("27:30", 1, true) then prev_item = it end
    end
    eq(prev_item ~= nil and prev_item.text:find(
        " — Preview text for 27:30", 1, true) ~= nil, true,
        "r3-b4: similar rows carry a translation preview")
    dq._textModule = nil
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

-- quran_marks (D-R2-5): layer queries against the real qul build,
-- page resolution + cache, grayscale painters
do
package.preload["ffi/blitbuffer"] = package.preload["ffi/blitbuffer"]
    or function() return { COLOR_DARK_GRAY = "dg" } end
package.loaded["ffi/blitbuffer"] = nil
local QM = dofile("tools/quran.koplugin/quran_marks.lua")
if have_qul and sq3_ok then
    local QQm = dofile("tools/quran.koplugin/quran_qul.lua")
    local mconn = QQm.openPath(qul_db)
    eq(mconn ~= nil, true, "marks: qul db opened")
    -- ground truth rows straight off the extract
    local function firstRow(sql)
        local stmt = mconn:prepare(sql)
        local r = stmt:step()
        stmt:close()
        return r
    end
    local pr = firstRow("SELECT surah, ayah FROM phrase_occ LIMIT 1")
    local ps_s, ps_a = tonumber(pr[1]), tonumber(pr[2])
    local mset = QM.layerAyahs(mconn, "mutashabihat", ps_s, ps_a, ps_a)
    eq(mset[ps_a], true, "marks: mutashabihat layer finds a phrase_occ row")
    local tr = firstRow("SELECT surah, ayah_from FROM theme LIMIT 1")
    local th_s, th_a = tonumber(tr[1]), tonumber(tr[2])
    eq(QM.layerAyahs(mconn, "themes", th_s, th_a, th_a)[th_a], true,
        "marks: themes layer finds a span start")
    eq(QM.layerAyahs(mconn, "similar", 27, 30, 30)[30], true,
        "marks: similar layer catches the m_-side of a pair (1:1↔27:30)")
    -- browser parity (owner repro: 79:19 marked but browser empty):
    -- similarFor now answers from EITHER side of a pair
    local rev = QQm.similarFor(mconn, 27, 30)
    local rev_hit = false
    for _i, p in ipairs(rev) do
        if p.surah == 1 and p.ayah == 1 then rev_hit = true end
    end
    eq(rev_hit, true,
        "marks: similarFor answers from the m_-side (browser parity)")
    -- similar-ayah strength floor (owner 2026-07-17: 79:19↔79:44 is a
    -- weak score-60 wording match — QUL matching-ayah, not semantics)
    eq(#QQm.similarFor(mconn, 79, 19), 1,
        "similar: weak pair listed with no floor")
    eq(#QQm.similarFor(mconn, 79, 19, 80), 0,
        "similar: strict floor drops the weak 79:19 pair")
    eq(QM.layerAyahs(mconn, "similar", 79, 19, 19, 80)[19], nil,
        "marks: strict floor unmarks 79:19")
    eq(QM.layerAyahs(mconn, "similar", 79, 19, 19)[19], true,
        "marks: no floor keeps it")
    eq(QQm.countsFor(mconn, 79, 19, 80).similar, 0,
        "counts: strict floor zeroes 79:19's similar count")
    eq(QQm.countsFor(mconn, 79, 19).similar, 1,
        "counts: no floor counts the weak pair")
    eq(QQm.similarMinScore({}), 80, "similar: floor defaults strict")
    eq(QQm.similarMinScore({ settings = {
        readSetting = function(_, _k, _d) return 0 end } }), 0,
        "similar: floor honors the setting")
    eq(next(QM.layerAyahs(mconn, "nope", 1, 1, 7)), nil,
        "marks: unknown layer yields nothing")

    -- marksForPage: fake reader over the real db — resolution + cache
    local ms_settings = { marks_mutashabihat = true }
    local ms_range = { ps_s, ps_a, ps_a }
    local msq
    msq = {
        settings = {
            isTrue = function(_, k) return ms_settings[k] == true end,
            readSetting = function(_, k, d)
                if ms_settings[k] == nil then return d end
                return ms_settings[k]
            end,
            saveSetting = function(_, k, v) ms_settings[k] = v end,
            flush = function() end,
        },
        ui = { document = {
            getCurrentPage = function() return 42 end,
            getXPointer = function() return "/xp42" end,
        } },
        _actionsModule = function()
            return { visibleAyahRange = function()
                return ms_range[1], ms_range[2], ms_range[3]
            end }
        end,
        _qulModule = function()
            return { ensureDb = function() return mconn end }
        end,
    }
    local mk = QM.marksForPage(msq)
    eq(mk ~= nil and mk.surah == ps_s, true, "marks-page: surah resolved")
    eq(mk.ayahs[ps_a][1], "mutashabihat", "marks-page: layer attributed")
    eq(QM.marksForPage(msq) == mk, true, "marks-page: cached per page")
    QM.setEnabled(msq, "mutashabihat", false)
    eq(QM.marksForPage(msq), nil, "marks-page: toggle off invalidates -> nothing")
    QM.setEnabled(msq, "similar", true)
    ms_range = { 27, 30, 30 }
    eq(QM.marksForPage(msq).ayahs[30][1], "similar",
        "marks-page: second layer resolves after invalidation")
    eq(QM.anyEnabled(msq), true, "marks: anyEnabled sees the toggle")
    eq(QM.styleFor(msq, "similar"), "underline",
        "marks: per-layer default style")
    QM.setStyle(msq, "similar", "gutter")
    eq(QM.styleFor(msq, "similar"), "gutter", "marks: style override saved")
else
    print("skip marks db tests (qul build or sqlite binding unavailable)")
end

-- painters are pure over fake boxes (two words on one line, one below)
local mb_boxes = {
    { x0 = 10, y0 = 100, x1 = 60, y1 = 120 },
    { x0 = 70, y0 = 102, x1 = 130, y1 = 118 },
    { x0 = 10, y0 = 140, x1 = 90, y1 = 160 },
}
local bands = QM.lineBands(mb_boxes)
eq(#bands, 2, "marks-paint: boxes merge into per-line bands")
eq(bands[1].y0 == 100 and bands[1].y1 == 120, true,
    "marks-paint: band spans the union of its boxes")
local lit, rects = 0, {}
local mb_bb = {
    lightenRect = function() lit = lit + 1 end,
    paintRect = function(_, px, py, pw, ph, color)
        table.insert(rects, { px, py, pw, ph, color })
    end,
}
QM.paintBoxes(mb_bb, 0, 0, mb_boxes, "lighten")
eq(lit, 3, "marks-paint: lighten touches every word box")
QM.paintBoxes(mb_bb, 0, 0, mb_boxes, "underline")
eq(#rects, 3, "marks-paint: underline = one rule per box")
eq(rects[1][2], 119, "marks-paint: rule sits at the box baseline")
rects = {}
QM.paintBoxes(mb_bb, 0, 0, mb_boxes, "gutter")
eq(#rects, 2, "marks-paint: gutter = one margin bar per line band")
local mb_g = QM.gutterGeom()
eq(rects[1][1] == mb_g.inset and rects[1][3] == mb_g.width, true,
    "marks-paint: gutter bar at the scaled inset (R3-F7, was x=2 raw)")
eq(mb_g.inset >= 10, true, "marks-paint: inset clear of e-reader bezels")
eq(#QM.lineBands({
    { x0 = 0, y0 = 100, x1 = 5, y1 = 110 },
    { x0 = 0, y0 = 130, x1 = 5, y1 = 140 },
    { x0 = 0, y0 = 105, x1 = 5, y1 = 135 },  -- bridges both bands
}), 1, "marks-paint: bridging box merges bands (no double gutter)")

-- review fixes: an enabled layer WITHOUT the qul package must not
-- re-scan on every paint (negative memoization, retried on invalidate)
local nm_settings = { marks_mutashabihat = true }
local nm_scans = 0
local nmq = {
    settings = {
        isTrue = function(_, k) return nm_settings[k] == true end,
        readSetting = function(_, k, d)
            if nm_settings[k] == nil then return d end
            return nm_settings[k]
        end,
        saveSetting = function(_, k, v) nm_settings[k] = v end,
        flush = function() end,
    },
    ui = { document = {
        getCurrentPage = function() return 7 end,
        getXPointer = function() return "/p7" end,
    } },
    _actionsModule = function()
        return { visibleAyahRange = function() return 1, 1, 7 end }
    end,
    _qulModule = function()
        return { ensureDb = function() nm_scans = nm_scans + 1 end }
    end,
}
eq(QM.marksForPage(nmq), nil, "marks-nodb: no package -> nothing marked")
QM.marksForPage(nmq)
nmq.ui.document.getCurrentPage = function() return 8 end
QM.marksForPage(nmq)
eq(nm_scans, 1, "marks-nodb: db absence memoized across pages (one scan)")
QM.invalidate(nmq)
QM.marksForPage(nmq)
eq(nm_scans, 2, "marks-nodb: invalidate retries the scan once")

-- live-app API: CreDocument exposes getScreenBoxesFromPositions
-- (Geom {x,y,w,h}) — normalized back to {x0,y0,x1,y1} (the raw-engine
-- path is exercised in the cre block below)
local wq = {
    ui = { document = {
        getScreenBoxesFromPositions = function(_, _r0, _r1, _seg)
            return { { x = 10, y = 20, w = 30, h = 12 },
                     { x = 0, y = 0, w = 0, h = 0 } }  -- degenerate: dropped
        end,
    } },
    _actionsModule = function()
        return {
            anchorConvention = function() return "start" end,
            resolveAnchorRef = function(_, s, a)
                return "#" .. s .. ":" .. tostring(a)
            end,
        }
    end,
}
local wb = QM.ayahBoxes(wq, 2, 5)
eq(#wb, 1, "marks-boxes: wrapper geoms normalized, degenerate dropped")
eq(wb[1].x0 == 10 and wb[1].x1 == 40 and wb[1].y1 == 32, true,
    "marks-boxes: Geom {x,y,w,h} -> {x0,y0,x1,y1}")

-- scroll mode: the overlay stands down before any resolution
local sc_pages = 0
local scq = {
    settings = nmq.settings,
    ui = {
        view = { view_mode = "scroll" },
        document = {
            getCurrentPage = function()
                sc_pages = sc_pages + 1
                return 1
            end,
            getXPointer = function() return "/x" end,
        },
    },
}
QM.drawMarks(scq, {}, 0, 0)
eq(sc_pages, 0, "marks-scroll: scroll mode skips resolution entirely")
end

-- quran_ayahpopup (D-R2-9): the ayah card — rows, routing, lead landing
do
local QAP = dofile("tools/quran.koplugin/quran_ayahpopup.lua")
if have_qul and sq3_ok then
    local QQc = dofile("tools/quran.koplugin/quran_qul.lua")
    local cconn = QQc.openPath(qul_db)
    local qul_stub = setmetatable({ ensureDb = function() return cconn end },
        { __index = QQc })
    local cap_log = {}
    local cardq = {
        surahName = function(_, s) return "Surah" .. s end,
        _qulModule = function() return qul_stub end,
        _actionsModule = function()
            return { showBrowser = function(_q, land)
                land({ qulModule = function() return {
                    showSimilar = function(_, s, a)
                        table.insert(cap_log, "sim:" .. s .. ":" .. a) end,
                    showThemesFor = function(_, s, a)
                        table.insert(cap_log, "th:" .. s .. ":" .. a) end,
                    showMutashabihat = function(_, s, a)
                        table.insert(cap_log, "ph:" .. s .. ":" .. a) end,
                    showTopicsFor = function(_, s, a)
                        table.insert(cap_log, "tp:" .. s .. ":" .. a) end,
                } end })
            end }
        end,
        _readerModule = function()
            return { showAyah = function(_q, s, a, _o)
                table.insert(cap_log, "read:" .. s .. ":" .. a)
                return true
            end }
        end,
        _textModule = function()
            return { ensureDb = function() return true end }
        end,
        _marksModule = function() return nil end,
        canReaderTafsir = function() return false end,
        openBrowserAtAyah = function(_, s, a)
            table.insert(cap_log, "uap:" .. s .. ":" .. a)
        end,
    }
    eq(QAP.show(cardq, 1, 1), true, "card: shows for 1:1")
    local cd = _shown
    local function findBtn(pat)
        for _i, r in ipairs(cd.buttons) do
            for _j, b in ipairs(r) do
                if b.text and b.text:find(pat, 1, true) then return b end
            end
        end
    end
    eq(cd.title, "Surah1 1:1", "card: titled with the ayah")
    eq(findBtn("Translations") ~= nil, true, "card: Translations row (text package present, D-R3-3)")
    eq(findBtn("Tafsir"), nil, "card: no Tafsir row without a tafsir path")
    local simbtn = findBtn("Similar ayahs (")
    eq(simbtn ~= nil and simbtn.enabled, true,
        "card: similar count row live (bidirectional count)")
    simbtn.callback()
    eq(cap_log[#cap_log], "sim:1:1", "card: similar row lands the browser list")
    findBtn("Translations").callback()
    eq(cap_log[#cap_log], "read:1:1", "card: Translations row opens the Reader")
    eq(findBtn("Ayah page") ~= nil, true, "card: full ayah page row")
    findBtn("Ayah page").callback()
    eq(cap_log[#cap_log], "uap:1:1", "card: ayah page row routes to the UAP")

    -- D-R3-5 STABLE CARD: the lead machinery is GONE — the card presents
    -- the same four counted rows, same order, marked or not (marked
    -- state lives only in the in-book mark itself)
    eq(QAP.leadFor, nil, "card: entry-point lead machinery removed (D-R3-5)")
    local function cardShape(d)
        local t = {}
        for _i, r in ipairs(d.buttons) do
            for _j, b in ipairs(r) do table.insert(t, b.text) end
        end
        return table.concat(t, "|")
    end
    local base_shape = cardShape(cd)
    eq(base_shape:find("Similar ayahs %(.-|Themes %(.-|Repeated phrases %(.-|Topics %(")
        ~= nil, true, "card: four counted rows, fixed order (D-R3-5)")
    -- D-R3-12: every connection row lands the per-kind browser LIST
    -- (siblings never lost — no direct single-connection opens)
    cap_log = {}
    findBtn("Themes (").callback()
    findBtn("Repeated phrases (").callback()
    findBtn("Topics (").callback()
    eq(table.concat(cap_log, ","), "th:1:1,ph:1:1,tp:1:1",
        "card: themes/phrases/topics land the per-kind lists (D-R3-12)")
    -- a marked ayah changes NOTHING: the card never consults the marks
    -- module and renders the identical shape
    cardq._marksModule = function()
        error("card must not consult marks (D-R3-5 stable card)")
    end
    eq(QAP.show(cardq, 1, 1), true, "card: shows with marks layer active")
    eq(cardShape(_shown), base_shape,
        "card: marked-state shape identical to unmarked (stable card)")
else
    print("skip ayah-card tests (qul build or sqlite binding unavailable)")
end
end

-- ROUND 3 fixes (owner feedback 2026-07-17, design doc §ROUND 3 F7–F12)
do
    -- F11: stripEntryHeader (extracted live from main.lua) — the baked-in
    -- duplicate header is dropped, range comment + body survive
    local shchunk = extract("--- Strip the entry's own leading centered header",
        "--- Create a TXT ON/OFF toggle button") .. "\nreturn stripEntryHeader\n"
    local stripEntryHeader = assert(loadstring(shchunk))()
    local tdef = '<!-- range:2:255-255 -->\n'
        .. '<p style="text-align:center;font-size:110%"><b>Al-Baqarah 255</b></p>\n'
        .. '<div>Body text</div>'
    local sout = stripEntryHeader(tdef)
    eq(sout:find("range:2:255", 1, true) ~= nil, true,
        "r3-strip: range comment preserved (group nav parses it)")
    eq(sout:find("Al-Baqarah 255", 1, true), nil, "r3-strip: duplicate header dropped")
    eq(sout:find("Body text", 1, true) ~= nil, true, "r3-strip: body intact")
    local odef = '<p style="text-align:center;font-size:130%"><b>1. X</b></p>\n<div>ov</div>'
    eq(stripEntryHeader(odef):find("<b>", 1, true), nil,
        "r3-strip: overview header (no range comment) dropped")
    local wdef = '<b>word</b> — root: x<br>gloss'
    eq(stripEntryHeader(wdef), wdef, "r3-strip: non-header entries pass through")
    eq(stripEntryHeader(nil), nil, "r3-strip: nil-safe")

    -- F10 + F7: marking defaults + gutter geometry
    local QM3 = dofile("tools/quran.koplugin/quran_marks.lua")
    local mut_style
    for _i, l in ipairs(QM3.LAYERS) do
        if l.key == "mutashabihat" then mut_style = l.default_style end
    end
    eq(mut_style, "underline", "r3-marks: mutashabihat default off gray-highlight")
    package.preload["ffi/blitbuffer"] = package.preload["ffi/blitbuffer"]
        or function() return { COLOR_DARK_GRAY = "dg" } end
    package.loaded["ffi/blitbuffer"] = nil
    local g = QM3.gutterGeom()
    eq(g.inset >= 10, true, "r3-marks: gutter inset clear of the bezel (was 2 raw px)")
    local rects = {}
    local fbb = { paintRect = function(_, x2, y2, w2, h2)
        table.insert(rects, { x = x2, y = y2, w = w2, h = h2 })
    end }
    QM3.paintBoxes(fbb, 0, 0, { { x0 = 50, x1 = 90, y0 = 100, y1 = 120 } }, "gutter")
    eq(rects[1] and rects[1].x, g.inset, "r3-marks: bar painted at the scaled inset")

    -- F8 + F12: grammar rows in the browser + LIVE back labels
    bq.ui.dictionary.enabled_dict_names = {
        "Tafsir al-Muyassar (المیسر)", "Quran I'rab", "Quran Grammar",
    }
    local taf_opens = {}
    bq.openTafsirReader = function(_, s2, a2, o2)
        table.insert(taf_opens, (o2.dict or "?") .. "@" .. s2 .. ":" .. a2
            .. "|" .. tostring(o2.back_label))
        return true
    end
    bq.canReaderTafsir = function() return true end
    QB.show(bq, QA)
    local root3 = _shown.item_table
    local gram_root
    for _i, it in ipairs(root3) do
        if it.text == "Grammar" then gram_root = it end
    end
    eq(gram_root ~= nil, true,
        "r3-grammar: Grammar promoted to the browser root (D-R3-7a)")
    QB.show(bq, QA)
    _shown.item_table[1].callback()  -- Current position → ayah page
    local gram_row
    for _i, it in ipairs(_shown.item_table) do
        if it.text == "Grammar" then gram_row = it end
    end
    eq(gram_row ~= nil, true, "r3-grammar: ayah page gains the Grammar row")
    gram_row.callback()
    eq(taf_opens[1], "Quran Grammar@77:33|←",
        "r3-backlabel: browser-launched bottom-of-stack = bare ← (D-R3-8 hybrid)")
    bq.ui.dictionary.enabled_dict_names = {
        "Tafsir al-Muyassar (المیسر)", "Quran I'rab",
    }
    bq.openTafsirReader = nil
    bq.canReaderTafsir = nil

    -- F12: the tafsir picker forwards the caller's back label
    local pchunk = "local _ = function(s) return s end\nlocal Quran = {}\n"
        .. extract("--- Tafsir picker:", "--- Build the custom button layout")
        .. "\nreturn Quran\n"
    local P = assert(loadstring(pchunk))()
    local picked
    local pq = {
        _installedTafsirs = function() return { "A", "B" } end,
        settings = { saveSetting = function() end, flush = function() end },
        openTafsirReader = function(_, _s2, _a2, o2)
            picked = (o2.dict or "?") .. "|" .. tostring(o2.back_label)
        end,
        _showTafsirPicker = P._showTafsirPicker,
    }
    pq:_showTafsirPicker(2, 5, { back_label = "← Ayah page" })
    _shown.buttons[1][1].callback()
    eq(picked, "A|← Ayah page", "r3-backlabel: picker forwards the back label")

    -- F12: topic About routes through the Reader idiom (hop stack, ←)
    if have_qul and sq3_ok then
        local QQ3 = dofile("tools/quran.koplugin/quran_qul.lua")
        local q3conn = QQ3.openPath(qul_db)
        eq(q3conn ~= nil, true, "r3-about: qul db opens")
        local rd_specs = {}
        local ab_t, ab_i
        local abrowser = {
            current_title = "Topics 1:1",
            quran = {
                surahName = function(_, s2) return "S" .. s2 end,
                _readerModule = function()
                    return { show = function(spec)
                        table.insert(rd_specs, spec)
                    end }
                end,
            },
            navigateForward = function(_, t3, i3) ab_t, ab_i = t3, i3 end,
        }
        QQ3.showTopic(abrowser, 1)  -- "Allah" (has a description)
        eq(ab_t, "Allah", "r3-about: topic screen opens")
        eq(ab_i[1].text:find("About", 1, true), 1, "r3-about: About row present")
        ab_i[1].callback()
        eq(rd_specs[1] and rd_specs[1].kind, "topic",
            "r3-about: About opens in the Reader idiom (hop-stack surface)")
        eq(rd_specs[1].back_label, "←",
            "r3-about: browser-launched About shows the bare arrow (D-R3-8)")
    end

    -- F9: the ayah card gains a Grammar row (Reader route, tafsir pattern)
    local QAP3 = dofile("tools/quran.koplugin/quran_ayahpopup.lua")
    local g_open
    local g_res = { grammar = "Quran Grammar",
                    tafsir = { "Tafsir al-Muyassar (المیسر)" } }
    local gcard = {
        surahName = function(_, s2) return "S" .. s2 end,
        _actionsModule = function()
            return {
                showBrowser = function() end,
                detectResources = function() return g_res end,
            }
        end,
        _qulModule = function() return nil end,
        _readerModule = function() return {} end,
        _textModule = function() return nil end,
        _marksModule = function() return nil end,
        canReaderTafsir = function() return true end,
        openTafsirReader = function(_, s2, a2, o2)
            g_open = tostring(o2.dict) .. "@" .. s2 .. ":" .. a2
        end,
    }
    eq(QAP3.show(gcard, 2, 5), true, "r3-card: card shows")
    local grow
    for _i, r in ipairs(_shown.buttons) do
        for _j, b in ipairs(r) do
            if b.text == "Grammar" then grow = b end
        end
    end
    eq(grow ~= nil, true, "r3-card: Grammar row present")
    grow.callback()
    eq(g_open, "Quran Grammar@2:5", "r3-card: opens the grammar dict in the Reader")
    local trow
    for _i, r in ipairs(_shown.buttons) do
        for _j, b in ipairs(r) do
            if b.text == "Tafsir" then trow = b end
        end
    end
    eq(trow ~= nil, true, "r3-card: Tafsir row present when a tafsir is installed")

    -- F13+F14: continuous 2-per-row grid THROUGH Close — a single
    -- full-width row may only be the LAST row (odd totals); Close is
    -- the grid's final cell, not a standalone bold row
    local singles_mid = 0
    for i2 = 1, #_shown.buttons - 1 do
        if #_shown.buttons[i2] == 1 then singles_mid = singles_mid + 1 end
    end
    eq(singles_mid, 0, "r3-card-grid: singles only allowed as the last row")
    local last_row = _shown.buttons[#_shown.buttons]
    eq(last_row[#last_row].text, "Close",
        "r3-card-grid: Close is the grid's last cell (F14)")
    -- gcard = Tafsir/Grammar/Ayah page/Close (even) → Close pairs up
    eq(#last_row, 2, "r3-card-grid: Close pairs with Ayah page on even totals")
    eq(last_row[#last_row].font_bold, false, "r3-card-grid: Close unbolded")

    -- F16: no tafsir dict installed → NO Tafsir row (openTafsirReader
    -- returns false with none — the row was a dead button)
    g_res = { tafsir = {} }
    eq(QAP3.show(gcard, 2, 5), true, "r3-card: card shows without tafsirs")
    local trow2
    for _i, r in ipairs(_shown.buttons) do
        for _j, b in ipairs(r) do
            if b.text == "Tafsir" then trow2 = b end
        end
    end
    eq(trow2, nil, "r3-card: Tafsir row gated on an installed tafsir (F16)")
end

-- F15 + D-R3-11a: quick panel = surah/Quran-level launcher on one
-- continuous 2-per-row grid; ayah-scoped rows gone (the long-press
-- card and the browser own ayah level); More settings…/Close unbolded
do
    local pset = {}
    local pq = {
        _is_quran_book = true,
        ui = { dictionary = { enabled_dict_names = {} } },
        settings = {
            isTrue = function(_, k) return pset[k] == true end,
            nilOrTrue = function(_, k) return pset[k] ~= false end,
            readSetting = function() return nil end,
            saveSetting = function(_, k, v) pset[k] = v end,
            flush = function() end,
        },
    }
    QA.showQuickPanel(pq)
    local pb = _shown.buttons
    local ptexts = {}
    for _i, r in ipairs(pb) do
        for _j, b in ipairs(r) do table.insert(ptexts, b.text) end
    end
    local pjoined = table.concat(ptexts, "|")
    eq(pjoined:find("This ayah", 1, true), nil,
        "r3-panel: This ayah row gone (D-R3-11a)")
    eq(pjoined:find("All resources", 1, true), nil,
        "r3-panel: ayah-scoped All resources row gone (D-R3-11a)")
    eq(pjoined:find("Tafsir", 1, true), nil,
        "r3-panel: ayah-scoped Tafsir row gone (D-R3-11a)")
    eq(ptexts[1]:find("This surah", 1, true), 1,
        "r3-panel: This surah launcher row leads")
    eq(pjoined:find("Search", 1, true) ~= nil, true,
        "r3-panel: Search launcher row")
    eq(pjoined:find("Browser", 1, true) ~= nil, true,
        "r3-panel: Browser launcher row")
    local psingles = 0
    for i2 = 1, #pb - 1 do
        if #pb[i2] == 1 then psingles = psingles + 1 end
    end
    eq(psingles, 0, "r3-panel-grid: no mid-panel single rows")
    local plast = pb[#pb]
    eq(plast[#plast].text, "Close", "r3-panel-grid: Close is the last cell")
    eq(plast[#plast].font_bold, false, "r3-panel-grid: Close unbolded")
    local msb, smb
    for _i, r in ipairs(pb) do
        for _j, b in ipairs(r) do
            if b.text == "More settings…" then msb = b end
            if b.text and b.text:find("Simple mode", 1, true) then smb = b end
        end
    end
    eq(msb ~= nil, true, "r3-panel: Settings renamed to 'More settings…'")
    eq(msb.font_bold, false, "r3-panel: More settings… unbolded")
    -- D-R3-2: the open-MODE toggle chip lives on the panel
    eq(smb ~= nil, true, "d-r3-2: Simple mode chip on the panel")
    smb.callback()
    eq(pset.quran_simple_mode, true, "d-r3-2: chip toggles the mode setting")
    for _i, r in ipairs(_shown.buttons) do
        for _j, b in ipairs(r) do
            if b.text and b.text:find("Simple mode", 1, true) then smb = b end
        end
    end
    eq(smb.text:sub(1, 3), "\226\156\147",
        "d-r3-2: reopened panel shows the chip checked")
    pset.quran_simple_mode = nil
    -- with the mark chips joining (9 + 3 = 12, even): Close pairs up
    local QMp = dofile("tools/quran.koplugin/quran_marks.lua")
    pq._marksModule = function() return QMp end
    pq._qulModule = function()
        return { ensureDb = function() return true end }
    end
    QA.showQuickPanel(pq)
    pb = _shown.buttons
    psingles = 0
    for i2 = 1, #pb - 1 do
        if #pb[i2] == 1 then psingles = psingles + 1 end
    end
    eq(psingles, 0, "r3-panel-grid: even case — no mid-panel singles")
    eq(#pb[#pb], 2, "r3-panel-grid: even case — Close pairs up")
    eq(pb[#pb][2].text, "Close", "r3-panel-grid: even case — Close is last")
end

-- D-R3-4: terminology unification — string-parity pin. ONE canonical
-- name per connection layer everywhere ("Similar ayahs" / "Themes" /
-- "Repeated phrases" / "Topics"; "Translations" for the text row,
-- D-R3-3); legacy variants must never reappear in any plugin surface.
do
    local tfiles = {
        "main.lua", "quran_actions.lua", "quran_ayahpopup.lua",
        "quran_browser.lua", "quran_marks.lua", "quran_qul.lua",
        "quran_reader.lua", "quran_roots.lua", "quran_bands.lua",
    }
    local tsrcs = {}
    for _i, f in ipairs(tfiles) do
        local fh = assert(io.open("tools/quran.koplugin/" .. f, "r"))
        tsrcs[f] = fh:read("*a"); fh:close()
    end
    local banned = {
        '_("Mutashabihat")', '_("Theme starts")', '_("Themes here")',
        '_("Topics here")', '_("Similar to")', '_("All similar")',
        '_("Phrases")', '_("Similar")', '_("Read")',
        '_("Read (text & translation)")', '_("Text & translation")',
    }
    for _j, b in ipairs(banned) do
        local hits = {}
        for _i, f in ipairs(tfiles) do
            if tsrcs[f]:find(b, 1, true) then table.insert(hits, f) end
        end
        eq(table.concat(hits, ","), "",
            "r3-terms: no surface carries legacy " .. b)
    end
    local QM4 = dofile("tools/quran.koplugin/quran_marks.lua")
    local canon = {}
    for _i, l in ipairs(QM4.LAYERS) do
        canon[l.key] = { label = l.label, long = l.long_label }
    end
    eq(canon.mutashabihat.label, "Repeated phrases",
        "r3-terms: phrase layer canonical short name")
    eq(canon.mutashabihat.long, "Repeated phrases (mutashabihat)",
        "r3-terms: phrase layer settings long form")
    eq(canon.themes.label, "Themes", "r3-terms: theme layer canonical")
    eq(canon.similar.label, "Similar ayahs",
        "r3-terms: similar layer canonical")
end

-- D-R3-1: theme heading bands (CSS generation + style-tweak toggle)
do
    local QBN = dofile("tools/quran.koplugin/quran_bands.lua")
    eq(QBN.cssEscape('a "b" \\ c'), 'a \\"b\\" \\\\ c', "bands: css escaping")
    local css = QBN.generateCss({
        { surah = 2, ayah_from = 6, theme = "Warning" },
        { surah = 2, ayah_from = 6, theme = "Zeal" },
        { surah = 2, ayah_from = 45, theme = 'Say "help"' },
        { surah = 3, ayah_from = 1, theme = "Opening" },
    })
    eq(css:find("p.ayah-text::before", 1, true) ~= nil, true,
        "bands: shared block rule present")
    eq(css:find('p#ayah-2-6::before { content: "1) Warning · Zeal"', 1, true) ~= nil,
        true, "bands: same-ayah themes merge into one numbered band")
    eq(css:find('p#ayah-2-45::before { content: "2) Say \\"help\\""', 1, true) ~= nil,
        true, "bands: per-surah numbering + escaped quotes")
    eq(css:find('p#ayah-3-1::before { content: "1) Opening"', 1, true) ~= nil,
        true, "bands: numbering restarts per surah")
    eq(css, QBN.generateCss({
        { surah = 2, ayah_from = 6, theme = "Warning" },
        { surah = 2, ayah_from = 6, theme = "Zeal" },
        { surah = 2, ayah_from = 45, theme = 'Say "help"' },
        { surah = 3, ayah_from = 1, theme = "Opening" },
    }), "bands: byte-deterministic (render-cache hash stability)")

    if have_qul and sq3_ok then
        local QQb = dofile("tools/quran.koplugin/quran_qul.lua")
        local bconn = QQb.openPath(qul_db)
        local all = QBN.allThemes(bconn)
        eq(#all, 1049, "bands-db: all QUL ayah-theme rows (issue #3 dataset)")
        local real_css = QBN.generateCss(all)
        eq(select(2, real_css:gsub("::before { content:", "")) > 900, true,
            "bands-db: ~1k content rules generated")
        eq(real_css, QBN.generateCss(QBN.allThemes(bconn)),
            "bands-db: full stylesheet deterministic")
    end

    -- toggle wiring over a fake ReaderStyleTweak
    package.preload["ui/widget/notification"] =
        package.preload["ui/widget/notification"] or function()
            return { new = function(_, spec) return spec end }
        end
    local applied = 0
    local st = {
        enabled = true,
        doc_tweaks = {},
        tweaks_by_id = {},
        updateCssText = function(_self, apply)
            if apply then applied = applied + 1 end
        end,
    }
    local bq2 = {
        ui = { styletweak = st },
        _qulModule = function() return nil end,  -- forces the css-file miss
    }
    eq(QBN.enabled(bq2), false, "bands: disabled by default")
    local ok2, err2 = QBN.setEnabled(bq2, true)
    eq(ok2 == nil and err2 ~= nil, true,
        "bands: enable without the qul package fails loud")
    -- with a css file already on disk the enable path registers + applies
    QBN.ensureCssFile = function() return "/tmp/fake.css" end
    eq(QBN.setEnabled(bq2, true), true, "bands: enable succeeds")
    eq(st.doc_tweaks[QBN.TWEAK_ID], true, "bands: doc tweak enabled (sidecar-persisted)")
    eq(st.tweaks_by_id[QBN.TWEAK_ID] ~= nil, true,
        "bands: first-session registry injection")
    eq(st.tweaks_by_id[QBN.TWEAK_ID].css_path, "/tmp/fake.css",
        "bands: injected entry carries css_path")
    eq(applied, 1, "bands: applied immediately (one re-render)")
    QBN.setEnabled(bq2, false)
    eq(st.doc_tweaks[QBN.TWEAK_ID], nil, "bands: disable removes the doc tweak")
    eq(applied, 2, "bands: removal re-applies")
    eq(QBN.enabled(bq2), false, "bands: reads back disabled")
end

-- REAL-ENGINE integration: load the actual CREngine + a real built EPUB
-- (marks: the overlay's box primitive runs against the real engine below)
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
    -- D-R2-5 spike: ayah anchor range -> screen boxes, the in-book
    -- marking layer's core primitive (drawing is already proven by the
    -- header overlay's paintTo hook). Same engine call highlights use
    -- (CreDocument:getScreenBoxesFromPositions wraps it).
    local mprefix = QA.fragPrefix(doc:getXPointer())
    local mk0 = "#" .. (mprefix or "") .. "ayah-77-33"
    local mk1 = "#" .. (mprefix or "") .. "ayah-77-34"
    local okb, mboxes = pcall(doc.getWordBoxesFromPositions, doc, mk0, mk1, true)
    eq(okb and type(mboxes) == "table" and #mboxes > 0, true,
        "cre-spike: ayah anchor range yields word boxes (marking feasible)")
    if okb and type(mboxes) == "table" and mboxes[1] then
        local mb = mboxes[1]
        eq(mb.x1 ~= nil and mb.x0 ~= nil and mb.x1 > mb.x0 and mb.y1 >= mb.y0,
            true, "cre-spike: box geometry sane")
    end
    -- D-R2-5 overlay: the marks module's full box primitive (anchor
    -- pair per convention -> word boxes) against the real engine
    do
        local QMc = dofile("tools/quran.koplugin/quran_marks.lua")
        cq._actionsModule = function() return QA end
        local mkb = QMc.ayahBoxes(cq, 77, 33)
        eq(type(mkb) == "table" and #mkb > 0, true,
            "cre-marks: ayahBoxes resolves real word boxes")
        eq(QMc.ayahBoxes(cq, 77, 9999), nil,
            "cre-marks: missing anchors degrade to nil, never crash")
        cq._actionsModule = nil
    end
    -- pin the engine's compareXPointers sign convention every detection
    -- path relies on (earlier-in-DOM first argument -> +1)
    doc:gotoPage(p77)
    local sign_a = doc:getXPointer()
    doc:gotoPage(p33)
    local sign_b = doc:getXPointer()
    eq(doc:compareXPointers(sign_a, sign_b), 1,
        "cre: compareXPointers sign — earlier first arg = +1")
    eq(doc:compareXPointers(sign_b, sign_a), -1,
        "cre: compareXPointers sign — later first arg = -1")
    doc:close()
else
    print("skip cre integration tests (app bundle or built EPUB unavailable)")
end

print("ALL HELPER TESTS PASS")
