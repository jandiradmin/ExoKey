import re, sys, collections
sys.path.insert(0, 'tools')
from build_dicts import norm, ok, RAW, HUN, MINCOUNT
import os
rep3 = re.compile(r'(.)\1\1')          # 3+ same letters in a row
for lang in ('ru','uk','en'):
    hun=set()
    with open(os.path.join(RAW, HUN[lang]+'_forms.txt'), encoding='utf-8', errors='ignore') as f:
        for line in f:
            t=line.split('/')[0].split('\t')[0].strip()
            if '=' in t: t=t.rsplit('=',1)[1]
            hun.add(norm(t,lang))
    total=0; bad=[]; notin=0; one=[]
    with open(os.path.join(RAW, lang+'_full.txt'), encoding='utf-8', errors='ignore') as f:
        for line in f:
            p=line.rsplit(' ',1)
            if len(p)!=2: continue
            w=norm(p[0],lang); c=int(p[1])
            if not ok(w,lang) or (c<MINCOUNT[lang] and w not in hun): continue
            total+=1
            if w not in hun:
                notin+=1
                if rep3.search(w): bad.append((c,w))
    bad.sort(reverse=True)
    print(f"== {lang}: из частотного списка {total}, нет в Hunspell {notin}, с 3+ одинаковыми буквами подряд {len(bad)}")
    print("   самые частые:", ', '.join(w for c,w in bad[:15]))
    print("   редкие:", ', '.join(w for c,w in bad[-10:]))
