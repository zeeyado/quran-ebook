import { FontOption } from './types';

export const API_BASE_URL = 'https://api.quran.com/api/v4/verses/by_key';

export const REQUIRED_FIELDS = [
  'text_indopak',
  'text_imlaei_simple',
  'text_imlaei',
  'text_uthmani',
  'text_uthmani_simple',
  'text_uthmani_tajweed',
  'text_qpc_hafs',
  'qpc_uthmani_hafs',
  'text_qpc_nastaleeq_hafs',
  'text_qpc_nastaleeq',
  'text_indopak_nastaleeq'
].join(',');

export const FONTS: { label: string; value: FontOption }[] = [
  // --- KFGQPC / QPC ---
  { label: 'KFGQPC Hafs V22 (current)', value: 'qpc-hafs' },
  { label: 'KFGQPC Hafs V18', value: 'uthmanic-hafs-v18' },
  { label: 'KFGQPC Hafs V14', value: 'uthmanic-hafs-v14' },
  { label: 'KFGQPC Dot (practice)', value: 'kfgqpc-dot' },
  { label: 'Me Quran (Volt Newmet)', value: 'me' },
  { label: 'QPC Nastaleeq', value: 'qpc-nastaleeq' },
  { label: 'Hafs Nastaleeq V10', value: 'hafs-nastaleeq-v10' },
  { label: 'Indopak Nastaleeq (Hanafi)', value: 'indopak-nastaleeq' },
  { label: 'Digital Khatt V2', value: 'digitalkhaat-v2' },
  { label: 'Digital Khatt V1', value: 'digitalkhaat' },
  // --- Quran-specific ---
  { label: 'Amiri Quran', value: 'amiri-quran' },
  { label: 'Amiri Quran Colored (tajweed)', value: 'amiri-quran-colored' },
  { label: 'Scheherazade New', value: 'scheherazade' },
  { label: 'Kitab (Scheherazade fork)', value: 'kitab' },
  { label: 'Al Mushaf', value: 'al-mushaf' },
  { label: 'Al Qalam Quran Majeed', value: 'al-qalam' },
  { label: 'Noorehuda', value: 'noorehuda' },
  // --- General Arabic Naskh ---
  { label: 'Amiri', value: 'amiri' },
  { label: 'Noto Naskh Arabic', value: 'noto-naskh' },
  { label: 'Lateef (SIL)', value: 'lateef' },
  { label: 'Harmattan (SIL)', value: 'harmattan' },
  { label: 'Markazi Text', value: 'markazi' },
  { label: 'Aref Ruqaa', value: 'aref-ruqaa' },
  // --- Kufi / Sans-serif ---
  { label: 'Noto Kufi Arabic', value: 'noto-kufi' },
  { label: 'Noto Sans Arabic', value: 'noto-sans-arabic' },
  { label: 'Reem Kufi', value: 'reem-kufi' },
  { label: 'El Messiri', value: 'el-messiri' },
  // --- Nastaleeq ---
  { label: 'Noto Nastaliq Urdu', value: 'noto-nastaliq' },
  // --- System ---
  { label: 'System Default', value: 'sans-serif' },
];

export const SCRIPT_LABELS: Record<string, string> = {
  text_uthmani: 'Uthmani',
  text_uthmani_simple: 'Uthmani Simple',
  text_qpc_hafs: 'QPC Hafs',
  qpc_uthmani_hafs: 'QPC Uthmani Hafs',
  text_indopak: 'Indopak',
  text_indopak_nastaleeq: 'Indopak Nastaleeq',
  text_qpc_nastaleeq: 'QPC Nastaleeq',
  text_qpc_nastaleeq_hafs: 'QPC Nastaleeq Hafs',
  text_imlaei: 'Imlaei',
  text_imlaei_simple: 'Imlaei Simple',
  text_uthmani_tajweed: 'Uthmani Tajweed',
};
