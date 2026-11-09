#!/usr/bin/env python3
"""Typing map: where the fingers landed on the ExoKey iPhone keyboard (from ios/keyboard.log).

Usage: python3 ios/typing_map.py [keyboard.log] [out.html]
Pairs every "spy↓ x,y" (raw touch) with the key typed right after it; key rectangles come from the
"keys …" log lines, or are recomputed with the keyboard's layout rules for older logs.
"""
import html, math, re, sys
from collections import defaultdict

LOG = sys.argv[1] if len(sys.argv) > 1 else "keyboard.log"
OUT = sys.argv[2] if len(sys.argv) > 2 else "typing_map.html"

# --- the layout rules of KeyboardView.layoutSubviews (for logs without "keys" lines) ---
def layout(lang, W=440.0, H=326.0):
    g, side, bar = 11.0, 3.0, 46.0
    top, bottom = bar + 2, 4.0
    rows_spec = [[(c, 1.0) for c in "1234567890"]]
    if lang == "ru":
        rows_spec += [[(c, 1.0) for c in "йцукенгшщзх"], [(c, 1.0) for c in "фывапролджэ"],
                      [("⇧", 1.0)] + [(c, 1.0) for c in "ячсмитьбю"] + [("⌫", 1.0)]]
    else:
        rows_spec += [[(c, 1.0) for c in "qwertyuiop"], [(c, 1.0) for c in "asdfghjkl"],
                      [("⇧", 1.0)] + [(c, 1.0) for c in "zxcvbnm"] + [("⌫", 1.0)]]
    rows_spec.append([("#+=", 1.4), ("␣", None), (".", 1.1), ("⏎", 1.9)])
    rowH = (H - top - bottom) / len(rows_spec)
    gapX, gapY = 6.0, (12.0 if rowH > 50 else 10.0)
    unit = (W - 2 * side) / g
    rects = {}
    for r, row in enumerate(rows_spec):
        fixed = sum(w for _, w in row if w is not None)
        flex = max(3.0, g - fixed) if any(w is None for _, w in row) else 0.0
        total = fixed + flex
        u = unit * g / total if total > g else unit
        y = top + r * rowH + gapY / 2
        if row[0][0] == "⇧" and row[-1][0] == "⌫" and total < g:
            rects["⇧"] = (side + gapX / 2, y, row[0][1] * u - gapX, rowH - gapY)
            rects["⌫"] = (W - side - row[-1][1] * u + gapX / 2, y, row[-1][1] * u - gapX, rowH - gapY)
            inner = row[1:-1]
            x = (W - sum(w for _, w in inner) * u) / 2
            for k, w in inner:
                rects[k] = (x + gapX / 2, y, w * u - gapX, rowH - gapY)
                x += w * u
            continue
        x = side + (g * unit - total * u) / 2
        for k, w in row:
            kw = (flex if w is None else w) * u
            rects[k] = (x + gapX / 2, y, kw - gapX, rowH - gapY)
            x += kw
    return rects, W, H

# --- read the log ---
touches = []          # (x, y, key, lang)
layouts = {}          # lang -> (rects, W, H) from "keys" lines
cur_lang = "ru"
pending = None
for line in open(LOG, encoding="utf-8", errors="replace"):
    m = re.search(r" keys (\w+) (\d+)x(\d+) (.*)$", line)
    if m:
        lang, W, H, items = m.group(1), float(m.group(2)), float(m.group(3)), m.group(4).split(" ")
        rects = {}
        for it in items:
            k, _, v = it.rpartition("=")
            try:
                x, y, w, h = map(float, v.split(","))
                rects[k] = (x, y, w, h)
            except ValueError:
                pass
        if H < 600:          # the first layout pass is full-screen (before the keyboard height is set)
            layouts[lang] = (rects, W, H)
        if lang in ("ru", "en"):
            cur_lang = lang
        continue
    m = re.search(r"spy↓ (\d+),(\d+)", line)
    if m:
        pending = (float(m.group(1)), float(m.group(2)))
        continue
    m = re.search(r" ↓(\S+) late=", line)
    if m and pending:
        key = m.group(1)
        lang = "ru" if re.match(r"[а-яё]", key) else ("en" if re.match(r"[a-z]", key) else cur_lang)
        if lang != cur_lang and key.isalpha():
            cur_lang = lang
        touches.append((pending[0], pending[1], key, cur_lang))
        pending = None

if not touches:
    sys.exit("no touches with coordinates in " + LOG)

def rects_for(lang):
    return layouts.get(lang) or layout(lang)

def center(r): return (r[0] + r[2] / 2, r[1] + r[3] / 2)

# --- statistics per key: offset of the touches from the key centre (in key sizes) ---
stats = defaultdict(list)
outside = 0
for x, y, k, lang in touches:
    rects, _, _ = rects_for(lang)
    if k in rects:
        r = rects[k]
        cx, cy = center(r)
        stats[(lang, k)].append(((x - cx) / r[2], (y - cy) / r[3]))
        if not (r[0] - 3 <= x <= r[0] + r[2] + 3 and r[1] - 6 <= y <= r[1] + r[3] + 6):
            outside += 1

all_dx = [d[0] for v in stats.values() for d in v]
all_dy = [d[1] for v in stats.values() for d in v]
mean = lambda a: sum(a) / len(a) if a else 0

# --- draw ---
def svg(lang):
    rects, W, H = rects_for(lang)
    pts = [(x, y, k) for x, y, k, l in touches if l == lang]
    if not pts:
        return ""
    s = [f'<svg viewBox="0 0 {W:.0f} {H:.0f}" class="kb">']
    for k, (x, y, w, h) in rects.items():
        n = len(stats.get((lang, k), []))
        s.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="6" class="key"/>')
        s.append(f'<text x="{x + w / 2:.1f}" y="{y + h / 2 + 6:.1f}" class="lbl">{html.escape(k)}</text>')
        if n:
            dx = mean([d[0] for d in stats[(lang, k)]]) * w
            dy = mean([d[1] for d in stats[(lang, k)]]) * h
            cx, cy = x + w / 2, y + h / 2
            s.append(f'<line x1="{cx:.1f}" y1="{cy:.1f}" x2="{cx + dx:.1f}" y2="{cy + dy:.1f}" class="bias"/>')
    for x, y, k in pts:
        r = rects.get(k)
        inside = r and (r[0] - 3 <= x <= r[0] + r[2] + 3 and r[1] - 6 <= y <= r[1] + r[3] + 6)
        cls = "in" if inside else "out"
        s.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" class="{cls}"><title>{html.escape(k)}</title></circle>')
    s.append("</svg>")
    return "\n".join(s)

worst = sorted(((math.hypot(mean([d[0] for d in v]), mean([d[1] for d in v])), k, len(v), mean([d[0] for d in v]), mean([d[1] for d in v]))
                for k, v in stats.items() if len(v) >= 3), reverse=True)[:12]
rows = "".join(f"<tr><td>{html.escape(k[1])}</td><td>{n}</td><td>{dx:+.2f}</td><td>{dy:+.2f}</td></tr>" for _, k, n, dx, dy in worst)

page = f"""<!doctype html><meta charset="utf-8"><title>Typing map</title>
<style>
:root {{ --bg:#f4f4f6; --key:#fff; --ink:#222; --muted:#777; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1c1c1e; --key:#3a3a3c; --ink:#eee; --muted:#999; }} }}
body {{ background:var(--bg); color:var(--ink); font:15px -apple-system, sans-serif; margin:24px; }}
.kb {{ width:min(880px, 100%); display:block; margin:12px 0 28px; }}
.key {{ fill:var(--key); stroke:#0002; }}
.lbl {{ font-size:15px; text-anchor:middle; fill:var(--muted); }}
.in {{ fill:#2a7de1; opacity:.55; }} .out {{ fill:#e5484d; opacity:.8; }}
.bias {{ stroke:#e5484d; stroke-width:2.5; }}
table {{ border-collapse:collapse; }} td,th {{ padding:4px 12px; border-bottom:1px solid #0002; text-align:right; }}
</style>
<h1>Карта набора</h1>
<p>Касаний: {len(touches)}. Мимо клавиши, которая напечаталась: {outside} ({outside * 100 // max(1, len(touches))}%).
Средний сдвиг пальца от центра клавиши: вправо {mean(all_dx):+.2f}, вниз {mean(all_dy):+.2f} (в долях клавиши).</p>
<p>Синие точки — касание в своей клавише, красные — за её краем. Красная линия из центра клавиши — куда в среднем смещён палец.</p>
<h2>Русская</h2>{svg("ru")}
<h2>English</h2>{svg("en")}
<h2>Клавиши с самым большим сдвигом</h2>
<table><tr><th>клавиша</th><th>касаний</th><th>вправо</th><th>вниз</th></tr>{rows}</table>
"""
open(OUT, "w", encoding="utf-8").write(page)
print(f"{OUT}: {len(touches)} touches, outside {outside}, mean dx {mean(all_dx):+.2f} dy {mean(all_dy):+.2f}")
