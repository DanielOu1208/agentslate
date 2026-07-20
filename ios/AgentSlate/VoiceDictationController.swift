@preconcurrency import AVFoundation
import Foundation
import Speech

/// Hold-to-talk dictation with optional user-funded cloud transcription and on-device fallback.
@MainActor
final class VoiceDictationController {
  enum Failure: LocalizedError {
    case permissionDenied
    case localeNotSupported
    case assetUnavailable
    case audioSetupFailed
    case notListening
    case transcriptionFailed

    var errorDescription: String? {
      switch self {
      case .permissionDenied:
        "Microphone permission is required for voice dictation."
      case .localeNotSupported:
        "On-device speech recognition is unavailable for this language."
      case .assetUnavailable:
        "The speech model is not installed. Connect to the network and try again."
      case .audioSetupFailed:
        "Could not start the microphone for dictation."
      case .notListening:
        "Voice dictation is not active."
      case .transcriptionFailed:
        "Cloud and on-device transcription both failed. Try again."
      }
    }
  }

  private(set) var isListening = false
  private(set) var finalizedText = ""
  private(set) var volatileText = ""
  private(set) var lastPartial = ""

  var liveText: String { finalizedText + volatileText }

  private let audioEngine = AVAudioEngine()
  private let cloudClient: CloudDictationClient
  private var transcriber: DictationTranscriber?
  private var analyzer: SpeechAnalyzer?
  private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
  private var analyzerFormat: AVAudioFormat?
  private var resultsTask: Task<Void, any Error>?
  private var resultFailure: (any Error)?
  private var sessionGeneration = 0
  private var preparedLocale: Locale?
  private var microphonePrepared = false
  private var audioSessionConfigured = false
  private var applePrepared = false
  private var activeMode: DictationMode = .apple
  private var recorder: AVAudioRecorder?
  private var recordingURL: URL?
  private var tapInstalled = false
  private var cancellationRequested = false
  private var onPartial: ((String) -> Void)?
  private var onFailure: ((any Error) -> Void)?

  init(cloudClient: CloudDictationClient = CloudDictationClient()) {
    self.cloudClient = cloudClient
  }

  func isPrepared(for mode: DictationMode) -> Bool {
    microphonePrepared && (mode.isCloud || applePrepared)
  }

  func prepare(for mode: DictationMode) async throws {
    if !microphonePrepared {
      guard await AVAudioApplication.requestRecordPermission() else {
        throw Failure.permissionDenied
      }
      microphonePrepared = true
    }
    try Task.checkCancellation()
    try configureAudioSession()

    guard !mode.isCloud else { return }
    try await prepareApple()
  }

  private func prepareApple() async throws {
    guard !applePrepared else { return }
    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else {
      throw Failure.localeNotSupported
    }
    let transcriber = makeTranscriber(locale: locale)
    do {
      try await ensureModelInstalled(for: transcriber, locale: locale)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Failure.assetUnavailable
    }
    try Task.checkCancellation()

    preparedLocale = locale
    applePrepared = true
  }

  func start(
    mode: DictationMode,
    onPartial: @escaping (String) -> Void,
    onFailure: @escaping (any Error) -> Void
  ) async throws {
    guard !isListening else { return }
    if !isPrepared(for: mode) { try await prepare(for: mode) }
    try Task.checkCancellation()

    sessionGeneration &+= 1
    let generation = sessionGeneration
    self.onPartial = onPartial
    self.onFailure = onFailure
    finalizedText = ""
    volatileText = ""
    lastPartial = ""
    cancellationRequested = false
    resultFailure = nil
    activeMode = mode
    onPartial("")

    if mode.isCloud {
      do {
        try startCloudRecording()
        isListening = true
      } catch {
        finishSession(for: generation)
        throw Failure.audioSetupFailed
      }
      return
    }

    try await startAppleCapture(generation: generation)
  }

  private func startAppleCapture(generation: Int) async throws {
    guard let locale = preparedLocale else {
      finishSession(for: generation)
      throw Failure.localeNotSupported
    }
    let transcriber = makeTranscriber(locale: locale)
    self.transcriber = transcriber

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    self.analyzer = analyzer
    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    do {
      try Task.checkCancellation()
    } catch {
      finishSession(for: generation)
      throw error
    }
    guard let format else {
      finishSession(for: generation)
      throw Failure.audioSetupFailed
    }
    analyzerFormat = format

    resultsTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await result in transcriber.results {
          let piece = String(result.text.characters)
          if result.isFinal {
            self.finalizedText += piece
            self.volatileText = ""
          } else {
            self.volatileText = piece
          }
          let live = self.liveText
          self.lastPartial = live
          self.onPartial?(live)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard generation == self.sessionGeneration else { throw CancellationError() }
        self.lastPartial = self.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resultFailure = error
        let failureHandler = self.onFailure
        self.finishSession(for: generation, cancelResults: false)
        failureHandler?(error)
        throw error
      }
    }

    let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
    inputBuilder = builder
    do {
      try await analyzer.start(inputSequence: sequence)
      try Task.checkCancellation()
    } catch {
      await analyzer.cancelAndFinishNow()
      finishSession(for: generation)
      throw error
    }
    do {
      try setupAudioSession()
      try startMicrophone()
    } catch {
      await analyzer.cancelAndFinishNow()
      finishSession(for: generation)
      throw Failure.audioSetupFailed
    }

    isListening = true
  }

  func finalize(onPhase: (CloudDictationPhase) -> Void) async throws -> DictationResult {
    guard isListening else { throw Failure.notListening }
    let generation = sessionGeneration

    if case .cloud(let credentials) = activeMode {
      return try await finalizeCloud(
        generation: generation,
        credentials: credentials,
        onPhase: onPhase
      )
    }

    let text = try await finalizeAppleCapture(generation: generation)
    return DictationResult(rawText: text, text: text, fallbackNotice: nil)
  }

  private func finalizeAppleCapture(generation: Int) async throws -> String {
    let analyzer = analyzer
    let resultsTask = resultsTask
    isListening = false

    stopCapture()

    do {
      try await analyzer?.finalizeAndFinishThroughEndOfInput()
      try await resultsTask?.value
      guard generation == sessionGeneration else { throw CancellationError() }
      if let resultFailure { throw resultFailure }
      try Task.checkCancellation()
      guard !cancellationRequested else { throw CancellationError() }
      let text = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
      lastPartial = text
      finishSession(for: generation)
      return text
    } catch {
      if generation == sessionGeneration {
        lastPartial = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        finishSession(for: generation)
      }
      throw error
    }
  }

  private func finalizeCloud(
    generation: Int,
    credentials: DictationCredentials,
    onPhase: (CloudDictationPhase) -> Void
  ) async throws -> DictationResult {
    isListening = false
    recorder?.stop()
    recorder = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    guard let recordingURL else {
      finishSession(for: generation)
      throw Failure.audioSetupFailed
    }
    defer {
      try? FileManager.default.removeItem(at: recordingURL)
      if generation == sessionGeneration { self.recordingURL = nil }
    }

    onPhase(.transcribing)
    let rawText: String
    var notice: String?
    do {
      rawText = try await cloudClient.transcribe(
        audioURL: recordingURL,
        apiKey: credentials.openRouterAPIKey
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      onPhase(.appleFallback)
      do {
        rawText = try await transcribeAppleFile(recordingURL)
        notice = "Cloud transcription unavailable; used Apple transcription."
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        finishSession(for: generation)
        throw Failure.transcriptionFailed
      }
    }

    try Task.checkCancellation()
    guard generation == sessionGeneration, !cancellationRequested else {
      throw CancellationError()
    }

    onPhase(.cleaning)
    let cleanedText = try? await cloudClient.cleanup(
      transcript: rawText,
      apiKey: credentials.openRouterAPIKey
    )
    try Task.checkCancellation()
    guard generation == sessionGeneration, !cancellationRequested else {
      throw CancellationError()
    }

    let cleanup = resolveCleanup(rawText: rawText, cleanedText: cleanedText)
    if let cleanupNotice = cleanup.fallbackNotice {
      notice = notice.map { "\($0) \(cleanupNotice)" } ?? cleanupNotice
    }
    lastPartial = cleanup.text
    finishSession(for: generation)
    return DictationResult(rawText: rawText, text: cleanup.text, fallbackNotice: notice)
  }

  func cancel() async {
    let generation = sessionGeneration
    let analyzer = analyzer
    let resultsTask = resultsTask
    cancellationRequested = true
    guard isListening || analyzer != nil || recorder != nil || recordingURL != nil else {
      finishSession(for: generation)
      return
    }

    recorder?.stop()
    recorder = nil
    stopCapture()
    await analyzer?.cancelAndFinishNow()
    if let resultsTask {
      resultsTask.cancel()
      _ = await resultsTask.result
    }
    if let recordingURL {
      try? FileManager.default.removeItem(at: recordingURL)
      self.recordingURL = nil
    }
    finishSession(for: generation)
  }

  private func finishSession(for generation: Int, cancelResults: Bool = true) {
    guard generation == sessionGeneration else { return }
    stopCapture()
    if cancelResults { resultsTask?.cancel() }
    resultsTask = nil
    analyzer = nil
    transcriber = nil
    analyzerFormat = nil
    recorder = nil
    onPartial = nil
    onFailure = nil
    isListening = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func stopCapture() {
    if audioEngine.isRunning { audioEngine.stop() }
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    inputBuilder?.finish()
    inputBuilder = nil
  }

  private func makeTranscriber(locale: Locale) -> DictationTranscriber {
    makeTranscriber(locale: locale, reportsVolatileResults: true)
  }

  private func makeTranscriber(
    locale: Locale,
    reportsVolatileResults: Bool
  ) -> DictationTranscriber {
    DictationTranscriber(
      locale: locale,
      contentHints: [.shortForm],
      transcriptionOptions: [.punctuation, .etiquetteReplacements],
      reportingOptions: reportsVolatileResults ? [.volatileResults] : [],
      attributeOptions: []
    )
  }

  private func startCloudRecording() throws {
    try setupAudioSession()
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentslate-\(UUID().uuidString)")
      .appendingPathExtension("wav")
    let recorder = try AVAudioRecorder(
      url: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
    guard recorder.prepareToRecord(), recorder.record() else {
      throw Failure.audioSetupFailed
    }
    recordingURL = url
    self.recorder = recorder
  }

  private func transcribeAppleFile(_ url: URL) async throws -> String {
    try await prepareApple()
    guard let locale = preparedLocale else { throw Failure.localeNotSupported }
    let transcriber = makeTranscriber(locale: locale, reportsVolatileResults: false)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: url)

    async let collectedText = collectResults(from: transcriber)
    do {
      if let lastSampleTime = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: lastSampleTime)
      } else {
        await analyzer.cancelAndFinishNow()
      }
      let collected = try await collectedText
      let text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw Failure.transcriptionFailed }
      return text
    } catch {
      await analyzer.cancelAndFinishNow()
      throw error
    }
  }

  private func collectResults(from transcriber: DictationTranscriber) async throws -> String {
    var text = ""
    for try await result in transcriber.results where result.isFinal {
      text += String(result.text.characters)
    }
    return text
  }

  private func ensureModelInstalled(for transcriber: DictationTranscriber, locale: Locale)
    async throws
  {
    let installed = await Set(DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    if installed.contains(locale.identifier(.bcp47)) { return }

    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }

    let nowInstalled = await Set(
      DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) }
    )
    guard nowInstalled.contains(locale.identifier(.bcp47)) else {
      throw Failure.assetUnavailable
    }
  }

  private func setupAudioSession() throws {
    try configureAudioSession()
    try AVAudioSession.sharedInstance().setActive(
      true,
      options: .notifyOthersOnDeactivation
    )
  }

  private func configureAudioSession() throws {
    guard !audioSessionConfigured else { return }
    try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
    audioSessionConfigured = true
  }

  private func startMicrophone() throws {
    guard let builder = inputBuilder, let target = analyzerFormat else {
      throw Failure.audioSetupFailed
    }

    let converter = AudioBufferConverter()
    let input = audioEngine.inputNode
    let micFormat = input.outputFormat(forBus: 0)

    input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { @Sendable buffer, _ in
      guard let converted = try? converter.convert(buffer, to: target) else { return }
      builder.yield(AnalyzerInput(buffer: converted))
    }
    tapInstalled = true

    audioEngine.prepare()
    try audioEngine.start()
  }
}

/// Converts mic buffers to the format SpeechAnalyzer requests.
/// Single-threaded: create one per capture session and call only from the audio tap.
private final class AudioBufferConverter: @unchecked Sendable {
  enum Failure: Error {
    case cannotCreateConverter
    case cannotCreateBuffer
    case conversionFailed
  }

  private var converter: AVAudioConverter?

  func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let inputFormat = buffer.format
    guard inputFormat != format else { return buffer }

    if converter == nil || converter?.outputFormat != format {
      converter = AVAudioConverter(from: inputFormat, to: format)
      converter?.primeMethod = .none
    }
    guard let converter else { throw Failure.cannotCreateConverter }

    let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
    guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
    else {
      throw Failure.cannotCreateBuffer
    }

    var nsError: NSError?
    let inputOnce = OnceBuffer(buffer)
    let status = converter.convert(to: output, error: &nsError) { _, statusPtr in
      if inputOnce.consumed {
        statusPtr.pointee = .noDataNow
        return nil
      }
      inputOnce.consumed = true
      statusPtr.pointee = .haveData
      return inputOnce.buffer
    }
    guard status != .error else { throw Failure.conversionFailed }
    return output
  }
}

/// Supplies an AVAudioPCMBuffer to AVAudioConverter exactly once.
private final class OnceBuffer: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  var consumed = false

  init(_ buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }
}
