import Foundation
@preconcurrency import Network

public actor BridgeClient {
  private enum Lifecycle {
    case stopped
    case connecting(NWConnection)
    case authenticating(NWConnection)
    case connected(NWConnection)
    case reconnecting

    var connection: NWConnection? {
      switch self {
      case .connecting(let connection), .authenticating(let connection),
        .connected(let connection):
        connection
      case .stopped, .reconnecting:
        nil
      }
    }
  }

  private struct PendingRequest {
    let continuation: CheckedContinuation<WireMessage, any Error>
    let timeoutTask: Task<Void, Never>
  }

  public nonisolated let events: AsyncStream<BridgeEvent>

  private let host: NWEndpoint.Host
  private let port: NWEndpoint.Port
  private let token: String
  private let eventContinuation: AsyncStream<BridgeEvent>.Continuation
  private let queue = DispatchQueue(label: "HerdrRemoteClient.BridgeClient")

  private var reconnectTask: Task<Void, Never>?
  private var decoder = FrameDecoder()
  private var pending: [String: PendingRequest] = [:]
  private var nextRequestID = 0
  private var reconnectAttempt = 0
  private var lifecycle = Lifecycle.stopped

  public init(host: String, port: UInt16 = 8765, token: String) throws {
    guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, port != 0 else {
      throw BridgeError.invalidAddress
    }
    guard token.utf8.count == 64,
      token.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      })
    else {
      throw BridgeError.invalidToken
    }

    self.host = NWEndpoint.Host(host)
    self.port = NWEndpoint.Port(rawValue: port)!
    self.token = token
    let stream = AsyncStream.makeStream(of: BridgeEvent.self)
    events = stream.stream
    eventContinuation = stream.continuation
  }

  public func start() {
    guard case .stopped = lifecycle else { return }
    reconnectAttempt = 0
    emit(.connectionState(.connecting))
    openConnection()
  }

  public func stop() {
    if case .stopped = lifecycle { return }
    reconnectTask?.cancel()
    reconnectTask = nil
    let activeConnection = lifecycle.connection
    lifecycle = .stopped
    activeConnection?.cancel()
    failPending(with: .notConnected)
    emit(.connectionState(.stopped))
  }

  public func requestSnapshot() async throws -> [BridgeAgent] {
    let message = try await request(.requestSnapshot)
    guard case .agentSnapshot(_, let agents) = message else {
      throw BridgeError.protocolViolation("snapshot response is invalid")
    }
    emit(.agents(agents))
    return agents
  }

  public func ping() async throws {
    let message = try await request(.ping)
    guard case .pong = message else {
      throw BridgeError.protocolViolation("ping response is invalid")
    }
  }

  public func focus(agentID: String) async throws {
    let message = try await request(.focusAgent(agentID: agentID))
    guard case .agentFocused = message else {
      throw BridgeError.protocolViolation("focus response is invalid")
    }
  }

  public func send(key: RemoteKey, to agentID: String) async throws {
    let message = try await request(.sendKey(agentID: agentID, key: key))
    guard case .inputAcknowledged = message else {
      throw BridgeError.protocolViolation("key response is invalid")
    }
  }

  public func send(text: String, submit: Bool, to agentID: String) async throws {
    guard text.utf8.count <= 8_192,
      !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw BridgeError.invalidText
    }
    let message = try await request(.sendText(agentID: agentID, text: text, submit: submit))
    guard case .inputAcknowledged = message else {
      throw BridgeError.protocolViolation("text response is invalid")
    }
  }

  private func openConnection() {
    switch lifecycle {
    case .stopped, .reconnecting:
      break
    case .connecting, .authenticating, .connected:
      return
    }
    decoder = FrameDecoder()
    let newConnection = NWConnection(host: host, port: port, using: .tcp)
    lifecycle = .connecting(newConnection)
    newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
      guard let self, let newConnection else { return }
      Task { await self.handle(state, from: newConnection) }
    }
    newConnection.start(queue: queue)
  }

  private func handle(_ state: NWConnection.State, from source: NWConnection) {
    guard lifecycle.connection === source else { return }
    switch state {
    case .ready:
      lifecycle = .authenticating(source)
      emit(.connectionState(.authenticating))
      receive(from: source)
      Task { await authenticate(on: source) }
    case .waiting(let error), .failed(let error):
      disconnected(source, error: .transport(error.localizedDescription))
    case .cancelled:
      disconnected(source, error: .transport("connection closed"))
    default:
      break
    }
  }

  private func authenticate(on source: NWConnection) async {
    do {
      let message = try await request(.authenticate(token: token))
      guard case .authenticated = message else {
        throw BridgeError.authenticationFailed
      }
      guard case .authenticating(let connection) = lifecycle, connection === source else {
        return
      }
      lifecycle = .connected(source)
      reconnectAttempt = 0
      emit(.connectionState(.connected))
    } catch let error as BridgeError {
      guard lifecycle.connection === source else { return }
      switch error {
      case .authenticationFailed:
        stopAfterFatalError(.authenticationFailed)
      case .transport:
        disconnected(source, error: error)
      default:
        stopAfterFatalError(error)
      }
    } catch {
      guard lifecycle.connection === source else { return }
      stopAfterFatalError(.protocolViolation(error.localizedDescription))
    }
  }

  private func stopAfterFatalError(_ error: BridgeError) {
    reconnectTask?.cancel()
    reconnectTask = nil
    let activeConnection = lifecycle.connection
    lifecycle = .stopped
    activeConnection?.cancel()
    failPending(with: error)
    emit(.error(error))
    emit(.connectionState(.stopped))
  }

  private func receive(from source: NWConnection) {
    source.receive(minimumIncompleteLength: 1, maximumLength: FrameDecoder.maximumBytes) {
      [weak self, weak source] data, _, complete, error in
      guard let self, let source else { return }
      Task { await self.received(data, complete: complete, error: error, from: source) }
    }
  }

  private func received(
    _ data: Data?,
    complete: Bool,
    error: NWError?,
    from source: NWConnection
  ) {
    guard lifecycle.connection === source else { return }
    do {
      if let data, !data.isEmpty {
        for frame in try decoder.append(data) {
          try process(frame)
        }
      }
    } catch let bridgeError as BridgeError {
      stopAfterFatalError(bridgeError)
      return
    } catch {
      let bridgeError = BridgeError.protocolViolation(error.localizedDescription)
      stopAfterFatalError(bridgeError)
      return
    }

    if let error {
      disconnected(source, error: .transport(error.localizedDescription))
    } else if complete {
      disconnected(source, error: .transport("connection closed"))
    } else {
      receive(from: source)
    }
  }

  private func process(_ frame: Data) throws {
    let message: WireMessage
    do {
      message = try JSONDecoder().decode(WireMessage.self, from: frame)
    } catch {
      throw BridgeError.protocolViolation("invalid protocol message")
    }
    if let id = message.id, let request = pending.removeValue(forKey: id) {
      request.timeoutTask.cancel()
      if case .error = message {
        request.continuation.resume(throwing: remoteError(from: message))
      } else {
        request.continuation.resume(returning: message)
      }
      return
    }

    switch message {
    case .agentSnapshot(_, let agents):
      emit(.agents(agents))
    case .herdrState(let state):
      emit(.herdrAvailability(state))
    case .error:
      emit(.error(remoteError(from: message)))
    case .authenticated, .agentFocused, .inputAcknowledged, .pong, .unknown:
      break
    }
  }

  private func request(_ payload: WireRequestPayload) async throws -> WireMessage {
    let connection: NWConnection
    switch payload {
    case .authenticate:
      guard case .authenticating(let activeConnection) = lifecycle else {
        throw BridgeError.notConnected
      }
      connection = activeConnection
    case .requestSnapshot, .focusAgent, .sendKey, .sendText, .ping:
      guard case .connected(let activeConnection) = lifecycle else {
        throw BridgeError.notConnected
      }
      connection = activeConnection
    }

    nextRequestID += 1
    let id = "swift-\(nextRequestID)"
    let request = WireRequest(id: id, payload: payload)
    var data = try JSONEncoder().encode(request)
    data.append(0x0A)
    guard data.count <= FrameDecoder.maximumBytes else {
      throw BridgeError.protocolViolation("JSON line exceeds size limit")
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timeoutTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(5))
          guard !Task.isCancelled else { return }
          await self?.requestTimedOut(id: id)
        }
        pending[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
        connection.send(
          content: data,
          completion: .contentProcessed { [weak self] error in
            guard let error, let self else { return }
            Task { await self.sendFailed(id: id, error: error) }
          })
      }
    } onCancel: {
      Task { await self.cancelRequest(id: id) }
    }
  }

  private func sendFailed(id: String, error: NWError) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timeoutTask.cancel()
    request.continuation.resume(
      throwing: BridgeError.transport(error.localizedDescription)
    )
  }

  private func requestTimedOut(id: String) {
    pending.removeValue(forKey: id)?.continuation.resume(throwing: BridgeError.requestTimedOut)
  }

  private func cancelRequest(id: String) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timeoutTask.cancel()
    request.continuation.resume(throwing: CancellationError())
  }

  private func remoteError(from message: WireMessage) -> BridgeError {
    guard case .error(_, let code, let detail) = message else {
      return .protocolViolation("error response is invalid")
    }
    return code == "authentication_failed"
      ? .authenticationFailed
      : .remote(code: code, message: detail)
  }

  private func disconnected(_ source: NWConnection?, error: BridgeError) {
    guard let source, lifecycle.connection === source else { return }
    source.cancel()
    failPending(with: error)
    scheduleReconnect()
  }

  private func scheduleReconnect() {
    reconnectTask?.cancel()
    reconnectAttempt += 1
    let attempt = reconnectAttempt
    lifecycle = .reconnecting
    emit(.connectionState(.reconnecting(attempt: attempt)))
    let delay = Self.reconnectDelayMilliseconds(for: attempt)
    reconnectTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(delay))
      guard !Task.isCancelled else { return }
      await self?.reconnectIfRunning()
    }
  }

  private func reconnectIfRunning() {
    guard case .reconnecting = lifecycle else { return }
    reconnectTask = nil
    openConnection()
  }

  static func reconnectDelayMilliseconds(for attempt: Int) -> Int {
    let delays = [500, 1_000, 2_000, 4_000, 5_000]
    return delays[min(max(attempt, 1) - 1, delays.count - 1)]
  }

  private func failPending(with error: BridgeError) {
    let requests = pending.values
    pending.removeAll()
    for request in requests {
      request.timeoutTask.cancel()
      request.continuation.resume(throwing: error)
    }
  }

  private func emit(_ event: BridgeEvent) {
    eventContinuation.yield(event)
  }
}
