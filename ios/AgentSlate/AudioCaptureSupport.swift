import AVFoundation
import Foundation

/// Converts and fans out one Soniox capture stream to the socket and Apple fallback file.
final class SonioxAudioSink: @unchecked Sendable {
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
final class AudioBufferConverter: @unchecked Sendable {
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
