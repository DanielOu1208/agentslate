import HerdrRemoteClient
import Testing

@testable import HerdrRemoteKeypad

@MainActor
@Test
func agentOrderingAndKeypadAvailability() {
  let model = AppModel(configuredHost: "", configuredToken: "")
  let working = BridgeAgent(id: "working", name: "Codex", status: .working)
  let blocked = BridgeAgent(id: "blocked", name: "Claude", status: .blocked)

  model.apply(.agents([working, blocked]))
  #expect(model.displayAgents.map(\.id) == ["blocked", "working"])

  model.apply(.connectionState(.connected))
  model.apply(.herdrAvailability(.connected))
  #expect(!model.canSend)

  model.apply(.agents([blocked]))
  #expect(model.selectedAgentID == nil)
  #expect(!model.canSend)
}
