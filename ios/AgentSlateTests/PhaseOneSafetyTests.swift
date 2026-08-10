import AVFoundation
import AgentSlateClient
import Foundation
import Testing

@testable import AgentSlate

@Test
func recordingStorePurgesOnlyOwnedRegularRecordings() throws {
  let fileManager = FileManager.default
  let directory = fileManager.temporaryDirectory
    .appendingPathComponent("AgentSlateRecordingStoreTests-(UUID().uuidString)")
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: directory) }

  let ownedOpenRouter = directory.appendingPathComponent(
    "agentslate-11111111-1111-1111-1111-111111111111.wav")
  let ownedSoniox = directory.appendingPathComponent(
    "agentslate-soniox-22222222-2222-2222-2222-222222222222.wav")
  let invalidIdentifier = directory.appendingPathComponent("agentslate-recording.wav")
  let unrelated = directory.appendingPathComponent("voice-memo.wav")
  let wrongExtension = directory.appendingPathComponent(
    "agentslate-33333333-3333-3333-3333-333333333333.txt")
  let ownedDirectory = directory.appendingPathComponent(
    "agentslate-44444444-4444-4444-4444-444444444444.wav")
  let ownedSymlink = directory.appendingPathComponent(
    "agentslate-55555555-5555-5555-5555-555555555555.wav")

  for url in [ownedOpenRouter, ownedSoniox, invalidIdentifier, unrelated, wrongExtension] {
    try Data("test".utf8).write(to: url)
  }
  try fileManager.createDirectory(at: ownedDirectory, withIntermediateDirectories: false)
  try fileManager.createSymbolicLink(at: ownedSymlink, withDestinationURL: unrelated)

  let store = DictationRecordingStore(directory: directory, fileManager: fileManager)
  try store.purgeOrphans()

  #expect(!fileManager.fileExists(atPath: ownedOpenRouter.path))
  #expect(!fileManager.fileExists(atPath: ownedSoniox.path))
  for url in [invalidIdentifier, unrelated, wrongExtension, ownedDirectory, ownedSymlink] {
    #expect(fileManager.fileExists(atPath: url.path))
  }
}

@Test
func recordingStoreProtectsPreparedRecorderFiles() throws {
  let fileManager = FileManager.default
  let directory = fileManager.temporaryDirectory
    .appendingPathComponent("AgentSlateRecordingProtectionTests-(UUID().uuidString)")
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: directory) }

  let store = DictationRecordingStore(directory: directory, fileManager: fileManager)
  let recording = store.recordingURL(for: .openRouter)
  let recorder = try AVAudioRecorder(
    url: recording,
    settings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ])
  let prepared = recorder.prepareToRecord()
  #expect(prepared)
  guard prepared else { return }
  try store.protect(recording)

  #if targetEnvironment(simulator)
    // CoreSimulator accepts file-protection writes but does not expose the metadata again.
    #expect(fileManager.fileExists(atPath: recording.path))
  #else
    let attributes = try fileManager.attributesOfItem(atPath: recording.path)
    #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
  #endif
}

@MainActor
@Test
func sessionScopedBridgeErrorsAffectOnlyTheSelectedSession() {
  let model = AppModel(
    configuredHost: "", configuredCredential: nil, selectedSessionName: "default")
  model.apply(
    .sessions([
      BridgeSession(name: "default", isDefault: true),
      BridgeSession(name: "team"),
    ]))
  model.apply(.herdrAvailability(session: "default", state: .connected))

  model.apply(
    HerdrSessionError(
      session: "team",
      error: .remote(code: "unsupported_herdr_version", message: "upgrade team")))
  #expect(model.herdrAvailability == .connected)
  #expect(model.errorMessage == nil)

  model.select(BridgeSession(name: "team"))
  #expect(model.herdrAvailability == .unavailable)
  #expect(model.errorMessage?.contains("upgrade team") == true)

  model.apply(.herdrAvailability(session: "team", state: .connected))
  #expect(model.herdrAvailability == .connected)
  #expect(model.errorMessage == nil)

  model.select(BridgeSession(name: "default", isDefault: true))
  model.apply(
    HerdrSessionError(
      session: "default",
      error: .remote(code: "unsupported_herdr_version", message: "upgrade default")))
  #expect(model.herdrAvailability == .unavailable)
  #expect(model.errorMessage?.contains("upgrade default") == true)
}

@Test
func recoveredProviderResultsAlwaysRequireReview() {
  #expect(
    requiresVoiceReview(
      action: .send,
      delivery: .reviewRequired,
      promptIssue: nil
    ))
  #expect(
    !requiresVoiceReview(
      action: .send,
      delivery: .automatic,
      promptIssue: nil
    ))

  let draft = VoiceDraft(
    text: "  exact partial  ",
    rawText: "  exact partial  ",
    agentID: "agent-1",
    agentName: "Codex",
    session: "default",
    notice: "Review before sending."
  )
  #expect(draft.text == "  exact partial  ")
  #expect(draft.notice == "Review before sending.")
}

@MainActor
@Test
func reviewRequiredDictationNeverAutoSends() async {
  let dictation = FakeVoiceDictation(
    result: DictationResult(
      rawText: "  exact partial  ",
      text: "  exact partial  ",
      fallbackNotice: "Review before sending.",
      delivery: .reviewRequired
    ))
  let model = AppModel(
    configuredHost: "",
    configuredCredential: nil,
    selectedSessionName: nil,
    dictationCredentials: nil,
    savedDictationEngine: DictationEngine.apple.rawValue,
    dictation: dictation
  )

  await model.activateDemoMode()
  await model.select(model.agents[0])
  await model.prepareVoice()
  model.beginVoice()
  for _ in 0..<100 where model.voiceState != .listening {
    await Task.yield()
  }
  #expect(model.voiceState == .listening)

  await model.finishVoice(.send)

  #expect(model.successFeedback == 0)
  #expect(model.voiceDraft?.text == "  exact partial  ")
  #expect(model.voiceDraft?.notice == "Review before sending.")
}

@MainActor
@Test
func vocabularyEditsDoNotChangeAnActiveDictationSnapshot() async throws {
  let suiteName = "ActiveDictationVocabularyTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let initialVocabulary = try DictationVocabulary(validating: ["Herdr"])
  let dictation = FakeVoiceDictation(
    result: DictationResult(
      rawText: "draft",
      text: "draft",
      fallbackNotice: nil,
      delivery: .reviewRequired
    ))
  let model = AppModel(
    configuredHost: "",
    configuredCredential: nil,
    savedDictationEngine: DictationEngine.apple.rawValue,
    dictationVocabulary: initialVocabulary,
    vocabularyDefaults: defaults,
    dictation: dictation
  )

  await model.activateDemoMode()
  await model.select(model.agents[0])
  await model.prepareVoice()
  model.beginVoice()
  for _ in 0..<100 where model.voiceState != .listening {
    await Task.yield()
  }
  #expect(model.voiceState == .listening)

  #expect(await model.addVocabularyTerm("AgentSlate") == nil)
  #expect(model.vocabularyTerms == ["AgentSlate", "Herdr"])
  #expect(await dictation.startedMode?.vocabulary == initialVocabulary)
  #expect(await dictation.cancelCount == 0)
  #expect(DictationVocabulary.load(from: defaults).terms == ["AgentSlate", "Herdr"])

  await model.finishVoice(.edit)
}

private actor FakeVoiceDictation: VoiceDictating {
  private let result: DictationResult
  private var prepared = false
  private(set) var isListening = false
  private(set) var lastPartial = ""
  private(set) var startedMode: DictationMode?
  private(set) var cancelCount = 0

  init(result: DictationResult) {
    self.result = result
  }

  func isPrepared(for mode: DictationMode) -> Bool { prepared }

  func prepare(for mode: DictationMode) {
    prepared = true
  }

  func start(
    mode: DictationMode,
    onPartial: @escaping @MainActor @Sendable (String) -> Void,
    onLevel: @escaping @MainActor @Sendable (Double) -> Void,
    onFailure: @escaping @MainActor @Sendable (any Error) async -> Void
  ) async {
    startedMode = mode
    isListening = true
  }

  func finalize(
    onPhase: @MainActor @Sendable (CloudDictationPhase) -> Void
  ) -> DictationResult {
    isListening = false
    return result
  }

  func cancel() {
    cancelCount += 1
    isListening = false
  }
}
