import HerdrRemoteClient
import Testing

@testable import HerdrRemoteKeypad

@MainActor
@Test
func agentOrderingAndKeypadAvailability() {
  let model = AppModel(configuredHost: "", configuredToken: "", selectedSessionName: "default")
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
  let model = AppModel(configuredHost: "", configuredToken: "", selectedSessionName: "default")
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
  let model = AppModel(configuredHost: "", configuredToken: "", selectedSessionName: "team")
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
