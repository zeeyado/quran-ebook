local _ = require("gettext")
return {
    name = "quran",
    version = "1.6",
    fullname = _("Quran Helper"),
    description = _([[
Quran reading companion for KOReader.

Features:
- Grammar dictionary lookup: long-press ayah numbers for word-by-word
  grammar analysis (requires Quran grammar StarDict dictionary)
- Surah overview lookup: long-press surah name headers for introductory
  text about each surah (requires Surah Overview StarDict dictionary)
- Tafsir lookup: long-press ayah numbers for tafsir commentary
  (requires Quran tafsir StarDict dictionaries)
- Juz status bar: shows current juz (and boundary transitions) in the
  footer while reading]]),
}
