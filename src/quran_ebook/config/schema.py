"""Build configuration schema."""

from pathlib import Path

import yaml
from pydantic import BaseModel, model_validator

from .registry import FONTS, abbreviate, get_riwayah, validate_script_font_pair


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


class TranslationConfig(BaseModel):
    resource_id: int | None = 20  # Sahih International (Quran.com API)
    language: str = "en"
    name: str = "Sahih International"
    native_name: str = ""  # Translator/institute name in native script (e.g. "فتح محمد جالندھری"). Fallback: name.
    abbreviation: str = "sahih"  # Used in auto-generated filenames
    language_name: str = ""  # Native name (e.g. "Français"). Auto-resolved from registry if empty.
    source: str = "quran_api"  # "quran_api", "fawazahmed0", or "local"
    edition: str = ""  # fawazahmed0 edition key (e.g. "eng-mustafakhattaba")

    @property
    def display_name(self) -> str:
        """Translator name for display: native_name if set, else name."""
        return self.native_name or self.name


class OutputConfig(BaseModel):
    filename: str = ""  # Empty = auto-generate from config
    directory: str = "output"


class BuildConfig(BaseModel):
    """Top-level build configuration."""

    book: BookConfig = BookConfig()
    quran: QuranConfig = QuranConfig()
    font: FontConfig = FontConfig()
    translation: TranslationConfig | None = None  # None = Arabic-only
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
    def auto_filename(self) -> str:
        """Generate a descriptive filename from config settings.

        Pattern: quran_{riwayah}[_{script}]_{font}_{layout}_{lang}[-{translation}][_{gloss}wbw]
        e.g. quran_hafs_kfgqpc_inline_ar
        With translation: quran_hafs_kfgqpc_bilin_ar-en-sahih
        Cross-lang WBW: quran_hafs_kfgqpc_wbw_ar-fr-hamidullah_enwbw
        """
        layout_key = self.layout.structure
        if layout_key != "wbw" and self.translation and layout_key not in ("interactive_inline", "qcf_interactive"):
            layout_key = "bilingual_interleaved"

        lang = self.book.language
        if self.translation:
            lang = (
                f"{self.book.language}-{self.translation.language}"
                f"-{self.translation.abbreviation}"
            )

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
