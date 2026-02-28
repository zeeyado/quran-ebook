import React from 'react';
import { FontOption } from '../types';

interface VerseCardProps {
  label: string;
  text: string;
  font: FontOption;
  isHtml?: boolean;
}

export const VerseCard: React.FC<VerseCardProps> = ({ label, text, font, isHtml = false }) => {
  return (
    <div className="bg-white rounded-xl shadow-sm border border-gray-200 p-6 hover:shadow-md transition-shadow duration-200">
      <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4 border-b border-gray-100 pb-2">
        {label}
      </div>
      <div 
        className="w-full text-right leading-loose text-3xl sm:text-4xl text-slate-800"
        style={{ fontFamily: font }}
        dir="rtl"
      >
        {isHtml ? (
          <div dangerouslySetInnerHTML={{ __html: text }} />
        ) : (
          text
        )}
      </div>
    </div>
  );
};
