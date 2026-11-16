#!/usr/bin/env python3
"""Feedback service for exokey.top/feedback/ (all Exo apps).

Stdlib only: http.server + sqlite3. nginx proxies /api/feedback/ here (127.0.0.1:8740).
Spam protection: proof-of-work captcha (ALTCHA-style: the browser finds n with sha256(salt+n) == challenge),
signed by the server, one use per challenge, a honeypot field and a per-IP rate limit.
Messages are stored as 'new'; only 'approved' ones are shown on the site. Admin: /api/feedback/admin (basic auth).

Env: FEEDBACK_DB, FEEDBACK_KEY (HMAC secret), FEEDBACK_ADMIN_PASSWORD, FEEDBACK_PORT, FEEDBACK_ORIGIN.
"""
import base64, hashlib, hmac, html, json, os, secrets, sqlite3, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DB = os.environ.get("FEEDBACK_DB", "/var/lib/exo-feedback/feedback.db")
KEY = os.environ["FEEDBACK_KEY"].encode()
ADMIN_PW = os.environ["FEEDBACK_ADMIN_PASSWORD"]
PORT = int(os.environ.get("FEEDBACK_PORT", "8740"))
ORIGIN = os.environ.get("FEEDBACK_ORIGIN", "https://exokey.top")

PRODUCTS = ("exokey", "exocalc", "exocommander", "exotools", "other")
KINDS = ("bug", "idea", "other")
MAX_NUMBER = 60000          # PoW difficulty: ~1–3 s in a browser
CHALLENGE_TTL = 20 * 60     # seconds
RATE = (5, 600)             # at most 5 messages per IP per 10 minutes

lock = threading.Lock()
db = sqlite3.connect(DB, check_same_thread=False)
db.executescript("""
CREATE TABLE IF NOT EXISTS messages(
  id INTEGER PRIMARY KEY, created INTEGER NOT NULL, product TEXT NOT NULL, kind TEXT NOT NULL,
  name TEXT, contact TEXT, text TEXT NOT NULL, lang TEXT, version TEXT,
  status TEXT NOT NULL DEFAULT 'new', reply TEXT, ip_hash TEXT);
CREATE INDEX IF NOT EXISTS messages_status ON messages(status, created);
CREATE TABLE IF NOT EXISTS used_challenges(salt TEXT PRIMARY KEY, expires INTEGER NOT NULL);
""")


def sign(s: str) -> str:
    return hmac.new(KEY, s.encode(), hashlib.sha256).hexdigest()


def new_challenge() -> dict:
    salt = f"{secrets.token_hex(12)}?expires={int(time.time()) + CHALLENGE_TTL}"
    number = secrets.randbelow(MAX_NUMBER)
    challenge = hashlib.sha256(f"{salt}{number}".encode()).hexdigest()
    return {"algorithm": "SHA-256", "salt": salt, "challenge": challenge,
            "maxnumber": MAX_NUMBER, "signature": sign(challenge)}


def check_pow(p) -> bool:
    try:
        salt, number = str(p["salt"]), int(p["number"])
        challenge, signature = str(p["challenge"]), str(p["signature"])
        expires = int(salt.rsplit("?expires=", 1)[1])
    except (KeyError, ValueError, TypeError, IndexError):
        return False
    if expires < time.time() or not hmac.compare_digest(sign(challenge), signature):
        return False
    if hashlib.sha256(f"{salt}{number}".encode()).hexdigest() != challenge:
        return False
    with lock:
        db.execute("DELETE FROM used_challenges WHERE expires < ?", (int(time.time()),))
        try:
            db.execute("INSERT INTO used_challenges VALUES (?, ?)", (salt, expires))
        except sqlite3.IntegrityError:
            return False  # already used
        db.commit()
    return True


def clean(v, limit):
    return " ".join(str(v or "").split())[:limit] if limit <= 200 else str(v or "").strip()[:limit]


class H(BaseHTTPRequestHandler):
    server_version = "exo-feedback"

    def log_message(self, fmt, *args):  # no IPs or texts in the journal
        pass

    def ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        data = body if isinstance(body, bytes) else (json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def body(self, limit=20000):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            return None
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return None

    def is_admin(self):
        a = self.headers.get("Authorization", "")
        if not a.startswith("Basic "):
            return False
        try:
            user, _, pw = base64.b64decode(a[6:]).decode().partition(":")
        except Exception:
            return False
        return user == "yan" and hmac.compare_digest(pw.encode(), ADMIN_PW.encode())

    def ask_auth(self):
        self.send(401, "auth required", "text/plain; charset=utf-8", {"WWW-Authenticate": 'Basic realm="feedback"'})

    # ---- routes ----
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/api/feedback/challenge":
            return self.send(200, new_challenge())
        if u.path == "/api/feedback/list":
            q = parse_qs(u.query)
            product = (q.get("product") or [""])[0]
            sql = "SELECT id, created, product, kind, name, text, reply FROM messages WHERE status='approved'"
            args = []
            if product in PRODUCTS:
                sql += " AND product=?"; args.append(product)
            sql += " ORDER BY created DESC LIMIT 200"
            with lock:
                rows = db.execute(sql, args).fetchall()
            keys = ("id", "created", "product", "kind", "name", "text", "reply")
            return self.send(200, [dict(zip(keys, r)) for r in rows])
        if u.path == "/api/feedback/admin":
            return self.admin_page() if self.is_admin() else self.ask_auth()
        self.send(404, {"error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        if u.path == "/api/feedback":
            return self.submit()
        if u.path == "/api/feedback/admin/act":
            if not self.is_admin():
                return self.ask_auth()
            # CSRF: only same-origin fetch() with a JSON body
            if self.headers.get("Origin") != ORIGIN or "application/json" not in (self.headers.get("Content-Type") or ""):
                return self.send(403, {"error": "origin"})
            return self.act()
        self.send(404, {"error": "not found"})

    def submit(self):
        p = self.body()
        if not isinstance(p, dict):
            return self.send(400, {"error": "bad request"})
        if p.get("website"):  # honeypot: bots fill every field; pretend success
            return self.send(200, {"ok": True})
        if not check_pow(p.get("pow") or {}):
            return self.send(400, {"error": "captcha"})
        product, kind = p.get("product"), p.get("kind")
        text = clean(p.get("text"), 4000)
        if product not in PRODUCTS or kind not in KINDS or len(text) < 5:
            return self.send(400, {"error": "fields"})
        ip_hash = hashlib.sha256(KEY + self.ip().encode()).hexdigest()[:24]
        now = int(time.time())
        with lock:
            n = db.execute("SELECT COUNT(*) FROM messages WHERE ip_hash=? AND created>?", (ip_hash, now - RATE[1])).fetchone()[0]
            if n >= RATE[0]:
                return self.send(429, {"error": "rate"})
            db.execute("INSERT INTO messages(created, product, kind, name, contact, text, lang, version, ip_hash) VALUES (?,?,?,?,?,?,?,?,?)",
                       (now, product, kind, clean(p.get("name"), 60) or None, clean(p.get("contact"), 120) or None,
                        text, clean(p.get("lang"), 5), clean(p.get("version"), 40) or None, ip_hash))
            db.commit()
        self.send(200, {"ok": True})

    def act(self):
        p = self.body()
        if not isinstance(p, dict):
            return self.send(400, {"error": "bad request"})
        try:
            mid = int(p.get("id"))
        except (TypeError, ValueError):
            return self.send(400, {"error": "id"})
        action = p.get("action")
        with lock:
            if action in ("approve", "hide", "new"):
                db.execute("UPDATE messages SET status=? WHERE id=?", ({"approve": "approved", "hide": "hidden", "new": "new"}[action], mid))
            elif action == "reply":
                db.execute("UPDATE messages SET reply=? WHERE id=?", (clean(p.get("reply"), 2000) or None, mid))
            elif action == "delete":
                db.execute("DELETE FROM messages WHERE id=?", (mid,))
            else:
                return self.send(400, {"error": "action"})
            db.commit()
        self.send(200, {"ok": True})

    def admin_page(self):
        with lock:
            rows = db.execute("SELECT id, created, product, kind, name, contact, text, lang, version, status, reply "
                              "FROM messages ORDER BY (status='new') DESC, created DESC LIMIT 500").fetchall()
        e = html.escape
        items = []
        for (mid, created, product, kind, name, contact, text, lang, version, status, reply) in rows:
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(created))
            meta = " · ".join(x for x in (when, product, kind, lang or "", version or "", name or "аноним", contact or "") if x)
            items.append(f"""<div class="m {e(status)}" data-id="{mid}">
<div class="meta"><b>#{mid} {e(status)}</b> · {e(meta)}</div>
<div class="t">{e(text)}</div>
<textarea placeholder="Ответ (виден на сайте)">{e(reply or '')}</textarea>
<div class="b"><button data-a="approve">Показать</button><button data-a="hide">Скрыть</button>
<button data-a="reply">Сохранить ответ</button><button data-a="delete" class="del">Удалить</button></div></div>""")
        new = sum(1 for r in rows if r[9] == "new")
        page = f"""<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>Feedback admin</title><style>
body{{background:#0e1013;color:#eef0f3;font:15px/1.5 -apple-system,sans-serif;margin:0;padding:16px;max-width:900px;margin:auto}}
.m{{background:#191d23;border:1px solid #2a2f38;border-radius:12px;padding:12px 14px;margin:12px 0}}
.m.new{{border-color:#ffb547}}.m.hidden{{opacity:.55}}.meta{{color:#98a0ae;font-size:13px}}
.t{{white-space:pre-wrap;margin:8px 0}}textarea{{width:100%;box-sizing:border-box;background:#14171c;color:inherit;border:1px solid #2a2f38;border-radius:8px;min-height:44px;font:inherit}}
button{{margin:6px 6px 0 0;padding:6px 12px;border-radius:8px;border:1px solid #2a2f38;background:#14171c;color:inherit;cursor:pointer}}
button.del{{color:#ff7b72}}</style></head><body><h2>Замечания: новых {new}, всего {len(rows)}</h2>{''.join(items) or '<p>Пусто</p>'}
<script>
document.addEventListener('click', async ev => {{
  const b = ev.target.closest('button[data-a]'); if (!b) return;
  const m = b.closest('.m'), a = b.dataset.a;
  const r = await fetch('/api/feedback/admin/act', {{method: 'POST', headers: {{'Content-Type': 'application/json'}},
    body: JSON.stringify({{id: +m.dataset.id, action: a, reply: m.querySelector('textarea').value}})}});
  if (r.ok) location.reload(); else b.textContent = 'Ошибка ' + r.status;
}});
</script></body></html>"""
        self.send(200, page, "text/html; charset=utf-8", {"X-Frame-Options": "DENY"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
