import Foundation

struct FrameDecoder: Sendable {
  static let maximumBytes = 65_536

  private var buffer = Data()

  mutating func append(_ data: Data) throws -> [Data] {
    buffer.append(data)
    var frames: [Data] = []

    while let newline = buffer.firstIndex(of: 0x0A) {
      let length = buffer.distance(from: buffer.startIndex, to: newline) + 1
      guard length <= Self.maximumBytes else {
        throw BridgeError.protocolViolation("JSON line exceeds size limit")
      }

      var frame = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if frame.last == 0x0D {
        frame.removeLast()
      }
      frames.append(frame)
    }

    guard buffer.count <= Self.maximumBytes else {
      throw BridgeError.protocolViolation("JSON line exceeds size limit")
    }
    return frames
  }
}
