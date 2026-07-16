# Herdr Remote Keypad Protocol v1

Protocol v1 is the keypad-only contract shared by the Rust bridge and Swift client. Tapping an agent focuses its Herdr pane and selects it as the keypad target; every focus and input request names its target agent so the bridge can revalidate it immediately before forwarding the action.

## Transport

The client opens a persistent TCP connection to the bridge over Tailscale. Each UTF-8 JSON object occupies one line. The maximum encoded line is 65,536 bytes.

Every client message contains:

- `version`: bridge protocol version, currently `1`
- `id`: non-empty client request identifier, maximum 128 bytes
- `type`: message type

Responses repeat the request's `id`. Unsolicited bridge events contain a connection-local increasing `event_id`. Unknown JSON fields are ignored; unknown client message types are rejected.

## Authentication

Authentication must be the first message and must arrive within five seconds:

```json
{"version":1,"id":"1","type":"authenticate","token":"64 lowercase hexadecimal characters"}
```

Success:

```json
{"version":1,"id":"1","type":"authenticated"}
```

Failure returns `authentication_failed` and closes the connection. No agent data is sent before success.

## Client messages

Request a fresh complete agent list:

```json
{"version":1,"id":"2","type":"request_snapshot"}
```

Focus a current agent's Herdr pane:

```json
{"version":1,"id":"3","type":"focus_agent","agent_id":"w1:p1"}
```

Send an allowlisted key to a current agent:

```json
{"version":1,"id":"4","type":"send_key","agent_id":"w1:p1","key":"arrow_down"}
```

Allowed bridge key names are `arrow_up`, `arrow_down`, `arrow_left`, `arrow_right`, `enter`, `escape`, `tab`, and `space`.

Send printable Unicode text, optionally followed atomically by Enter:

```json
{"version":1,"id":"5","type":"send_text","agent_id":"w1:p1","text":"Continue with the smallest fix.","submit":true}
```

Text is limited to 8,192 UTF-8 bytes and may not contain Unicode control characters. This prevents embedded newlines or escape bytes from bypassing the key allowlist.

Connection check:

```json
{"version":1,"id":"5","type":"ping"}
```

## Server messages

Complete agent snapshot:

```json
{
  "version":1,
  "event_id":1,
  "type":"agent_snapshot",
  "herdr_protocol":16,
  "herdr_version":"0.7.4",
  "agents":[
    {
      "id":"w1:p1",
      "name":"codex",
      "status":"working",
      "title":"Fix authentication tests",
      "workspace":"api",
      "cwd":"/project"
    }
  ]
}
```

The bridge pushes this event after authentication and whenever normalized agent state changes. A snapshot requested with `request_snapshot` has the same fields but repeats the request's `id` instead of using `event_id`.

Input success:

```json
{"version":1,"id":"4","type":"input_acknowledged"}
```

Focus success:

```json
{"version":1,"id":"3","type":"agent_focused"}
```

Herdr availability:

```json
{"version":1,"event_id":2,"type":"herdr_state","state":"connected"}
```

`state` is `connected` or `unavailable`. Input requests received while unavailable fail instead of being queued.

Ping response:

```json
{"version":1,"id":"5","type":"pong"}
```

## Errors

```json
{
  "version":1,
  "id":"3",
  "type":"error",
  "code":"invalid_key",
  "message":"unsupported key"
}
```

Stable error codes:

- `authentication_failed`
- `unsupported_version`
- `invalid_message`
- `invalid_key`
- `invalid_text`
- `agent_not_found`
- `herdr_unavailable`
- `internal_error`

Error messages are for diagnostics; clients branch on `code`.

## Client state and recovery

- Clients replace their agent cache whenever `agent_snapshot` arrives.
- The bridge pushes the initial snapshot after authentication; clients do not need a second bootstrap `request_snapshot`.
- The selected keypad target is client state. Change it only after `agent_focused`; preserve it while its ID remains in the latest snapshot and clear it when the agent disappears.
- After reconnecting, clients authenticate again and use the new snapshot as authoritative state.
- Clients fail a request if no matching response arrives within 5 seconds, even when the TCP connection remains open.
- Unexpected transport failures retry after 0.5, 1, 2, 4, then 5 seconds, capped at 5 seconds. Authentication failures do not retry.
- A connected bridge may report Herdr as unavailable. Keep the bridge connection open and disable input until Herdr reconnects.
