use agentslate::devices::{DeviceStore, default_state_dir};
use agentslate::herdr::{HerdrClient, discover_sessions};
use agentslate::server::{self, ServerConfig};
use std::collections::VecDeque;
use std::net::SocketAddr;
use std::path::PathBuf;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let mut arguments = std::env::args().skip(1).collect::<VecDeque<_>>();
    match arguments.pop_front().as_deref() {
        Some("pair") => pair(arguments),
        Some("devices") => devices(arguments),
        Some("doctor") => doctor(arguments).await,
        Some("serve") => serve(arguments).await,
        Some("help") | Some("--help") | Some("-h") | None => {
            println!("{}", usage());
            Ok(())
        }
        Some(command) => Err(format!("unknown command '{command}'\n\n{}", usage())),
    }
}

fn pair(mut arguments: VecDeque<String>) -> Result<(), String> {
    let state_dir =
        take_path_option(&mut arguments, "--state-dir")?.unwrap_or(default_state_dir()?);
    reject_remaining(arguments)?;
    let code = DeviceStore::new(state_dir).create_pairing()?;
    println!("Pairing code: {code}");
    println!("Expires in 10 minutes. The code can be used once.");
    Ok(())
}

fn devices(mut arguments: VecDeque<String>) -> Result<(), String> {
    let command = arguments
        .pop_front()
        .ok_or_else(|| format!("devices requires list or revoke\n\n{}", usage()))?;
    match command.as_str() {
        "list" => {
            let state_dir =
                take_path_option(&mut arguments, "--state-dir")?.unwrap_or(default_state_dir()?);
            reject_remaining(arguments)?;
            let devices = DeviceStore::new(state_dir).list()?;
            if devices.is_empty() {
                println!("No paired devices.");
            } else {
                for device in devices {
                    println!("{}\t{}\t{}", device.id, device.name, device.paired_at);
                }
            }
            Ok(())
        }
        "revoke" => {
            let device_id = arguments
                .pop_front()
                .ok_or("devices revoke requires DEVICE_ID")?;
            let state_dir =
                take_path_option(&mut arguments, "--state-dir")?.unwrap_or(default_state_dir()?);
            reject_remaining(arguments)?;
            if DeviceStore::new(state_dir).revoke(&device_id)? {
                println!("Revoked device {device_id}.");
                Ok(())
            } else {
                Err(format!("device {device_id} was not found"))
            }
        }
        _ => Err(format!("unknown devices command '{command}'")),
    }
}

async fn doctor(mut arguments: VecDeque<String>) -> Result<(), String> {
    let mut herdr_socket = None;
    let mut state_dir = None;
    while let Some(argument) = arguments.pop_front() {
        match argument.as_str() {
            "--herdr-socket" => {
                herdr_socket = Some(PathBuf::from(
                    arguments
                        .pop_front()
                        .ok_or("--herdr-socket requires a path")?,
                ));
            }
            "--state-dir" => {
                state_dir = Some(PathBuf::from(
                    arguments.pop_front().ok_or("--state-dir requires a path")?,
                ));
            }
            _ => return Err(format!("unknown doctor option '{argument}'")),
        }
    }

    let store = DeviceStore::new(state_dir.unwrap_or(default_state_dir()?));
    store.initialize()?;
    println!(
        "ok: private state directory {}",
        store.state_dir().display()
    );

    let tailscale = server::resolve_tailscale_command()?;
    let address = server::discover_tailscale_address(8765)?;
    server::validate_listen_address(address)?;
    println!(
        "ok: Tailscale CLI {} ({})",
        tailscale.display(),
        address.ip()
    );

    if let Some(socket) = herdr_socket {
        HerdrClient::new(socket.clone())
            .snapshot()
            .await
            .map_err(|error| format!("Herdr socket {} failed: {error}", socket.display()))?;
        println!("ok: Herdr socket {}", socket.display());
    } else {
        let sessions = discover_sessions()?;
        let session = sessions
            .first()
            .ok_or("Herdr reported no running sessions")?;
        HerdrClient::new(session.socket_path.clone())
            .snapshot()
            .await
            .map_err(|error| format!("Herdr session '{}' failed: {error}", session.name))?;
        println!("ok: Herdr session {}", session.name);
    }
    println!("AgentSlate is ready.");
    Ok(())
}

async fn serve(mut arguments: VecDeque<String>) -> Result<(), String> {
    let mut listen = None;
    let mut herdr_socket = None;
    let mut state_dir = None;
    while let Some(argument) = arguments.pop_front() {
        match argument.as_str() {
            "--listen" => {
                listen = Some(
                    arguments
                        .pop_front()
                        .ok_or("--listen requires IP:PORT")?
                        .parse::<SocketAddr>()
                        .map_err(|error| format!("invalid --listen value: {error}"))?,
                );
            }
            "--herdr-socket" => {
                herdr_socket = Some(PathBuf::from(
                    arguments
                        .pop_front()
                        .ok_or("--herdr-socket requires a path")?,
                ));
            }
            "--state-dir" => {
                state_dir = Some(PathBuf::from(
                    arguments.pop_front().ok_or("--state-dir requires a path")?,
                ));
            }
            _ => return Err(format!("unknown serve option '{argument}'")),
        }
    }
    server::run(ServerConfig {
        listen,
        herdr_socket,
        state_dir: state_dir.unwrap_or(default_state_dir()?),
    })
    .await
}

fn take_path_option(
    arguments: &mut VecDeque<String>,
    option: &str,
) -> Result<Option<PathBuf>, String> {
    match arguments.front().map(String::as_str) {
        Some(value) if value == option => {
            arguments.pop_front();
            Ok(Some(PathBuf::from(
                arguments
                    .pop_front()
                    .ok_or_else(|| format!("{option} requires a path"))?,
            )))
        }
        _ => Ok(None),
    }
}

fn reject_remaining(arguments: VecDeque<String>) -> Result<(), String> {
    if arguments.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "unexpected argument(s): {}",
            arguments.into_iter().collect::<Vec<_>>().join(" ")
        ))
    }
}

fn usage() -> &'static str {
    "AgentSlate — Remote control for Herdr\n\n\
Usage:\n\
  agentslate pair [--state-dir PATH]\n\
  agentslate devices list [--state-dir PATH]\n\
  agentslate devices revoke DEVICE_ID [--state-dir PATH]\n\
  agentslate doctor [--herdr-socket PATH] [--state-dir PATH]\n\
  agentslate serve [--listen IP:PORT] [--herdr-socket PATH] [--state-dir PATH]"
}
