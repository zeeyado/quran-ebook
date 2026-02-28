"""Build configuration schema."""

from pathlib import Path

import yaml
from pydantic import BaseModel, model_validator

from .registry import FONTS, abbreviate, validate_script_font_pair


class BookConfig(BaseModel):
    title: str = "القرآن الكريم"
    language: str = "ar"


class QuranConfig(BaseModel):
    script: str = "qpc_uthmani_hafs"
    source: str = "quran_api"


class FontConfig(BaseModel):
    arabic: str = "kfgqpc_uthmanic_hafs"


class LayoutConfig(BaseModel):
    structure: str = "by_surah"
    show_ayah_numbers: bool = True
    show_bismillah: bool = True


class TranslationConfig(BaseModel):
    resource_id: int = 20  # Sahih International
    language: str = "en"
    name: str = "Sahih International"
    abbreviation: str = "sahih"  # Used in auto-generated filenames


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

        Pattern: quran_{layout}_{script}_{font}_{lang}
        e.g. quran_inline_qpc-hafs_kfgqpc-hafs_ar
        With translation: quran_bilin_qpc-hafs_kfgqpc-hafs_ar-en-sahih
        """
        layout_key = self.layout.structure
        if self.translation:
            layout_key = "bilingual_interleaved"

        parts = [
            "quran",
            abbreviate("layout", layout_key),
            abbreviate("script", self.quran.script),
            abbreviate("font", self.font.arabic),
            self.book.language,
        ]
        if self.translation:
            parts[-1] = (
                f"{self.book.language}-{self.translation.language}"
                f"-{self.translation.abbreviation}"
            )
        return "_".join(parts)

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
