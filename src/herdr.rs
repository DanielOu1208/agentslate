use crate::protocol::{Agent, MAX_HERDR_LINE_BYTES, read_frame};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fmt::{Display, Formatter};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

static REQUEST_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone)]
pub struct HerdrClient {
    socket_path: PathBuf,
}

#[derive(Debug)]
pub enum HerdrError {
    Unavailable(String),
    Api { code: String, message: String },
    Protocol(String),
}

impl Display for HerdrError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(message) | Self::Protocol(message) => formatter.write_str(message),
            Self::Api { code, message } => write!(formatter, "Herdr {code}: {message}"),
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
    pub agent: String,
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
            .map(|agent| Agent {
                id: agent.pane_id.clone(),
                kind: agent.agent.clone(),
                name: agent
                    .display_agent
                    .clone()
                    .unwrap_or_else(|| agent.agent.clone()),
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
            .collect()
    }

    pub fn has_agent(&self, agent_id: &str) -> bool {
        self.agents.iter().any(|agent| agent.pane_id == agent_id)
    }
}

impl HerdrClient {
    pub fn new(socket_path: PathBuf) -> Self {
        Self { socket_path }
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
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
        serde_json::from_value(
            result
                .get("snapshot")
                .cloned()
                .ok_or_else(|| HerdrError::Protocol("snapshot result is missing".into()))?,
        )
        .map_err(|error| HerdrError::Protocol(error.to_string()))
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

    #[tokio::test]
    async fn requests_and_normalizes_a_fake_snapshot() {
        let socket = std::env::temp_dir().join(format!(
            "herdr-remote-keypad-test-{}-{}.sock",
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
                        "protocol": 16,
                        "version": "0.7.4",
                        "agents": [{
                            "pane_id": "w1:p1",
                            "agent": "codex",
                            "agent_status": "blocked",
                            "workspace_id": "w1"
                        }],
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
        server.await.unwrap();
        std::fs::remove_file(socket).unwrap();
    }
}
