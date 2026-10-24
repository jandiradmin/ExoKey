#!/usr/bin/env python3
"""Records docs/demo/index.html into docs/media/demo-<lang>.gif (one full cycle of scenes).
Usage: tools/.venv/bin/python tools/record_demo.py uk|en"""
import io, sys, time, pathlib
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
lang = sys.argv[1] if len(sys.argv) > 1 else "en"
out = ROOT / "docs" / "media" / f"demo-{lang}.gif"
SECONDS, FPS, WIDTH = float(sys.argv[2]) if len(sys.argv) > 2 else 64, 8, 760

with sync_playwright() as p:
    b = p.chromium.launch(channel="chrome")
    page = b.new_page(viewport={"width": 900, "height": 820}, device_scale_factor=1)
    page.add_init_script(f"try{{localStorage.setItem('exokey-demo-lang','{lang}')}}catch(e){{}}")
    page.goto((ROOT / "docs" / "demo" / "index.html").as_uri())
    page.add_style_tag(content=".controls{visibility:hidden} body{padding-block:16px 16px}")
    page.wait_for_function("document.fonts.status==='loaded'")
    page.evaluate("document.getElementById('nav0').click()")
    box = page.locator(".wrap").bounding_box()
    clip = {"x": box["x"] - 8, "y": box["y"] - 8, "width": box["width"] + 16, "height": box["height"] + 16}
    frames, stamps = [], []
    start = time.time()
    seen_last = False
    while time.time() - start < SECONDS:
        t0 = time.time()
        cur = page.evaluate("[...document.querySelectorAll('#nav button')].findIndex(b => b.getAttribute('aria-current') === 'true')")
        if cur == 5: seen_last = True
        if seen_last and cur == 0: break          # one full cycle recorded

        png = page.screenshot(clip=clip)
        img = Image.open(io.BytesIO(png)).convert("RGB")
        img = img.resize((WIDTH, round(img.height * WIDTH / img.width)), Image.LANCZOS)
        if not frames or img.tobytes() != frames[-1].tobytes():
            frames.append(img); stamps.append(t0)
        time.sleep(max(0, 1 / FPS - (time.time() - t0)))
    b.close()

pal = frames[len(frames) // 2].quantize(colors=96, method=Image.MEDIANCUT)
q = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
ms = [max(40, int((stamps[i + 1] - stamps[i]) * 1000)) for i in range(len(stamps) - 1)] + [800]
q[0].save(out, save_all=True, append_images=q[1:], duration=ms, loop=0, optimize=True, disposal=1)
print(out, len(q), "frames", round(out.stat().st_size / 1e6, 2), "MB")
