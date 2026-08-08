import Foundation

func makeSonioxConfiguration(apiKey: String) throws -> Data {
  let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !apiKey.isEmpty else { throw SonioxRealtimeClient.Failure.missingAPIKey }
  return try JSONEncoder().encode(SonioxConfiguration(apiKey: apiKey))
}

func sonioxEndOfStreamMessage() -> URLSessionWebSocketTask.Message {
  .string("")
}

func recoverableSonioxPartial(_ text: String) -> String? {
  let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
  return text.isEmpty ? nil : text
}

struct SonioxToken: Decodable, Equatable, Sendable {
  let text: String
  let isFinal: Bool

  enum CodingKeys: String, CodingKey {
    case text
    case isFinal = "is_final"
  }
}

struct SonioxTranscriptAssembler: Sendable {
  private(set) var finalizedText = ""
  private(set) var provisionalText = ""

  var currentText: String {
    (finalizedText + provisionalText).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  mutating func apply(_ tokens: [SonioxToken]) throws {
    let visibleTokens = tokens.filter { !Self.controlTokens.contains($0.text) }
    let finalizedText = finalizedText + visibleTokens.filter(\.isFinal).map(\.text).joined()
    let provisionalText = visibleTokens.filter { !$0.isFinal }.map(\.text).joined()
    guard (finalizedText + provisionalText).utf8.count <= ProviderResponseLimits.transcriptBytes
    else {
      throw SonioxRealtimeClient.Failure.transcriptTooLarge
    }
    self.finalizedText = finalizedText
    self.provisionalText = provisionalText
  }

  private static let controlTokens: Set<String> = ["<end>", "<fin>"]
}

protocol SonioxWebSocketTask: Sendable {
  func resume()
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: SonioxWebSocketTask {}

struct SonioxRealtimeClient: Sendable {
  enum Failure: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case providerError(status: Int, type: String?, message: String?)
    case responseFrameTooLarge
    case transcriptTooLarge
    case audioStreamTooLarge
    case finalResponseTimedOut
    case emptyTranscript
    case connectionFailed

    var errorDescription: String? {
      switch self {
      case .missingAPIKey:
        "A Soniox API key is required."
      case .invalidResponse:
        "Soniox returned an invalid response."
      case .providerError(let status, let type, let message):
        "Soniox returned HTTP \(status): \(message ?? type ?? "Unknown provider error.")"
      case .responseFrameTooLarge:
        "The Soniox response was too large."
      case .transcriptTooLarge:
        "The Soniox transcript was too large."
      case .audioStreamTooLarge:
        "The Soniox audio stream was too long."
      case .finalResponseTimedOut:
        "Soniox did not finish the transcript in time."
      case .emptyTranscript:
        "No speech was recognized."
      case .connectionFailed:
        "The connection to Soniox failed."
      }
    }
  }

  private enum StreamEvent: Sendable {
    case audioFinished
    case transcript(String)
    case finalResponseTimedOut
  }

  private static let endpoint = URL(
    string: "wss://stt-rt.soniox.com/transcribe-websocket")!

  private let makeWebSocketTask: @Sendable (URLRequest) -> any SonioxWebSocketTask

  init(session: URLSession = .shared) {
    self.makeWebSocketTask = { session.webSocketTask(with: $0) }
  }

  init(webSocketTaskFactory: @escaping @Sendable (URLRequest) -> any SonioxWebSocketTask) {
    self.makeWebSocketTask = webSocketTaskFactory
  }

  func transcribe(
    apiKey: String,
    audio: AsyncStream<Data>,
    onPartial: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let configuration = try makeSonioxConfiguration(apiKey: apiKey)
    var request = URLRequest(url: Self.endpoint)
    request.timeoutInterval = 15
    let socket = makeWebSocketTask(request)

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      socket.resume()
      defer { socket.cancel(with: .normalClosure, reason: nil) }

      do {
        try await socket.send(.string(String(decoding: configuration, as: UTF8.self)))
        return try await transcribe(socket: socket, audio: audio, onPartial: onPartial)
      } catch is CancellationError {
        throw CancellationError()
      } catch let failure as Failure {
        throw failure
      } catch {
        throw Failure.connectionFailed
      }
    } onCancel: {
      socket.cancel(with: .goingAway, reason: nil)
    }
  }

  private func transcribe(
    socket: any SonioxWebSocketTask,
    audio: AsyncStream<Data>,
    onPartial: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let (finishing, finishingBuilder) = AsyncStream<Void>.makeStream()
    return try await withThrowingTaskGroup(of: StreamEvent.self) { group in
      defer {
        finishingBuilder.finish()
        group.cancelAll()
        socket.cancel(with: .normalClosure, reason: nil)
      }

      group.addTask {
        var audioBytes = 0
        for await chunk in audio {
          try Task.checkCancellation()
          guard !chunk.isEmpty else { continue }
          guard chunk.count <= ProviderResponseLimits.sonioxAudioBytes - audioBytes else {
            throw Failure.audioStreamTooLarge
          }
          audioBytes += chunk.count
          try await socket.send(.data(chunk))
        }
        try Task.checkCancellation()
        finishingBuilder.yield(())
        finishingBuilder.finish()
        try await socket.send(sonioxEndOfStreamMessage())
        return .audioFinished
      }
      group.addTask {
        .transcript(try await receiveTranscript(from: socket, onPartial: onPartial))
      }
      group.addTask {
        for await _ in finishing {
          try await Task.sleep(for: .seconds(15))
          return .finalResponseTimedOut
        }
        throw CancellationError()
      }

      while let event = try await group.next() {
        switch event {
        case .audioFinished:
          continue
        case .transcript(let text):
          return text
        case .finalResponseTimedOut:
          throw Failure.finalResponseTimedOut
        }
      }
      throw Failure.invalidResponse
    }
  }

  private func receiveTranscript(
    from socket: any SonioxWebSocketTask,
    onPartial: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    var assembler = SonioxTranscriptAssembler()
    var lastPartial = ""

    while true {
      try Task.checkCancellation()
      let message = try await socket.receive()
      let response = try decode(message)
      if let status = response.errorCode {
        throw Failure.providerError(
          status: status, type: response.errorType, message: response.errorMessage)
      }

      try assembler.apply(response.tokens ?? [])
      let currentText = assembler.currentText
      if !currentText.isEmpty, currentText != lastPartial {
        lastPartial = currentText
        await onPartial(currentText)
      }

      if response.finished == true {
        guard !currentText.isEmpty else { throw Failure.emptyTranscript }
        return currentText
      }
    }
  }

  private func decode(
    _ message: sending URLSessionWebSocketTask.Message
  ) throws -> SonioxResponse {
    let data: Data
    switch message {
    case .data(let value):
      guard value.count <= ProviderResponseLimits.sonioxFrameBytes else {
        throw Failure.responseFrameTooLarge
      }
      data = value
    case .string(let value):
      guard value.utf8.count <= ProviderResponseLimits.sonioxFrameBytes else {
        throw Failure.responseFrameTooLarge
      }
      data = Data(value.utf8)
    @unknown default:
      throw Failure.invalidResponse
    }

    do {
      return try JSONDecoder().decode(SonioxResponse.self, from: data)
    } catch {
      throw Failure.invalidResponse
    }
  }
}

private struct SonioxConfiguration: Encodable {
  let apiKey: String
  let model = "stt-rt-v5"
  let audioFormat = "pcm_s16le"
  let sampleRate = 16_000
  let numChannels = 1
  let enableEndpointDetection = true

  enum CodingKeys: String, CodingKey {
    case apiKey = "api_key"
    case model
    case audioFormat = "audio_format"
    case sampleRate = "sample_rate"
    case numChannels = "num_channels"
    case enableEndpointDetection = "enable_endpoint_detection"
  }
}

private struct SonioxResponse: Decodable {
  let tokens: [SonioxToken]?
  let finished: Bool?
  let errorCode: Int?
  let errorType: String?
  let errorMessage: String?

  enum CodingKeys: String, CodingKey {
    case tokens, finished
    case errorCode = "error_code"
    case errorType = "error_type"
    case errorMessage = "error_message"
  }
}
