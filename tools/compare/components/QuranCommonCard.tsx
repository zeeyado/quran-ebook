import React from 'react';

// quran-common ligature triggers — ASCII text that renders as ornamental glyphs
// via OpenType liga substitution when the quran-common font is active.

const JUZ_LONG_SAMPLES = [1, 2, 3, 10, 15, 20, 30].map(n => ({
  num: n,
  trigger: `juz${String(n).padStart(3, '0')}`,
}));

const JUZ_SHORT_SAMPLES = [1, 2, 3, 10, 15, 20, 30].map(n => ({
  num: n,
  trigger: `j${String(n).padStart(3, '0')}`,
}));

const MARKERS = [
  { name: 'Half Marker (Rub)', trigger: 'marker-half' },
  { name: 'Full Marker (Hizb)', trigger: 'marker-full' },
];

const ICONS = [
  { name: 'Makkah', trigger: 'makkah' },
  { name: 'Madinah', trigger: 'madinah' },
  { name: 'Madani (alt)', trigger: 'madnai' },
  { name: 'Quran', trigger: 'quran' },
  { name: 'Header', trigger: 'header' },
];

const BRACKETS = [
  { style: 1, open: 's1open', close: 's1close' },
  { style: 2, open: 's2open', close: 's2close' },
  { style: 3, open: 's3open', close: 's3close' },
];

const SAMPLE_SURAH_NAME = 'سورة البقرة';

const fontStyle = { fontFamily: 'quran-common, serif' };

export const QuranCommonCard: React.FC = () => {
  return (
    <div className="space-y-10">

      {/* Brackets — shown first since user asked about ornamental frames */}
      <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-6">
        <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4 border-b border-gray-100 pb-2">
          Decorative Brackets — 3 styles (fixed-width glyphs)
        </div>
        <p className="text-xs text-gray-400 mb-4">
          Each bracket pair is a single fixed-width glyph. They don't stretch to fit content.
          Shown here flanking a surah name to visualize framing potential.
        </p>
        <div className="space-y-6">
          {BRACKETS.map(b => (
            <div key={b.style} className="space-y-2">
              <div className="text-[10px] text-gray-400 font-mono">
                Style {b.style}: {b.open} + {b.close}
              </div>
              {/* Show bracket pair alone */}
              <div className="text-center text-4xl text-slate-800 leading-relaxed" dir="rtl">
                <span style={fontStyle}>{b.open}</span>
                <span className="mx-2" style={{ fontFamily: 'qpc-hafs, serif' }}>{SAMPLE_SURAH_NAME}</span>
                <span style={fontStyle}>{b.close}</span>
              </div>
              {/* Show brackets isolated */}
              <div className="flex justify-center gap-8 text-2xl text-slate-500">
                <span className="text-center">
                  <span className="text-[10px] text-gray-400 block font-mono mb-1">open</span>
                  <span style={fontStyle}>{b.open}</span>
                </span>
                <span className="text-center">
                  <span className="text-[10px] text-gray-400 block font-mono mb-1">close</span>
                  <span style={fontStyle}>{b.close}</span>
                </span>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Juz Labels — Long Form */}
      <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-6">
        <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4 border-b border-gray-100 pb-2">
          Juz Labels — Long Form (ornamental)
        </div>
        <p className="text-xs text-gray-400 mb-4">
          Triggers: juz001–juz030. Each renders as a full ornamental label like "الجزء الأول".
        </p>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          {JUZ_LONG_SAMPLES.map(j => (
            <div key={j.trigger} className="text-center space-y-1 py-2 border border-gray-100 rounded-lg">
              <div className="text-[10px] text-gray-400 font-mono">{j.trigger} (Juz {j.num})</div>
              <div
                className="text-3xl text-slate-800 leading-relaxed"
                style={fontStyle}
                dir="ltr"
              >
                {j.trigger}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Juz Labels — Short Form */}
      <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-6">
        <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4 border-b border-gray-100 pb-2">
          Juz Labels — Short Form (compact)
        </div>
        <p className="text-xs text-gray-400 mb-4">
          Triggers: j001–j030. Compact juz labels.
        </p>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          {JUZ_SHORT_SAMPLES.map(j => (
            <div key={j.trigger} className="text-center space-y-1 py-2 border border-gray-100 rounded-lg">
              <div className="text-[10px] text-gray-400 font-mono">{j.trigger}</div>
              <div
                className="text-3xl text-slate-800"
                style={fontStyle}
                dir="ltr"
              >
                {j.trigger}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Markers */}
      <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-6">
        <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4 border-b border-gray-100 pb-2">
          Hizb Markers
        </div>
        <p className="text-xs text-gray-400 mb-4">
          Compare with Scheherazade New's U+06DE (۞) rendering — these are alternative marker glyphs from quran-common.
        </p>
        <div className="flex gap-8 justify-center">
          {MARKERS.map(m => (
            <div key={m.trigger} className="text-center space-y-1">
              <div className="text-[10px] text-gray-400 font-mono">{m.trigger}</div>
              <div
                className="text-5xl text-slate-800"
                style={fontStyle}
                dir="ltr"
              >
                {m.trigger}
              </div>
              <div className="text-[10px] text-gray-500">{m.name}</div>
            </div>
          ))}
          {/* Compare with Scheherazade New ۞ */}
          <div className="text-center space-y-1 border-l border-gray-200 pl-8">
            <div className="text-[10px] text-gray-400 font-mono">U+06DE</div>
            <div
              className="text-5xl text-slate-800"
              style={{ fontFamily: 'scheherazade, serif' }}
            >
              ۞
            </div>
            <div className="text-[10px] text-gray-500">Scheherazade New (current)</div>
          </div>
        </div>
      </div>

      {/* Icons */}
      <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-6">
        <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4 border-b border-gray-100 pb-2">
          Icons (Revelation Location + Decorative)
        </div>
        <p className="text-xs text-gray-400 mb-4">
          Makkah/Madinah icons could indicate revelation location in surah headers.
          The "header" trigger is a decorative bar/ornament element.
        </p>
        <div className="flex flex-wrap gap-6 justify-center">
          {ICONS.map(icon => (
            <div key={icon.trigger} className="text-center space-y-1">
              <div className="text-[10px] text-gray-400 font-mono">{icon.trigger}</div>
              <div
                className="text-5xl text-slate-800"
                style={fontStyle}
                dir="ltr"
              >
                {icon.trigger}
              </div>
              <div className="text-[10px] text-gray-500">{icon.name}</div>
            </div>
          ))}
        </div>
      </div>

    </div>
  );
};
