import Foundation
import AgentSlateClient
import Observation
import Security
import UIKit

enum VoiceState: Equatable {
  case notPrepared
  case preparing
  case ready
  case starting
  case listening
  case finalizing
  case failed(String)
}

enum VoiceReleaseAction: Equatable {
  case send
  case cancel
  case edit

  static func classify(
    _ location: CGPoint, cancelTarget: CGRect, editTarget: CGRect
  ) -> Self {
    if cancelTarget.contains(location) { return .cancel }
    if editTarget.contains(location) { return .edit }
    return .send
  }
}

struct VoiceDraft: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let agentID: String
  let agentName: String
  let session: String

  func matches(agentID: String?, session: String?, available: Bool) -> Bool {
    available && self.agentID == agentID && self.session == session
  }
}

enum VoiceTextIssue: Equatable {
  case blank
  case controlCharacters
  case tooLarge
}

enum ForgetBridgeResult: Equatable {
  case revoked
  case localOnly
  case failed(String)
}

struct VoiceTextValidation: Equatable {
  let normalizedText: String
  let byteCount: Int
  let issue: VoiceTextIssue?

  var isValid: Bool { issue == nil }
}

func validateVoiceDraftText(_ text: String) -> VoiceTextValidation {
  var normalized = ""
  var previousWasCarriageReturn = false
  for scalar in text.unicodeScalars {
    if CharacterSet.newlines.contains(scalar) {
      if !(scalar.value == 10 && previousWasCarriageReturn) { normalized.append(" ") }
      previousWasCarriageReturn = scalar.value == 13
    } else {
      normalized.unicodeScalars.append(scalar)
      previousWasCarriageReturn = false
    }
  }
  normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
  let byteCount = normalized.utf8.count
  let issue: VoiceTextIssue? =
    if normalized.isEmpty {
      .blank
    } else if normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
      .controlCharacters
    } else if byteCount > 8_192 {
      .tooLarge
    } else {
      nil
    }
  return VoiceTextValidation(normalizedText: normalized, byteCount: byteCount, issue: issue)
}

@MainActor
@Observable
final class AppModel {
  private(set) var connectionState: ConnectionState = .stopped
  private(set) var herdrAvailability: HerdrAvailability = .unavailable
  private(set) var sessions: [BridgeSession] = []
  private(set) var selectedSessionName: String?
  private(set) var agents: [BridgeAgent] = []
  private(set) var selectedAgentID: String?
  private(set) var errorMessage: String?
  private(set) var successFeedback = 0
  private(set) var errorFeedback = 0
  private(set) var configuredHost: String
  private(set) var configuredCredential: BridgeCredential?
  private(set) var isPairing = false
  private(set) var isDemoMode = false
  private(set) var voiceState: VoiceState = .notPrepared
  private(set) var partialTranscript = ""
  private(set) var voiceDraft: VoiceDraft?

  @ObservationIgnored private var client: BridgeClient?
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private let dictation = VoiceDictationController()
  @ObservationIgnored private var voiceStartTask: Task<Void, Never>?
  @ObservationIgnored private var voiceEndInProgress = false
  @ObservationIgnored private var voiceCancelInProgress = false
  @ObservationIgnored private var voiceSessionGeneration = 0
  @ObservationIgnored private var voiceTarget: (agentID: String, agentName: String, session: String)?
  @ObservationIgnored private var agentsBySession: [String: [BridgeAgent]] = [:]
  @ObservationIgnored private var availabilityBySession: [String: HerdrAvailability] = [:]

  init(
    configuredHost: String = UserDefaults.standard.string(forKey: "bridgeHost") ?? "",
    configuredCredential: BridgeCredential? = CredentialStore.load(),
    selectedSessionName: String? = UserDefaults.standard.string(forKey: "selectedHerdrSession")
  ) {
    self.configuredHost = configuredHost
    self.configuredCredential = configuredCredential
    self.selectedSessionName = selectedSessionName
  }

  var hasConfiguration: Bool {
    !configuredHost.isEmpty && configuredCredential != nil
  }

  var displayAgents: [BridgeAgent] {
    agents.filter { $0.status == .blocked } + agents.filter { $0.status != .blocked }
  }

  var selectedAgent: BridgeAgent? {
    agents.first { $0.id == selectedAgentID }
  }

  var canSend: Bool {
    (isDemoMode || connectionState == .connected)
      && herdrAvailability == .connected
      && selectedAgent != nil
  }

  var canSendAction: Bool {
    guard canSend, let selectedAgent else { return false }
    return supportsRemoteActions(for: selectedAgent)
  }

  var connectionLabel: String {
    if isDemoMode { return "Demo Mode, offline" }
    if connectionState == .connected, selectedSessionName == nil {
      return "No Herdr sessions"
    }
    return switch (connectionState, herdrAvailability) {
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
    guard let configuredCredential, hasConfiguration else { return }
    _ = connect(host: configuredHost, credential: configuredCredential)
  }

  @discardableResult
  func pair(host: String, code: String, deviceName: String = UIDevice.current.name) async -> Bool {
    guard !hasConfiguration else {
      errorMessage = "Forget the current bridge before pairing with another Mac."
      errorFeedback += 1
      return false
    }
    guard !isPairing else { return false }
    isPairing = true
    defer { isPairing = false }
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let credential = try await BridgeClient.pair(
        host: host,
        code: code,
        deviceName: deviceName
      )
      try CredentialStore.save(credential)
      UserDefaults.standard.set(host, forKey: "bridgeHost")
      configuredHost = host
      configuredCredential = credential
      return connect(host: host, credential: credential)
    } catch {
      report(error)
      return false
    }
  }

  func activateDemoMode() async {
    await stopClientAndWait()
    isDemoMode = true
    connectionState = .connected
    herdrAvailability = .connected
    let session = BridgeSession(name: "Offline Demo", isDefault: true)
    sessions = [session]
    selectedSessionName = session.name
    agents = Self.demoAgents
    agentsBySession = [session.name: agents]
    availabilityBySession = [session.name: .connected]
    selectedAgentID = nil
    errorMessage = nil
  }

  func forgetBridge() async -> ForgetBridgeResult {
    let revoked: Bool
    if !isDemoMode, connectionState == .connected, let client {
      do {
        try await client.revokeSelf()
        revoked = true
      } catch {
        revoked = false
      }
    } else {
      revoked = false
    }

    do {
      try CredentialStore.delete()
    } catch {
      report(error)
      return .failed(error.localizedDescription)
    }

    await stopClientAndWait()
    isDemoMode = false
    configuredHost = ""
    configuredCredential = nil
    UserDefaults.standard.removeObject(forKey: "bridgeHost")
    UserDefaults.standard.removeObject(forKey: "selectedHerdrSession")
    resetBridgeState()
    errorMessage = nil
    return revoked ? .revoked : .localOnly
  }

  func select(_ agent: BridgeAgent) async {
    if isDemoMode {
      guard agents.contains(agent) else { return }
      selectedAgentID = agent.id
      errorMessage = nil
      return
    }
    guard let client, let session = selectedSessionName else {
      report(BridgeError.notConnected)
      return
    }
    do {
      try await client.focus(agentID: agent.id, session: session)
      guard selectedSessionName == session,
        agents.contains(where: { $0.id == agent.id })
      else { return }
      selectedAgentID = agent.id
      errorMessage = nil
    } catch {
      report(error)
    }
  }

  func select(_ session: BridgeSession) {
    guard sessions.contains(session) else { return }
    activateSession(session.name)
  }

  func send(_ key: RemoteKey) async {
    if isDemoMode, canSend {
      successFeedback += 1
      return
    }
    guard canSend, let client, let selectedAgentID, let session = selectedSessionName else {
      return
    }
    do {
      try await client.send(key: key, to: selectedAgentID, session: session)
      errorMessage = nil
      successFeedback += 1
    } catch {
      report(error)
    }
  }

  func send(_ action: RemoteAction) async {
    if isDemoMode, canSendAction {
      successFeedback += 1
      return
    }
    guard canSendAction, let client, let selectedAgentID, let session = selectedSessionName else {
      return
    }
    do {
      try await client.send(action: action, to: selectedAgentID, session: session)
      errorMessage = nil
      successFeedback += 1
    } catch {
      report(error)
    }
  }

  @discardableResult
  func send(text: String, submit: Bool = true) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if isDemoMode, canSend {
      successFeedback += 1
      return true
    }
    guard canSend, let client, let selectedAgentID, let session = selectedSessionName else {
      return false
    }
    return await send(
      text: trimmed, submit: submit, to: selectedAgentID, session: session, client: client)
  }

  @discardableResult
  func sendVoiceDraft(_ draft: VoiceDraft, text: String) async -> Bool {
    let validation = validateVoiceDraftText(text)
    guard validation.isValid,
      draft.matches(
        agentID: selectedAgentID, session: selectedSessionName, available: canSend)
    else { return false }
    if isDemoMode {
      successFeedback += 1
      return true
    }
    guard let client else { return false }
    return await send(
      text: validation.normalizedText,
      submit: true,
      to: draft.agentID,
      session: draft.session,
      client: client
    )
  }

  func discardVoiceDraft() {
    voiceDraft = nil
  }

  private func send(
    text: String,
    submit: Bool,
    to agentID: String,
    session: String,
    client: BridgeClient
  ) async -> Bool {
    do {
      try await client.send(
        text: text, submit: submit, to: agentID, session: session)
      errorMessage = nil
      successFeedback += 1
      return true
    } catch {
      report(error)
      return false
    }
  }

  func prepareVoice() async {
    guard
      voiceState != .preparing,
      voiceState != .ready,
      voiceState != .starting,
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
      let selectedAgent,
      let selectedSessionName,
      voiceState == .ready,
      voiceStartTask == nil,
      !voiceEndInProgress,
      !voiceCancelInProgress
    else { return }
    voiceSessionGeneration &+= 1
    let generation = voiceSessionGeneration
    partialTranscript = ""
    voiceTarget = (selectedAgent.id, selectedAgent.name, selectedSessionName)
    voiceState = .starting
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

  func finishVoice(_ action: VoiceReleaseAction) async {
    if action == .cancel {
      await cancelVoice()
      return
    }
    guard
      !voiceEndInProgress,
      voiceState == .starting || voiceState == .listening || voiceStartTask != nil
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
      if let voiceTarget {
        if action == .edit {
          voiceDraft = VoiceDraft(
            text: trimmed,
            agentID: voiceTarget.agentID,
            agentName: voiceTarget.agentName,
            session: voiceTarget.session
          )
        } else if !trimmed.isEmpty,
          canSend,
          selectedAgentID == voiceTarget.agentID,
          selectedSessionName == voiceTarget.session
        {
          if isDemoMode {
            successFeedback += 1
          } else if let client {
            _ = await send(
              text: trimmed,
              submit: true,
              to: voiceTarget.agentID,
              session: voiceTarget.session,
              client: client
            )
          }
        }
      }
      guard generation == voiceSessionGeneration else { return }
      voiceState = .ready
      partialTranscript = ""
      voiceTarget = nil
    } catch is CancellationError {
      if generation == voiceSessionGeneration {
        voiceState = dictation.isPrepared ? .ready : .notPrepared
        voiceTarget = nil
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
      voiceState == .starting || voiceState == .listening || voiceState == .finalizing
        || voiceStartTask != nil
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
    voiceTarget = nil
  }

  func apply(_ event: BridgeEvent) {
    guard !isDemoMode else { return }
    switch event {
    case .connectionState(let state):
      connectionState = state
      if state != .connected { herdrAvailability = .unavailable }
    case .sessions(let snapshot):
      sessions = snapshot
      let names = Set(snapshot.map(\.name))
      agentsBySession = agentsBySession.filter { names.contains($0.key) }
      availabilityBySession = availabilityBySession.filter { names.contains($0.key) }

      if let selectedSessionName, names.contains(selectedSessionName) {
        refreshSelectedSession()
      } else if let fallback = snapshot.first(where: \.isDefault) ?? snapshot.first {
        activateSession(fallback.name)
      } else {
        activateSession(nil)
      }
    case .herdrAvailability(let session, let availability):
      availabilityBySession[session] = availability
      if session == selectedSessionName { herdrAvailability = availability }
    case .agents(let session, let snapshot):
      agentsBySession[session] = snapshot
      if session == selectedSessionName {
        agents = snapshot
        if let selectedAgentID, !snapshot.contains(where: { $0.id == selectedAgentID }) {
          self.selectedAgentID = nil
        }
      }
    case .error(let error):
      report(error)
    }
  }

  private func connect(host: String, credential: BridgeCredential) -> Bool {
    do {
      let newClient = try BridgeClient(host: host, credential: credential)

      stopClient()
      isDemoMode = false
      client = newClient
      let preferredSession = selectedSessionName
      resetBridgeState()
      selectedSessionName = preferredSession
      connectionState = .connecting
      errorMessage = nil
      eventTask = Task { [weak self, newClient] in
        guard !Task.isCancelled else { return }
        await newClient.start()
        guard !Task.isCancelled else {
          await newClient.stop()
          return
        }
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

  private func stopClient() {
    eventTask?.cancel()
    eventTask = nil
    if let client { Task { await client.stop() } }
    client = nil
  }

  private func stopClientAndWait() async {
    let activeTask = eventTask
    eventTask = nil
    let activeClient = client
    client = nil
    activeTask?.cancel()
    if let activeClient {
      await activeClient.stop()
    }
    await activeTask?.value
  }

  private func resetBridgeState() {
    connectionState = .stopped
    herdrAvailability = .unavailable
    sessions = []
    selectedSessionName = nil
    agents = []
    selectedAgentID = nil
    agentsBySession = [:]
    availabilityBySession = [:]
  }

  private func activateSession(_ name: String?) {
    if selectedSessionName != name { selectedAgentID = nil }
    selectedSessionName = name
    refreshSelectedSession()
    UserDefaults.standard.set(name, forKey: "selectedHerdrSession")
  }

  private func refreshSelectedSession() {
    agents = selectedSessionName.flatMap { agentsBySession[$0] } ?? []
    herdrAvailability =
      selectedSessionName.flatMap { availabilityBySession[$0] } ?? .unavailable
    if let selectedAgentID, !agents.contains(where: { $0.id == selectedAgentID }) {
      self.selectedAgentID = nil
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
    voiceTarget = nil
  }

  private static let demoAgents = [
    BridgeAgent(
      id: "demo-codex", kind: "codex", name: "Codex", status: .working,
      title: "Implementing onboarding", workspace: "AgentSlate", cwd: "/Demo/AgentSlate"),
    BridgeAgent(
      id: "demo-claude", kind: "claude", name: "Claude", status: .blocked,
      title: "Approve test command", workspace: "Website", cwd: "/Demo/Website"),
    BridgeAgent(
      id: "demo-omp", kind: "omp", name: "OMP", status: .idle,
      title: "Waiting", workspace: "CLI", cwd: "/Demo/CLI"),
    BridgeAgent(
      id: "demo-cursor", kind: "cursor", name: "Cursor", status: .done,
      title: "Finished review", workspace: "Dashboard", cwd: "/Demo/Dashboard"),
    BridgeAgent(
      id: "demo-opencode", kind: "opencode", name: "OpenCode", status: .blocked,
      title: "Needs input", workspace: "Mobile", cwd: "/Demo/Mobile"),
  ]
}

func supportsRemoteActions(for agent: BridgeAgent) -> Bool {
  guard agent.status == .blocked else { return false }
  return switch agent.kind {
  case "codex", "claude", "omp", "cursor", "opencode": true
  default: false
  }
}

private enum CredentialStore {
  private static let service = "com.danielou.AgentSlate.bridge"
  private static let account = "bridge-credential"

  static func load() -> BridgeCredential? {
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
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return try? JSONDecoder().decode(BridgeCredential.self, from: data)
  }

  static func save(_ credential: BridgeCredential) throws {
    let query =
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
      ] as CFDictionary
    let data = try JSONEncoder().encode(credential)
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

  static func delete() throws {
    let status = SecItemDelete(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
      ] as CFDictionary
    )
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw keychainError(status)
    }
  }

  private static func keychainError(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status))
  }
}
