---
layout: default
title: AgentSlate Support
permalink: /support/
---

# AgentSlate Support

AgentSlate is beta software. Public support is available through [GitHub Issues](https://github.com/DanielOu1208/agentslate/issues).

## First checks

On the Mac:

```sh
agentslate doctor
brew services info agentslate
agentslate devices list
```

Confirm that:

- Herdr is running;
- the Mac and iPhone are connected to the same Tailscale network;
- the AgentSlate Homebrew service is running; and
- the iPhone has not been revoked.

For a new phone, run `agentslate pair` and enter the new six-digit code within ten minutes. A pairing code works once and locks after five failed attempts.

## Forget or revoke a phone

Use **Forget Bridge** in the iPhone app. If the phone is unavailable, revoke it from the Mac:

```sh
agentslate devices revoke DEVICE_ID
```

## File a useful issue

Include the AgentSlate version/build, iOS and macOS versions, Herdr version, what you expected, and what happened. Say whether the problem occurs in Demo Mode or with a real bridge.

Never post a pairing code, device credential, private prompt, full personal path, or unredacted log. Report suspected vulnerabilities privately through [GitHub Security Advisories](https://github.com/DanielOu1208/agentslate/security/advisories/new).

[Privacy policy]({{ "/privacy/" | relative_url }}) · [Project source](https://github.com/DanielOu1208/agentslate)
