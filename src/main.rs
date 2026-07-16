use herdr_remote_keypad::probe::{self, ProbeAction};
use herdr_remote_keypad::server::{self, ServerConfig};
use herdr_remote_keypad::token;
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
        Some("setup") => setup(arguments),
        Some("serve") => serve(arguments).await,
        Some("probe") => probe(arguments).await,
        Some("help") | Some("--help") | Some("-h") | None => {
            print_usage();
            Ok(())
        }
        Some(command) => Err(format!("unknown command '{command}'\n\n{}", usage())),
    }
}

fn setup(mut arguments: VecDeque<String>) -> Result<(), String> {
    let token_file =
        parse_path_option(&mut arguments, "--token-file")?.unwrap_or(token::default_token_path()?);
    reject_remaining(arguments)?;
    let created = token::initialize(&token_file)?;
    if created {
        println!(
            "Created private development token at {}",
            token_file.display()
        );
    } else {
        println!("Using existing token at {}", token_file.display());
    }
    println!("The token value is not printed. Keep this file private.");
    Ok(())
}

async fn serve(mut arguments: VecDeque<String>) -> Result<(), String> {
    let mut listen = None;
    let mut herdr_socket = None;
    let mut token_file = None;
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
            "--token-file" => {
                token_file = Some(PathBuf::from(
                    arguments
                        .pop_front()
                        .ok_or("--token-file requires a path")?,
                ));
            }
            _ => return Err(format!("unknown serve option '{argument}'")),
        }
    }
    server::run(ServerConfig {
        listen,
        herdr_socket: herdr_socket.unwrap_or(default_herdr_socket()?),
        token_file: token_file.unwrap_or(token::default_token_path()?),
    })
    .await
}

async fn probe(mut arguments: VecDeque<String>) -> Result<(), String> {
    let mut address = "127.0.0.1:8765".to_owned();
    let mut token_file = token::default_token_path()?;
    loop {
        match arguments.front().map(String::as_str) {
            Some("--address") => {
                arguments.pop_front();
                address = arguments
                    .pop_front()
                    .ok_or("--address requires HOST:PORT")?;
            }
            Some("--token-file") => {
                arguments.pop_front();
                token_file = PathBuf::from(
                    arguments
                        .pop_front()
                        .ok_or("--token-file requires a path")?,
                );
            }
            _ => break,
        }
    }

    let action = match arguments.pop_front().as_deref() {
        Some("list") => {
            reject_remaining(arguments)?;
            ProbeAction::List
        }
        Some("key") => {
            let agent_id = arguments.pop_front().ok_or("key requires AGENT_ID")?;
            let key = arguments.pop_front().ok_or("key requires KEY")?;
            reject_remaining(arguments)?;
            ProbeAction::Key { agent_id, key }
        }
        Some("text") => {
            let agent_id = arguments.pop_front().ok_or("text requires AGENT_ID")?;
            let submit = arguments.front().is_some_and(|value| value == "--submit");
            if submit {
                arguments.pop_front();
            }
            if arguments.is_empty() {
                return Err("text requires TEXT".into());
            }
            ProbeAction::Text {
                agent_id,
                text: arguments.into_iter().collect::<Vec<_>>().join(" "),
                submit,
            }
        }
        Some("ping") => {
            reject_remaining(arguments)?;
            ProbeAction::Ping
        }
        Some(command) => return Err(format!("unknown probe command '{command}'")),
        None => return Err(format!("probe requires a command\n\n{}", usage())),
    };
    probe::run(address, token_file, action).await
}

fn parse_path_option(
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

fn default_herdr_socket() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("HERDR_SOCKET_PATH") {
        return Ok(PathBuf::from(path));
    }
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(PathBuf::from(home)
        .join(".config")
        .join("herdr")
        .join("herdr.sock"))
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

fn print_usage() {
    println!("{}", usage());
}

fn usage() -> &'static str {
    "Herdr Remote Keypad connector\n\n\
Usage:\n\
  herdr-remote-keypad setup [--token-file PATH]\n\
  herdr-remote-keypad serve [--listen IP:PORT] [--herdr-socket PATH] [--token-file PATH]\n\
  herdr-remote-keypad probe [--address HOST:PORT] [--token-file PATH] list\n\
  herdr-remote-keypad probe [options] key AGENT_ID KEY\n\
  herdr-remote-keypad probe [options] text AGENT_ID [--submit] TEXT\n\
  herdr-remote-keypad probe [options] ping"
}
