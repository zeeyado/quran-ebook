--- Quran grammar dictionary lookup support for KOReader.
-- This plugin intercepts dictionary lookups on ayah number markers in Quran
-- EPUBs and prepends the surah name (derived from the current TOC entry)
-- so the grammar dictionary can be looked up unambiguously.
--
-- Flow:
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

local DictQuickLookup = require("ui/widget/dictquicklookup")
local Geom = require("ui/geometry")
local LanguageSupport = require("languagesupport")
local Math = require("optmath")
local Size = require("ui/size")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local logger = require("logger")
local Screen = Device.screen
local _ = require("gettext")

local Quran = WidgetContainer:extend{
    name = "quran",
    pretty_name = "Quran",
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
    self._last_ayah_surah = nil
    self._last_ayah_num = nil
    LanguageSupport:registerPlugin(self)
    applyMonkeyPatches()
end

function Quran:supportsLanguage(language_code)
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
    -- Clear nav state from previous Quran popup so it doesn't leak
    -- into subsequent non-Quran lookups (onDictButtonsReady would
    -- otherwise patch a normal word popup's buttons away).
    self._last_ayah_surah = nil
    self._last_ayah_num = nil

    local text = args.text
    logger.dbg("quran.koplugin: onWordSelection text='" .. (text or "nil") .. "'")

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

--- Called when dictionary popup buttons are ready.
-- For Quran ayah lookups: replace buttons, override key handlers,
-- flag popup for medium height.
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

    if not surah or not ayah then
        return
    end

    logger.dbg("quran.koplugin: patching dict buttons for", surah, ":", ayah)

    -- Flag popup for medium height resize (in monkey-patched init)
    if DictQuickLookup._quran_next_lookup then
        DictQuickLookup._quran_next_lookup = nil
        dict_popup._quran_popup = true
    end

    -- Clear word_boxes for consistent centered positioning
    dict_popup.word_boxes = nil

    -- Store mutable state for button callbacks and key handlers
    dict_popup._quran_surah = surah
    dict_popup._quran_ayah = ayah

    local has_prev = ayah > 1 or surah > 1
    local has_next = ayah < (SURAH_AYAH_COUNTS[surah] or 0) or surah < 114

    -- Replace all button rows with [Next ◁] [Close] [▷ Prev]
    -- RTL: left=next (forward in reading), right=prev (backward)
    for i = #buttons, 1, -1 do
        table.remove(buttons, i)
    end

    table.insert(buttons, {
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

function Quran:genMenuItem()
    return {
        text = _("Quran grammar lookup"),
    }
end

return Quran
