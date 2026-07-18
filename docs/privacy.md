---
layout: default
title: AgentSlate Privacy Policy
permalink: /privacy/
---

# AgentSlate Privacy Policy

Effective: July 18, 2026

The AgentSlate developer does not operate an account system, cloud backend, advertising service, analytics service, or tracking service. Optional cloud dictation sends data through OpenRouter using an API key that you supply.

## How the app works

AgentSlate connects directly from your iPhone to a Mac you pair over your private Tailscale network. There is no AgentSlate account, cloud backend, advertising, analytics, tracking, or developer-operated server.

The app stores:

- the paired Mac address and app preferences on your iPhone;
- the device ID and device credential in the iOS Keychain; and
- an optional OpenRouter API key in the iOS Keychain; and
- optional voice drafts in memory only while you review them.

The paired Mac stores the device name reported by iOS, a random device ID, the pairing time, and only a SHA-256 digest of the device credential in owner-only local files. A device name can include a person's name if that is how the iPhone is named. This record is used only to authenticate and identify paired phones; it is not sent to the AgentSlate developer.

Apple Dictation is the default and uses Apple's on-device speech frameworks. In this mode, microphone audio stays on the iPhone.

Cloud Dictation is optional and disabled until you save an OpenRouter API key and explicitly enable it. In this mode:

- the app records a temporary audio file and sends it through OpenRouter to Groq-hosted Whisper for transcription;
- the raw transcript, but not the audio, is sent through OpenRouter to the selected cleanup model;
- the app requests zero-data-retention routing for both requests, but provider handling is also governed by your OpenRouter account and the current terms of the routed providers;
- if cloud transcription fails, the app retries locally with Apple's speech framework;
- if cleanup fails, the raw transcript is used; and
- the temporary recording is deleted after processing or cancellation.

Microphone audio is never sent to the AgentSlate bridge. Only text you choose to send is delivered to the selected Herdr agent on your paired Mac.

Demo Mode uses fixed sample data and never contacts a real bridge.

## Data shared by you

If you voluntarily submit a GitHub issue, security advisory, or TestFlight report, GitHub or Apple processes the information you provide under its own privacy terms. Do not include pairing codes, device credentials, private prompts, or sensitive logs.

## Removing local data

Use **Remove API Key** in Dictation settings to delete the saved OpenRouter key. Use **Forget Bridge** to remove the saved Mac and iPhone credential. When connected, AgentSlate also revokes that device on the Mac. If the Mac is offline, revoke its remaining record later with:

```sh
agentslate devices revoke DEVICE_ID
```

## Changes and contact

Material changes will be posted to this page with a new effective date. For privacy questions, use [AgentSlate support]({{ "/support/" | relative_url }}). Report security problems privately through [GitHub Security Advisories](https://github.com/DanielOu1208/agentslate/security/advisories/new).
