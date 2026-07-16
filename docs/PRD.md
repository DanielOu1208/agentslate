# Herdr Remote Keypad Product Requirements

Status: Active draft  
Product: Herdr Remote Keypad  
Primary client: Native SwiftUI iPhone application  
Desktop dependency: Herdr runtime plus the connector in this repository

## Executive summary

Herdr Remote Keypad is a focused iPhone companion for developers controlling terminal-based coding agents in Herdr while watching the laptop or another display. It shows which agents are working or need attention, lets the user select one, and sends the small set of keys or text needed to answer prompts without using a full remote-desktop or terminal client.

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
- list live Herdr agents and semantic states;
- focus a current agent's Herdr pane;
- send arrows, Enter, Escape, Tab, Shift+Tab, Space, and printable text to a current agent;
- acknowledge successful Herdr input;
- report Herdr availability and recover after interruption.

The supplied Rust command-line probe verifies this slice.

### Swift client foundation

The reusable Swift package must:

- model protocol v1 without depending on SwiftUI;
- authenticate and exchange newline-delimited JSON using `Network.framework`;
- publish connection, Herdr availability, and agent snapshot events;
- focus a current agent and wait for bridge acknowledgement;
- send allowlisted keys and validated text;
- reconnect after transport failure but stop after authentication failure.

### Usable iPhone vertical slice

The first phone build adds:

- a four-column SwiftUI agent-key grid with clear selected-agent identity;
- a connected D-pad, Enter, Tab, Escape, Shift+Tab, and haptics;
- active-looking Accept and Deny placeholders that provide local press feedback without sending remote input;
- hold-to-talk Voice that converts speech on-device and sends text plus Enter to the selected agent;
- connection state, automatic reconnect, and disabled controls when unavailable;
- manual bridge address and token entry with Keychain storage.

### Complete MVP

The complete MVP additionally includes typed instructions and hold-to-talk local speech recognition. It is complete when an iPhone can select among at least three agents, operate approvals and pickers, send typed and spoken instructions, reconnect, and reject unauthenticated input.

## Functional requirements

### Agent dashboard

- Show every Herdr-reported agent with name, workspace, state, optional task title, and selected state.
- Distinguish working, blocked, done, idle, and unknown states.
- Focus the tapped agent's existing Herdr pane and select it only after acknowledgement.
- Keep selection when its agent ID remains in the latest snapshot; clear it when the agent disappears.
- Prioritize blocked agents visually in the SwiftUI client.

### Input

- Keep arrows, Enter, Escape, Tab, and Shift+Tab on the primary phone control bank for every current agent.
- Continue supporting Space in protocol v1 even though the phone layout does not expose a dedicated key for it.
- Support printable Unicode text with and without a final Enter.
- Include the selected agent ID in every input request.
- Acknowledge input only after Herdr accepts it.
- Reject control characters, unknown keys, oversized input, and panes that are not current Herdr agents.
- Disable controls while the bridge is disconnected or Herdr is unavailable.

### Voice and speech

- Use Apple's on-device SpeechAnalyzer and DictationTranscriber (iOS 26+) for hold-to-talk dictation.
- Default to hold, speak, release, then send text plus Enter through the existing bridge `send_text` path.
- Prepare speech after saved bridge setup is available so the first press does not perform model setup.
- Request microphone access with the native asynchronous audio API; do not request the legacy speech-recognition permission.
- Cancel capture when the gesture is interrupted or the app leaves the foreground, and never send partial text after a recognition or finalization failure.
- With VoiceOver, use one activation to start, a second to send, and a separate Cancel dictation action.
- Keep audio on the phone; never stream microphone audio through the Herdr bridge.
- Provide review-before-send as a safer later option.
- Keep text-to-speech out of the initial keypad release because the external screen remains the source of context.

### Connection and security

- Use Tailscale for private encrypted transport; do not expose the bridge on public or general LAN interfaces by default.
- Require application authentication before returning agent state or accepting input.
- Do not log tokens or user input text.
- Store the development token in an owner-only file; replace it with one-time pairing and per-device Keychain credentials before wider beta.
- Keep the bridge protocol narrower than the Herdr API so the phone cannot invoke arbitrary Herdr or shell commands.

## Out of scope for the first iPhone slice

- terminal output, terminal emulation, or a remote-desktop view
- QR pairing, per-device revocation, APNs, TestFlight, and Apple Watch
- multiple Herdr machines or public-internet exposure
- Herdr plugin packaging or launchd service management
- direct Codex or Claude Code approval integration before the bridge exposes structured request type and choice data
- arbitrary control-key chords such as Control+C

## Dependencies and risks

- Herdr's local protocol is versioned independently from bridge protocol v1. The connector must tolerate unknown fields and surface incompatible required behavior clearly.
- iOS cannot maintain a permanent socket while suspended; reliable closed-app notifications would require a later APNs design.
- A wrong agent selection can send valid input to the wrong pane. The phone must show the selected agent clearly and the bridge must revalidate membership before every input.
- The shared development token is acceptable for one owner on Tailscale but must be replaced before wider distribution.

## Decisions

- Rust provides the durable desktop connector.
- Newline-delimited JSON remains the bridge wire format for easy Swift decoding and debugging.
- The development credential is a generated shared token; QR pairing and revocation are later work.
- Terminal streaming was removed before the first phone client because the user will watch the agent on another display.
- The selected keypad target remains client state, while each agent tap focuses the matching Herdr pane before changing that selection.
- Protocol v1 was revised in place because no released client depended on its earlier terminal-streaming draft.
- The shared Swift package targets iOS 18 and newer.
- The iPhone app targets iOS 26 and newer so it can use SpeechAnalyzer for on-device dictation.
- Dedicated Accept and Deny keys remain local-only placeholders until their integrations have enough structured data to send safe remote input.
- The Voice key uses on-device hold-to-talk dictation and sends finalized text through the bridge.
