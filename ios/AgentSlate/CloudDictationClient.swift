import Foundation

struct DictationCredentials: Codable, Equatable, Sendable {
  let openRouterAPIKey: String

  init(openRouterAPIKey: String) {
    self.openRouterAPIKey = openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var isComplete: Bool {
    !openRouterAPIKey.isEmpty
  }
}

enum DictationMode: Equatable, Sendable {
  case apple
  case cloud(DictationCredentials)

  var isCloud: Bool {
    if case .cloud = self { return true }
    return false
  }
}

struct DictationResult: Equatable, Sendable {
  let rawText: String
  let text: String
  let fallbackNotice: String?
}

enum CloudDictationPhase: Sendable {
  case transcribing
  case appleFallback
  case cleaning
}

struct CleanupResolution: Equatable {
  let text: String
  let fallbackNotice: String?
}

func resolveCleanup(rawText: String, cleanedText: String?) -> CleanupResolution {
  guard let cleanedText else {
    return CleanupResolution(
      text: rawText, fallbackNotice: "Cleanup unavailable; used raw transcript.")
  }
  let validation = validateVoiceDraftText(cleanedText)
  guard validation.isValid else {
    return CleanupResolution(
      text: rawText, fallbackNotice: "Cleanup unavailable; used raw transcript.")
  }
  return CleanupResolution(text: validation.normalizedText, fallbackNotice: nil)
}

struct CloudDictationClient: Sendable {
  enum Failure: LocalizedError {
    case invalidResponse
    case requestFailed(Int)
    case emptyTranscript

    var errorDescription: String? {
      switch self {
      case .invalidResponse:
        "The dictation provider returned an invalid response."
      case .requestFailed(let status):
        "The dictation provider returned HTTP \(status)."
      case .emptyTranscript:
        "No speech was recognized."
      }
    }
  }

  static let transcriptionModel = "openai/whisper-large-v3-turbo"
  static let cleanupModel = "google/gemini-3.1-flash-lite"

  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func transcribe(audioURL: URL, apiKey: String) async throws -> String {
    let audioData = try Data(contentsOf: audioURL)
    let request = try makeTranscriptionRequest(audioData: audioData, apiKey: apiKey)
    let (data, response) = try await session.data(for: request)
    try Self.validate(response)
    let text = try JSONDecoder().decode(TranscriptionResponse.self, from: data).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw Failure.emptyTranscript }
    return text
  }

  func cleanup(transcript: String, apiKey: String) async throws -> String {
    let request = try makeCleanupRequest(transcript: transcript, apiKey: apiKey)
    let (data, response) = try await session.data(for: request)
    try Self.validate(response)
    guard
      let text = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
        .choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else {
      throw Failure.emptyTranscript
    }
    return text
  }

  func makeTranscriptionRequest(audioData: Data, apiKey: String) throws -> URLRequest {
    var request = URLRequest(
      url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      TranscriptionRequest(
        inputAudio: .init(data: audioData.base64EncodedString(), format: "wav"),
        model: Self.transcriptionModel,
        temperature: 0,
        provider: Provider(zdr: true)
      ))
    return request
  }

  func makeCleanupRequest(transcript: String, apiKey: String) throws -> URLRequest {
    var request = URLRequest(
      url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      OpenRouterRequest(
        model: Self.cleanupModel,
        messages: [
          Message(role: "system", content: Self.cleanupInstruction),
          Message(role: "user", content: transcript),
        ],
        temperature: 0,
        maxTokens: 4_096,
        reasoning: Reasoning(effort: "none"),
        provider: Provider(zdr: true)
      ))
    return request
  }

  private static func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else {
      throw Failure.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      throw Failure.requestFailed(response.statusCode)
    }
  }

  private static let cleanupInstruction = """
    Lightly clean this speech transcript for use as an instruction to a coding agent. Return only \
    the cleaned text. Remove filler words and abandoned false starts, apply explicit corrections, \
    and fix obvious punctuation and grammar. Preserve the speaker's meaning, language, uncertainty, \
    technical names, identifiers, file paths, URLs, shell commands, and numbers. Do not add facts, \
    explanations, markdown fences, or instructions that were not spoken.
    """
}

private struct TranscriptionRequest: Encodable {
  let inputAudio: InputAudio
  let model: String
  let temperature: Double
  let provider: Provider

  enum CodingKeys: String, CodingKey {
    case inputAudio = "input_audio"
    case model, temperature, provider
  }

  struct InputAudio: Encodable {
    let data: String
    let format: String
  }
}

private struct TranscriptionResponse: Decodable {
  let text: String
}

private struct OpenRouterRequest: Encodable {
  let model: String
  let messages: [Message]
  let temperature: Int
  let maxTokens: Int
  let reasoning: Reasoning
  let provider: Provider

  enum CodingKeys: String, CodingKey {
    case model, messages, temperature, reasoning, provider
    case maxTokens = "max_tokens"
  }
}

private struct Message: Codable {
  let role: String
  let content: String
}

private struct Reasoning: Encodable {
  let effort: String
}

private struct Provider: Encodable {
  let zdr: Bool
}

private struct OpenRouterResponse: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let message: Message
  }
}
