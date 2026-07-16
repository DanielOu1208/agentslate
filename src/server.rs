use crate::herdr::{HerdrClient, HerdrError, HerdrSession, Snapshot, discover_sessions};
use crate::protocol::{
    Agent, ClientMessage, MAX_CLIENT_LINE_BYTES, MAX_REQUEST_ID_BYTES, PROTOCOL_VERSION, Session,
    herdr_key, read_frame, remote_action_keys, validate_text,
};
use crate::token;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::tcp::OwnedWriteHalf;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{RwLock, mpsc};
use tokio::time::{Instant, sleep, timeout};

pub struct ServerConfig {
    pub listen: Option<SocketAddr>,
    pub herdr_socket: Option<PathBuf>,
    pub token_file: PathBuf,
}

#[derive(Clone)]
enum SessionSource {
    Discover,
    Fixed(Vec<HerdrSession>),
}

impl SessionSource {
    fn sessions(&self) -> Result<Vec<HerdrSession>, String> {
        match self {
            Self::Discover => discover_sessions(),
            Self::Fixed(sessions) => Ok(sessions.clone()),
        }
    }
}

pub fn discover_tailscale_address(port: u16) -> Result<SocketAddr, String> {
    let output = Command::new("tailscale")
        .args(["ip", "-4"])
        .output()
        .map_err(|error| format!("cannot run 'tailscale ip -4': {error}"))?;
    if !output.status.success() {
        return Err("Tailscale is unavailable; pass --listen for a local-only test".into());
    }
    let address = String::from_utf8(output.stdout)
        .map_err(|error| error.to_string())?
        .lines()
        .next()
        .ok_or("Tailscale returned no IPv4 address")?
        .parse::<IpAddr>()
        .map_err(|error| format!("invalid Tailscale address: {error}"))?;
    Ok(SocketAddr::new(address, port))
}

pub async fn run(config: ServerConfig) -> Result<(), String> {
    let listen = config
        .listen
        .map(Ok)
        .unwrap_or_else(|| discover_tailscale_address(8765))?;
    let expected_token = Arc::new(token::read(&config.token_file)?);
    let source = Arc::new(match config.herdr_socket {
        Some(socket) => SessionSource::Fixed(vec![HerdrSession::new("custom", true, socket)]),
        None => {
            discover_sessions()?;
            SessionSource::Discover
        }
    });
    let listener = TcpListener::bind(listen)
        .await
        .map_err(|error| format!("cannot listen on {listen}: {error}"))?;
    println!("Herdr Remote Keypad listening on {listen}");
    match source.as_ref() {
        SessionSource::Discover => println!("Herdr sessions: automatic discovery"),
        SessionSource::Fixed(sessions) => {
            println!("Herdr socket: {}", sessions[0].socket_path.display())
        }
    }

    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (stream, peer) = accepted.map_err(|error| error.to_string())?;
                let source = Arc::clone(&source);
                let expected_token = Arc::clone(&expected_token);
                tokio::spawn(async move {
                    if let Err(error) = handle_connection(stream, source, expected_token).await {
                        eprintln!("connection {peer} closed: {error}");
                    }
                });
            }
            signal = tokio::signal::ctrl_c() => {
                signal.map_err(|error| error.to_string())?;
                println!("Bridge stopped");
                return Ok(());
            }
        }
    }
}

async fn handle_connection(
    stream: TcpStream,
    source: Arc<SessionSource>,
    expected_token: Arc<String>,
) -> Result<(), String> {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let first = timeout(
        Duration::from_secs(5),
        read_frame(&mut reader, MAX_CLIENT_LINE_BYTES),
    )
    .await
    .map_err(|_| "authentication timed out".to_owned())?
    .map_err(|error| error.to_string())?
    .ok_or("client disconnected before authentication")?;
    let message: ClientMessage = serde_json::from_str(&first)
        .map_err(|_| "first message was not valid protocol JSON".to_owned())?;

    let (id, supplied_token) = match message {
        ClientMessage::Authenticate {
            version,
            id,
            token: supplied_token,
        } => {
            if version != PROTOCOL_VERSION {
                write_direct(
                    &mut write_half,
                    error_response(&id, "unsupported_version", "unsupported protocol version"),
                )
                .await?;
                return Err("authentication used an invalid envelope".into());
            }
            if id.is_empty() || id.len() > MAX_REQUEST_ID_BYTES {
                write_direct(
                    &mut write_half,
                    error_response("unknown", "invalid_message", "invalid request envelope"),
                )
                .await?;
                return Err("authentication used an invalid request id".into());
            }
            (id, supplied_token)
        }
        _ => {
            write_direct(
                &mut write_half,
                error_response("unknown", "authentication_failed", "authentication failed"),
            )
            .await?;
            return Err("authentication was not the first message".into());
        }
    };

    if !token::constant_time_eq(expected_token.as_bytes(), supplied_token.as_bytes()) {
        sleep(Duration::from_millis(250)).await;
        write_direct(
            &mut write_half,
            error_response(&id, "authentication_failed", "authentication failed"),
        )
        .await?;
        return Err("authentication failed".into());
    }
    write_direct(&mut write_half, response(&id, "authenticated", json!({}))).await?;

    let sessions = Arc::new(RwLock::new(source.sessions()?));
    let (outgoing, receiver) = mpsc::channel::<Value>(64);
    let writer = tokio::spawn(writer_loop(write_half, receiver));
    let events = Arc::new(AtomicU64::new(1));
    let status_monitor = tokio::spawn(monitor_sessions(
        source,
        Arc::clone(&sessions),
        outgoing.clone(),
        Arc::clone(&events),
    ));

    while let Some(line) = read_frame(&mut reader, MAX_CLIENT_LINE_BYTES)
        .await
        .map_err(|error| error.to_string())?
    {
        let message: ClientMessage = match serde_json::from_str(&line) {
            Ok(message) => message,
            Err(_) => {
                send(
                    &outgoing,
                    error_response("unknown", "invalid_message", "invalid protocol message"),
                )
                .await?;
                continue;
            }
        };
        if let Err(code) = message.validate_envelope() {
            let detail = if code == "unsupported_version" {
                "unsupported protocol version"
            } else {
                "invalid request envelope"
            };
            send(&outgoing, error_response(message.id(), code, detail)).await?;
            continue;
        }

        match message {
            ClientMessage::Authenticate { id, .. } => {
                send(
                    &outgoing,
                    error_response(&id, "invalid_message", "already authenticated"),
                )
                .await?;
            }
            ClientMessage::RequestSnapshot { id, session, .. } => {
                match session_client(&sessions, &session).await {
                    Ok(herdr) => match herdr.snapshot().await {
                        Ok(snapshot) => {
                            send(&outgoing, snapshot_response(&id, &session, &snapshot)).await?;
                        }
                        Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                    },
                    Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                }
            }
            ClientMessage::FocusAgent {
                id,
                session,
                agent_id,
                ..
            } => {
                let herdr = match session_client(&sessions, &session).await {
                    Ok(herdr) => herdr,
                    Err(error) => {
                        send_herdr_error(&outgoing, &id, error).await?;
                        continue;
                    }
                };
                match current_agent(&herdr, &agent_id).await {
                    Ok(_) => match herdr.focus_pane(&agent_id).await {
                        Ok(()) => {
                            send(&outgoing, response(&id, "agent_focused", json!({}))).await?
                        }
                        Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                    },
                    Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                }
            }
            ClientMessage::SendKey {
                id,
                session,
                agent_id,
                key,
                ..
            } => {
                let Some(key) = herdr_key(&key) else {
                    send(
                        &outgoing,
                        error_response(&id, "invalid_key", "unsupported key"),
                    )
                    .await?;
                    continue;
                };
                let herdr = match session_client(&sessions, &session).await {
                    Ok(herdr) => herdr,
                    Err(error) => {
                        send_herdr_error(&outgoing, &id, error).await?;
                        continue;
                    }
                };
                match current_agent(&herdr, &agent_id).await {
                    Ok(_) => match herdr.send_key(&agent_id, key).await {
                        Ok(()) => {
                            send(&outgoing, response(&id, "input_acknowledged", json!({}))).await?
                        }
                        Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                    },
                    Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                }
            }
            ClientMessage::SendText {
                id,
                session,
                agent_id,
                text,
                submit,
                ..
            } => {
                if validate_text(&text).is_err() {
                    send(
                        &outgoing,
                        error_response(
                            &id,
                            "invalid_text",
                            "text is too large or contains control characters",
                        ),
                    )
                    .await?;
                    continue;
                }
                let herdr = match session_client(&sessions, &session).await {
                    Ok(herdr) => herdr,
                    Err(error) => {
                        send_herdr_error(&outgoing, &id, error).await?;
                        continue;
                    }
                };
                match current_agent(&herdr, &agent_id).await {
                    Ok(_) => match herdr.send_text(&agent_id, &text, submit).await {
                        Ok(()) => {
                            send(&outgoing, response(&id, "input_acknowledged", json!({}))).await?
                        }
                        Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                    },
                    Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                }
            }
            ClientMessage::SendAction {
                id,
                session,
                agent_id,
                action,
                ..
            } => {
                let herdr = match session_client(&sessions, &session).await {
                    Ok(herdr) => herdr,
                    Err(error) => {
                        send_herdr_error(&outgoing, &id, error).await?;
                        continue;
                    }
                };
                match current_agent(&herdr, &agent_id).await {
                    Ok(snapshot) => {
                        let agent = snapshot
                            .agents
                            .iter()
                            .find(|agent| agent.pane_id == agent_id)
                            .expect(
                                "current_agent returned a snapshot without the requested agent",
                            );
                        let keys = if agent.agent_status == "blocked" {
                            remote_action_keys(&agent.agent, action)
                        } else {
                            None
                        };
                        let Some(keys) = keys else {
                            send(
                                &outgoing,
                                error_response(
                                    &id,
                                    "action_unavailable",
                                    "action is unavailable for the agent's current state or type",
                                ),
                            )
                            .await?;
                            continue;
                        };
                        match herdr.send_keys(&agent_id, keys).await {
                            Ok(()) => {
                                send(&outgoing, response(&id, "input_acknowledged", json!({})))
                                    .await?
                            }
                            Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                        }
                    }
                    Err(error) => send_herdr_error(&outgoing, &id, error).await?,
                }
            }
            ClientMessage::Ping { id, .. } => {
                send(&outgoing, response(&id, "pong", json!({}))).await?;
            }
        }
    }

    status_monitor.abort();
    drop(outgoing);
    let _ = writer.await;
    Ok(())
}

async fn current_agent(herdr: &HerdrClient, agent_id: &str) -> Result<Snapshot, HerdrError> {
    let snapshot = herdr.snapshot().await?;
    if snapshot.has_agent(agent_id) {
        Ok(snapshot)
    } else {
        Err(HerdrError::Api {
            code: "agent_not_found".into(),
            message: "agent is not present in the current Herdr snapshot".into(),
        })
    }
}

async fn session_client(
    sessions: &RwLock<Vec<HerdrSession>>,
    name: &str,
) -> Result<HerdrClient, HerdrError> {
    sessions
        .read()
        .await
        .iter()
        .find(|session| session.name == name)
        .map(|session| HerdrClient::new(session.socket_path.clone()))
        .ok_or_else(|| HerdrError::Api {
            code: "session_not_found".into(),
            message: "session is not currently running".into(),
        })
}

async fn monitor_sessions(
    source: Arc<SessionSource>,
    sessions: Arc<RwLock<Vec<HerdrSession>>>,
    outgoing: mpsc::Sender<Value>,
    events: Arc<AtomicU64>,
) {
    let mut previous_sessions = None;
    let mut connected = HashMap::<String, bool>::new();
    let mut previous_agents = HashMap::<String, Vec<Agent>>::new();
    let mut next_discovery = Instant::now();

    loop {
        if Instant::now() >= next_discovery {
            match source.sessions() {
                Ok(discovered) => *sessions.write().await = discovered,
                Err(error) => eprintln!("Herdr session discovery failed: {error}"),
            }
            next_discovery = Instant::now() + Duration::from_secs(1);
        }

        let current_sessions = sessions.read().await.clone();
        let summaries = current_sessions
            .iter()
            .map(|session| Session {
                name: session.name.clone(),
                is_default: session.is_default,
            })
            .collect::<Vec<_>>();
        if previous_sessions.as_ref() != Some(&summaries) {
            if send_event(
                &outgoing,
                &events,
                "session_snapshot",
                json!({"sessions": summaries}),
            )
            .await
            .is_err()
            {
                return;
            }
            previous_sessions = Some(summaries);
        }

        let current_names = current_sessions
            .iter()
            .map(|session| session.name.as_str())
            .collect::<Vec<_>>();
        connected.retain(|name, _| current_names.contains(&name.as_str()));
        previous_agents.retain(|name, _| current_names.contains(&name.as_str()));

        for session in current_sessions {
            let herdr = HerdrClient::new(session.socket_path);
            match herdr.snapshot().await {
                Ok(snapshot) => {
                    if connected.get(&session.name) != Some(&true) {
                        if send_event(
                            &outgoing,
                            &events,
                            "herdr_state",
                            json!({"session": session.name, "state": "connected"}),
                        )
                        .await
                        .is_err()
                        {
                            return;
                        }
                        connected.insert(session.name.clone(), true);
                    }
                    let agents = snapshot.normalized_agents();
                    if previous_agents.get(&session.name) != Some(&agents) {
                        if send_event(
                            &outgoing,
                            &events,
                            "agent_snapshot",
                            snapshot_payload(&session.name, &snapshot, &agents),
                        )
                        .await
                        .is_err()
                        {
                            return;
                        }
                        previous_agents.insert(session.name.clone(), agents);
                    }
                }
                Err(error) => {
                    eprintln!("Herdr session '{}' unavailable: {error}", session.name);
                    if connected.get(&session.name) != Some(&false) {
                        if send_event(
                            &outgoing,
                            &events,
                            "herdr_state",
                            json!({"session": session.name, "state": "unavailable"}),
                        )
                        .await
                        .is_err()
                        {
                            return;
                        }
                        connected.insert(session.name.clone(), false);
                        previous_agents.remove(&session.name);
                    }
                }
            }
        }

        // ponytail: per-client polling is enough for the single-phone MVP; move to a shared
        // cache only when multiple simultaneous devices make the duplicate work measurable.
        sleep(Duration::from_millis(200)).await;
    }
}

async fn writer_loop(mut writer: OwnedWriteHalf, mut receiver: mpsc::Receiver<Value>) {
    while let Some(value) = receiver.recv().await {
        if write_direct(&mut writer, value).await.is_err() {
            return;
        }
    }
}

async fn write_direct(writer: &mut OwnedWriteHalf, value: Value) -> Result<(), String> {
    let mut encoded = serde_json::to_vec(&value).map_err(|error| error.to_string())?;
    encoded.push(b'\n');
    writer
        .write_all(&encoded)
        .await
        .map_err(|error| error.to_string())
}

async fn send(outgoing: &mpsc::Sender<Value>, value: Value) -> Result<(), String> {
    outgoing
        .send(value)
        .await
        .map_err(|_| "connection writer stopped".into())
}

async fn send_event(
    outgoing: &mpsc::Sender<Value>,
    events: &AtomicU64,
    message_type: &str,
    payload: Value,
) -> Result<(), String> {
    let mut object = payload.as_object().cloned().unwrap_or_default();
    object.insert("version".into(), json!(PROTOCOL_VERSION));
    object.insert(
        "event_id".into(),
        json!(events.fetch_add(1, Ordering::Relaxed)),
    );
    object.insert("type".into(), json!(message_type));
    send(outgoing, Value::Object(object)).await
}

fn response(id: &str, message_type: &str, payload: Value) -> Value {
    let mut object = payload.as_object().cloned().unwrap_or_default();
    object.insert("version".into(), json!(PROTOCOL_VERSION));
    object.insert("id".into(), json!(id));
    object.insert("type".into(), json!(message_type));
    Value::Object(object)
}

fn error_response(id: &str, code: &str, message: &str) -> Value {
    response(id, "error", json!({"code": code, "message": message}))
}

fn snapshot_payload(session: &str, snapshot: &Snapshot, agents: &[Agent]) -> Value {
    json!({
        "session": session,
        "herdr_protocol": snapshot.protocol,
        "herdr_version": snapshot.version,
        "agents": agents
    })
}

fn snapshot_response(id: &str, session: &str, snapshot: &Snapshot) -> Value {
    let agents = snapshot.normalized_agents();
    response(
        id,
        "agent_snapshot",
        snapshot_payload(session, snapshot, &agents),
    )
}

async fn send_herdr_error(
    outgoing: &mpsc::Sender<Value>,
    id: &str,
    error: HerdrError,
) -> Result<(), String> {
    let (code, message) = match error {
        HerdrError::Api { code, message }
            if code == "agent_not_found" || code == "session_not_found" =>
        {
            (code, message)
        }
        HerdrError::Api { code, .. } if code == "pane_not_found" || code == "not_found" => (
            "agent_not_found".into(),
            "agent is no longer present in Herdr".into(),
        ),
        HerdrError::Unavailable(_) => (
            "herdr_unavailable".into(),
            "Herdr is currently unavailable".into(),
        ),
        other => {
            eprintln!("Herdr request failed: {other}");
            ("internal_error".into(), "Herdr request failed".into())
        }
    };
    send(outgoing, error_response(id, &code, &message)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::MAX_HERDR_LINE_BYTES;
    use serde_json::json;
    use std::sync::atomic::{AtomicU64, Ordering};
    use tokio::net::UnixListener;
    use tokio::sync::Mutex;

    static TEST_ID: AtomicU64 = AtomicU64::new(1);

    async fn write_client(writer: &mut OwnedWriteHalf, value: Value) {
        write_direct(writer, value).await.unwrap();
    }

    async fn read_for_id(
        reader: &mut BufReader<tokio::net::tcp::OwnedReadHalf>,
        id: &str,
    ) -> Value {
        timeout(Duration::from_secs(2), async {
            loop {
                let line = read_frame(reader, MAX_CLIENT_LINE_BYTES)
                    .await
                    .unwrap()
                    .unwrap();
                let value: Value = serde_json::from_str(&line).unwrap();
                if value.get("id").and_then(Value::as_str) == Some(id) {
                    return value;
                }
            }
        })
        .await
        .unwrap()
    }

    async fn read_for_type(
        reader: &mut BufReader<tokio::net::tcp::OwnedReadHalf>,
        message_type: &str,
    ) -> Value {
        timeout(Duration::from_secs(2), async {
            loop {
                let line = read_frame(reader, MAX_CLIENT_LINE_BYTES)
                    .await
                    .unwrap()
                    .unwrap();
                let value: Value = serde_json::from_str(&line).unwrap();
                if value.get("type").and_then(Value::as_str) == Some(message_type) {
                    return value;
                }
            }
        })
        .await
        .unwrap()
    }

    async fn run_fake_herdr(listener: UnixListener, requests: Arc<Mutex<Vec<Value>>>) {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let mut reader = BufReader::new(stream);
            let line = read_frame(&mut reader, MAX_HERDR_LINE_BYTES)
                .await
                .unwrap()
                .unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            requests.lock().await.push(request.clone());
            let response = match request["method"].as_str().unwrap() {
                "session.snapshot" => json!({
                    "id": request["id"],
                    "result": {
                        "type": "session_snapshot",
                        "snapshot": {
                            "protocol": 16,
                            "version": "0.7.4",
                            "agents": [
                                {
                                    "pane_id": "w1:p1",
                                    "agent": "codex",
                                    "agent_status": "blocked",
                                    "workspace_id": "w1"
                                },
                                {
                                    "pane_id": "w1:p2",
                                    "agent": "codex",
                                    "agent_status": "working",
                                    "workspace_id": "w1"
                                },
                                {
                                    "pane_id": "w1:p3",
                                    "agent": "custom",
                                    "agent_status": "blocked",
                                    "workspace_id": "w1"
                                },
                                {
                                    "pane_id": "w1:p4",
                                    "agent": "opencode",
                                    "agent_status": "blocked",
                                    "workspace_id": "w1"
                                }
                            ],
                            "workspaces": [{"workspace_id": "w1", "label": "demo"}]
                        }
                    }
                }),
                "pane.focus" => json!({"id": request["id"], "result": {"type": "pane_focused"}}),
                "pane.send_keys" | "pane.send_input" => {
                    json!({"id": request["id"], "result": {"type": "input_sent"}})
                }
                method => json!({
                    "id": request["id"],
                    "error": {
                        "code": "unexpected_method",
                        "message": format!("unexpected Herdr method: {method}")
                    }
                }),
            };
            let mut stream = reader.into_inner();
            let mut bytes = serde_json::to_vec(&response).unwrap();
            bytes.push(b'\n');
            stream.write_all(&bytes).await.unwrap();
        }
    }

    #[test]
    fn event_and_response_envelopes_do_not_overwrite_payloads() {
        let response = response("abc", "pong", json!({"detail": "ok"}));
        assert_eq!(response["version"], PROTOCOL_VERSION);
        assert_eq!(response["id"], "abc");
        assert_eq!(response["detail"], "ok");
    }

    #[tokio::test]
    async fn routes_authenticated_keypad_requests_end_to_end() {
        let socket = std::env::temp_dir().join(format!(
            "herdr-remote-keypad-server-test-{}-{}.sock",
            std::process::id(),
            TEST_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let herdr_listener = UnixListener::bind(&socket).unwrap();
        let herdr_requests = Arc::new(Mutex::new(Vec::new()));
        let fake_herdr = tokio::spawn(run_fake_herdr(herdr_listener, Arc::clone(&herdr_requests)));

        let second_socket = std::env::temp_dir().join(format!(
            "herdr-remote-keypad-server-test-{}-{}.sock",
            std::process::id(),
            TEST_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let second_listener = UnixListener::bind(&second_socket).unwrap();
        let second_requests = Arc::new(Mutex::new(Vec::new()));
        let second_herdr = tokio::spawn(run_fake_herdr(
            second_listener,
            Arc::clone(&second_requests),
        ));

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let expected_token = Arc::new("a".repeat(64));
        let source = Arc::new(SessionSource::Fixed(vec![
            HerdrSession::new("default", true, socket.clone()),
            HerdrSession::new("team", false, second_socket.clone()),
        ]));
        let bridge = tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let source = Arc::clone(&source);
                let token = Arc::clone(&expected_token);
                tokio::spawn(async move {
                    let _ = handle_connection(stream, source, token).await;
                });
            }
        });

        let old_stream = TcpStream::connect(address).await.unwrap();
        let (old_read, mut old_write) = old_stream.into_split();
        let mut old_reader = BufReader::new(old_read);
        write_client(
            &mut old_write,
            json!({
                "version": 1,
                "id": "old-auth",
                "type": "authenticate",
                "token": "a".repeat(64)
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut old_reader, "old-auth").await["code"],
            "unsupported_version"
        );

        let bad_stream = TcpStream::connect(address).await.unwrap();
        let (bad_read, mut bad_write) = bad_stream.into_split();
        let mut bad_reader = BufReader::new(bad_read);
        write_client(
            &mut bad_write,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "bad-auth",
                "type": "authenticate",
                "token": "b".repeat(64)
            }),
        )
        .await;
        let rejected = read_for_id(&mut bad_reader, "bad-auth").await;
        assert_eq!(rejected["code"], "authentication_failed");
        assert!(
            timeout(
                Duration::from_secs(1),
                read_frame(&mut bad_reader, MAX_CLIENT_LINE_BYTES)
            )
            .await
            .unwrap()
            .unwrap()
            .is_none()
        );

        let stream = TcpStream::connect(address).await.unwrap();
        let (read_half, mut write_half) = stream.into_split();
        let mut reader = BufReader::new(read_half);
        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "auth",
                "type": "authenticate",
                "token": "a".repeat(64)
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "auth").await["type"],
            "authenticated"
        );
        let sessions = read_for_type(&mut reader, "session_snapshot").await;
        assert_eq!(sessions["sessions"][0]["name"], "default");
        assert_eq!(sessions["sessions"][1]["name"], "team");

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "snapshot",
                "type": "request_snapshot",
                "session": "default"
            }),
        )
        .await;
        let snapshot = read_for_id(&mut reader, "snapshot").await;
        assert_eq!(snapshot["agents"][0]["id"], "w1:p1");
        assert!(snapshot["agents"][0].get("revision").is_none());

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "focus",
                "type": "focus_agent",
                "session": "default",
                "agent_id": "w1:p1"
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "focus").await["type"],
            "agent_focused"
        );

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "missing-focus",
                "type": "focus_agent",
                "session": "default",
                "agent_id": "missing"
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "missing-focus").await["code"],
            "agent_not_found"
        );

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "invalid-key",
                "type": "send_key",
                "session": "default",
                "agent_id": "w1:p1",
                "key": "ctrl_c"
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "invalid-key").await["code"],
            "invalid_key"
        );

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "key",
                "type": "send_key",
                "session": "default",
                "agent_id": "w1:p1",
                "key": "arrow_down"
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "key").await["type"],
            "input_acknowledged"
        );

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "team-key",
                "type": "send_key",
                "session": "team",
                "agent_id": "w1:p1",
                "key": "arrow_up"
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "team-key").await["type"],
            "input_acknowledged"
        );

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "missing-session",
                "type": "send_key",
                "session": "missing",
                "agent_id": "w1:p1",
                "key": "enter"
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "missing-session").await["code"],
            "session_not_found"
        );

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "shift-tab",
                "type": "send_key",
                "session": "default",
                "agent_id": "w1:p1",
                "key": "shift_tab"
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "shift-tab").await["type"],
            "input_acknowledged"
        );

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "accept",
                "type": "send_action",
                "session": "default",
                "agent_id": "w1:p1",
                "action": "accept"
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "accept").await["type"],
            "input_acknowledged"
        );

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "opencode-deny",
                "type": "send_action",
                "session": "default",
                "agent_id": "w1:p4",
                "action": "deny"
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "opencode-deny").await["type"],
            "input_acknowledged"
        );

        for (id, agent_id) in [("working-action", "w1:p2"), ("unsupported-action", "w1:p3")] {
            write_client(
                &mut write_half,
                json!({
                    "version": PROTOCOL_VERSION,
                    "id": id,
                    "type": "send_action",
                    "session": "default",
                    "agent_id": agent_id,
                    "action": "accept"
                }),
            )
            .await;
            assert_eq!(
                read_for_id(&mut reader, id).await["code"],
                "action_unavailable"
            );
        }

        write_client(
            &mut write_half,
            json!({
                "version": PROTOCOL_VERSION,
                "id": "text",
                "type": "send_text",
                "session": "default",
                "agent_id": "w1:p1",
                "text": "continue",
                "submit": true
            }),
        )
        .await;
        assert_eq!(
            read_for_id(&mut reader, "text").await["type"],
            "input_acknowledged"
        );

        let requests = herdr_requests.lock().await;
        assert!(requests.iter().any(|request| {
            request["method"] == "pane.focus" && request["params"] == json!({"pane_id": "w1:p1"})
        }));
        assert!(!requests.iter().any(|request| {
            request["method"] == "pane.focus" && request["params"] == json!({"pane_id": "missing"})
        }));
        assert!(requests.iter().any(|request| {
            request["method"] == "pane.send_keys"
                && request["params"] == json!({"pane_id": "w1:p1", "keys": ["down"]})
        }));
        assert!(requests.iter().any(|request| {
            request["method"] == "pane.send_keys"
                && request["params"] == json!({"pane_id": "w1:p1", "keys": ["shift+tab"]})
        }));
        assert!(requests.iter().any(|request| {
            request["method"] == "pane.send_keys"
                && request["params"] == json!({"pane_id": "w1:p1", "keys": ["y"]})
        }));
        assert!(requests.iter().any(|request| {
            request["method"] == "pane.send_keys"
                && request["params"] == json!({"pane_id": "w1:p4", "keys": ["esc", "enter"]})
        }));
        assert!(!requests.iter().any(|request| {
            request["method"] == "pane.send_keys"
                && matches!(
                    request["params"]["pane_id"].as_str(),
                    Some("w1:p2" | "w1:p3")
                )
        }));
        assert!(requests.iter().any(|request| {
            request["method"] == "pane.send_input"
                && request["params"]
                    == json!({"pane_id": "w1:p1", "text": "continue", "keys": ["enter"]})
        }));
        assert!(!requests.iter().any(|request| {
            request["method"] == "pane.send_keys" && request["params"]["keys"] == json!(["ctrl_c"])
        }));
        assert!(requests.iter().all(|request| matches!(
            request["method"].as_str(),
            Some("session.snapshot" | "pane.focus" | "pane.send_keys" | "pane.send_input")
        )));
        drop(requests);

        let requests = second_requests.lock().await;
        assert!(requests.iter().any(|request| {
            request["method"] == "pane.send_keys"
                && request["params"] == json!({"pane_id": "w1:p1", "keys": ["up"]})
        }));
        drop(requests);

        drop(write_half);
        drop(reader);
        bridge.abort();
        fake_herdr.abort();
        second_herdr.abort();
        let _ = bridge.await;
        let _ = fake_herdr.await;
        let _ = second_herdr.await;
        std::fs::remove_file(socket).unwrap();
        std::fs::remove_file(second_socket).unwrap();
    }
}
