#!/usr/bin/env python3
"""Typing simulation: replays the user's real sent messages (ai-samples snapshot, held-out split) letter by letter,
asks for a suggestion the way the app does and accepts it word by word only when it is right.
Prints aggregate numbers only, never the text.
Usage: typing_sim.py MODEL_FILE [--lora ADAPTER.gguf] [--conf 0|1|2] [--no-screen] [--limit N]"""
import json, os, re, subprocess, sys, time, urllib.request, math, argparse, random
AI = os.path.expanduser('~/Library/Application Support/ExoKey/ai')
ENGINE = os.path.join(AI, 'engine/llama-b11840/llama-server')
PORT = 8791
FIRST = [0.12, 0.05, 0.03]     # same as AIModel.minFirstWordProb
TOKEN = [0.45, 0.30, 0.20]     # same as AIModel.minTokenProb
WORD = re.compile(r"[\w'’-]+", re.U)

def load():
    snap = os.path.join(AI, 'bench', 'samples-snapshot2.jsonl')
    rows = []
    for l in open(snap, encoding='utf-8'):
        try: rows.append(json.loads(l))
        except Exception: pass
    return rows

def split(rows):
    """Held-out test = every 5th message (never used for training)."""
    return [r for i, r in enumerate(rows) if i % 5 == 0], [r for i, r in enumerate(rows) if i % 5 != 0]

def style_examples(train, app, n=6, seed=0):
    pool = [r['final'] for r in train if r.get('app', '') == app and len(r.get('final', '')) > 15]
    rnd = random.Random(seed); rnd.shuffle(pool)
    return [p.replace('\n', ' ')[:200] for p in pool[:n]]

def prompt(styles, screen, draft):
    head = ('How I write:\n' + '\n'.join('- ' + s for s in styles) + '\n\n') if styles else ''
    screen = screen[-2500:].strip()
    if screen: head += 'Screen:\n' + screen + '\n\n'
    return head + 'My message:\n' + draft

def ask(p, conf):
    body = {'prompt': p, 'n_predict': 24, 'temperature': 0, 'cache_prompt': True, 'stop': ['\n'], 'n_probs': 1}
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/completion', json.dumps(body).encode(), {'Content-Type': 'application/json'})
    r = json.load(urllib.request.urlopen(req, timeout=60))
    # replay the app's confidence gate on the token stream
    acc, total, first_done = '', 1.0, False
    for t in r.get('completion_probabilities', []):
        piece, pr = t.get('token', ''), math.exp(t.get('logprob', -99))
        if re.search(r'[⺀-퟿豈-￯]', piece): break
        if first_done and piece and pr < TOKEN[conf]: break
        total *= pr; acc += piece
        if not first_done:
            s = acc.lstrip(' ')
            m = re.search(r"[\w]", s)
            if m and re.search(r"[^\w'’-]", s[m.start():]):
                if total < FIRST[conf]: return ''
                first_done = True
    if not first_done and total < FIRST[conf]: return ''
    return acc

def ask_word(p):
    """Model's completion of the word being typed and the probability of that whole word."""
    body = {'prompt': p, 'n_predict': 8, 'temperature': 0, 'cache_prompt': True, 'stop': ['\n'], 'n_probs': 1}
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/completion', json.dumps(body).encode(), {'Content-Type': 'application/json'})
    r = json.load(urllib.request.urlopen(req, timeout=60))
    acc, total = '', 1.0
    for t in r.get('completion_probabilities', []):
        piece, pr = t.get('token', ''), math.exp(t.get('logprob', -99))
        m = re.match(r"[\w'’-]*", piece)
        acc += m.group(0); total *= pr
        if len(m.group(0)) < len(piece): break
    return acc, total

def model_first_tokens(p):
    body = {'prompt': p, 'n_predict': 1, 'temperature': 0, 'cache_prompt': True, 'n_probs': 12}
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/completion', json.dumps(body).encode(), {'Content-Type': 'application/json'})
    r = json.load(urllib.request.urlopen(req, timeout=60))
    cp = r.get('completion_probabilities', [])
    return [(t['token'], math.exp(t['logprob'])) for t in (cp[0].get('top_logprobs', []) if cp else [])]

def dict_candidates(partial, k=12):
    import bisect
    pl = partial.lower().replace('ё', 'е')
    cyr = bool(re.search('[а-яіїєґ]', pl))
    cands = {}
    for lang in (('ru', 'uk') if cyr else ('en',)):
        words, freqs = DICTS[lang]
        i = bisect.bisect_left(words, pl)
        while i < len(words) and words[i].startswith(pl):
            if len(words[i]) > len(pl): cands[words[i]] = max(cands.get(words[i], 0), freqs[i])
            i += 1
    for w, c in USER_WORDS.items():
        if w.startswith(pl) and len(w) > len(pl): cands[w] = cands.get(w, 0) + c * 200000
    return sorted(cands.items(), key=lambda x: -x[1])[:k]

def rerank(partial, toks, min_mass):
    """Dictionary spellings, ordered by how much the model's next-token distribution supports each."""
    best, best_m = None, 0.0
    for w, f in dict_candidates(partial):
        rest = w[len(partial):]
        m = sum(p for t, p in toks if t and rest.startswith(t.lower()))
        if m > best_m: best, best_m = rest, m
    return best if best and best_m >= min_mass else ''

GRAM_PROB = [0.0]
def grammar_pick(p, partial, cands):
    """The model chooses the ending, but only among dictionary forms (GBNF grammar): grammar by the model,
    spelling by the dictionary."""
    rests = [w[len(partial.lower().replace('ё', 'е')):] for w, _ in cands]
    rests = [r for r in rests if r and re.fullmatch(r"[\w'’-]+", r)]
    if len(rests) < 2: return rests[0] if rests else ''
    alts = ' | '.join(json.dumps(r, ensure_ascii=False) for r in rests)
    body = {'prompt': p, 'n_predict': 12, 'temperature': 0, 'cache_prompt': True, 'grammar': 'root ::= ' + alts, 'n_probs': 1}
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/completion', json.dumps(body, ensure_ascii=False).encode(), {'Content-Type': 'application/json'})
    r = json.load(urllib.request.urlopen(req, timeout=60))
    out = r.get('content', '')
    prob = 1.0
    for t in r.get('completion_probabilities', []): prob *= math.exp(t.get('logprob', -99))
    GRAM_PROB[0] = prob
    return out if out in rests else ''

def filtered_completion(partial, toks, rule):
    """The model rules out unlikely words (by its next-token probabilities), the dictionary picks among the rest."""
    cands = dict_candidates(partial, 12)
    if not cands: return ''
    pl = partial.lower().replace('ё', 'е')
    scored = []
    for w, f in cands:
        rest = w[len(pl):]
        m = sum(p for t, p in toks if t and rest.startswith(t.lower()))
        scored.append((w, f * (m + rule.get('eps', 0.01))))
    scored.sort(key=lambda x: -x[1])
    tot = sum(x[1] for x in scored)
    if tot <= 0: return ''
    top = scored[0]; second = scored[1][1] if len(scored) > 1 else 0
    if top[1] / tot >= rule['share'] or (second and top[1] >= rule['ratio'] * second and top[1] / tot >= rule['share'] / 2):
        return top[0][len(pl):]
    return ''

def is_word(w):
    import bisect
    lw = w.lower().replace('ё', 'е')
    if lw in USER_WORDS: return True
    for lang in ('en', 'ru', 'uk'):
        words, _ = DICTS[lang]
        i = bisect.bisect_left(words, lw)
        if i < len(words) and words[i] == lw: return True
    return False

def screen_completion(screen, before, partial):
    """Port of Predictor.contextCompletion."""
    src = screen + '\n' + before[-3000:]
    toks = []
    for m in re.finditer(r"[\w'’]+(?:-[\w'’]+)*", src):
        gap = src[toks[-1][2]:m.start()] if toks else ''
        toks.append((m.group(0), m.group(0).lower(), m.end(), bool(re.search(r'[.!?;:\n()\[\]"«»]', gap))))
    if len(toks) < 3: return ''
    typed = [w.lower() for w in WORD.findall(before)]
    p1 = typed[-1] if typed else None; p2 = typed[-2] if len(typed) > 1 else None
    def follow(i, n):
        out, j = [], i + 1
        while j < len(toks) and len(out) < n and not toks[j][3]: out.append(toks[j][0]); j += 1
        return ' '.join(out)
    if partial:
        pl = partial.lower()
        if len(pl) < 2: return ''
        best = None
        for i, t in enumerate(toks):
            if len(t[1]) >= max(4, len(pl) + 2) and t[1].startswith(pl):
                sc = i + (100000 if p1 and i > 0 and toks[i-1][1] == p1 and not t[3] else 0)
                if best is None or sc >= best[0]: best = (sc, i)
        if not best: return ''
        rest = toks[best[1]][0][len(partial):]
        if best[0] >= 100000:
            more = follow(best[1], 3)
            if more: rest += ' ' + more
        return rest
    if not p1 or not before.endswith(' ') or before.rstrip()[-1:] in '.!?': return ''
    for i in range(len(toks) - 1, -1, -1):
        if toks[i][1] != p1: continue
        ok = (i > 0 and toks[i-1][1] == p2 and not toks[i][3]) if p2 else len(p1) >= 5
        if ok:
            more = follow(i, 4)
            if more: return more
    return ''

DICTS = {}
def load_dicts():
    import struct, bisect
    root = os.path.expanduser('~/exokey/data/dict')
    for lang in ('en', 'ru', 'uk'):
        b = open(os.path.join(root, lang + '.exd'), 'rb').read()
        n, nb, bs, _ = struct.unpack('<IIII', b[4:20]); data = b[20 + nb * 4 + (nb + 1) * 4:]
        pos = 0; prev = b''; words = []; freqs = []
        def vi():
            nonlocal pos
            r = sh = 0
            while True:
                x = data[pos]; pos += 1; r |= (x & 0x7f) << sh
                if not x & 0x80: return r
                sh += 7
        for i in range(n):
            if i % bs == 0: L = vi(); w = data[pos:pos + L]; pos += L
            else: sh_ = data[pos]; pos += 1; L = vi(); w = prev[:sh_] + data[pos:pos + L]; pos += L
            f = vi(); prev = w
            if f >= 2: words.append(w.decode()); freqs.append(f)
        DICTS[lang] = (words, freqs)

USER_WORDS = {}
BIGRAMS = {}
def bigram_next(before):
    """User's own word pairs: after "external" they usually write "power"."""
    ws = [w.lower() for w in WORD.findall(before)]
    if not ws or not before.endswith(' '): return ''
    nxt = BIGRAMS.get(ws[-1])
    if not nxt: return ''
    tot = sum(nxt.values()); w, c = max(nxt.items(), key=lambda x: x[1])
    return w if c >= 2 and c / tot >= 0.5 else ''
def dict_completion(partial, rule):
    """Most likely word for a prefix: user's words first, then the frequency dictionary; only if it clearly dominates."""
    import bisect
    pl = partial.lower().replace('ё', 'е')
    if len(pl) < rule['min']: return ''
    cyr = bool(re.search('[а-яіїєґ]', pl))
    cands = {}
    for lang in (('ru', 'uk') if cyr else ('en',)):
        words, freqs = DICTS[lang]
        i = bisect.bisect_left(words, pl)
        while i < len(words) and words[i].startswith(pl):
            w = words[i]
            if len(w) > len(pl): cands[w] = max(cands.get(w, 0), freqs[i])
            i += 1
    for w, c in USER_WORDS.items():
        if w.startswith(pl) and len(w) > len(pl): cands[w] = cands.get(w, 0) + c * rule['boost']
    if not cands: return ''
    total = sum(cands.values()) + (DICTS['ru' if cyr else 'en'][1][0] if False else 0)
    top = sorted(cands.items(), key=lambda x: -x[1])
    f1 = top[0][1]; f2 = top[1][1] if len(top) > 1 else 0
    if rule.get('stem') and not (f1 / total >= rule['share'] or (f2 and f1 >= rule['ratio'] * f2 and f1 / total >= rule['share'] / 2)):
        # no single form wins ("соотв" → -ует/-ии/-енно): offer the part all likely forms share ("етств")
        import os.path
        keep, mass = [], 0
        for w, f in top:
            keep.append(w); mass += f
            if mass / total >= rule['stem']: break
        stem = os.path.commonprefix(keep)
        if len(stem) - len(pl) >= 3: return stem[len(pl):]
        return ''
    if f1 / total >= rule['share'] or (f2 and f1 >= rule['ratio'] * f2 and f1 / total >= rule['share'] / 2):
        w = top[0][0]
        rest = w[len(pl):]
        if partial[:1].isupper(): pass
        return rest
    return ''

def accept(sugg, rest):
    """Chars the user saves by pressing Tab word by word while the suggestion matches what they meant."""
    saved, i = 0, 0
    while i < len(sugg):
        m = re.match(r"\s*[^\s]+", sugg[i:])
        if not m: break
        chunk = m.group(0)
        if rest[saved:saved + len(chunk)].lower() == chunk.lower(): saved += len(chunk); i += len(chunk)
        else: break
    return saved

def simulate(test, train, conf, use_screen, use_model, limit, dict_rule=None):
    typed_total = saved_total = shown = wrong = asks = 0
    from_screen = 0
    for k, r in enumerate(test[:limit]):
        text, screen = r.get('final', ''), r.get('context', '') if use_screen else ''
        if len(text) < 8: continue
        styles = style_examples(train, r.get('app', ''), seed=k)
        pos, last_word_start, last_wrong = 0, 0, None
        while pos < len(text):
            before = text[:pos]
            m = re.search(r"[\w'’]*$", before); partial = m.group(0)
            # the app asks at a pause; we ask at a word start and after 1 and 3 letters
            model_point = len(partial) in (0, 1, 3)
            if pos >= 2 and (model_point or partial) and not before.rstrip().endswith('?'):
                sugg = ''
                if use_screen and (screen or before):
                    sugg = screen_completion(screen, before[:len(before) - len(partial)] if partial else before, partial)
                    if sugg: from_screen += 1
                if not sugg and dict_rule and dict_rule.get('bigram') and not partial:
                    sugg = bigram_next(before)
                if not sugg and dict_rule and partial and dict_rule.get('rerank') and use_model and len(partial) >= 2:
                    asks += 1
                    sugg = rerank(partial, model_first_tokens(prompt(styles, screen, before)), dict_rule['rerank'])
                if not sugg and dict_rule and partial and dict_rule.get('hybrid') and use_model and len(partial) >= 2 and model_point:
                    asks += 1
                    mrest, mp = ask_word(prompt(styles, screen, before))
                    if mrest and mp >= dict_rule['hybrid'] and is_word(partial + mrest): sugg = mrest
                if not sugg and dict_rule and partial and dict_rule.get('gram') and use_model and len(partial) >= 2:
                    cands = dict_candidates(partial, 8)
                    tot = sum(f for _, f in cands)
                    # only when the dictionary is unsure (no form clearly dominates) — or always, if gram == 'all'
                    if cands and (dict_rule['gram'] == 'all' or cands[0][1] < 0.5 * tot):
                        asks += 1
                        sugg = grammar_pick(prompt(styles, screen, before), partial, cands)
                        if sugg and GRAM_PROB[0] < dict_rule.get('gmin', 0): sugg = ''
                if not sugg and dict_rule and partial and dict_rule.get('filter') and use_model and len(partial) >= 2:
                    asks += 1
                    sugg = filtered_completion(partial, model_first_tokens(prompt(styles, screen, before)), dict_rule)
                if not sugg and dict_rule and partial:
                    sugg = dict_completion(partial, dict_rule)
                    # model only picks the form among dictionary words, and only where the dictionary already suggests
                    if sugg and dict_rule.get('reform') and use_model:
                        asks += 1
                        alt = rerank(partial, model_first_tokens(prompt(styles, screen, before)), dict_rule['reform'])
                        if alt: sugg = alt
                if not sugg and use_model and model_point and (not dict_rule or not partial or dict_rule.get('model_midword')):
                    asks += 1
                    raw = ask(prompt(styles, screen, before.rstrip(' ') if not partial else before), conf)
                    if partial: sugg = raw if raw[:1].isalpha() else ''
                    else: sugg = raw.lstrip(' ') if raw.startswith(' ') or before.endswith(' ') else ''
                if sugg.strip():
                    s = accept(sugg, text[pos:])
                    if s: shown += 1; saved_total += s; pos += s; last_wrong = None; continue
                    full = (partial + sugg).split(' ')[0].lower()
                    if full != last_wrong:            # the same wrong word still on screen is one miss, not many
                        shown += 1; wrong += 1; last_wrong = full
            pos += 1; typed_total += 1
    total = typed_total + saved_total
    return {'messages': min(limit, len(test)), 'chars': total, 'saved%': round(100 * saved_total / max(1, total), 1),
            'shown': shown, 'right%': round(100 * (shown - wrong) / max(1, shown), 1),
            'wrong_per_100_chars': round(100 * wrong / max(1, total), 1), 'model_calls': asks, 'screen_hits': from_screen}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('model'); ap.add_argument('--lora'); ap.add_argument('--conf', type=int, default=1)
    ap.add_argument('--no-screen', action='store_true'); ap.add_argument('--no-model', action='store_true')
    ap.add_argument('--limit', type=int, default=80)
    ap.add_argument('--lang', choices=['en', 'cyr'], help='only messages in this script')
    ap.add_argument('--dict', help='word completion rule json, e.g. {"min":2,"share":0.5,"ratio":3,"boost":200000}')
    a = ap.parse_args()
    test, train = split(load())
    if a.lang:
        is_cyr = lambda r: len(re.findall('[а-яіїєґё]', r.get('final', '').lower())) > len(re.findall('[a-z]', r.get('final', '').lower()))
        test = [r for r in test if is_cyr(r) == (a.lang == 'cyr')]
    proc = None
    if not a.no_model:
        # the app's own server keeps running (the app restarts it if killed anyway)
        cmd = [ENGINE, '-m', os.path.join(AI, a.model), '--host', '127.0.0.1', '--port', str(PORT), '-c', '4096', '-ngl', '99', '--parallel', '1']
        if a.lora: cmd += ['--lora', a.lora]
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=os.path.dirname(ENGINE))
        for _ in range(120):
            try:
                if urllib.request.urlopen(f'http://127.0.0.1:{PORT}/health', timeout=1).status == 200: break
            except Exception: pass
            time.sleep(1)
    try:
        t = time.time()
        rule = json.loads(a.dict) if a.dict else None
        if rule:
            load_dicts()
            for r in train:
                ws = [w.lower() for w in WORD.findall(r.get('final', ''))]
                for a_, b_ in zip(ws, ws[1:]):
                    BIGRAMS.setdefault(a_, {}); BIGRAMS[a_][b_] = BIGRAMS[a_].get(b_, 0) + 1
                for w in WORD.findall(r.get('final', '')):
                    lw = w.lower().replace('ё', 'е')
                    if len(lw) >= 3: USER_WORDS[lw] = USER_WORDS.get(lw, 0) + 1
        res = simulate(test, train, a.conf, not a.no_screen, not a.no_model, a.limit, rule)
        res['dict'] = a.dict
        res['lang'] = a.lang
        res.update({'model': os.path.basename(a.model), 'lora': os.path.basename(a.lora) if a.lora else None, 'conf': a.conf,
                    'screen': not a.no_screen, 'llm': not a.no_model, 'minutes': round((time.time() - t) / 60, 1)})
        print(json.dumps(res, ensure_ascii=False), flush=True)
    finally:
        if proc: proc.terminate(); proc.wait()

if __name__ == '__main__':
    main()
