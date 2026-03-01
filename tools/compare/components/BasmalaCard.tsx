import React from 'react';
import { FontOption } from '../types';

interface BasmalaCardProps {
  font: FontOption;
  fontLabel: string;
}

// U+FDFD — Bismillah ligature (single codepoint)
const BASMALA_LIGATURE = '\uFDFD';

// QPC Uthmani Hafs basmala text (from 1:1, stripped of ayah number)
// Uses QPC encoding: U+06E1 (small high dotless head of khah) for sukun
const QPC_BASMALA = '\u0628\u0650\u0633\u06E1\u0645\u0650 \u0671\u0644\u0644\u0651\u064E\u0647\u0650 \u0671\u0644\u0631\u0651\u064E\u062D\u06E1\u0645\u064E\u0670\u0646\u0650 \u0671\u0644\u0631\u0651\u064E\u062D\u0650\u064A\u0645\u0650';

// Standard Uthmani basmala text (uses U+0652 for sukun)
const UTHMANI_BASMALA = '\u0628\u0650\u0633\u0652\u0645\u0650 \u0671\u0644\u0644\u0651\u064E\u0647\u0650 \u0671\u0644\u0631\u0651\u064E\u062D\u0652\u0645\u064E\u0670\u0646\u0650 \u0671\u0644\u0631\u0651\u064E\u062D\u0650\u064A\u0645\u0650';

// Fonts verified (via fontTools) to contain the U+FDFD glyph.
// Fonts not in this set will show a browser fallback for the ligature.
const HAS_FDFD: Set<FontOption> = new Set([
  'amiri',
  'amiri-quran',
  'amiri-quran-colored',
  'scheherazade',
  'kitab',
  'noto-naskh',
  'noto-sans-arabic',
  'harmattan',
  'lateef',
]);

export const BasmalaCard: React.FC<BasmalaCardProps> = ({ font, fontLabel }) => {
  const hasFdfd = HAS_FDFD.has(font);

  return (
    <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-6 hover:shadow-md transition-shadow duration-200">
      <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4 border-b border-gray-100 pb-2">
        {fontLabel}
      </div>
      <div className="space-y-4">
        {/* U+FDFD ligature */}
        <div>
          <div className="text-[10px] text-gray-400 mb-1">
            U+FDFD ligature
            {!hasFdfd && (
              <span className="ml-2 text-amber-500 font-medium">(browser fallback — font lacks this glyph)</span>
            )}
          </div>
          <div
            className={`w-full text-center leading-loose text-5xl sm:text-6xl ${hasFdfd ? 'text-slate-800' : 'text-slate-400'}`}
            style={{ fontFamily: font }}
            dir="rtl"
          >
            {BASMALA_LIGATURE}
          </div>
        </div>
        {/* QPC text basmala */}
        <div>
          <div className="text-[10px] text-gray-400 mb-1">QPC Uthmani Hafs text</div>
          <div
            className="w-full text-right leading-loose text-3xl sm:text-4xl text-slate-800"
            style={{ fontFamily: font }}
            dir="rtl"
          >
            {QPC_BASMALA}
          </div>
        </div>
        {/* Standard Uthmani text basmala */}
        <div>
          <div className="text-[10px] text-gray-400 mb-1">Standard Uthmani text</div>
          <div
            className="w-full text-right leading-loose text-3xl sm:text-4xl text-slate-800"
            style={{ fontFamily: font }}
            dir="rtl"
          >
            {UTHMANI_BASMALA}
          </div>
        </div>
      </div>
    </div>
  );
};
