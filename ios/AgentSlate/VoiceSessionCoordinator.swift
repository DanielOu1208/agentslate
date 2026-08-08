import Foundation
import Observation

@MainActor
@Observable
final class VoiceSessionCoordinator {
  typealias Target = (agentID: String, agentName: String, session: String)

  var state: VoiceState = .notPrepared
  var partialTranscript = ""
  var level = 0.0
  var draft: VoiceDraft?

  @ObservationIgnored let dictation: any VoiceDictating
  @ObservationIgnored var startTask: Task<Void, Never>?
  @ObservationIgnored var processingTask: Task<DictationResult, any Error>?
  @ObservationIgnored var durationTask: Task<Void, Never>?
  @ObservationIgnored var endInProgress = false
  @ObservationIgnored var cancelInProgress = false
  @ObservationIgnored var generation = 0
  @ObservationIgnored var target: Target?
  @ObservationIgnored var capturedEngine: DictationEngine?

  init(dictation: any VoiceDictating) {
    self.dictation = dictation
  }
}
