#!/usr/bin/env python3
"""Model x prompt comparison on the user's own samples (ai-samples.jsonl). Runs only on this Mac.
Prints aggregate numbers only, never the text.
Usage: prompt_bench.py MODEL_FILE VARIANT[,VARIANT...]   (model path relative to ExoKey/ai)"""
import json, os, re, subprocess, sys, time, urllib.request, random, math
AI = os.path.expanduser('~/Library/Application Support/ExoKey/ai')
ENGINE = os.path.join(AI, 'engine/llama-b11840/llama-server')
PORT = 8790
W = re.compile(r"[\w'’-]+", re.U)
def norm(s): return s.lower().replace('ё', 'е').replace('’', "'")

SYS = ("You are an autocomplete engine inside the user's keyboard. The user is typing a message. "
       "Continue the user's draft with the most likely next words, in the same language, tone and style. "
       "Use the conversation for context. Write only the continuation of the draft, never repeat it, never answer for the other person.")

def load():
    snap = os.path.join(AI, 'bench', 'samples-snapshot2.jsonl')   # frozen: same cases for every run
    if not os.path.exists(snap):
        import shutil; shutil.copy(os.path.join(os.path.dirname(AI), 'ai-samples.jsonl'), snap)
    rows = []
    for l in open(snap, encoding='utf-8'):
        try: rows.append(json.loads(l))
        except Exception: pass
    return rows

def cases(rows):
    out, seen = [], set()
    rnd = random.Random(7)
    for idx, r in enumerate(rows):
        final, draft, ctx = r.get('final', ''), r.get('draft', ''), r.get('context', '')
        words = W.findall(final)
        if len(words) < 3: continue
        k = draft.rfind(words[0] + ' ' + words[1])
        before = draft[:k] if k > 0 else ''
        spans = [m.span() for m in W.finditer(final)]
        cuts = list(range(1, len(spans)))
        rnd.shuffle(cuts)
        for i in sorted(cuts[:3]):
            target = final[spans[i][0]:spans[i][1]]
            if len(target) < 2 or target.isdigit(): continue
            prefix = before + final[:spans[i][0]]
            mid = rnd.random() < 0.4 and len(target) >= 5
            if mid: prefix += target[:2]
            key = (prefix[-80:], target)
            if key in seen: continue
            seen.add(key)
            rest = [norm(w) for w in W.findall(final[spans[i][0]:])][:8]
            out.append({'row': idx, 'app': r.get('app', ''), 'ctx': ctx, 'prefix': prefix, 'target': target, 'mid': mid, 'rest': rest})
    rnd.shuffle(out)
    return out[:400]

def style_examples(rows, c, n=6):
    pool = [r.get('final', '') for i, r in enumerate(rows) if i != c['row'] and r.get('app', '') == c['app'] and len(r.get('final', '')) > 15]
    rnd = random.Random(c['row'])
    rnd.shuffle(pool)
    return [p.replace('\n', ' ')[:200] for p in pool[:n]]

def build(variant, c, rows):
    ctx = c['ctx'][-1800:].strip()
    pre = c['prefix'] if c['mid'] else c['prefix'].rstrip(' ')
    if variant == 'raw':
        return (ctx + '\n' if ctx else '') + pre
    if variant == 'labeled':
        return ('Screen:\n' + ctx + '\n\n' if ctx else '') + 'My message:\n' + pre
    if variant == 'dialog':
        return (ctx + '\n\n' if ctx else '') + 'Me: ' + pre
    if variant == 'style':
        ex = style_examples(rows, c)
        head = ('How I write:\n' + '\n'.join('- ' + e for e in ex) + '\n\n') if ex else ''
        return head + ('Screen:\n' + ctx + '\n\n' if ctx else '') + 'My message:\n' + pre
    if variant == 'chat':
        conv = f"Conversation above the input field:\n\"\"\"\n{ctx}\n\"\"\"\n" if ctx else ''
        return f"<|im_start|>system\n{SYS}<|im_end|>\n<|im_start|>user\n{conv}<|im_end|>\n<|im_start|>assistant\n{pre}"
    raise SystemExit('unknown variant ' + variant)

def post(prompt, n=16):
    body = {'prompt': prompt, 'n_predict': n, 'temperature': 0, 'cache_prompt': False,
            'stop': ['\n', '<|im_end|>'], 'n_probs': 1}
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/completion', json.dumps(body).encode(), {'Content-Type': 'application/json'})
    t = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=60))
    return r, time.time() - t

def score(c, r):
    text = r.get('content', '')
    probs = [math.exp(p.get('logprob', -99)) for p in r.get('completion_probabilities', [])]
    if c['mid']:
        last = c['prefix'].split()[-1]
        full = last + text
    else:
        if not text.startswith(' '): return 0, 0, 0.0
        full = text[1:]
    guess = [norm(w) for w in W.findall(full)]
    if not guess: return 0, 0, 0.0
    first_ok = guess[0] == norm(c['target'])
    run = 0
    for g, t in zip(guess, c['rest']):
        if g != t: break
        run += 1
    # confidence of the first word: product of token probs until the first word is complete
    acc, pw = '', 1.0
    for tok, p in zip(r.get('completion_probabilities', []), probs):
        acc += tok.get('token', '')
        pw *= p
        if re.search(r"\w[\W]", acc.lstrip() + ('' if not c['mid'] else ''), re.U): break
    return int(first_ok), run, pw

def main():
    model, variants = sys.argv[1], sys.argv[2].split(',')
    # the app's own server keeps running (the app restarts it if killed anyway)
    proc = subprocess.Popen([ENGINE, '-m', os.path.join(AI, model), '--host', '127.0.0.1', '--port', str(PORT),
                             '-c', '4096', '-ngl', '99', '--parallel', '1'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=os.path.dirname(ENGINE))
    try:
        for _ in range(120):
            try:
                if urllib.request.urlopen(f'http://127.0.0.1:{PORT}/health', timeout=1).status == 200: break
            except Exception: pass
            time.sleep(1)
        rows = load(); cs = cases(rows)
        for v in variants:
            res, times = [], []
            for c in cs:
                r, dt = post(build(v, c, rows)); times.append(dt)
                res.append(score(c, r))
            n = len(res)
            curve = {}
            for th in (0.03, 0.05, 0.08, 0.1, 0.15, 0.2, 0.3):
                sel = [(ok, run) for ok, run, p in res if p >= th]
                curve[str(th)] = {'shown%': round(100 * len(sel) / n), 'hit%': round(100 * sum(o for o, _ in sel) / max(1, len(sel))),
                                  'words': round(sum(run for _, run in sel) / max(1, len(sel)), 2)}
            times.sort()
            print(json.dumps({'model': model.split('/')[-1], 'variant': v, 'cases': n,
                              'top1%': round(100 * sum(o for o, _, _ in res) / n, 1),
                              'avg_words': round(sum(run for _, run, _ in res) / n, 2),
                              'median_ms': int(1000 * times[n // 2]), 'curve': curve}, ensure_ascii=False), flush=True)
    finally:
        proc.terminate(); proc.wait()

if __name__ == '__main__':
    main()
