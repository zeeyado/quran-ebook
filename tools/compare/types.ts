export interface Verse {
  id: number;
  verse_number: number;
  verse_key: string;
  hizb_number: number;
  rub_el_hizb_number: number;
  ruku_number: number;
  manzil_number: number;
  sajdah_number: number | null;
  text_indopak: string;
  text_imlaei_simple: string;
  text_imlaei: string;
  text_uthmani: string;
  text_uthmani_simple: string;
  text_uthmani_tajweed: string;
  text_qpc_hafs: string;
  qpc_uthmani_hafs: string;
  text_qpc_nastaleeq_hafs: string;
  text_qpc_nastaleeq: string;
  text_indopak_nastaleeq: string;
  page_number: number;
  juz_number: number;
}

export interface VerseResponse {
  verse: Verse;
}

export type FontOption =
  // KFGQPC / QPC fonts
  | 'qpc-hafs'
  | 'uthmanic-hafs-v18'
  | 'uthmanic-hafs-v14'
  | 'kfgqpc-dot'
  | 'me'
  | 'qpc-nastaleeq'
  | 'hafs-nastaleeq-v10'
  | 'indopak-nastaleeq'
  | 'digitalkhaat-v2'
  | 'digitalkhaat'
  // Quran-specific fonts
  | 'amiri-quran'
  | 'amiri-quran-colored'
  | 'scheherazade'
  | 'kitab'
  | 'al-mushaf'
  | 'al-qalam'
  | 'noorehuda'
  // General Arabic Naskh
  | 'amiri'
  | 'noto-naskh'
  | 'lateef'
  | 'harmattan'
  | 'markazi'
  | 'aref-ruqaa'
  // Kufi / Sans-serif
  | 'noto-kufi'
  | 'noto-sans-arabic'
  | 'reem-kufi'
  | 'el-messiri'
  // Nastaleeq
  | 'noto-nastaliq'
  // System
  | 'sans-serif';

export interface Surah {
  id: number;
  name_simple: string;
  name_arabic: string;
  verses_count: number;
}

export type SurahMap = Record<string, Surah>;
