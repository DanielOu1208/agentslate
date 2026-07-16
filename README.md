# Herdr Remote Keypad

Herdr Remote Keypad is an iPhone companion for controlling coding agents running in Herdr while the user watches the laptop or another display. The phone shows current agents and their states, lets the user choose a target, and sends a small set of keys or printable text through an authenticated Rust bridge.

This repository contains the working Rust bridge, command-line probe, reusable Swift networking package, and the first native SwiftUI iPhone keypad. Physical-iPhone acceptance is the remaining step for the current milestone.

## Current capabilities

- Authenticate over a private Tailscale TCP connection.
- Receive live Herdr agent names, workspaces, and states.
- Discover and switch between running named Herdr sessions on the connected Mac.
- Focus an agent's existing Herdr pane by tapping its phone button.
- Send arrows, Enter, Escape, Tab, Space, and printable text to a current agent.
- Report Herdr availability and recover after Herdr or the network becomes unavailable.
- Use the same protocol from the Rust probe or the Swift `HerdrRemoteClient` package.
- Configure the bridge manually on iPhone with Keychain-backed token storage.
- Select a Herdr session from the header, then select and focus a live agent from a four-column icon grid with compact working-folder labels.
- Hold the Voice key to dictate on-device; release to send text plus Enter to the selected agent.
- Use agent-aware Accept and Deny shortcuts for blocked Codex, Claude Code, OMP, Cursor, and OpenCode panes while watching the agent's screen.

Terminal output is intentionally not sent to the phone. The keypad is designed for use while the agent's screen remains visible elsewhere. Accept and Deny send each supported agent's default terminal shortcut; they do not inspect or identify the permission request, so they are a watched-screen convenience rather than verified authorization.

Voice prepares after an existing configuration loads, or after a new Bridge setup is saved and dismissed. The app requests microphone access only; speech recognition and its model stay on the iPhone. With VoiceOver, activate Voice once to start, activate it again to send, or use the Cancel dictation action.

## Build and test

Requirements:

- macOS with Rust 1.85 or newer
- Swift 6 or newer for builds; full Xcode for the standard Swift test runner
- Herdr 0.7.4 or newer running locally
- Tailscale for non-local connections
- iOS 26 or newer for the iPhone app's on-device speech support

```sh
cargo build
cargo test
swift build --package-path swift-client
```

With full Xcode installed:

```sh
swift test --package-path swift-client
```

Build and test the iOS app with Xcode or from the command line:

```sh
xcodebuild test \
  -project ios/HerdrRemoteKeypad.xcodeproj \
  -scheme HerdrRemoteKeypad \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

The Command Line Tools-only installation on this Mac keeps Swift Testing outside the default search paths. Use:

```sh
swift test --package-path swift-client \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

## Configure

Create the development credential once:

```sh
cargo run -- setup
```

The token is stored at `~/.config/herdr-remote-keypad/token` with owner-only permissions. The command never replaces an existing token.

## Run the bridge

The default command discovers the machine's Tailscale IPv4 address and listens on port `8765`:

```sh
cargo run -- serve
```

For a local-only test:

```sh
cargo run -- serve --listen 127.0.0.1:8765
```

Normal startup discovers running sessions with `herdr session list --json`. Use `--herdr-socket PATH` only for a fixed custom socket; this disables discovery and exposes one session named `custom`. The bridge intentionally ignores Herdr's inherited `HERDR_SOCKET_PATH` so starting it from inside a Herdr pane still discovers every session.

## Probe the bridge

The probe reads the same local token file by default:

```sh
cargo run -- probe --address 127.0.0.1:8765 sessions
cargo run -- probe --address 127.0.0.1:8765 list default
cargo run -- probe --address 127.0.0.1:8765 key default w1:p1 arrow_down
cargo run -- probe --address 127.0.0.1:8765 text default w1:p1 --submit "Continue with the simplest fix."
cargo run -- probe --address 127.0.0.1:8765 ping
```

Do not send test input to an agent doing valuable work. Automated input tests use a fake Herdr socket; live input acceptance uses a disposable pane.

## Documents

- [Product requirements](docs/PRD.md)
- [Bridge protocol v2](docs/PROTOCOL.md)
- [Implementation tracker](docs/IMPLEMENTATION_TRACKER.md)
