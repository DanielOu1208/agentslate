import HerdrRemoteClient
import Testing

@testable import HerdrRemoteKeypad

@MainActor
@Test
func agentOrderingAndKeypadAvailability() {
  let model = AppModel(configuredHost: "", configuredToken: "")
  let working = BridgeAgent(id: "working", kind: "codex", name: "Codex", status: .working)
  let blocked = BridgeAgent(id: "blocked", kind: "claude", name: "Claude", status: .blocked)

  model.apply(.agents([working, blocked]))
  #expect(model.displayAgents.map(\.id) == ["blocked", "working"])

  model.apply(.connectionState(.connected))
  model.apply(.herdrAvailability(.connected))
  #expect(!model.canSend)

  model.apply(.agents([blocked]))
  #expect(model.selectedAgentID == nil)
  #expect(!model.canSend)
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
}
