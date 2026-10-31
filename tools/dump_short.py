#!/usr/bin/env python3
"""Dump short dictionary words: python3 tools/dump_short.py [maxlen=3] -> data/dict/short_<lang>.txt
Columns: word, frequency (ppb; 1 = only in Hunspell, not seen in the frequency list)."""
import os, struct, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(ROOT, 'data', 'dict')
maxlen = int(sys.argv[1]) if len(sys.argv) > 1 else 3

def words(lang):
    b = open(os.path.join(D, lang + '.exd'), 'rb').read()
    n, nb, bs, _ = struct.unpack('<IIII', b[4:20])
    data = b[20 + nb * 4 + (nb + 1) * 4:]
    pos = 0; prev = b''
    def vi():
        nonlocal pos
        r = sh = 0
        while True:
            x = data[pos]; pos += 1; r |= (x & 0x7f) << sh
            if not x & 0x80: return r
            sh += 7
    for i in range(n):
        if i % bs == 0:
            L = vi(); w = data[pos:pos + L]; pos += L
        else:
            s = data[pos]; pos += 1; L = vi(); w = prev[:s] + data[pos:pos + L]; pos += L
        f = vi(); prev = w
        yield w.decode(), f

for lang in ('en', 'ru', 'uk'):
    out = os.path.join(D, f'short_{lang}.txt')
    with open(out, 'w', encoding='utf-8') as f:
        for ln in range(2, maxlen + 1):
            ws = sorted(((w, fr) for w, fr in words(lang) if len(w) == ln), key=lambda x: -x[1])
            f.write(f'== {ln} букв: {len(ws)} слов (сначала частые; частота 1 = только из Hunspell)\n')
            for w, fr in ws:
                f.write(f'{w}\t{fr}\n')
            f.write('\n')
    print(lang, out)
