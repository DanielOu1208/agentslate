---
layout: default
title: AgentSlate
permalink: /
---

# AgentSlate

<img src="{{ "/assets/agentslate-icon.png" | relative_url }}" alt="AgentSlate app icon" width="128">

**Remote control for Herdr.**

AgentSlate is an open-source iPhone companion for supervising coding agents running in Herdr on your Mac. It connects directly over your private Tailscale network; there is no AgentSlate cloud service or account.

[Join the TestFlight beta](https://testflight.apple.com/join/T1bCGkH6) · [View the source](https://github.com/DanielOu1208/agentslate) · [Get support]({{ "/support/" | relative_url }}) · [Read the privacy policy]({{ "/privacy/" | relative_url }})

## Quick start

Live control requires Herdr 0.8.0 or newer. Run `herdr update --handoff` from a terminal outside Herdr when upgrading an older installation with running sessions.

```sh
brew install DanielOu1208/agentslate/agentslate
agentslate doctor
brew services start agentslate
agentslate pair
```

Enter the Mac's Tailscale address and the six-digit pairing code in the iPhone app. Pairing codes expire after ten minutes and work once.

AgentSlate is beta software. Keep the target terminal visible and review every permission prompt before accepting it.

## What's new in 0.2.0

AgentSlate 0.2.0 adds three explicit dictation choices: Apple On-Device, OpenRouter-routed Whisper, and Soniox v5 Real-Time. Cloud modes use API keys that you supply, support optional transcript cleanup, and fall back to Apple's speech framework when transcription fails.

[Read the AgentSlate 0.2.0 release notes](https://github.com/DanielOu1208/agentslate/blob/main/RELEASE_NOTES_0.2.0.md)

## Independent project

AgentSlate is not affiliated with, endorsed by, or sponsored by Herdr, Tailscale, Apple, or any coding-agent vendor. Product names and marks belong to their respective owners.

This project is unrelated to the existing [pathupally/AgentSlate repository](https://github.com/pathupally/AgentSlate) and Random Labs' [Slate coding agent](https://www.ycombinator.com/companies/random-labs).
