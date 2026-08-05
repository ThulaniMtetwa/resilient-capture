# Mock verification backend

A dependency-free stand-in for iiDENTIFii's verification endpoint. Python 3
standard library only - no `pip install`.

## Run

```bash
python3 mock-server/server.py
```

Listens on `http://localhost:8080`. The iOS Simulator shares the Mac's network,
so the app reaches it at `localhost` directly.

## Endpoints

| Method | Path      | Purpose |
|--------|-----------|---------|
| POST   | `/upload` | Accepts a raw JPEG body. Capture id via `X-Capture-Id` header. |
| GET    | `/health` | Liveness + how many captures have been stored + active faults. |

The capture id is treated as an **idempotency key**: re-uploading the same id
returns `200 {"duplicate": true}` and does **not** store a second copy. Received
images land in `mock-server/received/<id>.jpg`.

## Fault injection (env vars)

Use these to exercise the app's retry / backoff / resume paths:

| Variable        | Effect |
|-----------------|--------|
| `FAIL_FIRST_N`  | Fail the first N attempts **per capture id** with 503, then succeed. |
| `FAIL_RATE`     | Fail each request independently with probability `0..1`. |
| `LATENCY_MS`    | Delay every response (simulate a slow network). |
| `DROP_RATE`     | With probability `0..1`, read the body then never respond (black-hole -> client times out and retries). |
| `FORCE_STATUS`  | Always return this HTTP status (e.g. `400` to force a permanent failure). |
| `REQUIRE_AUTH`  | `1` to reject uploads that lack an `Authorization: Bearer` header (401). |
| `TLS_CERT` / `TLS_KEY` | Paths to a PEM cert/key to serve HTTPS instead of http. |
| `PORT`          | Listen port (default `8080`). |

For the secure-transport demo (TLS + certificate pinning + auth), generate a
self-signed cert and run over HTTPS:

```bash
mkdir -p certs
openssl req -x509 -newkey rsa:2048 -keyout certs/key.pem -out certs/cert.pem \
  -days 3650 -nodes -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1"
REQUIRE_AUTH=1 TLS_CERT=certs/cert.pem TLS_KEY=certs/key.pem PORT=8443 python3 server.py
```

The certificate pin the app expects is
`openssl x509 -in certs/cert.pem -outform der | openssl dgst -sha256 -binary | base64`.

Examples:

```bash
# First two attempts of every capture fail, then succeed - shows retry+backoff
FAIL_FIRST_N=2 python3 mock-server/server.py

# Flaky, slow network
FAIL_RATE=0.4 LATENCY_MS=800 python3 mock-server/server.py

# Black-hole: uploads never get a response
DROP_RATE=1.0 python3 mock-server/server.py
```

## Quick manual check

```bash
curl -s localhost:8080/health
curl -s -X POST -H "X-Capture-Id: demo-1" --data-binary @some.jpg localhost:8080/upload
```
