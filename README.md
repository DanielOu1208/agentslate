# AgentSlate

<img src="docs/assets/agentslate-icon.png" alt="AgentSlate app icon" width="128">

**Remote control for Herdr.**

AgentSlate is an open-source iPhone companion for supervising coding agents running in [Herdr](https://herdr.dev/) on your Mac. It shows live agents and sessions, focuses the selected Herdr pane, and sends a small set of keys or short text while the terminal remains visible on another screen.

> AgentSlate is beta software. Use it only on agents you can see, and review every permission prompt before accepting it.

## What it does

- Connects directly to your Mac over your private Tailscale network.
- Pairs with a six-digit, single-use code instead of a shared token.
- Gives each iPhone its own revocable credential stored in Keychain.
- Shows Herdr sessions, agents, workspaces, and current states.
- Sends arrows, Enter, Escape, Tab, Shift+Tab, Space, and printable text.
- Offers watched-screen Accept and Deny shortcuts for supported agent defaults.
- Keeps dictation on the iPhone and sends only the resulting text.
- Includes an offline Demo Mode that never contacts a bridge.

AgentSlate does not stream terminal output, expose arbitrary shell commands, use analytics, or require a cloud account.

## Requirements

- A Mac running Herdr 0.7.4 or newer
- Tailscale on the Mac and iPhone
- iOS 26 or newer

## Install the Mac bridge

The Homebrew formula builds the Rust bridge from source:

```sh
brew install DanielOu1208/agentslate/agentslate
agentslate doctor
brew services start agentslate
```

Check the service at any time:

```sh
brew services info agentslate
agentslate doctor
```

AgentSlate listens only on loopback or Tailscale addresses. It does not offer a public or general-LAN listening mode.

## Pair an iPhone

1. Make sure Herdr, Tailscale, and the AgentSlate service are running on the Mac.
2. Create a pairing code:

   ```sh
   agentslate pair
   ```

3. In the iPhone app, enter the Mac's Tailscale address and the six-digit code.

The code expires after ten minutes, works once, and locks after five failed attempts. A successful pairing creates a separate device credential for that iPhone.

Manage paired phones from the Mac:

```sh
agentslate devices list
agentslate devices revoke DEVICE_ID
```

Use **Forget Bridge** in the iPhone app to revoke that phone and remove its local credentials. If the Mac is offline, AgentSlate clears the phone and explains how to revoke the remaining Mac record later.

## Run from source

Install Rust 1.85 or newer, then:

```sh
cargo build
cargo test
cargo run -- doctor
cargo run -- serve
```

Build the reusable Swift package:

```sh
swift build --package-path swift-client
swift test --package-path swift-client
```

Build and test the iPhone app with full Xcode:

```sh
xcodebuild test \
  -project ios/AgentSlate.xcodeproj \
  -scheme AgentSlate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest'
```

Do not send test input to an agent doing valuable work. Live input acceptance should use a disposable Herdr pane.

## Privacy, support, and security

- [Privacy policy](docs/privacy.md)
- [Support](docs/support.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

Public support belongs in [GitHub Issues](https://github.com/DanielOu1208/agentslate/issues). Report security problems privately through [GitHub Security Advisories](https://github.com/DanielOu1208/agentslate/security/advisories/new).

## Project documents

- [Product requirements](docs/PRD.md)
- [Protocol v3](docs/PROTOCOL.md)
- [Implementation tracker](docs/IMPLEMENTATION_TRACKER.md)
- [Release checklist and App Store metadata](docs/RELEASE_CHECKLIST.md)

## Non-affiliation

AgentSlate is an independent project. It is not affiliated with, endorsed by, or sponsored by Herdr, Tailscale, Apple, or the makers of the coding agents whose names and marks appear in the app. Those names and marks belong to their respective owners.

This project is also unrelated to the existing [pathupally/AgentSlate repository](https://github.com/pathupally/AgentSlate) and Random Labs' [Slate coding agent](https://www.ycombinator.com/companies/random-labs).

## License

AgentSlate is available under the [MIT License](LICENSE).
