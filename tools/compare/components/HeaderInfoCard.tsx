import React from 'react';
import { FontOption } from '../types';

interface HeaderInfoCardProps {
  font: FontOption;
  fontLabel: string;
}

// Sample surah header info text — mirrors the EPUB surah-header side cells
// "Its order" + surah number, "Its ayahs" + ayah count (Al-Baqarah = longest)
const HEADER_LEFT = 'ترتيبها';
const HEADER_RIGHT = 'آياتها';

// Arabic-Indic numerals for sample display
const NUM_114 = '١١٤';   // surah number (3 digits)
const NUM_286 = '٢٨٦';   // ayah count (Al-Baqarah)
const NUM_7 = '٧';        // ayah count (Al-Fatiha, 1 digit)

// Sample body text (start of 2:255, Ayat al-Kursi) for visual weight comparison
const BODY_SAMPLE = 'ٱللَّهُ لَآ إِلَٰهَ إِلَّا هُوَ ٱلْحَىُّ ٱلْقَيُّومُ';

export const HeaderInfoCard: React.FC<HeaderInfoCardProps> = ({ font, fontLabel }) => {
  return (
    <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-6 hover:shadow-md transition-shadow duration-200">
      <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4 border-b border-gray-100 pb-2">
        {fontLabel}
      </div>
      <div className="space-y-4">
        {/* Simulated surah header row */}
        <div>
          <div className="text-[10px] text-gray-400 mb-2">Surah header side cells (current: Scheherazade New)</div>
          <div
            className="w-full border-t border-b border-gray-400 py-3 flex justify-between items-center"
            dir="rtl"
          >
            {/* Right side cell (RTL: appears first) */}
            <div
              className="text-center px-4 text-gray-600 leading-snug"
              style={{ fontFamily: font, fontSize: '0.9em' }}
            >
              <div>{HEADER_LEFT}</div>
              <div className="text-lg mt-0.5">{NUM_114}</div>
            </div>

            {/* Center — surah name in same font for comparison */}
            <div
              className="text-center text-2xl text-slate-800"
              style={{ fontFamily: font }}
              dir="rtl"
            >
              سورة البقرة
            </div>

            {/* Left side cell */}
            <div
              className="text-center px-4 text-gray-600 leading-snug"
              style={{ fontFamily: font, fontSize: '0.9em' }}
            >
              <div>{HEADER_RIGHT}</div>
              <div className="text-lg mt-0.5">{NUM_286}</div>
            </div>
          </div>
        </div>

        {/* Short surah variant (1-digit number) */}
        <div>
          <div className="text-[10px] text-gray-400 mb-2">Short surah variant (Al-Fatiha)</div>
          <div
            className="w-full border-t border-b border-gray-400 py-3 flex justify-between items-center"
            dir="rtl"
          >
            <div
              className="text-center px-4 text-gray-600 leading-snug"
              style={{ fontFamily: font, fontSize: '0.9em' }}
            >
              <div>{HEADER_LEFT}</div>
              <div className="text-lg mt-0.5">١</div>
            </div>

            <div
              className="text-center text-2xl text-slate-800"
              style={{ fontFamily: font }}
              dir="rtl"
            >
              سورة الفاتحة
            </div>

            <div
              className="text-center px-4 text-gray-600 leading-snug"
              style={{ fontFamily: font, fontSize: '0.9em' }}
            >
              <div>{HEADER_RIGHT}</div>
              <div className="text-lg mt-0.5">{NUM_7}</div>
            </div>
          </div>
        </div>

        {/* Body text for visual weight comparison */}
        <div>
          <div className="text-[10px] text-gray-400 mb-1">Body text comparison (KFGQPC Hafs V22)</div>
          <div
            className="w-full text-right leading-loose text-2xl text-slate-800"
            style={{ fontFamily: 'qpc-hafs' }}
            dir="rtl"
          >
            {BODY_SAMPLE}
          </div>
        </div>
      </div>
    </div>
  );
};
