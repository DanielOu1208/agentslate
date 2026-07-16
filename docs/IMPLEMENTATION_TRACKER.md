# Herdr Remote Keypad Implementation Tracker

Last updated: 2026-07-15  
Allowed states: `Not started`, `In progress`, `Blocked`, `Done`

A task is `Done` only when its acceptance evidence is recorded here. A phase is `Done` only when every exit criterion passes.

## Current milestone

| Phase | Status | Exit result |
|---|---|---|
| 0. Herdr API validation | Done | Disposable prompt controlled through the bridge |
| 1. Rust connector vertical slice | Done | Local and Tailscale acceptance checks passed |
| 2. SwiftUI dashboard and keypad | In progress | Shared Swift networking package done; Xcode UI pending |
| 3. Typed and voice interaction | Not started | Starts after keypad loop is reliable |
| 4. Pairing and lifecycle | Not started | Starts before wider beta |
| 5. Hardening | Not started | Starts after daily-use validation |

## Phase 0: Herdr API validation

- [x] Confirm Herdr 0.7.4 exposes `session.snapshot` and normalized agent records.
- [x] Confirm `pane.send_keys`, `pane.send_input`, and subscriptions exist in the installed schema.
- [x] Confirm observing state uses a separate local Unix socket and does not take over the visible Herdr client.
- [x] Navigate and submit a disposable test prompt through the bridge probe.
- [x] Record input acknowledgement latency.

Exit criterion: a disposable agent prompt is controlled without sending keys through the desktop Herdr client.

## Phase 1: Rust connector vertical slice

### Repository and contract

- [x] Create the local Git repository in the development workspace.
- [x] Separate connector, iPhone vertical slice, and complete MVP acceptance criteria.
- [x] Revise protocol v1 to the keypad-only contract before a client release.
- [x] Run a final document consistency review after implementation.

### Bridge

- [x] Generate and validate an owner-only 256-bit token file.
- [x] Bind to the discovered Tailscale IPv4 address by default and fail closed when unavailable.
- [x] Authenticate before sending any Herdr state.
- [x] Bootstrap and normalize agents from `session.snapshot`.
- [x] Refresh the full snapshot within 200 ms when normalized agent state changes.
- [x] Forward the eight allowlisted keys.
- [x] Forward printable text with optional atomic Enter.
- [x] Validate current agent membership before every input.
- [x] Report Herdr unavailability and reconnect with bounded backoff.
- [x] Avoid logging tokens and input text.

### Probe and verification

- [x] Implement `list`, `key`, `text`, and `ping` probe commands.
- [x] Add unit tests for credentials, protocol validation, and input bounds.
- [x] Add a full-route fake-Herdr integration test over Unix and TCP sockets.
- [x] Pass `cargo fmt --check`, Clippy with warnings denied, and `cargo test`.
- [x] Pass localhost live smoke test using a disposable Herdr pane.
- [x] Pass Tailscale-address smoke test.

Exit criterion: the authenticated probe lists current agents and safely operates a disposable prompt over Tailscale.

## Phase 2: SwiftUI dashboard and keypad

- [ ] Create the native SwiftUI project on the Xcode-equipped MacBook.
- [x] Implement protocol v1 models and `Network.framework` connection as an iOS 18+ Swift package.
- [ ] Add manual host/token configuration and Keychain storage.
- [x] Add connection state and bounded automatic reconnect to the Swift package.
- [ ] Add horizontally scrolling agents, local selection, and clear selected-agent identity.
- [ ] Add arrows, Enter, Escape, Tab, Space, haptics, and disconnected-state disabling.
- [ ] Verify at least three simultaneous agents on a physical iPhone.

Exit criterion: command approvals and question pickers can be completed from the physical iPhone while its target screen remains visible elsewhere.

## Phase 3: Typed and voice interaction

- [ ] Add text editing, send, send-without-Enter, cancel, and target-agent confirmation.
- [ ] Add microphone permission and audio-session handling.
- [ ] Add hold-to-talk, partial transcription, release-to-send, and cancellation.
- [ ] Add review-before-send and automatic-Enter options.
- [ ] Preserve partial transcription when recognition fails.

Exit criterion: typed and spoken instructions reach the selected agent without streaming audio off the phone.

## Phase 4: Pairing and lifecycle

- [ ] Replace the shared token with one-time pairing and per-device credentials.
- [ ] Store iPhone credentials in Keychain and support revocation.
- [ ] Add QR configuration and authentication throttling.
- [ ] Add launchd management for the persistent bridge.
- [ ] Re-evaluate a Herdr plugin only for pair/status/restart/revoke controls.

Exit criterion: an unpaired device cannot read state or send input, and setup no longer requires copying configuration manually.

## Phase 5: Hardening

- [ ] Test multiple agents, interruptions, lock/unlock, Herdr restarts, and Tailscale route changes.
- [ ] Measure CPU, memory, battery, reconnection rate, and crash-free sessions.
- [ ] Add redacted diagnostics, onboarding, TestFlight, and troubleshooting.

Exit criterion: the app is reliable enough for repeated daily supervision.

## Decision log

| Date | Decision | Reason |
|---|---|---|
| 2026-07-15 | Build the connector on the Mac mini before SwiftUI | Full Xcode is available on the later MacBook, not this device |
| 2026-07-15 | Use Rust for the connector | Prefer a durable native binary for the long-running bridge |
| 2026-07-15 | Track work in repository Markdown | Keeps requirements, evidence, and code versioned together |
| 2026-07-15 | Generate a shared development token file | Smallest authenticated configuration before QR pairing |
| 2026-07-15 | Defer the Herdr plugin | It would add launcher/management UI but no connector capability |
| 2026-07-15 | Poll normalized agent state every 200 ms | Change-only polling is deterministic for one phone and meets the status target |
| 2026-07-15 | Remove terminal streaming and keep selection client-local | The phone acts as a keypad while the user watches another display |
| 2026-07-15 | Revise protocol v1 in place | No released client depends on the earlier terminal-streaming draft |
| 2026-07-15 | Target iOS 18+ in the shared Swift package | Matches the chosen compatibility floor and modern Swift concurrency |
| 2026-07-15 | Use typed Swift wire messages and a five-second request timeout | Invalid message shapes become unrepresentable and stalled responses cannot hang the app indefinitely |

## Verification evidence

| Date | Check | Result | Evidence |
|---|---|---|---|
| 2026-07-15 | Local environment | Pass | Rust 1.96.0, Swift 6.3, Herdr 0.7.4, and Tailscale IPv4 available |
| 2026-07-15 | Herdr API inspection | Pass | Snapshot, agent state, and pane input methods found in installed protocol 16 schema |
| 2026-07-15 | Rust quality gates | Pass | 7 tests passed; `cargo fmt --check` and Clippy with `-D warnings` passed |
| 2026-07-15 | Rust full-route integration | Pass | Fake Unix Herdr plus loopback TCP verified auth, snapshot, key/text forwarding, and rejection boundaries |
| 2026-07-15 | Credential boundary | Pass | Token mode `0600`; incorrect token returned `authentication_failed` before agent state |
| 2026-07-15 | Local input | Pass | Text acknowledgement completed in 0.11 s; all eight keys completed in 0.03 s total; `ctrl_c` returned `invalid_key` |
| 2026-07-15 | Agent state | Pass | Idle-to-blocked snapshot arrived automatically and pane removal emitted a reduced snapshot |
| 2026-07-15 | Tailscale endpoint | Pass | Default bind selected the machine's private Tailscale IPv4 address; authenticated ping, list, and text input succeeded |
| 2026-07-15 | Herdr recovery | Pass | A connected probe received `unavailable`, then `connected` and a fresh snapshot when the configured socket appeared |
| 2026-07-15 | Swift package tests | Pass | 15 tests covered framing, typed envelopes, validation, auth, input, errors, reconnect, cancellation, request timeout, and live interoperability |
| 2026-07-15 | Swift-to-Rust live smoke | Pass | Swift authenticated to the localhost Rust bridge, received current Herdr agents, and completed ping without sending agent input |
| 2026-07-15 | Post-audit connector regression | Pass | Updated Rust list/ping and Swift live smoke passed against the real Herdr 0.7.4 socket; no agent input was sent |
