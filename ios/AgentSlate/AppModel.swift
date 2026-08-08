import Foundation
import AgentSlateClient
import Observation
import UIKit

enum ForgetBridgeResult: Equatable {
  case revoked
  case localOnly
  case failed(String)
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
  private(set) var dictationCredentials: DictationCredentials?
  private(set) var dictationEngine: DictationEngine
  private(set) var cloudCleanupEnabled: Bool

  @ObservationIgnored private var client: BridgeClient?
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private let voiceSession: VoiceSessionCoordinator
  @ObservationIgnored private var agentsBySession: [String: [BridgeAgent]] = [:]
  @ObservationIgnored private var availabilityBySession: [String: HerdrAvailability] = [:]
  @ObservationIgnored private var errorsBySession: [String: BridgeError] = [:]
  @ObservationIgnored private var displayedSessionError: BridgeError?

  init(
    configuredHost: String = UserDefaults.standard.string(forKey: "bridgeHost") ?? "",
    configuredCredential: BridgeCredential? = KeychainStore.loadBridge(),
    selectedSessionName: String? = UserDefaults.standard.string(forKey: "selectedHerdrSession"),
    dictationCredentials: DictationCredentials? = KeychainStore.loadDictation(),
    savedDictationEngine: String? = UserDefaults.standard.string(forKey: "dictationEngine"),
    legacyCloudDictationEnabled: Bool = UserDefaults.standard.bool(
      forKey: "cloudDictationEnabled"),
    openRouterDictationConsentGranted: Bool = UserDefaults.standard.bool(
      forKey: "openRouterDictationConsentGranted"),
    sonioxDictationConsentGranted: Bool = UserDefaults.standard.bool(
      forKey: "sonioxDictationConsentGranted"),
    cloudCleanupEnabled: Bool? = UserDefaults.standard.object(
      forKey: "cloudCleanupEnabled") as? Bool,
    dictation: any VoiceDictating = VoiceDictationController()
  ) {
    self.configuredHost = configuredHost
    self.configuredCredential = configuredCredential
    self.selectedSessionName = selectedSessionName
    self.dictationCredentials = dictationCredentials
    self.voiceSession = VoiceSessionCoordinator(dictation: dictation)
    let resolvedEngine = resolveDictationEngine(
      savedValue: savedDictationEngine,
      legacyCloudEnabled: legacyCloudDictationEnabled,
      credentials: dictationCredentials,
      openRouterConsentGranted: openRouterDictationConsentGranted,
      sonioxConsentGranted: sonioxDictationConsentGranted
    )
    self.dictationEngine = resolvedEngine
    self.cloudCleanupEnabled = cloudCleanupEnabled ?? true
    if savedDictationEngine != nil, savedDictationEngine != resolvedEngine.rawValue {
      UserDefaults.standard.set(resolvedEngine.rawValue, forKey: "dictationEngine")
    }
  }

  private(set) var voiceState: VoiceState {
    get { voiceSession.state }
    set { voiceSession.state = newValue }
  }

  private(set) var partialTranscript: String {
    get { voiceSession.partialTranscript }
    set { voiceSession.partialTranscript = newValue }
  }

  private(set) var voiceLevel: Double {
    get { voiceSession.level }
    set { voiceSession.level = newValue }
  }

  private(set) var voiceDraft: VoiceDraft? {
    get { voiceSession.draft }
    set { voiceSession.draft = newValue }
  }

  private var dictation: any VoiceDictating { voiceSession.dictation }
  private var voiceStartTask: Task<Void, Never>? {
    get { voiceSession.startTask }
    set { voiceSession.startTask = newValue }
  }
  private var voiceProcessingTask: Task<DictationResult, any Error>? {
    get { voiceSession.processingTask }
    set { voiceSession.processingTask = newValue }
  }
  private var voiceDurationTask: Task<Void, Never>? {
    get { voiceSession.durationTask }
    set { voiceSession.durationTask = newValue }
  }
  private var voiceEndInProgress: Bool {
    get { voiceSession.endInProgress }
    set { voiceSession.endInProgress = newValue }
  }
  private var voiceCancelInProgress: Bool {
    get { voiceSession.cancelInProgress }
    set { voiceSession.cancelInProgress = newValue }
  }
  private var voiceSessionGeneration: Int {
    get { voiceSession.generation }
    set { voiceSession.generation = newValue }
  }
  private var voiceTarget: VoiceSessionCoordinator.Target? {
    get { voiceSession.target }
    set { voiceSession.target = newValue }
  }
  private var capturedVoiceEngine: DictationEngine? {
    get { voiceSession.capturedEngine }
    set { voiceSession.capturedEngine = newValue }
  }

  var hasConfiguration: Bool {
    !configuredHost.isEmpty && configuredCredential != nil
  }

  var hasOpenRouterAPIKey: Bool { dictationCredentials?.hasOpenRouterKey == true }
  var hasSonioxAPIKey: Bool { dictationCredentials?.hasSonioxKey == true }
  var effectiveCloudCleanupEnabled: Bool { cloudCleanupEnabled && hasOpenRouterAPIKey }

  var dictationMode: DictationMode {
    switch dictationEngine {
    case .apple:
      return .apple
    case .openRouter:
      guard let key = dictationCredentials?.openRouterAPIKey, !key.isEmpty else { return .apple }
      return .openRouter(apiKey: key, cleanupEnabled: effectiveCloudCleanupEnabled)
    case .soniox:
      guard let key = dictationCredentials?.sonioxAPIKey, !key.isEmpty else { return .apple }
      let cleanupKey =
        effectiveCloudCleanupEnabled ? dictationCredentials?.openRouterAPIKey : nil
      return .soniox(apiKey: key, cleanupAPIKey: cleanupKey)
    }
  }

  var voiceProvider: VoiceProvider? {
    guard let capturedVoiceEngine else { return nil }
    return currentVoiceProvider(engine: capturedVoiceEngine, state: voiceState)
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
      try KeychainStore.saveBridge(credential)
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
    errorsBySession = [:]
    displayedSessionError = nil
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
      try KeychainStore.deleteBridge()
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
      clearTransientError()
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
      clearTransientError()
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
      clearTransientError()
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
      clearTransientError()
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
    let validation = validateVoicePromptText(text)
    guard validation.isValid,
      draft.matches(
        agentID: selectedAgentID, session: selectedSessionName, available: canSend)
    else { return false }
    if isDemoMode {
      successFeedback += 1
      clearVoicePresentationAfterAcknowledgement()
      return true
    }
    guard let client else { return false }
    let acknowledged = await send(
      text: validation.normalizedText,
      submit: true,
      to: draft.agentID,
      session: draft.session,
      client: client
    )
    if acknowledged {
      clearVoicePresentationAfterAcknowledgement()
    }
    return acknowledged
  }

  func discardVoiceDraft() {
    let discardedFailure =
      if case .failed = voiceState { true } else { false }
    voiceDraft = nil
    partialTranscript = ""
    capturedVoiceEngine = nil
    if discardedFailure {
      voiceState = .notPrepared
      clearTransientError()
      if canSend {
        Task { [weak self] in await self?.prepareVoice() }
      }
    }
  }

  func canUseDictationEngine(_ engine: DictationEngine) -> Bool {
    switch engine {
    case .apple: true
    case .openRouter: hasOpenRouterAPIKey
    case .soniox: hasSonioxAPIKey
    }
  }

  func hasDictationConsent(for engine: DictationEngine) -> Bool {
    engine == .apple
      || UserDefaults.standard.bool(forKey: "\(engine.rawValue)DictationConsentGranted")
  }

  @discardableResult
  func saveOpenRouterAPIKey(_ apiKey: String) -> Bool {
    let updated = DictationCredentials(
      openRouterAPIKey: apiKey,
      sonioxAPIKey: dictationCredentials?.sonioxAPIKey ?? ""
    )
    guard updated.hasOpenRouterKey else { return false }
    return saveDictationCredentials(updated)
  }

  @discardableResult
  func saveSonioxAPIKey(_ apiKey: String) -> Bool {
    let updated = DictationCredentials(
      openRouterAPIKey: dictationCredentials?.openRouterAPIKey ?? "",
      sonioxAPIKey: apiKey
    )
    guard updated.hasSonioxKey else { return false }
    return saveDictationCredentials(updated)
  }

  func setDictationEngine(_ engine: DictationEngine, grantingConsent: Bool = false) async {
    guard canUseDictationEngine(engine) else { return }
    if grantingConsent, engine != .apple {
      UserDefaults.standard.set(
        true, forKey: "\(engine.rawValue)DictationConsentGranted")
    }
    guard hasDictationConsent(for: engine) else { return }
    await cancelVoice()
    dictationEngine = engine
    UserDefaults.standard.set(engine.rawValue, forKey: "dictationEngine")
    voiceState = .notPrepared
    partialTranscript = ""
    if canSend { await prepareVoice() }
  }

  func setCloudCleanupEnabled(_ enabled: Bool) async {
    guard hasOpenRouterAPIKey else { return }
    await cancelVoice()
    cloudCleanupEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "cloudCleanupEnabled")
    voiceState = .notPrepared
    partialTranscript = ""
    if canSend { await prepareVoice() }
  }

  func removeOpenRouterAPIKey() async {
    if dictationEngine == .openRouter { await setDictationEngine(.apple) }
    let updated = DictationCredentials(sonioxAPIKey: dictationCredentials?.sonioxAPIKey ?? "")
    saveOrDeleteDictationCredentials(updated)
  }

  func removeSonioxAPIKey() async {
    if dictationEngine == .soniox { await setDictationEngine(.apple) }
    let updated = DictationCredentials(
      openRouterAPIKey: dictationCredentials?.openRouterAPIKey ?? "")
    saveOrDeleteDictationCredentials(updated)
  }

  private func saveDictationCredentials(_ credentials: DictationCredentials) -> Bool {
    do {
      try KeychainStore.saveDictation(credentials)
      dictationCredentials = credentials
      clearTransientError()
      return true
    } catch {
      report(error)
      return false
    }
  }

  private func saveOrDeleteDictationCredentials(_ credentials: DictationCredentials) {
    do {
      if credentials.isEmpty {
        try KeychainStore.deleteDictation()
        dictationCredentials = nil
      } else {
        try KeychainStore.saveDictation(credentials)
        dictationCredentials = credentials
      }
      clearTransientError()
    } catch {
      report(error)
    }
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
      clearTransientError()
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
      voiceState != .finalizing,
      voiceState != .transcribing,
      voiceState != .appleFallback,
      voiceState != .cleaning
    else {
      return
    }

    partialTranscript = ""
    capturedVoiceEngine = nil
    voiceLevel = 0
    voiceState = .preparing
    let generation = voiceSessionGeneration
    let mode = dictationMode
    do {
      try await dictation.prepare(for: mode)
      try Task.checkCancellation()
      guard generation == voiceSessionGeneration else {
        await dictation.cancel()
        return
      }
      voiceState = .ready
    } catch is CancellationError {
      if generation == voiceSessionGeneration {
        voiceState = .notPrepared
      }
    } catch {
      if generation == voiceSessionGeneration {
        await handleVoiceFailure(error)
      }
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
    let mode = dictationMode
    partialTranscript = ""
    voiceLevel = 0
    capturedVoiceEngine = voiceEngine(for: mode)
    voiceTarget = (selectedAgent.id, selectedAgent.name, selectedSessionName)
    voiceState = .starting
    voiceStartTask = Task { [weak self] in
      guard let self else { return }
      do {
        try Task.checkCancellation()
        try await self.dictation.start(
          mode: mode,
          onPartial: { [weak self] partial in
            guard let self, generation == self.voiceSessionGeneration else { return }
            self.partialTranscript = partial
          },
          onLevel: { [weak self] level in
            guard let self, generation == self.voiceSessionGeneration,
              self.voiceState == .starting || self.voiceState == .listening
            else { return }
            self.voiceLevel = level
          },
          onFailure: { [weak self] error in
            guard let self, generation == self.voiceSessionGeneration else { return }
            await self.handleVoiceFailure(error)
          }
        )
        try Task.checkCancellation()
        guard generation == self.voiceSessionGeneration else {
          await self.dictation.cancel()
          return
        }
        self.voiceState = self.voiceEndInProgress ? .finalizing : .listening
        if mode.isCloud, !self.voiceEndInProgress {
          self.voiceDurationTask?.cancel()
          self.voiceDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, !Task.isCancelled, generation == self.voiceSessionGeneration else {
              return
            }
            self.voiceDurationTask = nil
            await self.finishVoice(.edit)
          }
        }
      } catch is CancellationError {
        await self.dictation.cancel()
        if generation == self.voiceSessionGeneration {
          let prepared = await self.dictation.isPrepared(for: self.dictationMode)
          self.voiceState = prepared ? .ready : .notPrepared
        }
      } catch {
        if generation == self.voiceSessionGeneration {
          await self.handleVoiceFailure(error)
        }
      }
      if generation == self.voiceSessionGeneration {
        self.voiceStartTask = nil
      }
    }
  }

  func finishVoice(_ action: VoiceReleaseAction) async {
    if action == .cancel {
      await cancelVoice(reprepare: true)
      return
    }
    guard
      !voiceEndInProgress,
      voiceState == .starting || voiceState == .listening || voiceStartTask != nil
    else { return }
    voiceDurationTask?.cancel()
    voiceDurationTask = nil
    voiceEndInProgress = true
    let generation = voiceSessionGeneration
    voiceLevel = 0
    voiceState = .finalizing
    defer {
      if generation == voiceSessionGeneration {
        voiceEndInProgress = false
      }
    }

    if let voiceStartTask {
      await voiceStartTask.value
    }
    let isListening = await dictation.isListening
    guard generation == voiceSessionGeneration, isListening else { return }
    do {
      let task = Task { [weak self] () throws -> DictationResult in
        guard let self else { throw CancellationError() }
        return try await self.dictation.finalize { phase in
          guard generation == self.voiceSessionGeneration else { return }
          self.voiceState =
            switch phase {
            case .transcribing: .transcribing
            case .appleFallback: .appleFallback
            case .cleaning: .cleaning
            }
        }
      }
      voiceProcessingTask = task
      let result = try await task.value
      voiceProcessingTask = nil
      guard generation == voiceSessionGeneration, !Task.isCancelled else { return }
      let transcriptValidation = validateVoiceDraftText(result.text)
      let promptValidation = validateVoicePromptText(result.text)
      var sendAcknowledged: Bool?
      if let voiceTarget {
        if requiresVoiceReview(
          action: action,
          delivery: result.delivery,
          promptIssue: promptValidation.issue
        ) {
          voiceDraft = VoiceDraft(
            text: result.delivery == .reviewRequired
              ? result.text : transcriptValidation.normalizedText,
            rawText: result.rawText,
            agentID: voiceTarget.agentID,
            agentName: voiceTarget.agentName,
            session: voiceTarget.session,
            notice: result.fallbackNotice
          )
        } else if promptValidation.isValid,
          canSend,
          selectedAgentID == voiceTarget.agentID,
          selectedSessionName == voiceTarget.session
        {
          if isDemoMode {
            successFeedback += 1
            sendAcknowledged = true
          } else if let client {
            sendAcknowledged = await send(
              text: promptValidation.normalizedText,
              submit: true,
              to: voiceTarget.agentID,
              session: voiceTarget.session,
              client: client
            )
          } else {
            sendAcknowledged = false
          }
        } else if promptValidation.isValid {
          errorMessage = "The original agent is no longer available for this dictation."
          errorFeedback += 1
          sendAcknowledged = false
        }
      }
      guard generation == voiceSessionGeneration else { return }
      if let sendAcknowledged {
        let completion = resolveVoiceSendCompletion(
          acknowledged: sendAcknowledged,
          transcript: result.text,
          fallbackNotice: result.fallbackNotice
        )
        if completion.shouldClear {
          clearVoicePresentationAfterAcknowledgement()
        } else {
          if let voiceTarget {
            voiceDraft = recoveryDraftForFailedVoiceSend(
              completion: completion,
              text: transcriptValidation.normalizedText,
              rawText: result.rawText,
              agentID: voiceTarget.agentID,
              agentName: voiceTarget.agentName,
              session: voiceTarget.session,
              notice: result.fallbackNotice
            )
          }
          partialTranscript = completion.retainedTranscript
          voiceLevel = 0
          voiceTarget = nil
          voiceState = .failed(errorMessage ?? "The dictation could not be sent. Try again.")
          return
        }
      }
      voiceState = .notPrepared
      partialTranscript = ""
      voiceLevel = 0
      voiceTarget = nil
      if canSend {
        await prepareVoice()
      }
      if sendAcknowledged == nil, voiceState == .ready {
        partialTranscript = result.fallbackNotice ?? ""
      }
    } catch is CancellationError {
      voiceProcessingTask = nil
      if generation == voiceSessionGeneration {
        let prepared = await dictation.isPrepared(for: dictationMode)
        voiceState = prepared ? .ready : .notPrepared
        voiceTarget = nil
      }
    } catch {
      voiceProcessingTask = nil
      if generation == voiceSessionGeneration {
        await handleVoiceFailure(error)
      }
    }
  }

  func cancelVoice(reprepare: Bool = false) async {
    guard
      !voiceCancelInProgress,
      voiceState == .preparing || voiceState == .ready || voiceState == .starting
        || voiceState == .listening || voiceState == .finalizing
        || voiceState == .transcribing || voiceState == .appleFallback
        || voiceState == .cleaning
        || voiceStartTask != nil || voiceProcessingTask != nil
    else { return }
    voiceCancelInProgress = true
    defer { voiceCancelInProgress = false }
    voiceSessionGeneration &+= 1
    voiceEndInProgress = false
    voiceLevel = 0
    voiceState = .finalizing
    voiceDurationTask?.cancel()
    voiceDurationTask = nil
    let startTask = voiceStartTask
    let processingTask = voiceProcessingTask
    startTask?.cancel()
    processingTask?.cancel()
    await dictation.cancel()
    await startTask?.value
    _ = await processingTask?.result
    voiceStartTask = nil
    voiceProcessingTask = nil
    voiceState = .notPrepared
    partialTranscript = ""
    capturedVoiceEngine = nil
    voiceTarget = nil
    if reprepare, canSend {
      await prepareVoice()
    }
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
      errorsBySession = errorsBySession.filter { names.contains($0.key) }

      if let selectedSessionName, names.contains(selectedSessionName) {
        refreshSelectedSession()
      } else if let fallback = snapshot.first(where: \.isDefault) ?? snapshot.first {
        activateSession(fallback.name)
      } else {
        activateSession(nil)
      }
    case .herdrAvailability(let session, let availability):
      availabilityBySession[session] = availability
      if availability == .connected { errorsBySession[session] = nil }
      if session == selectedSessionName {
        herdrAvailability = availability
        reconcileSelectedSessionError()
      }
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

  func apply(_ event: HerdrSessionError) {
    guard !isDemoMode else { return }
    errorsBySession[event.session] = event.error
    availabilityBySession[event.session] = .unavailable
    if event.session == selectedSessionName {
      herdrAvailability = .unavailable
      displaySessionError(event.error)
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
        for await update in newClient.updates {
          guard !Task.isCancelled else { break }
          switch update {
          case .event(let event): self?.apply(event)
          case .herdrError(let error): self?.apply(error)
          }
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
    errorsBySession = [:]
    displayedSessionError = nil
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
    reconcileSelectedSessionError()
  }

  private func report(_ error: any Error) {
    displayedSessionError = nil
    errorMessage = error.localizedDescription
    errorFeedback += 1
  }

  private func reconcileSelectedSessionError() {
    if let error = selectedSessionName.flatMap({ errorsBySession[$0] }) {
      displaySessionError(error)
    } else if displayedSessionError != nil {
      displayedSessionError = nil
      errorMessage = nil
    }
  }

  private func displaySessionError(_ error: BridgeError) {
    let message = error.localizedDescription
    guard displayedSessionError != error || errorMessage != message else { return }
    displayedSessionError = error
    errorMessage = message
    errorFeedback += 1
  }

  private func clearTransientError() {
    if let error = selectedSessionName.flatMap({ errorsBySession[$0] }) {
      displayedSessionError = error
      errorMessage = error.localizedDescription
    } else {
      displayedSessionError = nil
      errorMessage = nil
    }
  }

  private func clearVoicePresentationAfterAcknowledgement() {
    partialTranscript = ""
    capturedVoiceEngine = nil
    clearTransientError()
  }

  private func handleVoiceFailure(_ error: any Error) async {
    let failedState = VoiceState.failed(error.localizedDescription)
    partialTranscript = await dictation.lastPartial
    voiceLevel = 0
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
