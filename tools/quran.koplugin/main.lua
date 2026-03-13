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
local DataStorage = require("datastorage")
local DictQuickLookup = require("ui/widget/dictquicklookup")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local LanguageSupport = require("languagesupport")
local LuaSettings = require("luasettings")
local Math = require("optmath")
local Size = require("ui/size")
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
    local orig_init = DictQuickLookup.init
    DictQuickLookup.init = function(self_dql, ...)
        orig_init(self_dql, ...)
        if self_dql._quran_popup then
            resizeToMedium(self_dql)
        end
    end

    -- Patch 2: ReaderDictionary.showDict — in-place update for Quran nav
    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    local orig_showDict = ReaderDictionary.showDict
    ReaderDictionary.showDict = function(self_dict, word, results, boxes, link, dict_close_callback)
        local target = DictQuickLookup._quran_update_popup
        if target and results and results[1] then
            DictQuickLookup._quran_update_popup = nil
            -- Update existing popup in-place
            target.results = results
            target.word = word
            target:changeDictionary(1)
            self_dict:dismissLookupInfo()
            return
        end
        return orig_showDict(self_dict, word, results, boxes, link, dict_close_callback)
    end
end

-- ---------------------------------------------------------------------------
-- Plugin methods
-- ---------------------------------------------------------------------------

function Quran:init()
    self._stashed_surah = nil
    self._stashed_surah_name = nil
    self._stashed_surah_glyph = nil
    self._last_ayah_surah = nil
    self._last_ayah_num = nil
    self._last_overview_surah = nil
    self._cached_juz = nil       -- cached juz number for current page
    self._cached_boundary = nil  -- cached boundary flag for current page
    self._cached_pageno = nil    -- page number the juz cache is valid for
    self._cached_surah = nil     -- cached surah number for current page
    self._cached_surah_pg = nil  -- page number the surah cache is valid for
    self._juz_toc_pages = nil    -- juz TOC entry -> page mapping
    self._status_bar_registered = false
    LanguageSupport:registerPlugin(self)
    applyMonkeyPatches()

    -- Persistent settings
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/quran.lua")

    -- Juz status bar content function (closure captures self)
    self.additional_footer_content_func = function()
        if not self.settings:nilOrTrue("show_juz_in_footer") then return end
        return self:_getJuzFooterString()
    end

    self.ui.menu:registerToMainMenu(self)
end

--- Register status bar content after document is ready.
-- Deferred from init() because ui.view and ui.crelistener may not
-- be available yet during plugin initialization.
function Quran:onReaderReady()
    if self._status_bar_registered then return end
    self._status_bar_registered = true

    logger.dbg("quran.koplugin: onReaderReady — view:", self.ui.view and "yes" or "nil",
                "crelistener:", self.ui.crelistener and "yes" or "nil")

    if self.settings:nilOrTrue("show_juz_in_footer") then
        self:_addFooterContent()
    end
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
    -- Clear nav state from previous Quran popup so it doesn't leak
    -- into subsequent non-Quran lookups (onDictButtonsReady would
    -- otherwise patch a normal word popup's buttons away).
    self._last_ayah_surah = nil
    self._last_ayah_num = nil
    self._last_overview_surah = nil

    local text = args.text
    logger.dbg("quran.koplugin: onWordSelection text='" .. (text or "nil") .. "'")

    -- Detect surah glyph long-press: trigger text is "surahNNNx" (e.g. "surah002x").
    -- Returns the surah name as lookup candidate for surah overview dictionary.
    if text then
        local surah_num_str = text:match("^surah(%d+)x?$")
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
    self._stashed_surah = nil
    self._stashed_surah_name = nil

    if not surah then
        logger.dbg("quran.koplugin: no stashed surah, skipping")
        return nil
    end

    -- Extract trailing digits (handles inline layout where Arabic text
    -- is joined to the ayah number, and KOReader digit normalization)
    local digit_str = extractTrailingDigits(text)
    if not digit_str then
        logger.dbg("quran.koplugin: no trailing digits in lookup text, skipping")
        return nil
    end

    local ayah
    if isArabicIndicDigits(digit_str) then
        ayah = arabicIndicToInt(digit_str)
    else
        ayah = tonumber(digit_str)
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

    -- Signal showDict to update this popup in-place
    DictQuickLookup._quran_update_popup = dict_popup

    -- Trigger lookup through normal pipeline
    self.ui.dictionary:onLookupWord(name)
end

--- Common setup for all Quran custom popups.
-- Clears default buttons, sets flags for medium height and no word highlight.
-- @param dict_popup DictQuickLookup instance
-- @param buttons Buttons table from onDictButtonsReady
local function setupQuranPopup(dict_popup, buttons)
    if DictQuickLookup._quran_next_lookup then
        DictQuickLookup._quran_next_lookup = nil
    end
    dict_popup._quran_popup = true
    dict_popup.word_boxes = nil
    for i = #buttons, 1, -1 do
        table.remove(buttons, i)
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

--- Called when dictionary popup buttons are ready.
-- For Quran lookups: replace buttons with custom nav/scroll,
-- override key handlers, flag popup for medium height.
function Quran:onDictButtonsReady(dict_popup, buttons)
    DictQuickLookup.temp_large_window_request = nil

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
        setupQuranPopup(dict_popup, buttons)
        dict_popup._quran_overview_surah = overview_surah

        local has_prev = overview_surah and overview_surah > 1
        local has_next = overview_surah and overview_surah < 114

        table.insert(buttons, {
            scrollTopButton(dict_popup),
            {
                id = "next_surah",
                text = "◁",
                enabled = has_next,
                vsync = true,
                callback = function()
                    local s = (dict_popup._quran_overview_surah or 0) + 1
                    if s <= 114 then
                        self:_lookupSurah(s, dict_popup)
                    end
                end,
            },
            {
                id = "close",
                text = _("Close"),
                callback = function()
                    dict_popup:onClose()
                end,
            },
            {
                id = "prev_surah",
                text = "▷",
                enabled = has_prev,
                vsync = true,
                callback = function()
                    local s = (dict_popup._quran_overview_surah or 2) - 1
                    if s >= 1 then
                        self:_lookupSurah(s, dict_popup)
                    end
                end,
            },
            scrollBottomButton(dict_popup),
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

    -- Grammar dictionary popup: [⇱] [◁ Next] [Close] [Prev ▷] [⇲]
    -- Navigation goes to next/prev ayah
    logger.dbg("quran.koplugin: patching grammar popup for", surah, ":", ayah)
    setupQuranPopup(dict_popup, buttons)

    -- Store mutable state for button callbacks and key handlers
    dict_popup._quran_surah = surah
    dict_popup._quran_ayah = ayah

    local has_prev = ayah > 1 or surah > 1
    local has_next = ayah < (SURAH_AYAH_COUNTS[surah] or 0) or surah < 114

    -- Button row: [⇱] [◁ Next] [Close] [Prev ▷] [⇲]
    -- RTL: left=next (forward in reading), right=prev (backward)
    table.insert(buttons, {
        scrollTopButton(dict_popup),
        {
            id = "next_ayah",
            text = "◁",
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
        },
        {
            id = "close",
            text = _("Close"),
            callback = function()
                dict_popup:onClose()
            end,
        },
        {
            id = "prev_ayah",
            text = "▷",
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
        },
        scrollBottomButton(dict_popup),
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

--- Format juz string for footer (bidi-safe, mixed scripts OK).
-- Appends a boundary marker (*) when a new juz starts on this page.
-- Optionally appends surah name with separator.
function Quran:_getJuzFooterString()
    local juz, boundary = self:_getCurrentJuz()
    if not juz then return end

    local mark = boundary and "*" or ""
    local display = self.settings:readSetting("juz_display", "number_arabic")

    local juz_part
    if display == "name_arabic" then
        juz_part = (JUZ_NAMES_ARABIC[juz] or "")
    elseif display == "name_arabic_with_juz" then
        juz_part = "جزء " .. (JUZ_NAMES_ARABIC[juz] or "")
    elseif display == "number_latin" then
        juz_part = "Juz " .. juz
    elseif display == "name_latin" then
        juz_part = (JUZ_NAMES_LATIN[juz] or "")
    elseif display == "name_latin_with_juz" then
        juz_part = "Juz' " .. (JUZ_NAMES_LATIN[juz] or "")
    else -- "number_arabic" (default)
        juz_part = "جزء " .. toArabicIndic(juz)
    end

    juz_part = juz_part .. mark

    -- Detect if this format is Arabic (RTL) or Latin (LTR)
    local is_arabic = display == "number_arabic" or display == "name_arabic"
                      or display == "name_arabic_with_juz"

    -- Append surah name if enabled
    local surah_display = self.settings:readSetting("surah_display", "auto")
    if self.settings:isTrue("show_surah_in_footer") then
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

    -- Wrap RTL if juz format is Arabic, OR if surah name is Arabic (even with Latin juz)
    local surah_is_arabic = surah_display == "arabic" or surah_display == "arabic_with_surat"
        or (surah_display == "auto" and is_arabic)
    local needs_bidi = is_arabic
        or (surah_is_arabic and self.settings:isTrue("show_surah_in_footer"))
    if needs_bidi then
        return BD.wrap(juz_part)
    else
        return juz_part
    end
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

-- NOTE: Alt status bar (header) support deferred — CRE's page info section
-- requires at least one built-in item enabled, and there's no "External content"
-- toggle like the footer has. See docs/juz_navigation_plan.md for details.

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function Quran:addToMainMenu(menu_items)
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
                separator = true,
            },
            -- Juz status bar toggle
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
            -- Juz display format
            {
                text_func = function()
                    local displays = {
                        number_arabic = "جزء ٣٠",
                        name_arabic_with_juz = "جزء عم",
                        name_arabic = "عم",
                        number_latin = "Juz 30",
                        name_latin_with_juz = "Juz' 'Amma",
                        name_latin = "'Amma",
                    }
                    local current = self.settings:readSetting("juz_display", "number_arabic")
                    return _("Juz format: ") .. (displays[current] or "جزء ٣٠")
                end,
                help_text = _("Choose how the juz is displayed in the status bar. An asterisk (*) appears at juz boundaries."),
                enabled_func = function()
                    return self.settings:nilOrTrue("show_juz_in_footer")
                end,
                sub_item_table = {
                    {
                        text = "جزء ١، جزء ٢، ... جزء ٣٠",
                        checked_func = function()
                            return self.settings:readSetting("juz_display", "number_arabic") == "number_arabic"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("juz_display", "number_arabic")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = "جزء عم، جزء تبارك، ... جزء آلم",
                        checked_func = function()
                            return self.settings:readSetting("juz_display") == "name_arabic_with_juz"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("juz_display", "name_arabic_with_juz")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = "عم، تبارك، ... آلم",
                        checked_func = function()
                            return self.settings:readSetting("juz_display") == "name_arabic"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("juz_display", "name_arabic")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = "Juz 1, Juz 2, ... Juz 30",
                        checked_func = function()
                            return self.settings:readSetting("juz_display") == "number_latin"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("juz_display", "number_latin")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = "Juz' 'Amma, Juz' Tabaraka, ... Juz' Alif Lam Mim",
                        checked_func = function()
                            return self.settings:readSetting("juz_display") == "name_latin_with_juz"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("juz_display", "name_latin_with_juz")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = "'Amma, Tabaraka, ... Alif Lam Mim",
                        checked_func = function()
                            return self.settings:readSetting("juz_display") == "name_latin"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("juz_display", "name_latin")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                },
            },
            -- Surah name toggle
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
            -- Surah name format
            {
                text_func = function()
                    local displays = {
                        auto = _("auto"),
                        arabic = "الفاتحة",
                        arabic_with_surat = "سورة الفاتحة",
                        latin = "Al-Fatihah",
                        latin_with_surat = "Surat Al-Fatihah",
                    }
                    local current = self.settings:readSetting("surah_display", "auto")
                    return _("Surah format: ") .. (displays[current] or _("auto"))
                end,
                help_text = _("Choose how the surah name is displayed. 'Auto' matches the juz format language."),
                enabled_func = function()
                    return self.settings:nilOrTrue("show_juz_in_footer")
                        and self.settings:isTrue("show_surah_in_footer")
                end,
                sub_item_table = {
                    {
                        text = _("Auto (match juz format)"),
                        help_text = _("Arabic name with Arabic juz formats, Latin name with Latin juz formats."),
                        checked_func = function()
                            return self.settings:readSetting("surah_display", "auto") == "auto"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("surah_display", "auto")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = "الفاتحة، البقرة، ...",
                        checked_func = function()
                            return self.settings:readSetting("surah_display") == "arabic"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("surah_display", "arabic")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = "سورة الفاتحة، سورة البقرة، ...",
                        checked_func = function()
                            return self.settings:readSetting("surah_display") == "arabic_with_surat"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("surah_display", "arabic_with_surat")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = "Al-Fatihah, Al-Baqarah, ...",
                        checked_func = function()
                            return self.settings:readSetting("surah_display") == "latin"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("surah_display", "latin")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                    {
                        text = "Surat Al-Fatihah, Surat Al-Baqarah, ...",
                        checked_func = function()
                            return self.settings:readSetting("surah_display") == "latin_with_surat"
                        end,
                        radio = true,
                        callback = function()
                            self.settings:saveSetting("surah_display", "latin_with_surat")
                            self.settings:flush()
                            UIManager:broadcastEvent(Event:new("UpdateFooter", true))
                        end,
                    },
                },
            },
        },
    }
end

return Quran
