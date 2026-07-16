# Herdr Remote Keypad Implementation Tracker

Last updated: 2026-07-15  
Allowed states: `Not started`, `In progress`, `Blocked`, `Done`

A task is `Done` only when its acceptance evidence is recorded here. A phase is `Done` only when every exit criterion passes.

## Current milestone

| Phase | Status | Exit result |
|---|---|---|
| 0. Herdr API validation | Done | Disposable prompt controlled through the bridge |
| 1. Rust connector vertical slice | Done | Local and Tailscale acceptance checks passed |
| 2. SwiftUI dashboard and keypad | In progress | SwiftUI dashboard and keypad simulator-verified; physical iPhone acceptance pending |
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

- [x] Create the native SwiftUI project on the Xcode-equipped MacBook.
- [x] Implement protocol v1 models and `Network.framework` connection as an iOS 18+ Swift package.
- [x] Add manual host/token configuration and Keychain storage.
- [x] Add connection state and bounded automatic reconnect to the Swift package.
- [x] Add a four-column square agent-key grid, confirmed Herdr pane focus, and clear selected-agent identity.
- [x] Add a connected D-pad, Enter, Tab, haptics, and disconnected-state disabling.
- [x] Add active-looking Accept, Deny, Voice, and blank-agent placeholders with local press feedback only.
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
| 2026-07-15 | Remove terminal streaming and keep the keypad target client-local | The phone acts as a keypad while the user watches another display |
| 2026-07-15 | Focus the matching Herdr pane before changing the keypad target | The watched display and phone controls stay aligned after an agent tap |
| 2026-07-15 | Revise protocol v1 in place | No released client depends on the earlier terminal-streaming draft |
| 2026-07-15 | Target iOS 18+ in the shared Swift package | Matches the chosen compatibility floor and modern Swift concurrency |
| 2026-07-15 | Use typed Swift wire messages and a five-second request timeout | Invalid message shapes become unrepresentable and stalled responses cannot hang the app indefinitely |
| 2026-07-15 | Use a neutral-white modern hardware style for the iPhone keypad | Large sculpted square keys, circular recessed dishes, and a connected D-pad make the remote tactile without copying retro screws, dials, textures, or decoration |
| 2026-07-15 | Keep Accept, Deny, and Voice local-only until their integrations are structured | The placeholders can demonstrate the final interaction without blindly sending input to the wrong prompt |
| 2026-07-15 | Keep bridge port 8765 fixed in the first iPhone setup screen | Manual host and token are sufficient for the current single-owner Tailscale workflow |

## Verification evidence

| Date | Check | Result | Evidence |
|---|---|---|---|
| 2026-07-15 | Local environment | Pass | Rust 1.96.0, Swift 6.3, Herdr 0.7.4, and Tailscale IPv4 available |
| 2026-07-15 | Herdr API inspection | Pass | Snapshot, agent state, and pane input methods found in installed protocol 16 schema |
| 2026-07-15 | Rust quality gates | Pass | 7 tests passed; `cargo fmt --check` and Clippy with `-D warnings` passed |
| 2026-07-15 | Rust full-route integration | Pass | Fake Unix Herdr plus loopback TCP verified auth, snapshot, key/text forwarding, and rejection boundaries |
| 2026-07-15 | Agent pane focus route | Pass | Rust integration forwarded current agents to `pane.focus`, rejected stale IDs before forwarding, Swift verified acknowledgement/errors, and a live bridge focused the installed Herdr session's current pane |
| 2026-07-15 | Credential boundary | Pass | Token mode `0600`; incorrect token returned `authentication_failed` before agent state |
| 2026-07-15 | Local input | Pass | Text acknowledgement completed in 0.11 s; all eight keys completed in 0.03 s total; `ctrl_c` returned `invalid_key` |
| 2026-07-15 | Agent state | Pass | Idle-to-blocked snapshot arrived automatically and pane removal emitted a reduced snapshot |
| 2026-07-15 | Tailscale endpoint | Pass | Default bind selected the machine's private Tailscale IPv4 address; authenticated ping, list, and text input succeeded |
| 2026-07-15 | Herdr recovery | Pass | A connected probe received `unavailable`, then `connected` and a fresh snapshot when the configured socket appeared |
| 2026-07-15 | Swift package tests | Pass | 16 tests covered framing, typed envelopes, validation, auth, input, errors, reconnect, cancellation, request timeout, and live interoperability |
| 2026-07-15 | Swift-to-Rust live smoke | Pass | Swift authenticated to the localhost Rust bridge, received current Herdr agents, and completed ping without sending agent input |
| 2026-07-15 | Post-audit connector regression | Pass | Updated Rust list/ping and Swift live smoke passed against the real Herdr 0.7.4 socket; no agent input was sent |
| 2026-07-15 | iOS simulator build and app-model test | Pass | Xcode 26.4.1 built the iOS 18 app for an iPhone 17 Pro Max simulator; blocked-first ordering and keypad gating test passed after confirmed-focus selection wiring |
| 2026-07-15 | iOS visual and accessibility review | Pass | The four-column grid, rounded D-pad, and centered Voice key rendered without clipping on iPhone 17e and 17 Pro Max at standard and large content sizes; lighter shadows, VoiceOver names, and local-only placeholder feedback were verified |
| 2026-07-15 | iOS-to-Rust live simulator smoke | Pass | The app authenticated with a disposable simulator credential, displayed current agents from the real Herdr socket, and enabled the D-pad, Enter, and Tab after explicit selection; placeholder taps remained local and no test input was sent |
| 2026-07-15 | Unavailable-endpoint reconnect regression | Pass | Swift client now treats `Network.framework` waiting as a transport interruption; 16 package tests cover the bounded reconnect path |
