import Foundation

struct DictationRecordingStore: @unchecked Sendable {
  enum Kind {
    case openRouter
    case soniox

    fileprivate var filenamePrefix: String {
      switch self {
      case .openRouter: "agentslate-"
      case .soniox: "agentslate-soniox-"
      }
    }
  }

  private let directory: URL
  private let fileManager: FileManager

  init(
    directory: URL = FileManager.default.temporaryDirectory,
    fileManager: FileManager = .default
  ) {
    self.directory = directory
    self.fileManager = fileManager
  }

  func purgeOrphans() throws {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    let contents = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    )
    for url in contents where Self.ownsRecording(at: url) {
      let values = try url.resourceValues(forKeys: keys)
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      try fileManager.removeItem(at: url)
    }
  }

  func recordingURL(for kind: Kind) -> URL {
    directory
      .appendingPathComponent("\(kind.filenamePrefix)\(UUID().uuidString)")
      .appendingPathExtension("wav")
  }

  func protect(_ url: URL) throws {
    try fileManager.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: url.path
    )
  }

  func remove(_ url: URL) {
    try? fileManager.removeItem(at: url)
  }

  static func ownsRecording(at url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "wav" else { return false }
    let stem = url.deletingPathExtension().lastPathComponent
    for prefix in [Kind.soniox.filenamePrefix, Kind.openRouter.filenamePrefix]
    where stem.hasPrefix(prefix) {
      let identifier = String(stem.dropFirst(prefix.count))
      return UUID(uuidString: identifier) != nil
    }
    return false
  }
}
