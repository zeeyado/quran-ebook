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

print("ALL HELPER TESTS PASS")
