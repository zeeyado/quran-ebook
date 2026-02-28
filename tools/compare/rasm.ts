/**
 * Rasm (consonantal skeleton) conversion for Arabic text.
 *
 * Converts dotted Arabic to its dotless rasm form by:
 * 1. Removing all diacritics and marks (tashkeel, Quranic annotations)
 * 2. Replacing dotted letters with their dotless Unicode equivalents
 * 3. Fixing lam-lam-heh to prevent incorrect Allah ligature
 *
 * Mapping derived from rasmipy (TELOTA, Berlin-Brandenburg Academy of Sciences)
 * and rasmifize (TypeScript port with positional yeh-with-hamza handling).
 */

/** Character replacement mapping: dotted Arabic --> dotless rasm */
const RASM_REPLACEMENTS: Record<string, string> = {
  '\u0622': '\u0627', // آ ALEF WITH MADDA ABOVE     --> ا ALEF
  '\u0623': '\u0627', // أ ALEF WITH HAMZA ABOVE     --> ا ALEF
  '\u0624': '\u0648', // ؤ WAW WITH HAMZA ABOVE      --> و WAW
  '\u0625': '\u0627', // إ ALEF WITH HAMZA BELOW     --> ا ALEF
  // U+0626 (ئ YEH WITH HAMZA) handled separately with positional logic
  '\u0628': '\u066E', // ب BEH                       --> ٮ DOTLESS BEH
  '\u0629': '\u0647', // ة TEH MARBUTA               --> ه HEH
  '\u062A': '\u066E', // ت TEH                       --> ٮ DOTLESS BEH
  '\u062B': '\u066E', // ث THEH                      --> ٮ DOTLESS BEH
  '\u062C': '\u062D', // ج JEEM                      --> ح HAH
  '\u062E': '\u062D', // خ KHAH                      --> ح HAH
  '\u0630': '\u062F', // ذ THAL                      --> د DAL
  '\u0632': '\u0631', // ز ZAIN                      --> ر REH
  '\u0634': '\u0633', // ش SHEEN                     --> س SEEN
  '\u0636': '\u0635', // ض DAD                       --> ص SAD
  '\u0638': '\u0637', // ظ ZAH                       --> ط TAH
  '\u063A': '\u0639', // غ GHAIN                     --> ع AIN
  '\u0641': '\u06A1', // ف FEH                       --> ڡ DOTLESS FEH
  '\u0642': '\u066F', // ق QAF                       --> ٯ DOTLESS QAF
  '\u0643': '\u06A9', // ك KAF                       --> ک KEHEH
  '\u0646': '\u06BA', // ن NOON                      --> ں NOON GHUNNA
  '\u064A': '\u0649', // ي YEH                       --> ى ALEF MAKSURA
  '\u06CC': '\u0649', // ی FARSI YEH                 --> ى ALEF MAKSURA
  '\u0671': '\u0627', // ٱ ALEF WASLA                --> ا ALEF
};

/** Regex matching all diacritics and marks to remove */
const RASM_REMOVALS = /[\u0615-\u061E\u0621\u0640\u064B-\u0656\u0670\u0674\u06D6-\u06DC\u06DF\u06E1-\u06E6\u06ED]/g;

/** Regex matching all replaceable characters */
const RASM_REPLACE_RE = /[\u0622\u0623\u0624\u0625\u0628\u0629\u062A\u062B\u062C\u062E\u0630\u0632\u0634\u0636\u0638\u063A\u0641\u0642\u0643\u0646\u064A\u06CC\u0671]/g;

/**
 * Convert Arabic text to its rasm (consonantal skeleton) form.
 * Works with any Arabic text encoding (Uthmani, QPC, Imlaei, etc.)
 */
export function rasmify(text: string): string {
  // Step 1: Remove diacritics and marks
  let result = text.replace(RASM_REMOVALS, '');

  // Step 2: Handle yeh-with-hamza positionally (rasmifize approach)
  // Word-final --> alef maksura, elsewhere --> dotless beh
  result = result.replace(/\u0626(?=\s|$)/g, '\u0649');
  result = result.replace(/\u0626/g, '\u066E');

  // Step 3: Apply all other letter replacements
  result = result.replace(RASM_REPLACE_RE, (ch) => RASM_REPLACEMENTS[ch] ?? ch);

  // Step 4: Insert ZWJ into lam-lam-heh to prevent incorrect Allah ligature
  result = result.replace(/\u0644\u0644\u0647/g, '\u0644\u0644\u200D\u0647');

  return result.trim();
}
