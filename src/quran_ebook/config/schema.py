"""Build configuration schema."""

from pathlib import Path
from typing import Literal

import yaml
from pydantic import BaseModel, model_validator

from .registry import FONTS, abbreviate, get_riwayah, validate_script_font_pair


# --- Frozen filename grammar v1 vocabulary (docs/filename_grammar_v1.md) ---
# script -> (orthography, encoding); encoding only for non-Unicode glyph text
_VARIANT_ORTHO = {
    "qpc_uthmani_hafs": ("uthmani", None),
    "text_qpc_hafs": ("uthmani", None),
    "text_uthmani": ("uthmani", None),
    "qpc_uthmani_warsh": ("uthmani", None),
    "text_indopak": ("indopak", None),
    "text_indopak_nastaleeq": ("indopak", None),
    "qcf_v1_plain": ("uthmani", "qcf1"),
    "qcf_v4_tajweed": ("uthmani", "qcf4"),
    # Parked tajweed axis (configs-tajweed/): additive encoding vocabulary,
    # legal under the grammar freeze (hyphen-suffix within slot 2b).
    "qpc_uthmani_hafs_tajweed": ("uthmani", "tj"),
    "text_uthmani_tajweed": ("uthmani", "tj"),
}
_VARIANT_FONT = {
    "kfgqpc_uthmanic_hafs": "kfgqpc",
    "kfgqpc_uthmanic_warsh": "kfgqpc",
    "indopak_nastaleeq": "nastaleeq",
    "qcf_v1": "qcf1",
    "qcf_v4": "qcf4",
    "kfgqpc_uthmanic_hafs_v17": "kfgqpc17",  # parked tajweed pairing
}
# structure -> (granularity, placement-with-translation, placement-without)
_VARIANT_STRUCT = {
    "inline": ("flow", None, None),
    "by_surah": ("ayah", "inline", None),
    "interactive_inline": ("flow", "popup", None),
    "wbw": ("word", "inline", "inline"),
    "bilingual_interactive": ("ayah", "inline", None),
    "qcf_inline": ("flow", None, None),
    "qcf_by_surah": ("ayah", "inline", None),
    "qcf_interactive": ("flow", "popup", None),
    "qcf_fixed": ("page", None, None),
    "qcf_fixed_interactive": ("page", "popup", None),
}


class BookConfig(BaseModel):
    title: str = "القرآن الكريم"
    language: str = "ar"


class QuranConfig(BaseModel):
    script: str = "qpc_uthmani_hafs"
    source: str = "quran_api"


class FontConfig(BaseModel):
    arabic: str = "kfgqpc_uthmanic_hafs"


class LayoutConfig(BaseModel):
    structure: str = "inline"
    show_ayah_numbers: bool = True
    show_bismillah: bool = True
    wbw_transliteration: bool = False  # Show transliteration row in WBW layout
    wbw_gloss_language: str = ""  # Override WBW gloss language (e.g. "en" for English glosses with non-English translation). Empty = use translation language.
    ayah_align: str = "center"  # .ayah-text alignment in by_surah layouts: center | right | justify (justify sets text-align-last: right)


class TranslationConfig(BaseModel):
    resource_id: int | None = 20  # Sahih International (Quran.com API)
    language: str = "en"
    name: str = "Sahih International"
    native_name: str = ""  # Translator/institute name in native script (e.g. "فتح محمد جالندھری"). Fallback: name.
    abbreviation: str = "sahih"  # Used in auto-generated filenames
    language_name: str = ""  # Native name (e.g. "Français"). Auto-resolved from registry if empty.
    source: str = "quran_api"  # "quran_api", "fawazahmed0", "local", "qul", or "qul_tafsir"
    edition: str = ""  # fawazahmed0 edition key (e.g. "eng-mustafakhattaba")

    @property
    def display_name(self) -> str:
        """Translator name for display: native_name if set, else name."""
        return self.native_name or self.name


class TafsirConfig(BaseModel):
    """Tafsir/commentary source for bilingual+interactive popup content."""

    resource_id: int
    source: str = "qul_tafsir"  # "qul_tafsir" or "qul"
    name: str
    abbreviation: str
    language: str
    language_name: str = ""
    native_name: str = ""

    @property
    def display_name(self) -> str:
        """Tafsir name for display: native_name if set, else name."""
        return self.native_name or self.name


class OutputConfig(BaseModel):
    filename: str = ""  # Empty = auto-generate from config
    directory: str = "output"
    status: Literal["stable", "beta", "experimental"] = "stable"  # Variant tier — stamped into OPF as quran:status (tier convention: docs/production_push_2026-07.md §0c; never encoded in filenames)


class BuildConfig(BaseModel):
    """Top-level build configuration."""

    book: BookConfig = BookConfig()
    quran: QuranConfig = QuranConfig()
    font: FontConfig = FontConfig()
    translation: TranslationConfig | None = None  # None = Arabic-only
    tafsir: TafsirConfig | None = None  # Optional tafsir for bilingual+interactive popup
    layout: LayoutConfig = LayoutConfig()
    output: OutputConfig = OutputConfig()

    @model_validator(mode="after")
    def validate_font_pairing(self) -> "BuildConfig":
        warnings = validate_script_font_pair(self.quran.script, self.font.arabic)
        if warnings:
            # Store warnings for the CLI to display — don't block the build
            if not hasattr(self, "_warnings"):
                object.__setattr__(self, "_warnings", [])
            object.__setattr__(self, "_warnings", warnings)
        return self

    @property
    def warnings(self) -> list[str]:
        return getattr(self, "_warnings", [])

    @property
    def font_info(self):
        return FONTS.get(self.font.arabic)

    @property
    def variant_id(self) -> str:
        """Stable variant ID per the FROZEN filename grammar v1.

        See docs/filename_grammar_v1.md (validated against all 164 configs,
        adversarially reviewed 2026-07-05). This ID doubles as: the new-scheme
        filename stem (clean-sweep release), the OPF quran:variant stamp, the
        OPDS entry ID, and the catalog.json key. auto_filename flips to this
        at sweep time; until then old names remain for existing artifacts.

        Grammar:
        quran_{riwayah}-{ortho}[-{enc}]_{font}_{gran}[-{placement}]_ar[-{lang}-{translator}][_gloss-{ll}][_tafsir-{slug}]
        """
        try:
            ortho, enc = _VARIANT_ORTHO[self.quran.script]
        except KeyError:
            raise ValueError(
                f"script {self.quran.script!r} has no filename-grammar mapping — "
                "add it to _VARIANT_ORTHO (docs/filename_grammar_v1.md §1)"
            ) from None
        try:
            gran, pl_translated, pl_bare = _VARIANT_STRUCT[self.layout.structure]
        except KeyError:
            raise ValueError(
                f"layout.structure {self.layout.structure!r} has no filename-grammar "
                "mapping — add it to _VARIANT_STRUCT (docs/filename_grammar_v1.md §1)"
            ) from None
        try:
            font_tag = _VARIANT_FONT[self.font.arabic]
        except KeyError:
            raise ValueError(
                f"font {self.font.arabic!r} has no filename-grammar mapping — "
                "add it to _VARIANT_FONT (docs/filename_grammar_v1.md §1)"
            ) from None
        placement = pl_translated if self.translation else pl_bare
        parts = [
            "quran",
            get_riwayah(self.quran.script) + f"-{ortho}" + (f"-{enc}" if enc else ""),
            font_tag,
            gran + (f"-{placement}" if placement else ""),
        ]
        if self.translation:
            parts.append(
                f"ar-{self.translation.language}-{self.translation.abbreviation}"
            )
        else:
            parts.append("ar")
        # Trailing tokens in canonical prefix order: gloss < tafsir (grammar §1b.5)
        if self.layout.structure == "wbw":
            gloss = self.layout.wbw_gloss_language
            if gloss and self.translation and gloss != self.translation.language:
                parts.append(f"gloss-{gloss}")
        if self.tafsir:
            parts.append(f"tafsir-{self.tafsir.abbreviation}")
        return "_".join(parts)

    @property
    def auto_filename(self) -> str:
        """Generate a descriptive filename from config settings.

        Pattern: quran_{riwayah}[_{script}]_{font}_{layout}_{lang}[-{translation}][_{gloss}wbw]
        e.g. quran_hafs_kfgqpc_inline_ar
        With translation: quran_hafs_kfgqpc_bilin_ar-en-sahih
        Cross-lang WBW: quran_hafs_kfgqpc_wbw_ar-fr-hamidullah_enwbw
        """
        layout_key = self.layout.structure
        if layout_key != "wbw" and self.translation and layout_key not in ("interactive_inline", "bilingual_interactive", "qcf_interactive", "qcf_fixed_interactive"):
            layout_key = "bilingual_interleaved"

        lang = self.book.language
        if self.translation:
            lang = (
                f"{self.book.language}-{self.translation.language}"
                f"-{self.translation.abbreviation}"
            )
            # Append tafsir abbreviation for bilingual+interactive
            if self.tafsir:
                lang += f"-{self.tafsir.abbreviation}"

        parts = [
            "quran",
            get_riwayah(self.quran.script),
        ]
        script_tag = abbreviate("script", self.quran.script)
        if script_tag:
            parts.append(script_tag)
        parts.extend([
            abbreviate("font", self.font.arabic),
            abbreviate("layout", layout_key),
            lang,
        ])

        # Append gloss language suffix for cross-language WBW
        if layout_key == "wbw":
            gloss = self.layout.wbw_gloss_language
            if gloss and self.translation and gloss != self.translation.language:
                parts.append(f"{gloss}wbw")

        return "_".join(p for p in parts if p)

    @property
    def output_filename(self) -> str:
        """Resolve the output filename — explicit or auto-generated."""
        return self.output.filename or self.auto_filename


def load_config(path: str | Path) -> BuildConfig:
    """Load and validate a build config from a YAML file."""
    path = Path(path)
    with path.open() as f:
        raw = yaml.safe_load(f)
    return BuildConfig.model_validate(raw or {})
