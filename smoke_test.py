"""One-shot in-process smoke test: runs the server in a background *thread*
inside this single process (not a separate backgrounded process), then
exercises every endpoint. Proves the app logic works without needing a
persistent process, which this sandbox blocks.
"""
import base64
import json
import threading
import time
import urllib.request

import server as app

BASE = f"http://{app.HOST}:{app.PORT}"

TINY_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBA"
    "SwAyDwAAAAASUVORK5CYII="
)
DATA_URL = f"data:image/png;base64,{TINY_PNG_B64}"


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method,
                                headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(r, timeout=5) as resp:
        return resp.status, json.loads(resp.read().decode())


def run_checks():
    time.sleep(0.3)
    results = []

    st, body = req("GET", "/api/guestbook")
    results.append(("GET /api/guestbook empty", st == 200 and body == []))

    st, body = req("POST", "/api/guestbook", {"name": "Aunty May", "message": "So cute!", "photoDataUrl": DATA_URL})
    results.append(("POST /api/guestbook with photo", st == 200 and body.get("photoUrl")))

    st, body = req("GET", "/api/guestbook")
    results.append(("GET /api/guestbook has 1 entry", st == 200 and len(body) == 1))

    st, body = req("POST", "/api/photos", {"name": "Uncle Bob", "caption": "Cake time", "photoDataUrl": DATA_URL})
    results.append(("POST /api/photos", st == 200 and body.get("photoUrl")))

    st, body = req("POST", "/api/photos", {"name": "No photo"})
    results.append(("POST /api/photos rejects missing photo", st == 400))

    st, body = req("POST", "/api/race/start")
    race_id = body.get("raceId")
    results.append(("POST /api/race/start", st == 200 and race_id))

    st, body = req("POST", "/api/race/finish", {"raceId": race_id, "taps": 5, "name": "TooFast"})
    results.append(("finish rejects too-early race", st == 400))

    time.sleep(app.RACE_DURATION_MS / 1000)
    st, body = req("POST", "/api/race/start")
    race_id2 = body.get("raceId")
    time.sleep(app.RACE_DURATION_MS / 1000 + 0.2)
    st, body = req("POST", "/api/race/finish", {"raceId": race_id2, "taps": 47, "name": "SpeedyG"})
    results.append(("finish accepts valid race", st == 200 and body["entry"]["taps"] == 47))

    st, body = req("POST", "/api/race/finish", {"raceId": race_id2, "taps": 999, "name": "Replay"})
    results.append(("finish rejects reused raceId", st == 400))

    st, body = req("POST", "/api/race/finish", {"raceId": race_id2, "taps": 9999, "name": "Cheater"})
    results.append(("cheater cap didn't matter (already used)", st == 400))

    st, body = req("GET", "/api/race/leaderboard")
    results.append(("leaderboard has SpeedyG on top", st == 200 and body[0]["name"] == "SpeedyG"))

    st, body = req("POST", "/api/admin/reset", {"what": "all"})
    results.append(("admin reset all", st == 200 and body.get("ok")))

    st, body = req("GET", "/api/guestbook")
    results.append(("guestbook empty after reset", st == 200 and body == []))

    print("\n=== RESULTS ===")
    all_ok = True
    for name, ok in results:
        print(("PASS" if ok else "FAIL"), "-", name)
        all_ok = all_ok and bool(ok)
    print("ALL PASS" if all_ok else "SOME FAILED")


if __name__ == "__main__":
    server = app.ThreadingHTTPServer((app.HOST, app.PORT), app.Handler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    try:
        run_checks()
    finally:
        server.shutdown()
