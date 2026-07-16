--- Quran Helper plugin for KOReader.
--
-- Features:
--   1. Grammar dictionary lookup: intercepts long-press on ayah number markers
--      and prepends the surah name for unambiguous dictionary lookup.
--   2. Juz status bar: shows current juz in KOReader's footer while reading,
--      with boundary indicator (*) at juz transitions.
--
-- Grammar lookup flow:
--   1. onWordSelection: if selected text is Arabic-Indic digits, extract
--      surah number and name from TOC title and stash them.
--   2. onWordLookup: if we have a stashed surah and the text is
--      Arabic-Indic digits, return candidates for dictionary lookup:
--      - "An-Naba 2" (human-readable, for grammar dictionary headers)
--      - "078:002" (zero-padded, for backward compatibility)
--
-- Compatible TOC title formats:
--   Arabic-only: "٧٨ سورة النبإ"
--   Bilingual:   "78. An-Naba — سورة النبإ"
--
-- @module koplugin.quran
-- @alias Quran

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local DictQuickLookup = require("ui/widget/dictquicklookup")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LanguageSupport = require("languagesupport")
local LuaSettings = require("luasettings")
local Math = require("optmath")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local SpinWidget = require("ui/widget/spinwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local logger = require("logger")
local Screen = Device.screen
local _ = require("gettext")

local Quran = WidgetContainer:extend{
    name = "quran",
    pretty_name = "Quran Helper",
}

-- UTF-8 character iterator pattern (start byte + continuation bytes).
-- Lua's byte-range patterns like [٠-٩] are broken for multi-byte UTF-8,
-- so we iterate characters and look them up in tables instead.
local UTF8_CHAR = ".[\128-\191]*"

-- Surah names for generating human-readable lookup keys.
-- Used when TOC has no Latin name (Arabic-only EPUBs).
-- Source: Quran.com API name_simple field.
local SURAH_NAMES = {
    "Al-Fatihah", "Al-Baqarah", "Ali 'Imran", "An-Nisa", "Al-Ma'idah",
    "Al-An'am", "Al-A'raf", "Al-Anfal", "At-Tawbah", "Yunus",
    "Hud", "Yusuf", "Ar-Ra'd", "Ibrahim", "Al-Hijr",
    "An-Nahl", "Al-Isra", "Al-Kahf", "Maryam", "Taha",
    "Al-Anbya", "Al-Hajj", "Al-Mu'minun", "An-Nur", "Al-Furqan",
    "Ash-Shu'ara", "An-Naml", "Al-Qasas", "Al-'Ankabut", "Ar-Rum",
    "Luqman", "As-Sajdah", "Al-Ahzab", "Saba", "Fatir",
    "Ya-Sin", "As-Saffat", "Sad", "Az-Zumar", "Ghafir",
    "Fussilat", "Ash-Shuraa", "Az-Zukhruf", "Ad-Dukhan", "Al-Jathiyah",
    "Al-Ahqaf", "Muhammad", "Al-Fath", "Al-Hujurat", "Qaf",
    "Adh-Dhariyat", "At-Tur", "An-Najm", "Al-Qamar", "Ar-Rahman",
    "Al-Waqi'ah", "Al-Hadid", "Al-Mujadila", "Al-Hashr", "Al-Mumtahanah",
    "As-Saf", "Al-Jumu'ah", "Al-Munafiqun", "At-Taghabun", "At-Talaq",
    "At-Tahrim", "Al-Mulk", "Al-Qalam", "Al-Haqqah", "Al-Ma'arij",
    "Nuh", "Al-Jinn", "Al-Muzzammil", "Al-Muddaththir", "Al-Qiyamah",
    "Al-Insan", "Al-Mursalat", "An-Naba", "An-Nazi'at", "'Abasa",
    "At-Takwir", "Al-Infitar", "Al-Mutaffifin", "Al-Inshiqaq", "Al-Buruj",
    "At-Tariq", "Al-A'la", "Al-Ghashiyah", "Al-Fajr", "Al-Balad",
    "Ash-Shams", "Al-Layl", "Ad-Duhaa", "Ash-Sharh", "At-Tin",
    "Al-'Alaq", "Al-Qadr", "Al-Bayyinah", "Az-Zalzalah", "Al-'Adiyat",
    "Al-Qari'ah", "At-Takathur", "Al-'Asr", "Al-Humazah", "Al-Fil",
    "Quraysh", "Al-Ma'un", "Al-Kawthar", "Al-Kafirun", "An-Nasr",
    "Al-Masad", "Al-Ikhlas", "Al-Falaq", "An-Nas",
}

-- Arabic surah names (without سورة prefix).
-- Source: Quran.com API name_arabic field.
local SURAH_NAMES_ARABIC = {
    "الفاتحة", "البقرة", "آل عمران", "النساء", "المائدة",
    "الأنعام", "الأعراف", "الأنفال", "التوبة", "يونس",
    "هود", "يوسف", "الرعد", "إبراهيم", "الحجر",
    "النحل", "الإسراء", "الكهف", "مريم", "طه",
    "الأنبياء", "الحج", "المؤمنون", "النور", "الفرقان",
    "الشعراء", "النمل", "القصص", "العنكبوت", "الروم",
    "لقمان", "السجدة", "الأحزاب", "سبأ", "فاطر",
    "يس", "الصافات", "ص", "الزمر", "غافر",
    "فصلت", "الشورى", "الزخرف", "الدخان", "الجاثية",
    "الأحقاف", "محمد", "الفتح", "الحجرات", "ق",
    "الذاريات", "الطور", "النجم", "القمر", "الرحمن",
    "الواقعة", "الحديد", "المجادلة", "الحشر", "الممتحنة",
    "الصف", "الجمعة", "المنافقون", "التغابن", "الطلاق",
    "التحريم", "الملك", "القلم", "الحاقة", "المعارج",
    "نوح", "الجن", "المزمل", "المدثر", "القيامة",
    "الإنسان", "المرسلات", "النبأ", "النازعات", "عبس",
    "التكوير", "الانفطار", "المطففين", "الانشقاق", "البروج",
    "الطارق", "الأعلى", "الغاشية", "الفجر", "البلد",
    "الشمس", "الليل", "الضحى", "الشرح", "التين",
    "العلق", "القدر", "البينة", "الزلزلة", "العاديات",
    "القارعة", "التكاثر", "العصر", "الهمزة", "الفيل",
    "قريش", "الماعون", "الكوثر", "الكافرون", "النصر",
    "المسد", "الإخلاص", "الفلق", "الناس",
}

-- Ayah counts per surah (1-indexed) for prev/next navigation.
local SURAH_AYAH_COUNTS = {
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109,  -- 1-10
    123, 111, 43, 52, 99, 128, 111, 110, 98, 135,   -- 11-20
    112, 78, 118, 64, 77, 227, 93, 88, 69, 60,      -- 21-30
    34, 30, 73, 54, 45, 83, 182, 88, 75, 85,        -- 31-40
    54, 53, 89, 59, 37, 35, 38, 29, 18, 45,         -- 41-50
    60, 49, 62, 55, 78, 96, 29, 22, 24, 13,         -- 51-60
    14, 11, 11, 18, 12, 12, 30, 52, 52, 44,         -- 61-70
    28, 28, 20, 56, 40, 31, 50, 40, 46, 42,         -- 71-80
    29, 19, 36, 25, 22, 17, 19, 26, 30, 20,         -- 81-90
    15, 21, 11, 8, 8, 19, 5, 8, 8, 11,              -- 91-100
    11, 8, 3, 9, 5, 4, 7, 3, 6, 3,                  -- 101-110
    5, 4, 5, 6,                                       -- 111-114
}

-- Warsh (Nafi') ayah counts -- 6,214 total; 50 surahs differ from Hafs.
-- Source: src/quran_ebook/data/validate.py AYAH_COUNTS_WARSH (the pipeline's
-- riwayah-aware validation table). Selected via Quran:_ayahCounts().
local SURAH_AYAH_COUNTS_WARSH = {
    7, 285, 200, 175, 122, 167, 206, 76, 130, 109,  -- 1-10
    121, 111, 44, 54, 99, 128, 110, 105, 99, 134,  -- 11-20
    111, 76, 119, 62, 77, 226, 95, 88, 69, 59,  -- 21-30
    33, 30, 73, 54, 46, 82, 182, 86, 72, 84,  -- 31-40
    53, 50, 89, 56, 36, 34, 39, 29, 18, 45,  -- 41-50
    60, 47, 61, 55, 77, 99, 28, 21, 24, 13,  -- 51-60
    14, 11, 11, 18, 12, 12, 31, 52, 52, 44,  -- 61-70
    30, 28, 18, 55, 39, 31, 50, 40, 45, 42,  -- 71-80
    29, 19, 36, 25, 22, 17, 19, 26, 32, 20,  -- 81-90
    15, 21, 11, 8, 8, 20, 5, 8, 9, 11,  -- 91-100
    10, 8, 3, 9, 5, 5, 6, 3, 6, 3,  -- 101-110
    5, 4, 5, 6,  -- 111-114
}

-- PARKED 2026-07-10: hizb display stuck at "hizb 20" in several books
-- (both bars, riwayah-independent — so not the Warsh remap). Suspected:
-- getPageFromXPointer resolving anchors beyond CREngine's lazily-paginated
-- frontier to a clamped/garbage page at cache-build time, so every
-- position past boundary 20's page matches it. logger.info
-- instrumentation is wired (resolution dump, hizb transitions, rerender
-- events) — flip this flag and run the emulator from a terminal to
-- capture. Menu toggles hidden while parked; settings are preserved.
local HIZB_FEATURE_ENABLED = false

-- Hizb boundary data (hizb number -> {surah, ayah}), 60 hizbs (Hafs).
-- Generated from Quran.com API v4 verse metadata (hizb_number per verse).
local HIZB_BOUNDARIES = {
    {1, 1},      {2, 75},     {2, 142},    {2, 203},    {2, 253},   
    {3, 15},     {3, 93},     {3, 171},    {4, 24},     {4, 88},    
    {4, 148},    {5, 27},     {5, 82},     {6, 36},     {6, 111},   
    {7, 1},      {7, 88},     {7, 171},    {8, 41},     {9, 34},    
    {9, 93},     {10, 26},    {11, 6},     {11, 84},    {12, 53},   
    {13, 19},    {15, 1},     {16, 51},    {17, 1},     {17, 99},   
    {18, 75},    {20, 1},     {21, 1},     {22, 1},     {23, 1},    
    {24, 21},    {25, 21},    {26, 111},   {27, 56},    {28, 51},   
    {29, 46},    {31, 22},    {33, 31},    {34, 24},    {36, 28},   
    {37, 145},   {39, 32},    {40, 41},    {41, 47},    {43, 24},   
    {46, 1},     {48, 18},    {51, 31},    {55, 1},     {58, 1},    
    {62, 1},     {67, 1},     {72, 1},     {78, 1},     {87, 1},    
}

-- One-line warning prepended to ayah-keyed dictionary results on Warsh
-- books in surahs whose ayah numbering differs from Hafs (decision W2:
-- gate now, remap via the alignment table in Wave 5). The dicts are keyed
-- by Hafs numbers, so content there may belong to a neighboring ayah.
local WARSH_NOTICE_TEXT = "\226\154\160 \216\170\216\177\217\130\217\138\217\133 \216\167\217\132\216\162\217\138\216\167\216\170 \216\168\216\167\217\132\216\173\217\129\216\181 \226\128\148 \217\130\216\175 \217\138\216\174\216\181 \216\167\217\132\217\133\216\173\216\170\217\136\217\137 \216\162\217\138\216\169 \217\133\216\172\216\167\217\136\216\177\216\169 \216\168\216\177\217\136\216\167\217\138\216\169 \217\136\216\177\216\180\n\n"
local WARSH_NOTICE_HTML = "<p><small>\226\154\160 \216\170\216\177\217\130\217\138\217\133 \216\167\217\132\216\162\217\138\216\167\216\170 \216\168\216\167\217\132\216\173\217\129\216\181 \226\128\148 \217\130\216\175 \217\138\216\174\216\181 \216\167\217\132\217\133\216\173\216\170\217\136\217\137 \216\162\217\138\216\169 \217\133\216\172\216\167\217\136\216\177\216\169 \216\168\216\177\217\136\216\167\217\138\216\169 \217\136\216\177\216\180</small></p>"

-- Reverse lookup: surah name -> surah number
local SURAH_NAME_TO_NUM = {}
for i, name in ipairs(SURAH_NAMES) do
    SURAH_NAME_TO_NUM[name] = i
end

--- Normalize Arabic for surah-name matching: strip tashkeel/tatweel/NBSP,
-- fold alef variants (wasla/hamza carriers), drop a leading "surat" word.
local function normalizeArabicName(str)
    if not str then return "" end
    str = str:gsub("\216[\144-\154]", "")             -- U+0610-061A small-high signs
    str = str:gsub("\217[\139-\159]", "")             -- U+064B-065F harakat
    str = str:gsub("\217\176", "")                     -- U+0670 superscript alef
    str = str:gsub("\217\128", "")                     -- U+0640 tatweel
    str = str:gsub("\194\160", " ")                    -- NBSP -> space
    str = str:gsub("\217\177", "\216\167")            -- U+0671 wasla -> alef
    str = str:gsub("\216[\162\163\165]", "\216\167") -- alef-hamza forms -> alef
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    str = str:gsub("^\216\179\217\136\216\177\216\169%s+", "")               -- drop "surat " prefix
    return str
end

-- Normalized Arabic surah name -> number (plain-text header detection)
local SURAH_AR_NAME_TO_NUM = {}
for i, name in ipairs(SURAH_NAMES_ARABIC) do
    SURAH_AR_NAME_TO_NUM[normalizeArabicName(name)] = i
    -- Multi-word names (e.g. Ali 'Imran): each word is a candidate too --
    -- the id="surah-N" probe decides, so over-matching here is harmless.
    for word in name:gmatch("%S+") do
        local w = normalizeArabicName(word)
        if w ~= "" and not SURAH_AR_NAME_TO_NUM[w] then
            SURAH_AR_NAME_TO_NUM[w] = i
        end
    end
end

-- ---------------------------------------------------------------------------
-- Juz boundary data (juz number -> {surah, ayah})
-- Source: Quran.com API v4 juz data (Hafs, Madinah Mushaf)
-- ---------------------------------------------------------------------------
local JUZ_BOUNDARIES = {
    { 1, 1 },    -- Juz 1:  Al-Fatihah 1
    { 2, 142 },  -- Juz 2:  Al-Baqarah 142
    { 2, 253 },  -- Juz 3:  Al-Baqarah 253
    { 3, 93 },   -- Juz 4:  Ali 'Imran 93
    { 4, 24 },   -- Juz 5:  An-Nisa 24
    { 4, 148 },  -- Juz 6:  An-Nisa 148
    { 5, 82 },   -- Juz 7:  Al-Ma'idah 82
    { 6, 111 },  -- Juz 8:  Al-An'am 111
    { 7, 88 },   -- Juz 9:  Al-A'raf 88
    { 8, 41 },   -- Juz 10: Al-Anfal 41
    { 9, 93 },   -- Juz 11: At-Tawbah 93
    { 11, 6 },   -- Juz 12: Hud 6
    { 12, 53 },  -- Juz 13: Yusuf 53
    { 15, 1 },   -- Juz 14: Al-Hijr 1
    { 17, 1 },   -- Juz 15: Al-Isra 1
    { 18, 75 },  -- Juz 16: Al-Kahf 75
    { 21, 1 },   -- Juz 17: Al-Anbya 1
    { 23, 1 },   -- Juz 18: Al-Mu'minun 1
    { 25, 21 },  -- Juz 19: Al-Furqan 21
    { 27, 56 },  -- Juz 20: An-Naml 56
    { 29, 46 },  -- Juz 21: Al-'Ankabut 46
    { 33, 31 },  -- Juz 22: Al-Ahzab 31
    { 36, 28 },  -- Juz 23: Ya-Sin 28
    { 39, 32 },  -- Juz 24: Az-Zumar 32
    { 41, 47 },  -- Juz 25: Fussilat 47
    { 46, 1 },   -- Juz 26: Al-Ahqaf 1
    { 51, 31 },  -- Juz 27: Adh-Dhariyat 31
    { 58, 1 },   -- Juz 28: Al-Mujadila 1
    { 67, 1 },   -- Juz 29: Al-Mulk 1
    { 78, 1 },   -- Juz 30: An-Naba 1
}

-- Juz Arabic names (traditional names from the first word/phrase)
local JUZ_NAMES_ARABIC = {
    "آلم",              -- 1
    "سيقول",            -- 2
    "تلك الرسل",        -- 3
    "لن تنالوا",        -- 4 (actually "كل الطعام" in some traditions)
    "والمحصنات",        -- 5
    "لا يحب الله",      -- 6
    "وإذا سمعوا",       -- 7
    "ولو أننا",         -- 8
    "قال الملأ",        -- 9
    "واعلموا",          -- 10
    "يعتذرون",          -- 11
    "وما من دابة",      -- 12
    "وما أبرئ",         -- 13
    "ربما",             -- 14 (actually "آلر")
    "سبحان",            -- 15
    "قال ألم",          -- 16
    "اقترب",            -- 17
    "قد أفلح",          -- 18
    "وقال الذين",       -- 19
    "أمن خلق",          -- 20 (actually "فما كان جواب" in some)
    "اتل ما أوحي",     -- 21
    "ومن يقنت",         -- 22
    "وما لي",           -- 23 (actually "وما أنزلنا")
    "فمن أظلم",         -- 24
    "إليه يرد",         -- 25
    "حم",               -- 26
    "قال فما خطبكم",    -- 27
    "قد سمع",           -- 28
    "تبارك",            -- 29
    "عم",               -- 30
}

-- Juz Latin names (transliterated traditional names)
local JUZ_NAMES_LATIN = {
    "Alif Lam Mim",
    "Sayaqul",
    "Tilkar-Rusul",
    "Lan Tanaalu",
    "Wal-Muhsanat",
    "La Yuhibbu-llah",
    "Wa Idha Sami'u",
    "Wa Lau Annana",
    "Qalal-Mala'u",
    "Wa'lamu",
    "Ya'tadhirun",
    "Wa Ma Min Dabbah",
    "Wa Ma Ubri'u",
    "Rubama",
    "Subhanalladhi",
    "Qal Alam",
    "Iqtaraba",
    "Qad Aflaha",
    "Wa Qalal-Ladhina",
    "Amman Khalaqa",
    "Utlu Ma Uhiya",
    "Wa Man Yaqnut",
    "Wa Ma Liya",
    "Faman Adhlamu",
    "Ilaihi Yuraddu",
    "Ha Mim",
    "Qala Fama Khatbukum",
    "Qad Sami'a",
    "Tabaraka",
    "'Amma",
}

-- Juz ordinal Arabic names (الجزء + ordinal number)
-- Used for the "الجزء الأول" display format.
local JUZ_ORDINAL_ARABIC = {
    "الأول",              -- 1
    "الثاني",             -- 2
    "الثالث",             -- 3
    "الرابع",             -- 4
    "الخامس",             -- 5
    "السادس",             -- 6
    "السابع",             -- 7
    "الثامن",             -- 8
    "التاسع",             -- 9
    "العاشر",             -- 10
    "الحادي عشر",         -- 11
    "الثاني عشر",         -- 12
    "الثالث عشر",         -- 13
    "الرابع عشر",         -- 14
    "الخامس عشر",         -- 15
    "السادس عشر",         -- 16
    "السابع عشر",         -- 17
    "الثامن عشر",         -- 18
    "التاسع عشر",         -- 19
    "العشرون",            -- 20
    "الحادي والعشرون",    -- 21
    "الثاني والعشرون",    -- 22
    "الثالث والعشرون",    -- 23
    "الرابع والعشرون",    -- 24
    "الخامس والعشرون",    -- 25
    "السادس والعشرون",    -- 26
    "السابع والعشرون",    -- 27
    "الثامن والعشرون",    -- 28
    "التاسع والعشرون",    -- 29
    "الثلاثون",           -- 30
}

--- Parse a dictionary lookup word to extract surah number and ayah number.
-- Matches "Surah_Name N" (human-readable) or "NNN:NNN" (zero-padded).
-- @return surah_num (integer or nil), ayah_num (integer or nil)
local function parseQuranKey(word)
    if not word then return nil, nil end

    -- Try zero-padded "NNN:NNN"
    local s, a = word:match("^(%d+):(%d+)$")
    if s and a then
        return tonumber(s), tonumber(a)
    end

    -- Try "Surah_Name N" — match last space + digits
    local name, ayah_str = word:match("^(.+)%s+(%d+)$")
    if name and ayah_str then
        local surah_num = SURAH_NAME_TO_NUM[name]
        if surah_num then
            return surah_num, tonumber(ayah_str)
        end
    end

    return nil, nil
end

-- Map Arabic-Indic digits (2-byte UTF-8) to Western digits
local DIGIT_MAP = {
    ["٠"] = "0", ["١"] = "1", ["٢"] = "2", ["٣"] = "3", ["٤"] = "4",
    ["٥"] = "5", ["٦"] = "6", ["٧"] = "7", ["٨"] = "8", ["٩"] = "9",
}

--- Check if a string is a QCF glyph code (Arabic Presentation Forms-A/B).
-- QCF fonts encode each word as a single glyph in the U+FB50–U+FDFF or
-- U+FE70–U+FEFF range.  These are not real Arabic text — they're opaque
-- codepoints that only render correctly with the matching per-page font.
local function isQcfGlyph(s)
    if not s or s == "" then return false end
    -- QCF glyph codes are 1–2 characters in Presentation Forms ranges.
    -- In UTF-8: U+FB50 = EF AD 90, U+FDFF = EF B7 BF, U+FE70 = EF B9 B0, U+FEFF = EF BB BF.
    -- Check first char: byte 1 = 0xEF (239), byte 2 in [0xAD..0xB7] or [0xB9..0xBB].
    local b1, b2 = s:byte(1, 2)
    if b1 == 0xEF and b2 then
        if (b2 >= 0xAD and b2 <= 0xB7) or (b2 >= 0xB9 and b2 <= 0xBB) then
            return true
        end
    end
    return false
end

--- Detect an IndoPak ayah-marker selection: text made only of marks/PUA
-- glyphs (no Arabic letters). Returns the medallion codepoint when one is
-- in U+F500..U+F61D (medallion band; F500 + n - 1), 0 for a marker without
-- a medallion (unnumbered basmala F61E, sajdah/ruku ornaments), or nil when
-- the selection contains real letters (regular word -- do not hijack).
local function markerPuaCodepoint(s)
    if not s or s == "" then return nil end
    local medallion = nil
    local has_pua = false
    local i, n = 1, #s
    while i <= n do
        local b1 = s:byte(i)
        local cp, step
        if b1 < 0x80 then cp, step = b1, 1
        elseif b1 >= 0xF0 then cp, step = 0, 4
        elseif b1 >= 0xE0 then
            local b2, b3 = s:byte(i + 1), s:byte(i + 2)
            if not b3 then return nil end
            cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
            step = 3
        elseif b1 >= 0xC0 then
            local b2 = s:byte(i + 1)
            if not b2 then return nil end
            cp = (b1 - 0xC0) * 64 + (b2 - 0x80)
            step = 2
        else cp, step = 0, 1 end
        if cp >= 0xE000 and cp <= 0xF8FF then
            has_pua = true
            if cp >= 0xF500 and cp <= 0xF61D and not medallion then
                medallion = cp
            end
        elseif (cp >= 0x0621 and cp <= 0x063A) or (cp >= 0x0641 and cp <= 0x064A)
            or (cp >= 0x0671 and cp <= 0x06D3) or (cp >= 0x0750 and cp <= 0x077F) then
            return nil  -- contains an Arabic letter: not a bare marker
        end
        i = i + step
    end
    if not has_pua then return nil end
    return medallion or 0
end

--- Read QCF word info from the element at an XPointer.
-- Uses CREngine's getHTMLFromXPointer with EXTRA_OFFSETS_SELECTORS flag
-- to retrieve the HTML of the block-level parent, then finds the specific
-- <span> containing the selected glyph to extract its attributes.
-- @param document CreDocument handle
-- @param xpointer XPointer of the selected text
-- @param glyph_text The selected QCF glyph string (used to find the right span)
-- @return uthmani_text (string|nil), surah_num (int|nil), ayah_num (int|nil)
--   Regular word: uthmani_text is set, surah/ayah are nil
--   End marker:   uthmani_text is nil, surah/ayah are set
--   Failure:      all nil
local function readQcfWordInfo(document, pos0, pos1)
    if not document or not pos0 or not pos1 then return nil end
    -- from_root_node=true wraps the selected range with its parent elements,
    -- giving us the enclosing <span> with data-uthmani and id attributes.
    -- 0x8000 = WRITENODEEX_EXTRA_OFFSETS_SELECTORS (preserves data-* attrs).
    local html = document:getHTMLFromXPointers(pos0, pos1, 0x8000, true)
    if not html then return nil end

    -- Regular word: has data-uthmani attribute
    local uthmani = html:match('data%-uthmani="([^"]*)"')
    if uthmani then return uthmani, nil, nil end

    -- Ayah-end marker: has id="...ayah-{surah}-{ayah}" (CREngine prefixes the id)
    local surah, ayah = html:match('ayah%-(%d+)%-(%d+)')
    if surah and ayah then return nil, tonumber(surah), tonumber(ayah) end

    return nil
end

--- Check if a string consists only of Arabic-Indic digits.
local function isArabicIndicDigits(s)
    if not s or s == "" then return false end
    for c in s:gmatch(UTF8_CHAR) do
        if not DIGIT_MAP[c] then
            return false
        end
    end
    return true
end

--- Convert Arabic-Indic numeral string to Western integer.
local function arabicIndicToInt(s)
    local western = ""
    for c in s:gmatch(UTF8_CHAR) do
        if DIGIT_MAP[c] then
            western = western .. DIGIT_MAP[c]
        end
    end
    if western == "" then return nil end
    return tonumber(western)
end

--- Normalize QPC-repurposed tanween codepoints to standard Arabic equivalents.
-- QPC uses three codepoints with custom glyphs in its font that render
-- incorrectly in standard Arabic fonts (e.g. KOReader dictionary popup):
--   U+0657 (inverted damma)      → U+064B (fathatan)
--   U+065E (fatha with two dots) → U+064C (dammatan)
--   U+0656 (subscript alef)      → U+064D (kasratan)
local function normalizeQpcTanween(text)
    text = text:gsub("\xD9\x97", "\xD9\x8B")
    text = text:gsub("\xD9\x9E", "\xD9\x8C")
    text = text:gsub("\xD9\x96", "\xD9\x8D")
    return text
end

--- Extract trailing Arabic-Indic digits from a string.
-- In inline layout, the word joiner (U+2060) prevents word boundary detection
-- from splitting Arabic text and the ayah number, so the selected "word" may
-- include preceding Arabic text (e.g., "بِسْمِ٢٥٥"). This extracts the
-- trailing digit sequence.
-- Also handles Western digits (after KOReader's cleanSelection).
-- @return digit string (Arabic-Indic or Western) or nil
local function extractTrailingDigits(s)
    if not s or s == "" then return nil end
    -- First try: purely Arabic-Indic digits (no extraction needed)
    if isArabicIndicDigits(s) then return s end
    -- Extract trailing Arabic-Indic digits
    local chars = {}
    for c in s:gmatch(UTF8_CHAR) do
        table.insert(chars, c)
    end
    local digits = {}
    for i = #chars, 1, -1 do
        if DIGIT_MAP[chars[i]] then
            table.insert(digits, 1, chars[i])
        else
            break
        end
    end
    if #digits > 0 then
        return table.concat(digits)
    end
    -- Try trailing Western digits (KOReader may normalize)
    local western = s:match("(%d+)$")
    if western then return western end
    return nil
end

--- Extract surah number and name from a TOC title string.
-- @param title TOC title string
-- @return surah number (integer) or nil, surah name (string) or nil
local function extractSurahInfo(title)
    if not title or title == "" then return nil, nil end

    -- Bilingual: "78. An-Naba — سورة النبإ"
    local w_num, name = title:match("^(%d+)%.%s*(.-)%s*—")
    if w_num and name then
        return tonumber(w_num), name:match("^%s*(.-)%s*$")
    end
    -- Bilingual without Arabic part
    w_num, name = title:match("^(%d+)%.%s*(.+)")
    if w_num and name then
        return tonumber(w_num), name:match("^%s*(.-)%s*$")
    end

    -- Arabic-only: "٧٨ سورة النبإ"
    local prefix = ""
    for c in title:gmatch(UTF8_CHAR) do
        if DIGIT_MAP[c] then
            prefix = prefix .. c
        else
            break
        end
    end
    if prefix ~= "" then
        return arabicIndicToInt(prefix), nil
    end

    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Text mode viewer (ScrollTextWidget alternative to ScrollHtmlWidget)
-- ---------------------------------------------------------------------------

-- Dictionaries whose formatting relies on MuPDF (tables, structured layout).
-- Everything else (tafsir, word-by-word, surah overview) defaults to text mode.
local HTML_PREFERRED_DICTS = {
    ["Quran Grammar"]        = true,  -- grammar combined
    ["Quran Grammar (Lite)"] = true,  -- grammar lite
}

--- Check whether a dictionary should default to HTML/MuPDF rendering.
-- @param dict_name string StarDict bookname
-- @return boolean true if this dict benefits from HTML rendering
local function isHtmlPreferred(dict_name)
    return dict_name and HTML_PREFERRED_DICTS[dict_name] or false
end

-- PTF markers for inline bold in ScrollTextWidget (via TextBoxWidget).
local PTF_HEADER = TextBoxWidget.PTF_HEADER
local PTF_BOLD_START = TextBoxWidget.PTF_BOLD_START
local PTF_BOLD_END = TextBoxWidget.PTF_BOLD_END

--- Convert HTML definition text to plain text with PTF bold markers.
-- Strips tags, converts <b>/<strong> to PTF bold, preserves structure.
-- @param html string HTML content from StarDict definition
-- @return string plain text with PTF bold markers
local function htmlToText(html)
    if not html or html == "" then return "" end

    -- Remove hidden ref comments used by per-instance word matching
    local text = html:gsub("<!%-%-.-%-%->\n?", "")

    -- Convert <br> and <br/> to newlines
    text = text:gsub("<br%s*/?>", "\n")

    -- Convert block elements to double newlines (paragraph breaks)
    text = text:gsub("</?p[^>]*>", "\n")
    text = text:gsub("</?div[^>]*>", "\n")
    text = text:gsub("</?h%d[^>]*>", "\n")
    text = text:gsub("<hr[^>]*>", "\n")

    -- Convert <b> and <strong> to PTF bold markers
    text = text:gsub("<b[^a-z>]*>", PTF_BOLD_START)
    text = text:gsub("</b>", PTF_BOLD_END)
    text = text:gsub("<strong[^>]*>", PTF_BOLD_START)
    text = text:gsub("</strong>", PTF_BOLD_END)

    -- Strip all remaining HTML tags
    text = text:gsub("<[^>]+>", "")

    -- Decode common HTML entities
    text = text:gsub("&amp;", "&")
    text = text:gsub("&lt;", "<")
    text = text:gsub("&gt;", ">")
    text = text:gsub("&quot;", '"')
    text = text:gsub("&#39;", "'")
    text = text:gsub("&nbsp;", " ")
    text = text:gsub("&#x200[eE];", "\u{200E}") -- LRM
    text = text:gsub("&#x200[fF];", "\u{200F}") -- RLM

    -- Collapse multiple blank lines into at most two newlines
    text = text:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
    -- Trim leading/trailing whitespace
    text = text:gsub("^%s+", ""):gsub("%s+$", "")

    -- Prepend PTF header if we have any bold markers
    if text:find(PTF_BOLD_START, 1, true) then
        text = PTF_HEADER .. text
    end

    return text
end

--- Create a TXT ON/OFF toggle button for Quran popups.
-- Toggles between HTML (MuPDF) and plain-text (TextBoxWidget) rendering
-- by manipulating DQL's own is_html flag and calling update().  DQL's
-- native _instantiateScrollWidget / update flow handles all widget
-- lifecycle — we never create or free widgets ourselves.
-- @param dict_popup DictQuickLookup instance
-- @return table button spec for insertion into button row
local function textModeButton(dict_popup)
    return {
        id = "text_mode",
        text_func = function()
            if dict_popup._quran_text_mode then
                return _("TXT ON")
            else
                return _("TXT OFF")
            end
        end,
        callback = function()
            -- Toggle: set manual override, opposite of current state
            local new_mode = not dict_popup._quran_text_mode
            dict_popup._quran_text_override = new_mode
            -- Restore original HTML values so update() starts clean
            if not new_mode then
                local result = dict_popup.results and dict_popup.results[dict_popup.dict_index]
                if result then
                    dict_popup.is_html = result.is_html
                    dict_popup.definition = result.definition
                end
            end
            dict_popup:update()
            -- Refresh button label
            if dict_popup.button_table then
                local btn = dict_popup.button_table:getButtonById("text_mode")
                if btn then
                    local label = dict_popup._quran_text_mode
                        and _("TXT ON") or _("TXT OFF")
                    btn:setText(label, btn.width)
                end
            end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Monkey-patches (applied once at first plugin init)
-- ---------------------------------------------------------------------------

--- Resize a DictQuickLookup popup after init to use ~65% of available height.
-- Called from the monkey-patched init when _quran_popup flag is set.
-- The default dict popup uses ~35% height. We expand the definition area
-- and update the widget tree so the larger window renders correctly.
local function resizeToMedium(dql)
    local margin_top = Size.margin.default
    local margin_bottom = Size.margin.default
    if dql.ui and dql.ui.view and dql.ui.view.footer_visible then
        margin_bottom = margin_bottom + dql.ui.view.footer:getHeight()
    end
    local actual_avail = Screen:getHeight() - margin_top - margin_bottom

    -- Target: ~65% of available height for the definition area
    local target_def = math.floor(actual_avail * 0.65)
    local nb_lines = Math.round(target_def / dql.definition_line_height)
    local new_def = nb_lines * dql.definition_line_height

    if new_def <= dql.definition_height then
        return -- already at or above target, skip
    end

    local old_def = dql.definition_height
    dql.definition_height = new_def
    dql.height = dql.height + (new_def - old_def)

    -- Recreate scroll widget with new height
    if dql.text_widget and dql.text_widget.free then
        dql.text_widget:free()
    end
    dql:_instantiateScrollWidget()
    dql.definition_widget[1] = dql.text_widget

    -- Update the CenterContainer wrapping definition_widget
    local vg = dql.dict_frame[1] -- VerticalGroup
    if vg then
        for i = 1, #vg do
            if type(vg[i]) == "table" and vg[i][1] == dql.definition_widget then
                vg[i].dimen.h = dql.definition_widget:getSize().h
                break
            end
        end
    end

    -- Recompute region so window centers in actual available space
    dql.region = Geom:new{
        x = 0,
        y = margin_top,
        w = Screen:getWidth(),
        h = actual_avail,
    }
    dql.align = "center"
    dql[1].dimen = dql.region
    dql[1].align = dql.align
end

-- Active plugin instance for use inside monkeypatches. Patches are applied
-- once per session, but a new plugin instance is created for every document,
-- so patches must not close over `self` — they go through this upvalue,
-- refreshed on every Quran:init().
local _active_quran = nil

local function applyMonkeyPatches(quran)
    _active_quran = quran
    if DictQuickLookup._quran_patched then return end
    DictQuickLookup._quran_patched = true

    -- Patch 1: DictQuickLookup.init — resize Quran popups to medium height
    -- and apply content-type-aware text mode via update() (Patch 2).
    local orig_init = DictQuickLookup.init
    DictQuickLookup.init = function(self_dql, ...)
        orig_init(self_dql, ...)
        if self_dql._quran_popup then
            resizeToMedium(self_dql)
            -- Re-run update so Patch 2 auto-determines rendering mode
            self_dql:update()
        end
    end

    -- Patch 2: DictQuickLookup.update — auto-select rendering mode.
    -- Prose dictionaries (tafsir, word-by-word) default to text mode for
    -- better Arabic shaping; structured dictionaries (grammar) stay HTML.
    -- Manual toggle via TXT button sets _quran_text_override, which is
    -- cleared when the dictionary changes so the new dict gets its default.
    local orig_update = DictQuickLookup.update
    DictQuickLookup.update = function(self_dql, ...)
        if self_dql._quran_popup then
            local result = self_dql.results and self_dql.results[self_dql.dict_index]
            if result then
                -- Reset manual override when dictionary changes
                if self_dql._quran_last_dict ~= result.dict then
                    self_dql._quran_text_override = nil
                    self_dql._quran_last_dict = result.dict
                end
                -- Determine mode: manual override wins, else content-type default
                if self_dql._quran_text_override ~= nil then
                    self_dql._quran_text_mode = self_dql._quran_text_override
                else
                    self_dql._quran_text_mode = not isHtmlPreferred(result.dict)
                end
                -- Apply text mode
                if self_dql._quran_text_mode then
                    self_dql.is_html = false
                    self_dql.definition = htmlToText(result.definition or "")
                end
            end
        end
        orig_update(self_dql, ...)
        -- Update TXT button label to reflect the (possibly auto-changed) mode
        if self_dql._quran_popup and self_dql.button_table then
            local btn = self_dql.button_table:getButtonById("text_mode")
            if btn then
                local label = self_dql._quran_text_mode
                    and _("TXT ON") or _("TXT OFF")
                btn:setText(label, btn.width)
            end
        end
    end

    -- Patch 3: ReaderDictionary.showDict — per-instance word filtering and
    -- in-place update for Quran nav. Filtering happens here (before the popup
    -- is built) so it works on every KOReader version — the DictButtonsReady
    -- event this used to rely on was removed upstream in May 2026 (#15184).
    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    local orig_showDict = ReaderDictionary.showDict
    ReaderDictionary.showDict = function(self_dict, word, results, boxes, link, dict_close_callback)
        -- Ayah long-press divert (D-R2-4a): the diverted surface is
        -- already opening — swallow this lookup's popup (one-shot).
        if DictQuickLookup._quran_suppress_next then
            DictQuickLookup._quran_suppress_next = nil
            self_dict:dismissLookupInfo()
            return
        end
        if _active_quran and _active_quran._is_quran_book and results then
            results = _active_quran:_filterWordResultsByPosition(results)
            -- One-shot dictionary filter (quick panel "open in X" buttons):
            -- keep only the requested dict's result; if it has no entry
            -- for this ayah (e.g. sparse asbab), fall back to all results
            -- with a notification instead of a dead popup.
            local want_dict = _active_quran._dict_filter_name
            if want_dict then
                _active_quran._dict_filter_name = nil
                local kept = {}
                for _, r in ipairs(results) do
                    if r.dict == want_dict then table.insert(kept, r) end
                end
                if #kept > 0 then
                    results = kept
                else
                    local Notification = require("ui/widget/notification")
                    UIManager:show(Notification:new{
                        text = _("No entry in ") .. want_dict .. _(" for this ayah"),
                    })
                end
            end
            -- Warsh gate (W2): dicts are Hafs-keyed; warn in surahs whose
            -- numbering differs instead of silently serving wrong-ayah text.
            local ws = _active_quran._last_ayah_surah
            if ws and _active_quran._riwayah == "warsh"
                and not _active_quran:_warshMap()
                and SURAH_AYAH_COUNTS[ws] ~= SURAH_AYAH_COUNTS_WARSH[ws] then
                for _, r in ipairs(results) do
                    if r.definition then
                        if r.is_html then
                            r.definition = WARSH_NOTICE_HTML .. r.definition
                        else
                            r.definition = WARSH_NOTICE_TEXT .. r.definition
                        end
                    end
                end
            end
        end
        local target = DictQuickLookup._quran_update_popup
        if target and results and results[1] then
            DictQuickLookup._quran_update_popup = nil
            -- Update existing popup in-place
            target.results = results
            target.word = word
            -- Stay in the same dictionary the user was viewing
            local target_index = 1
            local dict_name = target._quran_dict_name
            if dict_name then
                for i, r in ipairs(results) do
                    if r.dict == dict_name then
                        target_index = i
                        break
                    end
                end
            end
            -- changeDictionary() → update() → Patch 2 handles text mode
            target:changeDictionary(target_index)
            self_dict:dismissLookupInfo()
            return
        end
        return orig_showDict(self_dict, word, results, boxes, link, dict_close_callback)
    end

    -- Patch 4: ReaderDictionary.onLookupWord — normalize QPC tanween BEFORE
    -- the word enters the dictionary lookup pipeline.  This makes the normalized
    -- word the primary lookup term (exact match, correct popup header rendering)
    -- instead of an appended candidate that loses to the original's fuzzy match.
    -- (The ayah long-press divert does NOT live here: at this point the
    -- press may not be resolved yet — it hooks onWordLookup instead, and
    -- the popup is suppressed at showDict time via _quran_suppress_next.)
    local orig_onLookupWord = ReaderDictionary.onLookupWord
    ReaderDictionary.onLookupWord = function(self_dict, word, ...)
        if word and _active_quran and _active_quran._is_quran_book then
            word = normalizeQpcTanween(word)
        end
        return orig_onLookupWord(self_dict, word, ...)
    end

    -- Patch 5: DictQuickLookup.buildButtonLayout — KOReader ≥ 2026.05.
    -- Upstream #15184 (ed695fe34) removed the DictButtonsReady event and
    -- replaced it with a button-pool layout system. On those versions we
    -- replace the layout wholesale for Quran popups; non-Quran popups fall
    -- through to the stock layout. Older KOReader keeps using the
    -- Quran:onDictButtonsReady event handler instead — buildButtonLayout
    -- doesn't exist there, so this patch is skipped.
    if DictQuickLookup.buildButtonLayout then
        local orig_buildButtonLayout = DictQuickLookup.buildButtonLayout
        DictQuickLookup.buildButtonLayout = function(self_dql, ...)
            if _active_quran then
                local rows = {}
                if _active_quran:_setupQuranPopupButtons(self_dql, rows) then
                    return rows
                end
            end
            return orig_buildButtonLayout(self_dql, ...)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Plugin methods
-- ---------------------------------------------------------------------------

function Quran:init()
    self._stashed_surah = nil
    self._stashed_surah_name = nil
    self._stashed_surah_glyph = nil
    self._stashed_qcf_ayah = nil
    self._last_ayah_surah = nil
    self._last_ayah_num = nil
    self._last_overview_surah = nil
    self._cached_juz = nil       -- cached juz number for current page
    self._cached_boundary = nil  -- cached boundary flag for current page
    self._cached_pageno = nil    -- page number the juz cache is valid for
    self._cached_surah = nil     -- cached surah number for current page
    self._cached_surah_pg = nil  -- page number the surah cache is valid for
    self._juz_toc_pages = nil    -- juz TOC entry -> page mapping
    self._hizb_pages = nil       -- hizb boundary -> page mapping
    self._is_quran_book = nil    -- true if current book is a quran-ebook EPUB
    self._riwayah = "hafs"       -- set by _detectQuranBook ("hafs"|"warsh")
    self._warsh_map = nil        -- lazy: warshalign.lua (false = load failed)
    self._rename_map = nil       -- lazy: renamemap.lua inverse (false = load failed)
    self._actions_mod = nil      -- lazy: quran_actions.lua (false = load failed)
    self._browser_mod = nil      -- lazy: quran_browser.lua (false = load failed)
    self._assets_mod = nil       -- lazy: quran_assets.lua (loaded by the browser)
    self._roots_mod = nil        -- lazy: quran_roots.lua (root explorer)
    self._qul_mod = nil          -- lazy: quran_qul.lua (themes/topics/similar)
    self._text_mod = nil         -- lazy: quran_text.lua (text package access)
    self._reader_mod = nil       -- lazy: quran_reader.lua (shared Reader)
    self._text_hint_shown = nil  -- once-per-session install hint (Reader)
    self._frag_offset = nil      -- spine offset cache (actions.resolveAnchorPage)
    self._anchor_conv = nil      -- per-book anchor convention (actions.anchorConvention)
    self._dict_filter_name = nil -- one-shot dict filter (quick panel direct-open)
    self._status_bar_registered = false
    LanguageSupport:registerPlugin(self)
    applyMonkeyPatches(self)

    -- Persistent settings
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/quran.lua")

    -- Juz status bar content function (closure captures self)
    self.additional_footer_content_func = function()
        if not self._is_quran_book then return end
        if not self.settings:nilOrTrue("show_juz_in_footer") then return end
        return self:_getJuzFooterString()
    end


    self.ui.menu:registerToMainMenu(self)

    -- v1.12 hub: gesture-assignable actions + quick panel (quran_actions.lua)
    local actions = self:_actionsModule()
    if actions then
        actions.registerDispatcherActions()
    end

    -- v1.12 hub: word-popup "Root explorer" button. KOReader ≥ 2026.05 has
    -- an official registration API; older versions take the
    -- DictButtonsReady append path in _setupQuranPopupButtons instead.
    if self.ui.dictionary and self.ui.dictionary.addToDictButtons then
        self:_registerRootDictButton()
    end
end

--- Register the word-popup Root-explorer button (KOReader ≥ 2026.05).
-- conditional + show_func: the button only appears on Quran books when a
-- displayed dict entry carries a parseable "root: ‎X-Y-Z" line.
function Quran:_registerRootDictButton()
    local quran = self
    local function popupRoot(popup)
        local roots = quran:_rootsModule()
        if not roots then return end
        local cur = popup.results and popup.dict_index
            and popup.results[popup.dict_index]
        local root = cur and roots.parseRootFromDefinition(cur.definition)
        if root then return root end
        for _idx, r in ipairs(popup.results or {}) do
            root = roots.parseRootFromDefinition(r.definition)
            if root then return root end
        end
    end
    self.ui.dictionary:addToDictButtons{
        id = "quran_root_explorer",
        text = _("Root explorer"),
        conditional = true,
        show_func = function(popup)
            -- Our custom ayah/overview popups replace the layout wholesale
            -- and never reach the button pool; this only sees word popups.
            return quran._is_quran_book == true and popupRoot(popup) ~= nil
        end,
        callback = function(popup)
            local root = popupRoot(popup)
            if not root then return end
            popup:onClose()
            quran:openRootExplorer(root)
        end,
    }
end

--- Lazy-load the actions module (dispatcher actions + quick panel).
function Quran:_actionsModule()
    if self._actions_mod == nil then
        local ok, mod = pcall(dofile, (self.path or "") .. "/quran_actions.lua")
        self._actions_mod = (ok and type(mod) == "table") and mod or false
        if not self._actions_mod then
            logger.info("quran.koplugin: quran_actions.lua unavailable:", tostring(mod))
        end
    end
    return self._actions_mod or nil
end

--- Lazy-load the root explorer module (Lane extract queries + screens).
function Quran:_rootsModule()
    if self._roots_mod == nil then
        local ok, mod = pcall(dofile, (self.path or "") .. "/quran_roots.lua")
        self._roots_mod = (ok and type(mod) == "table") and mod or false
        if not self._roots_mod then
            logger.info("quran.koplugin: quran_roots.lua unavailable:", tostring(mod))
        end
    end
    return self._roots_mod or nil
end

--- Lazy-load the Quran text package module (ayah text + translations).
function Quran:_textModule()
    if self._text_mod == nil then
        local ok, mod = pcall(dofile, (self.path or "") .. "/quran_text.lua")
        self._text_mod = (ok and type(mod) == "table") and mod or false
        if not self._text_mod then
            logger.info("quran.koplugin: quran_text.lua unavailable:", tostring(mod))
        end
    end
    return self._text_mod or nil
end

--- Lazy-load the shared Reader module (full-screen reading surface).
function Quran:_readerModule()
    if self._reader_mod == nil then
        local ok, mod = pcall(dofile, (self.path or "") .. "/quran_reader.lua")
        self._reader_mod = (ok and type(mod) == "table") and mod or false
        if not self._reader_mod then
            logger.info("quran.koplugin: quran_reader.lua unavailable:", tostring(mod))
        else
            self._reader_mod.paging_mode =
                self.settings:readSetting("reader_paging_mode", "auto")
            -- setPagingMode persistence (the title-bar quick menus call
            -- it from the reader module — plugin settings live here)
            local settings = self.settings
            self._reader_mod._save_paging = function(value)
                settings:saveSetting("reader_paging_mode", value)
                settings:flush()
            end
        end
    end
    return self._reader_mod or nil
end

--- Lazy-load the qul connections module (themes/topics/mutashabihat/
-- similar — the browser reaches it via its own loader; this one serves
-- the panel and the marking overlay).
function Quran:_qulModule()
    if self._qul_mod_main == nil then
        local ok, mod = pcall(dofile, (self.path or "") .. "/quran_qul.lua")
        self._qul_mod_main = (ok and type(mod) == "table") and mod or false
        if not self._qul_mod_main then
            logger.info("quran.koplugin: quran_qul.lua unavailable:", tostring(mod))
        end
    end
    return self._qul_mod_main or nil
end

--- Lazy-load the in-book marking overlay module (design D-R2-5).
function Quran:_marksModule()
    if self._marks_mod == nil then
        local ok, mod = pcall(dofile, (self.path or "") .. "/quran_marks.lua")
        self._marks_mod = (ok and type(mod) == "table") and mod or false
        if not self._marks_mod then
            logger.info("quran.koplugin: quran_marks.lua unavailable:", tostring(mod))
        end
    end
    return self._marks_mod or nil
end

--- Open the browser landed on a root's headword screen (word-popup path).
function Quran:openRootExplorer(root)
    local actions = self:_actionsModule()
    if not (actions and actions.showBrowser) then return end
    actions.showBrowser(self, function(browser)
        local roots = browser:rootsModule()
        if roots then
            roots.showRoot(browser, root)
        end
    end)
end

--- Open the browser landed on the unified ayah page for S:A (Hafs) —
-- the bridge from the quick surfaces (ayah popup, Reader) into the full
-- study browser. Callers must NOT already have a browser beneath
-- (design D9: one browser window; the UAP's own screens never use this).
function Quran:openBrowserAtAyah(surah, ayah)
    local actions = self:_actionsModule()
    if not (actions and actions.showBrowser) then return end
    actions.showBrowser(self, function(browser)
        if browser.showAyahPage then
            browser:showAyahPage(surah, ayah)
        end
    end)
end

--- Detect whether the current book is a quran-ebook EPUB.
-- Checks dc:subject (exposed as keywords by CRe) for "Quran" and
-- dc:publisher for "quran-ebook".  This prevents the plugin from
-- injecting juz/surah status into unrelated books.
function Quran:_detectQuranBook()
    -- Check doc_props (available after document load)
    local props = self.ui.doc_props
    if props then
        local kw = props.keywords or ""
        local desc = props.description or ""
        -- dc:subject → keywords in CRe; dc:description → description
        -- Our EPUBs set dc:subject to "Quran"
        if kw:find("Quran") or desc:find("Quran") then
            -- Riwayah: the builder stamps dc:description with
            -- "Riwayat Warsh 'an Nafi'"; the Arabic title carries the name too
            local title = props.title or ""
            if desc:find("Warsh") or title:find("\217\136\216\177\216\180") then
                self._riwayah = "warsh"
            else
                self._riwayah = "hafs"
            end
            logger.dbg("quran.koplugin: detected Quran book via metadata, riwayah:", self._riwayah)
            return true
        end
    end
    -- Fallback: check if the TOC has juz entries (unique to our EPUBs)
    local juz_pages = self:_getJuzTocPages()
    if juz_pages then
        logger.dbg("quran.koplugin: detected Quran book via juz TOC entries")
        return true
    end
    logger.dbg("quran.koplugin: not a Quran book")
    return false
end

--- Warsh->Hafs alignment map (generated warshalign.lua; divergent surahs
-- only). Returns the table, or nil when the file is missing (old install)
-- -- callers then fall back to warsh-passthrough + the Patch-3 notice.
function Quran:_warshMap()
    if self._warsh_map == nil then
        local ok, map = pcall(dofile, (self.path or "") .. "/warshalign.lua")
        self._warsh_map = (ok and type(map) == "table") and map or false
        if not self._warsh_map then
            logger.info("quran.koplugin: warshalign.lua unavailable -- Warsh dict lookups fall back to passthrough + notice")
        end
    end
    return self._warsh_map or nil
end

--- Map a book ayah number to the Hafs number that keys the dictionaries.
-- Identity for Hafs books and for non-divergent Warsh surahs.
function Quran:_warshToHafs(surah, ayah)
    if self._riwayah ~= "warsh" then return ayah end
    local map = self:_warshMap()
    local row = map and map[surah]
    return row and row[ayah] or ayah
end

--- Inverse direction: the book (Warsh) ayah whose span covers a Hafs
-- ayah — needed when Hafs-numbered reference data (HIZB_BOUNDARIES) must
-- resolve against the book's Warsh-numbered anchors. The alignment rows
-- are monotonic non-decreasing (row[w] = first Hafs ayah covered by
-- Warsh ayah w), so the covering ayah is the LAST w with row[w] <= ayah
-- (an exact-match search would miss Hafs ayahs absorbed mid-merge).
-- Identity for Hafs books and non-divergent surahs.
function Quran:_hafsToWarsh(surah, ayah)
    if self._riwayah ~= "warsh" then return ayah end
    local map = self:_warshMap()
    local row = map and map[surah]
    if not row then return ayah end
    local w = 1
    for i = 1, #row do
        if row[i] <= ayah then w = i else break end
    end
    return w
end

--- Jump-direction variant: the FIRST book (Warsh) ayah covering a Hafs
-- ayah — "go to the START of Hafs ayah H". _hafsToWarsh returns the LAST
-- covering ayah, which on split ayahs (one Hafs ayah spanning several
-- Warsh ayahs: row[w] == row[w+1]) would land one sub-ayah late.
-- Identity for Hafs books and non-divergent surahs.
function Quran:_hafsToWarshStart(surah, ayah)
    if self._riwayah ~= "warsh" then return ayah end
    local map = self:_warshMap()
    local row = map and map[surah]
    if not row then return ayah end
    local w = self:_hafsToWarsh(surah, ayah)
    while w > 1 and row[w] == ayah and row[w - 1] == ayah do
        w = w - 1
    end
    return w
end

-- ---------------------------------------------------------------------------
-- Sidecar migration (decision N1): the rename sweep changes every EPUB
-- filename, and KOReader keys .sdr reading data (highlights, progress) to
-- the filename. renamemap.lua (generated from the release rename map)
-- lets the plugin move/copy sidecars to the new names using KOReader's
-- own DocSettings.updateLocation (which also handles custom covers and
-- the hash-metadata mode). Old KOReader without updateLocation -> the
-- feature quietly disables itself; migration instructions in the release
-- notes remain the fallback.
-- ---------------------------------------------------------------------------

--- Lazy inverse rename map: new filename stem -> old filename stem.
-- (Inverse because the trigger is a NEW-named book whose OLD sidecar we
-- go looking for.) nil when renamemap.lua is missing (old install).
function Quran:_renameMap()
    if self._rename_map == nil then
        local ok, map = pcall(dofile, (self.path or "") .. "/renamemap.lua")
        if ok and type(map) == "table" then
            local inv = {}
            for old, new in pairs(map) do inv[new] = old end
            self._rename_map = inv
        else
            self._rename_map = false
            logger.info("quran.koplugin: renamemap.lua unavailable -- sidecar migration disabled")
        end
    end
    return self._rename_map or nil
end

--- Migrate sidecars for renamed books in one directory.
-- For every new-named .epub whose old-named sidecar exists and whose own
-- sidecar does NOT (strict guard: never overwrite reading data), move the
-- old sidecar over — or copy it when the old .epub is still present (its
-- data must keep working). skip_path excludes the currently-open book
-- (its close-flush would clobber a restore; the in-reader flow handles it).
-- Returns migrated, found.
function Quran:_migrateSidecarsInDir(dir, skip_path)
    local inv = self:_renameMap()
    if not inv then return 0, 0 end
    local DocSettings = require("docsettings")
    if not DocSettings.updateLocation then return 0, 0 end
    local lfs = require("libs/libkoreader-lfs")
    local migrated, found = 0, 0
    for f in lfs.dir(dir) do
        local stem = f:match("^(.+)%.epub$")
        local old_stem = stem and inv[stem]
        if old_stem then
            local new_path = dir .. "/" .. f
            local old_path = dir .. "/" .. old_stem .. ".epub"
            if new_path ~= skip_path
                and DocSettings:hasSidecarFile(old_path)
                and not DocSettings:hasSidecarFile(new_path) then
                found = found + 1
                local keep_old = lfs.attributes(old_path, "mode") == "file"
                local ok = pcall(DocSettings.updateLocation,
                                 old_path, new_path, keep_old)
                if ok then
                    migrated = migrated + 1
                    logger.info("quran.koplugin: sidecar migrated:",
                                old_stem, "->", stem,
                                keep_old and "(copied)" or "(moved)")
                end
            end
        end
    end
    return migrated, found
end

--- On opening a renamed book with no reading data of its own but an
-- old-named sidecar next to it: offer restore. Restoring the OPEN book
-- in place would be clobbered by the close-flush, so the flow is
-- confirm -> close -> updateLocation -> reopen.
function Quran:_checkOldSidecar()
    local inv = self:_renameMap()
    if not inv then return end
    local DocSettings = require("docsettings")
    if not DocSettings.updateLocation then return end
    local path = self.ui.document and self.ui.document.file
    if not path then return end
    local dir, stem = path:match("^(.*)/([^/]+)%.epub$")
    local old_stem = stem and inv[stem]
    if not old_stem then return end
    local old_path = dir .. "/" .. old_stem .. ".epub"
    if DocSettings:hasSidecarFile(path)
        or not DocSettings:hasSidecarFile(old_path) then
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    local keep_old = require("libs/libkoreader-lfs").attributes(old_path, "mode") == "file"
    UIManager:show(ConfirmBox:new{
        text = _("Reading data (highlights, progress) from this book's previous filename was found.\n\nRestore it? The book will reopen."),
        ok_text = _("Restore"),
        cancel_text = _("Not now"),
        ok_callback = function()
            local ReaderUI = require("apps/reader/readerui")
            local ok = pcall(function() self.ui:onClose() end)
            UIManager:nextTick(function()
                local ok2 = pcall(DocSettings.updateLocation,
                                  old_path, path, keep_old)
                logger.info("quran.koplugin: open-book sidecar restore:",
                            ok and ok2 and "ok" or "FAILED")
                pcall(function() ReaderUI:showReader(path) end)
            end)
        end,
    })
end

--- Ayah-count table for dict-popup navigation.
-- With the alignment map, Warsh lookups convert to Hafs numbers at entry
-- and navigate in HAFS space (reaches merged ayahs' entries); only the
-- no-map fallback navigates in the book's Warsh numbering.
function Quran:_ayahCounts()
    if self._riwayah == "warsh" and not self:_warshMap() then
        return SURAH_AYAH_COUNTS_WARSH
    end
    return SURAH_AYAH_COUNTS
end

--- Book-space ayah count (anchor numbering): Warsh books carry Warsh
-- numbers regardless of whether the Hafs remap table is available
-- (contrast _ayahCounts, which is Hafs-space for popup NAVIGATION when
-- the remap is present).
function Quran:bookAyahCount(surah)
    if self._riwayah == "warsh" then
        return SURAH_AYAH_COUNTS_WARSH[surah]
    end
    return SURAH_AYAH_COUNTS[surah]
end

--- Latin surah name (for quick-panel display and lookups).
function Quran:surahName(surah)
    return SURAH_NAMES[surah]
end

--- Arabic surah name (browser display).
function Quran:surahNameArabic(surah)
    return SURAH_NAMES_ARABIC[surah]
end

--- Juz boundary (Hafs-numbered): returns surah, ayah of juz j's start.
function Quran:juzBoundary(j)
    local b = JUZ_BOUNDARIES[j]
    if not b then return nil end
    return b[1], b[2]
end

--- Register status bar content after document is ready.
-- Deferred from init() because ui.view and ui.crelistener may not
-- be available yet during plugin initialization.
function Quran:onReaderReady()
    if self._status_bar_registered then return end
    self._status_bar_registered = true

    self._is_quran_book = self:_detectQuranBook()

    logger.dbg("quran.koplugin: onReaderReady — view:", self.ui.view and "yes" or "nil",
                "crelistener:", self.ui.crelistener and "yes" or "nil",
                "quran_book:", self._is_quran_book and "yes" or "no")

    if self._is_quran_book and self.settings:nilOrTrue("show_juz_in_footer") then
        self:_addFooterContent()
    end
    -- Header overlay (pure Lua, replaces CREngine alt status bar approach)
    if self._is_quran_book then
        self:_setupHeaderOverlay()
        self._header_overlay_enabled = self.settings:isTrue("show_header_overlay")
        if self._header_overlay_enabled then
            self:_applyHeaderMargin()
        end
        -- Renamed book with orphaned old-name reading data? Offer restore.
        self:_checkOldSidecar()
    end
end


function Quran:supportsLanguage(language_code)
    if not self.settings:nilOrTrue("grammar_lookup") then return false end
    return language_code == "ar" or language_code == "ara"
end

--- Find surah number and name for a given position by searching the TOC.
-- DOM-ORDER comparison (compareXPointers of the TOC entry's own
-- xpointer vs the press position), NOT page numbers: beyond CREngine's
-- lazy-pagination frontier, getPageFromXPointer and TOC entry pages
-- CLAMP to the frontier page, so a page-based `entry.page <= pageno`
-- scan credits LATER surahs — owner repro 2026-07-16: marker presses
-- in surah 80 resolved surah 83/84, the popup keyed "Al-Inshiqaq 31"
-- (doesn't exist — 25 ayahs) and fuzzy-matched to ayah 1. Same clamp
-- class as the fixed panel detection (quran_actions findAyahForPage).
-- Page numbers remain the PER-ENTRY fallback when an xpointer
-- comparison isn't possible (page-only TOC entries, engines without
-- compareXPointers).
function Quran:_findSurahForPosition(pos)
    local toc = self.ui.toc
    if not toc then return nil, nil end

    toc:fillToc()
    local toc_list = toc.toc
    if not toc_list or #toc_list == 0 then return nil, nil end

    local doc = self.ui.document
    if not doc then return nil, nil end

    local pageno  -- resolved lazily, only if an entry needs the fallback
    local best_surah = nil
    local best_name = nil
    for _, entry in ipairs(toc_list) do
        local at_or_before  -- entry starts at/before the pressed position
        if entry.xpointer and doc.compareXPointers then
            -- compareXPointers(a, b): 1 = b after a, 0 = same, -1 = b
            -- before a, nil = invalid xpointer (then fall through)
            local ok, cmp = pcall(doc.compareXPointers, doc,
                entry.xpointer, pos)
            if ok and cmp then at_or_before = cmp >= 0 end
        end
        if at_or_before == nil then
            -- orig_page: the pre-validateAndFixToc value (see
            -- _findSurahForPage — the fixer may corrupt surah pages)
            local page = entry.orig_page or entry.page
            if page then
                if pageno == nil then
                    pageno = doc:getPageFromXPointer(pos) or false
                end
                at_or_before = pageno and page <= pageno
            end
        end
        if at_or_before and entry.title then
            local title = toc:cleanUpTocTitle(entry.title)
            local surah_num, surah_name = extractSurahInfo(title)
            if surah_num then
                best_surah = surah_num
                best_name = surah_name
            end
        end
    end

    if best_surah then
        logger.dbg("quran.koplugin: pos -> surah", best_surah, best_name)
    end
    return best_surah, best_name
end

--- Called during word selection (long-press).
function Quran:onWordSelection(args)
    self._stashed_surah = nil
    self._stashed_surah_name = nil
    self._stashed_surah_glyph = nil
    self._stashed_qcf_uthmani = nil
    self._stashed_qcf_ayah = nil
    -- Clear nav state from previous Quran popup so it doesn't leak
    -- into subsequent non-Quran lookups (_setupQuranPopupButtons would
    -- otherwise patch a normal word popup's buttons away).
    self._last_ayah_surah = nil
    self._last_ayah_num = nil
    self._last_overview_surah = nil

    -- Stash raw XPointers for per-instance dictionary matching
    -- (no CREngine calls here — detection deferred to the showDict filter)
    self._stashed_word_pos0 = args.pos0
    self._stashed_word_pos1 = args.pos1

    local text = args.text
    logger.dbg("quran.koplugin: onWordSelection text='" .. (text or "nil") .. "'")

    -- Detect surah glyph long-press: trigger text is "surahNNNsurah-icon" (e.g. "surah002surah-icon").
    -- Also matches legacy "surahNNNx" (V2) and bare "surahNNN" formats.
    -- Returns the surah name as lookup candidate for surah overview dictionary.
    if text then
        local surah_num_str = text:match("^surah(%d+)")
        if surah_num_str then
            local surah_num = tonumber(surah_num_str)
            if surah_num and surah_num >= 1 and surah_num <= 114 then
                local name = SURAH_NAMES[surah_num]
                logger.dbg("quran.koplugin: surah glyph detected, surah", surah_num, name)
                self._stashed_surah_glyph = surah_num
                return nil
            end
        end
    end

    -- Plain-text surah header (IndoPak now, Warsh's styled headers later):
    -- the selected word matches a surah name AND the selection sits inside
    -- the header cell (id="surah-N" in all templates). The id probe is the
    -- decider -- body-text occurrences of surah names (some, like Ya-Sin or
    -- Sad, are ordinary words too) fail it and fall through to word lookup.
    if text and self._is_quran_book then
        local norm = normalizeArabicName(text)
        -- pressing the standalone "surat" word of the header counts too
        if SURAH_AR_NAME_TO_NUM[norm] or norm == "\216\179\217\136\216\177\216\169" then
            local ok, html = pcall(function()
                return self.ui.document:getHTMLFromXPointers(args.pos0, args.pos1, 0x8000, true)
            end)
            -- CREngine prefixes id attributes in serialized HTML (same
            -- reason readQcfWordInfo matches 'ayah-S-A' without the id=
            -- anchor), so match the attribute value tail only.
            local sid = ok and html and html:match('surah%-(%d+)"')
            local surah_num = sid and tonumber(sid)
            if surah_num and surah_num >= 1 and surah_num <= 114 then
                logger.info("quran.koplugin: plain header detected, surah", surah_num)
                self._stashed_surah_glyph = surah_num
                return nil
            end
            logger.info("quran.koplugin: header name matched but no surah id;",
                        "html head:", html and html:sub(1, 120) or tostring(html))
        end
    end

    -- QCF glyph: the selected text is an opaque Presentation Forms codepoint.
    -- Read the real Arabic text (word) or ayah info (end marker) from span attrs.
    if isQcfGlyph(text) then
        local uthmani, surah, ayah = readQcfWordInfo(self.ui.document, args.pos0, args.pos1)
        if uthmani then
            logger.dbg("quran.koplugin: QCF word → data-uthmani='" .. uthmani .. "'")
            self._stashed_qcf_uthmani = uthmani
        elseif surah and ayah then
            logger.dbg("quran.koplugin: QCF end marker → surah=" .. surah .. " ayah=" .. ayah)
            self._stashed_surah = surah
            self._stashed_surah_name = SURAH_NAMES[surah]
            self._stashed_qcf_ayah = ayah
        else
            logger.dbg("quran.koplugin: QCF glyph but no word info found")
        end
        return nil
    end

    -- IndoPak ayah marker: a bare marks/PUA selection (medallion band
    -- U+F500..U+F61D = ayah F500+n-1; PUA waqf/ornaments live at F61E+ and
    -- also appear mid-verse attached to words -- markerPuaCodepoint returns
    -- nil for those since letters are present). The marker element carries
    -- id="ayah-S-A" (anchor contract), so the xpointer route is exact and
    -- immune to the known medallion deviations (al-Fatihah off-by-one,
    -- ornament-after-medallion on sajdah ayahs); codepoint math is fallback.
    local marker_cp = markerPuaCodepoint(text)
    if marker_cp then
        local m_surah, m_ayah = self:_detectAyahFromXPointer(args.pos0, args.pos1)
        if not m_surah and marker_cp >= 0xF500 and marker_cp <= 0xF61D then
            m_surah = self:_findSurahForPosition(args.pos0)
            if m_surah then m_ayah = marker_cp - 0xF500 + 1 end
        end
        if m_surah and m_ayah then
            logger.info("quran.koplugin: IndoPak marker -> ayah", m_surah, m_ayah)
            self._stashed_surah = m_surah
            self._stashed_surah_name = SURAH_NAMES[m_surah]
            self._stashed_qcf_ayah = m_ayah
        end
        return nil
    end

    -- In inline layout, word joiner (U+2060) may cause the selection to include
    -- preceding Arabic text along with the ayah digits. Extract trailing digits.
    local digit_str = extractTrailingDigits(text)
    if not digit_str then
        logger.dbg("quran.koplugin: no trailing digits found, skipping")
        return nil
    end

    logger.dbg("quran.koplugin: extracted digits='" .. digit_str .. "'")

    local surah_num, surah_name = self:_findSurahForPosition(args.pos0)
    if surah_num then
        logger.dbg("quran.koplugin: ayah " .. digit_str .. " in surah " .. surah_num .. " " .. (surah_name or "(no name)"))
        self._stashed_surah = surah_num
        self._stashed_surah_name = surah_name
    else
        logger.dbg("quran.koplugin: could not find surah for ayah " .. digit_str)
    end

    return nil
end

--- Called during dictionary lookup.
function Quran:onWordLookup(args)
    local text = args.text
    logger.dbg("quran.koplugin: onWordLookup text='" .. (text or "nil") .. "'")

    -- QCF glyph lookup: substitute real Arabic text from data-uthmani attribute
    local qcf_uthmani = self._stashed_qcf_uthmani
    self._stashed_qcf_uthmani = nil
    if qcf_uthmani then
        logger.dbg("quran.koplugin: QCF word lookup:", qcf_uthmani)
        return { qcf_uthmani }
    end

    -- Surah glyph lookup: return surah name as candidate for overview dictionary
    local surah_glyph = self._stashed_surah_glyph
    self._stashed_surah_glyph = nil
    if surah_glyph then
        local name = SURAH_NAMES[surah_glyph]
        if name then
            logger.dbg("quran.koplugin: surah overview lookup:", name)
            self._last_overview_surah = surah_glyph
            DictQuickLookup._quran_next_lookup = true
            return { name }
        end
        return nil
    end

    local surah = self._stashed_surah
    local surah_name = self._stashed_surah_name
    local qcf_ayah = self._stashed_qcf_ayah
    self._stashed_surah = nil
    self._stashed_surah_name = nil
    self._stashed_qcf_ayah = nil

    if not surah then
        logger.dbg("quran.koplugin: no stashed surah, skipping")
        return nil
    end

    -- QCF ayah-end markers: ayah number already extracted from id attribute
    local ayah = qcf_ayah
    if not ayah then
        -- Extract trailing digits (handles inline layout where Arabic text
        -- is joined to the ayah number, and KOReader digit normalization)
        local digit_str = extractTrailingDigits(text)
        if not digit_str then
            logger.dbg("quran.koplugin: no trailing digits in lookup text, skipping")
            return nil
        end

        if isArabicIndicDigits(digit_str) then
            ayah = arabicIndicToInt(digit_str)
        else
            ayah = tonumber(digit_str)
        end
    end
    if not ayah then return nil end

    -- Warsh books: anchors/markers carry Warsh numbers; dictionaries are
    -- Hafs-keyed. Convert once here; popup navigation then stays in Hafs
    -- space (see _ayahCounts).
    ayah = self:_warshToHafs(surah, ayah)

    logger.dbg("quran.koplugin: lookup surah=" .. surah .. " ayah=" .. ayah)

    -- D-R2-4a: configurable long-press action, diverted HERE — after
    -- the popup path's own surah/ayah resolution, so both can never
    -- disagree. The lookup pipeline still runs (one exact candidate);
    -- Patch 3 swallows its showDict via the one-shot suppress flag, so
    -- no popup flashes under the diverted surface.
    if self:_divertAyahAction(surah, ayah) then
        DictQuickLookup._quran_suppress_next = true
        local dname = surah_name or SURAH_NAMES[surah]
        logger.dbg("quran.koplugin: lookup diverted (ayah long-press action)")
        return dname and { dname .. " " .. ayah } or nil
    end

    local candidates = {}
    local name = surah_name or SURAH_NAMES[surah]
    if name then
        table.insert(candidates, name .. " " .. ayah)
    end
    table.insert(candidates, string.format("%03d:%03d", surah, ayah))

    -- Stash for _setupQuranPopupButtons
    self._last_ayah_surah = surah
    self._last_ayah_num = ayah

    -- Flag next DictQuickLookup for medium-height Quran window
    DictQuickLookup._quran_next_lookup = true

    logger.dbg("quran.koplugin: lookup candidates:", candidates)
    return candidates
end

--- Standalone plugin settings menu (owner ask 2026-07-16; koassistant
-- a8bfa3c idiom): the Quran Helper menu opened directly as its own
-- TouchMenu, built from the same addToMainMenu items — NOT by crawling
-- KOReader's main menu (menu_order overrides, slow devices, and menu
-- refactors made crawling silently no-op in koassistant's previous
-- implementation).
function Quran:showSettingsMenu()
    local UIManager = require("ui/uimanager")
    local TouchMenu = require("ui/widget/touchmenu")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Screen = require("device").screen
    local menu_items = {}
    self:addToMainMenu(menu_items)
    local items = menu_items.quran and menu_items.quran.sub_item_table
    if not items then return end
    items.icon = "appbar.settings"  -- TouchMenu builds its icon bar from each tab's .icon
    local menu_container = CenterContainer:new{
        covers_header = true,
        ignore = "height",
        dimen = Screen:getSize(),
    }
    local main_menu = TouchMenu:new{
        width = Screen:getWidth(),
        tab_item_table = { items },
        show_parent = menu_container,
    }
    main_menu.close_callback = function()
        UIManager:close(menu_container)
    end
    menu_container[1] = main_menu
    UIManager:show(menu_container)
end

--- Configurable ayah-marker long-press action (design D-R2-4a, owner
-- 2026-07-16). Called from onWordLookup AFTER the press has been
-- resolved to surah + Hafs ayah — the popup path's OWN resolution, so
-- the diverted action can never disagree with what the popup would
-- have shown (v1 resolved independently at the onLookupWord patch,
-- which could act on a stale stash: opened surah 83 instead of 80,
-- then stopped diverting — owner report 2026-07-16). When the
-- configured action can run, it is scheduled on the next tick (outside
-- the lookup pipeline), the selection highlight is cleared, and true
-- is returned — the caller then flags the pending popup for
-- suppression. Returns nil when the action is "popup" or unavailable
-- (no Reader path / no text package / ayah missing from the package):
-- the popup proceeds and the user always gets something.
function Quran:_divertAyahAction(surah, hafs)
    local action = self.settings
        and self.settings:readSetting("ayah_longpress_action", "popup")
    if not action or action == "popup" then return end
    local UIManager = require("ui/uimanager")
    if action == "tafsir" then
        if not self:canReaderTafsir() or #self:_installedTafsirs() == 0 then
            return
        end
        UIManager:nextTick(function()
            self:openTafsirReader(surah, hafs, { explore = true })
        end)
    elseif action == "ayah_page" then
        local actions = self:_actionsModule()
        if not (actions and actions.showBrowser) then return end
        UIManager:nextTick(function()
            self:openBrowserAtAyah(surah, hafs)
        end)
    elseif action == "translation" then
        local reader = self:_readerModule()
        local qt = self._textModule and self:_textModule()
        local conn = qt and qt.ensureDb and qt.ensureDb(self)
        if not (reader and reader.showAyah and conn) then return end
        if qt.ayah and not qt.ayah(conn, "hafs", surah, hafs) then return end
        UIManager:nextTick(function()
            reader.showAyah(self, surah, hafs, { explore = true })
        end)
    else
        return
    end
    if self.ui and self.ui.highlight and self.ui.highlight.clear then
        self.ui.highlight:clear()
    end
    return true
end

--- Open a FRESH ayah-keyed dictionary popup (quick panel / gesture path —
-- contrast _lookupAyah below, which updates an existing popup in place).
-- surah is book-space; ayah must already be the Hafs number that keys the
-- dictionaries (caller converts via _warshToHafs).
function Quran:openAyahPopup(surah, ayah)
    local name = SURAH_NAMES[surah]
    if not name or not self.ui or not self.ui.dictionary then return end
    self._last_ayah_surah = surah
    self._last_ayah_num = ayah
    DictQuickLookup._quran_next_lookup = true
    self.ui.dictionary:onLookupWord(name .. " " .. ayah)
end

--- Open a FRESH surah-overview popup (quick panel / gesture path).
function Quran:openSurahOverviewPopup(surah)
    local name = SURAH_NAMES[surah]
    if not name or not self.ui or not self.ui.dictionary then return end
    self._last_overview_surah = surah
    DictQuickLookup._quran_next_lookup = true
    self.ui.dictionary:onLookupWord(name)
end

--- Navigate to a specific ayah. Updates the popup in-place.
function Quran:_lookupAyah(surah, ayah, dict_popup)
    local name = SURAH_NAMES[surah]
    if not name then return end

    local key = name .. " " .. ayah
    logger.dbg("quran.koplugin: navigating to", key)

    -- Pre-stash for _setupQuranPopupButtons (won't fire for in-place update,
    -- but needed if showDict falls through to creating a new popup)
    self._last_ayah_surah = surah
    self._last_ayah_num = ayah

    -- Update mutable state on popup (button callbacks reference these)
    dict_popup._quran_surah = surah
    dict_popup._quran_ayah = ayah

    -- Update button enable/disable states
    local has_prev = ayah > 1 or surah > 1
    local has_next = ayah < (self:_ayahCounts()[surah] or 0) or surah < 114
    local next_btn = dict_popup.button_table:getButtonById("next_ayah")
    local prev_btn = dict_popup.button_table:getButtonById("prev_ayah")
    if next_btn then next_btn:enableDisable(has_next) end
    if prev_btn then prev_btn:enableDisable(has_prev) end

    -- Capture current dictionary so in-place update stays in it
    dict_popup._quran_dict_name = dict_popup.dictionary

    -- Signal showDict to update this popup in-place
    DictQuickLookup._quran_update_popup = dict_popup

    -- Trigger lookup through normal pipeline
    self.ui.dictionary:onLookupWord(key)
end

--- Navigate to a specific surah overview. Updates the popup in-place.
function Quran:_lookupSurah(surah, dict_popup)
    local name = SURAH_NAMES[surah]
    if not name then return end

    logger.dbg("quran.koplugin: navigating to surah overview", surah, name)

    -- Update mutable state on popup (button callbacks reference this)
    dict_popup._quran_overview_surah = surah

    -- Update button enable/disable states
    local has_prev = surah > 1
    local has_next = surah < 114
    local next_btn = dict_popup.button_table:getButtonById("next_surah")
    local prev_btn = dict_popup.button_table:getButtonById("prev_surah")
    if next_btn then next_btn:enableDisable(has_next) end
    if prev_btn then prev_btn:enableDisable(has_prev) end

    -- Capture current dictionary so in-place update stays in it
    dict_popup._quran_dict_name = dict_popup.dictionary

    -- Signal showDict to update this popup in-place
    DictQuickLookup._quran_update_popup = dict_popup

    -- Trigger lookup through normal pipeline
    self.ui.dictionary:onLookupWord(name)
end

--- Common setup for all Quran custom popups.
-- Clears default buttons, sets flags for medium height and no word highlight.
-- Initializes text mode state from saved settings.
-- @param dict_popup DictQuickLookup instance
-- @param buttons Buttons table from _setupQuranPopupButtons
-- @param settings LuaSettings instance
local function setupQuranPopup(dict_popup, buttons)
    if DictQuickLookup._quran_next_lookup then
        DictQuickLookup._quran_next_lookup = nil
    end
    -- Don't inherit temp large-window mode from a previous regular popup
    DictQuickLookup.temp_large_window_request = nil
    dict_popup._quran_popup = true
    dict_popup.word_boxes = nil
    for i = #buttons, 1, -1 do
        table.remove(buttons, i)
    end
    -- Text mode is auto-determined per dict type in the update() patch
end

--- Build a nav button pair (next/prev) respecting RTL/LTR setting.
-- RTL (default): ◁ = next (forward), ▷ = prev (backward)
-- LTR: ◁ = prev (backward), ▷ = next (forward)
-- @param self_quran Quran plugin instance (for accessing ReaderView)
-- @param next_btn table with id, enabled, callback for forward nav
-- @param prev_btn table with id, enabled, callback for backward nav
-- @return left_btn, right_btn (ready for button row insertion)
local function navButtons(self_quran, next_btn, prev_btn)
    -- Follow KOReader's page turn direction (inverse_reading_order = RTL)
    local rtl = self_quran.ui and self_quran.ui.view
        and self_quran.ui.view.inverse_reading_order
    if rtl then
        -- RTL: left=next(◁), right=prev(▷)
        next_btn.text = "◁"
        prev_btn.text = "▷"
        return next_btn, prev_btn
    else
        -- LTR: left=prev(◁), right=next(▷)
        prev_btn.text = "◁"
        next_btn.text = "▷"
        return prev_btn, next_btn
    end
end

--- Scroll-to-top button for Quran popups.
local function scrollTopButton(dict_popup)
    return {
        id = "scroll_top",
        text = "⇱",
        callback = function()
            if dict_popup.definition_widget and dict_popup.definition_widget[1] then
                if dict_popup.definition_widget[1].scrollToTop then
                    dict_popup.definition_widget[1]:scrollToTop()
                elseif dict_popup.definition_widget[1].scrollToRatio then
                    dict_popup.definition_widget[1]:scrollToRatio(0)
                end
            end
        end,
    }
end

--- Scroll-to-bottom button for Quran popups.
local function scrollBottomButton(dict_popup)
    return {
        id = "scroll_bottom",
        text = "⇲",
        callback = function()
            if dict_popup.definition_widget and dict_popup.definition_widget[1] then
                if dict_popup.definition_widget[1].scrollToBottom then
                    dict_popup.definition_widget[1]:scrollToBottom()
                elseif dict_popup.definition_widget[1].scrollToRatio then
                    dict_popup.definition_widget[1]:scrollToRatio(1)
                end
            end
        end,
    }
end

--- Detect surah:ayah from XPointers using CREngine HTML.
-- Works for per-ayah layouts where each ayah is wrapped in <p id="ayah-S-A">.
-- Returns surah (int), ayah (int) or nil, nil.
function Quran:_detectAyahFromXPointer(pos0, pos1)
    if not self.ui or not self.ui.document then
        return nil, nil
    end
    local doc = self.ui.document

    -- Try narrow range first (per-ayah/bilingual/wbw: ayah ID is on ancestor)
    local ok, html = pcall(function()
        return doc:getHTMLFromXPointers(pos0, pos1, 0x8000, true)
    end)
    if ok and html then
        local surah_str, ayah_str = html:match('ayah%-(%d+)%-(%d+)')
        if surah_str and ayah_str then
            logger.info("QURAN: detect: ancestor match", surah_str, ayah_str)
            return tonumber(surah_str), tonumber(ayah_str)
        end
    end

    -- For inline/continuous layouts: ayah ID is on a sibling <span> after the word.
    -- Extend range forward to include the next ayah marker in the HTML.
    local ok2, pageno = pcall(function()
        return doc:getPageFromXPointer(pos0)
    end)
    if not ok2 or not pageno then
        logger.info("QURAN: detect: could not get page")
        return nil, nil
    end

    local ok3, ext_xp = pcall(function()
        return doc:getPageXPointer(pageno + 3)
    end)
    if not ok3 or not ext_xp then
        -- Near end of document — try page + 1
        ok3, ext_xp = pcall(function()
            return doc:getPageXPointer(pageno + 1)
        end)
        if not ok3 or not ext_xp then
            logger.info("QURAN: detect: could not get extended xpointer")
            return nil, nil
        end
    end

    local ok4, ext_html = pcall(function()
        return doc:getHTMLFromXPointers(pos0, ext_xp, 0x20000, true)
    end)
    if ok4 and ext_html then
        local surah_str, ayah_str = ext_html:match('ayah%-(%d+)%-(%d+)')
        if surah_str and ayah_str then
            logger.info("QURAN: detect: extended match", surah_str, ayah_str)
            return tonumber(surah_str), tonumber(ayah_str)
        end
    end

    logger.info("QURAN: detect: no ayah found")
    return nil, nil
end

--- Filter word-lookup results down to the instance at the pressed position.
-- Consumes the XPointers stashed by onWordSelection, detects the pressed
-- word's surah:ayah, and keeps only results whose embedded
-- <!-- ref:S:A:W --> comment matches that ayah (instance-mode word
-- dictionaries). Returns results unchanged when detection fails or nothing
-- matches. Runs inside the showDict patch, before the popup is built, so it
-- works on all KOReader versions.
function Quran:_filterWordResultsByPosition(results)
    local word_pos0 = self._stashed_word_pos0
    local word_pos1 = self._stashed_word_pos1
    self._stashed_word_pos0 = nil
    self._stashed_word_pos1 = nil

    if not (word_pos0 and word_pos1 and #results > 1) then
        return results
    end
    logger.info("QURAN: instance match:", #results, "results")
    local det_surah, det_ayah = self:_detectAyahFromXPointer(word_pos0, word_pos1)
    if not (det_surah and det_ayah) then
        return results
    end
    local ref_prefix = det_surah .. ":" .. det_ayah .. ":"
    -- Keep only results whose ref matches this ayah
    local filtered = {}
    for _, result in ipairs(results) do
        if result.definition then
            local refs = result.definition:match("<!%-%- ref:(.-) %-%->")
            if refs then
                for ref in refs:gmatch("[^,]+") do
                    if ref:sub(1, #ref_prefix) == ref_prefix then
                        table.insert(filtered, result)
                        break
                    end
                end
            end
        end
    end
    if #filtered > 0 then
        logger.info("QURAN: filtered", #results, "->", #filtered, "results")
        return filtered
    end
    logger.info("QURAN: no ref matched prefix", ref_prefix)
    return results
end

--- Append a "Root explorer" row to WORD popups on Quran books when a
-- result carries a parseable "root: ‎X-Y-Z" line (word-by-word dict).
-- PRE-2026.05 KOREADER ONLY (DictButtonsReady hands us the real buttons
-- table); newer versions register via _registerRootDictButton instead.
-- Unlike the ayah/overview popups, the default buttons stay — this only
-- adds a row. The root is re-read from the DISPLAYED result at tap time
-- (◀▶ may have switched dictionaries).
function Quran:_maybeAddRootButton(dict_popup, buttons)
    if not self._is_quran_book then return end
    local roots = self:_rootsModule()
    if not roots then return end
    local any
    for _idx, r in ipairs(dict_popup.results or {}) do
        any = roots.parseRootFromDefinition(r.definition)
        if any then break end
    end
    if not any then return end
    table.insert(buttons, {
        {
            id = "quran_root_explorer",
            text = _("Root explorer"),
            callback = function()
                local cur = dict_popup.results and dict_popup.dict_index
                    and dict_popup.results[dict_popup.dict_index]
                local root = (cur and roots.parseRootFromDefinition(cur.definition)) or any
                dict_popup:onClose()
                self:openRootExplorer(root)
            end,
        },
    })
end

--- Read the group-range comment from the result the popup is displaying.
-- Every tafsir-dict entry starts with <!-- range:S:A1-A2 --> (grouped
-- tafsirs comment the whole block, per-ayah entries a degenerate
-- single-ayah range). Returns surah, first, last — or nil for dicts
-- without the comment (word/grammar/non-Quran).
function Quran:_displayedRange(dict_popup)
    local r = dict_popup.results and dict_popup.dict_index
        and dict_popup.results[dict_popup.dict_index]
    local def = r and r.definition
    if not def then return end
    local s, a1, a2 = def:match("<!%-%- range:(%d+):(%d+)%-(%d+) %-%->")
    if s then return tonumber(s), tonumber(a1), tonumber(a2) end
end

--- Next/prev target for popup ayah navigation, skipping the displayed
-- entry's group: grouped tafsirs (e.g. Fi Zilal commenting 2:1-29 as one
-- block) advance to fresh content instead of re-showing the same entry.
-- The skip follows the CURRENTLY displayed dict only (mixed-dict policy);
-- entries without a range comment step by single ayahs. Numbering is
-- Hafs-space like the rest of the popup nav. Returns surah, ayah — or
-- nil at the ends of the mushaf.
function Quran:_ayahNavTarget(dict_popup, dir)
    local s = dict_popup._quran_surah
    local a = dict_popup._quran_ayah
    if not (s and a) then return end
    local rs, r1, r2 = self:_displayedRange(dict_popup)
    if rs == s then
        if dir > 0 and r2 and r2 >= a then
            a = r2
        elseif dir < 0 and r1 and r1 <= a then
            a = r1
        end
    end
    a = a + dir
    local counts = self:_ayahCounts()
    if a > (counts[s] or 0) then
        s = s + 1
        a = 1
    elseif a < 1 then
        s = s - 1
        a = counts[s] or 1
    end
    if s >= 1 and s <= 114 then
        return s, a
    end
end

--- First ayah at/after S:A (walking direction dir, Hafs space) that has
-- an entry in dict_name — ONE batched exact-match sdcv probe over the
-- next max_steps ayahs' key candidates. Sparse resources (grouped
-- tafsirs with gaps, asbab at ~5% coverage) need this so "next" means
-- "next entry in THIS dict". Returns surah, ayah — or nil when nothing
-- is covered within max_steps (or rawSdcv is unavailable).
function Quran:_firstAyahWithEntry(dict_name, surah, ayah, dir, max_steps)
    local dictionary = self.ui and self.ui.dictionary
    if not (dictionary and dictionary.rawSdcv) then return end
    local counts = self:_hafsCounts()
    local words, spots = {}, {}
    local s, a = surah, ayah
    for _i = 1, max_steps or 30 do
        for _k, key in ipairs(self:_ayahDictKeys(s, a)) do
            table.insert(words, key)
            table.insert(spots, { s = s, a = a })
        end
        a = a + dir
        if a > (counts[s] or 0) then
            s = s + 1
            a = 1
        elseif a < 1 then
            s = s - 1
            a = counts[s] or 1
        end
        if s < 1 or s > 114 then break end
    end
    local cancelled, results = dictionary:rawSdcv(words, { dict_name }, false, false)
    if cancelled then return end
    for i = 1, #words do
        for _idx, r in ipairs(results and results[i] or {}) do
            if r.definition and r.definition ~= "" then
                return spots[i].s, spots[i].a
            end
        end
    end
end

--- Popup ◀ ▶ / page-turn ayah navigation: group-skip target, then —
-- when the DISPLAYED dict has no entry there (coverage gap) — skip on
-- to its next covered ayah instead of letting the popup silently
-- switch to whichever dictionary sorts first (owner report 2026-07-12:
-- reading Tazkirul Quran groups jumped to the grammar dict). The probe
-- needs rawSdcv; pre-rawSdcv KOReader keeps the plain step.
function Quran:_navigateAyahPopup(dict_popup, dir)
    local s, a = self:_ayahNavTarget(dict_popup, dir)
    if not s then return end
    local dict = dict_popup.dictionary
    local dictionary = self.ui and self.ui.dictionary
    if dict and dictionary and dictionary.rawSdcv then
        local quran = self
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            -- 100-ayah window: covers asbab-scale sparseness in one call;
            -- beyond it the plain step (old behavior) is the fallback
            local ns, na = quran:_firstAyahWithEntry(dict, s, a, dir, 100)
            if ns then s, a = ns, na end
            quran:_lookupAyah(s, a, dict_popup)
        end)
        return
    end
    self:_lookupAyah(s, a, dict_popup)
end

--- Expose the file-local HTML→PTF converter to sibling modules (the
-- Reader renders StarDict definitions with it).
function Quran:_htmlToText(html)
    return htmlToText(html)
end

--- Hafs ayah counts regardless of the open book's riwayah — Reader/hub
-- navigation is Hafs-canonical (dictionaries and connection data are
-- Hafs-keyed; design invariant D8).
function Quran:_hafsCounts()
    return SURAH_AYAH_COUNTS
end

--- Dictionary key candidates for S:A (Hafs) — the ayah-keyed dicts index
-- headwords as "<surah name_simple> <ayah>" ("Al-Baqarah 255"; see
-- build_tafseer_dictionary.py), with "SSS:AAA" as a legacy candidate.
-- Same candidate list as the popup lookup path; there is NO "2:255" key.
function Quran:_ayahDictKeys(surah, ayah)
    local keys = {}
    local name = SURAH_NAMES[surah]
    if name then
        table.insert(keys, name .. " " .. ayah)
    end
    table.insert(keys, string.format("%03d:%03d", surah, ayah))
    return keys
end

-- ---------------------------------------------------------------------
-- Content-first resource enumeration (design D-R2-2): an ayah-keyed
-- dictionary's entries become browsable ITEMS by parsing its StarDict
-- .idx directly — no data-format change, works on every installed dict.
-- Grouped tafsirs/asbab index one key PER COVERED AYAH, all pointing at
-- the same entry: keys sharing (offset, size) collapse into one item
-- carrying the covered range. Our builder always writes 32-bit offsets
-- (no idxoffsetbits=64), which is all this parser handles.
-- ---------------------------------------------------------------------

--- Parse a StarDict .idx blob: (word\0, 32-bit BE offset, 32-bit BE
-- size) records. Returns an array of { word, offset, size }.
local function parseStarDictIdx(data)
    local entries = {}
    local pos, len = 1, #data
    while pos <= len do
        local z = data:find("\0", pos, true)
        if not z or z + 8 > len then break end
        local b1, b2, b3, b4, c1, c2, c3, c4 = data:byte(z + 1, z + 8)
        entries[#entries + 1] = {
            word = data:sub(pos, z - 1),
            offset = ((b1 * 256 + b2) * 256 + b3) * 256 + b4,
            size = ((c1 * 256 + c2) * 256 + c3) * 256 + c4,
        }
        pos = z + 9
    end
    return entries
end

--- Classify one idx key of an ayah-keyed dict. Returns surah, ayah —
-- ayah nil for bare surah-name keys (the overview dict) — or nil for
-- foreign keys. Handles "Al-Baqarah 255", legacy "002:255", "Al-Baqarah".
local function ayahKeyInfo(key)
    local s3, a3 = key:match("^(%d%d%d):(%d%d%d)$")
    if s3 then return tonumber(s3), tonumber(a3) end
    local name, a = key:match("^(.-)%s+(%d+)$")
    if name and SURAH_NAME_TO_NUM[name] then
        return SURAH_NAME_TO_NUM[name], tonumber(a)
    end
    if SURAH_NAME_TO_NUM[key] then return SURAH_NAME_TO_NUM[key], nil end
end

--- Group parsed idx entries into browsable items. Same-entry keys
-- (shared surah + offset + size — synonym keys and per-covered-ayah
-- group keys) collapse; the item carries the covered range. Returns
--   items    { { surah, a1, a2 }, ... }  mushaf-ordered (a1/a2 nil for
--            bare surah-name keys)
--   by_surah { [surah] = item count }
local function groupAyahKeys(entries)
    local groups, items, by_surah = {}, {}, {}
    for _i, e in ipairs(entries) do
        local s, a = ayahKeyInfo(e.word)
        if s then
            local gk = s .. ":" .. e.offset .. ":" .. e.size
            local g = groups[gk]
            if not g then
                g = { surah = s, a1 = a, a2 = a }
                groups[gk] = g
                items[#items + 1] = g
                by_surah[s] = (by_surah[s] or 0) + 1
            elseif a then
                if not g.a1 or a < g.a1 then g.a1 = a end
                if not g.a2 or a > g.a2 then g.a2 = a end
            end
        end
    end
    table.sort(items, function(x, y)
        if x.surah ~= y.surah then return x.surah < y.surah end
        return (x.a1 or 0) < (y.a1 or 0)
    end)
    return items, by_surah
end

--- Resolve an enabled dictionary bookname to its .idx path: scan the
-- dict data dir(s) for .ifo files and read their bookname line (the
-- name↔file mapping only lives inside the .ifo). Cached per session.
function Quran:_dictIdxPath(bookname)
    if not self._dict_idx_paths then
        local map = {}
        local dirs = {}
        local dictionary = self.ui and self.ui.dictionary
        if dictionary and dictionary.data_dir then
            table.insert(dirs, dictionary.data_dir)
            table.insert(dirs, dictionary.data_dir .. "_ext")
        else
            local ok, DataStorage = pcall(require, "datastorage")
            if ok then
                table.insert(dirs, DataStorage:getDataDir() .. "/data/dict")
            end
        end
        local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if lfs_ok then
            local function scan(dir, depth)
                if depth > 4
                    or lfs.attributes(dir, "mode") ~= "directory" then
                    return
                end
                for entry in lfs.dir(dir) do
                    if entry ~= "." and entry ~= ".." then
                        local path = dir .. "/" .. entry
                        if lfs.attributes(path, "mode") == "directory" then
                            scan(path, depth + 1)
                        elseif entry:match("%.ifo$") then
                            local f = io.open(path, "r")
                            if f then
                                local content = f:read("*all")
                                f:close()
                                local name = content
                                    and content:match("\nbookname=(.-)\r?\n")
                                if name then
                                    map[name] = path:gsub("%.ifo$", ".idx")
                                end
                            end
                        end
                    end
                end
            end
            for _i, d in ipairs(dirs) do pcall(scan, d, 0) end
        end
        self._dict_idx_paths = map
    end
    return self._dict_idx_paths[bookname]
end

--- Enumerate an ayah-keyed dictionary as browsable items (cached).
-- Returns items, by_surah (see groupAyahKeys), or nil when the dict's
-- .idx cannot be located or read.
function Quran:_dictAyahItems(bookname)
    self._dict_items_cache = self._dict_items_cache or {}
    local cached = self._dict_items_cache[bookname]
    if cached then return cached.items, cached.by_surah end
    local idx = self:_dictIdxPath(bookname)
    if not idx then return end
    local f = io.open(idx, "rb")
    if not f then return end
    local data = f:read("*all")
    f:close()
    if not data or #data == 0 then return end
    local items, by_surah = groupAyahKeys(parseStarDictIdx(data))
    self._dict_items_cache[bookname] = { items = items, by_surah = by_surah }
    return items, by_surah
end

--- Splice a reordered Quran-dict subset back into the full enabled-dict
-- order, preserving every other dictionary's position. enabled = the
-- current effective order; reordered = the Quran subset in its new
-- order; is_quran(name) decides membership. Pure (unit-tested).
local function spliceDictOrder(enabled, reordered, is_quran)
    local out, qi = {}, 1
    for _i, name in ipairs(enabled) do
        if is_quran(name) then
            out[#out + 1] = reordered[qi] or name
            qi = qi + 1
        else
            out[#out + 1] = name
        end
    end
    return out
end

--- Plugin-side popup dictionary ordering (design D-R2-4 slice, owner
-- 2026-07-16: "handle the order of the popup dictionaries the plugin
-- ships"). Reorders the Quran dictionaries with KOReader's own
-- SortWidget, then writes KOReader's dicts_order (keyed by .ifo path)
-- rebuilt over the enabled dicts — the popup's result/◀▶ order follows
-- it. Non-Quran dicts keep their relative positions; disabled dicts end
-- up unnumbered (name-sorted at the end of the manage list — cosmetic).
function Quran:showQuranDictOrder()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local dictionary = self.ui and self.ui.dictionary
    local actions = self:_actionsModule()
    if not (dictionary and actions and dictionary.sortAvailableIfos) then return end
    local enabled = dictionary.enabled_dict_names or {}
    local function isQuran(name) return actions.classifyDict(name) ~= nil end
    local quran_names = {}
    for _i, name in ipairs(enabled) do
        if isQuran(name) then table.insert(quran_names, name) end
    end
    if #quran_names < 2 then
        UIManager:show(InfoMessage:new{
            text = _("Fewer than two enabled Quran dictionaries — nothing to reorder."),
        })
        return
    end
    -- Resolve every enabled dict to its .ifo (the dicts_order key);
    -- abort rather than corrupt the global order if one won't resolve.
    local files = {}
    for _i, name in ipairs(enabled) do
        local idx = self:_dictIdxPath(name)
        if not idx then
            UIManager:show(InfoMessage:new{
                text = _("Could not resolve every dictionary file — order left unchanged."),
            })
            return
        end
        files[name] = idx:gsub("%.idx$", ".ifo")
    end
    local sort_items = {}
    for _i, name in ipairs(quran_names) do
        table.insert(sort_items, { text = name })
    end
    local SortWidget = require("ui/widget/sortwidget")
    UIManager:show(SortWidget:new{
        title = _("Quran dictionary order"),
        item_table = sort_items,
        callback = function()
            local reordered = {}
            for _i, it in ipairs(sort_items) do
                table.insert(reordered, it.text)
            end
            local new_order = spliceDictOrder(enabled, reordered, isQuran)
            local dicts_order = {}
            for i, name in ipairs(new_order) do
                dicts_order[files[name]] = i
            end
            dictionary.dicts_order = dicts_order
            G_reader_settings:saveSetting("dicts_order", dicts_order)
            dictionary:sortAvailableIfos()
            dictionary:updateSdcvDictNamesOptions()
            UIManager:setDirty(nil, "ui")
        end,
    })
end

--- Fetch one dictionary definition headlessly (no popup) via
-- ReaderDictionary:rawSdcv. keys = one key or an ordered candidate list
-- (first key with a non-empty definition wins — single sdcv call).
-- Must run inside a Trapper coroutine (rawSdcv uses dismissablePopen).
-- Returns the definition string or nil.
function Quran:_rawDefinition(dict_name, keys)
    local dictionary = self.ui and self.ui.dictionary
    if not (dictionary and dictionary.rawSdcv) then return end
    if type(keys) ~= "table" then keys = { keys } end
    local cancelled, results = dictionary:rawSdcv(keys, { dict_name }, false, false)
    if cancelled then return end
    for i = 1, #keys do
        for _idx, r in ipairs(results and results[i] or {}) do
            if r.definition and r.definition ~= "" then
                return r.definition
            end
        end
    end
end

--- Whether the full-screen tafsir Reader path is available (needs
-- KOReader's headless rawSdcv; older versions keep the popup flow).
function Quran:canReaderTafsir()
    if not (self.ui and self.ui.dictionary and self.ui.dictionary.rawSdcv) then
        return false
    end
    return self:_readerModule() ~= nil
end

--- Installed ayah-keyed tafsir dictionaries (panel classification).
function Quran:_installedTafsirs()
    local actions = self:_actionsModule()
    local res = actions and actions.detectResources
        and actions.detectResources(self)
    return res and res.tafsir or {}
end

--- Open a tafsir for S:A (Hafs numbering) in the full-screen Reader.
-- Resolves the dictionary: explicit opts.dict → the preferred-tafsir
-- setting → the single installed tafsir → a picker (which saves the
-- choice as preferred). opts.explore adds the Reader's bridge button
-- into the browser (set by entry points that do NOT already have the
-- browser beneath). Returns false when the Reader path is
-- unavailable — callers fall back to the popup flow.
function Quran:openTafsirReader(surah, ayah, opts)
    opts = opts or {}
    if not self:canReaderTafsir() then return false end
    local reader = self:_readerModule()
    local dict = opts.dict
    if not dict then
        local tafsirs = self:_installedTafsirs()
        if #tafsirs == 0 then return false end
        local preferred = self.settings
            and self.settings:readSetting("preferred_tafsir")
        for _idx, name in ipairs(tafsirs) do
            if name == preferred then
                dict = name
                break
            end
        end
        if not dict and #tafsirs == 1 then dict = tafsirs[1] end
        if not dict then
            self:_showTafsirPicker(surah, ayah, opts)
            return true
        end
    end
    return reader.showTafsir(self, surah, ayah,
        { dict = dict, explore = opts.explore, back_label = opts.back_label })
end

--- Tafsir picker: choose which tafsir to read S:A in; the choice is
-- saved as the preferred tafsir (one tap opens it next time; the
-- Reader's Switch button or a hold on the panel button reopens this).
-- opts (optional) is forwarded to openTafsirReader (explore flag).
function Quran:_showTafsirPicker(surah, ayah, opts)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local tafsirs = self:_installedTafsirs()
    if #tafsirs == 0 then return end
    local quran = self
    local rows = {}
    for _idx, name in ipairs(tafsirs) do
        table.insert(rows, { {
            text = name,
            font_bold = false,
            callback = function()
                UIManager:close(quran._tafsir_picker)
                quran._tafsir_picker = nil
                if quran.settings then
                    quran.settings:saveSetting("preferred_tafsir", name)
                    quran.settings:flush()
                end
                quran:openTafsirReader(surah, ayah,
                    { dict = name, explore = opts and opts.explore })
            end,
        } })
    end
    table.insert(rows, { {
        text = _("Close"),
        callback = function()
            UIManager:close(quran._tafsir_picker)
            quran._tafsir_picker = nil
        end,
    } })
    self._tafsir_picker = ButtonDialog:new{
        title = _("Read tafsir — your pick becomes the default"),
        title_align = "center",
        buttons = rows,
        tap_close_callback = function() quran._tafsir_picker = nil end,
    }
    UIManager:show(self._tafsir_picker)
end

--- Build the custom button layout for Quran popups (grammar / surah overview).
-- Replaces the default buttons with nav/scroll/text-mode rows, overrides
-- key handlers, and flags the popup for medium height. Leaves non-Quran
-- popups untouched (returns nil).
-- Reached via Quran:onDictButtonsReady (KOReader < 2026.05) or the
-- buildButtonLayout patch (newer versions).
-- @param dict_popup DictQuickLookup instance
-- @param buttons button-row table to fill (cleared first)
-- @return true if this was a Quran popup and the buttons were replaced
function Quran:_setupQuranPopupButtons(dict_popup, buttons)
    -- Try parsing the lookup word first (works for prev/next navigation)
    local surah, ayah = parseQuranKey(dict_popup.word)

    -- Fall back to stashed info from onWordLookup (initial long-press case)
    if not surah and self._last_ayah_surah then
        surah = self._last_ayah_surah
        ayah = self._last_ayah_num
        self._last_ayah_surah = nil
        self._last_ayah_num = nil
    end

    -- Surah overview popup: [⇱] [◁ Next] [Close] [Prev ▷] [⇲]
    -- Navigation goes to next/prev surah overview
    if not surah or not ayah then
        if not DictQuickLookup._quran_next_lookup then
            -- Ordinary word popup (long-press). On OLD KOReader (the
            -- DictButtonsReady event) `buttons` is the real table, so the
            -- Root-explorer row is appended here. On ≥ 2026.05 this
            -- function gets a throwaway table on the fall-through path —
            -- there the button comes from _registerRootDictButton instead.
            if not (self.ui.dictionary and self.ui.dictionary.addToDictButtons) then
                self:_maybeAddRootButton(dict_popup, buttons)
            end
            return
        end

        local overview_surah = self._last_overview_surah
        self._last_overview_surah = nil

        logger.dbg("quran.koplugin: patching surah overview popup for surah", overview_surah)
        setupQuranPopup(dict_popup, buttons)
        dict_popup._quran_overview_surah = overview_surah

        local has_prev = overview_surah and overview_surah > 1
        local has_next = overview_surah and overview_surah < 114

        local left_btn, right_btn = navButtons(self, {
            id = "next_surah",
            enabled = has_next,
            vsync = true,
            callback = function()
                local s = (dict_popup._quran_overview_surah or 0) + 1
                if s <= 114 then
                    self:_lookupSurah(s, dict_popup)
                end
            end,
        }, {
            id = "prev_surah",
            enabled = has_prev,
            vsync = true,
            callback = function()
                local s = (dict_popup._quran_overview_surah or 2) - 1
                if s >= 1 then
                    self:_lookupSurah(s, dict_popup)
                end
            end,
        })

        table.insert(buttons, {
            scrollTopButton(dict_popup),
            left_btn,
            textModeButton(dict_popup),
            right_btn,
            scrollBottomButton(dict_popup),
        })
        table.insert(buttons, {
            {
                id = "close",
                text = _("Close"),
                callback = function()
                    dict_popup:onClose()
                end,
            },
        })

        -- Volume/page-turn keys for surah navigation
        dict_popup.onReadNextResult = function(self_dql)
            local s = (self_dql._quran_overview_surah or 0) + 1
            if s <= 114 then
                self:_lookupSurah(s, self_dql)
            end
            return true
        end
        dict_popup.onReadPrevResult = function(self_dql)
            local s = (self_dql._quran_overview_surah or 2) - 1
            if s >= 1 then
                self:_lookupSurah(s, self_dql)
            end
            return true
        end

        return true  -- block VocabBuilder
    end

    -- Grammar dictionary popup: [⇱] [◁ Next] [TXT] [Prev ▷] [⇲]
    -- Navigation goes to next/prev ayah
    logger.dbg("quran.koplugin: patching grammar popup for", surah, ":", ayah)
    setupQuranPopup(dict_popup, buttons)

    -- Store mutable state for button callbacks and key handlers
    dict_popup._quran_surah = surah
    dict_popup._quran_ayah = ayah

    local has_prev = ayah > 1 or surah > 1
    local has_next = ayah < (self:_ayahCounts()[surah] or 0) or surah < 114

    -- Button rows:
    -- Row 1: [⇱] [◁/▷] [TXT ON/OFF] [▷/◁] [⇲]
    -- Row 2: [Close]
    -- Direction follows KOReader's inverse_reading_order setting
    local left_btn, right_btn = navButtons(self, {
        id = "next_ayah",
        enabled = has_next,
        vsync = true,
        callback = function()
            self:_navigateAyahPopup(dict_popup, 1)
        end,
    }, {
        id = "prev_ayah",
        enabled = has_prev,
        vsync = true,
        callback = function()
            self:_navigateAyahPopup(dict_popup, -1)
        end,
    })

    table.insert(buttons, {
        scrollTopButton(dict_popup),
        left_btn,
        textModeButton(dict_popup),
        right_btn,
        scrollBottomButton(dict_popup),
    })
    -- Row 2: bridges into the study surfaces + Close. "Explore" opens the
    -- browser's unified ayah page (the quick-lookup → browser bridge);
    -- "Read full" promotes the DISPLAYED entry into the full-screen
    -- Reader (any dict here is ayah-keyed; resolved at tap time because
    -- dict swipes don't rebuild this layout). Read full needs the
    -- headless fetch, so pre-rawSdcv KOReader gets Explore + Close only.
    local row2 = {
        {
            id = "quran_explore",
            text = _("Explore"),
            callback = function()
                local s = dict_popup._quran_surah
                local a = dict_popup._quran_ayah
                dict_popup:onClose()
                if s and a then
                    self:openBrowserAtAyah(s, a)
                end
            end,
        },
    }
    if self:canReaderTafsir() then
        table.insert(row2, {
            id = "quran_read_full",
            text = _("Read full"),
            callback = function()
                local cur = dict_popup.results and dict_popup.dict_index
                    and dict_popup.results[dict_popup.dict_index]
                local dict = cur and cur.dict
                local s = dict_popup._quran_surah
                local a = dict_popup._quran_ayah
                if not (dict and s and a) then return end
                dict_popup:onClose()
                self:openTafsirReader(s, a, { dict = dict, explore = true })
            end,
        })
    end
    table.insert(row2, {
        id = "close",
        text = _("Close"),
        callback = function()
            dict_popup:onClose()
        end,
    })
    table.insert(buttons, row2)

    -- Override volume/page-turn keys for ayah navigation
    dict_popup.onReadNextResult = function(self_dql)
        self:_navigateAyahPopup(self_dql, 1)
        return true
    end
    dict_popup.onReadPrevResult = function(self_dql)
        self:_navigateAyahPopup(self_dql, -1)
        return true
    end

    -- Block VocabBuilder from adding its button
    return true
end

--- DictButtonsReady event handler — KOReader < 2026.05 only.
-- Newer versions removed the event (#15184); they take the
-- buildButtonLayout patch path instead.
function Quran:onDictButtonsReady(dict_popup, buttons)
    return self:_setupQuranPopupButtons(dict_popup, buttons)
end

-- ---------------------------------------------------------------------------
-- Juz status bar
-- ---------------------------------------------------------------------------

--- Determine the current juz based on reading position.
-- Uses the TOC to find the current surah, then looks up which juz it falls in.
-- Caches result per page to avoid repeated TOC scans.
-- @return juz number (1-30), or nil if on front matter
-- @return boolean boundary — true if a juz boundary occurs on this page
function Quran:_getCurrentJuz()
    if not self.ui or not self.ui.document then return nil end

    -- Juz features only work with CRE (reflowable) documents (EPUB/HTML).
    -- PDFs/DjVu are page-based and use a different API — bail out.
    if self.ui.document.info and self.ui.document.info.has_pages then return nil end
    local pageno = self.ui.document:getCurrentPage()
    if not pageno then return nil end

    -- Return cached value if page hasn't changed
    if self._cached_pageno == pageno then
        return self._cached_juz, self._cached_boundary
    end

    -- Primary path: use juz TOC entries (accurate, independent of surah lookup).
    -- Our EPUBs have juz entries in the nav TOC (titles like "جزء ١").
    -- Uses entry.orig_page to bypass validateAndFixToc page corruption.
    local juz_pages = self:_getJuzTocPages()
    logger.dbg("quran.koplugin: page", pageno, "juz_pages?", juz_pages and "yes" or "nil")
    if juz_pages then
        -- Before juz 1 = cover/TOC/front matter — show nothing
        if juz_pages[1] and pageno < juz_pages[1] then
            logger.dbg("quran.koplugin: front-matter guard -> nil (page", pageno, "< juz1 page", juz_pages[1], ")")
            self._cached_juz = nil
            self._cached_boundary = false
            self._cached_pageno = pageno
            return nil
        end
        -- Find the last juz TOC entry whose page <= current page.
        -- Boundary = this juz's anchor resolves to exactly this page
        -- (i.e., the juz-starting ayah begins here).
        local juz = nil
        local boundary = false
        for j = 30, 1, -1 do
            if juz_pages[j] and juz_pages[j] <= pageno then
                juz = j
                if juz_pages[j] == pageno and j > 1 then
                    boundary = true
                end
                break
            end
        end
        if juz then
            logger.dbg("quran.koplugin: page", pageno, "-> juz", juz, boundary and "(boundary)" or "")
            self._cached_juz = juz
            self._cached_boundary = boundary
            self._cached_pageno = pageno
            return juz, boundary
        end
    end

    -- Fallback: estimate juz from surah number (for EPUBs without juz TOC)
    logger.dbg("quran.koplugin: juz TOC path found no match, trying surah fallback for page", pageno)
    local surah_num = self:_findSurahForPage(pageno)
    if not surah_num then
        logger.dbg("quran.koplugin: no surah found for page", pageno, "-> nil")
        self._cached_juz = nil
        self._cached_boundary = false
        self._cached_pageno = pageno
        return nil
    end
    local juz = 1
    for i = #JUZ_BOUNDARIES, 1, -1 do
        if surah_num >= JUZ_BOUNDARIES[i][1] then
            juz = i
            break
        end
    end

    self._cached_juz = juz
    self._cached_boundary = false
    self._cached_pageno = pageno
    return juz, false
end

--- Extract juz page numbers (cached).
-- Primary: uses mushaf page markers from the EPUB page-list (epub:type="page-list").
-- These markers are separate <span> elements placed BEFORE the ayah block in our
-- templates, so they resolve to the CRE page where the juz content starts visually
-- — even when CRE's anti-orphan logic pushes the ayah block to the next page.
-- Fallback: uses juz TOC entry xpointers (may resolve to the "late" page for
-- spanning ayahs, since the anchor is on the <p> inside the <div>).
-- @return table {[juz_num] = page_num} or nil
function Quran:_getJuzTocPages()
    if self._juz_toc_pages then return self._juz_toc_pages end

    local toc = self.ui.toc
    if not toc then return nil end

    toc:fillToc()
    local toc_list = toc.toc
    if not toc_list or #toc_list == 0 then return nil end

    -- Pass 1: collect juz TOC pages and xpointers
    local juz_pages = {}
    local juz_xpointers = {}
    local count = 0
    for _, entry in ipairs(toc_list) do
        local page = entry.orig_page or entry.page
        if entry.title and page then
            local title = toc:cleanUpTocTitle(entry.title)
            -- Match "جزء ١" through "جزء ٣٠" (Arabic-Indic numerals)
            local after_juz = title:match("^جزء%s+(.+)$")
            if after_juz then
                local juz_num = arabicIndicToInt(after_juz)
                if not juz_num then
                    juz_num = tonumber(after_juz)
                end
                if juz_num and juz_num >= 1 and juz_num <= 30 then
                    juz_pages[juz_num] = page
                    juz_xpointers[juz_num] = entry.xpointer
                    count = count + 1
                end
            end
        end
    end

    if count == 0 then
        logger.dbg("quran.koplugin: NO juz TOC entries found!")
        return nil
    end

    -- Pass 2: try to get more accurate pages from the page map.
    -- Mushaf page markers (<span id="pageNNN">) are BEFORE the ayah block
    -- in our templates, so they resolve to the page where the content starts
    -- — even when anti-orphan pushes the block element to the next page.
    local doc = self.ui.document
    if doc and doc.hasPageMap and doc:hasPageMap() then
        local page_map = doc:getPageMap()
        if page_map and #page_map > 0 then
            -- Build mushaf label → CRE page lookup
            local label_to_cre = {}
            for _, pm in ipairs(page_map) do
                if pm.label and pm.page then
                    label_to_cre[pm.label] = pm.page
                end
            end
            -- For each juz, find its mushaf page label via its xpointer
            local upgraded = 0
            for j = 1, 30 do
                if juz_xpointers[j] then
                    local ok, label = pcall(doc.getPageMapXPointerPageLabel, doc, juz_xpointers[j])
                    if ok and label and label_to_cre[label] then
                        local marker_page = label_to_cre[label]
                        if marker_page ~= juz_pages[j] then
                            logger.dbg("quran.koplugin: juz", j,
                                "page marker", label, "-> page", marker_page,
                                "(was", juz_pages[j], "from TOC anchor)")
                        end
                        juz_pages[j] = marker_page
                        upgraded = upgraded + 1
                    end
                end
            end
            if upgraded > 0 then
                logger.dbg("quran.koplugin: upgraded", upgraded, "juz pages from page map")
            end
        end
    end

    self._juz_toc_pages = juz_pages
    local parts = {}
    for j = 1, 30 do
        if juz_pages[j] then
            table.insert(parts, j .. "=" .. juz_pages[j])
        end
    end
    logger.dbg("quran.koplugin: juz pages:", table.concat(parts, " "))
    return juz_pages
end

--- Find the surah number for a page. For the CURRENT page — which is
-- every live caller: header bar, browser position, panel detection,
-- fragment-offset heuristic — this resolves by DOM order against the
-- view xpointer (_findSurahForPosition, the F5 path), because TOC
-- entry pages CLAMP beyond CREngine's lazy-pagination frontier: owner
-- repro 2026-07-16 №2, header/browser said Al-Buruj on At-Takwir's
-- first page once F4's pre-render margin removed the accidental
-- post-load full re-render that used to hide the clamp here. The page
-- scan remains for non-current pages and engines without xpointers.
-- IMPORTANT: the scan uses entry.orig_page when available. KOReader's
-- validateAndFixToc() may corrupt surah entry page numbers because
-- our nav TOC has juz entries (high pages) before surah entries
-- (low pages), which triggers the "bogus page" fixer.
function Quran:_findSurahForPage(pageno)
    local doc = self.ui and self.ui.document
    if doc and doc.getCurrentPage and doc.getXPointer then
        local okp, cur = pcall(doc.getCurrentPage, doc)
        if okp and cur == pageno then
            local okx, pos = pcall(doc.getXPointer, doc)
            if okx and pos then
                local surah_num = self:_findSurahForPosition(pos)
                if surah_num then return surah_num end
            end
        end
    end
    local toc = self.ui.toc
    if not toc then return nil end

    toc:fillToc()
    local toc_list = toc.toc
    if not toc_list or #toc_list == 0 then return nil end

    local best_surah = nil
    for _, entry in ipairs(toc_list) do
        local page = entry.orig_page or entry.page
        if page and page <= pageno and entry.title then
            local title = toc:cleanUpTocTitle(entry.title)
            local surah_num = extractSurahInfo(title)
            if surah_num then
                best_surah = surah_num
            end
        end
    end
    return best_surah
end

--- Convert integer to Arabic-Indic numeral string.
--- Resolve hizb boundary pages via ayah anchors (cached; invalidated on
-- rerender). Boundary S:A resolves through the END marker of the previous
-- ayah (id="ayah-S-(A-1)") -- visually where ayah A starts; surah-initial
-- boundaries use the header anchor (id="surah-S"). Fragment ids resolve
-- through CREngine's createXPointer, same as internal links. Books without
-- the anchors (pre-v0.11 EPUBs) resolve nothing -> feature disables itself.
function Quran:_getHizbPages()
    if self._hizb_pages ~= nil then
        return self._hizb_pages or nil
    end
    if not self.ui or not self.ui.document then return nil end
    if self.ui.document.info and self.ui.document.info.has_pages then return nil end
    local doc = self.ui.document
    local pages = {}
    local resolved = 0
    for i, b in ipairs(HIZB_BOUNDARIES) do
        -- Boundaries are Hafs-numbered; Warsh books have Warsh-numbered
        -- anchors — convert (identity for Hafs / non-divergent surahs).
        local a = b[2] > 1 and self:_hafsToWarsh(b[1], b[2]) or 1
        local xp
        if a > 1 then
            xp = string.format("#ayah-%d-%d", b[1], a - 1)
        else
            xp = string.format("#surah-%d", b[1])
        end
        local ok, page = pcall(doc.getPageFromXPointer, doc, xp)
        if ok and page and page > 0 then
            pages[i] = page
            resolved = resolved + 1
        end
    end
    -- info-level: one line per render generation; the resolved page list is
    -- the ground truth for any "hizb stuck/wrong" report (2026-07-10).
    local dump = {}
    for i = 1, 60 do
        dump[i] = pages[i] and tostring(pages[i]) or "-"
    end
    logger.info("quran.koplugin: hizb pages resolved:", resolved, "/60",
        "riwayah:", self._riwayah, "[", table.concat(dump, " "), "]")
    if resolved < 30 then
        self._hizb_pages = false  -- cache the failure; retry only on rerender
        return nil
    end
    self._hizb_pages = pages
    return pages
end

--- Current hizb (1-60) from boundary pages; nil when unavailable.
function Quran:_getCurrentHizb()
    if not HIZB_FEATURE_ENABLED then return nil end
    local pages = self:_getHizbPages()
    if not pages then return nil end
    local pageno = self.ui.document:getCurrentPage()
    if not pageno then return nil end
    for i = 60, 1, -1 do
        if pages[i] and pages[i] <= pageno then
            if self._last_logged_hizb ~= i then
                self._last_logged_hizb = i
                logger.info("quran.koplugin: hizb ->", i, "at page", pageno,
                    "(boundary page", pages[i], ", next",
                    pages[i + 1] or "-", ")")
            end
            return i
        end
    end
    return nil
end

local function toArabicIndic(n)
    local digits = {"٠","١","٢","٣","٤","٥","٦","٧","٨","٩"}
    local result = ""
    for ch in tostring(n):gmatch(".") do
        local d = tonumber(ch)
        result = result .. digits[d + 1]
    end
    return result
end

--- Format a juz number according to the display format key.
-- @param juz number: juz number (1-30)
-- @param juz_display string: format key
-- @return string, bool: formatted string, whether the format is Arabic/RTL
function Quran:_formatJuzString(juz, juz_display)
    local juz_str
    if juz_display == "name_arabic" then
        juz_str = (JUZ_NAMES_ARABIC[juz] or "")
    elseif juz_display == "name_arabic_with_juz" then
        juz_str = "جزء " .. (JUZ_NAMES_ARABIC[juz] or "")
    elseif juz_display == "ordinal_arabic" then
        juz_str = "الجزء " .. (JUZ_ORDINAL_ARABIC[juz] or "")
    elseif juz_display == "number_latin" then
        juz_str = "Juz " .. juz
    elseif juz_display == "name_latin" then
        juz_str = (JUZ_NAMES_LATIN[juz] or "")
    elseif juz_display == "name_latin_with_juz" then
        juz_str = "Juz' " .. (JUZ_NAMES_LATIN[juz] or "")
    else -- "number_arabic" (default)
        juz_str = "جزء " .. toArabicIndic(juz)
    end
    local is_arabic = juz_display == "number_arabic" or juz_display == "name_arabic"
                      or juz_display == "name_arabic_with_juz"
                      or juz_display == "ordinal_arabic"
    return juz_str, is_arabic
end

--- Build display string with juz and optional surah.
-- @param opts table with keys: juz_display, show_surah, surah_display
function Quran:_buildDisplayString(opts)
    local juz, boundary = self:_getCurrentJuz()
    if not juz then return end

    local mark = boundary and "*" or ""
    local juz_str, is_arabic = self:_formatJuzString(juz, opts.juz_display)

    local segments = { juz_str .. mark }

    -- Hizb (half-juz, #13): follows the juz format's script
    if opts.show_hizb then
        local hizb = self:_getCurrentHizb()
        if hizb then
            if is_arabic then
                table.insert(segments, "\216\173\216\178\216\168 " .. toArabicIndic(hizb))
            else
                table.insert(segments, "Hizb " .. hizb)
            end
        end
    end

    -- Surah name (always last)
    if opts.show_surah then
        local surah = self:_getCurrentSurah()
        if surah then
            local surah_name
            local use_arabic = opts.surah_display == "arabic"
                or opts.surah_display == "arabic_with_surat"
                or (opts.surah_display == "auto" and is_arabic)
            if use_arabic then
                surah_name = SURAH_NAMES_ARABIC[surah]
                if surah_name and opts.surah_display == "arabic_with_surat" then
                    surah_name = "سورة " .. surah_name
                end
            else
                surah_name = SURAH_NAMES[surah]
                if surah_name and opts.surah_display == "latin_with_surat" then
                    surah_name = "Surat " .. surah_name
                end
            end
            if surah_name then
                table.insert(segments, surah_name)
            end
        end
    end

    local result = table.concat(segments, " · ")

    -- Wrap RTL if juz format is Arabic, OR if surah name is Arabic
    local surah_is_arabic = opts.surah_display == "arabic" or opts.surah_display == "arabic_with_surat"
        or (opts.surah_display == "auto" and is_arabic)
    local needs_bidi = is_arabic or (surah_is_arabic and opts.show_surah)
    if needs_bidi then
        return BD.wrap(result)
    else
        return result
    end
end

--- Format display string for footer status bar.
function Quran:_getJuzFooterString()
    return self:_buildDisplayString({
        juz_display = self.settings:readSetting("juz_display", "number_arabic"),
        show_hizb = self.settings:isTrue("show_hizb_in_footer"),
        show_surah = self.settings:isTrue("show_surah_in_footer"),
        surah_display = self.settings:readSetting("surah_display", "auto"),
    })
end


--- Get current surah number (cached per page).
function Quran:_getCurrentSurah()
    if not self.ui or not self.ui.document then return nil end
    if self.ui.document.info and self.ui.document.info.has_pages then return nil end
    local pageno = self.ui.document:getCurrentPage()
    if not pageno then return nil end
    if self._cached_surah_pg == pageno then
        return self._cached_surah
    end
    local surah_num = self:_findSurahForPage(pageno)
    self._cached_surah = surah_num
    self._cached_surah_pg = pageno
    return surah_num
end

--- Invalidate caches on page turn.
-- v1.12 hub: gesture-assignable events (registered in quran_actions.lua).
-- Handlers gate on _is_quran_book so gestures are inert in other books.
function Quran:onQuranQuickPanel()
    local mod = self:_actionsModule()
    if mod then mod.showQuickPanel(self) end
    return true
end

function Quran:onQuranAyahLookup()
    local mod = self:_actionsModule()
    if mod and self._is_quran_book then mod.openAyahLookup(self) end
    return true
end

function Quran:onQuranSurahOverview()
    local mod = self:_actionsModule()
    if mod and self._is_quran_book then mod.openSurahOverview(self) end
    return true
end

function Quran:onQuranToggleHeader()
    local mod = self:_actionsModule()
    if mod and self._is_quran_book then mod.toggleHeader(self) end
    return true
end

function Quran:onQuranToggleJuzFooter()
    local mod = self:_actionsModule()
    if mod and self._is_quran_book then mod.toggleJuzFooter(self) end
    return true
end

function Quran:onQuranBrowser()
    local mod = self:_actionsModule()
    if mod then mod.showBrowser(self) end
    return true
end

function Quran:onPageUpdate()
    self._cached_pageno = nil
    self._cached_juz = nil
    self._cached_boundary = nil
    self._cached_surah_pg = nil
    self._cached_surah = nil
end

function Quran:onPosUpdate()
    self._cached_pageno = nil
    self._cached_juz = nil
    self._cached_boundary = nil
    self._cached_surah_pg = nil
    self._cached_surah = nil
end

--- Re-resolve cached page mappings after a re-pagination (font size,
-- margins, line spacing...) -- all boundary pages shift. Without this the
-- juz/hizb footer showed stale numbers until the book was reopened.
function Quran:onDocumentRerendered()
    logger.info("quran.koplugin: document rerendered -- caches invalidated")
    self._juz_toc_pages = nil
    self._hizb_pages = nil
    self._cached_pageno = nil
    self._cached_juz = nil
    self._cached_boundary = nil
    self._cached_surah_pg = nil
    self._cached_surah = nil
    self._last_logged_hizb = nil
end

-- Status bar registration helpers (following ReadTimer pattern)

function Quran:_addFooterContent()
    if self.ui.view then
        self.ui.view.footer:addAdditionalFooterContent(self.additional_footer_content_func)
        UIManager:broadcastEvent(Event:new("UpdateFooter", true))
    end
end

function Quran:_removeFooterContent()
    if self.ui.view then
        self.ui.view.footer:removeAdditionalFooterContent(self.additional_footer_content_func)
        UIManager:broadcastEvent(Event:new("UpdateFooter", true))
    end
end


-- ---------------------------------------------------------------------------
-- Header overlay (pure Lua, independent of CREngine alt status bar)
-- ---------------------------------------------------------------------------

--- Hook ReaderView.paintTo to draw our header overlay after normal rendering.
function Quran:_setupHeaderOverlay()
    if self._header_overlay_hooked then return end
    self._header_overlay_hooked = true

    local quran = self
    local orig_paintTo = self.ui.view.paintTo
    self.ui.view.paintTo = function(view_self, bb, x, y)
        orig_paintTo(view_self, bb, x, y)
        if quran._header_overlay_enabled and quran._is_quran_book then
            quran:_drawHeaderOverlay(bb, x, y)
        end
        -- in-book marking overlay (D-R2-5) — same hook, view-only
        if quran._is_quran_book then
            local marks = quran:_marksModule()
            if marks and marks.anyEnabled(quran) then
                marks.drawMarks(quran, bb, x, y)
            end
        end
    end
end

--- Build and paint the header overlay: surah (left) — juz (right).
function Quran:_drawHeaderOverlay(bb, x, y)
    local screen_width = Screen:getWidth()
    local margin = Math.round(screen_width * 0.02) -- 2% side margins

    -- Font size from settings
    local font_size = self.settings:readSetting("header_font_size", 13)
    local face = Font:getFace("cfont", font_size)

    -- Text color from gray level setting (0 = black, 10 = light gray)
    local gray_level = self.settings:readSetting("header_text_gray", 5)
    local gray_byte = math.min(gray_level * 25, 250)
    local text_color = Blitbuffer.colorFromString(string.format("#%02x%02x%02x", gray_byte, gray_byte, gray_byte))

    -- Build left side (surah)
    local left_text = nil
    if self.settings:nilOrTrue("header_show_surah") then
        local surah = self:_getCurrentSurah()
        if surah then
            local surah_display = self.settings:readSetting("header_surah_display", "arabic_with_surat")
            local surah_name
            if surah_display == "arabic" then
                surah_name = SURAH_NAMES_ARABIC[surah]
            elseif surah_display == "arabic_with_surat" then
                surah_name = SURAH_NAMES_ARABIC[surah]
                if surah_name then surah_name = "سورة " .. surah_name end
            elseif surah_display == "latin_with_surat" then
                surah_name = SURAH_NAMES[surah]
                if surah_name then surah_name = "Surat " .. surah_name end
            elseif surah_display == "latin" then
                surah_name = SURAH_NAMES[surah]
            else -- auto: default to arabic for header
                surah_name = SURAH_NAMES_ARABIC[surah]
            end
            if surah_name then
                left_text = BD.auto(surah_name)
            end
        end
    end

    -- Build right side (juz [+ hizb], same middot join as the footer)
    local right_text = nil
    local juz, boundary = self:_getCurrentJuz()
    if juz then
        local mark = boundary and "*" or ""
        local juz_display = self.settings:readSetting("header_juz_display", "ordinal_arabic")
        local juz_str, is_arabic = self:_formatJuzString(juz, juz_display)
        local txt = juz_str .. mark
        if self.settings:isTrue("show_hizb_in_header") then
            local hizb = self:_getCurrentHizb()
            if hizb then
                if is_arabic then
                    txt = txt .. " \194\183 \216\173\216\178\216\168 " .. toArabicIndic(hizb)
                else
                    txt = txt .. " \194\183 Hizb " .. hizb
                end
            end
        end
        right_text = BD.auto(txt)
    end

    if not left_text and not right_text then return end

    -- Create text widgets
    local max_item_width = math.floor((screen_width - margin * 3) / 2)
    local left_widget = left_text and TextWidget:new{
        text = left_text,
        face = face,
        max_width = max_item_width,
        fgcolor = text_color,
        padding = 0,
    }
    local right_widget = right_text and TextWidget:new{
        text = right_text,
        face = face,
        max_width = max_item_width,
        fgcolor = text_color,
        padding = 0,
    }

    -- Calculate layout
    local left_w = left_widget and left_widget:getSize().w or 0
    local right_w = right_widget and right_widget:getSize().w or 0
    local spacer_w = math.max(0, screen_width - margin * 2 - left_w - right_w)

    -- Build horizontal group
    local items = {}
    table.insert(items, HorizontalSpan:new{ width = margin })
    if left_widget then
        table.insert(items, left_widget)
    end
    table.insert(items, HorizontalSpan:new{ width = spacer_w })
    if right_widget then
        table.insert(items, right_widget)
    end

    local header_height = math.max(
        left_widget and left_widget:getSize().h or 0,
        right_widget and right_widget:getSize().h or 0
    )

    local header = HorizontalGroup:new(items)
    header:paintTo(bb, x, y)

    -- Free widgets
    header:free()
end

--- Minimum unscaled top margin that keeps page text clear of the header
-- bar: one line-height plus a small gap. Same units as KOReader's margin
-- config — both margins and the header font go through Screen:scaleBySize,
-- so the arithmetic holds on every DPI.
function Quran:_headerMarginNeeded()
    local font_size = self.settings:readSetting("header_font_size", 13)
    return Math.round(font_size * 1.5) + 4
end

--- Raise the document top margin to clear the header bar (auto-margin
-- option, Quran books only). Since 2026-07-16 this post-render path is
-- the FALLBACK — onPreRenderDocument (below) normally raises the margin
-- before the initial render, so this early-returns (current >= needed);
-- it still covers KOReader versions without the PreRenderDocument event.
-- Only ever raises: a user margin that already clears the bar is left
-- alone. The pre-bump value is remembered in the book's own settings so
-- turning the header (or this option) off restores it. Fires KOReader's
-- own SetPageTopMargin event, so sync-T/B-margins and sidecar
-- persistence behave exactly as if set from the margin dialog.
--
-- LOOP GUARD (owner bug 2026-07-12, Android): the raise happens AFTER the
-- document is rendered, so it forces a full re-render — acceptable ONCE,
-- but when the raised margin does not persist across opens (KOReader's
-- per-book document settings off → the global margin reapplies at every
-- load; or the user deliberately lowered it again) re-raising would
-- re-render on EVERY open and invalidate the render cache each time:
-- every open became a full re-parse, slower than a true first open. The
-- pre-bump marker doubles as the guard: marker present + margin low
-- again = the raise didn't stick — draw the bar without raising and say
-- so once EVER (flag persisted in plugin settings: a per-session flag
-- reset on every Android process restart, where each open is often a
-- fresh process, so the notice nagged on every open — owner report
-- 2026-07-16) instead of fighting the settings forever.
function Quran:_applyHeaderMargin()
    if not self._is_quran_book then return end
    if not self.settings:nilOrTrue("header_auto_margin") then return end
    local configurable = self.ui.document and self.ui.document.configurable
    if not configurable or not self.ui.doc_settings then return end
    local needed = self:_headerMarginNeeded()
    local current = configurable.t_page_margin
    if not current or current >= needed then return end
    if self.ui.doc_settings:readSetting("quran_pre_header_t_margin") ~= nil then
        logger.info("quran.koplugin: header auto-margin did not persist — "
            .. "not re-raising (loop guard)")
        if not self.settings:isTrue("header_margin_notice_shown") then
            self.settings:saveSetting("header_margin_notice_shown", true)
            self.settings:flush()
            local UIManager = require("ui/uimanager")
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("KOReader is not keeping the extra top margin the Quran header bar needs on this device, so the bar may overlap the first line of text.\nTo fix it, raise the top margin slightly yourself, or enable per-book document settings.\nThis notice will not be shown again."),
                timeout = 10,
            })
        end
        return
    end
    self.ui.doc_settings:saveSetting("quran_pre_header_t_margin", current)
    logger.dbg("quran.koplugin: header auto-margin", current, "->", needed)
    self.ui:handleEvent(Event:new("SetPageTopMargin", needed))
end

--- Apply the header top margin BEFORE the initial render (margin round,
-- owner 2026-07-16: text starts under the header bar on non-surah
-- pages). PreRenderDocument fires after loadDocument (doc_props ready →
-- detection works) and before document:render(), and KOReader's own
-- init path fires the margin events pre-render too — so raising here
-- costs NOTHING: the first render already includes the margin, no
-- re-render, no cache invalidation. On setups where the raise never
-- persists (per-book settings off — the F1/Android loop-guard case)
-- this re-raises every open for free, so the post-render path below
-- becomes a fallback for KOReader versions without this event.
function Quran:onPreRenderDocument()
    if self._is_quran_book == nil then
        self._is_quran_book = self:_detectQuranBook()
    end
    if not self._is_quran_book then return end
    if not self.settings:isTrue("show_header_overlay") then return end
    if not self.settings:nilOrTrue("header_auto_margin") then return end
    local configurable = self.ui.document and self.ui.document.configurable
    if not configurable or not self.ui.doc_settings then return end
    local needed = self:_headerMarginNeeded()
    local current = configurable.t_page_margin
    if not current or current >= needed then return end
    if self.ui.doc_settings:readSetting("quran_pre_header_t_margin") == nil then
        self.ui.doc_settings:saveSetting("quran_pre_header_t_margin", current)
    end
    logger.dbg("quran.koplugin: header margin pre-render", current, "->", needed)
    self.ui:handleEvent(Event:new("SetPageTopMargin", needed))
end

--- Undo _applyHeaderMargin (header bar or auto-margin turned off).
function Quran:_restoreHeaderMargin()
    if not self.ui.doc_settings then return end
    local orig = self.ui.doc_settings:readSetting("quran_pre_header_t_margin")
    if orig == nil then return end
    self.ui.doc_settings:delSetting("quran_pre_header_t_margin")
    logger.dbg("quran.koplugin: header auto-margin restore ->", orig)
    self.ui:handleEvent(Event:new("SetPageTopMargin", orig))
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

--- Batch sidecar restore for the current folder (menu + quick panel).
function Quran:restoreBookData()
    local InfoMessage = require("ui/widget/infomessage")
    local dir, skip
    if self.ui.document and self.ui.document.file then
        skip = self.ui.document.file
        dir = skip:match("^(.*)/[^/]+$")
    elseif self.ui.file_chooser and self.ui.file_chooser.path then
        dir = self.ui.file_chooser.path
    end
    if not dir then
        UIManager:show(InfoMessage:new{
            text = _("Could not determine the current folder."),
        })
        return
    end
    local migrated, found = self:_migrateSidecarsInDir(dir, skip)
    local msg
    if not self:_renameMap() then
        msg = _("Rename map missing — reinstall the plugin.")
    elseif found == 0 then
        msg = _("No old reading data found for renamed books in this folder.")
    else
        msg = string.format(
            _("Restored reading data for %d of %d renamed book(s)."),
            migrated, found)
    end
    UIManager:show(InfoMessage:new{ text = msg })
end

function Quran:addToMainMenu(menu_items)
    -- Display labels for format pickers
    local juz_displays = {
        number_arabic = "جزء ٣٠",
        name_arabic_with_juz = "جزء عم",
        ordinal_arabic = "الجزء الثلاثون",
        name_arabic = "عم",
        number_latin = "Juz 30",
        name_latin_with_juz = "Juz' 'Amma",
        name_latin = "'Amma",
    }
    local surah_displays = {
        auto = _("auto"),
        arabic = "الفاتحة",
        arabic_with_surat = "سورة الفاتحة",
        latin = "Al-Fatihah",
        latin_with_surat = "Surat Al-Fatihah",
    }

    -- Helper: build juz format radio items for a given settings key
    local function juzFormatItems(key, default, update_footer, update_header)
        local function save(value)
            self.settings:saveSetting(key, value)
            self.settings:flush()
            if update_footer then UIManager:broadcastEvent(Event:new("UpdateFooter", true)) end
            if update_header then UIManager:broadcastEvent(Event:new("UpdateHeader")) end
        end
        return {
            {
                text = "جزء ١، جزء ٢، ... جزء ٣٠",
                checked_func = function() return self.settings:readSetting(key, default) == "number_arabic" end,
                radio = true,
                callback = function() save("number_arabic") end,
            },
            {
                text = "جزء عم، جزء تبارك، ... جزء آلم",
                checked_func = function() return self.settings:readSetting(key, default) == "name_arabic_with_juz" end,
                radio = true,
                callback = function() save("name_arabic_with_juz") end,
            },
            {
                text = "الجزء الأول، الجزء الثاني، ... الجزء الثلاثون",
                checked_func = function() return self.settings:readSetting(key, default) == "ordinal_arabic" end,
                radio = true,
                callback = function() save("ordinal_arabic") end,
            },
            {
                text = "عم، تبارك، ... آلم",
                checked_func = function() return self.settings:readSetting(key, default) == "name_arabic" end,
                radio = true,
                callback = function() save("name_arabic") end,
            },
            {
                text = "Juz 1, Juz 2, ... Juz 30",
                checked_func = function() return self.settings:readSetting(key, default) == "number_latin" end,
                radio = true,
                callback = function() save("number_latin") end,
            },
            {
                text = "Juz' 'Amma, Juz' Tabaraka, ... Juz' Alif Lam Mim",
                checked_func = function() return self.settings:readSetting(key, default) == "name_latin_with_juz" end,
                radio = true,
                callback = function() save("name_latin_with_juz") end,
            },
            {
                text = "'Amma, Tabaraka, ... Alif Lam Mim",
                checked_func = function() return self.settings:readSetting(key, default) == "name_latin" end,
                radio = true,
                callback = function() save("name_latin") end,
            },
        }
    end

    -- Helper: build surah format radio items for a given settings key
    local function surahFormatItems(key, default, update_footer, update_header)
        local function save(value)
            self.settings:saveSetting(key, value)
            self.settings:flush()
            if update_footer then UIManager:broadcastEvent(Event:new("UpdateFooter", true)) end
            if update_header then UIManager:broadcastEvent(Event:new("UpdateHeader")) end
        end
        return {
            {
                text = _("Auto (match juz format)"),
                help_text = _("Arabic name with Arabic juz formats, Latin name with Latin juz formats."),
                checked_func = function() return self.settings:readSetting(key, default) == "auto" end,
                radio = true,
                callback = function() save("auto") end,
            },
            {
                text = "الفاتحة، البقرة، ...",
                checked_func = function() return self.settings:readSetting(key, default) == "arabic" end,
                radio = true,
                callback = function() save("arabic") end,
            },
            {
                text = "سورة الفاتحة، سورة البقرة، ...",
                checked_func = function() return self.settings:readSetting(key, default) == "arabic_with_surat" end,
                radio = true,
                callback = function() save("arabic_with_surat") end,
            },
            {
                text = "Al-Fatihah, Al-Baqarah, ...",
                checked_func = function() return self.settings:readSetting(key, default) == "latin" end,
                radio = true,
                callback = function() save("latin") end,
            },
            {
                text = "Surat Al-Fatihah, Surat Al-Baqarah, ...",
                checked_func = function() return self.settings:readSetting(key, default) == "latin_with_surat" end,
                radio = true,
                callback = function() save("latin_with_surat") end,
            },
        }
    end

    -- Helper: paging-direction radio items (Round-2 F3 + D-R2-7b) —
    -- rendered from the reader module's PAGING_MODES so the settings
    -- radio and the title-bar quick menus can never drift apart.
    local function readerPagingItems()
        local reader = self:_readerModule()
        local modes = (reader and reader.PAGING_MODES) or {}
        local function save(value)
            if reader and reader.setPagingMode then
                reader.setPagingMode(value)
            else
                self.settings:saveSetting("reader_paging_mode", value)
                self.settings:flush()
            end
        end
        local items = {}
        for _i, m in ipairs(modes) do
            table.insert(items, {
                text = m.label,
                help_text = m.help,
                checked_func = function()
                    return self.settings:readSetting(
                        "reader_paging_mode", "auto") == m.value
                end,
                radio = true,
                callback = function() save(m.value) end,
            })
        end
        return items
    end

    menu_items.quran = {
        text = _("Quran Helper"),
        sorting_hint = "tools",
        sub_item_table = {
            -- v1.12 hub: the quick panel (also gesture-assignable)
            {
                text = _("Quick panel"),
                help_text = _("Actions for the current position: ayah tafsir & resources, surah overview, display toggles. Also assignable to a gesture (Taps and gestures → Quran: quick panel)."),
                callback = function()
                    local mod = self:_actionsModule()
                    if mod then mod.showQuickPanel(self) end
                end,
            },
            {
                text = _("Quran browser"),
                help_text = _("Browse surahs, juz, and the current ayah's resources in one window. Also assignable to a gesture (Taps and gestures → Quran: browser)."),
                callback = function()
                    local mod = self:_actionsModule()
                    if mod then mod.showBrowser(self) end
                end,
            },
            -- Grammar dictionary lookup toggle
            {
                text = _("Quran lookups"),
                help_text = _("Long-press ayah markers, words, or surah headers to look up grammar, word-by-word, tafsir, and surah overviews. Requires the Quran StarDict dictionaries in data/dict/. Turning this off disables all Quran-specific lookup handling."),
                checked_func = function()
                    return self.settings:nilOrTrue("grammar_lookup")
                end,
                callback = function()
                    if self.settings:nilOrTrue("grammar_lookup") then
                        self.settings:saveSetting("grammar_lookup", false)
                    else
                        self.settings:saveSetting("grammar_lookup", true)
                    end
                    self.settings:flush()
                end,
            },
            -- Reading-window paging direction (Round-2 F3)
            {
                text_func = function()
                    local labels = {
                        auto = _("match book"),
                        standard = _("standard"),
                        inverted = _("mushaf-style"),
                        content = _("follow content"),
                    }
                    local cur = self.settings:readSetting(
                        "reader_paging_mode", "auto")
                    return _("Paging direction: ")
                        .. (labels[cur] or labels.auto)
                end,
                help_text = _("Tap and swipe paging direction in the plugin's reading window and browser. Also reachable from those screens' title-bar menus. Hardware page-turn buttons and dictionary-popup swipes follow KOReader's own settings."),
                sub_item_table = readerPagingItems(),
            },
            -- Quran dictionary order (D-R2-4 slice)
            {
                text = _("Quran dictionary order"),
                help_text = _("Reorder the Quran dictionaries (word, grammar, tafsirs, …) without the global manage-dictionaries screen. Controls the popup's result order and which dictionary shows first."),
                callback = function() self:showQuranDictOrder() end,
            },
            -- Ayah-marker long-press action (D-R2-4a)
            {
                text_func = function()
                    local labels = {
                        popup = _("resources popup"),
                        tafsir = _("preferred tafsir"),
                        ayah_page = _("ayah page"),
                        translation = _("translation"),
                    }
                    local cur = self.settings:readSetting(
                        "ayah_longpress_action", "popup")
                    return _("Ayah long-press opens: ")
                        .. (labels[cur] or labels.popup)
                end,
                help_text = _("What a long-press on an ayah marker opens. Anything unavailable falls back to the resources popup."),
                sub_item_table = (function()
                    local function item(value, label, help)
                        return {
                            text = label,
                            help_text = help,
                            checked_func = function()
                                return self.settings:readSetting(
                                    "ayah_longpress_action", "popup") == value
                            end,
                            radio = true,
                            callback = function()
                                self.settings:saveSetting(
                                    "ayah_longpress_action", value)
                                self.settings:flush()
                            end,
                        }
                    end
                    return {
                        item("popup", _("Resources popup"),
                            _("The multi-dictionary popup with every ayah-keyed resource (default).")),
                        item("tafsir", _("Preferred tafsir"),
                            _("Straight into the reading window (a picker appears on first use; hold the panel's Tafsir button to change it later).")),
                        item("ayah_page", _("Ayah page (browser)"),
                            _("The unified ayah page: text, tafsir, connections.")),
                        item("translation", _("Text & translation"),
                            _("The ayah in the reading window (needs the Quran text package).")),
                    }
                end)(),
            },
            -- In-book marking (design D-R2-5): layer toggles + the C3
            -- style switcher (owner judges styles on real pages)
            {
                text = _("In-book marking"),
                help_text = _("Mark ayahs on the page by connection layer — mutashabihat phrases, theme starts, similar ayahs. View-only: nothing is saved into your annotations. Toggles also live in the quick panel."),
                sub_item_table = (function()
                    local items = {}
                    local marks = self:_marksModule()
                    if not marks then return items end
                    for _i, l in ipairs(marks.LAYERS) do
                        local key = l.key
                        table.insert(items, {
                            text = l.label,
                            checked_func = function()
                                return marks.enabled(self, key)
                            end,
                            callback = function()
                                marks.setEnabled(self, key,
                                    not marks.enabled(self, key))
                            end,
                        })
                    end
                    for _i, l in ipairs(marks.LAYERS) do
                        local key = l.key
                        local style_items = {}
                        for _j, st in ipairs(marks.STYLES) do
                            local sk = st.key
                            table.insert(style_items, {
                                text = st.label,
                                checked_func = function()
                                    return marks.styleFor(self, key) == sk
                                end,
                                radio = true,
                                callback = function()
                                    marks.setStyle(self, key, sk)
                                end,
                            })
                        end
                        table.insert(items, {
                            text_func = function()
                                local cur = marks.styleFor(self, key)
                                local label = cur
                                for _j, st in ipairs(marks.STYLES) do
                                    if st.key == cur then label = st.label end
                                end
                                return l.label .. " " .. _("style") .. ": "
                                    .. label:lower()
                            end,
                            sub_item_table = style_items,
                        })
                    end
                    return items
                end)(),
            },
            -- Footer status bar submenu
            {
                text = _("Status bar"),
                sub_item_table = {
                    {
                        text = _("Show juz in status bar"),
                        help_text = _("Shows current juz in the footer status bar. Requires 'External content' to be enabled in Status bar settings (top menu → gear icon → Status bar → Status bar items → toggle 'External content')."),
                        checked_func = function()
                            return self.settings:nilOrTrue("show_juz_in_footer")
                        end,
                        callback = function()
                            if self.settings:nilOrTrue("show_juz_in_footer") then
                                self.settings:saveSetting("show_juz_in_footer", false)
                                self:_removeFooterContent()
                            else
                                self.settings:saveSetting("show_juz_in_footer", true)
                                self:_addFooterContent()
                            end
                            self.settings:flush()
                        end,
                    },
                    {
                        text_func = function()
                            local current = self.settings:readSetting("juz_display", "number_arabic")
                            return _("Juz format: ") .. (juz_displays[current] or "جزء ٣٠")
                        end,
                        help_text = _("Choose how the juz is displayed in the footer status bar. An asterisk (*) appears at juz boundaries."),
                        enabled_func = function()
                            return self.settings:nilOrTrue("show_juz_in_footer")
                        end,
                        sub_item_table = juzFormatItems("juz_display", "number_arabic", true, false),
                    },
                    {
                        text = _("Show hizb"),
                        help_text = _("Temporarily disabled: hizb resolution shows wrong numbers (under investigation). Your setting is preserved."),
                        enabled_func = function()
                            return HIZB_FEATURE_ENABLED
                                and self.settings:nilOrTrue("show_juz_in_footer")
                        end,
                        checked_func = function()
                            return self.settings:isTrue("show_hizb_in_footer")
                        end,
                        callback = function()
                            self.settings:saveSetting("show_hizb_in_footer",
                                not self.settings:isTrue("show_hizb_in_footer"))
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = _("Append surah name"),
                        help_text = _("Appends the current surah name after the juz display (e.g. 'جزء ١ · الفاتحة')."),
                        enabled_func = function()
                            return self.settings:nilOrTrue("show_juz_in_footer")
                        end,
                        checked_func = function()
                            return self.settings:isTrue("show_surah_in_footer")
                        end,
                        callback = function()
                            if self.settings:isTrue("show_surah_in_footer") then
                                self.settings:saveSetting("show_surah_in_footer", false)
                            else
                                self.settings:saveSetting("show_surah_in_footer", true)
                            end
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text_func = function()
                            local current = self.settings:readSetting("surah_display", "auto")
                            return _("Surah format: ") .. (surah_displays[current] or _("auto"))
                        end,
                        help_text = _("Choose how the surah name is displayed in the footer. 'Auto' matches the juz format language."),
                        enabled_func = function()
                            return self.settings:nilOrTrue("show_juz_in_footer")
                                and self.settings:isTrue("show_surah_in_footer")
                        end,
                        sub_item_table = surahFormatItems("surah_display", "auto", true, false),
                    },
                },
            },
            -- Header overlay submenu
            {
                text = _("Header bar"),
                sub_item_table = {
                    {
                        text = _("Show header bar"),
                        help_text = _("Shows surah name (left) and juz info (right) at the top of the page. This is an overlay — adjust the book's top margin to avoid overlap."),
                        checked_func = function()
                            return self.settings:isTrue("show_header_overlay")
                        end,
                        callback = function()
                            if self.settings:isTrue("show_header_overlay") then
                                self.settings:saveSetting("show_header_overlay", false)
                                self._header_overlay_enabled = false
                                self:_restoreHeaderMargin()
                            else
                                self.settings:saveSetting("show_header_overlay", true)
                                self._header_overlay_enabled = true
                                self:_applyHeaderMargin()
                            end
                            self.settings:flush()
                            UIManager:setDirty(self.ui.view, "ui")
                        end,
                    },
                    {
                        text_func = function()
                            local current = self.settings:readSetting("header_juz_display", "ordinal_arabic")
                            return _("Juz format: ") .. (juz_displays[current] or "الجزء الثلاثون")
                        end,
                        help_text = _("Choose how the juz is displayed in the header bar. An asterisk (*) appears at juz boundaries."),
                        enabled_func = function()
                            return self.settings:isTrue("show_header_overlay")
                        end,
                        sub_item_table = juzFormatItems("header_juz_display", "ordinal_arabic", false, false),
                    },
                    {
                        text = _("Show hizb"),
                        help_text = _("Temporarily disabled: hizb resolution shows wrong numbers (under investigation). Your setting is preserved."),
                        enabled_func = function()
                            return HIZB_FEATURE_ENABLED
                                and self.settings:isTrue("show_header_overlay")
                        end,
                        checked_func = function()
                            return self.settings:isTrue("show_hizb_in_header")
                        end,
                        callback = function()
                            self.settings:saveSetting("show_hizb_in_header",
                                not self.settings:isTrue("show_hizb_in_header"))
                            self.settings:flush()
                            UIManager:setDirty("all", "ui")
                        end,
                    },
                    {
                        text = _("Show surah name"),
                        help_text = _("Shows the current surah name on the left side of the header bar."),
                        enabled_func = function()
                            return self.settings:isTrue("show_header_overlay")
                        end,
                        checked_func = function()
                            return self.settings:nilOrTrue("header_show_surah")
                        end,
                        callback = function()
                            if self.settings:nilOrTrue("header_show_surah") then
                                self.settings:saveSetting("header_show_surah", false)
                            else
                                self.settings:saveSetting("header_show_surah", true)
                            end
                            self.settings:flush()
                            UIManager:setDirty(self.ui.view, "ui")
                        end,
                    },
                    {
                        text_func = function()
                            local current = self.settings:readSetting("header_surah_display", "arabic_with_surat")
                            return _("Surah format: ") .. (surah_displays[current] or "سورة الفاتحة")
                        end,
                        help_text = _("Choose how the surah name is displayed in the header bar."),
                        enabled_func = function()
                            return self.settings:isTrue("show_header_overlay")
                                and self.settings:nilOrTrue("header_show_surah")
                        end,
                        sub_item_table = surahFormatItems("header_surah_display", "arabic_with_surat", false, false),
                    },
                    {
                        text_func = function()
                            return _("Font size: ") .. self.settings:readSetting("header_font_size", 13)
                        end,
                        enabled_func = function()
                            return self.settings:isTrue("show_header_overlay")
                        end,
                        callback = function(touchmenu_instance)
                            local spin = SpinWidget:new{
                                value = self.settings:readSetting("header_font_size", 13),
                                value_min = 8,
                                value_max = 30,
                                default_value = 13,
                                title_text = _("Header font size"),
                                callback = function(spin)
                                    self.settings:saveSetting("header_font_size", spin.value)
                                    self.settings:flush()
                                    if self._header_overlay_enabled then
                                        self:_applyHeaderMargin()
                                    end
                                    UIManager:setDirty(self.ui.view, "ui")
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            }
                            UIManager:show(spin)
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Auto top margin"),
                        help_text = _("Raises the page top margin when needed so the text clears the header bar (never lowers a larger margin you set yourself). The previous margin is restored when the header or this option is turned off."),
                        enabled_func = function()
                            return self.settings:isTrue("show_header_overlay")
                        end,
                        checked_func = function()
                            return self.settings:nilOrTrue("header_auto_margin")
                        end,
                        callback = function()
                            if self.settings:nilOrTrue("header_auto_margin") then
                                self.settings:saveSetting("header_auto_margin", false)
                                self:_restoreHeaderMargin()
                            else
                                self.settings:saveSetting("header_auto_margin", true)
                                if self._header_overlay_enabled then
                                    self:_applyHeaderMargin()
                                end
                            end
                            self.settings:flush()
                        end,
                    },
                    {
                        text_func = function()
                            local gray = self.settings:readSetting("header_text_gray", 5)
                            if gray == 0 then
                                return _("Text gray: black")
                            else
                                return _("Text gray: ") .. gray
                            end
                        end,
                        help_text = _("Adjust text lightness. 0 = black, 10 = light gray. Default 5."),
                        enabled_func = function()
                            return self.settings:isTrue("show_header_overlay")
                        end,
                        callback = function(touchmenu_instance)
                            local spin = SpinWidget:new{
                                value = self.settings:readSetting("header_text_gray", 5),
                                value_min = 0,
                                value_max = 10,
                                default_value = 5,
                                title_text = _("Header text gray level"),
                                info_text = _("0 = black, 10 = light gray"),
                                callback = function(spin)
                                    self.settings:saveSetting("header_text_gray", spin.value)
                                    self.settings:flush()
                                    UIManager:setDirty(self.ui.view, "ui")
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            }
                            UIManager:show(spin)
                        end,
                        keep_menu_open = true,
                    },
                },
            },
            -- Sidecar migration after the filename sweep (decision N1)
            {
                text = _("Restore book data after update"),
                help_text = _("After downloading renamed editions of the Quran EPUBs, this copies your reading data (highlights, progress) from the old filenames to the new ones. Acts on the current folder; run it from the file browser with the books closed."),
                callback = function()
                    self:restoreBookData()
                end,
            },
        },
    }
end

return Quran
