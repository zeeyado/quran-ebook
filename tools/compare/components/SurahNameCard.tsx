import React from 'react';

interface SurahNameVersion {
  family: string;
  label: string;
  triggerFormat: string; // e.g. 'surah001' or 'surah001surah-icon'
}

const VERSIONS: SurahNameVersion[] = [
  { family: 'surah-name-v1', label: 'V1 (1405H Madani Mushaf)', triggerFormat: 'combined' },
  { family: 'surah-name-v2', label: 'V2 (intermediate)', triggerFormat: 'bare' },
  { family: 'surah-name-v4', label: 'V4 (modern, current)', triggerFormat: 'combined' },
];

// Sample surahs covering different name lengths and styles
const SAMPLES = [
  { num: 1, name: 'Al-Fatihah', trigger: 'surah001' },
  { num: 2, name: 'Al-Baqarah', trigger: 'surah002' },
  { num: 36, name: 'Ya-Sin', trigger: 'surah036' },
  { num: 55, name: 'Ar-Rahman', trigger: 'surah055' },
  { num: 112, name: 'Al-Ikhlas', trigger: 'surah112' },
  { num: 114, name: 'An-Nas', trigger: 'surah114' },
];

export const SurahNameCard: React.FC = () => {
  return (
    <div className="space-y-8">
      {VERSIONS.map((version) => (
        <div
          key={version.family}
          className="bg-white rounded-xl shadow-sm border border-gray-200 p-6 hover:shadow-md transition-shadow duration-200"
        >
          <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4 border-b border-gray-100 pb-2">
            {version.label}
          </div>

          {/* Grid of sample surah names */}
          <div className="grid grid-cols-2 gap-4">
            {SAMPLES.map((s) => {
              // V1 uses 'surah' for standalone icon, V4 uses 'surah-icon'
              const combinedTrigger =
                version.triggerFormat === 'combined'
                  ? `${s.trigger}${version.family === 'surah-name-v1' ? 'surah' : 'surah-icon'}`
                  : s.trigger;

              return (
                <div key={s.num} className="text-center space-y-1">
                  <div className="text-[10px] text-gray-400">
                    {s.num}. {s.name}
                  </div>
                  {/* Combined trigger (surahNNNsurah-icon) */}
                  <div
                    className="text-3xl text-slate-800 leading-relaxed"
                    style={{ fontFamily: version.family }}
                    dir="ltr"
                  >
                    {combinedTrigger}
                  </div>
                  {/* Bare trigger (surahNNN only — name without سورة prefix) */}
                  <div
                    className="text-2xl text-slate-500 leading-relaxed"
                    style={{ fontFamily: version.family }}
                    dir="ltr"
                  >
                    {s.trigger}
                  </div>
                </div>
              );
            })}
          </div>

          {/* Full row comparison at header size */}
          <div className="mt-6 pt-4 border-t border-gray-100">
            <div className="text-[10px] text-gray-400 mb-2">
              Simulated surah header (as used in EPUB)
            </div>
            <div
              className="w-full border-t border-b border-gray-400 py-3 flex justify-between items-center"
              dir="rtl"
            >
              <div className="text-center px-4 text-gray-500 text-sm leading-snug" style={{ fontFamily: 'scheherazade' }}>
                <div>ترتيبها</div>
                <div className="text-base mt-0.5">٢</div>
              </div>
              <div
                className="text-center text-3xl text-slate-800"
                style={{ fontFamily: version.family }}
                dir="ltr"
              >
                {version.triggerFormat === 'combined'
                  ? `surah002${version.family === 'surah-name-v1' ? 'surah' : 'surah-icon'}`
                  : 'surah002'}
              </div>
              <div className="text-center px-4 text-gray-500 text-sm leading-snug" style={{ fontFamily: 'scheherazade' }}>
                <div>آياتها</div>
                <div className="text-base mt-0.5">٢٨٦</div>
              </div>
            </div>

            {/* Body text for weight comparison */}
            <div className="mt-3">
              <div className="text-[10px] text-gray-400 mb-1">Body text (KFGQPC) for weight comparison</div>
              <div
                className="text-2xl text-slate-800 text-right leading-loose"
                style={{ fontFamily: 'qpc-hafs' }}
                dir="rtl"
              >
                ٱللَّهُ لَآ إِلَٰهَ إِلَّا هُوَ ٱلْحَىُّ ٱلْقَيُّومُ
              </div>
            </div>
          </div>
        </div>
      ))}
    </div>
  );
};
