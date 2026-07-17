# Security Policy

## Supported versions

AgentSlate is beta software. Security fixes are applied to the latest code and latest published release only.

## Report a vulnerability

Please use a private [GitHub Security Advisory](https://github.com/DanielOu1208/agentslate/security/advisories/new). Do not open a public issue for a suspected vulnerability.

Include:

- the affected version or commit;
- clear reproduction steps;
- the expected and actual behavior;
- the security impact; and
- any suggested fix, if available.

Do not include real pairing codes, device credentials, terminal input, or other people's data. You may use a disposable Herdr session and redacted logs.

The maintainer will acknowledge the report through GitHub, investigate it, and coordinate disclosure after a fix is available. Please do not publicly disclose an unresolved issue.

## Security boundaries

AgentSlate is intended for loopback and Tailscale addresses only. It is not a public-network service. Pairing codes are short-lived and single-use; paired devices receive separate credentials that can be revoked. The bridge rechecks device authorization and current Herdr agent membership before commands.

Watched-screen Accept and Deny buttons are convenience key mappings, not verified authorization. Keep the target terminal visible and confirm the prompt before using them.
