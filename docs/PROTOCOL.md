# AgentSlate Protocol v3

Protocol v3 is the device-paired, session-aware keypad contract shared by the Rust bridge and `AgentSlateClient`. The phone owns session and agent selection. Every targeted request names both so the bridge can resolve the correct Herdr socket and revalidate the device and agent immediately before forwarding input.

Protocol v1 and v2 clients are incompatible with v3.

## Transport and envelope

The client opens a persistent TCP connection over Tailscale. Each UTF-8 JSON object occupies one line, with a maximum encoded size of 65,536 bytes.

Every client message contains `version: 3`, a non-empty `id` no longer than 128 bytes, and a `type`. A `pair` or `authenticate` request must be first and arrive within five seconds. No Herdr state is exposed before authentication.

## Pairing

Running `agentslate pair` creates a six-digit pairing code. The code:

- expires after ten minutes;
- works once;
- locks and is removed after five failed attempts; and
- is stored only as a SHA-256 digest in the owner-only AgentSlate state directory.

A new phone opens a connection and sends:

```json
{"version":3,"id":"1","type":"pair","code":"123456","device_name":"Daniel's iPhone"}
```

`device_name` is trimmed and must contain 1-100 characters without control characters. Success returns a server-generated 16-byte device ID and random 32-byte credential, both serialized as lowercase hexadecimal:

```json
{"version":3,"id":"1","type":"paired","device_id":"32 lowercase hex characters","credential":"64 lowercase hex characters"}
```

The pairing connection then closes. The client stores the device ID and credential in iPhone Keychain and opens an authenticated connection. The Mac stores the device name, device ID, paired time, and only the credential's SHA-256 digest in an owner-only device file.

All pairing failures return the same delayed `pairing_failed` response so callers cannot distinguish a missing, expired, exhausted, malformed, or incorrect code:

```json
{"version":3,"id":"1","type":"error","code":"pairing_failed","message":"pairing failed"}
```

## Authentication and revocation

Each normal connection starts with:

```json
{"version":3,"id":"2","type":"authenticate","device_id":"32 lowercase hex characters","credential":"64 lowercase hex characters"}
```

Success returns:

```json
{"version":3,"id":"2","type":"authenticated"}
```

Invalid or revoked credentials return `authentication_failed` and close the connection before any Herdr state is exposed. The bridge rechecks the device file before every later command and every 200-millisecond state poll. Deleting it stops an existing connection before its next command or poll.

An authenticated phone can revoke itself:

```json
{"version":3,"id":"3","type":"revoke_self"}
```

Success returns `{"version":3,"id":"3","type":"revoked"}` and closes the connection. The app then clears its Keychain credential. A Mac user can also run `agentslate devices revoke DEVICE_ID`.

## Sessions

After authentication, and whenever running sessions change, the bridge sends:

```json
{
  "version":3,
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
{"version":3,"id":"4","type":"request_snapshot","session":"default"}
```

Focus a current agent's pane:

```json
{"version":3,"id":"5","type":"focus_agent","session":"default","agent_id":"w1:p1"}
```

Send an allowlisted key:

```json
{"version":3,"id":"6","type":"send_key","session":"default","agent_id":"w1:p1","key":"arrow_down"}
```

Allowed key names are `arrow_up`, `arrow_down`, `arrow_left`, `arrow_right`, `enter`, `escape`, `tab`, `shift_tab`, and `space`.

Send a watched-screen Accept or Deny shortcut:

```json
{"version":3,"id":"7","type":"send_action","session":"default","agent_id":"w1:p1","action":"accept"}
```

The bridge refreshes the selected session's snapshot and permits actions only for blocked agents with a supported mapping. Codex and Cursor use `y`/`n`; Claude Code and OMP use Enter/Escape; OpenCode uses Enter or Escape followed by Enter.

Send printable Unicode text, optionally followed atomically by Enter:

```json
{"version":3,"id":"8","type":"send_text","session":"default","agent_id":"w1:p1","text":"Continue with the smallest fix.","submit":true}
```

Text is limited to 8,192 UTF-8 bytes and may not contain Unicode control characters. `ping` remains session-independent:

```json
{"version":3,"id":"9","type":"ping"}
```

## Server messages

Agent snapshots identify their session:

```json
{
  "version":3,
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

The bridge sends snapshots after authentication and when normalized agents change. A requested snapshot uses the request `id` instead of `event_id`. `kind` is the stable implementation identifier; `name` is the user-facing label.

Availability is per session:

```json
{"version":3,"event_id":3,"type":"herdr_state","session":"default","state":"connected"}
```

`state` is `connected` or `unavailable`. An unavailable session remains visible while Herdr reports it running, but its input fails instead of being queued. Successful focus, input, and ping responses remain `agent_focused`, `input_acknowledged`, and `pong`.

## Errors and recovery

Errors use `{"version":3,"id":"5","type":"error","code":"agent_not_found","message":"..."}`. Stable codes are:

- `pairing_failed`
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

Clients branch on `code`, not diagnostic messages. They cache agents and availability by session, clear the selected agent when sessions change, and fall back to the running default or first session when the current session closes. Request timeout remains five seconds; transport reconnection remains 0.5, 1, 2, 4, then 5 seconds capped. A revoked or rejected device does not reconnect until it pairs again.
