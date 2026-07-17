# Contributing to AgentSlate

Thanks for helping improve AgentSlate.

## Before opening a change

- Use [GitHub Issues](https://github.com/DanielOu1208/agentslate/issues) for bugs and focused feature proposals.
- Use [GitHub Security Advisories](https://github.com/DanielOu1208/agentslate/security/advisories/new), not a public issue, for security reports.
- Keep changes narrow. AgentSlate intentionally has no cloud backend, telemetry, public-network mode, or terminal streaming.

## Development

Requirements are Rust 1.85 or newer, Swift 6 or newer, and full Xcode for iOS tests.

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
swift test --package-path swift-client
xcodebuild test \
  -project ios/AgentSlate.xcodeproj \
  -scheme AgentSlate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest'
```

Add the smallest test that would fail without a non-trivial behavior change. Never include pairing codes, device credentials, personal paths, Xcode user data, or real agent input in commits or logs.

## Pull requests

Describe the user-visible change, the checks you ran, and any physical-iPhone validation still pending. Update the README, protocol, or tracker when behavior changes. By contributing, you agree that your contribution is licensed under this repository's MIT License.
