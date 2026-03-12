local _ = require("gettext")
return {
    name = "quran",
    fullname = _("Quran Helper"),
    description = _([[
Quran reading companion for KOReader.

Features:
- Grammar dictionary lookup: long-press ayah numbers for word-by-word
  grammar analysis (requires Quran grammar StarDict dictionary)
- Juz status bar: shows current juz (and boundary transitions) in the
  footer while reading]]),
}
