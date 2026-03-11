local _ = require("gettext")
return {
    name = "quran",
    fullname = _("Quran grammar lookup"),
    description = _([[
Quran grammar dictionary support for KOReader.

When long-pressing an ayah number marker in a Quran EPUB, this plugin
detects the current surah from the TOC and converts the ambiguous ayah
number (e.g. "255") into a surah:ayah key (e.g. "2:255") that matches
the grammar dictionary.

Requires the Quran grammar StarDict dictionary to be installed.]]),
}
