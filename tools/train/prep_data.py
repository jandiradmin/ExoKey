#!/usr/bin/env python3
"""Training data for the two autocomplete adapters, in the app's own prompt format.
  textbook (Учебник): public conversations only — OpenAssistant oasst2 (Apache-2.0), russian_dialogues (MIT).
                      This adapter may be published, so it never sees the user's text.
  mystyle (Мой стиль): the user's own sent messages (training split only) mixed with some textbook data.
                      Stays on this Mac.
Output: <out>/{textbook,mystyle}/{train,valid}.jsonl with {"prompt","completion"}."""
import gzip, json, os, random, sys, re
from huggingface_hub import hf_hub_download, list_repo_files
OUT = sys.argv[1]
AI = os.path.expanduser('~/Library/Application Support/ExoKey/ai')
rnd = random.Random(42)

def prompt(screen='', styles=None):
    head = ''
    if styles: head += 'How I write:\n' + '\n'.join('- ' + s for s in styles) + '\n\n'
    if screen: head += 'Screen:\n' + screen.strip()[-1500:] + '\n\n'
    return head + 'My message:\n'

def clean(t): return re.sub(r'\s+\n', '\n', t.strip())

def ok(t): return 3 <= len(t) <= 500 and '```' not in t and 'http' not in t

def oasst():
    files = [f for f in list_repo_files('OpenAssistant/oasst2', repo_type='dataset') if f.endswith('.messages.jsonl.gz') and 'ready' in f]
    path = hf_hub_download('OpenAssistant/oasst2', files[0], repo_type='dataset')
    msgs = {}
    for l in gzip.open(path, 'rt', encoding='utf-8'):
        m = json.loads(l); msgs[m['message_id']] = m
    out = {'en': [], 'ru': [], 'uk': []}
    for m in msgs.values():
        lang = (m.get('lang') or '')[:2]
        if m.get('role') != 'prompter' or lang not in out or m.get('deleted'): continue
        t = clean(m['text'])
        if not ok(t): continue
        parent = msgs.get(m.get('parent_id') or '')
        screen = ('Them: ' + clean(parent['text'])[:800]) if parent else ''
        out[lang].append({'prompt': prompt(screen), 'completion': t})
    return out

def dialogues(n):
    files = [f for f in list_repo_files('Den4ikAI/russian_dialogues', repo_type='dataset') if f.endswith(('.json', '.jsonl', '.parquet'))]
    rows = []
    for f in files:
        p = hf_hub_download('Den4ikAI/russian_dialogues', f, repo_type='dataset')
        if f.endswith('.parquet'):
            import pyarrow.parquet as pq
            rows += pq.read_table(p).to_pylist()
        else:
            txt = open(p, encoding='utf-8').read().strip()
            rows += json.loads(txt) if txt.startswith('[') else [json.loads(l) for l in txt.splitlines() if l.strip()]
        if len(rows) > 400000: break
    rows = [r for r in rows if str(r.get('relevance', 1)) in ('1', '1.0', 'True') and ok(clean(r.get('answer') or '')) and len(r.get('question') or '') > 2]
    rnd.shuffle(rows)
    return [{'prompt': prompt('Them: ' + clean(r['question'])[:600]), 'completion': clean(r['answer'])} for r in rows[:n]]

def write(name, items):
    rnd.shuffle(items)
    d = os.path.join(OUT, name); os.makedirs(d, exist_ok=True)
    k = max(50, len(items) // 50)
    for fn, part in (('valid.jsonl', items[:k]), ('train.jsonl', items[k:])):
        with open(os.path.join(d, fn), 'w', encoding='utf-8') as f:
            for it in part: f.write(json.dumps(it, ensure_ascii=False) + '\n')
    print(name, 'train', len(items) - k, 'valid', k)

o = oasst()
print('oasst prompter messages:', {k: len(v) for k, v in o.items()})
rnd.shuffle(o['en'])
textbook = o['en'][:7000] + o['ru'] + o['uk'] + dialogues(9000)
write('textbook', list(textbook))

# My style: the user's messages, training split only (every 5th message is held out for the typing test)
rows = []
for l in open(os.path.join(AI, 'bench', 'samples-snapshot2.jsonl'), encoding='utf-8'):
    try: rows.append(json.loads(l))
    except Exception: pass
train = [r for i, r in enumerate(rows) if i % 5 != 0 and len(r.get('final', '')) >= 3]
mine = []
for r in train:
    pool = [x['final'].replace('\n', ' ')[:200] for x in train if x is not r and x.get('app') == r.get('app')]
    rnd.shuffle(pool)
    item = {'prompt': prompt(r.get('context', ''), pool[:6] or None), 'completion': r['final'].strip()}
    mine += [item, item]            # the user's own text counts twice
mine += rnd.sample(textbook, min(len(textbook), 2 * len(mine)))
write('mystyle', mine)
