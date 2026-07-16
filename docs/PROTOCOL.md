# Herdr Remote Keypad Protocol v2

Protocol v2 is the session-aware keypad contract shared by the Rust bridge and Swift client. The phone owns session and agent selection. Every targeted request names both so the bridge can resolve the correct Herdr socket and revalidate the agent immediately before forwarding input.

## Transport and authentication

The client opens a persistent TCP connection over Tailscale. Each UTF-8 JSON object occupies one line, with a maximum encoded size of 65,536 bytes.

Every client message contains `version: 2`, a non-empty `id` no longer than 128 bytes, and a `type`. Authentication must be first and arrive within five seconds:

```json
{"version":2,"id":"1","type":"authenticate","token":"64 lowercase hexadecimal characters"}
```

Success returns `{"version":2,"id":"1","type":"authenticated"}`. Failure returns `authentication_failed` and closes the connection before session or agent state is exposed. Protocol v1 clients are incompatible with v2.

## Sessions

After authentication, and whenever running sessions change, the bridge sends:

```json
{
  "version":2,
  "event_id":1,
  "type":"session_snapshot",
  "sessions":[
    {"name":"default","default":true},
    {"name":"review","default":false}
  ]
}
```

Only running sessions appear. The bridge discovers them with Herdr's session-list command, orders the default first and remaining names alphabetically, and resolves client-supplied names only through this catalog. Socket paths never cross the network.

Session selection is client state; there is no `select_session` message. Choosing a session sends nothing to Herdr or macOS.

## Client messages

Request a complete agent list for one session:

```json
{"version":2,"id":"2","type":"request_snapshot","session":"default"}
```

Focus a current agent's pane:

```json
{"version":2,"id":"3","type":"focus_agent","session":"default","agent_id":"w1:p1"}
```

Send an allowlisted key:

```json
{"version":2,"id":"4","type":"send_key","session":"default","agent_id":"w1:p1","key":"arrow_down"}
```

Allowed key names are `arrow_up`, `arrow_down`, `arrow_left`, `arrow_right`, `enter`, `escape`, `tab`, `shift_tab`, and `space`.

Send a watched-screen Accept or Deny shortcut:

```json
{"version":2,"id":"5","type":"send_action","session":"default","agent_id":"w1:p1","action":"accept"}
```

The bridge refreshes the selected session's snapshot and permits actions only for blocked agents with a supported mapping. Codex and Cursor use `y`/`n`; Claude Code and OMP use Enter/Escape; OpenCode uses Enter or Escape followed by Enter.

Send printable Unicode text, optionally followed atomically by Enter:

```json
{"version":2,"id":"6","type":"send_text","session":"default","agent_id":"w1:p1","text":"Continue with the smallest fix.","submit":true}
```

Text is limited to 8,192 UTF-8 bytes and may not contain Unicode control characters. `ping` remains session-independent:

```json
{"version":2,"id":"7","type":"ping"}
```

## Server messages

Agent snapshots identify their session:

```json
{
  "version":2,
  "event_id":2,
  "type":"agent_snapshot",
  "session":"default",
  "herdr_protocol":16,
  "herdr_version":"0.7.4",
  "agents":[{
    "id":"w1:p1",
    "kind":"codex",
    "name":"codex",
    "status":"working",
    "title":"Fix authentication tests",
    "workspace":"api",
    "cwd":"/project"
  }]
}
```

The bridge sends a snapshot after authentication and whenever normalized agents change. A requested snapshot uses the request `id` instead of `event_id`. `kind` is the stable implementation identifier; `name` is the user-facing label.

Availability is also per session:

```json
{"version":2,"event_id":3,"type":"herdr_state","session":"default","state":"connected"}
```

`state` is `connected` or `unavailable`. An unavailable session remains visible while Herdr reports it running, but its input fails instead of being queued. Successful focus, input, and ping responses remain `agent_focused`, `input_acknowledged`, and `pong`.

## Errors and recovery

Errors use `{"version":2,"id":"3","type":"error","code":"session_not_found","message":"..."}`. Stable codes are:

- `authentication_failed`
- `unsupported_version`
- `invalid_message`
- `invalid_key`
- `invalid_text`
- `action_unavailable`
- `session_not_found`
- `agent_not_found`
- `herdr_unavailable`
- `internal_error`

Clients branch on `code`, not diagnostic messages. They cache agents and availability by session, clear the selected agent when sessions change, and fall back to the running default or first session when the current session closes. Request timeout remains five seconds; transport reconnection remains 0.5, 1, 2, 4, then 5 seconds capped.
