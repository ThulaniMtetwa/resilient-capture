#!/usr/bin/env python3
"""
Mock verification backend for ResilientCapture.

A deliberately tiny, dependency-free stand-in for iiDENTIFii's verification
endpoint. Uses only the Python 3 standard library so a reviewer can run it with
one command and no `pip install`.

What it does
------------
* Accepts an image upload at POST /upload (raw JPEG body, as sent by a
  background URLSession upload task).
* Treats the client-supplied capture id as an IDEMPOTENCY KEY: a second upload
  of the same id is acknowledged with 200 but NOT stored again, and the response
  says `duplicate: true`. This is what lets the app retry safely without ever
  creating a second verification.
* Persists received images under mock-server/received/ and logs every request.
* Can inject faults so the app's retry/backoff/resume paths can be exercised.

Fault injection (environment variables)
---------------------------------------
  FAIL_FIRST_N=<n>     Fail the first n attempts *per capture id* with 503,
                       then succeed. Best for demonstrating retry-with-backoff.
  FAIL_RATE=<0..1>     Independently fail each request with this probability.
  LATENCY_MS=<ms>      Sleep this long before responding (simulate slow network).
  DROP_RATE=<0..1>     With this probability, read the body then hang/close
                       without responding (simulate a black-hole network).
  PORT=<port>          Listen port (default 8080).

Run
---
  python3 mock-server/server.py
  # or with faults:
  FAIL_FIRST_N=2 LATENCY_MS=500 python3 mock-server/server.py

Health check
------------
  GET /health  -> 200 {"status":"ok", ...}
"""

from __future__ import annotations

import json
import os
import random
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

RECEIVED_DIR = Path(__file__).resolve().parent / "received"
RECEIVED_DIR.mkdir(exist_ok=True)

PORT = int(os.environ.get("PORT", "8080"))
FORCE_STATUS = int(os.environ.get("FORCE_STATUS", "0"))  # if set, always return this status
FAIL_FIRST_N = int(os.environ.get("FAIL_FIRST_N", "0"))
FAIL_RATE = float(os.environ.get("FAIL_RATE", "0"))
LATENCY_MS = int(os.environ.get("LATENCY_MS", "0"))
DROP_RATE = float(os.environ.get("DROP_RATE", "0"))

# In-memory server state. Fine for a mock; resets when the process restarts.
_attempts: dict[str, int] = {}          # capture_id -> attempts seen
_stored: set[str] = set()               # capture_ids already persisted (idempotency)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%S")


def _log(message: str) -> None:
    print(f"[{_now()}] {message}", flush=True)


class Handler(BaseHTTPRequestHandler):
    # Quieter default logging; we do our own.
    def log_message(self, *args) -> None:  # noqa: D401
        pass

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ---- Routing -------------------------------------------------------

    def do_GET(self) -> None:
        if self.path.startswith("/health"):
            self._send_json(200, {
                "status": "ok",
                "received": len(_stored),
                "faults": {
                    "FAIL_FIRST_N": FAIL_FIRST_N,
                    "FAIL_RATE": FAIL_RATE,
                    "LATENCY_MS": LATENCY_MS,
                    "DROP_RATE": DROP_RATE,
                },
            })
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if not self.path.startswith("/upload"):
            self._send_json(404, {"error": "not found"})
            return

        capture_id, image_bytes = self._parse_upload()
        attempt = _attempts.get(capture_id, 0) + 1
        _attempts[capture_id] = attempt

        # Optional latency, applied before any fault decision.
        if LATENCY_MS > 0:
            time.sleep(LATENCY_MS / 1000.0)

        # Black-hole: read the request but never answer. The client must time
        # out and retry. We simply return without writing a response.
        if DROP_RATE > 0 and random.random() < DROP_RATE:
            _log(f"DROP    id={capture_id[:8]} attempt={attempt} (no response sent)")
            return

        # Always return a fixed status (e.g. 400 to force a permanent failure).
        if FORCE_STATUS:
            _log(f"{FORCE_STATUS}   id={capture_id[:8]} attempt={attempt} (force-status)")
            self._send_json(FORCE_STATUS, {"error": "forced status", "attempt": attempt})
            return

        # Deterministic fail-first-N per id, then succeed.
        if attempt <= FAIL_FIRST_N:
            _log(f"503     id={capture_id[:8]} attempt={attempt} (fail-first-{FAIL_FIRST_N})")
            self._send_json(503, {"error": "service unavailable (injected)", "attempt": attempt})
            return

        # Independent random failures.
        if FAIL_RATE > 0 and random.random() < FAIL_RATE:
            _log(f"500     id={capture_id[:8]} attempt={attempt} (fail-rate)")
            self._send_json(500, {"error": "internal error (injected)", "attempt": attempt})
            return

        # Success path — idempotent store.
        if capture_id in _stored:
            _log(f"200 DUP id={capture_id[:8]} attempt={attempt} (already stored)")
            self._send_json(200, {"status": "ok", "id": capture_id, "duplicate": True})
            return

        if image_bytes and capture_id != "unknown":
            out = RECEIVED_DIR / f"{capture_id}.jpg"
            out.write_bytes(image_bytes)
        _stored.add(capture_id)
        _log(f"200 OK  id={capture_id[:8]} attempt={attempt} bytes={len(image_bytes)} stored={len(_stored)}")
        self._send_json(200, {"status": "ok", "id": capture_id, "duplicate": False, "bytes": len(image_bytes)})

    # ---- Body parsing --------------------------------------------------

    def _parse_upload(self) -> tuple[str, bytes]:
        """Return (capture_id, image_bytes) from the raw request body.

        capture_id is taken from the `X-Capture-Id` header (what the app sends)
        or a `?id=` query param as a fallback.
        """
        length = int(self.headers.get("Content-Length", "0"))
        image_bytes = self.rfile.read(length) if length else b""

        capture_id = self.headers.get("X-Capture-Id")
        if not capture_id and "id=" in self.path:
            capture_id = self.path.split("id=", 1)[1].split("&", 1)[0]
        return (capture_id or "unknown", image_bytes)


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    _log(f"Mock backend listening on http://localhost:{PORT}")
    _log(f"  faults: FAIL_FIRST_N={FAIL_FIRST_N} FAIL_RATE={FAIL_RATE} "
         f"LATENCY_MS={LATENCY_MS} DROP_RATE={DROP_RATE}")
    _log(f"  received images -> {RECEIVED_DIR}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _log("shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
