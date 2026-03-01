import React, { useState, useEffect, useCallback } from 'react';
import { Verse, FontOption } from './types';
import { fetchVerseByKey } from './services/quranService';
import { FONTS, SCRIPT_LABELS } from './constants';
import { SURAH_MAP } from './surahData';
import { VerseCard } from './components/VerseCard';
import { BasmalaCard } from './components/BasmalaCard';
import { Loader } from './components/Loader';
import { rasmify } from './rasm';

const App: React.FC = () => {
  const [chapter, setChapter] = useState<string>('30');
  const [ayah, setAyah] = useState<string>('29');
  const [showBasmala, setShowBasmala] = useState<boolean>(false);
  
  const [verseData, setVerseData] = useState<Verse | null>(null);
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedFont, setSelectedFont] = useState<FontOption>('qpc-hafs');

  const loadVerse = useCallback(async (key: string) => {
    if (!key.trim()) return;
    
    setLoading(true);
    setError(null);
    try {
      const data = await fetchVerseByKey(key.trim());
      setVerseData(data.verse);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'An unexpected error occurred');
      setVerseData(null);
    } finally {
      setLoading(false);
    }
  }, []);

  // Initial load
  useEffect(() => {
    loadVerse('30:29');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (chapter && ayah) {
      loadVerse(`${chapter}:${ayah}`);
    }
  };

  const handleChapterChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const newChapter = e.target.value;
    setChapter(newChapter);
    
    // Reset ayah to 1 when surah changes to prevent out of bounds
    const newSurah = SURAH_MAP[newChapter];
    if (newSurah && parseInt(ayah) > newSurah.verses_count) {
       setAyah('1');
    }
  };

  const currentSurah = SURAH_MAP[chapter];
  const maxVerses = currentSurah ? currentSurah.verses_count : 999;

  return (
    <div className="min-h-screen bg-mono-bg text-mono-text font-sans selection:bg-mono-accent/20">
      {/* Header & Controls - Sticky */}
      <div className="md:sticky top-0 z-50 bg-mono-bg/95 backdrop-blur-sm border-b border-mono-border transition-all duration-200">
        <div className="max-w-4xl mx-auto px-6 py-4">
          <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
            
            <div className="flex items-center gap-3">
              <h1 className="text-md font-semibold tracking-tight text-mono-text">Compare Quran API Scripts & Fonts</h1>
            </div>

            <form onSubmit={handleSubmit} className="flex flex-col sm:flex-row gap-3 w-full md:w-auto items-end sm:items-end">
              <div className="flex flex-wrap gap-2 w-full items-end">
                
                {/* Chapter Select */}
                <div className="flex flex-col gap-1 w-full sm:w-auto">
                  <label className="text-[10px] uppercase tracking-wider text-mono-textSec font-semibold ml-1">Surah</label>
                  <select
                    value={chapter}
                    onChange={handleChapterChange}
                    className="w-full sm:w-48 px-3 py-2 rounded-md border border-mono-border bg-white text-mono-text focus:ring-1 focus:ring-mono-text focus:border-mono-text outline-none cursor-pointer text-sm shadow-sm"
                  >
                    {Object.values(SURAH_MAP).map((s) => (
                      <option key={s.id} value={s.id}>
                        {s.id}. {s.name_simple} ({s.name_arabic})
                      </option>
                    ))}
                  </select>
                </div>
                
                <span className="text-mono-textSec font-bold pb-2 hidden sm:block">:</span>

                {/* Verse Input */}
                <div className="flex flex-col gap-1 w-full sm:w-auto">
                  <label className="text-[10px] uppercase tracking-wider text-mono-textSec font-semibold ml-1 whitespace-nowrap">
                    Ayah <span className="text-mono-textSec/50 font-normal normal-case hidden sm:inline">(1-{maxVerses})</span>
                  </label>
                  <input
                    type="number"
                    min="1"
                    max={maxVerses}
                    value={ayah}
                    onChange={(e) => setAyah(e.target.value)}
                    placeholder="1..."
                    className="w-full sm:w-20 px-3 py-2 rounded-md border border-mono-border bg-white text-mono-text placeholder-mono-textSec focus:ring-1 focus:ring-mono-text focus:border-mono-text outline-none transition-all text-sm font-mono shadow-sm"
                  />
                </div>
                
                {/* Font Selector */}
                <div className="flex flex-col gap-1 w-full sm:w-auto flex-1">
                  <label className="text-[10px] uppercase tracking-wider text-mono-textSec font-semibold ml-1">Font</label>
                  <select
                    value={selectedFont}
                    onChange={(e) => setSelectedFont(e.target.value as FontOption)}
                    className="w-full sm:w-40 px-3 py-2 rounded-md border border-mono-border bg-white text-mono-text focus:ring-1 focus:ring-mono-text focus:border-mono-text outline-none cursor-pointer text-sm shadow-sm"
                  >
                    {FONTS.map((f) => (
                      <option key={f.value} value={f.value}>
                        {f.label}
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              <button
                type="submit"
                disabled={loading}
                className="w-full sm:w-auto px-5 py-2 bg-mono-text hover:bg-mono-text/90 text-mono-bg font-medium text-sm rounded-md transition-all shadow-sm disabled:opacity-50 disabled:cursor-not-allowed whitespace-nowrap active:transform active:scale-95 h-[38px]"
              >
                {loading ? '...' : 'Go'}
              </button>
            </form>
          </div>
        </div>
      </div>

      {/* Main Content */}
      <main className="flex-1 max-w-4xl mx-auto w-full px-6 py-10 animate-fade-in">
        {error && (
          <div className="bg-red-50 text-mono-error border border-mono-error/20 rounded-lg p-4 mb-8 text-sm">
            <p className="font-semibold">Unable to load verse</p>
            <p className="opacity-80 mt-1">{error}</p>
          </div>
        )}

        {/* Basmala Comparison Toggle */}
        <div className="mb-8">
          <button
            onClick={() => setShowBasmala(!showBasmala)}
            className="px-4 py-2 text-sm border border-mono-border rounded-md hover:bg-gray-50 transition-colors"
          >
            {showBasmala ? 'Hide' : 'Show'} Basmala Comparison (﷽)
          </button>
        </div>

        {/* Basmala Comparison Section */}
        {showBasmala && (
          <div className="space-y-8 mb-12">
            <h2 className="text-lg font-semibold text-mono-text border-b border-mono-border pb-2">
              Basmala — All Fonts
            </h2>
            <p className="text-xs text-mono-textSec -mt-4">
              U+FDFD (﷽) is a single Unicode codepoint for the full Bismillah ligature.
              Compare how each font renders it vs the plain QPC text basmala from 1:1.
            </p>

            {FONTS.map((f) => (
              <BasmalaCard key={f.value} font={f.value} fontLabel={f.label} />
            ))}
          </div>
        )}

        {loading ? (
          <Loader />
        ) : verseData ? (
          <div className="space-y-8 pb-20">

            {/* Scripts Grid */}
            <div className="grid grid-cols-1 gap-8">

              {/* Tajweed Special Case */}
               <VerseCard
                  label={SCRIPT_LABELS['text_uthmani_tajweed']}
                  text={verseData.text_uthmani_tajweed}
                  font={selectedFont}
                  isHtml={true}
               />

               {/* Secondary Scripts Grid */}
               <div className="grid grid-cols-1 gap-8">
                  {Object.entries(SCRIPT_LABELS).map(([key, label]) => {
                    const value = verseData[key as keyof Verse];
                    // Skip the ones we already displayed prominently
                    if (['text_uthmani_tajweed'].includes(key)) return null;
                    if (typeof value !== 'string') return null;

                    return (
                      <VerseCard
                        key={key}
                        label={label}
                        text={value}
                        font={selectedFont}
                      />
                    );
                  })}

                  {/* Computed rasm (dotless skeleton) variants */}
                  <VerseCard
                    label="Rasm (from Uthmani)"
                    text={rasmify(verseData.text_uthmani)}
                    font={selectedFont}
                  />
                  <VerseCard
                    label="Rasm (from QPC Uthmani Hafs)"
                    text={rasmify(verseData.qpc_uthmani_hafs)}
                    font={selectedFont}
                  />
               </div>
            </div>
          </div>
        ) : (
          !error && (
            <div className="flex flex-col items-center justify-center py-20 text-mono-textSec gap-3">
              <div className="text-4xl opacity-20 font-serif">﴾ ﴿</div>
              <p className="text-sm">Select a Surah and Ayah to begin comparing scripts.</p>
            </div>
          )
        )}
      </main>
    </div>
  );
};

export default App;