@preconcurrency import AVFoundation
import Foundation
import Speech

func normalizedAudioLevel(decibels: Float) -> Double {
  guard decibels.isFinite else { return 0 }
  return Double(min(max((decibels + 50) / 50, 0), 1))
}

private func audioLevel(for buffer: AVAudioPCMBuffer) -> Double {
  guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
  let count = Int(buffer.frameLength)
  var squareSum: Float = 0
  for index in 0..<count {
    squareSum += samples[index] * samples[index]
  }
  let rootMeanSquare = sqrt(squareSum / Float(count))
  return normalizedAudioLevel(decibels: rootMeanSquare > 0 ? 20 * log10(rootMeanSquare) : -50)
}

/// Hold-to-talk dictation with optional user-funded cloud transcription and on-device fallback.
actor VoiceDictationController {
  enum Failure: LocalizedError {
    case permissionDenied
    case localeNotSupported
    case assetUnavailable
    case audioSetupFailed
    case notListening
    case transcriptionFailed
    case sonioxAndAppleFallbackFailed(soniox: String, apple: String)

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
      case .sonioxAndAppleFallbackFailed(let soniox, let apple):
        "Soniox could not finish: \(soniox) Apple fallback also failed: \(apple)"
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
  private let sonioxClient: SonioxRealtimeClient
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
  private var sonioxFormat: AVAudioFormat?
  private var sonioxFile: AVAudioFile?
  private var sonioxSink: SonioxAudioSink?
  private var sonioxTask: Task<String, any Error>?
  private var meterTask: Task<Void, Never>?
  private var tapInstalled = false
  private var cancellationRequested = false
  private var onPartial: (@MainActor @Sendable (String) -> Void)?
  private var onLevel: (@MainActor @Sendable (Double) -> Void)?
  private var onFailure: (@MainActor @Sendable (any Error) async -> Void)?

  init(
    cloudClient: CloudDictationClient = CloudDictationClient(),
    sonioxClient: SonioxRealtimeClient = SonioxRealtimeClient()
  ) {
    self.cloudClient = cloudClient
    self.sonioxClient = sonioxClient
  }

  func isPrepared(for mode: DictationMode) -> Bool {
    guard microphonePrepared else { return false }
    return switch mode {
    case .apple:
      applePrepared && transcriber != nil && analyzer != nil && analyzerFormat != nil
    case .openRouter:
      recorder != nil && recordingURL != nil
    case .soniox:
      sonioxFormat != nil && sonioxFile != nil && sonioxSink == nil && recordingURL != nil
    }
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

    switch mode {
    case .apple:
      try await prepareAppleCapture()
    case .openRouter:
      try prepareCloudRecording()
    case .soniox:
      try prepareSonioxRecording()
    }
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

  private func prepareAppleCapture() async throws {
    guard transcriber == nil, analyzer == nil, analyzerFormat == nil else { return }
    try await prepareApple()
    guard let locale = preparedLocale else { throw Failure.localeNotSupported }

    let transcriber = makeTranscriber(locale: locale)
    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      options: .init(priority: .userInitiated, modelRetention: .lingering)
    )
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [transcriber]
    ) else {
      throw Failure.audioSetupFailed
    }
    try await analyzer.prepareToAnalyze(in: format)
    try Task.checkCancellation()

    self.transcriber = transcriber
    self.analyzer = analyzer
    analyzerFormat = format
  }

  func start(
    mode: DictationMode,
    onPartial: @escaping @MainActor @Sendable (String) -> Void,
    onLevel: @escaping @MainActor @Sendable (Double) -> Void,
    onFailure: @escaping @MainActor @Sendable (any Error) async -> Void
  ) async throws {
    guard !isListening else { return }
    if !isPrepared(for: mode) { try await prepare(for: mode) }
    try Task.checkCancellation()

    sessionGeneration &+= 1
    let generation = sessionGeneration
    self.onPartial = onPartial
    self.onLevel = onLevel
    self.onFailure = onFailure
    finalizedText = ""
    volatileText = ""
    lastPartial = ""
    cancellationRequested = false
    resultFailure = nil
    activeMode = mode
    await onPartial("")
    await onLevel(0)

    switch mode {
    case .openRouter:
      do {
        try startCloudRecording()
        isListening = true
        startCloudMetering(generation: generation)
      } catch {
        discardRecording()
        finishSession(for: generation)
        throw Failure.audioSetupFailed
      }
      return
    case .soniox(let apiKey, _):
      do {
        try startSonioxRecording(apiKey: apiKey, generation: generation)
        isListening = true
      } catch {
        discardRecording()
        finishSession(for: generation)
        throw Failure.audioSetupFailed
      }
      return
    case .apple:
      try await startAppleCapture(generation: generation)
    }
  }

  private func startAppleCapture(generation: Int) async throws {
    guard let transcriber, let analyzer, analyzerFormat != nil else {
      finishSession(for: generation)
      throw Failure.audioSetupFailed
    }

    resultsTask = Task { [weak self] in
      guard let self else { return }
      try await self.collectLiveResults(from: transcriber, generation: generation)
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

  private func collectLiveResults(
    from transcriber: DictationTranscriber,
    generation: Int
  ) async throws {
    do {
      for try await result in transcriber.results {
        let piece = String(result.text.characters)
        if result.isFinal {
          finalizedText += piece
          volatileText = ""
        } else {
          volatileText = piece
        }
        let live = liveText
        lastPartial = live
        await onPartial?(live)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard generation == sessionGeneration else { throw CancellationError() }
      lastPartial = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
      resultFailure = error
      let failureHandler = onFailure
      finishSession(for: generation, cancelResults: false)
      await failureHandler?(error)
      throw error
    }
  }

  func finalize(
    onPhase: @MainActor @Sendable (CloudDictationPhase) -> Void
  ) async throws -> DictationResult {
    guard isListening else { throw Failure.notListening }
    let generation = sessionGeneration

    switch activeMode {
    case .apple:
      let text = try await finalizeAppleCapture(generation: generation)
      return DictationResult(rawText: text, text: text, fallbackNotice: nil)
    case .openRouter(let apiKey, let cleanupEnabled):
      return try await finalizeOpenRouter(
        generation: generation,
        apiKey: apiKey,
        cleanupAPIKey: cleanupEnabled ? apiKey : nil,
        onPhase: onPhase
      )
    case .soniox(_, let cleanupAPIKey):
      return try await finalizeSoniox(
        generation: generation,
        cleanupAPIKey: cleanupAPIKey,
        onPhase: onPhase
      )
    }
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

  private func finalizeOpenRouter(
    generation: Int,
    apiKey: String,
    cleanupAPIKey: String?,
    onPhase: @MainActor @Sendable (CloudDictationPhase) -> Void
  ) async throws -> DictationResult {
    isListening = false
    stopMetering()
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

    await onPhase(.transcribing)
    let rawText: String
    var notice: String?
    do {
      rawText = try await cloudClient.transcribe(
        audioURL: recordingURL,
        apiKey: apiKey
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await onPhase(.appleFallback)
      do {
        rawText = try await transcribeAppleFile(recordingURL)
        notice = "OpenRouter transcription unavailable; used Apple transcription."
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        finishSession(for: generation)
        throw Failure.transcriptionFailed
      }
    }

    return try await finishCloudResult(
      rawText: rawText,
      cleanupAPIKey: cleanupAPIKey,
      notice: notice,
      generation: generation,
      onPhase: onPhase
    )
  }

  private func finalizeSoniox(
    generation: Int,
    cleanupAPIKey: String?,
    onPhase: @MainActor @Sendable (CloudDictationPhase) -> Void
  ) async throws -> DictationResult {
    isListening = false
    let sinkFailed = sonioxSink?.failed ?? true
    stopCapture()
    sonioxSink = nil
    sonioxFile = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    guard let recordingURL, let sonioxTask else {
      finishSession(for: generation)
      throw Failure.audioSetupFailed
    }
    self.sonioxTask = nil
    defer {
      try? FileManager.default.removeItem(at: recordingURL)
      if generation == sessionGeneration { self.recordingURL = nil }
    }

    let rawText: String
    var notice: String?
    do {
      guard !sinkFailed else { throw Failure.transcriptionFailed }
      rawText = try await withTaskCancellationHandler {
        try await sonioxTask.value
      } onCancel: {
        sonioxTask.cancel()
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let sonioxError {
      await onPhase(.appleFallback)
      do {
        rawText = try await transcribeAppleFile(recordingURL)
        notice = "Soniox unavailable; used Apple transcription."
      } catch is CancellationError {
        throw CancellationError()
      } catch let appleError {
        if let partial = recoverableSonioxPartial(lastPartial) {
          rawText = partial
          notice =
            "Soniox could not finalize and Apple fallback was unavailable; used the latest live transcript."
        } else {
          finishSession(for: generation)
          throw Failure.sonioxAndAppleFallbackFailed(
            soniox: sonioxError.localizedDescription,
            apple: appleError.localizedDescription
          )
        }
      }
    }

    return try await finishCloudResult(
      rawText: rawText,
      cleanupAPIKey: cleanupAPIKey,
      notice: notice,
      generation: generation,
      onPhase: onPhase
    )
  }

  private func finishCloudResult(
    rawText: String,
    cleanupAPIKey: String?,
    notice: String?,
    generation: Int,
    onPhase: @MainActor @Sendable (CloudDictationPhase) -> Void
  ) async throws -> DictationResult {
    try Task.checkCancellation()
    guard generation == sessionGeneration, !cancellationRequested else {
      throw CancellationError()
    }

    var resultText = rawText
    var resultNotice = notice
    if let cleanupAPIKey {
      await onPhase(.cleaning)
      let cleanedText = try? await cloudClient.cleanup(
        transcript: rawText,
        apiKey: cleanupAPIKey
      )
      try Task.checkCancellation()
      guard generation == sessionGeneration, !cancellationRequested else {
        throw CancellationError()
      }

      let cleanup = resolveCleanup(rawText: rawText, cleanedText: cleanedText)
      resultText = cleanup.text
      if let cleanupNotice = cleanup.fallbackNotice {
        resultNotice = resultNotice.map { "\($0) \(cleanupNotice)" } ?? cleanupNotice
      }
    }

    lastPartial = resultText
    finishSession(for: generation)
    return DictationResult(rawText: rawText, text: resultText, fallbackNotice: resultNotice)
  }

  func cancel() async {
    let generation = sessionGeneration
    let analyzer = analyzer
    let resultsTask = resultsTask
    cancellationRequested = true
    guard
      isListening || analyzer != nil || recorder != nil || sonioxTask != nil
        || recordingURL != nil
    else {
      finishSession(for: generation)
      return
    }

    discardRecording()
    stopCapture()
    await analyzer?.cancelAndFinishNow()
    if let resultsTask {
      resultsTask.cancel()
      _ = await resultsTask.result
    }
    finishSession(for: generation)
  }

  private func finishSession(for generation: Int, cancelResults: Bool = true) {
    guard generation == sessionGeneration else { return }
    stopMetering()
    stopCapture()
    if cancelResults { resultsTask?.cancel() }
    resultsTask = nil
    analyzer = nil
    transcriber = nil
    analyzerFormat = nil
    recorder = nil
    sonioxSink?.finish()
    sonioxSink = nil
    sonioxTask?.cancel()
    sonioxTask = nil
    sonioxFile = nil
    sonioxFormat = nil
    onPartial = nil
    onLevel = nil
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
    sonioxSink?.finish()
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

  private func prepareCloudRecording() throws {
    guard recorder == nil, recordingURL == nil else { return }
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
    recorder.isMeteringEnabled = true
    guard recorder.prepareToRecord() else {
      try? FileManager.default.removeItem(at: url)
      throw Failure.audioSetupFailed
    }
    recordingURL = url
    self.recorder = recorder
  }

  private func startCloudRecording() throws {
    guard let recorder, recordingURL != nil else { throw Failure.audioSetupFailed }
    try setupAudioSession()
    guard recorder.record() else { throw Failure.audioSetupFailed }
  }

  private func prepareSonioxRecording() throws {
    guard sonioxFile == nil, sonioxFormat == nil, recordingURL == nil else { return }
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
      )
    else {
      throw Failure.audioSetupFailed
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentslate-soniox-\(UUID().uuidString)")
      .appendingPathExtension("wav")
    do {
      sonioxFile = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatInt16,
        interleaved: true
      )
      sonioxFormat = format
      recordingURL = url
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw Failure.audioSetupFailed
    }
  }

  private func startSonioxRecording(apiKey: String, generation: Int) throws {
    guard let sonioxFile, let sonioxFormat, recordingURL != nil else {
      throw Failure.audioSetupFailed
    }
    let (audio, builder) = AsyncStream<Data>.makeStream()
    let sink = SonioxAudioSink(format: sonioxFormat, file: sonioxFile, builder: builder)
    sonioxSink = sink
    sonioxTask = Task { [weak self] in
      guard let self else { throw CancellationError() }
      return try await self.sonioxClient.transcribe(
        apiKey: apiKey,
        audio: audio,
        onPartial: { [weak self] text in
          await self?.receiveSonioxPartial(text, generation: generation)
        }
      )
    }

    try setupAudioSession()
    let levelHandler = onLevel
    let input = audioEngine.inputNode
    let micFormat = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { @Sendable buffer, _ in
      let level = audioLevel(for: buffer)
      Task { @MainActor in levelHandler?(level) }
      sink.process(buffer)
    }
    tapInstalled = true
    audioEngine.prepare()
    try audioEngine.start()
  }

  private func receiveSonioxPartial(_ text: String, generation: Int) async {
    guard generation == sessionGeneration, isListening else { return }
    lastPartial = text
    await onPartial?(text)
  }

  private func startCloudMetering(generation: Int) {
    meterTask?.cancel()
    meterTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.reportCloudLevel(generation: generation)
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  private func reportCloudLevel(generation: Int) async {
    guard generation == sessionGeneration, isListening, let recorder else { return }
    recorder.updateMeters()
    await onLevel?(normalizedAudioLevel(decibels: recorder.averagePower(forChannel: 0)))
  }

  private func stopMetering() {
    meterTask?.cancel()
    meterTask = nil
  }

  private func discardRecording() {
    stopMetering()
    recorder?.stop()
    recorder = nil
    sonioxSink?.finish()
    sonioxTask?.cancel()
    sonioxTask = nil
    sonioxSink = nil
    sonioxFile = nil
    sonioxFormat = nil
    if let recordingURL {
      try? FileManager.default.removeItem(at: recordingURL)
      self.recordingURL = nil
    }
  }

  private func transcribeAppleFile(_ url: URL) async throws -> String {
    try await prepareApple()
    guard let locale = preparedLocale else { throw Failure.localeNotSupported }
    let transcriber = makeTranscriber(locale: locale, reportsVolatileResults: false)
    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      options: .init(priority: .userInitiated, modelRetention: .lingering)
    )
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
    let levelHandler = onLevel
    let input = audioEngine.inputNode
    let micFormat = input.outputFormat(forBus: 0)

    input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { @Sendable buffer, _ in
      let level = audioLevel(for: buffer)
      Task { @MainActor in levelHandler?(level) }
      guard let converted = try? converter.convert(buffer, to: target) else { return }
      builder.yield(AnalyzerInput(buffer: converted))
    }
    tapInstalled = true

    audioEngine.prepare()
    try audioEngine.start()
  }
}

/// Converts and fans out one Soniox capture stream to the socket and Apple fallback file.
private final class SonioxAudioSink: @unchecked Sendable {
  private let converter = AudioBufferConverter()
  private let format: AVAudioFormat
  private let file: AVAudioFile
  private let builder: AsyncStream<Data>.Continuation
  private let failureLock = NSLock()
  private var hasFailed = false

  init(
    format: AVAudioFormat,
    file: AVAudioFile,
    builder: AsyncStream<Data>.Continuation
  ) {
    self.format = format
    self.file = file
    self.builder = builder
  }

  var failed: Bool {
    failureLock.withLock { hasFailed }
  }

  func process(_ buffer: AVAudioPCMBuffer) {
    guard !failed else { return }
    do {
      let converted = try converter.convert(buffer, to: format)
      try file.write(from: converted)
      let audioBuffer = converted.audioBufferList.pointee.mBuffers
      guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return }
      builder.yield(Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize)))
    } catch {
      failureLock.withLock { hasFailed = true }
      builder.finish()
    }
  }

  func finish() {
    builder.finish()
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
