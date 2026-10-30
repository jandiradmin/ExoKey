#!/usr/bin/env python3
"""Compares local models on the user's own samples (ai-samples.jsonl). Runs only on this Mac.
Prints aggregate numbers only, never the text."""
import json, os, re, subprocess, sys, time, urllib.request, random, math
AI = os.path.expanduser('~/Library/Application Support/ExoKey/ai')
ENGINE = os.path.join(AI, 'engine/llama-b11840/llama-server')
PORT = 8790
MODELS = sys.argv[1:] or ['model-fast.gguf']

def word_re(): return re.compile(r"[\w'’-]+", re.U)
W = word_re()
def norm(s): return s.lower().replace('ё', 'е').replace('’', "'")

def cases():
    snap = os.path.join(AI, 'bench', 'samples-snapshot.jsonl')   # frozen copy: same cases for every model
    if not os.path.exists(snap):
        import shutil; shutil.copy(os.path.join(os.path.dirname(AI), 'ai-samples.jsonl'), snap)
    rows = [json.loads(l) for l in open(snap) if l.strip()]
    out, seen = [], set()
    rnd = random.Random(7)
    for r in rows:
        final, draft, ctx = r.get('final', ''), r.get('draft', ''), r.get('context', '')
        words = W.findall(final)
        if len(words) < 3: continue
        head = ' '.join(words[:3])
        k = draft.rfind(words[0] + ' ' + words[1]) if len(words) > 1 else -1
        before = draft[:k] if k > 0 else ''
        # positions of words inside final
        spans = [m.span() for m in W.finditer(final)]
        cuts = list(range(1, len(spans)))
        rnd.shuffle(cuts)
        for i in sorted(cuts[:3]):
            target = final[spans[i][0]:spans[i][1]]
            if len(target) < 2 or target.isdigit(): continue
            prefix = before + final[:spans[i][0]]
            mid = rnd.random() < 0.4 and len(target) >= 5
            if mid:
                prefix += target[:2]
            key = (prefix[-80:], target)
            if key in seen: continue
            seen.add(key)
            out.append({'ctx': ctx, 'prefix': prefix, 'target': target, 'mid': mid})
    rnd.shuffle(out)
    return out[:300]

def post(prompt, n=6):
    body = {'prompt': prompt, 'n_predict': n, 'temperature': 0, 'cache_prompt': False,
            'stop': ['\n'], 'n_probs': 1, 'post_sampling_probs': False}
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/completion', json.dumps(body).encode(),
                                 {'Content-Type': 'application/json'})
    t = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=30))
    return r, time.time() - t

def evaluate(model):
    proc = subprocess.Popen([ENGINE, '-m', os.path.join(AI, model), '--host', '127.0.0.1', '--port', str(PORT),
                             '-c', '4096', '-ngl', '99', '--parallel', '1'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=os.path.dirname(ENGINE))
    try:
        for _ in range(120):
            try:
                if urllib.request.urlopen(f'http://127.0.0.1:{PORT}/health', timeout=1).status == 200: break
            except Exception: pass
            time.sleep(1)
        else:
            return {'model': model, 'error': 'did not start'}
        cs = cases()
        hit = shown = shown_hit = 0
        pts = []
        times, tps = [], []
        for c in cs:
            prompt = (c['ctx'][-1800:] + '\n' if c['ctx'] else '') + c['prefix']
            if not c['mid']: prompt = prompt.rstrip(' ')
            r, dt = post(prompt)
            times.append(dt); tps.append(r.get('timings', {}).get('predicted_per_second', 0))
            text = r.get('content', '')
            probs = [math.exp(p.get('logprob', -99)) for p in r.get('completion_probabilities', [])]
            if c['mid']:
                m = re.match(r"[\w'’-]*", text, re.U); guess = c['prefix'].split()[-1] + (m.group(0) if m else '')
                target = c['target']
            else:
                if not text.startswith(' '): guess = ''
                else:
                    m = W.match(text[1:]); guess = m.group(0) if m else ''
                target = c['target']
            ok = guess and norm(guess) == norm(target)
            hit += bool(ok)
            # app-like confidence gate on the first word's tokens
            pw, n = 1.0, 0
            acc = ''
            for tok, p in zip(r.get('completion_probabilities', []), probs):
                acc += tok.get('token', '')
                pw *= p; n += 1
                if len(W.findall(acc)) >= 1 and re.search(r"[\w]\W", acc + ' ', re.U) and len(acc.strip()) >= len(guess): break
            pts.append((pw if guess else 0.0, bool(ok)))
            confident = guess and min(probs[:max(1, n)] or [0]) >= 0.05 and pw >= 0.01
            if confident:
                shown += 1; shown_hit += bool(ok)
        rss = subprocess.run(['ps', '-o', 'rss=', '-p', str(proc.pid)], capture_output=True, text=True).stdout.strip()
        times.sort()
        curve = {}
        for th in (0.1, 0.2, 0.3, 0.5):
            sel = [o for p, o in pts if p >= th]
            curve[str(th)] = (round(100 * len(sel) / len(pts)), round(100 * sum(sel) / max(1, len(sel))))
        return {'model': model, 'cases': len(cs), 'curve(shown%,precision%)': curve, 'top1': round(100 * hit / len(cs), 1),
                'shown_pct': round(100 * shown / len(cs), 1),
                'precision_shown': round(100 * shown_hit / max(1, shown), 1),
                'median_ms': int(1000 * times[len(times) // 2]), 'p90_ms': int(1000 * times[int(len(times) * .9)]),
                'tok_s': round(sum(tps) / len(tps)), 'ram_mb': int(int(rss or 0) / 1024)}
    finally:
        proc.terminate(); proc.wait()

if __name__ == '__main__':
    subprocess.run(['pkill', '-f', 'ExoKey/ai/engine/'])   # free the GPU from the app's server during the test
    for m in MODELS:
        print(json.dumps(evaluate(m), ensure_ascii=False), flush=True)
