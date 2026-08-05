# Design

This document explains the architecture, the concurrency and threading model,
and the trade-offs made within the four-hour time box.

## The guarantee, and where it comes from

The core promise is that a completed capture is never silently lost. The design
achieves this by making the **durable store the source of truth**, not any
in-memory or in-flight state:

1. The image bytes and a `pending` metadata record are written to disk before
   any network call is attempted.
2. Every state transition is persisted immediately.
3. On launch (and on return to foreground, and on reconnect), the upload manager
   reconciles the persisted queue against reality and re-drives anything that was
   interrupted.
4. Uploads are idempotent on a client-generated id, so re-driving an item that
   may already have reached the backend cannot create a duplicate.

Because durability rests on these four points rather than on the operating system
keeping a transfer alive, the guarantee holds even for a hard process kill, and
it is demonstrable in the Simulator.

## Architecture

Three components, matching the brief, plus a thin UI facade.

```
              +-------------------------------+
              |      Mock Backend Endpoint     |
              +-------------------------------+
                            ^
                            |  upload / retry / resume
              +-------------------------------+
              |         UploadManager          |   orchestration + state machine
              |   (RetryPolicy, reconciliation)|
              +-------------------------------+
                 ^                        ^
   read/update   |                        |  enqueue (UploadTransport seam)
                 v                        v
      +---------------------+   +----------------------------+
      | FileCaptureQueueStore|  | BackgroundUploadTransport  |
      |  (actor, on disk)    |  |  (URLSession, from file)   |
      +---------------------+   +----------------------------+
                 ^
   write on capture
                 |
      +---------------------+
      |   CaptureQueueModel  |  @MainActor @Observable UI facade
      |   + Capture (Photos) |
      +---------------------+
```

### The seams (dependency injection)

The single highest-leverage design decision is where the substitutable
boundaries go. The rule applied: only side effects you cannot control get a
protocol. That yields exactly three seams, each with one production
implementation and one test double:

- **Disk**: `CaptureQueueStore` (production `FileCaptureQueueStore`; tests use a
  temp-directory instance).
- **Network**: `UploadTransport` (production `BackgroundUploadTransport`; tests
  use `FakeUploadTransport`).
- **Connectivity**: `ConnectivityMonitor` (production `PathConnectivityMonitor`;
  tests and demos use `ScriptedConnectivityMonitor`).

Pure logic (`RetryPolicy` backoff math, `UploadState` transitions, the
`StatusMessage` derivation) has no protocol, because there is nothing to
substitute. Dependencies are wired by hand through a composition root
(`AppLaunch.makeModel`) using constructor injection. No DI container is used:
for three seams and roughly a dozen types, a container would add indirection
without removing anything. If this grew into a multi-module app with per-session
and per-user lifetimes, the escalation path is a container such as Factory.

## The state machine

`UploadState` is a single enum, so impossible states (for example "uploaded and
failed at once") cannot be represented:

```
pending    persisted, not yet handed to the network
uploading  handed to the transport, or actively being retried
uploaded   backend confirmed receipt (2xx). Terminal.
failed     retries exhausted, or a permanent error. Needs manual retry.
```

Transitions:

- `pending -> uploading`: an upload is enqueued.
- `uploading -> uploaded`: the backend returns 2xx.
- `uploading -> uploading`: a retryable failure with attempts remaining. The
  item stays `uploading` through backoff, so `failed` means only "needs a human".
- `uploading -> failed`: retries exhausted, or a non-retryable (4xx) response.
- `failed -> uploading`: manual retry (resets the attempt budget).

## Persistence design

Layout under the app's Documents directory:

```
CaptureQueue/images/<uuid>.jpg   raw capture bytes
CaptureQueue/items/<uuid>.json   metadata (state, attempts, timestamps, lastError)
```

Decisions:

- **Persist-first.** `writeCapture` writes the image bytes, then the metadata
  record, and only then returns. The UI does not show a capture until this has
  completed, so what the user sees is always already on disk.
- **Image before metadata.** If the process dies between the two writes, the only
  possible orphan is an image with no record, which is recoverable. The reverse
  (a record pointing at absent bytes) is unrecoverable, so it is made impossible.
  If the metadata write fails, the image is rolled back.
- **Per-item sidecar files, not one manifest.** Each record is independent, so a
  write for one item can never corrupt another, a single unreadable file costs
  one capture instead of the whole queue, and concurrent updates to different
  items do not contend on a shared file.
- **Atomic writes.** Every file write uses `.atomic` (write to a temporary file,
  then rename), so a crash mid-write leaves either the old bytes or the new,
  never a half-written record.
- **Corruption tolerance.** `loadAll` skips an unreadable record rather than
  failing, so one bad file cannot sink the queue on launch.

## The upload pipeline

`UploadManager` owns the orchestration and depends only on the store and the
transport protocol. The production transport, `BackgroundUploadTransport`, wraps
a `URLSession` that uploads **from a file** (required for background sessions,
and a natural fit since every capture is already a file). Completions arrive on
the session's delegate and are forwarded onto an `AsyncStream` that the manager
consumes.

The transport reports one of two outcomes per attempt:

- `success` on 2xx.
- `failure(retryable:)` otherwise, where retryable is true for network errors,
  timeouts, and 408 / 429 / 5xx, and false for other 4xx. This split is what
  stops the manager from spinning forever on a request the server will always
  reject.

### Retry and backoff

`RetryPolicy` is a pure value type: exponential growth (`base * multiplier^n`),
capped at a maximum delay, with plus-or-minus jitter so a fleet of devices does
not stampede the backend in lockstep after an outage, and a bounded attempt
count. The random source is injectable, so the backoff is unit-tested with exact
expected values.

### Reconciliation on launch

`resume()` loads the persisted queue and, for each item:

- `pending`: enqueue it.
- `uploading` that the transport is not currently carrying: re-drive it (this is
  the killed-mid-upload case).
- `uploading` that the transport is still carrying, `uploaded`, or `failed`:
  leave it.

`resume()` is safe to call repeatedly. It runs on launch, on return to
foreground (`scenePhase`), and on reconnect.

## Connectivity and user feedback

`PathConnectivityMonitor` wraps `NWPathMonitor`, maps each `NWPath` to a small
transport-agnostic `NetworkStatus` (online, expensive, constrained, interface),
and broadcasts it to multiple subscribers from a single monitor. The UI reads it
for the status banner; the manager reads it (via the model) to pause and resume.

When offline, new and interrupted items stay `pending` and backoff timers are
cancelled, rather than being handed to the transport to fail in a loop and drain
the battery. On reconnect, `resume()` re-drives everything.

`CaptureQueueModel` derives a single `StatusMessage` from queue counts plus
network status, priority-ordered: offline, then uploading (noting Cellular),
then failed, then waiting, then all-uploaded (noting Low Data Mode). The banner
is slim and non-blocking; the success message auto-dismisses.

## Concurrency and threading model

The model is deliberately small and boundary-based:

- **`FileCaptureQueueStore` is an `actor`.** All disk access is serialized
  through it, so concurrent updates from the upload manager and reads for the UI
  cannot race, with no manual locks. Combined with atomic writes, there are no
  half-written or interleaved records. The only non-isolated member is
  `imageURL(for:)`, which is a pure function of immutable state.

- **`UploadManager` and `CaptureQueueModel` are `@MainActor`.** UI-observed state
  is mutated only on the main thread, checked by the compiler rather than by
  `DispatchQueue.main.async` discipline. The manager processes upload outcomes on
  the main actor and pushes each persisted change to the model through a callback,
  keeping the UI a faithful mirror of disk.

- **Cross-boundary events use `AsyncStream`.** The transport delivers completions
  (from the `URLSession` delegate's private queue) and the connectivity monitor
  delivers path changes (from `NWPathMonitor`'s queue) as async streams. The
  main-actor consumers await them, so values cross the thread boundary through
  the concurrency runtime rather than through shared mutable state.

- **The two `@unchecked Sendable` types** are the transport and the connectivity
  monitors. Each is an object bridging a callback-based Apple API to an
  `AsyncStream`; their small mutable state (a stream continuation, a subscriber
  map) is guarded by an `NSLock`. `@unchecked` is the honest annotation here: the
  safety is real but hand-maintained rather than compiler-proven.

- **Retry scheduling** uses a per-item `Task` with `Task.sleep` for the backoff
  delay. Going offline cancels these; a manual retry cancels and replaces the
  one for that item.

Language mode is Swift 5 for this build to keep the concurrency surface friendly
within the time box; the code is written to be clean under stricter checking and
would move to the Swift 6 language mode as a follow-up.

## Why idempotency is the linchpin

The killed-mid-upload case has a subtle race: the OS or server may have received
an upload that the app never learned succeeded, because it was killed before the
response arrived. Rather than try to reclaim that in-flight transfer (fragile,
and impossible after a hard kill), the design simply re-uploads on relaunch and
relies on the backend deduping on the capture id. The end-to-end test shows
exactly this: the first attempt reaches the server and is stored, the app is
killed before it hears back, and on relaunch the re-upload returns "duplicate,
already stored". One record, no loss, no duplicate.

This is also why `resume()` is safe to call redundantly, and why the one place
where a foreground `resume()` can re-enqueue an item that is genuinely still
in flight is harmless: at worst it costs one deduplicated request.

## The Simulator versus device decision

Background `URLSession` relies on `nsurlsessiond`, which is not functional in the
iOS Simulator (tasks fail immediately with `NSURLErrorUnknown`). The transport
therefore uses `URLSessionConfiguration.background` on device and
`URLSessionConfiguration.default` in the Simulator, selected with
`#if targetEnvironment(simulator)`.

This is a safe substitution for the guarantees here. What a background
configuration adds on device is the OS continuing a transfer while the app is
suspended. The resilience scenarios in this assessment (kill, offline, relaunch)
are all satisfied by the durable store, launch reconciliation, and server
idempotency, which are identical under both configurations. The device path
additionally handles the background-events completion handler
(`urlSessionDidFinishEvents`), wired through so a real device can be woken to
flush completions.

## Security: data at rest

The payload is identity documents and selfies, so captures are protected on disk.

- **Encryption at rest.** `CaptureCrypto` seals image bytes with AES-256-GCM
  before the store writes them, so the persisted `.enc` files are ciphertext
  (verified: an on-disk capture does not start with the JPEG magic bytes). GCM is
  authenticated, so tampered ciphertext fails to open rather than decrypting to
  garbage. Metadata sidecars are left in clear text deliberately: they hold no PII
  (a random UUID, a state, timestamps, and a short error string).
- **Key management.** The 256-bit key is created once and stored in the Keychain
  as `afterFirstUnlockThisDeviceOnly`: available for background uploads after the
  first unlock since boot, never synced to iCloud Keychain, and never in backups.
  A device backup therefore contains only ciphertext with no key to open it.
  Unsigned builds have no Keychain entitlement, so `CaptureKeyProvider` falls back
  to a Data-Protected, backup-excluded key file; signed builds always use the
  Keychain.
- **iOS Data Protection.** Every write carries
  `completeUntilFirstUserAuthentication`, which keeps files encrypted until first
  unlock while still allowing locked-state background uploads. Stricter
  `.complete` would block locked uploads, which conflicts with the whole point of
  the app. The queue directory is also excluded from iCloud/iTunes backup.
- **Decrypt only in a narrow window.** A background upload must send from a file,
  so the store writes a short-lived decrypted temp file for the transport, which
  the manager deletes on completion. A launch-time purge removes any temp left by
  a previous run that was killed mid-upload, so plaintext never lingers.
- **Data minimisation.** Once an upload is confirmed, the local image bytes are
  erased and only the metadata receipt is kept. This shrinks the at-rest exposure
  window for a delivered identity image to nearly zero.

These are verified by unit tests (ciphertext on disk, wrong-key cannot open,
tamper rejected, minimisation erases bytes but keeps the receipt) and by an
end-to-end run.

## Security: data in transit

- **TLS certificate pinning.** `CertificatePinner` holds a set of pinned
  certificate fingerprints (base64 SHA-256 of the DER). The transport's
  `URLSession` server-trust challenge validates the presented chain against the
  pins and rejects a mismatch, defeating a man-in-the-middle that presents a
  different certificate even if it is validly issued. Pinning is inert when no
  pins are configured, so the local http mock still works. Whole-certificate
  pinning is used for a self-contained, testable implementation; production would
  usually pin the public key (SPKI), which survives certificate renewal, using
  the same evaluation flow.
- **Authentication.** Each upload carries an `Authorization: Bearer` token read
  from the Keychain (`AuthTokenStore`). The request builder is a pure static
  function, so the header logic is unit-tested directly.
- Verified end to end against a self-signed HTTPS mock: the correct pin uploads
  successfully, a wrong pin is rejected (nothing reaches the server), and a
  missing token yields a 401 that the manager records as a permanent failure.

## Security: on-device access

- **Backgrounding privacy screen.** A cover view is shown whenever
  `scenePhase != .active`, so the snapshot iOS takes on backgrounding does not
  capture identity thumbnails. The decision is a pure function, unit-tested.
- **Biometric gate.** `BiometricAuthenticator` (a seam, so it is testable with a
  fake) gates the queue behind Face ID / Touch ID with a passcode fallback via
  `LocalAuthentication`. It degrades open when no biometrics or passcode are
  configured, so a bare device is not locked out. The gate logic is unit-tested
  (unlock on success, stay locked on failure, open when disabled).

## Testing strategy

- **Unit tests target the logic that matters**, behind the seams: the store
  (persistence, relaunch survival, upsert, corruption tolerance), the backoff
  math (exact values with an injected RNG), and the manager's state machine
  (success, retry-then-success, exhaustion, non-retryable, manual retry, launch
  reconciliation of stale `uploading`, no-duplicate when in flight, and
  offline-then-reconnect).
- **The manager tests use a real store (temp dir) plus a fake transport**, so
  they exercise persistence and orchestration together while remaining fast and
  deterministic. A tiny backoff policy keeps retries near-instant.
- The view layer is intentionally thin; behaviour worth testing lives in the
  model and manager, not in `body`. A launch-argument seam (`AppLaunch`) supports
  seeding and scripted connectivity for end-to-end verification.

## Trade-offs made within the time box

- **Standard `URLSession` in the Simulator** (discussed above): pragmatic, so the
  full pipeline is demonstrable without a device, at the cost of not exercising
  OS-continued suspended transfers in this environment.
- **Encryption key fallback in unsigned builds.** The key belongs in the
  Keychain; an unsigned Simulator build cannot use it, so a Data-Protected key
  file stands in. Signed builds always use the Keychain. Chosen so the proof of
  concept runs without a signing identity.
- **A single foreground `resume()` can cause one redundant, deduplicated
  request** on cold launch. Chosen over adding coordination, because idempotency
  already makes it correct and cheap.
- **In-memory mock backend.** Enough to prove client behaviour and idempotency;
  not a real service.
- **Photo-library capture rather than live camera.** The brief allows it, and it
  keeps the capture path runnable in the Simulator. A camera path is guarded for
  device by the same `PhotosPicker`-adjacent flow.

## Future work

Security:

- **Pin the public key (SPKI)** rather than the whole certificate, so pinning
  survives certificate renewal when the key is reused.
- **App Attest / DeviceCheck** so the backend only accepts genuine app instances.
- Token refresh and a real sign-in flow feeding `AuthTokenStore`.

Other:

- Move to the Swift 6 language mode and remove the `@unchecked Sendable`
  annotations where the compiler can then prove safety.
- Add the real multipart envelope the production backend expects.
- Surface a small storage budget and pruning policy for metadata receipts.
- Add a couple of XCUITest flows for the capture and manual-retry paths.
