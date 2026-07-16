# Coding Agent Key and Permission Research

Date: 2026-07-16
Status: Research complete; watched-screen shortcut MVP implemented

## Summary

Herdr Remote Keypad exposes the universal terminal controls used by coding agents: arrow keys, Enter, Tab, **Escape**, and **Shift+Tab** for cycling Plan, Manual, and automatic approval modes.

The Accept and Deny buttons now provide a deliberately narrow watched-screen shortcut for five mainstream agents. They enable only for a selected supported agent that Herdr reports as blocked, and the bridge checks a fresh snapshot before sending. This reduces stale-state mistakes but does not identify the permission request or prove what the prompt currently means.

| Agent kind | Accept | Deny |
|---|---|---|
| Codex | `y` | `n` |
| Claude Code | `enter` | `escape` |
| OMP | `enter` | `escape` |
| Cursor | `y` | `n` |
| OpenCode | `enter` | `escape`, then `enter` in one Herdr request |

These are default-keymap conveniences for use while the terminal is visible. Custom keymaps or changed agent prompts can make a mapping incorrect. A future trustworthy unattended permission design still requires a structured request-and-response path with request IDs and explicit native decisions.

There is no credible public cross-agent keypress-frequency dataset. The rankings below are based on overlap in current official documentation and the frequency with which the controls appear in routine prompting, selection, interruption, and approval flows.

## Recommended keypad controls

| Priority | Control | Recommendation | Reason |
|---|---|---|---|
| 1 | Escape | Implemented as a dedicated button | Cancels dialogs, rejects or closes selections, and interrupts turns across many agents. |
| 2 | Shift+Tab | Implemented as a dedicated button | Cycles the modes supported by Claude Code, Gemini, Copilot, Droid, and Kimi; the exact cycle differs by agent. |
| 3 | Space | Keep available, but do not prioritize a permanent button | Useful for checkbox and multi-select interfaces. The bridge already supports it, while arrows and Enter cover most current dialogs. |
| 4 | Ctrl+O | Consider in a secondary command sheet | Commonly expands tool output or opens detailed transcripts in Claude Code, Gemini, Kimi, and Amp. |
| 5 | Number keys 1-4 | Offer as a temporary number pad | Kimi and Gemini use number shortcuts in approval or question dialogs; Kilo exposes numbered persistent approval choices. |

Do not add a dedicated Ctrl+C button. Escape covers most useful interruption behavior and is less dangerous if the agent has unexpectedly returned to a shell.

## Recommended command macros

Slash commands are useful, but their names and behavior differ by agent. They should appear in an agent-aware command sheet selected from the current agent's `kind`, not as universal fixed buttons.

1. Plan or mode switch: `/plan` or Shift+Tab
2. Permissions: `/permissions`, `/permission`, or the agent's settings picker
3. Model selection: `/model` or `/models`
4. Context cleanup: `/compact`
5. New session: `/new`
6. Change review: `/review` or `/diff`

Sending an unsupported slash command may turn it into an ordinary prompt. Each macro therefore needs an explicit per-agent mapping.

## Supported agent findings

Herdr's current documentation lists 18 primary agents, calls Gemini CLI and Cline less thoroughly tested, and its current release notes add Maki. The iPhone app contains icons for all 21 kinds below.

| Agent | Interaction and permission behavior | Remote approval fit |
|---|---|---|
| Pi | Core Pi primarily gates project trust. Fine-grained per-tool approval is provided by optional extensions rather than a universal built-in prompt. | Do not assume Accept or Deny semantics without detecting the installed extension. |
| OMP | Supports interactive and ACP-style modes. Destructive actions can pause for approval. | Watched-screen Enter/Escape shortcuts are implemented; verify ACP later if structured approval is needed. |
| GitHub Copilot CLI | Shift+Tab cycles modes. Its own remote-session feature can surface questions and tool approvals on GitHub mobile. | Prefer a structured or native remote path over terminal scraping. |
| Devin CLI | Herdr can detect and restore sessions, but current public documentation does not establish a stable permission keystroke. | Keep dedicated approval disabled until the installed CLI is tested. |
| Kimi Code CLI | Approval panels use arrows plus Enter, number keys 1-3, and Escape/Ctrl+C/Ctrl+D to reject. Shift+Tab toggles Plan mode, and the CLI exposes ACP. | Strong structured candidate after its ACP choices are verified. |
| Hermes Agent | Protects dangerous shell commands and supports smart, manual, and off approval modes. Its Herdr plugin reports approval state. | Approval state alone is insufficient; request details still need a structured path. |
| Qoder CLI | Uses allow, ask, and deny policies with default, accept-edits, plan, auto, and non-prompting modes. | Menu navigation works, but structured request support must be verified. |
| Droid | Uses risk-based autonomy levels, and Shift+Tab toggles its specification-planning mode. Its SDK emits `droid.request_permission` and accepts a structured response. | Excellent first-class integration target. |
| OpenCode | Permission prompts offer once, always for matching requests, or reject. Most permissions are permissive by default unless configured otherwise. | Watched-screen Enter and Escape-then-Enter shortcuts are implemented; its server/client interface remains preferable for structured choices. |
| Kilo Code CLI | Similar allow/ask/deny model to OpenCode. Command approvals expose `y`, `n`, and numbered persistent choices. | Documented keys aid manual use, but remote approval still needs request identity. |
| MastraCode | Exposes `/permissions`, `/yolo`, `/review`, and `/diff`; its AgentController is designed for explicit permission handling. | Integrate through its controller when the API is stable enough for this app. |
| Claude Code | Permission dialogs use arrows to navigate tabs and options; Escape closes a dialog. Shift+Tab cycles permission modes. | Watched-screen Enter/Escape shortcuts are implemented; the TUI still provides no Herdr-side request identity. |
| Codex | The TUI supports configurable approval keymaps. Codex app-server sends request IDs and accepts decisions including accept, accept-for-session, decline, and cancel. | Watched-screen `y`/`n` shortcuts are implemented; app-server remains a strong structured candidate. |
| Cursor Agent | Terminal command approval documents `Y` and `N`. ACP exposes `session/request_permission` as a blocking structured interaction. | Watched-screen `y`/`n` shortcuts are implemented; ACP remains a strong structured candidate. |
| Amp | Does not ask before running tools by default; approval requires a custom policy plugin. | Keep Accept and Deny disabled unless such a plugin is detected. |
| Grok CLI | Herdr detects it, but authoritative public permission-key documentation was not found. | Keep dedicated approval disabled pending installed-version validation. |
| Antigravity CLI | Documents `Y`/`N` for terminal commands, Ctrl+K for instant tool approval, and fine-grained allow/ask/deny rules. | Documented keys aid manual use, but remote approval still needs request identity. |
| Kiro CLI | Herdr detects it, but authoritative public permission-key documentation was not found. | Keep dedicated approval disabled pending installed-version validation. |
| Maki | Supports fine-grained permissions, YOLO mode, and an ACP server. | Verify ACP permission capabilities and choice shapes. |
| Gemini CLI | Enter confirms, Escape cancels, Shift+Tab cycles approval modes, and numbered selection dialogs are supported. It also exposes ACP mode. | Strong structured candidate after capability verification. |
| Cline | The SDK exposes a `requestToolApproval` callback. The standalone CLI currently defaults to auto-approval unless configured otherwise. | Use the SDK callback; reflect configuration state in the phone UI. |

## Future structured permission safety requirements

A future unattended approval flow should resolve an identified request instead of simulating a generic keystroke:

1. The desktop bridge receives a structured permission request from an agent adapter.
2. It publishes the request ID, agent ID, agent kind, action summary, and available choices to the phone.
3. The phone renders every native choice when the request offers more than a simple one-time approval and rejection.
4. Fixed Accept and Deny buttons enable only when each has one unambiguous, accurately labelled mapping for that exact request. They remain disabled for choices such as approve-for-session, approve-always, or cancel until those choices are shown explicitly.
5. The phone returns the request ID and selected native decision.
6. The bridge confirms that the request is still pending before answering through the agent's native protocol.
7. Resolution or expiry immediately disables the controls.

The agent's blocked status is useful for gating the watched-screen shortcut, but it is not authorization evidence. It must not be treated as sufficient for unattended or persistent approval.

### Session ownership prerequisite

Herdr currently owns persistent terminal panes while the agents own their interactive TUI sessions. Before implementing an adapter, verify that its native protocol can observe and resolve permission requests for that same running session without becoming the competing session client.

If a protocol only works when the bridge launches and owns the agent session, adopting it would change Herdr's current launch, terminal rendering, and session-restore model. That change requires a separate architecture decision and must not be hidden inside the keypad approval feature.

`pane.read` screen parsing is not an acceptable approval fallback because the prompt can change between the read and the keystroke. It may still help validate ordinary navigation macros, but it must not authorize tool execution or persistent permission changes.

## Recommended rollout

1. ~~Expose the already-supported Escape key.~~ Implemented as a dedicated key.
2. ~~Add `shift+tab` to the bridge allowlist.~~ Implemented as a dedicated key.
3. ~~Add watched-screen Accept and Deny shortcuts for the five selected mainstream agents, gated by current blocked status.~~ Implemented.
4. Manually verify the default mappings against installed agent versions on a physical phone.
5. Run a later feasibility spike for structured agent protocols if unattended or request-identified approvals become a requirement.
6. Add a per-agent command sheet after real daily usage shows which macros deserve permanent placement.

## Sources

- [Herdr supported agents](https://herdr.dev/docs/agents/)
- [Herdr integrations](https://herdr.dev/docs/integrations/)
- [Codex app-server approvals](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [Claude Code interactive mode](https://code.claude.com/docs/en/interactive-mode)
- [Cursor CLI usage](https://docs.cursor.com/en/cli/using)
- [Droid SDK and headless interface](https://docs.factory.ai/cli/droid-exec/overview)
- [Gemini CLI keyboard shortcuts](https://geminicli.com/docs/reference/keyboard-shortcuts/)
- [Kimi interaction and approvals](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/interaction.html)
- [OpenCode permissions](https://opencode.ai/docs/permissions/)
- [Kilo Code CLI permissions](https://kilo.ai/docs/code-with-ai/platforms/cli)
- [Qoder CLI permissions](https://docs.qoder.com/en/cli/permissions)
- [Antigravity CLI controls](https://www.antigravity.google/docs/cli-using)
- [Hermes security and approvals](https://hermes-agent.nousresearch.com/docs/user-guide/security)
- [Amp manual](https://ampcode.com/manual)
- [Cline SDK permission handling](https://docs.cline.bot/sdk/guides/permission-handling)
- [MastraCode documentation](https://code.mastra.ai/)
- [Pi security](https://pi.dev/docs/latest/security)
- [Maki documentation](https://maki.sh/docs/)
