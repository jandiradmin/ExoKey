#!/usr/bin/env python3
"""Builds ExoKey binary dictionaries (.exd) from frequency lists + hunspell forms.

Sources (place into data/raw):
  {en,ru,uk}_full.txt          hermitdave/FrequencyWords (CC-BY-SA 4.0)
  {en_US,ru_RU,uk_UA}_forms.txt hunspell `unmunch` output of LibreOffice dictionaries

Format EXD2 (little-endian):
  magic 'EXD2', u32 nWords, u32 nBlocks, u32 blockSize, u32 dataLen
  u32 blockOffsets[nBlocks]
  u32 blockCum[nBlocks+1]        cumulative frequency before each block
  data: block = word0(varint len, bytes, varint freq) + rest(u8 shared, varint sufLen, bytes, varint freq)
Words: normalized, lowercase, sorted by UTF-8 bytes. Frequency: parts per billion (min 1).
"""
import os, re, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, 'data', 'raw')
OUT = os.path.join(ROOT, 'data', 'dict')
BLOCK = 32

ALPHA = {
    'en': set("abcdefghijklmnopqrstuvwxyz'-"),
    'ru': set("абвгдежзийклмнопрстуфхцчшщъыьэюя-"),
    'uk': set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'-"),
}
HUN = {'en': 'en_US', 'ru': 'ru_RU', 'uk': 'uk_UA'}
MINCOUNT = {'en': 5, 'ru': 3, 'uk': 2}   # for words absent from hunspell
REPEAT3 = re.compile(r'(.)\1\1')
REPEAT4 = re.compile(r'(.)\1\1\1')
COLLAPSE = re.compile(r'(.)\1+')
APOS = str.maketrans({'\u2019': "'", '\u02bc': "'", '`': "'", '\u00b4': "'"})


def norm(w, lang):
    w = w.strip().lower().translate(APOS)
    if lang == 'ru':
        w = w.replace('ё', 'е')
    return w


def ok(w, lang):
    if not w or len(w) > 32:
        return False
    if w[0] in "'-" or w[-1] in "'-" or '--' in w or "''" in w:
        return False
    return all(c in ALPHA[lang] for c in w)


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def build(lang):
    hun = set()
    caps = set()     # forms that appear capitalized in Hunspell (proper names)
    p = os.path.join(RAW, HUN[lang] + '_forms.txt')
    if os.path.exists(p):
        with open(p, encoding='utf-8', errors='ignore') as f:
            for line in f:
                t = line.split('/')[0].split('\t')[0].strip()
                if '=' in t:
                    t = t.rsplit('=', 1)[1]
                raw = t
                t = norm(t, lang)
                if not ok(t, lang):
                    continue
                if raw[:1].isupper() and raw[1:] == raw[1:].lower():
                    caps.add(t)
                else:
                    hun.add(t)
    names = caps - hun          # only ever written with a capital letter
    hun |= caps
    counts = {}
    with open(os.path.join(RAW, lang + '_full.txt'), encoding='utf-8', errors='ignore') as f:
        for line in f:
            parts = line.rsplit(' ', 1)
            if len(parts) != 2:
                continue
            w = norm(parts[0], lang)
            try:
                c = int(parts[1])
            except ValueError:
                continue
            if not ok(w, lang):
                continue
            if c < MINCOUNT[lang] and w not in hun:
                continue
            # subtitle noise: "дааа", "нееет", "mmm", "chffffff" (3+ same letters in a row)
            if w not in hun and REPEAT3.search(w):
                continue
            counts[w] = counts.get(w, 0) + c
    total = sum(counts.values()) or 1
    freq = {w: max(1, round(c * 1e9 / total)) for w, c in counts.items()}
    for w in hun:
        freq.setdefault(w, 1)
    # interjections even in Hunspell: "ааа", "бррр", "дуууже", "www" (4+ same letters, or 3+ in a short word)
    for w in [w for w in freq if REPEAT4.search(w) or (REPEAT3.search(w) and len(COLLAPSE.sub(r'\1', w)) <= 4)]:
        del freq[w]
    words = sorted(freq, key=lambda s: s.encode('utf-8'))

    data = bytearray()
    offsets, cums = [], []
    cum = 0
    prev = b''
    for i, w in enumerate(words):
        b = w.encode('utf-8')
        fr = freq[w]
        if i % BLOCK == 0:
            offsets.append(len(data))
            cums.append(cum)
            data += varint(len(b)) + b + varint(fr)
        else:
            s = 0
            m = min(len(b), len(prev), 255)
            while s < m and b[s] == prev[s]:
                s += 1
            data += bytes([s]) + varint(len(b) - s) + b[s:] + varint(fr)
        cum += fr
        prev = b
    cums.append(cum)
    if cum >= 2 ** 32:
        sys.exit('cum overflow for ' + lang)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, lang + '.exd'), 'wb') as f:
        f.write(b'EXD2')
        f.write(struct.pack('<IIII', len(words), len(offsets), BLOCK, len(data)))
        f.write(struct.pack('<%dI' % len(offsets), *offsets))
        f.write(struct.pack('<%dI' % len(cums), *cums))
        f.write(data)
    # frequency-list words unknown to Hunspell: slang, rare words and typos ("првиет", "recieve")
    with open(os.path.join(OUT, lang + '.unverified'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(sorted(w for w in counts if w not in hun and w in freq)))
    with open(os.path.join(OUT, lang + '.names'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(sorted(n for n in names if n in freq)))
    print(lang, 'names', len(names), end=' ')
    print(lang, 'words', len(words), 'hunspell', len(hun), 'freqlist', len(counts),
          'size MB', round(os.path.getsize(os.path.join(OUT, lang + '.exd')) / 1e6, 1))


if __name__ == '__main__':
    for l in (sys.argv[1:] or ['en', 'ru', 'uk']):
        build(l)
