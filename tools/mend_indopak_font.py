"""Make the IndoPak font the books carry: a changed copy of the source font.

  python tools/mend_indopak_font.py <source font> <font out> [--log FILE]
  python tools/mend_indopak_font.py --check <source font>

The source font is "AlQuran IndoPak by QuranWBW", version 2.100 (the registry
gives its address and checksum). The books carry the copy this tool makes of
it; the copy lies in src/quran_ebook/assets/fonts/ and the registry pins its
checksum. --check makes the copy again in memory and says whether it is the
file in the repo, byte for byte. The result is the same every time with the
fontTools version of requirements.lock.

No glyph outline is touched. What changes, and why:

F. The room of a pause sign. The text writes a pause sign as: word,
   no-break space, sign(s), space. The source font turns the space before
   the sign into a carrier of no width (glyph space.ccmp, a mark) and widens
   the space AFTER the sign by 550 units. Apple's text engine (Apple Books,
   Safari, every reader built on WebKit) gives every space and no-break
   space the font's plain width after shaping, so both tricks are undone
   there: every pause sign of the book stood against the NEXT word. KOReader
   squeezes spaces to fill a line, so in tight lines a sign lost its room
   there too, and on word-by-word pages it hung out of its word's box.
   The copy agrees with "every space has its plain width":
   1. the carrier is no longer a mark (GDEF class 3 -> 2) and keeps the
      plain space width (604);
   2. the lookups that stack signs on the carrier still see it (GPOS 3 to
      8: flag 7 -> 3), and every mark on the carrier is moved back by 604;
   3. the room after the signs is carried inside the sign's own word, by a
      new empty glyph, room.back, that GSUB puts after the last mark of
      every stack on a carrier. Its advance is set from what stands BEFORE
      it: -604 by default, -54 after a sign (604 - 54 + a plain space of
      604 = the source font's 0 + 1154), -604 after u06D8 or after u0615
      that follows u06D8 (those stacks are followed by a small label, never
      by a widened space). Nothing inside a word may depend on what follows
      its space: WebKit and KOReader draw word by word;
   4. the one label after a sign stack that these rules cannot tell from
      the stacks a space follows (uniF64F, 6:73) is moved by +550, also
      under a DFLT script, because an engine shapes a private-use label as
      a run of its own;
   5. GPOS 18 (alef, space, alef) gets a second subtable that names the
      two glyphs which now stand between;
   6. u0614 (the takhallus sign) was attached to the last letter before
      the carrier, because the search for its base skipped the carrier (a
      mark). New lookups place it where that attachment placed it: one
      rule per anchor offset, read from the source font's own lookups 20
      to 22, behind a mark filtering set (GDEF becomes version 1.2).
   Result: HarfBuzz (KOReader, Chromium) puts every glyph's ink where the
   source font puts it in 6,235 of 6,236 ayahs (6:73 gets 550 units more
   room after its sign), and Apple's engine now does the same.
   Side effect: a word that ends in a pause sign is 550 units wider when
   it closes a line.

A, B, C. Three places where Apple's shaper and HarfBuzz read the source
   font differently (seven ayahs):
   A. alef + superscript alef + maddah (U+0627 U+0670 U+0653): HarfBuzz
      composes alef and maddah before the font sees them, Apple's shaper
      does not. One chained rule in 'ccmp' gives Apple's shaper the same.
   B. two stop signs on one carrier (U+06D6 or U+06EB, then U+06EA):
      HarfBuzz reorders them by their canonical class, Apple's shaper keeps
      the typed order, and the font stacks them in the order it gets. One
      chained rule per pair swaps them for Apple's shaper.
   C. kaf before lam (GPOS 17): the pair moved the kaf by an x placement
      that HarfBuzz folds into the cursive join that follows and Apple's
      shaper does not. The copy writes what HarfBuzz makes of it: an x
      advance of minus the value for an initial kaf, nothing for a medial
      one.

Not mended by this copy: six pause signs that the text writes straight on a
letter with no no-break space (3:2, 76:16, 2:219, 2:259, 40:62, 57:10), and
four signs right after a small label (2:178, 3:36 twice, 3:195).

The copy says what it is: a description record in its name table. The
author's own records (copyright, licence note, contact) are kept as they are.
"""
import hashlib
import sys
from io import BytesIO
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import otTables as ot
from fontTools.ttLib.tables._g_l_y_f import Glyph
from fontTools.ttLib.tables.otBase import ValueRecord

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

FONT_KEY = "indopak_nastaleeq"
CARRIER = "space.ccmp"
SHIFT = 604  # the plain space advance
ROOM = "room.back"
TAKHALLUS = "u0614"
DEPTH = 6  # longest sign stack handled (the text has at most 4 marks on a carrier)
# The time written into the copy when its first part was first made. Kept,
# so that the tool gives the same file every time.
FIRST_PART_MODIFIED = 3877893037
NOTE = (
    "A changed copy of AlQuran IndoPak by QuranWBW, version 2.100, made for "
    "the books of the quran-ebook project (github.com/zeeyado/quran-ebook). "
    "No glyph outline is touched. Changed: the rules that place the pause "
    "signs, so that every text engine draws a sign beside its own word, and "
    "three small rules for Apple's text engine. This is not the author's "
    "file. The author's own notes in this font are kept as they are."
)


def _cov(glyphs, order=None):
    c = ot.Coverage()
    c.glyphs = sorted(set(glyphs), key=order.index) if order else list(glyphs)
    return c


def _records(kind, pairs):
    out = []
    for seq, lookup in pairs:
        r = kind()
        r.SequenceIndex = seq
        r.LookupListIndex = lookup
        out.append(r)
    return out


# --- A, B, C -----------------------------------------------------------

def apply_abc(tt: TTFont, log: list[str]) -> None:
    gsub = tt["GSUB"].table

    def add_gsub_lookup(ltype, flag, subtable):
        lk = ot.Lookup()
        lk.LookupType = ltype
        lk.LookupFlag = flag
        lk.SubTable = [subtable]
        lk.SubTableCount = 1
        gsub.LookupList.Lookup.append(lk)
        gsub.LookupList.LookupCount = len(gsub.LookupList.Lookup)
        return len(gsub.LookupList.Lookup) - 1

    def single(mapping):
        st = ot.SingleSubst()
        st.mapping = dict(mapping)
        return st

    def ligature(first, comps, out):
        st = ot.LigatureSubst()
        lig = ot.Ligature()
        lig.Component = comps
        lig.LigGlyph = out
        lig.CompCount = len(comps) + 1
        st.ligatures = {first: [lig]}
        return st

    def chain(inputs, pairs):
        st = ot.ChainContextSubst()
        st.Format = 3
        st.BacktrackCoverage = []
        st.InputCoverage = [_cov([g]) for g in inputs]
        st.LookAheadCoverage = []
        st.BacktrackGlyphCount = 0
        st.InputGlyphCount = len(inputs)
        st.LookAheadGlyphCount = 0
        st.SubstLookupRecord = _records(ot.SubstLookupRecord, pairs)
        st.SubstCount = len(pairs)
        return st

    def add_to_feature(tag, lookup):
        for fr in gsub.FeatureList.FeatureRecord:
            if fr.FeatureTag == tag:
                fr.Feature.LookupListIndex.append(lookup)
                fr.Feature.LookupCount = len(fr.Feature.LookupListIndex)
                return
        raise SystemExit(f"no feature {tag}")

    # C
    for st in tt["GPOS"].table.LookupList.Lookup[17].SubTable:
        st.ValueFormat1 = 0x0004  # XAdvance only
        for first, ps in zip(st.Coverage.glyphs, st.PairSet):
            for r in ps.PairValueRecord:
                old = r.Value1.XPlacement
                v = ot.ValueRecord()
                v.XAdvance = -old if ".init" in first else 0
                r.Value1 = v
                log.append(f"GPOS lookup 17: {first} + {r.SecondGlyph}: "
                           f"XPlacement {old} -> XAdvance {v.XAdvance}")
    # A
    l_single = add_gsub_lookup(1, 0, single({"u0627": "u0622"}))
    l_lig = add_gsub_lookup(4, 0, ligature("u0670", ["u0653"], "u0670"))
    l_chain = add_gsub_lookup(
        6, 0, chain(["u0627", "u0670", "u0653"], [(0, l_single), (1, l_lig)]))
    add_to_feature("ccmp", l_chain)
    log.append(f"GSUB: new lookups {l_single} (u0627->u0622), {l_lig} "
               f"(u0670 u0653 -> u0670), {l_chain} (chain u0627 u0670 u0653, in ccmp)")
    # B
    to_ea = add_gsub_lookup(1, 0, single({"u06D6": "u06EA", "u06EB": "u06EA"}))
    for sign in ("u06D6", "u06EB"):
        back = add_gsub_lookup(1, 0, single({"u06EA": sign}))
        # flag 1 as the font's own ccmp chains: marks are not skipped
        ch = add_gsub_lookup(6, 1, chain([sign, "u06EA"], [(0, to_ea), (1, back)]))
        add_to_feature("ccmp", ch)
        log.append(f"GSUB: new lookups {to_ea}/{back}/{ch}: {sign} u06EA -> "
                   f"u06EA {sign} (in ccmp)")


# --- F -----------------------------------------------------------------

def apply_f(tt: TTFont, log: list[str]) -> None:
    gdef = tt["GDEF"].table
    gpos = tt["GPOS"].table
    classes = gdef.GlyphClassDef.classDefs
    order = tt.getGlyphOrder()
    lookups = gpos.LookupList.Lookup

    signs = list(lookups[0].SubTable[0].Coverage.glyphs)  # the 19 pause signs
    assert len(signs) == 19, signs

    # 1: the carrier keeps a width
    old = classes.get(CARRIER)
    classes[CARRIER] = 2
    log.append(f"GDEF GlyphClassDef: {CARRIER} class {old} -> 2")
    old = tt["hmtx"].metrics[CARRIER]
    tt["hmtx"].metrics[CARRIER] = (SHIFT, old[1])
    log.append(f"hmtx: {CARRIER} advance {old[0]} -> {SHIFT} (lsb {old[1]})")

    marks = sorted((g for g, c in classes.items() if c == 3), key=order.index)

    # 2: the stacking lookups still see the carrier
    for li in (3, 4, 5, 6, 7, 8):
        log.append(f"GPOS lookup {li}: LookupFlag {lookups[li].LookupFlag} -> 3")
        lookups[li].LookupFlag = 3

    def cov(glyphs):
        return _cov(glyphs, order)

    def vrec(**kw):
        v = ValueRecord()
        for k, val in kw.items():
            setattr(v, k, val)
        return v

    def vformat(**kw):
        f = 0
        for k in kw:
            f |= {"XPlacement": 1, "YPlacement": 2, "XAdvance": 4, "YAdvance": 8}[k]
        return f

    def add_lookup(ltype, flag, subtables, mark_set=None):
        lk = ot.Lookup()
        lk.LookupType = ltype
        lk.LookupFlag = flag
        lk.SubTable = subtables
        lk.SubTableCount = len(subtables)
        if mark_set is not None:
            lk.MarkFilteringSet = mark_set
        lookups.append(lk)
        gpos.LookupList.LookupCount = len(lookups)
        return len(lookups) - 1

    def single_pos(glyphs, **kw):
        st = ot.SinglePos()
        st.Format = 1
        st.Coverage = cov(glyphs)
        st.ValueFormat = vformat(**kw)
        st.Value = vrec(**kw)
        return st

    def chain_pos(back, inp, look, pairs):
        st = ot.ChainContextPos()
        st.Format = 3
        st.BacktrackCoverage = [cov(g) for g in back]
        st.InputCoverage = [cov(g) for g in inp]
        st.LookAheadCoverage = [cov(g) for g in look]
        st.BacktrackGlyphCount = len(back)
        st.InputGlyphCount = len(inp)
        st.LookAheadGlyphCount = len(look)
        st.PosLookupRecord = _records(ot.PosLookupRecord, pairs)
        st.PosCount = len(pairs)
        return st

    def add_to_kern(lookup):
        for fr in gpos.FeatureList.FeatureRecord:
            if fr.FeatureTag == "kern":
                fr.Feature.LookupListIndex.append(lookup)
                fr.Feature.LookupCount = len(fr.Feature.LookupListIndex)

    # every mark on the carrier: back by the carrier's new width
    p604 = add_lookup(1, 1, [single_pos(marks, XPlacement=SHIFT)])
    m_subs = [
        chain_pos([[CARRIER]] if k == 0 else [marks] * k + [[CARRIER]],
                  [marks], [], [(0, p604)])
        for k in range(DEPTH)
    ]
    m = add_lookup(8, 1, m_subs)
    add_to_kern(m)
    log.append(f"GPOS: new lookup {p604} (SinglePos, all {len(marks)} mark-class "
               f"glyphs, XPlacement +{SHIFT}, flag 1); new lookup {m} "
               f"(ChainContextPos flag 1, in 'kern', {len(m_subs)} subtables: "
               f"backtrack carrier or 1-{DEPTH - 1} marks then carrier, input any "
               f"mark -> {p604})")

    # 3: the room after the stack, carried by a new empty glyph
    for tag in ("glyf", "hmtx", "GDEF", "GSUB", "GPOS", "post", "cmap"):
        tt[tag]  # decompile before the glyph order changes
    tt.setGlyphOrder(list(tt.getGlyphOrder()) + [ROOM])
    order = tt.getGlyphOrder()
    tt["glyf"][ROOM] = Glyph()
    tt["hmtx"].metrics[ROOM] = (0, 0)
    classes[ROOM] = 1
    log.append(f"new glyph {ROOM} (glyph id {order.index(ROOM)}): empty outline, "
               "hmtx advance 0, GDEF class 1 (base)")
    gsub = tt["GSUB"].table

    def add_gsub_lookup(ltype, flag, subtables):
        lk = ot.Lookup()
        lk.LookupType = ltype
        lk.LookupFlag = flag
        lk.SubTable = subtables
        lk.SubTableCount = len(subtables)
        gsub.LookupList.Lookup.append(lk)
        gsub.LookupList.LookupCount = len(gsub.LookupList.Lookup)
        return len(gsub.LookupList.Lookup) - 1

    def chain_sub(back, inp, look, pairs):
        st = ot.ChainContextSubst()
        st.Format = 3
        st.BacktrackCoverage = [cov(g) for g in back]
        st.InputCoverage = [cov(g) for g in inp]
        st.LookAheadCoverage = [cov(g) for g in look]
        st.BacktrackGlyphCount = len(back)
        st.InputGlyphCount = len(inp)
        st.LookAheadGlyphCount = len(look)
        st.SubstLookupRecord = _records(ot.SubstLookupRecord, pairs)
        st.SubstCount = len(pairs)
        return st

    ms = ot.MultipleSubst()
    ms.mapping = {g: [g, ROOM] for g in marks}
    l_mult = add_gsub_lookup(2, 1, [ms])
    backs = [[[CARRIER]] if k == 0 else [marks] * k + [[CARRIER]] for k in range(DEPTH)]
    # a mark with a mark after it: no action; else it is the last: insert
    subs = [chain_sub(b, [marks], [marks], []) for b in backs]
    subs += [chain_sub(b, [marks], [], [(0, l_mult)]) for b in backs]
    l_ins = add_gsub_lookup(6, 1, subs)
    for fr in gsub.FeatureList.FeatureRecord:
        if fr.FeatureTag == "ccmp":
            fr.Feature.LookupListIndex.append(l_ins)
            fr.Feature.LookupCount = len(fr.Feature.LookupListIndex)
    log.append(f"GSUB: new lookup {l_mult} (MultipleSubst, flag 1: each of the "
               f"{len(marks)} marks -> the mark, {ROOM}); new lookup {l_ins} "
               f"(ChainContextSubst flag 1, appended to 'ccmp', {len(subs)} "
               f"subtables: {ROOM} follows the last mark of every stack on a carrier)")
    nb604 = add_lookup(1, 1, [single_pos([ROOM], XAdvance=-SHIFT)])
    add_to_kern(nb604)
    wide = lookups[33].SubTable[0].Value.XAdvance  # 550: the source font's room
    signs_not_meem = [g for g in signs if g != "u06D8"]
    p550 = add_lookup(1, 1, [single_pos([ROOM], XAdvance=wide)])
    c550 = add_lookup(8, 1, [chain_pos([signs_not_meem], [[ROOM]], [], [(0, p550)])])
    add_to_kern(c550)
    m550 = add_lookup(1, 1, [single_pos([ROOM], XAdvance=-wide)])
    cm550 = add_lookup(8, 1, [chain_pos([["u0615"], ["u06D8"]], [[ROOM]], [], [(0, m550)])])
    add_to_kern(cm550)
    log.append(f"GPOS: new lookup {nb604} ({ROOM} XAdvance -{SHIFT}, in 'kern'); "
               f"{p550} and {c550} ({ROOM} right after one of the "
               f"{len(signs_not_meem)} signs other than u06D8: +{wide}, net "
               f"-{SHIFT - wide}); {m550} and {cm550} ({ROOM} right after u0615 "
               f"that follows u06D8: -{wide}, net -{SHIFT})")

    # 4: the label of 6:73
    lab = add_lookup(1, 1, [single_pos(["uniF64F"], XPlacement=wide)])
    add_to_kern(lab)
    fr = ot.FeatureRecord()
    fr.FeatureTag = "kern"
    fr.Feature = ot.Feature()
    fr.Feature.FeatureParams = None
    fr.Feature.LookupListIndex = [lab]
    fr.Feature.LookupCount = 1
    gpos.FeatureList.FeatureRecord.append(fr)
    gpos.FeatureList.FeatureCount = len(gpos.FeatureList.FeatureRecord)
    fidx = gpos.FeatureList.FeatureCount - 1
    sr = ot.ScriptRecord()
    sr.ScriptTag = "DFLT"
    sr.Script = ot.Script()
    sr.Script.DefaultLangSys = ot.LangSys()
    sr.Script.DefaultLangSys.LookupOrder = None
    sr.Script.DefaultLangSys.ReqFeatureIndex = 0xFFFF
    sr.Script.DefaultLangSys.FeatureIndex = [fidx]
    sr.Script.DefaultLangSys.FeatureCount = 1
    sr.Script.LangSysRecord = []
    sr.Script.LangSysCount = 0
    gpos.ScriptList.ScriptRecord.insert(0, sr)
    gpos.ScriptList.ScriptCount = len(gpos.ScriptList.ScriptRecord)
    log.append(f"GPOS: new lookup {lab} (uniF64F XPlacement +{wide}), in the "
               f"'arab' 'kern' and in a new script DFLT whose only feature is "
               f"FeatureRecord {fidx} 'kern' = [{lab}]")

    # 5: lookup 18 (alef form, space, alef: the second alef 50 units further)
    l18 = lookups[18]
    assert len(l18.SubTable) == 1
    o18 = l18.SubTable[0]
    alef_forms = list(o18.BacktrackCoverage[0].glyphs)
    inp18 = [list(c.glyphs) for c in o18.InputCoverage]
    rec18 = [(r.SequenceIndex, r.LookupListIndex) for r in o18.PosLookupRecord]
    l18.SubTable.append(chain_pos([[ROOM], [CARRIER], alef_forms], inp18, [], rec18))
    l18.SubTableCount = len(l18.SubTable)
    log.append(f"GPOS lookup 18: new 2nd subtable: backtrack {ROOM}, the carrier, "
               f"then {alef_forms}; input {inp18}; -> {rec18}")

    # 6: u0614, attached to the letter before the carrier, reproduced
    acc_x = lookups[35].SubTable[0].Value.XPlacement  # what lookup 3 gives
    acc_y = lookups[0].SubTable[0].Value.YPlacement   # what lookup 0 gives
    target = {}  # base glyph -> (dx, dy) as the source font's attachment gives it
    for li in (20, 21, 22):  # in the order a shaper applies them; a later one wins
        st = lookups[li].SubTable[0]
        mc = list(st.MarkCoverage.glyphs)
        if TAKHALLUS not in mc:
            continue
        mr = st.MarkArray.MarkRecord[mc.index(TAKHALLUS)]
        cl, mx, my = mr.Class, mr.MarkAnchor.XCoordinate, mr.MarkAnchor.YCoordinate
        if lookups[li].LookupType == 4:
            for g, br in zip(st.BaseCoverage.glyphs, st.BaseArray.BaseRecord):
                a = br.BaseAnchor[cl]
                if a is not None:
                    target[g] = (a.XCoordinate - mx, a.YCoordinate - my)
        else:
            for g, la in zip(st.LigatureCoverage.glyphs, st.LigatureArray.LigatureAttach):
                a = la.ComponentRecord[-1].LigatureAnchor[cl]
                if a is not None:
                    target[g] = (a.XCoordinate - mx, a.YCoordinate - my)
    groups = {}
    for g, t in target.items():
        groups.setdefault(t, []).append(g)
    if gdef.Version < 0x00010002 or getattr(gdef, "MarkGlyphSetsDef", None) is None:
        gdef.Version = 0x00010002
        gdef.MarkGlyphSetsDef = ot.MarkGlyphSetsDef()
        gdef.MarkGlyphSetsDef.MarkSetTableFormat = 1
        gdef.MarkGlyphSetsDef.Coverage = []
        log.append("GDEF: version 1.0 -> 1.2 (adds MarkGlyphSetsDef)")
    gdef.MarkGlyphSetsDef.Coverage.append(cov([TAKHALLUS]))
    gdef.MarkGlyphSetsDef.MarkSetCount = len(gdef.MarkGlyphSetsDef.Coverage)
    mset = gdef.MarkGlyphSetsDef.MarkSetCount - 1
    log.append(f"GDEF: mark filtering set {mset} = [{TAKHALLUS}]")
    u_subs = []
    first_e = None
    for (dx, dy), glyphs in sorted(groups.items()):
        e = add_lookup(1, 1, [single_pos([TAKHALLUS], XPlacement=dx - acc_x,
                                         YPlacement=dy - acc_y)])
        first_e = e if first_e is None else first_e
        u_subs.append(chain_pos([[CARRIER], glyphs], [[TAKHALLUS]], [], [(0, e)]))
    u = add_lookup(8, 1 | 0x10, u_subs, mark_set=mset)
    add_to_kern(u)
    log.append(f"GPOS: new lookups {first_e}-{u - 1} ({len(groups)} SinglePos on "
               f"{TAKHALLUS}, one per anchor offset) and {u} (ChainContextPos, "
               f"right to left + mark filtering set {mset}, in 'kern', "
               f"{len(u_subs)} subtables, {len(target)} base or ligature glyphs)")
    # a u0614 that is not the first sign: the attachment overwrote the y of
    # lookups 36, 37, 38; give it back
    attachable = sorted(target, key=order.index)
    u2_subs = []
    y_lookups = []
    for k, yc in {1: 600, 2: 1200, 3: 1500}.items():
        y = add_lookup(1, 1, [single_pos([TAKHALLUS], YPlacement=yc)])
        y_lookups.append(y)
        for j in range(0, 5):  # 0-4 marks on the letter before the carrier
            u2_subs.append(chain_pos(
                [signs] * k + [[CARRIER]] + [marks] * j + [attachable],
                [[TAKHALLUS]], [], [(0, y)]))
    u2 = add_lookup(8, 1, u2_subs)
    add_to_kern(u2)
    log.append(f"GPOS: new lookups {y_lookups[0]}-{y_lookups[-1]} ({TAKHALLUS} "
               f"YPlacement +600 / +1200 / +1500) and {u2} (ChainContextPos flag "
               f"1, in 'kern', {len(u2_subs)} subtables)")


def make(source: bytes, note: bool = True) -> tuple[bytes, list[str]]:
    """The changed copy of the source font, and the list of its changes."""
    log: list[str] = []
    # recalcTimestamp=False: the file keeps the times it is given here
    tt = TTFont(BytesIO(source), recalcTimestamp=False)
    apply_abc(tt, log)
    tt["head"].modified = FIRST_PART_MODIFIED
    first = BytesIO()
    tt.save(first)
    tt = TTFont(BytesIO(first.getvalue()), recalcTimestamp=False)
    apply_f(tt, log)
    if note:
        tt["name"].setName(NOTE, 10, 3, 1, 0x409)
        log.append("name: new record 10 (description): " + NOTE)
    out = BytesIO()
    tt.save(out)
    return out.getvalue(), log


def main(argv: list[str]) -> int:
    from quran_ebook.config.registry import FONTS

    info = FONTS[FONT_KEY]
    check = "--check" in argv
    log_path = argv[argv.index("--log") + 1] if "--log" in argv else None
    paths = [a for i, a in enumerate(argv)
             if not a.startswith("--") and (i == 0 or argv[i - 1] != "--log")]
    if (check and len(paths) != 1) or (not check and len(paths) != 2):
        print(__doc__)
        return 2
    source = Path(paths[0]).read_bytes()
    found = hashlib.sha256(source).hexdigest()
    if found != info.made_from_sha256:
        print(f"the source font is not the file the registry names "
              f"(sha256 {found}, expected {info.made_from_sha256})")
        return 1
    data, log = make(source)
    sha = hashlib.sha256(data).hexdigest()
    if log_path:
        Path(log_path).write_text("\n".join(log) + "\n", encoding="utf-8")
    if check:
        bundled = ROOT / "src" / "quran_ebook" / "assets" / "fonts" / info.filename
        same = bundled.read_bytes() == data
        print(f"made {sha}; registry {info.sha256}; file in the repo: "
              f"{'the same' if same else 'DIFFERENT'}")
        return 0 if same and sha == info.sha256 else 1
    Path(paths[1]).write_bytes(data)
    print(f"{paths[1]}: {len(data):,} bytes, sha256 {sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
