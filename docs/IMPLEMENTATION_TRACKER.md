# AgentSlate Implementation Tracker

Last updated: 2026-07-16
Allowed states: `Not started`, `In progress`, `Blocked`, `Done`

A task is `Done` only when its acceptance evidence is recorded here. A phase is `Done` only when every exit criterion passes.

## Current milestone

| Phase | Status | Exit result |
|---|---|---|
| 0. Herdr API validation | Done | Disposable prompt controlled through the bridge |
| 1. Rust connector vertical slice | Done | Local and Tailscale acceptance checks passed |
| 2. SwiftUI dashboard and keypad | In progress | SwiftUI dashboard and keypad simulator-verified; physical iPhone acceptance pending |
| 3. Typed and voice interaction | In progress | Send/Cancel/Edit voice flow and review editor are automated-test verified; full simulator visual and physical speech acceptance remain open |
| 4. Pairing and lifecycle | In progress | Protocol v3 Mac and Swift foundations implemented; iPhone onboarding/Forget Bridge acceptance pending |
| 5. Hardening | Not started | Starts after daily-use validation |
| 6. Release staging | In progress | Open-source, Homebrew, Pages, CI, TestFlight, and production-draft materials prepared for owner review |

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
- [x] Replace protocol v1 with the session-aware protocol v2 contract.
- [x] Replace the shared-token protocol with device-paired protocol v3 before public beta.
- [x] Run a final document consistency review after implementation.

### Bridge

- [x] Generate and validate an owner-only 256-bit token file.
- [x] Bind to the discovered Tailscale IPv4 address by default and fail closed when unavailable.
- [x] Authenticate before sending any Herdr state.
- [x] Bootstrap and normalize agents from `session.snapshot`.
- [x] Discover running named sessions and publish their ordered names without exposing socket paths.
- [x] Require and validate a session name before every targeted request.
- [x] Refresh the full snapshot within 200 ms when normalized agent state changes.
- [x] Forward the nine allowlisted keys.
- [x] Forward printable text with optional atomic Enter.
- [x] Validate current agent membership before every input.
- [x] Report Herdr unavailability and reconnect with bounded backoff.
- [x] Avoid logging tokens and input text.

### Probe and verification

- [x] Implement `sessions`, session-aware `list`, `key`, `text`, and `ping` probe commands.
- [x] Add unit tests for credentials, protocol validation, and input bounds.
- [x] Add a full-route fake-Herdr integration test over Unix and TCP sockets.
- [x] Pass `cargo fmt --check`, Clippy with warnings denied, and `cargo test`.
- [x] Pass localhost live smoke test using a disposable Herdr pane.
- [x] Pass Tailscale-address smoke test.

Exit criterion: the authenticated probe lists current agents and safely operates a disposable prompt over Tailscale.

## Phase 2: SwiftUI dashboard and keypad

- [x] Create the native SwiftUI project on the Xcode-equipped MacBook.
- [x] Implement protocol v3 models and `Network.framework` connection as an iOS 18+ Swift package.
- [x] Implement the original manual host/token configuration; superseded by Phase 4 device pairing before beta.
- [x] Add connection state and bounded automatic reconnect to the Swift package.
- [x] Add a branded four-column, 12-slot agent grid with compact working-folder labels, confirmed Herdr pane focus, and clear selected-agent identity.
- [x] Add a native header menu that remembers and safely falls back between running Herdr sessions.
- [x] Add a connected D-pad, Enter, Tab, haptics, and disconnected-state disabling.
- [x] Add dedicated Escape and Shift+Tab keys.
- [x] Add working Accept and Deny shortcuts for blocked Codex, Claude Code, OMP, Cursor, and OpenCode agents; keep blank-agent slots local-only.
- [ ] Verify at least three simultaneous agents on a physical iPhone.

Exit criterion: command approvals and question pickers can be completed from the physical iPhone while its target screen remains visible elsewhere.

## Phase 3: Typed and voice interaction

- [x] Add voice-draft text editing, send, cancel, and exact target-agent/session confirmation.
- [ ] Add a separate typed composer and send-without-Enter control.
- [x] Add microphone permission and audio-session handling.
- [x] Add hold-to-talk, partial transcription, release-to-send, visible drag-to-Cancel/Edit targets, and cancellation.
- [x] Add review-before-send with automatic Enter.
- [x] Preserve partial transcription when recognition fails.

Exit criterion: typed and spoken instructions reach the selected agent without streaming audio off the phone.

## Phase 4: Pairing and lifecycle

- [x] Replace the shared token with a six-digit, single-use pairing code that expires after ten minutes and locks after five failures.
- [x] Generate a separate random 32-byte credential and server-controlled ID for each paired device.
- [x] Store only the credential digest in owner-only Mac state and recheck authorization before every command.
- [x] Add `pair`, `devices list`, `devices revoke`, and self-revocation routes.
- [x] Add protocol v3 pairing/authentication/revocation models to `AgentSlateClient`.
- [x] Store the iPhone device ID and credential in Keychain.
- [x] Replace token onboarding with Mac address plus pairing code.
- [ ] Verify Forget Bridge revokes itself while connected and gives manual-revocation instructions while offline.
- [ ] Verify Setup, Support, Privacy, Acknowledgements, version/build, and offline Demo Mode on a physical iPhone.
- [x] Use the Homebrew service as the persistent bridge manager; do not add a separate launchd layer.

Exit criterion: an unpaired device cannot read state or send input, and setup no longer requires copying configuration manually.

## Phase 5: Hardening

- [ ] Test multiple agents, interruptions, lock/unlock, Herdr restarts, and Tailscale route changes.
- [ ] Measure CPU, memory, battery, reconnection rate, and crash-free sessions.
- [ ] Add redacted diagnostics, onboarding, TestFlight, and troubleshooting.

Exit criterion: the app is reliable enough for repeated daily supervision.

## Phase 6: Release staging

- [x] Add the MIT license, contributor/security policies, third-party notices, and release-ready README.
- [x] Add GitHub Pages landing, privacy, and support pages.
- [x] Add one CI workflow for Rust, Swift package, iOS simulator, and unsigned archive checks.
- [x] Prepare the Homebrew source formula with a release-checksum placeholder.
- [x] Prepare TestFlight metadata, production metadata, and screenshot requirements.
- [ ] Complete formal trademark clearance and confirm App Store name availability.
- [x] Rewrite Git history author/committer emails and verify the personal address is absent.
- [ ] Publish the repository, Pages site, GitHub release, and Homebrew tap only after owner approval.
- [ ] Upload and distribute an external TestFlight build only after owner approval.
- [ ] Install the approved external TestFlight build on reviewers' phones.
- [ ] Keep the production version in Prepare for Submission; do not submit it to App Review.

Exit criterion: the external TestFlight build is approved and installed, public source/Homebrew artifacts are available, and the production App Store version remains an unsubmitted draft.

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
| 2026-07-15 | Keep bridge port 8765 fixed in the first iPhone setup screen | Manual host and token are sufficient for the current single-owner Tailscale workflow |
| 2026-07-15 | Use bundled monochrome agent marks with a terminal fallback | Agent keys remain identifiable without crowding the tactile button face |
| 2026-07-15 | Use Apple on-device SpeechAnalyzer DictationTranscriber for voice MVP | Hold-release-send stays private, matches Phase 3 exit criterion, and reuses existing send_text |
| 2026-07-15 | Target the iPhone app at iOS 26+ for SpeechAnalyzer; keep the Swift package at iOS 18 | Speech stays in the app target; the shared bridge client does not need the newer OS floor |
| 2026-07-15 | Default voice UX to hold, speak, release, then send text plus Enter | Keeps the fastest path as the default outcome |
| 2026-07-16 | Prepare voice after saved bridge setup is available | Existing users prewarm on app launch; new users complete setup first, then incur permission and model preparation once |
| 2026-07-16 | Use the native asynchronous microphone permission API with SpeechAnalyzer | Removes the legacy speech-authorizer actor-isolation crash; SpeechAnalyzer performs recognition on-device, while the app still includes Apple's required speech-usage explanation |
| 2026-07-16 | Use a record-only measurement audio session without ducking other audio | Dictation owns only the microphone path it needs, does not lower other apps' audio, and deactivates capture on cleanup |
| 2026-07-16 | Add visible Cancel/Edit release targets and a target-bound review sheet | Normal release stays fast; alternate outcomes remain explicit and cannot redirect a captured draft to another agent |
| 2026-07-16 | Make VoiceOver dictation a start/send toggle with named Edit and Cancel actions | Hold gestures are not reliable under VoiceOver, while alternate actions preserve all three release outcomes |
| 2026-07-16 | Give Escape and Shift+Tab dedicated keypad buttons | Both controls are common across agent dialogs and mode switching |
| 2026-07-16 | Implement Accept and Deny as watched-screen default-keymap shortcuts for five agent kinds | This is the smallest useful phone workflow; blocked-state revalidation narrows mistakes, while the docs preserve that it is not structured authorization |
| 2026-07-16 | Replace protocol v1 with session-aware protocol v2 | Requiring the session on every request prevents colliding pane IDs from routing to the wrong Herdr server |
| 2026-07-16 | Keep session selection phone-local | The header menu changes the remote target without attaching, switching, or foregrounding anything on the Mac |
| 2026-07-16 | Discover sessions normally and reserve `--herdr-socket` for fixed mode | Herdr injects its current socket into pane environments, so implicitly honoring that variable would disable multi-session discovery |
| 2026-07-16 | Rename the public product and packages to AgentSlate | Gives the open-source beta a concise product identity while keeping Herdr named only as the backend |
| 2026-07-16 | Replace the shared token with protocol v3 device pairing | Short-lived attempt-limited codes simplify onboarding; separate revocable 256-bit credentials provide ongoing authentication |
| 2026-07-16 | Keep pairing manual instead of adding QR setup | A six-digit code and Tailscale address cover the beta without a camera flow or another dependency |
| 2026-07-16 | Stop the release workflow after external TestFlight | Production App Store review and release require a separate explicit owner decision after beta feedback |
| 2026-07-16 | Pause publication after refreshing the AgentSlate name search | Another developer recently announced an AgentSlate product in the coding-agent category, so the private release candidate stays unpublished until the owner chooses a different name or obtains independent clearance |

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
| 2026-07-15 | Agent icon and folder presentation | Pass | App-model tests cover all 21 supported agent kinds, the generic fallback, cwd basename extraction, and workspace fallback; simulator review confirmed recognizable agent marks, softer button glyphs, and one 48-point dish across populated keys, placeholders, controls, and D-pad directions |
| 2026-07-15 | iOS visual and accessibility review | Pass | The four-column grid, rounded D-pad, and centered Voice key rendered without clipping on iPhone 17e and 17 Pro Max at standard and large content sizes; lighter shadows, VoiceOver names, and local-only placeholder feedback were verified |
| 2026-07-15 | iOS-to-Rust live simulator smoke | Pass | The app authenticated with a disposable simulator credential, displayed current agents from the real Herdr socket, and enabled the D-pad, Enter, and Tab after explicit selection; placeholder taps remained local and no test input was sent |
| 2026-07-15 | Unavailable-endpoint reconnect regression | Pass | Swift client now treats `Network.framework` waiting as a transport interruption; 16 package tests cover the bounded reconnect path |
| 2026-07-15 | Initial Apple STT hold-release-send wiring | Superseded | The first build and simulator tests passed, but physical-device logs exposed an actor-isolation crash in the legacy speech authorization callback |
| 2026-07-16 | Speech reliability hardening | Automated pass; device pending | Generic iOS 26 simulator build and all 3 app-model tests pass; microphone permission, preparation, finalization, cancellation, failure display, and VoiceOver paths were reviewed. Xcode could not reconnect to the paired iPhone for the final microphone smoke test, so physical speech acceptance remains open |
| 2026-07-16 | Audio tap concurrency crash fix | Automated pass; device retest pending | Physical-device debugging isolated `_dispatch_assert_queue_fail` on the real-time audio queue. The microphone tap is now explicitly sendable so it can run safely outside the main thread; the simulator build and all 3 app-model tests pass, while a repeat physical hold/release test remains open because the paired iPhone is unavailable |
| 2026-07-16 | Escape and Shift+Tab keypad route | Automated pass | Rust formatting, Clippy, and all 7 tests passed, including `shift_tab` forwarding as Herdr `shift+tab`; all 16 Swift package tests and all 3 iPhone 17e simulator app tests passed under Xcode 26.6 with iOS 26.5 |
| 2026-07-16 | Agent-aware Accept and Deny route | Automated pass; physical-agent checks pending | Rust tests cover all five mappings plus rejection for working and unsupported agents; 17 Swift package tests and all 4 iPhone 17e simulator app tests pass. Real prompt behavior remains for manual verification on the user's phone. |
| 2026-07-16 | Multi-session protocol v2 | Pass | Rust formatting, Clippy, and all 9 tests passed; two fake Herdr sockets with the same `w1:p1` agent ID routed independently and protocol v1 was rejected. |
| 2026-07-16 | Swift and iOS session state | Pass | All 17 Swift package tests and all 5 iPhone 17 Pro Max simulator app tests passed; coverage includes tagged events, required session fields, remembered selection, fallback, and keypad gating. |
| 2026-07-16 | Live named-session discovery | Pass | A disposable `remote-keypad-test` session appeared beside `default`, returned its own tagged empty agent snapshot, and was then stopped and deleted; live Swift-to-Rust ping/snapshot passed without agent input. |
| 2026-07-16 | Voice Send/Cancel/Edit automation | Pass | Xcode 26.6 built the app and all 10 iPhone 17e simulator tests passed. New coverage checks displayed target centers and edges, release outside targets, moving into and out of targets, newline normalization, blank/control-character rejection, exact emoji byte limits, and original-target gating. |
| 2026-07-16 | Talking and editor simulator review | Partial; manual states pending | The updated app launched on iPhone 17e, connected through the local bridge, displayed three live agents, and exposed named Voice, Edit dictation, and Cancel dictation accessibility behavior in code. Simulator microphone startup returned an audio-setup failure, so talking-overlay alignment, long transcript scrolling, Reduce Motion, keyboard layout, and failed-send retention still need interactive simulator review. |
| 2026-07-16 | Voice gesture physical-iPhone acceptance | Pending | `devicectl` found no connected iPhone. Normal Send, Cancel sending nothing, Edit finalization, haptics, drag reach, blur/glow performance, connection loss, keyboard layout, and VoiceOver actions remain device acceptance work. |
| 2026-07-16 | AgentSlate 0.1.0 integrated release gates | Automated pass; physical device and publication pending | `cargo fmt`, strict locked Clippy, 12 Rust tests, locked release build, 21 Swift package tests, 11 iOS simulator tests, Xcode static analysis, unsigned archive, signed App Store Connect IPA export, manifest/notices/icon inspection, clean source install, live Tailscale/Herdr doctor, and simulator onboarding/demo/settings/acknowledgements review passed. The unavailable paired iPhone prevents the physical acceptance pass. |
