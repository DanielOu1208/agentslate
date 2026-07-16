import Foundation
import HerdrRemoteClient
import Observation
import Security

@MainActor
@Observable
final class AppModel {
  private(set) var connectionState: ConnectionState = .stopped
  private(set) var herdrAvailability: HerdrAvailability = .unavailable
  private(set) var agents: [BridgeAgent] = []
  private(set) var selectedAgentID: String?
  private(set) var errorMessage: String?
  private(set) var successFeedback = 0
  private(set) var errorFeedback = 0
  private(set) var configuredHost: String
  private(set) var configuredToken: String

  @ObservationIgnored private var client: BridgeClient?
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var started = false

  init(
    configuredHost: String = UserDefaults.standard.string(forKey: "bridgeHost") ?? "",
    configuredToken: String = TokenStore.load()
  ) {
    self.configuredHost = configuredHost
    self.configuredToken = configuredToken
  }

  var hasConfiguration: Bool {
    !configuredHost.isEmpty && configuredToken.count == 64
  }

  var displayAgents: [BridgeAgent] {
    agents.filter { $0.status == .blocked } + agents.filter { $0.status != .blocked }
  }

  var selectedAgent: BridgeAgent? {
    agents.first { $0.id == selectedAgentID }
  }

  var canSend: Bool {
    connectionState == .connected
      && herdrAvailability == .connected
      && selectedAgent != nil
  }

  var connectionLabel: String {
    switch (connectionState, herdrAvailability) {
    case (.connected, .connected): "Connected"
    case (.connected, .unavailable): "Herdr unavailable"
    case (.connecting, _): "Connecting"
    case (.authenticating, _): "Authenticating"
    case (.reconnecting(let attempt), _): "Reconnecting \(attempt)"
    case (.stopped, _): "Disconnected"
    }
  }

  func start() {
    guard !started else { return }
    started = true
    guard hasConfiguration else { return }
    connect(host: configuredHost, token: configuredToken, save: false)
  }

  @discardableResult
  func configure(host: String, token: String) -> Bool {
    connect(
      host: host.trimmingCharacters(in: .whitespacesAndNewlines),
      token: token.trimmingCharacters(in: .whitespacesAndNewlines),
      save: true
    )
  }

  func select(_ agent: BridgeAgent) {
    selectedAgentID = agent.id
  }

  func send(_ key: RemoteKey) async {
    guard canSend, let client, let selectedAgentID else { return }
    do {
      try await client.send(key: key, to: selectedAgentID)
      errorMessage = nil
      successFeedback += 1
    } catch {
      report(error)
    }
  }

  func apply(_ event: BridgeEvent) {
    switch event {
    case .connectionState(let state):
      connectionState = state
      if state != .connected { herdrAvailability = .unavailable }
    case .herdrAvailability(let availability):
      herdrAvailability = availability
    case .agents(let snapshot):
      agents = snapshot
      if let selectedAgentID, !snapshot.contains(where: { $0.id == selectedAgentID }) {
        self.selectedAgentID = nil
      }
    case .error(let error):
      report(error)
    }
  }

  private func connect(host: String, token: String, save: Bool) -> Bool {
    do {
      let newClient = try BridgeClient(host: host, token: token)
      if save {
        try TokenStore.save(token)
        UserDefaults.standard.set(host, forKey: "bridgeHost")
        configuredHost = host
        configuredToken = token
      }

      eventTask?.cancel()
      if let client { Task { await client.stop() } }
      client = newClient
      connectionState = .connecting
      herdrAvailability = .unavailable
      errorMessage = nil
      eventTask = Task { [weak self, newClient] in
        await newClient.start()
        for await event in newClient.events {
          guard !Task.isCancelled else { break }
          self?.apply(event)
        }
      }
      return true
    } catch {
      report(error)
      return false
    }
  }

  private func report(_ error: any Error) {
    errorMessage = error.localizedDescription
    errorFeedback += 1
  }
}

private enum TokenStore {
  private static let service = "com.danielou.HerdrRemoteKeypad.bridge"
  private static let account = "bridge-token"

  static func load() -> String {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ] as CFDictionary,
      &item
    )
    guard status == errSecSuccess, let data = item as? Data else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  static func save(_ token: String) throws {
    let query =
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
      ] as CFDictionary
    let data = Data(token.utf8)
    let status = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw keychainError(status) }

    let addStatus = SecItemAdd(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecValueData: data,
      ] as CFDictionary,
      nil
    )
    guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
  }

  private static func keychainError(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status))
  }
}
