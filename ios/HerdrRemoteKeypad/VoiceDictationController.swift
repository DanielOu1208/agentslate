@preconcurrency import AVFoundation
import Foundation
import Speech

/// On-device hold-to-talk dictation via iOS 26 SpeechAnalyzer + DictationTranscriber.
/// Audio never leaves the device.
@MainActor
final class VoiceDictationController {
  enum Failure: LocalizedError {
    case permissionDenied
    case localeNotSupported
    case assetUnavailable
    case audioSetupFailed
    case notListening

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
      }
    }
  }

  private(set) var isListening = false
  private(set) var isPrepared = false
  private(set) var finalizedText = ""
  private(set) var volatileText = ""
  private(set) var lastPartial = ""

  var liveText: String { finalizedText + volatileText }

  private let audioEngine = AVAudioEngine()
  private var transcriber: DictationTranscriber?
  private var analyzer: SpeechAnalyzer?
  private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
  private var analyzerFormat: AVAudioFormat?
  private var resultsTask: Task<Void, any Error>?
  private var resultFailure: (any Error)?
  private var sessionGeneration = 0
  private var preparedLocale: Locale?
  private var tapInstalled = false
  private var cancellationRequested = false
  private var onPartial: ((String) -> Void)?
  private var onFailure: ((any Error) -> Void)?

  func prepare() async throws {
    guard !isPrepared else { return }
    guard await AVAudioApplication.requestRecordPermission() else {
      throw Failure.permissionDenied
    }
    try Task.checkCancellation()

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
    isPrepared = true
  }

  func start(
    onPartial: @escaping (String) -> Void,
    onFailure: @escaping (any Error) -> Void
  ) async throws {
    guard !isListening else { return }
    if !isPrepared { try await prepare() }
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
    onPartial("")

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

  func finalize() async throws -> String {
    guard isListening else { throw Failure.notListening }
    let generation = sessionGeneration
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

  func cancel() async {
    let generation = sessionGeneration
    let analyzer = analyzer
    let resultsTask = resultsTask
    cancellationRequested = true
    guard isListening || analyzer != nil else {
      finishSession(for: generation)
      return
    }

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
    stopCapture()
    if cancelResults { resultsTask?.cancel() }
    resultsTask = nil
    analyzer = nil
    transcriber = nil
    analyzerFormat = nil
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
    DictationTranscriber(
      locale: locale,
      contentHints: [.shortForm],
      transcriptionOptions: [.punctuation, .etiquetteReplacements],
      reportingOptions: [.volatileResults],
      attributeOptions: []
    )
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
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement)
    try session.setActive(true, options: .notifyOthersOnDeactivation)
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
