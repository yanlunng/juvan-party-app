"""
Juvan's First Birthday - party mini-web-app backend.
Pure Python stdlib (no pip installs needed) so it runs anywhere, including
locked-down machines where unsigned binaries (e.g. Homebrew node) can't
open listening sockets.
"""
import base64
import json
import mimetypes
import os
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PUBLIC_DIR = os.path.join(BASE_DIR, "public")
UPLOADS_DIR = os.path.join(BASE_DIR, "uploads")
DATA_FILE = os.path.join(BASE_DIR, "data", "store.json")
PORT = int(os.environ.get("PORT", "8090"))
HOST = os.environ.get("HOST", "127.0.0.1")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "password")
ENTRY_PASSWORD = os.environ.get("ENTRY_PASSWORD", "party")

RACE_DURATION_MS = 10_000

lock = threading.Lock()
admin_tokens = set()
entry_tokens = set()


def load_store():
    try:
        with open(DATA_FILE, "r") as f:
            data = json.load(f)
    except Exception:
        data = {}
    data.setdefault("guestbook", [])
    data.setdefault("scores", [])
    data.setdefault("races", {})
    data.setdefault("flappy_scores", [])
    return data


store = load_store()


def save_store():
    with open(DATA_FILE, "w") as f:
        json.dump(store, f, indent=2)


def new_id(n=10):
    return uuid.uuid4().hex[:n]


def now_ms():
    return int(time.time() * 1000)


def save_data_url_image(data_url):
    """Decode a data: URL and save it to uploads/, return the public URL path."""
    m = re.match(r"^data:(image/[a-zA-Z0-9.+-]+);base64,(.*)$", data_url or "", re.DOTALL)
    if not m:
        return None
    mime, b64 = m.group(1), m.group(2)
    ext = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp",
           "image/gif": ".gif", "image/heic": ".heic"}.get(mime, ".jpg")
    raw = base64.b64decode(b64)
    if len(raw) > 8 * 1024 * 1024:
        raise ValueError("Image too large")
    filename = f"{new_id(12)}{ext}"
    with open(os.path.join(UPLOADS_DIR, filename), "wb") as f:
        f.write(raw)
    return f"/uploads/{filename}"


def top_scores(n=15):
    return sorted(store["scores"], key=lambda s: s["taps"], reverse=True)[:n]


def top_flappy_scores(n=15):
    return sorted(store["flappy_scores"], key=lambda s: s["score"], reverse=True)[:n]


class Handler(BaseHTTPRequestHandler):
    server_version = "JuvanPartyApp/1.0"

    def log_message(self, fmt, *args):
        pass  # keep console quiet

    # ---------- helpers ----------
    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_error_json(self, message, status=400):
        self._send_json({"error": message}, status)

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def _serve_static(self, rel_path, root):
        rel_path = rel_path.lstrip("/")
        if rel_path == "":
            rel_path = "index.html"
        full_path = os.path.normpath(os.path.join(root, rel_path))
        if not full_path.startswith(os.path.normpath(root)):
            self._send_error_json("Forbidden", 403)
            return
        if not os.path.isfile(full_path):
            self.send_response(404)
            self.end_headers()
            return
        ctype = mimetypes.guess_type(full_path)[0] or "application/octet-stream"
        with open(full_path, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        # uploaded photos are content-addressed (random filenames, never overwritten)
        # so they're safe to cache hard; everything else stays fresh for dev iteration
        if root == UPLOADS_DIR:
            self.send_header("Cache-Control", "public, max-age=86400, immutable")
        else:
            self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    # ---------- routing ----------
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/guestbook":
            return self._send_json(store["guestbook"])
        if path == "/api/race/leaderboard":
            return self._send_json(top_scores())
        if path == "/api/flappy/leaderboard":
            return self._send_json(top_flappy_scores())
        if path.startswith("/uploads/"):
            return self._serve_static(path[len("/uploads/"):], UPLOADS_DIR)
        return self._serve_static(path, PUBLIC_DIR)

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            if path == "/api/guestbook":
                return self._post_guestbook()
            if path == "/api/race/start":
                return self._post_race_start()
            if path == "/api/race/finish":
                return self._post_race_finish()
            if path == "/api/flappy/score":
                return self._post_flappy_score()
            if path == "/api/admin/login":
                return self._post_admin_login()
            if path == "/api/admin/verify":
                return self._post_admin_verify()
            if path == "/api/admin/logout":
                return self._post_admin_logout()
            if path == "/api/admin/reset":
                return self._post_admin_reset()
            if path == "/api/entry/login":
                return self._post_entry_login()
            if path == "/api/entry/verify":
                return self._post_entry_verify()
        except ValueError as e:
            return self._send_error_json(str(e), 400)
        except Exception as e:
            return self._send_error_json(f"Server error: {e}", 500)
        self.send_response(404)
        self.end_headers()

    # ---------- endpoints ----------
    def _post_guestbook(self):
        body = self._read_json_body()
        name = (body.get("name") or "A guest").strip()[:40]
        message = (body.get("message") or "").strip()[:280]
        if not message:
            return self._send_error_json("Message required", 400)
        photo_url = None
        if body.get("photoDataUrl"):
            photo_url = save_data_url_image(body["photoDataUrl"])
        entry = {"id": new_id(), "name": name, "message": message,
                 "photoUrl": photo_url, "ts": now_ms()}
        with lock:
            store["guestbook"].insert(0, entry)
            save_store()
        self._send_json(entry)

    def _post_race_start(self):
        race_id = new_id(12)
        with lock:
            store["races"][race_id] = {"startedAt": now_ms(), "used": False}
            save_store()
        self._send_json({"raceId": race_id, "durationMs": RACE_DURATION_MS})

    def _post_race_finish(self):
        body = self._read_json_body()
        race_id = body.get("raceId")
        taps = body.get("taps")
        name = body.get("name")
        with lock:
            race = store["races"].get(race_id)
            if not race or race.get("used"):
                return self._send_error_json("Invalid or already-used race session", 400)
            race["used"] = True
            elapsed = now_ms() - race["startedAt"]
            save_store()

        tap_count = max(0, int(taps)) if isinstance(taps, (int, float)) else 0
        min_elapsed = RACE_DURATION_MS - 500
        max_elapsed = RACE_DURATION_MS + 4000

        if elapsed < min_elapsed or elapsed > max_elapsed:
            return self._send_error_json("Race timing invalid", 400)

        final_taps = tap_count
        entry = {"id": new_id(), "name": (name or "Racer").strip()[:30] or "Racer",
                  "taps": final_taps, "ts": now_ms()}
        with lock:
            store["scores"].append(entry)
            save_store()
            leaderboard = top_scores()
        self._send_json({"entry": entry, "leaderboard": leaderboard})

    def _post_flappy_score(self):
        body = self._read_json_body()
        name = (body.get("name") or "Player").strip()[:30] or "Player"
        score = body.get("score")
        score = max(0, int(score)) if isinstance(score, (int, float)) else 0
        score = min(score, 999)  # sanity cap, this is a casual party game
        face_url = None
        if body.get("faceDataUrl"):
            face_url = save_data_url_image(body["faceDataUrl"])
        entry = {"id": new_id(), "name": name, "score": score, "faceUrl": face_url, "ts": now_ms()}
        with lock:
            store["flappy_scores"].append(entry)
            save_store()
            leaderboard = top_flappy_scores()
        self._send_json({"entry": entry, "leaderboard": leaderboard})

    def _post_admin_login(self):
        body = self._read_json_body()
        if (body.get("password") or "") != ADMIN_PASSWORD:
            return self._send_error_json("Incorrect password", 401)
        token = new_id(24)
        with lock:
            admin_tokens.add(token)
        self._send_json({"token": token})

    def _post_admin_verify(self):
        body = self._read_json_body()
        ok = bool(body.get("token")) and body["token"] in admin_tokens
        self._send_json({"ok": ok})

    def _post_admin_logout(self):
        body = self._read_json_body()
        with lock:
            admin_tokens.discard(body.get("token"))
        self._send_json({"ok": True})

    def _post_admin_reset(self):
        body = self._read_json_body()
        if body.get("token") not in admin_tokens:
            return self._send_error_json("Not authorized", 401)
        what = body.get("what")
        with lock:
            if what == "guestbook":
                store["guestbook"] = []
            elif what == "scores":
                store["scores"] = []
            elif what == "flappy_scores":
                store["flappy_scores"] = []
            elif what == "all":
                store["guestbook"], store["scores"], store["races"] = [], [], {}
                store["flappy_scores"] = []
            else:
                return self._send_error_json("Unknown reset target", 400)
            save_store()
        self._send_json({"ok": True})

    def _post_entry_login(self):
        body = self._read_json_body()
        if (body.get("password") or "") != ENTRY_PASSWORD:
            return self._send_error_json("Incorrect password", 401)
        token = new_id(24)
        with lock:
            entry_tokens.add(token)
        self._send_json({"token": token})

    def _post_entry_verify(self):
        body = self._read_json_body()
        ok = bool(body.get("token")) and body["token"] in entry_tokens
        self._send_json({"ok": ok})


def main():
    os.makedirs(UPLOADS_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(DATA_FILE), exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Juvan's party app running at http://{HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
