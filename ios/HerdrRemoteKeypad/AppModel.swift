import Foundation
import HerdrRemoteClient
import Observation
import Security

enum VoiceState: Equatable {
  case notPrepared
  case preparing
  case ready
  case listening
  case finalizing
  case failed(String)
}

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
  private(set) var voiceState: VoiceState = .notPrepared
  private(set) var partialTranscript = ""

  @ObservationIgnored private var client: BridgeClient?
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private let dictation = VoiceDictationController()
  @ObservationIgnored private var voiceStartTask: Task<Void, Never>?
  @ObservationIgnored private var voiceEndInProgress = false
  @ObservationIgnored private var voiceCancelInProgress = false
  @ObservationIgnored private var voiceSessionGeneration = 0

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
    _ = connect(host: configuredHost, token: configuredToken, save: false)
  }

  @discardableResult
  func configure(host: String, token: String) -> Bool {
    connect(
      host: host.trimmingCharacters(in: .whitespacesAndNewlines),
      token: token.trimmingCharacters(in: .whitespacesAndNewlines),
      save: true
    )
  }

  func select(_ agent: BridgeAgent) async {
    guard let client else {
      report(BridgeError.notConnected)
      return
    }
    do {
      try await client.focus(agentID: agent.id)
      guard agents.contains(where: { $0.id == agent.id }) else { return }
      selectedAgentID = agent.id
      errorMessage = nil
    } catch {
      report(error)
    }
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

  func send(text: String, submit: Bool = true) async {
    guard canSend, let client, let selectedAgentID else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try await client.send(text: trimmed, submit: submit, to: selectedAgentID)
      errorMessage = nil
      successFeedback += 1
    } catch {
      report(error)
    }
  }

  func prepareVoice() async {
    guard
      voiceState != .preparing,
      voiceState != .ready,
      voiceState != .listening,
      voiceState != .finalizing
    else {
      return
    }

    partialTranscript = ""
    voiceState = .preparing
    do {
      try await dictation.prepare()
      try Task.checkCancellation()
      voiceState = .ready
    } catch is CancellationError {
      voiceState = .notPrepared
    } catch {
      handleVoiceFailure(error)
    }
  }

  func beginVoice() {
    guard
      canSend,
      voiceState == .ready,
      voiceStartTask == nil,
      !voiceEndInProgress,
      !voiceCancelInProgress
    else { return }
    voiceSessionGeneration &+= 1
    let generation = voiceSessionGeneration
    partialTranscript = ""
    voiceStartTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.dictation.start(
          onPartial: { [weak self] partial in
            guard let self, generation == self.voiceSessionGeneration else { return }
            self.partialTranscript = partial
          },
          onFailure: { [weak self] error in
            guard let self, generation == self.voiceSessionGeneration else { return }
            self.handleVoiceFailure(error)
          }
        )
        try Task.checkCancellation()
        guard generation == self.voiceSessionGeneration else {
          await self.dictation.cancel()
          return
        }
        self.voiceState = self.voiceEndInProgress ? .finalizing : .listening
      } catch is CancellationError {
        await self.dictation.cancel()
        if generation == self.voiceSessionGeneration {
          self.voiceState = self.dictation.isPrepared ? .ready : .notPrepared
        }
      } catch {
        if generation == self.voiceSessionGeneration {
          self.handleVoiceFailure(error)
        }
      }
      if generation == self.voiceSessionGeneration {
        self.voiceStartTask = nil
      }
    }
  }

  func endVoiceAndSend() async {
    guard
      !voiceEndInProgress,
      voiceState == .listening || voiceStartTask != nil
    else { return }
    voiceEndInProgress = true
    let generation = voiceSessionGeneration
    voiceState = .finalizing
    defer {
      if generation == voiceSessionGeneration {
        voiceEndInProgress = false
      }
    }

    if let voiceStartTask {
      await voiceStartTask.value
    }
    guard generation == voiceSessionGeneration, dictation.isListening else { return }
    do {
      let text = try await dictation.finalize()
      guard generation == voiceSessionGeneration, !Task.isCancelled else { return }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        await send(text: trimmed, submit: true)
      }
      guard generation == voiceSessionGeneration else { return }
      voiceState = .ready
      partialTranscript = ""
    } catch is CancellationError {
      if generation == voiceSessionGeneration {
        voiceState = dictation.isPrepared ? .ready : .notPrepared
      }
    } catch {
      if generation == voiceSessionGeneration {
        handleVoiceFailure(error)
      }
    }
  }

  func cancelVoice() async {
    guard
      !voiceCancelInProgress,
      voiceState == .listening || voiceState == .finalizing || voiceStartTask != nil
    else { return }
    voiceCancelInProgress = true
    defer { voiceCancelInProgress = false }
    voiceSessionGeneration &+= 1
    voiceEndInProgress = false
    voiceState = .finalizing
    let startTask = voiceStartTask
    startTask?.cancel()
    await startTask?.value
    await dictation.cancel()
    voiceStartTask = nil
    voiceState = dictation.isPrepared ? .ready : .notPrepared
    partialTranscript = ""
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

  private func handleVoiceFailure(_ error: any Error) {
    let failedState = VoiceState.failed(error.localizedDescription)
    partialTranscript = dictation.lastPartial
    if voiceState != failedState { errorFeedback += 1 }
    voiceState = failedState
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
