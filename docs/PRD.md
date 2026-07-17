# AgentSlate Product Requirements

Status: Active draft  
Product: AgentSlate
Primary client: Native SwiftUI iPhone application  
Desktop dependency: Herdr runtime plus the connector in this repository

## Executive summary

AgentSlate is a focused iPhone companion for developers controlling terminal-based coding agents in Herdr while watching the laptop or another display. It shows which agents are working or need attention, lets the user select one, and sends the small set of keys or text needed to answer prompts without using a full remote-desktop or terminal client.

The phone intentionally does not reproduce terminal output. The visible external screen provides context; the phone provides a convenient remote keyboard and agent switcher.

## Problem and user

The primary user runs one or more coding agents through Herdr and wants to respond from a nearby phone while the agents remain visible on another screen. Reaching for the desktop keyboard or using a full remote-control client is unnecessarily heavy for choosing an option, pressing Enter, or sending a short instruction.

Initial validation is for the product owner using a Mac running Herdr, an iPhone, and Tailscale. Broader personas and market sizing remain discovery work and are not required to validate the interaction loop.

## Product outcome

The product succeeds when the user can select the correct visible agent and complete routine prompts from the phone. The primary validation measure is the percentage of intended keypad interactions completed successfully. Supporting measures are input acknowledgement latency, reconnection success, voice-send success, and the number of agents available for selection.

## Release slices

### Connector vertical slice

The desktop half of the system must:

- authenticate a client over the private Tailscale network;
- discover running named Herdr sessions on the bridge Mac;
- list live Herdr agents and semantic states;
- focus a current agent's Herdr pane;
- send arrows, Enter, Escape, Tab, Shift+Tab, Space, and printable text to a current agent;
- acknowledge successful Herdr input;
- report Herdr availability and recover after interruption.

The supplied Rust command-line probe verifies this slice.

### Swift client foundation

The reusable `AgentSlateClient` Swift package must:

- model protocol v3 without depending on SwiftUI;
- authenticate and exchange newline-delimited JSON using `Network.framework`;
- publish connection, session-list, per-session availability, and agent snapshot events;
- focus a current agent and wait for bridge acknowledgement;
- send allowlisted keys and validated text;
- reconnect after transport failure but stop after authentication failure.

### Usable iPhone vertical slice

The first phone build adds:

- a four-column SwiftUI agent-key grid with clear selected-agent identity;
- a native header menu for choosing among running Herdr sessions;
- a connected D-pad, Enter, Tab, Escape, Shift+Tab, and haptics;
- watched-screen Accept and Deny shortcuts for blocked Codex, Claude Code, OMP, Cursor, and OpenCode agents;
- hold-to-talk Voice with normal send, visible drag-to-Cancel and drag-to-Edit outcomes, plus a native review editor;
- connection state, automatic reconnect, and disabled controls when unavailable;
- onboarding for the bridge address and a six-digit pairing code, with the resulting per-device credential stored in Keychain;
- Setup, Support, Privacy, Acknowledgements, version/build, Demo Mode, and Forget Bridge screens.

### Open beta

The open beta additionally includes editable spoken instructions, hold-to-talk local speech recognition, secure device pairing and revocation, Homebrew service packaging, support/privacy pages, and an external TestFlight build. It is complete when an iPhone can select among at least three agents, operate approvals and pickers, review and send spoken instructions, reconnect, and reject unauthenticated or revoked devices.

## Functional requirements

### Agent dashboard

- Show running Herdr sessions with the default first and other names alphabetically.
- Restore the last selected session when it remains available; otherwise select the default or first running session.
- Keep session switching phone-local, clear the selected agent, and never attach or foreground a Mac window.
- Show every Herdr-reported agent with name, workspace, state, optional task title, and selected state.
- Distinguish Thinking (`working` on the wire), blocked, done, idle, and unknown states.
- Focus the tapped agent's existing Herdr pane and select it only after acknowledgement.
- Keep selection when its agent ID remains in the latest snapshot; clear it when the agent disappears.
- Prioritize blocked agents visually in the SwiftUI client.

### Input

- Keep arrows, Enter, Escape, Tab, and Shift+Tab on the primary phone control bank for every current agent.
- Continue supporting Space in protocol v3 even though the phone layout does not expose a dedicated key for it.
- Support printable Unicode text with and without a final Enter.
- Include the selected session name and agent ID in every input request.
- Enable Accept and Deny only for a selected blocked agent whose kind has a fixed mapping, and revalidate both conditions against a fresh snapshot before forwarding it.
- Map Codex and Cursor to `y`/`n`, Claude Code and OMP to Enter/Escape, and OpenCode to Enter/Escape-then-Enter.
- Acknowledge input only after Herdr accepts it.
- Reject control characters, unknown keys, oversized input, and panes that are not current Herdr agents.
- Disable controls while the bridge is disconnected or Herdr is unavailable.

### Voice and speech

- Use Apple's on-device SpeechAnalyzer and DictationTranscriber (iOS 26+) for hold-to-talk dictation.
- Default to hold, speak, and release to send text plus Enter through the existing bridge `send_text` path.
- While holding, show only two visible alternate release targets: upper-left Cancel discards and upper-right Edit finalizes into an in-memory review sheet. Leaving either target restores Send.
- Keep the microphone sharp and interactive while the blocked keypad is blurred and dimmed; show live, auto-scrolling transcript text and an outcome-colored border that respects Reduce Motion.
- Let the review sheet edit multi-line text, convert line breaks to spaces, reject blank/control-character/over-8,192-byte input, and retain failed or disconnected drafts for retry.
- Bind an Edit draft to the agent and session captured when recording began; send only while that exact target remains selected and available.
- Prepare speech after saved bridge setup is available so the first press does not perform model setup.
- Request microphone access with the native asynchronous audio API; do not request the legacy speech-recognition permission.
- Cancel capture when the gesture is interrupted or the app leaves the foreground, and never send partial text after a recognition or finalization failure.
- With VoiceOver, use one activation to start, a second to send, and named Edit dictation and Cancel dictation actions while keeping the same talking presentation.
- Keep audio on the phone; never stream microphone audio through the Herdr bridge.
- Keep text-to-speech out of the initial keypad release because the external screen remains the source of context.

### Connection and security

- Use Tailscale for private encrypted transport; do not expose the bridge on public or general LAN interfaces by default.
- Require application authentication before returning agent state or accepting input.
- Do not log pairing codes, device credentials, or user input text.
- Create six-digit, single-use pairing codes that expire after ten minutes and lock after five failed attempts.
- On successful pairing, create a random 32-byte credential and server-generated device ID.
- Store only the credential's SHA-256 digest in an owner-only Mac device file; store the device ID and credential in the iPhone Keychain.
- Recheck device authorization before every command and state poll so revocation stops an existing connection before its next command or 200-millisecond poll.
- Let a connected phone revoke itself before Forget Bridge clears local credentials. If offline, clear the phone and tell the user how to revoke the remaining Mac record.
- Keep the bridge protocol narrower than the Herdr API so the phone cannot invoke arbitrary Herdr or shell commands.
- Restrict bridge listeners to loopback and Tailscale address ranges without an insecure override.

### Demo Mode

- Use fixed fake sessions, agents, states, and command acknowledgements.
- Clearly label Demo Mode throughout the app.
- Never open a bridge connection or send input to a real Herdr session while Demo Mode is active.

## Out of scope for the first iPhone slice

- terminal output, terminal emulation, or a remote-desktop view
- QR pairing, APNs, and Apple Watch
- multiple Herdr machines or public-internet exposure
- Herdr plugin packaging or launchd service management
- structured, request-identified agent approval integrations
- arbitrary control-key chords such as Control+C

## Dependencies and risks

- Herdr's local protocol is versioned independently from bridge protocol v3. The connector must tolerate unknown fields and surface incompatible required behavior clearly.
- iOS cannot maintain a permanent socket while suspended; reliable closed-app notifications would require a later APNs design.
- A wrong agent selection can send valid input to the wrong pane. The phone must show the selected agent clearly and the bridge must revalidate membership before every input.
- Six-digit pairing codes are deliberately short-lived and attempt-limited; the generated 256-bit per-device credential provides ongoing authentication.

## Decisions

- Rust provides the durable desktop connector.
- Newline-delimited JSON remains the bridge wire format for easy Swift decoding and debugging.
- Protocol v3 uses short-lived pairing codes and separate revocable device credentials; QR pairing remains unnecessary for the first beta.
- Terminal streaming was removed before the first phone client because the user will watch the agent on another display.
- The selected keypad target remains client state, while each agent tap focuses the matching Herdr pane before changing that selection.
- Protocol v1 was revised in place because no released client depended on its earlier terminal-streaming draft.
- Protocol v3 requires a session name on every targeted request and per-device authentication; protocol v1 and v2 clients must update with the bridge.
- Session selection stays on the phone and does not switch or foreground a Mac window.
- The shared Swift package targets iOS 18 and newer.
- The iPhone app targets iOS 26 and newer so it can use SpeechAnalyzer for on-device dictation.
- Dedicated Accept and Deny keys are watched-screen default-keymap conveniences for five supported agent kinds; they are not structured authorization and remain disabled unless the selected agent is blocked.
- The Voice key uses on-device hold-to-talk dictation with Send, Cancel, and editable review outcomes; finalized sends reuse the existing bridge text route.
- Demo Mode is an offline review path with fixed sample data, not a simulated connection to the real bridge.
- Version 0.1.0 stops at external TestFlight. Production App Store metadata may be prepared, but production review and release require separate explicit approval.
