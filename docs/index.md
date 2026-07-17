---
layout: default
title: AgentSlate
permalink: /
---

# AgentSlate

<img src="{{ "/assets/agentslate-icon.png" | relative_url }}" alt="AgentSlate app icon" width="128">

**Remote control for Herdr.**

AgentSlate is an open-source iPhone companion for supervising coding agents running in Herdr on your Mac. It connects directly over your private Tailscale network; there is no AgentSlate cloud service or account.

[View the source](https://github.com/DanielOu1208/agentslate) · [Get support]({{ "/support/" | relative_url }}) · [Read the privacy policy]({{ "/privacy/" | relative_url }})

## Quick start

```sh
brew install DanielOu1208/agentslate/agentslate
agentslate doctor
brew services start agentslate
agentslate pair
```

Enter the Mac's Tailscale address and the six-digit pairing code in the iPhone app. Pairing codes expire after ten minutes and work once.

AgentSlate is beta software. Keep the target terminal visible and review every permission prompt before accepting it.

## Independent project

AgentSlate is not affiliated with, endorsed by, or sponsored by Herdr, Tailscale, Apple, or any coding-agent vendor. Product names and marks belong to their respective owners.

This project is unrelated to the existing [pathupally/AgentSlate repository](https://github.com/pathupally/AgentSlate) and Random Labs' [Slate coding agent](https://www.ycombinator.com/companies/random-labs).
