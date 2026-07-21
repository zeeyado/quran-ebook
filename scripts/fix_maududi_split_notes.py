#!/usr/bin/env python
"""Redistribute over-restored Maududi footnotes — v3 (precise + keep-complete).

Fixes vs v2:
  (1) BOUNDARY is found by exact substring match of the next marker's head
      inside the master (both usually share a source, so the head appears
      verbatim -> exact split), falling back to fuzzy align; ALWAYS snapped
      to a word boundary so we never cut mid-word (the 49:1 "Th|is" bug).
  (2) An already-COMPLETE next marker is KEPT intact (its own upstream text);
      we only truncate the master. Only TRUNCATED/chain markers are
      completed from the master's tail. This stops us from overwriting a
      good note with a boundary-shifted copy.
Content-preserving: the tail is only ever dropped when the neighbour already
holds it complete; otherwise it moves forward. Left-to-right, so chains
(58:4, 47:4) unravel.
"""
import json, glob, re, difflib, unicodedata

FP="data/footnote_patches.json"
patches=json.load(open(FP))
pid={k for k,e in patches.items() if e.get("resource_id")==95}
raw,loc={},{}
for f in glob.glob(".cache/quran_api_trans95_ch*.json"):
    for v in json.load(open(f)).get("value",[]):
        vk=v.get("verse_key","?")
        for fid,t in (v.get("foot_notes") or {}).items():
            raw[str(fid)]=re.sub(r"\s+"," ",re.sub(r"<[^>]+>"," ",t)).strip(); loc[str(fid)]=vk
def L(i): return patches[i]["locus"] if i in patches else loc.get(i,"?")
def rend(i): return patches[i]["full"] if i in pid else raw.get(i)
allids=sorted(set(list(raw)+list(pid)),key=int)

def _c(s):
    s=unicodedata.normalize("NFC",s or "")
    for x,y in [("“",'"'),("”",'"'),("‘","'"),("’","'"),("—","-"),("–","-")]: s=s.replace(x,y)
    return s
def snap(master,pos):
    """Move pos back to the start of the current word (never > 25 chars)."""
    if pos<=0 or pos>=len(master): return pos
    p=pos
    while p>0 and not master[p-1].isspace():
        if pos-p>25: return pos
        p-=1
    return p
def overlap(a,b):
    if not a or not b: return 0
    return difflib.SequenceMatcher(None,a,b,autojunk=False).find_longest_match(0,len(a),0,len(b)).size/min(len(a),len(b))
def boundary(neighbor,master,floor):
    """Char in master where `neighbor` (the next marker) begins. None if weak."""
    nb=_c(neighbor); mc=_c(master)          # canon is length-preserving -> offsets valid
    for hl in (60,45,30):
        head=nb[:hl].strip()
        if len(head)<20: continue
        idx=mc.find(head,floor)
        if idx!=-1: return snap(master,idx)
    # fuzzy fallback
    head=nb[:220]; sub=mc[floor:]
    if not sub or not head: return None
    m=difflib.SequenceMatcher(None,sub,head,autojunk=False).find_longest_match(0,len(sub),0,len(head))
    if m.size<max(35,len(head)*0.45): return None
    return snap(master,floor+m.a-m.b)

def setfull(fid,text,prov):
    text=text.strip()
    if fid in pid:
        patches[fid]["full"]=text; patches[fid]["corrected"]="2026-07-21"
        patches[fid].setdefault("sources",[]).append(prov)
    else:
        patches[fid]={"resource_id":95,"locus":L(fid),"truncated":raw.get(fid,""),
                      "full":text,"corrected":"2026-07-21","sources":[prov]}
        pid.add(fid)

n_trunc=n_keep=n_complete=0
for i in range(len(allids)-1):
    m=allids[i]
    if m not in pid: continue
    a=patches[m]["full"]; nxt=allids[i+1]; b=rend(nxt)
    if not b or len(b)<40: continue
    floor=int(len(patches[m].get("truncated",""))*0.85)
    pos=boundary(b,a,floor)
    if pos is None or pos<20: continue
    tail=a[pos:]
    if len(tail)<0.4*len(b): continue
    # truncate master to its own segment (clean word boundary)
    setfull(m, a[:pos], f"2026-07-21 redistribution v3: truncated at char {pos} (word boundary); tail belonged to fn{nxt} (and beyond)."); n_trunc+=1
    # neighbour: KEEP it intact when it already holds the tail's content
    # (length >= 90% of the tail — the neighbour is a complete copy of note2,
    # possibly from a different source; keeping preserves its own verified
    # wording). Only COMPLETE it from the master tail when it's truncated.
    if len(b)>=len(tail)*0.9:
        n_keep+=1
    else:
        setfull(nxt, tail, f"2026-07-21 redistribution v3: completed from fn{m}'s over-restored tail (split Tafheem note)."); n_complete+=1

json.dump(patches,open(FP,"w"),ensure_ascii=False,indent=2); open(FP,"a").write("\n")
print(f"masters truncated: {n_trunc} | complete neighbours kept: {n_keep} | truncated neighbours completed: {n_complete}")
print(f"resource-95 patches: {sum(1 for e in patches.values() if e.get('resource_id')==95)} | corrected: {sum(1 for e in patches.values() if e.get('corrected')=='2026-07-21')}")
