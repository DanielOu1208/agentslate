use crate::protocol::{Agent, MAX_HERDR_LINE_BYTES, read_frame};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fmt::{Display, Formatter};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

static REQUEST_ID: AtomicU64 = AtomicU64::new(1);
const MIN_HERDR_PROTOCOL: u32 = 19;
const SHIFT_TAB_SEQUENCE: &str = "\u{1b}[Z";
const OMP_SHIFT_TAB_SEQUENCE: &str = "\u{1b}[9;2u";

#[derive(Clone)]
pub struct HerdrClient {
    socket_path: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HerdrSession {
    pub name: String,
    pub is_default: bool,
    pub socket_path: PathBuf,
}

impl HerdrSession {
    pub fn new(name: impl Into<String>, is_default: bool, socket_path: PathBuf) -> Self {
        Self {
            name: name.into(),
            is_default,
            socket_path,
        }
    }
}

#[derive(Deserialize)]
struct SessionList {
    sessions: Vec<ListedSession>,
}

#[derive(Deserialize)]
struct ListedSession {
    name: String,
    #[serde(rename = "default")]
    is_default: bool,
    running: bool,
    socket_path: PathBuf,
}

pub fn discover_sessions() -> Result<Vec<HerdrSession>, String> {
    let output = Command::new("herdr")
        .args(["session", "list", "--json"])
        .output()
        .map_err(|error| format!("cannot run 'herdr session list --json': {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "Herdr session discovery failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    parse_sessions(&output.stdout)
}

fn parse_sessions(json: &[u8]) -> Result<Vec<HerdrSession>, String> {
    let listed: SessionList = serde_json::from_slice(json)
        .map_err(|error| format!("invalid Herdr session list: {error}"))?;
    let mut sessions = listed
        .sessions
        .into_iter()
        .filter(|session| session.running && !session.name.is_empty())
        .map(|session| HerdrSession {
            name: session.name,
            is_default: session.is_default,
            socket_path: session.socket_path,
        })
        .collect::<Vec<_>>();
    sessions.sort_by(|left, right| {
        right
            .is_default
            .cmp(&left.is_default)
            .then_with(|| left.name.cmp(&right.name))
    });
    Ok(sessions)
}

#[derive(Debug)]
pub enum HerdrError {
    Unavailable(String),
    Api { code: String, message: String },
    Protocol(String),
    UnsupportedVersion { version: String, protocol: u32 },
}

impl Display for HerdrError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(message) | Self::Protocol(message) => formatter.write_str(message),
            Self::Api { code, message } => write!(formatter, "Herdr {code}: {message}"),
            Self::UnsupportedVersion { version, protocol } => write!(
                formatter,
                "Herdr 0.8.0 or newer is required; found Herdr {version} (protocol {protocol})"
            ),
        }
    }
}

impl std::error::Error for HerdrError {}

#[derive(Clone, Debug, Deserialize)]
pub struct Snapshot {
    pub protocol: u32,
    pub version: String,
    #[serde(default)]
    pub agents: Vec<HerdrAgent>,
    #[serde(default)]
    pub workspaces: Vec<HerdrWorkspace>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct HerdrAgent {
    pub pane_id: String,
    pub agent: Option<String>,
    pub agent_status: String,
    #[serde(default)]
    pub display_agent: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub terminal_title_stripped: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    pub workspace_id: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct HerdrWorkspace {
    pub workspace_id: String,
    pub label: String,
}

impl Snapshot {
    pub fn normalized_agents(&self) -> Vec<Agent> {
        let workspaces = self
            .workspaces
            .iter()
            .map(|workspace| (workspace.workspace_id.as_str(), workspace.label.as_str()))
            .collect::<HashMap<_, _>>();
        self.agents
            .iter()
            .filter_map(|agent| {
                let kind = agent.agent.as_ref()?;
                Some(Agent {
                    id: agent.pane_id.clone(),
                    kind: kind.clone(),
                    name: agent.display_agent.clone().unwrap_or_else(|| kind.clone()),
                    status: agent.agent_status.clone(),
                    title: agent
                        .title
                        .clone()
                        .or_else(|| agent.terminal_title_stripped.clone()),
                    workspace: workspaces
                        .get(agent.workspace_id.as_str())
                        .map(|label| (*label).to_owned()),
                    cwd: agent.cwd.clone(),
                })
            })
            .collect()
    }

    pub fn has_agent(&self, agent_id: &str) -> bool {
        self.agents
            .iter()
            .any(|agent| agent.pane_id == agent_id && agent.agent.is_some())
    }
}

impl HerdrClient {
    pub fn new(socket_path: PathBuf) -> Self {
        Self { socket_path }
    }

    async fn connect(&self) -> Result<UnixStream, HerdrError> {
        UnixStream::connect(&self.socket_path)
            .await
            .map_err(|error| {
                HerdrError::Unavailable(format!(
                    "cannot connect to Herdr socket {}: {error}",
                    self.socket_path.display()
                ))
            })
    }

    async fn request(&self, method: &str, params: Value) -> Result<Value, HerdrError> {
        let mut stream = self.connect().await?;
        let id = format!("remote_{}", REQUEST_ID.fetch_add(1, Ordering::Relaxed));
        let request = json!({"id": id, "method": method, "params": params});
        let mut encoded = serde_json::to_vec(&request)
            .map_err(|error| HerdrError::Protocol(error.to_string()))?;
        encoded.push(b'\n');
        stream
            .write_all(&encoded)
            .await
            .map_err(|error| HerdrError::Unavailable(error.to_string()))?;

        let mut reader = BufReader::new(stream);
        let line = read_frame(&mut reader, MAX_HERDR_LINE_BYTES)
            .await
            .map_err(|error| HerdrError::Protocol(error.to_string()))?
            .ok_or_else(|| HerdrError::Unavailable("Herdr closed the socket".into()))?;
        let response: Value =
            serde_json::from_str(&line).map_err(|error| HerdrError::Protocol(error.to_string()))?;
        if response.get("id").and_then(Value::as_str) != Some(id.as_str()) {
            return Err(HerdrError::Protocol(
                "Herdr returned a mismatched request id".into(),
            ));
        }
        if let Some(error) = response.get("error") {
            return Err(HerdrError::Api {
                code: error
                    .get("code")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .to_owned(),
                message: error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown Herdr error")
                    .to_owned(),
            });
        }
        response
            .get("result")
            .cloned()
            .ok_or_else(|| HerdrError::Protocol("Herdr response has no result".into()))
    }

    pub async fn snapshot(&self) -> Result<Snapshot, HerdrError> {
        let result = self.request("session.snapshot", json!({})).await?;
        let snapshot: Snapshot = serde_json::from_value(
            result
                .get("snapshot")
                .cloned()
                .ok_or_else(|| HerdrError::Protocol("snapshot result is missing".into()))?,
        )
        .map_err(|error| HerdrError::Protocol(error.to_string()))?;
        if snapshot.protocol < MIN_HERDR_PROTOCOL {
            return Err(HerdrError::UnsupportedVersion {
                version: snapshot.version,
                protocol: snapshot.protocol,
            });
        }
        Ok(snapshot)
    }

    pub async fn focus_pane(&self, agent_id: &str) -> Result<(), HerdrError> {
        self.request("pane.focus", json!({"pane_id": agent_id}))
            .await?;
        Ok(())
    }

    pub async fn send_key(&self, agent_id: &str, key: &str) -> Result<(), HerdrError> {
        self.send_keys(agent_id, &[key]).await
    }

    pub async fn send_keys(&self, agent_id: &str, keys: &[&str]) -> Result<(), HerdrError> {
        self.request("pane.send_keys", json!({"pane_id": agent_id, "keys": keys}))
            .await?;
        Ok(())
    }

    pub async fn send_shift_tab(&self, agent_id: &str, agent_kind: &str) -> Result<(), HerdrError> {
        let sequence = if agent_kind == "omp" {
            OMP_SHIFT_TAB_SEQUENCE
        } else {
            SHIFT_TAB_SEQUENCE
        };
        self.request(
            "pane.send_text",
            json!({"pane_id": agent_id, "text": sequence}),
        )
        .await?;
        Ok(())
    }

    pub async fn send_text(
        &self,
        agent_id: &str,
        text: &str,
        submit: bool,
    ) -> Result<(), HerdrError> {
        let keys = if submit { vec!["enter"] } else { Vec::new() };
        self.request(
            "pane.send_input",
            json!({"pane_id": agent_id, "text": text, "keys": keys}),
        )
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixListener;

    #[test]
    fn parses_running_sessions_default_first() {
        let sessions = parse_sessions(
            br#"{"sessions":[
                {"name":"zeta","default":false,"running":true,"socket_path":"/tmp/zeta.sock"},
                {"name":"default","default":true,"running":true,"socket_path":"/tmp/default.sock"},
                {"name":"stopped","default":false,"running":false,"socket_path":"/tmp/stopped.sock"},
                {"name":"alpha","default":false,"running":true,"socket_path":"/tmp/alpha.sock"}
            ]}"#,
        )
        .unwrap();

        assert_eq!(
            sessions
                .iter()
                .map(|session| session.name.as_str())
                .collect::<Vec<_>>(),
            ["default", "alpha", "zeta"]
        );
    }

    #[tokio::test]
    async fn requests_and_normalizes_a_fake_snapshot() {
        let socket = std::env::temp_dir().join(format!(
            "agentslate-herdr-test-{}-{}.sock",
            std::process::id(),
            REQUEST_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).await.unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "session.snapshot");
            let response = json!({
                "id": request["id"],
                "result": {
                    "type": "session_snapshot",
                    "snapshot": {
                        "protocol": 19,
                        "version": "0.8.0",
                        "agents": [
                            {
                                "pane_id": "w1:p1",
                                "agent": "codex",
                                "agent_status": "blocked",
                                "workspace_id": "w1"
                            },
                            {
                                "pane_id": "w1:p2",
                                "agent": null,
                                "agent_status": "idle",
                                "workspace_id": "w1"
                            }
                        ],
                        "workspaces": [{"workspace_id": "w1", "label": "api"}]
                    }
                }
            });
            let mut stream = reader.into_inner();
            stream
                .write_all(format!("{response}\n").as_bytes())
                .await
                .unwrap();
        });

        let snapshot = HerdrClient::new(socket.clone()).snapshot().await.unwrap();
        let agents = snapshot.normalized_agents();
        assert_eq!(agents[0].kind, "codex");
        assert_eq!(agents[0].name, "codex");
        assert_eq!(agents[0].workspace.as_deref(), Some("api"));
        assert_eq!(agents.len(), 1);
        assert!(snapshot.has_agent("w1:p1"));
        assert!(!snapshot.has_agent("w1:p2"));
        server.await.unwrap();
        std::fs::remove_file(socket).unwrap();
    }

    #[tokio::test]
    async fn rejects_older_snapshot_protocol() {
        let socket = std::env::temp_dir().join(format!(
            "agentslate-herdr-test-{}-{}.sock",
            std::process::id(),
            REQUEST_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).await.unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            let response = json!({
                "id": request["id"],
                "result": {
                    "snapshot": {
                        "protocol": 17,
                        "version": "0.7.5",
                        "agents": [],
                        "workspaces": []
                    }
                }
            });
            reader
                .into_inner()
                .write_all(format!("{response}\n").as_bytes())
                .await
                .unwrap();
        });

        let error = HerdrClient::new(socket.clone())
            .snapshot()
            .await
            .unwrap_err();
        assert!(matches!(
            &error,
            HerdrError::UnsupportedVersion {
                version,
                protocol: 17
            } if version == "0.7.5"
        ));
        assert_eq!(
            error.to_string(),
            "Herdr 0.8.0 or newer is required; found Herdr 0.7.5 (protocol 17)"
        );
        server.await.unwrap();
        std::fs::remove_file(socket).unwrap();
    }

    #[tokio::test]
    async fn sends_shift_tab_as_literal_terminal_text() {
        let socket = std::env::temp_dir().join(format!(
            "agentslate-herdr-test-{}-{}.sock",
            std::process::id(),
            REQUEST_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).await.unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "pane.send_text");
            assert_eq!(
                request["params"],
                json!({"pane_id": "w1:p1", "text": SHIFT_TAB_SEQUENCE})
            );
            assert!(request["params"].get("keys").is_none());

            let response = json!({
                "id": request["id"],
                "result": {"type": "text_sent"}
            });
            reader
                .into_inner()
                .write_all(format!("{response}\n").as_bytes())
                .await
                .unwrap();
        });

        HerdrClient::new(socket.clone())
            .send_shift_tab("w1:p1", "codex")
            .await
            .unwrap();
        server.await.unwrap();
        std::fs::remove_file(socket).unwrap();
    }

    #[tokio::test]
    async fn sends_omp_shift_tab_as_enhanced_terminal_text() {
        let socket = std::env::temp_dir().join(format!(
            "agentslate-herdr-test-{}-{}.sock",
            std::process::id(),
            REQUEST_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).await.unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "pane.send_text");
            assert_eq!(
                request["params"],
                json!({"pane_id": "w1:p1", "text": OMP_SHIFT_TAB_SEQUENCE})
            );
            assert!(request["params"].get("keys").is_none());

            let response = json!({
                "id": request["id"],
                "result": {"type": "text_sent"}
            });
            reader
                .into_inner()
                .write_all(format!("{response}\n").as_bytes())
                .await
                .unwrap();
        });

        HerdrClient::new(socket.clone())
            .send_shift_tab("w1:p1", "omp")
            .await
            .unwrap();
        server.await.unwrap();
        std::fs::remove_file(socket).unwrap();
    }
}
