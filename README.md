# ResilientCapture

A native iOS proof of concept for iiDENTIFii's problem: capturing an identity
document or selfie on device and delivering it to a verification backend so that
**no completed capture is ever silently lost**, even under patchy networks, app
backgrounding, or a full app relaunch.

The app is a resilient `capture -> local persistence -> background-safe upload`
pipeline. A capture is written to disk and marked `pending` the instant it is
taken, before any network call, and an upload manager delivers it with retry,
backoff, connectivity awareness, and launch-time reconciliation. Uploads are
idempotent on a client-generated id, so a retry after a crash can never create a
duplicate verification.

SwiftUI, iOS 17+, no third-party dependencies.

## Quick start

Two terminals.

**1. Start the mock backend** (Python 3 standard library only, no `pip install`):

```bash
python3 mock-server/server.py
```

It listens on `http://localhost:8080`. See [mock-server/README.md](mock-server/README.md)
for fault-injection options (slow, flaky, offline, permanent-failure).

**2. Run the app** in Xcode:

```bash
open ResilientCapture.xcodeproj
```

Pick an iPhone simulator and Run. Tap the **+** button to select a photo from the
library (photo-library selection is used so it works in the Simulator). The
capture appears immediately as `pending`, then moves to `uploading` and
`uploaded`. Failed items show a **Retry** button.

The app talks to the backend at `127.0.0.1:8080` (see
[AppConfig.swift](ResilientCapture/Support/AppConfig.swift)).

## Run the tests

```bash
xcodebuild test \
  -scheme ResilientCapture \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

24 tests: persistence (persist-first, relaunch survival, corruption tolerance),
backoff math, and the retry/resume/reconciliation/connectivity state machine.

## What it demonstrates

| Scenario | Guarantee | How |
|----------|-----------|-----|
| App killed mid-upload | Capture is not lost | Image + `pending` metadata are written to disk before any network call; on relaunch `resume()` re-drives interrupted items |
| App killed mid-upload | No duplicate verification | Capture id is an idempotency key; the backend stores it once, so a re-upload is deduped |
| Connectivity lost | Uploads pause, nothing lost | `NWPathMonitor` reports offline; items stay `pending`, retry timers are cancelled |
| Connectivity restored | Uploads resume automatically | Reconnect triggers `resume()` |
| Full relaunch | Queue survives | Queue state lives in per-item files on disk, reloaded on launch |
| Transient server error (5xx/timeout) | Retried, then delivered | Exponential backoff with jitter, capped, bounded attempts |
| Permanent error (4xx) | Not retried, surfaced for manual retry | Marked `failed`; the user can tap Retry |

The user is kept informed with a small, non-invasive status banner (offline,
uploading N, N failed, all uploaded) that also notes Cellular / Low Data Mode.

## Project structure

```
ResilientCapture/
  Models/            CaptureItem + UploadState (the state machine); StatusMessage
  Persistence/       CaptureQueueStore (protocol) + FileCaptureQueueStore (actor)
  ImageProcessing/   ImageIO downsampling (memory-safe capture handling)
  Upload/            UploadTransport (protocol), BackgroundUploadTransport,
                     RetryPolicy, UploadManager (the orchestrator)
  Connectivity/      ConnectivityMonitor (protocol), PathConnectivityMonitor,
                     ScriptedConnectivityMonitor, NetworkStatus
  Queue/             CaptureQueueModel (@Observable UI facade)
  Views/             ContentView, CaptureRowView, ThumbnailView, StateBadgeView,
                     StatusBannerView
  Support/           AppConfig, AppLaunch (composition root + test seam)
ResilientCaptureTests/   store, retry policy, and upload-manager tests + fakes
mock-server/             dependency-free Python mock backend
```

See [DESIGN.md](DESIGN.md) for the architecture, the concurrency and threading
model, and the trade-offs made within the time box.

## Known limitations

- **Background uploads in the Simulator.** The iOS background transfer daemon is
  not functional in the Simulator, so the app uses a background `URLSession` on
  device and a standard `URLSession` in the Simulator. This does not weaken the
  resilience guarantees for the scenarios above, which come from the durable
  store, launch reconciliation, and server idempotency rather than from the OS
  continuing a suspended transfer. See DESIGN.md for detail.
- **Captures are stored unencrypted** in the app's Documents directory. For
  production, identity images should be encrypted at rest (see DESIGN.md, Future
  work).
- **The mock backend keeps state in memory** and resets on restart. It is a test
  stub, not a real service.
