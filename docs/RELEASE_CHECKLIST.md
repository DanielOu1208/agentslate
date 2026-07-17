# AgentSlate 0.1.0 Release Checklist

The project owner has authorized preparation and publication of the open-source repository, Homebrew release, and external TestFlight beta. Production App Store submission and release remain explicitly out of scope.

## Release identity

- Product and App Store name: `AgentSlate`
- Subtitle: `Remote control for Herdr`
- Version: `0.1.0`
- Bundle ID: `com.danielou.HerdrRemoteKeypad` (retained internally to reuse the unpublished App Store Connect record)
- Repository: `DanielOu1208/agentslate`
- Homebrew tap: `DanielOu1208/homebrew-agentslate`
- Primary category: Developer Tools
- Secondary category: Utilities
- Age rating: 4+
- Price: Free
- In-app purchases: None
- Copyright: `2026 Daniel Ou`

Before any public release:

- [ ] Complete formal trademark clearance for `AgentSlate`.
- [x] Project owner reviewed the July 16, 2026 AgentSlate name-search conflict and explicitly chose to proceed with the name.
- [x] Project owner confirmed authorization to bundle the Factory Droid and Herdr marks; preserve the permission records with the release records.
- [x] Confirm the App Store Connect name can be reserved.
- [x] Record the owner's approval to publish the open-source repository, Homebrew release, and external TestFlight beta.

## Source and Homebrew release

- [x] Confirm the repository history contains no personal email, credentials, pairing codes, or machine-local files.
- [ ] Pass the full CI workflow.
- [x] Confirm `THIRD_PARTY_NOTICES.md` is available in the repository and the app's Acknowledgements screen.
- [x] Rename/configure the GitHub repository, description, and topics without changing visibility.
- [ ] Enable GitHub Pages when the repository becomes public.
- [ ] Create the `v0.1.0` source tag and archive only after approval.
- [ ] Replace the placeholder SHA-256 in `packaging/homebrew/agentslate.rb` with the published source archive checksum.
- [ ] Create `DanielOu1208/homebrew-agentslate` and copy the formula only after approval.
- [ ] Verify a clean install, `brew services` start/stop/restart, pairing, upgrade, and uninstall.
- [ ] Create GitHub release `v0.1.0` and make the repository public only after approval.

Do not publish to crates.io, attach binary downloads, create bottles, notarize a separate installer, or add a custom updater for 0.1.0.

Local release gates passed on July 16, 2026: Rust/Swift/iOS tests, static analysis, unsigned archive, App Store Connect–signed IPA export, privacy/notices/icon inspection, clean CLI source install, live Tailscale/Herdr doctor, and simulator onboarding/Demo Mode/settings review. Physical-iPhone acceptance and the hosted CI run remain open.

The owner chose to proceed with AgentSlate after reviewing the same-category naming conflict. Formal trademark clearance remains an independent owner responsibility.

## TestFlight metadata

### Beta App Information

- Beta app description:

  > AgentSlate is an iPhone remote control for coding agents running in Herdr on your Mac. Pair over Tailscale, select a visible agent, and send common keys, short text, or on-device dictation. This beta includes an offline Demo Mode.

- Feedback email: temporarily use the email attached to the Apple developer account.
- Privacy policy URL: `https://danielou1208.github.io/agentslate/privacy/`
- Beta license agreement: use Apple's standard agreement.

### TestFlight review information

- Contact first/last name and phone: use the App Store Connect account holder's current details.
- Sign-in required: No.
- Review notes:

  > AgentSlate normally connects to a Mac running Herdr over Tailscale. No account is required. For review without a Mac, open Demo Mode from onboarding; Demo Mode uses fixed sample agents and never makes a network connection. To test a real bridge, install the linked Homebrew formula on a Mac with Herdr and Tailscale, run `brew services start agentslate`, then run `agentslate pair` and enter the Mac's Tailscale address and six-digit code in the app. Microphone permission is used only for on-device dictation.

- What to test:

  > Please test onboarding and Demo Mode, session and agent selection, control labels and VoiceOver, reconnect behavior, on-device dictation, Forget Bridge, and watched-screen Accept/Deny gating for blocked agents.

### TestFlight steps

- [x] Rename and reuse the unpublished Herdr Remote Keypad App Store Connect record and its existing bundle ID.
- [x] Upload verified build `0.1.0 (3)`.
- [x] Complete export compliance.
- [ ] Complete privacy, beta description, feedback, and review fields required for external testing.
- [x] Reuse the `Internal Testers` group and enable build `0.1.0 (3)` for its one tester.
- [ ] Create the `AgentSlate Beta` external testing group.
- [ ] Add only the selected external testers.
- [ ] Submit the build only to TestFlight App Review.
- [ ] After approval, distribute to the selected external testers.
- [ ] Confirm a reviewer can install the approved external TestFlight build.
- [ ] Stop for owner review.

The first external build requires TestFlight App Review. Do not use Xcode's TestFlight Internal Only upload option for the external build.

## Production App Store metadata

### Description

> AgentSlate is a focused iPhone remote control for developers supervising coding agents in Herdr on a Mac.
>
> See live Herdr sessions and agents, focus the agent you are watching, and send common navigation keys or short instructions without reaching for the desktop keyboard. Hold Voice to dictate on-device, then send, cancel, or review the text before it leaves your phone.
>
> AgentSlate connects directly over your private Tailscale network. It has no AgentSlate account, cloud backend, analytics, advertising, or tracking. Each iPhone pairs with a short-lived code and receives its own revocable credential.
>
> A Mac running Herdr, Tailscale, and the free open-source AgentSlate bridge is required for live use. Offline Demo Mode is included.
>
> AgentSlate is an independent project and is not affiliated with or endorsed by Herdr, Tailscale, Apple, or any coding-agent vendor.

- Keywords: `Herdr,agents,developer,remote,keypad,Tailscale,coding,terminal,Swift,Rust`
- Support URL: `https://danielou1208.github.io/agentslate/support/`
- Marketing URL: `https://danielou1208.github.io/agentslate/`
- Privacy policy URL: `https://danielou1208.github.io/agentslate/privacy/`
- App privacy: Data Not Collected
- Tracking: No
- Encryption declaration: `ITSAppUsesNonExemptEncryption=NO`
- EU Digital Services Act: Non-trader
- Availability: Worldwide, with a future availability date
- Release option: Manually release this version

### 6.9-inch iPhone screenshots

Prepare three screenshots without real names, workspaces, prompts, IP addresses, or credentials:

1. **See every agent at a glance** — live dashboard with multiple sample states and a selected agent.
2. **Control the agent you are watching** — keypad, session picker, and clearly identified target.
3. **Speak, review, and send privately** — on-device dictation review or the offline Demo Mode.

Verify legibility, no placeholder status-bar artifacts, and consistent 6.9-inch dimensions before upload.

### Production draft stop

- [ ] Fill in all production metadata and upload the three screenshots.
- [ ] Select the verified build only when preparing the draft for owner review.
- [ ] Leave version `0.1.0` in **Prepare for Submission**.
- [ ] Do not click **Add for Review**, **Submit for Review**, or any production release action.
- [ ] Do not submit a production App Store version.

Production submission is a separate phase. After the beta, incorporate accepted fixes, bump to `1.0.0`, rerun release checks, and request explicit authorization before submitting anything to App Review.
