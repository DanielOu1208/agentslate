import CoreGraphics
import Foundation

protocol VoiceDictating: Sendable {
  var isListening: Bool { get async }
  var lastPartial: String { get async }

  func isPrepared(for mode: DictationMode) async -> Bool
  func prepare(for mode: DictationMode) async throws
  func start(
    mode: DictationMode,
    onPartial: @escaping @MainActor @Sendable (String) -> Void,
    onLevel: @escaping @MainActor @Sendable (Double) -> Void,
    onFailure: @escaping @MainActor @Sendable (any Error) async -> Void
  ) async throws
  func finalize(
    onPhase: @MainActor @Sendable (CloudDictationPhase) -> Void
  ) async throws -> DictationResult
  func cancel() async
}

enum VoiceState: Equatable {
  case notPrepared
  case preparing
  case ready
  case starting
  case listening
  case finalizing
  case transcribing
  case appleFallback
  case cleaning
  case failed(String)
}

enum VoiceProvider: String, Equatable, Sendable {
  case appleOnDevice = "APPLE ON-DEVICE"
  case whisper = "WHISPER"
  case soniox = "SONIOX"
  case appleFallback = "APPLE FALLBACK"
  case geminiCleanup = "GEMINI CLEANUP"

  var accessibilityName: String {
    switch self {
    case .appleOnDevice: "Apple on-device"
    case .whisper: "Whisper"
    case .soniox: "Soniox"
    case .appleFallback: "Apple fallback"
    case .geminiCleanup: "Gemini cleanup"
    }
  }

  var accessibilityLabel: String {
    "Current transcription provider: \(accessibilityName)."
  }
}

func voiceEngine(for mode: DictationMode) -> DictationEngine {
  switch mode {
  case .apple: .apple
  case .openRouter: .openRouter
  case .soniox: .soniox
  }
}

func currentVoiceProvider(
  engine: DictationEngine,
  state: VoiceState
) -> VoiceProvider? {
  let primary: VoiceProvider =
    switch engine {
    case .apple: .appleOnDevice
    case .openRouter: .whisper
    case .soniox: .soniox
    }
  return switch state {
  case .starting, .listening, .finalizing: primary
  case .transcribing: .whisper
  case .appleFallback: .appleFallback
  case .cleaning: .geminiCleanup
  case .notPrepared, .preparing, .ready, .failed: nil
  }
}

struct VoiceSendCompletion: Equatable {
  let shouldClear: Bool
  let retainedTranscript: String
}

func resolveVoiceSendCompletion(
  acknowledged: Bool,
  transcript: String,
  fallbackNotice: String?
) -> VoiceSendCompletion {
  guard !acknowledged else {
    return VoiceSendCompletion(shouldClear: true, retainedTranscript: "")
  }
  let retained = [fallbackNotice, transcript]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
  return VoiceSendCompletion(shouldClear: false, retainedTranscript: retained)
}

func recoveryDraftForFailedVoiceSend(
  completion: VoiceSendCompletion,
  text: String,
  rawText: String,
  agentID: String,
  agentName: String,
  session: String,
  notice: String? = nil
) -> VoiceDraft? {
  guard !completion.shouldClear else { return nil }
  return VoiceDraft(
    text: text,
    rawText: rawText,
    agentID: agentID,
    agentName: agentName,
    session: session,
    notice: notice
  )
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

func requiresVoiceReview(
  action: VoiceReleaseAction,
  delivery: DictationDelivery,
  promptIssue: VoiceTextIssue?
) -> Bool {
  action == .edit || delivery == .reviewRequired
    || promptIssue == .controlCharacters || promptIssue == .tooLarge
}

struct VoiceDraft: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let rawText: String
  let agentID: String
  let agentName: String
  let session: String
  let notice: String?

  init(
    text: String,
    rawText: String,
    agentID: String,
    agentName: String,
    session: String,
    notice: String? = nil
  ) {
    self.text = text
    self.rawText = rawText
    self.agentID = agentID
    self.agentName = agentName
    self.session = session
    self.notice = notice
  }

  func matches(agentID: String?, session: String?, available: Bool) -> Bool {
    available && self.agentID == agentID && self.session == session
  }
}

enum VoiceTextIssue: Equatable {
  case blank
  case controlCharacters
  case tooLarge
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

func validateVoicePromptText(_ text: String) -> VoiceTextValidation {
  let transcript = validateVoiceDraftText(text)
  guard transcript.issue != .blank, transcript.issue != .controlCharacters else {
    return transcript
  }
  return validateVoiceDraftText(
    "[Voice transcript: Project-specific names may be phonetically misspelled. "
      + "Infer obvious matches from the repository; clarify ambiguous ones.] "
      + transcript.normalizedText
  )
}

func resolveDictationEngine(
  savedValue: String?,
  legacyCloudEnabled: Bool,
  credentials: DictationCredentials?,
  openRouterConsentGranted: Bool,
  sonioxConsentGranted: Bool
) -> DictationEngine {
  if let savedValue, let saved = DictationEngine(rawValue: savedValue) {
    return switch saved {
    case .openRouter
    where credentials?.hasOpenRouterKey != true || !openRouterConsentGranted: .apple
    case .soniox where credentials?.hasSonioxKey != true || !sonioxConsentGranted: .apple
    default: saved
    }
  }
  return legacyCloudEnabled && credentials?.hasOpenRouterKey == true ? .openRouter : .apple
}
