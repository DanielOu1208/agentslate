use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufRead, AsyncBufReadExt};

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_CLIENT_LINE_BYTES: usize = 65_536;
pub const MAX_HERDR_LINE_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_REQUEST_ID_BYTES: usize = 128;
pub const MAX_TEXT_BYTES: usize = 8_192;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Authenticate {
        version: u32,
        id: String,
        token: String,
    },
    RequestSnapshot {
        version: u32,
        id: String,
    },
    FocusAgent {
        version: u32,
        id: String,
        agent_id: String,
    },
    SendKey {
        version: u32,
        id: String,
        agent_id: String,
        key: String,
    },
    SendText {
        version: u32,
        id: String,
        agent_id: String,
        text: String,
        submit: bool,
    },
    SendAction {
        version: u32,
        id: String,
        agent_id: String,
        action: RemoteAction,
    },
    Ping {
        version: u32,
        id: String,
    },
}

impl ClientMessage {
    pub fn version(&self) -> u32 {
        match self {
            Self::Authenticate { version, .. }
            | Self::RequestSnapshot { version, .. }
            | Self::FocusAgent { version, .. }
            | Self::SendKey { version, .. }
            | Self::SendText { version, .. }
            | Self::SendAction { version, .. }
            | Self::Ping { version, .. } => *version,
        }
    }

    pub fn id(&self) -> &str {
        match self {
            Self::Authenticate { id, .. }
            | Self::RequestSnapshot { id, .. }
            | Self::FocusAgent { id, .. }
            | Self::SendKey { id, .. }
            | Self::SendText { id, .. }
            | Self::SendAction { id, .. }
            | Self::Ping { id, .. } => id,
        }
    }

    pub fn validate_envelope(&self) -> Result<(), &'static str> {
        if self.version() != PROTOCOL_VERSION {
            return Err("unsupported_version");
        }
        if self.id().is_empty() || self.id().len() > MAX_REQUEST_ID_BYTES {
            return Err("invalid_message");
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RemoteAction {
    Accept,
    Deny,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Agent {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub status: String,
    pub title: Option<String>,
    pub workspace: Option<String>,
    pub cwd: Option<String>,
}

pub fn herdr_key(key: &str) -> Option<&'static str> {
    match key {
        "arrow_up" => Some("up"),
        "arrow_down" => Some("down"),
        "arrow_left" => Some("left"),
        "arrow_right" => Some("right"),
        "enter" => Some("enter"),
        "escape" => Some("esc"),
        "tab" => Some("tab"),
        "shift_tab" => Some("shift+tab"),
        "space" => Some("space"),
        _ => None,
    }
}

pub fn remote_action_keys(
    agent_kind: &str,
    action: RemoteAction,
) -> Option<&'static [&'static str]> {
    match (agent_kind, action) {
        ("codex" | "cursor", RemoteAction::Accept) => Some(&["y"]),
        ("codex" | "cursor", RemoteAction::Deny) => Some(&["n"]),
        ("claude" | "omp" | "opencode", RemoteAction::Accept) => Some(&["enter"]),
        ("claude" | "omp", RemoteAction::Deny) => Some(&["esc"]),
        ("opencode", RemoteAction::Deny) => Some(&["esc", "enter"]),
        _ => None,
    }
}

pub fn validate_text(text: &str) -> Result<(), &'static str> {
    if text.len() > MAX_TEXT_BYTES || text.chars().any(char::is_control) {
        return Err("invalid_text");
    }
    Ok(())
}

pub async fn read_frame<R>(reader: &mut R, max_bytes: usize) -> std::io::Result<Option<String>>
where
    R: AsyncBufRead + Unpin,
{
    let mut bytes = Vec::new();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            if bytes.is_empty() {
                return Ok(None);
            }
            break;
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let take = newline.map_or(available.len(), |index| index + 1);
        if bytes.len() + take > max_bytes {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "JSON line exceeds size limit",
            ));
        }
        bytes.extend_from_slice(&available[..take]);
        reader.consume(take);
        if newline.is_some() {
            bytes.pop();
            if bytes.last() == Some(&b'\r') {
                bytes.pop();
            }
            break;
        }
    }

    String::from_utf8(bytes)
        .map(Some)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_only_the_nine_safe_keys() {
        assert_eq!(herdr_key("arrow_up"), Some("up"));
        assert_eq!(herdr_key("escape"), Some("esc"));
        assert_eq!(herdr_key("shift_tab"), Some("shift+tab"));
        assert_eq!(herdr_key("ctrl_c"), None);
        assert_eq!(herdr_key("a"), None);
    }

    #[test]
    fn text_rejects_controls_and_oversized_payloads() {
        assert!(validate_text("Use the smallest fix 👍").is_ok());
        assert_eq!(validate_text("submit\nnow"), Err("invalid_text"));
        assert_eq!(
            validate_text(&"x".repeat(MAX_TEXT_BYTES + 1)),
            Err("invalid_text")
        );
    }

    #[test]
    fn maps_remote_actions_for_supported_agents() {
        let cases: &[(&str, RemoteAction, &[&str])] = &[
            ("codex", RemoteAction::Accept, &["y"]),
            ("codex", RemoteAction::Deny, &["n"]),
            ("claude", RemoteAction::Accept, &["enter"]),
            ("claude", RemoteAction::Deny, &["esc"]),
            ("omp", RemoteAction::Accept, &["enter"]),
            ("omp", RemoteAction::Deny, &["esc"]),
            ("cursor", RemoteAction::Accept, &["y"]),
            ("cursor", RemoteAction::Deny, &["n"]),
            ("opencode", RemoteAction::Accept, &["enter"]),
            ("opencode", RemoteAction::Deny, &["esc", "enter"]),
        ];
        for (kind, action, keys) in cases {
            assert_eq!(remote_action_keys(kind, *action), Some(*keys));
        }
        assert_eq!(remote_action_keys("unknown", RemoteAction::Accept), None);
    }
}
