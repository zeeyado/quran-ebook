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

-- Reverse lookup: surah name -> surah number
local SURAH_NAME_TO_NUM = {}
for i, name in ipairs(SURAH_NAMES) do
    SURAH_NAME_TO_NUM[name] = i
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

local function applyMonkeyPatches()
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

    -- Patch 3: ReaderDictionary.showDict — in-place update for Quran nav
    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    local orig_showDict = ReaderDictionary.showDict
    ReaderDictionary.showDict = function(self_dict, word, results, boxes, link, dict_close_callback)
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
    local orig_onLookupWord = ReaderDictionary.onLookupWord
    ReaderDictionary.onLookupWord = function(self_dict, word, ...)
        if word then
            word = normalizeQpcTanween(word)
        end
        return orig_onLookupWord(self_dict, word, ...)
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
    self._is_quran_book = nil    -- true if current book is a quran-ebook EPUB
    self._status_bar_registered = false
    LanguageSupport:registerPlugin(self)
    applyMonkeyPatches()

    -- Persistent settings
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/quran.lua")

    -- Juz status bar content function (closure captures self)
    self.additional_footer_content_func = function()
        if not self._is_quran_book then return end
        if not self.settings:nilOrTrue("show_juz_in_footer") then return end
        return self:_getJuzFooterString()
    end

    -- Alt status bar (header) content function
    self.additional_header_content_func = function()
        if not self._is_quran_book then return end
        if not self.settings:nilOrTrue("show_juz_in_header") then return end
        return self:_getJuzHeaderString()
    end

    self.ui.menu:registerToMainMenu(self)
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
            logger.dbg("quran.koplugin: detected Quran book via metadata")
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
    end
end

--- [LEGACY] Re-apply header space hack when alt status bar is toggled.
-- Kept for reference but no longer called — overlay approach doesn't need this.
function Quran:onSetStatusLine()
    -- The overlay header is independent of CREngine's alt status bar,
    -- so no action needed here.
end

function Quran:supportsLanguage(language_code)
    if not self.settings:nilOrTrue("grammar_lookup") then return false end
    return language_code == "ar" or language_code == "ara"
end

--- Find surah number and name for a given position by searching the TOC.
function Quran:_findSurahForPosition(pos)
    local toc = self.ui.toc
    if not toc then return nil, nil end

    toc:fillToc()
    local toc_list = toc.toc
    if not toc_list or #toc_list == 0 then return nil, nil end

    local doc = self.ui.document
    if not doc then return nil, nil end

    local pageno = doc:getPageFromXPointer(pos)

    local best_surah = nil
    local best_name = nil
    for _, entry in ipairs(toc_list) do
        if entry.page and entry.page <= pageno and entry.title then
            local title = toc:cleanUpTocTitle(entry.title)
            local surah_num, surah_name = extractSurahInfo(title)
            if surah_num then
                best_surah = surah_num
                best_name = surah_name
            end
        end
    end

    if best_surah then
        logger.dbg("quran.koplugin: page", pageno, "-> surah", best_surah, best_name)
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
    -- into subsequent non-Quran lookups (onDictButtonsReady would
    -- otherwise patch a normal word popup's buttons away).
    self._last_ayah_surah = nil
    self._last_ayah_num = nil
    self._last_overview_surah = nil

    -- Stash raw XPointers for per-instance dictionary matching
    -- (no CREngine calls here — detection deferred to onDictButtonsReady)
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

    logger.dbg("quran.koplugin: lookup surah=" .. surah .. " ayah=" .. ayah)

    local candidates = {}
    local name = surah_name or SURAH_NAMES[surah]
    if name then
        table.insert(candidates, name .. " " .. ayah)
    end
    table.insert(candidates, string.format("%03d:%03d", surah, ayah))

    -- Stash for onDictButtonsReady
    self._last_ayah_surah = surah
    self._last_ayah_num = ayah

    -- Flag next DictQuickLookup for medium-height Quran window
    DictQuickLookup._quran_next_lookup = true

    logger.dbg("quran.koplugin: lookup candidates:", candidates)
    return candidates
end

--- Navigate to a specific ayah. Updates the popup in-place.
function Quran:_lookupAyah(surah, ayah, dict_popup)
    local name = SURAH_NAMES[surah]
    if not name then return end

    local key = name .. " " .. ayah
    logger.dbg("quran.koplugin: navigating to", key)

    -- Pre-stash for onDictButtonsReady (won't fire for in-place update,
    -- but needed if showDict falls through to creating a new popup)
    self._last_ayah_surah = surah
    self._last_ayah_num = ayah

    -- Update mutable state on popup (button callbacks reference these)
    dict_popup._quran_surah = surah
    dict_popup._quran_ayah = ayah

    -- Update button enable/disable states
    local has_prev = ayah > 1 or surah > 1
    local has_next = ayah < (SURAH_AYAH_COUNTS[surah] or 0) or surah < 114
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
-- @param buttons Buttons table from onDictButtonsReady
-- @param settings LuaSettings instance
local function setupQuranPopup(dict_popup, buttons, settings)
    if DictQuickLookup._quran_next_lookup then
        DictQuickLookup._quran_next_lookup = nil
    end
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

--- Called when dictionary popup buttons are ready.
-- For Quran lookups: replace buttons with custom nav/scroll,
-- override key handlers, flag popup for medium height.
function Quran:onDictButtonsReady(dict_popup, buttons)
    DictQuickLookup.temp_large_window_request = nil

    -- Per-instance word dictionary matching: select the correct entry
    -- based on detected surah:ayah position
    local word_pos0 = self._stashed_word_pos0
    local word_pos1 = self._stashed_word_pos1
    self._stashed_word_pos0 = nil
    self._stashed_word_pos1 = nil

    if word_pos0 and word_pos1 and dict_popup.results and #dict_popup.results > 1 then
        logger.info("QURAN: instance match:", #dict_popup.results, "results")
        local det_surah, det_ayah = self:_detectAyahFromXPointer(word_pos0, word_pos1)
        if det_surah and det_ayah then
            local ref_prefix = det_surah .. ":" .. det_ayah .. ":"
            -- Filter results to only those whose ref matches this ayah
            local filtered = {}
            for _, result in ipairs(dict_popup.results) do
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
                logger.info("QURAN: filtered", #dict_popup.results, "->", #filtered, "results")
                -- Defer update to after init() completes, then rebuild popup
                UIManager:scheduleIn(0, function()
                    dict_popup.results = filtered
                    dict_popup:changeDictionary(1)
                end)
            else
                logger.info("QURAN: no ref matched prefix", ref_prefix)
            end
        end
    end

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
        if not DictQuickLookup._quran_next_lookup then return end

        local overview_surah = self._last_overview_surah
        self._last_overview_surah = nil

        logger.dbg("quran.koplugin: patching surah overview popup for surah", overview_surah)
        setupQuranPopup(dict_popup, buttons, self.settings)
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
    setupQuranPopup(dict_popup, buttons, self.settings)

    -- Store mutable state for button callbacks and key handlers
    dict_popup._quran_surah = surah
    dict_popup._quran_ayah = ayah

    local has_prev = ayah > 1 or surah > 1
    local has_next = ayah < (SURAH_AYAH_COUNTS[surah] or 0) or surah < 114

    -- Button rows:
    -- Row 1: [⇱] [◁/▷] [TXT ON/OFF] [▷/◁] [⇲]
    -- Row 2: [Close]
    -- Direction follows KOReader's inverse_reading_order setting
    local left_btn, right_btn = navButtons(self, {
        id = "next_ayah",
        enabled = has_next,
        vsync = true,
        callback = function()
            local s = dict_popup._quran_surah
            local a = dict_popup._quran_ayah + 1
            if a > (SURAH_AYAH_COUNTS[s] or 0) then
                s = s + 1; a = 1
            end
            if s <= 114 then
                self:_lookupAyah(s, a, dict_popup)
            end
        end,
    }, {
        id = "prev_ayah",
        enabled = has_prev,
        vsync = true,
        callback = function()
            local s = dict_popup._quran_surah
            local a = dict_popup._quran_ayah - 1
            if a < 1 then
                s = s - 1; a = SURAH_AYAH_COUNTS[s] or 1
            end
            if s >= 1 then
                self:_lookupAyah(s, a, dict_popup)
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

    -- Override volume/page-turn keys for ayah navigation
    dict_popup.onReadNextResult = function(self_dql)
        local s = self_dql._quran_surah
        local a = self_dql._quran_ayah + 1
        if a > (SURAH_AYAH_COUNTS[s] or 0) then
            s = s + 1; a = 1
        end
        if s <= 114 then
            self:_lookupAyah(s, a, self_dql)
        end
        return true
    end
    dict_popup.onReadPrevResult = function(self_dql)
        local s = self_dql._quran_surah
        local a = self_dql._quran_ayah - 1
        if a < 1 then
            s = s - 1; a = SURAH_AYAH_COUNTS[s] or 1
        end
        if s >= 1 then
            self:_lookupAyah(s, a, self_dql)
        end
        return true
    end

    -- Block VocabBuilder from adding its button
    return true
end

-- ---------------------------------------------------------------------------
-- Juz/Hizb status bar
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

--- Find the current surah number from reading position (page-based).
-- Lighter than _findSurahForPosition (no xpointer needed).
-- IMPORTANT: Uses entry.orig_page when available. KOReader's
-- validateAndFixToc() may corrupt surah entry page numbers because
-- our nav TOC has juz entries (high pages) before surah entries
-- (low pages), which triggers the "bogus page" fixer.
function Quran:_findSurahForPage(pageno)
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
local function toArabicIndic(n)
    local digits = {"٠","١","٢","٣","٤","٥","٦","٧","٨","٩"}
    local result = ""
    for ch in tostring(n):gmatch(".") do
        local d = tonumber(ch)
        result = result .. digits[d + 1]
    end
    return result
end

--- Build juz/surah display string (shared by footer and header).
-- @param juz_display string: format key (number_arabic, name_arabic, etc.)
-- @param show_surah bool: whether to append surah name
-- @param surah_display string: surah format key (auto, arabic, etc.)
function Quran:_buildDisplayString(juz_display, show_surah, surah_display)
    local juz, boundary = self:_getCurrentJuz()
    if not juz then return end

    local mark = boundary and "*" or ""

    local juz_part
    if juz_display == "name_arabic" then
        juz_part = (JUZ_NAMES_ARABIC[juz] or "")
    elseif juz_display == "name_arabic_with_juz" then
        juz_part = "جزء " .. (JUZ_NAMES_ARABIC[juz] or "")
    elseif juz_display == "ordinal_arabic" then
        juz_part = "الجزء " .. (JUZ_ORDINAL_ARABIC[juz] or "")
    elseif juz_display == "number_latin" then
        juz_part = "Juz " .. juz
    elseif juz_display == "name_latin" then
        juz_part = (JUZ_NAMES_LATIN[juz] or "")
    elseif juz_display == "name_latin_with_juz" then
        juz_part = "Juz' " .. (JUZ_NAMES_LATIN[juz] or "")
    else -- "number_arabic" (default)
        juz_part = "جزء " .. toArabicIndic(juz)
    end

    juz_part = juz_part .. mark

    -- Detect if this format is Arabic (RTL) or Latin (LTR)
    local is_arabic = juz_display == "number_arabic" or juz_display == "name_arabic"
                      or juz_display == "name_arabic_with_juz"
                      or juz_display == "ordinal_arabic"

    -- Append surah name if enabled
    if show_surah then
        local surah = self:_getCurrentSurah()
        if surah then
            local surah_name
            local use_arabic = surah_display == "arabic"
                or surah_display == "arabic_with_surat"
                or (surah_display == "auto" and is_arabic)
            if use_arabic then
                surah_name = SURAH_NAMES_ARABIC[surah]
                if surah_name and surah_display == "arabic_with_surat" then
                    surah_name = "سورة " .. surah_name
                end
            else
                surah_name = SURAH_NAMES[surah]
                if surah_name and surah_display == "latin_with_surat" then
                    surah_name = "Surat " .. surah_name
                end
            end
            if surah_name then
                juz_part = juz_part .. " — " .. surah_name
            end
        end
    end

    -- Wrap RTL if juz format is Arabic, OR if surah name is Arabic
    local surah_is_arabic = surah_display == "arabic" or surah_display == "arabic_with_surat"
        or (surah_display == "auto" and is_arabic)
    local needs_bidi = is_arabic or (surah_is_arabic and show_surah)
    if needs_bidi then
        return BD.wrap(juz_part)
    else
        return juz_part
    end
end

--- Format juz string for footer status bar.
function Quran:_getJuzFooterString()
    return self:_buildDisplayString(
        self.settings:readSetting("juz_display", "number_arabic"),
        self.settings:isTrue("show_surah_in_footer"),
        self.settings:readSetting("surah_display", "auto")
    )
end

--- Format juz string for alt status bar (header).
-- Defaults: Arabic numerals, surah ON with "سورة" prefix.
function Quran:_getJuzHeaderString()
    return self:_buildDisplayString(
        self.settings:readSetting("header_juz_display", "ordinal_arabic"),
        self.settings:nilOrTrue("header_show_surah"),
        self.settings:readSetting("header_surah_display", "arabic_with_surat")
    )
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

function Quran:_addHeaderContent()
    if not self.ui.crelistener then return end
    logger.info("quran.koplugin: registering header content, status_line:",
                self.document.configurable.status_line,
                "view_mode:", self.view.view_mode)
    self.ui.crelistener:addAdditionalHeaderContent(self.additional_header_content_func)
    -- Edge case: if the user has disabled ALL built-in alt status bar items,
    -- CREngine allocates 0px for the header (m_pageHeaderInfo == 0).
    -- Force a flag so space is allocated; setPageInfoOverride() replaces
    -- the built-in rendering, so the forced flag has no visible side effect
    -- beyond the progress bar (which is always drawn anyway).
    self:_ensureHeaderSpace()
    UIManager:broadcastEvent(Event:new("UpdateHeader"))
end

function Quran:_removeHeaderContent()
    if not self.ui.crelistener then return end
    self.ui.crelistener:removeAdditionalHeaderContent(self.additional_header_content_func)
    UIManager:broadcastEvent(Event:new("UpdateHeader"))
end

--- Ensure CREngine allocates header space even if no built-in items are enabled.
-- When all built-in alt status bar items are off, m_pageHeaderInfo == 0 and
-- CREngine returns 0 from getPageHeaderHeight(), so the header is invisible.
-- We force PGHDR_PAGE_NUMBER (1) directly via setHeaderInfo to allocate space;
-- setPageInfoOverride() replaces the built-in page number rendering with our
-- content, so the forced flag has no visible side effect beyond the progress bar.
function Quran:_ensureHeaderSpace()
    if not self.ui.crelistener then return end
    local cl = self.ui.crelistener
    local any_builtin = cl.title == 1 or cl.author == 1 or cl.clock == 1
        or cl.page_number == 1 or cl.page_count == 1 or cl.reading_percent == 1
        or cl.chapter_marks == 1
        or (cl.battery == 1 and cl.battery_percent == 1)
    if not any_builtin then
        logger.info("quran.koplugin: no built-in header items enabled, forcing PGHDR_PAGE_NUMBER for header space")
        -- Use setHeaderInfo to directly set m_pageHeaderInfo, bypassing the
        -- property system (setIntProperty goes through propsApply but may
        -- not reliably update the bitfield)
        self.ui.document._document:setHeaderInfo(1) -- PGHDR_PAGE_NUMBER
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
    end
end

--- Build and paint the header overlay: surah (left) — juz (right).
function Quran:_drawHeaderOverlay(bb, x, y)
    local screen_width = Screen:getWidth()
    local margin = Math.round(screen_width * 0.02) -- 2% side margins

    -- Font size from settings (default 16)
    local font_size = self.settings:readSetting("header_font_size", 10)
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

    -- Build right side (juz)
    local right_text = nil
    local juz, boundary = self:_getCurrentJuz()
    if juz then
        local mark = boundary and "*" or ""
        local juz_display = self.settings:readSetting("header_juz_display", "ordinal_arabic")
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
        right_text = BD.auto(juz_str .. mark)
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

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

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

    menu_items.quran = {
        text = _("Quran Helper"),
        sorting_hint = "tools",
        sub_item_table = {
            -- Grammar dictionary lookup toggle
            {
                text = _("Grammar dictionary lookup"),
                help_text = _("Long-press an ayah number marker to look up word-by-word grammar analysis. Requires a Quran grammar StarDict dictionary in data/dict/."),
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
                        text = _("Append surah name"),
                        help_text = _("Appends the current surah name after the juz display (e.g. 'جزء ١ — الفاتحة')."),
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
                            else
                                self.settings:saveSetting("show_header_overlay", true)
                                self._header_overlay_enabled = true
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
                            return _("Font size: ") .. self.settings:readSetting("header_font_size", 10)
                        end,
                        enabled_func = function()
                            return self.settings:isTrue("show_header_overlay")
                        end,
                        callback = function(touchmenu_instance)
                            local spin = SpinWidget:new{
                                value = self.settings:readSetting("header_font_size", 10),
                                value_min = 8,
                                value_max = 30,
                                default_value = 10,
                                title_text = _("Header font size"),
                                callback = function(spin)
                                    self.settings:saveSetting("header_font_size", spin.value)
                                    self.settings:flush()
                                    UIManager:setDirty(self.ui.view, "ui")
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            }
                            UIManager:show(spin)
                        end,
                        keep_menu_open = true,
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
                        help_text = _("Adjust text lightness. 0 = black (default), higher = lighter gray."),
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
        },
    }
end

return Quran
