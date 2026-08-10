# AgentSlate 0.2.0

AgentSlate 0.2.0 expands voice input into a choice of private on-device dictation or user-funded cloud transcription, while improving terminal controls, compatibility, recovery, and security.

[Join the public TestFlight beta](https://testflight.apple.com/join/T1bCGkH6). Install or upgrade the Mac bridge with `brew install DanielOu1208/agentslate/agentslate`.

> **TestFlight status:** Build `0.2.0 (5)` is approved and available to external testers through the public beta link.

Automated and local-bridge validation passed, and the owner reported a successful physical dictation smoke test after the protected Whisper recording fix. The full physical fallback/provider matrix and locked-device file-protection check remain post-release beta validation items.

## Dictation pipelines

- **Apple On-Device** remains the default. Audio stays on the iPhone and only text you choose to send reaches the paired Mac.
- **OpenRouter Whisper** records speech locally and sends it through OpenRouter to `openai/whisper-large-v3-turbo`. The API key is supplied by you and stored in the iOS Keychain.
- **Soniox v5 Real-Time** streams opted-in audio directly to Soniox and shows provisional text while you speak. Its separate API key is also supplied by you and stored in the Keychain.
- **Optional transcript cleanup** sends cloud transcripts through OpenRouter to Gemini 3.1 Flash Lite under a rewrite-only instruction. Explicit Apple mode never uses cloud cleanup.

Cloud transcription failures fall back to Apple's on-device file transcription. Cleanup failures preserve the raw transcript. If Soniox finalization and Apple fallback both fail after live text appeared, AgentSlate preserves the exact partial transcript in the editor and requires review before it can be sent.

## Voice experience and safety

- The talking view now includes a live speech waveform and a compact label for the provider handling the current stage.
- Capture preparation and microphone startup were moved away from the main interface path to reduce touch-down delay and missed first words.
- Every voice-originated prompt carries a short marker that helps the selected coding agent resolve obvious phonetic project-name errors without sharing repository context with a cleanup provider.
- Temporary cloud recordings use complete iOS file protection, are removed after completion or cancellation, and are narrowly purged if an earlier session left an AgentSlate-owned orphan.
- Provider responses, WebSocket frames, accumulated transcript text, audio duration, and final prompt size are bounded and rejected rather than silently truncated.
- Cancellation now stops active dictation before waiting for background work to finish.

## Other fixes

- Requires Herdr 0.8.0 / protocol 19 and reports actionable compatibility errors for older Herdr versions.
- Shift+Tab now uses portable literal terminal input for Codex, OpenCode, and other non-OMP agents, with the enhanced keyboard sequence retained for OMP.
- Herdr errors remain scoped to the affected session and preserve their wire ordering.
- Failed delivery keeps useful dictated text visible instead of clearing it prematurely.

## Requirements

- iPhone running iOS 26 or newer
- Mac and iPhone connected through the same private Tailscale network
- Herdr 0.8.0 or newer for live control
- Your own OpenRouter or Soniox API key for the corresponding optional cloud engine

When upgrading Herdr with running sessions, run `herdr update --handoff` from a terminal outside Herdr.

**Changes since 0.1.0:** https://github.com/DanielOu1208/agentslate/compare/v0.1.0...v0.2.0
