---
layout: default
title: AgentSlate Privacy Policy
permalink: /privacy/
---

# AgentSlate Privacy Policy

Effective: August 10, 2026

The AgentSlate developer does not operate an account system, cloud backend, advertising service, analytics service, or tracking service. Optional cloud dictation sends audio and your saved vocabulary terms to the selected cloud speech-to-text provider: through OpenRouter to its routed Whisper provider, or directly to Soniox, using API keys that you supply. When transcript cleanup is enabled, the raw transcript and saved vocabulary terms are also sent to Google through OpenRouter.

## How the app works

AgentSlate connects directly from your iPhone to a Mac you pair over your private Tailscale network. There is no AgentSlate account, cloud backend, advertising, analytics, tracking, or developer-operated server.

The app stores:

- the paired Mac address and app preferences on your iPhone;
- the device ID and device credential in the iOS Keychain; and
- optional OpenRouter and Soniox API keys in the iOS Keychain; and
- one optional global vocabulary list stored locally on the iPhone; and
- optional voice drafts in memory only while you review them.

The paired Mac stores the device name reported by iOS, a random device ID, the pairing time, and only a SHA-256 digest of the device credential in owner-only local files. A device name can include a person's name if that is how the iPhone is named. This record is used only to authenticate and identify paired phones; it is not sent to the AgentSlate developer.

Apple Dictation is the default and uses Apple's on-device speech frameworks. In this mode, microphone audio and vocabulary terms stay on the iPhone.

Cloud dictation is optional. You choose Apple On-Device, OpenRouter Whisper, or Soniox v5 Real-Time in settings; each cloud engine remains unavailable until you save its API key and consent to sending audio and your saved vocabulary terms to the selected cloud speech-to-text provider. In cloud modes:

- OpenRouter mode records a temporary audio file and sends it with saved vocabulary terms through OpenRouter to the Groq-hosted `openai/whisper-large-v3-turbo` model after you release the microphone;
- Soniox mode streams live audio and saved vocabulary terms directly to Soniox and displays provisional and final text while you speak;
- Soniox says its real-time service does not retain audio or transcripts, but processing is also governed by your Soniox account and its current terms;
- when **Clean up transcripts** is enabled, the raw cloud transcript and saved vocabulary terms are sent through OpenRouter to the selected Google cleanup model; the app requests zero-data-retention routing for that request;
- if either cloud engine fails, the app retries locally with Apple's speech framework;
- if both Soniox finalization and Apple fallback fail after live text arrived, the app requires you to review that text before it can be sent;
- if cleanup fails or is disabled, the raw transcript is used; and
- local fallback recordings use iOS complete file protection, are deleted after processing or cancellation, and narrowly named orphaned recordings are removed before the next dictation session.

Provider responses and transcripts are bounded locally: HTTP response bodies are limited to 1 MiB, individual Soniox response frames and accumulated provider transcript text to 64 KiB, and cloud audio to two minutes. The final text sent to the paired Mac remains limited to 8,192 UTF-8 bytes.

When Apple On-Device is selected directly, cleanup is unavailable and audio, transcript text, and vocabulary terms are not sent to OpenRouter, Soniox, or Google.

Vocabulary entries are words or short phrases you add manually one at a time. AgentSlate keeps one global list on the iPhone and does not sync it, upload it to an AgentSlate backend, or import terms from another source. Providers use vocabulary as probabilistic recognition or spelling hints; the terms are not deterministic replacement rules.

Microphone audio is never sent to the AgentSlate bridge. Only text you choose to send is delivered to the selected Herdr agent on your paired Mac.

Demo Mode uses fixed sample data and never contacts a real bridge.

## Data shared by you

If you voluntarily submit a GitHub issue, security advisory, or TestFlight report, GitHub or Apple processes the information you provide under its own privacy terms. Do not include pairing codes, device credentials, private prompts, or sensitive logs.

## Removing local data

Use **Remove OpenRouter Key** or **Remove Soniox Key** in Dictation settings to delete the corresponding saved key. Use **Forget Bridge** to remove the saved Mac and iPhone credential. When connected, AgentSlate also revokes that device on the Mac. If the Mac is offline, revoke its remaining record later with:

```sh
agentslate devices revoke DEVICE_ID
```

## Changes and contact

Material changes will be posted to this page with a new effective date. For privacy questions, use [AgentSlate support]({{ "/support/" | relative_url }}). Report security problems privately through [GitHub Security Advisories](https://github.com/DanielOu1208/agentslate/security/advisories/new).
