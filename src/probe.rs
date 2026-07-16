use crate::protocol::{MAX_CLIENT_LINE_BYTES, PROTOCOL_VERSION, read_frame};
use crate::token;
use serde_json::{Value, json};
use std::path::PathBuf;
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::TcpStream;

pub enum ProbeAction {
    Sessions,
    List {
        session: String,
    },
    Key {
        session: String,
        agent_id: String,
        key: String,
    },
    Text {
        session: String,
        agent_id: String,
        text: String,
        submit: bool,
    },
    Ping,
}

pub async fn run(address: String, token_file: PathBuf, action: ProbeAction) -> Result<(), String> {
    let token = token::read(&token_file)?;
    let stream = TcpStream::connect(&address)
        .await
        .map_err(|error| format!("cannot connect to {address}: {error}"))?;
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    write(
        &mut write_half,
        json!({
            "version": PROTOCOL_VERSION,
            "id": "auth",
            "type": "authenticate",
            "token": token
        }),
    )
    .await?;
    let authentication = read_value(&mut reader).await?;
    if authentication["type"] != "authenticated" {
        return Err(format!("authentication failed: {authentication}"));
    }

    let (id, request) = match action {
        ProbeAction::Sessions => loop {
            let value = read_value(&mut reader).await?;
            if value["type"] == "session_snapshot" {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&value).map_err(|error| error.to_string())?
                );
                return Ok(());
            }
        },
        ProbeAction::List { session } => (
            "list",
            json!({
                "version": PROTOCOL_VERSION,
                "id": "list",
                "type": "request_snapshot",
                "session": session
            }),
        ),
        ProbeAction::Key {
            session,
            agent_id,
            key,
        } => (
            "key",
            json!({
                "version": PROTOCOL_VERSION,
                "id": "key",
                "type": "send_key",
                "session": session,
                "agent_id": agent_id,
                "key": key
            }),
        ),
        ProbeAction::Text {
            session,
            agent_id,
            text,
            submit,
        } => (
            "text",
            json!({
                "version": PROTOCOL_VERSION,
                "id": "text",
                "type": "send_text",
                "session": session,
                "agent_id": agent_id,
                "text": text,
                "submit": submit
            }),
        ),
        ProbeAction::Ping => (
            "ping",
            json!({"version": PROTOCOL_VERSION, "id": "ping", "type": "ping"}),
        ),
    };
    write(&mut write_half, request).await?;

    loop {
        let value = read_value(&mut reader).await?;
        println!(
            "{}",
            serde_json::to_string_pretty(&value).map_err(|error| error.to_string())?
        );
        if value.get("id").and_then(Value::as_str) == Some(id) {
            return if value["type"] == "error" {
                Err(format!("probe request failed: {}", value["code"]))
            } else {
                Ok(())
            };
        }
    }
}

async fn write(writer: &mut tokio::net::tcp::OwnedWriteHalf, value: Value) -> Result<(), String> {
    let mut bytes = serde_json::to_vec(&value).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    writer
        .write_all(&bytes)
        .await
        .map_err(|error| error.to_string())
}

async fn read_value(
    reader: &mut BufReader<tokio::net::tcp::OwnedReadHalf>,
) -> Result<Value, String> {
    let line = read_frame(reader, MAX_CLIENT_LINE_BYTES)
        .await
        .map_err(|error| error.to_string())?
        .ok_or("bridge closed the connection")?;
    serde_json::from_str(&line).map_err(|error| error.to_string())
}
