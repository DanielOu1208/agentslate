import AgentSlateClient
import CoreGraphics
import Testing

@testable import AgentSlate

@MainActor
@Test
func agentOrderingAndKeypadAvailability() {
  let model = AppModel(
    configuredHost: "", configuredCredential: nil, selectedSessionName: "default")
  let working = BridgeAgent(id: "working", kind: "codex", name: "Codex", status: .working)
  let blocked = BridgeAgent(id: "blocked", kind: "claude", name: "Claude", status: .blocked)

  model.apply(.sessions([BridgeSession(name: "default", isDefault: true)]))
  model.apply(.agents(session: "default", agents: [working, blocked]))
  #expect(model.displayAgents.map(\.id) == ["blocked", "working"])

  model.apply(.connectionState(.connected))
  model.apply(.herdrAvailability(session: "default", state: .connected))
  #expect(!model.canSend)

  model.apply(.agents(session: "default", agents: [blocked]))
  #expect(model.selectedAgentID == nil)
  #expect(!model.canSend)
  #expect(!model.canSendAction)
}

@Test
func approvalActionsRequireBlockedKnownAgents() {
  for kind in ["codex", "claude", "omp", "cursor", "opencode"] {
    let agent = BridgeAgent(id: kind, kind: kind, name: kind, status: .blocked)
    #expect(supportsRemoteActions(for: agent))
  }
  #expect(
    !supportsRemoteActions(
      for: BridgeAgent(id: "working", kind: "codex", name: "Codex", status: .working)))
  #expect(
    !supportsRemoteActions(
      for: BridgeAgent(id: "custom", kind: "custom", name: "Custom", status: .blocked)))
}

@Test
func agentIconAndFolderPresentation() {
  let expected = [
    "pi": "AgentPi", "omp": "AgentOMP", "copilot": "AgentCopilot",
    "devin": "AgentDevin", "kimi": "AgentKimi", "hermes": "AgentHermes",
    "qodercli": "AgentQoder", "droid": "AgentDroid", "opencode": "AgentOpenCode",
    "kilo": "AgentKilo", "mastracode": "AgentMastraCode", "claude": "AgentClaude",
    "codex": "AgentCodex", "cursor": "AgentCursor", "amp": "AgentAmp",
    "grok": "AgentGrok", "antigravity": "AgentAntigravity", "kiro": "AgentKiro",
    "maki": "AgentMaki", "gemini": "AgentGemini", "cline": "AgentCline",
  ]
  for (kind, asset) in expected {
    #expect(agentIconAssetName(for: kind) == asset)
  }
  #expect(agentIconAssetName(for: "custom") == nil)
  #expect(agentFolderName(cwd: "/projects/remote-keypad", workspace: "workspace") == "remote-keypad")
  #expect(agentFolderName(cwd: nil, workspace: "workspace") == "workspace")
  #expect(AgentStatus.working.label == "Thinking")
}

@MainActor
@Test
func sendAndVoiceAreGatedUntilAgentSelected() async {
  let model = AppModel(
    configuredHost: "", configuredCredential: nil, selectedSessionName: "default")
  model.apply(.sessions([BridgeSession(name: "default", isDefault: true)]))
  model.apply(.connectionState(.connected))
  model.apply(.herdrAvailability(session: "default", state: .connected))
  model.apply(
    .agents(
      session: "default",
      agents: [BridgeAgent(id: "a1", kind: "codex", name: "Codex", status: .blocked)])
  )
  #expect(!model.canSend)
  #expect(!model.canSendAction)
  #expect(model.voiceState == .notPrepared)

  await model.send(text: "hello", submit: true)
  #expect(model.successFeedback == 0)

  model.beginVoice()
  #expect(model.voiceState == .notPrepared)
}

@MainActor
@Test
func sessionSelectionRestoresAndFallsBackWithoutMacAction() {
  let model = AppModel(
    configuredHost: "", configuredCredential: nil, selectedSessionName: "team")
  let defaultSession = BridgeSession(name: "default", isDefault: true)
  let teamSession = BridgeSession(name: "team")
  let defaultAgent = BridgeAgent(
    id: "w1:p1", kind: "codex", name: "Default", status: .working)
  let teamAgent = BridgeAgent(id: "w1:p1", kind: "claude", name: "Team", status: .blocked)

  model.apply(.sessions([defaultSession, teamSession]))
  model.apply(.agents(session: "default", agents: [defaultAgent]))
  model.apply(.agents(session: "team", agents: [teamAgent]))
  #expect(model.selectedSessionName == "team")
  #expect(model.agents == [teamAgent])

  model.select(defaultSession)
  #expect(model.selectedSessionName == "default")
  #expect(model.agents == [defaultAgent])

  model.select(teamSession)
  model.apply(.sessions([defaultSession]))
  #expect(model.selectedSessionName == "default")
  #expect(model.agents == [defaultAgent])
}

@Test
func voiceTargetsUseTheirDisplayedRectangles() {
  let frames = VoiceTargetLayout.frames(
    in: CGSize(width: 390, height: 844),
    contentWidth: 354,
    gap: 12,
    targetHeight: 82
  )

  #expect(frames.cancel.size == frames.edit.size)
  #expect(frames.cancel.maxY + 12 + 82 + VoiceTargetLayout.bottomPadding == 844)
  #expect(
    VoiceReleaseAction.classify(
      CGPoint(x: frames.cancel.midX, y: frames.cancel.midY),
      cancelTarget: frames.cancel,
      editTarget: frames.edit
    ) == .cancel)
  #expect(
    VoiceReleaseAction.classify(
      CGPoint(x: frames.edit.midX, y: frames.edit.midY),
      cancelTarget: frames.cancel,
      editTarget: frames.edit
    ) == .edit)

  let cancelMinimumBoundary = CGPoint(x: frames.cancel.minX, y: frames.cancel.minY)
  let cancelMaximumBoundary = CGPoint(x: frames.cancel.maxX, y: frames.cancel.maxY)
  #expect(
    VoiceReleaseAction.classify(
      cancelMinimumBoundary, cancelTarget: frames.cancel, editTarget: frames.edit) == .cancel)
  #expect(
    VoiceReleaseAction.classify(
      cancelMaximumBoundary, cancelTarget: frames.cancel, editTarget: frames.edit) == .send)
}

@Test
func voiceTargetArmingReturnsToSendOutsideTargets() {
  let cancel = CGRect(x: 0, y: 0, width: 100, height: 100)
  let edit = CGRect(x: 120, y: 0, width: 100, height: 100)
  let locations = [
    CGPoint(x: 50, y: 50),
    CGPoint(x: 110, y: 50),
    CGPoint(x: 170, y: 50),
    CGPoint(x: 170, y: 110),
  ]
  let actions = locations.map {
    VoiceReleaseAction.classify($0, cancelTarget: cancel, editTarget: edit)
  }
  #expect(actions == [.cancel, .send, .edit, .send])
}

@Test
func voiceDraftTextNormalizesAndValidatesInput() {
  let normalized = validateVoiceDraftText("  first\r\nsecond\nthird  ")
  #expect(normalized.normalizedText == "first second third")
  #expect(normalized.isValid)

  #expect(validateVoiceDraftText(" \n \r ").issue == .blank)
  #expect(validateVoiceDraftText("hello\tworld").issue == .controlCharacters)
}

@Test
func voiceDraftTextCountsEmojiUTF8Bytes() {
  let atLimit = validateVoiceDraftText(String(repeating: "🙂", count: 2_048))
  #expect(atLimit.byteCount == 8_192)
  #expect(atLimit.isValid)

  let overLimit = validateVoiceDraftText(String(repeating: "🙂", count: 2_049))
  #expect(overLimit.byteCount == 8_196)
  #expect(overLimit.issue == .tooLarge)
}

@Test
func voiceDraftOnlyMatchesItsOriginalSelectedTarget() {
  let draft = VoiceDraft(
    text: "review me", agentID: "agent-1", agentName: "Codex", session: "default")
  #expect(draft.matches(agentID: "agent-1", session: "default", available: true))
  #expect(!draft.matches(agentID: "agent-2", session: "default", available: true))
  #expect(!draft.matches(agentID: "agent-1", session: "other", available: true))
  #expect(!draft.matches(agentID: "agent-1", session: "default", available: false))
}

@MainActor
@Test
func offlineDemoUsesFixedLocalStateAndAcknowledgesCommands() async {
  let model = AppModel(configuredHost: "", configuredCredential: nil)
  await model.activateDemoMode()

  #expect(model.isDemoMode)
  #expect(model.connectionLabel == "Demo Mode, offline")
  #expect(model.sessions.map(\.name) == ["Offline Demo"])
  #expect(model.agents.count == 5)
  #expect(!model.canSend)

  let agent = try! #require(model.agents.first)
  await model.select(agent)
  #expect(model.canSend)
  await model.send(.enter)
  #expect(model.successFeedback == 1)
  #expect(await model.send(text: "demo prompt"))
  #expect(model.successFeedback == 2)
}
