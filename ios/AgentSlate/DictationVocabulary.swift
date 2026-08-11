import Foundation

struct DictationVocabulary: Codable, Equatable, Sendable {
  enum Issue: LocalizedError, Equatable {
    case blank
    case controlCharacters
    case tooManyWords
    case termTooLong
    case duplicate
    case tooManyTerms
    case promptTooLarge
    case missingTerm

    var errorDescription: String? {
      switch self {
      case .blank:
        "Enter a word or short phrase."
      case .controlCharacters:
        "Remove line breaks, tabs, or other control characters."
      case .tooManyWords:
        "Use one or two words per vocabulary term."
      case .termTooLong:
        "Vocabulary terms can contain at most 60 characters."
      case .duplicate:
        "That term is already in the dictionary."
      case .tooManyTerms:
        "The dictionary can contain at most 100 terms."
      case .promptTooLarge:
        "The combined dictionary is full. Shorten or remove another term first."
      case .missingTerm:
        "That vocabulary term no longer exists."
      }
    }
  }

  static let maxTerms = 100
  static let maxTermCharacters = 60
  static let maxWhisperPromptBytes = 224
  static let storageKey = "dictationVocabulary"

  private static let whisperPromptPrefix = "Vocabulary: "

  private(set) var terms: [String]

  init() {
    terms = []
  }

  init(validating terms: [String]) throws {
    var vocabulary = Self()
    for term in terms {
      vocabulary = try vocabulary.adding(term).get()
    }
    self = vocabulary
  }

  var whisperPrompt: String? {
    guard !terms.isEmpty else { return nil }
    return Self.whisperPromptPrefix + terms.joined(separator: "; ")
  }

  var whisperPromptByteCount: Int {
    whisperPrompt?.utf8.count ?? 0
  }

  func adding(_ rawTerm: String) -> Result<Self, Issue> {
    guard terms.count < Self.maxTerms else { return .failure(.tooManyTerms) }
    return updated(rawTerm: rawTerm, replacing: nil)
  }

  func replacing(_ existingTerm: String, with rawTerm: String) -> Result<Self, Issue> {
    guard terms.contains(existingTerm) else { return .failure(.missingTerm) }
    return updated(rawTerm: rawTerm, replacing: existingTerm)
  }

  func removing(_ term: String) -> Self {
    Self(validatedTerms: terms.filter { $0 != term })
  }

  static func load(from defaults: UserDefaults = .standard) -> Self {
    guard let data = defaults.data(forKey: storageKey),
      let vocabulary = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return Self()
    }
    return vocabulary
  }

  func save(to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }

  private init(validatedTerms: [String]) {
    terms = validatedTerms.sorted(by: Self.alphabeticallyPrecedes)
  }

  private func updated(rawTerm: String, replacing existingTerm: String?) -> Result<Self, Issue> {
    guard !rawTerm.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      return .failure(.controlCharacters)
    }

    let term = Self.normalize(rawTerm)
    guard !term.isEmpty else { return .failure(.blank) }
    guard term.split(separator: " ").count <= 2 else { return .failure(.tooManyWords) }
    guard term.count <= Self.maxTermCharacters else { return .failure(.termTooLong) }

    let retainedTerms = terms.filter { $0 != existingTerm }
    guard !retainedTerms.contains(where: { Self.matchesIgnoringCase($0, term) }) else {
      return .failure(.duplicate)
    }

    let candidate = Self(validatedTerms: retainedTerms + [term])
    guard candidate.whisperPromptByteCount <= Self.maxWhisperPromptBytes else {
      return .failure(.promptTooLarge)
    }
    return .success(candidate)
  }

  private static func normalize(_ value: String) -> String {
    value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
  }

  private static func matchesIgnoringCase(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
  }

  private static func alphabeticallyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
  }

  private enum CodingKeys: String, CodingKey {
    case terms
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(validating: values.decode([String].self, forKey: .terms))
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(terms, forKey: .terms)
  }
}
