import Foundation
@preconcurrency import Network
import Testing

@testable import AgentSlateClient

private let testCredential = BridgeCredential(
  deviceID: String(repeating: "b", count: 32),
  credential: String(repeating: "a", count: 64)
)

private enum TestFailure: Error {
  case timeout
  case listenerFailed
}

private struct RecordedRequest: Equatable, Sendable {
  let type: String
  let session: String?
  let agentID: String?
  let key: String?
  let action: String?
  let text: String?
  let submit: Bool?
}

private final class FakeBridge: @unchecked Sendable {
  private let queue = DispatchQueue(label: "AgentSlateClientTests.FakeBridge")
  private let listener: NWListener
  private let lock = NSLock()
  private let rejectAuthentication: Bool
  private let dropFirstConnection: Bool
  private let dropOnPing: Bool
  private let ignorePing: Bool
  private var connections = 0
  private var snapshotRequests = 0
  private var recorded: [RecordedRequest] = []

  init(
    rejectAuthentication: Bool = false,
    dropFirstConnection: Bool = false,
    dropOnPing: Bool = false,
    ignorePing: Bool = false
  ) throws {
    self.rejectAuthentication = rejectAuthentication
    self.dropFirstConnection = dropFirstConnection
    self.dropOnPing = dropOnPing
    self.ignorePing = ignorePing
    listener = try NWListener(using: .tcp, on: .any)
  }

  var connectionCount: Int {
    lock.withLock { connections }
  }

  var requests: [RecordedRequest] {
    lock.withLock { recorded }
  }

  var snapshotRequestCount: Int {
    lock.withLock { snapshotRequests }
  }

  func start() async throws -> UInt16 {
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    for _ in 0..<100 {
      if let port = listener.port?.rawValue, port != 0 {
        return port
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.listenerFailed
  }

  func stop() {
    listener.cancel()
  }

  private func accept(_ connection: NWConnection) {
    let number = lock.withLock {
      connections += 1
      return connections
    }
    let handler = FakeConnection(
      connection: connection,
      queue: queue,
      server: self,
      number: number
    )
    connection.stateUpdateHandler = { state in
      if case .ready = state {
        handler.receive()
      }
    }
    connection.start(queue: queue)
  }

  fileprivate func handle(_ request: [String: Any], on handler: FakeConnection) {
    guard let type = request["type"] as? String, let id = request["id"] as? String else {
      return
    }

    switch type {
    case "pair":
      if request["code"] as? String == "123456",
        request["device_name"] as? String == "Test iPhone"
      {
        handler.send([
          response(
            id: id,
            type: "paired",
            extra: [
              "device_id": testCredential.deviceID,
              "credential": testCredential.credential,
            ]
          )
        ], cancelAfterSending: true)
      } else {
        handler.send([
          response(
            id: id,
            type: "error",
            extra: ["code": "pairing_failed", "message": "pairing failed"]
          )
        ], cancelAfterSending: true)
      }
    case "authenticate":
      if rejectAuthentication
        || request["device_id"] as? String != testCredential.deviceID
        || request["credential"] as? String != testCredential.credential
      {
        handler.send(
          [
            response(
              id: id, type: "error",
              extra: [
                "code": "authentication_failed",
                "message": "authentication failed",
              ])
          ], cancelAfterSending: true)
      } else if dropFirstConnection, handler.number == 1 {
        handler.send([response(id: id, type: "authenticated")], cancelAfterSending: true)
      } else {
        handler.send([
          response(id: id, type: "authenticated"),
          event(
            type: "session_snapshot",
            extra: [
              "sessions": [
                ["name": "default", "default": true],
                ["name": "team", "default": false],
              ]
            ]),
          event(type: "herdr_state", extra: ["session": "default", "state": "connected"]),
          snapshot(eventID: 2),
        ])
      }
    case "request_snapshot":
      lock.withLock { snapshotRequests += 1 }
      handler.send([snapshot(id: id)])
    case "ping":
      if dropOnPing {
        handler.cancel()
      } else if !ignorePing {
        handler.send([response(id: id, type: "pong")])
      }
    case "focus_agent", "send_key", "send_action", "send_text":
      if request["agent_id"] as? String == "missing" {
        handler.send([
          response(
            id: id,
            type: "error",
            extra: ["code": "agent_not_found", "message": "agent is unavailable"])
        ])
        return
      }
      lock.withLock {
        recorded.append(
          RecordedRequest(
            type: type,
            session: request["session"] as? String,
            agentID: request["agent_id"] as? String,
            key: request["key"] as? String,
            action: request["action"] as? String,
            text: request["text"] as? String,
            submit: request["submit"] as? Bool
          ))
      }
      handler.send([
        response(id: id, type: type == "focus_agent" ? "agent_focused" : "input_acknowledged")
      ])
    case "revoke_self":
      handler.send([response(id: id, type: "revoked")])
    default:
      handler.send([
        response(
          id: id, type: "error",
          extra: [
            "code": "invalid_message",
            "message": "invalid protocol message",
          ])
      ])
    }
  }

  private func response(id: String, type: String, extra: [String: Any] = [:]) -> [String: Any] {
    ["version": 3, "id": id, "type": type].merging(extra) { _, new in new }
  }

  private func event(type: String, extra: [String: Any]) -> [String: Any] {
    ["version": 3, "event_id": 1, "type": type].merging(extra) { _, new in new }
  }

  private func snapshot(id: String? = nil, eventID: Int? = nil) -> [String: Any] {
    var message: [String: Any] = [
      "version": 3,
      "type": "agent_snapshot",
      "session": "default",
      "herdr_protocol": 16,
      "herdr_version": "0.7.4",
      "agents": [
        [
          "id": "w1:p1",
          "kind": "codex",
          "name": "codex",
          "status": "blocked",
          "title": "Approve command",
          "workspace": "demo",
          "cwd": "/tmp/demo",
        ]
      ],
    ]
    message["id"] = id
    message["event_id"] = eventID
    return message
  }
}

private final class FakeConnection: @unchecked Sendable {
  let number: Int
  private let connection: NWConnection
  private let queue: DispatchQueue
  private weak var server: FakeBridge?
  private var decoder = FrameDecoder()

  init(connection: NWConnection, queue: DispatchQueue, server: FakeBridge, number: Int) {
    self.connection = connection
    self.queue = queue
    self.server = server
    self.number = number
  }

  func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: FrameDecoder.maximumBytes) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      if let data {
        for frame in (try? decoder.append(data)) ?? [] {
          if let request = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] {
            server?.handle(request, on: self)
          }
        }
      }
      if error == nil, !complete {
        receive()
      }
    }
  }

  func send(_ messages: [[String: Any]], cancelAfterSending: Bool = false) {
    var data = Data()
    for message in messages {
      data.append(try! JSONSerialization.data(withJSONObject: message))
      data.append(0x0A)
    }
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self] _ in
        guard cancelAfterSending, let self else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
          self.connection.cancel()
        }
      })
  }

  func cancel() {
    connection.cancel()
  }
}

private func withTimeout<T: Sendable>(
  seconds: Int = 3,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask(operation: operation)
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw TestFailure.timeout
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}

@Test func clientAuthenticatesReceivesAgentsAndSendsInput() async throws {
  let bridge = try FakeBridge()
  let port = try await bridge.start()
  let client = try BridgeClient(
    host: "127.0.0.1",
    port: port,
    credential: testCredential
  )
  let agents = Task { () throws -> [BridgeAgent] in
    for await event in client.events {
      if case .agents(session: "default", let agents) = event, !agents.isEmpty {
        return agents
      }
    }
    throw TestFailure.timeout
  }

  await client.start()
  #expect(try await withTimeout { try await agents.value }.first?.status == .blocked)
  try await client.ping()
  try await client.focus(agentID: "w1:p1", session: "default")
  do {
    try await client.focus(agentID: "missing", session: "default")
    Issue.record("remote focus error was not returned")
  } catch let BridgeError.remote(code, message) {
    #expect(code == "agent_not_found")
    #expect(message == "agent is unavailable")
  }
  try await client.send(key: .arrowDown, to: "w1:p1", session: "default")
  try await client.send(action: .accept, to: "w1:p1", session: "default")
  try await client.send(text: "continue", submit: true, to: "w1:p1", session: "default")
  do {
    try await client.send(key: .enter, to: "missing", session: "default")
    Issue.record("remote error was not returned")
  } catch let BridgeError.remote(code, message) {
    #expect(code == "agent_not_found")
    #expect(message == "agent is unavailable")
  }

  #expect(
    bridge.requests == [
      RecordedRequest(
        type: "focus_agent", session: "default", agentID: "w1:p1", key: nil, action: nil,
        text: nil, submit: nil),
      RecordedRequest(
        type: "send_key", session: "default", agentID: "w1:p1", key: "arrow_down",
        action: nil, text: nil, submit: nil),
      RecordedRequest(
        type: "send_action", session: "default", agentID: "w1:p1", key: nil,
        action: "accept", text: nil, submit: nil),
      RecordedRequest(
        type: "send_text", session: "default", agentID: "w1:p1", key: nil, action: nil,
        text: "continue", submit: true),
    ])
  #expect(bridge.snapshotRequestCount == 0)
  try await client.revokeSelf()
  await client.stop()
  bridge.stop()
}

@Test func pairReturnsPerDeviceCredential() async throws {
  let bridge = try FakeBridge()
  let port = try await bridge.start()
  let credential = try await BridgeClient.pair(
    host: "127.0.0.1",
    port: port,
    code: "123456",
    deviceName: "Test iPhone"
  )

  #expect(credential == testCredential)
  bridge.stop()
}

@Test func cancellingPairingCompletesPromptly() async throws {
  let operation = Task {
    try await BridgeClient.pair(
      host: "127.0.0.1",
      port: 9,
      code: "123456",
      deviceName: "Test iPhone"
    )
  }
  operation.cancel()
  do {
    _ = try await withTimeout { try await operation.value }
    Issue.record("cancelled pairing unexpectedly succeeded")
  } catch is CancellationError {
    // Expected.
  } catch TestFailure.timeout {
    Issue.record("cancelled pairing did not finish")
  } catch {
    // The local discard endpoint can fail before cancellation wins the race.
  }
}

@Test func authenticationFailureDoesNotReconnect() async throws {
  let bridge = try FakeBridge(rejectAuthentication: true)
  let port = try await bridge.start()
  let client = try BridgeClient(
    host: "127.0.0.1",
    port: port,
    credential: testCredential
  )
  let failure = Task { () throws -> BridgeError in
    for await event in client.events {
      if case .error(let error) = event {
        return error
      }
    }
    throw TestFailure.timeout
  }

  await client.start()
  #expect(try await withTimeout { try await failure.value } == .authenticationFailed)
  try await Task.sleep(for: .milliseconds(700))
  #expect(bridge.connectionCount == 1)
  bridge.stop()
}

@Test func transportFailureReconnects() async throws {
  let bridge = try FakeBridge(dropFirstConnection: true)
  let port = try await bridge.start()
  let client = try BridgeClient(
    host: "127.0.0.1",
    port: port,
    credential: testCredential
  )
  let connections = Task { () throws -> Int in
    var connectedEvents = 0
    var reconnectStarted = false
    var receivedFreshSnapshot = false
    for await event in client.events {
      if case .connectionState(.reconnecting) = event {
        reconnectStarted = true
      } else if case .agents = event, reconnectStarted {
        receivedFreshSnapshot = true
      } else if event == .connectionState(.connected) {
        connectedEvents += 1
      }
      if connectedEvents == 2, receivedFreshSnapshot {
        return connectedEvents
      }
    }
    throw TestFailure.timeout
  }

  await client.start()
  #expect(try await withTimeout { try await connections.value } == 2)
  #expect(bridge.connectionCount >= 2)
  await client.stop()
  bridge.stop()
}

@Test func unavailableEndpointStartsBoundedReconnect() async throws {
  let bridge = try FakeBridge()
  let port = try await bridge.start()
  bridge.stop()
  try await Task.sleep(for: .milliseconds(100))

  let client = try BridgeClient(
    host: "127.0.0.1",
    port: port,
    credential: testCredential
  )
  let reconnectAttempt = Task { () throws -> Int in
    for await event in client.events {
      if case .connectionState(.reconnecting(let attempt)) = event {
        return attempt
      }
    }
    throw TestFailure.timeout
  }

  await client.start()
  #expect(try await withTimeout { try await reconnectAttempt.value } == 1)
  await client.stop()
}

@Test func invalidConfigurationAndTextFailLocally() async throws {
  do {
    _ = try BridgeClient(
      host: "127.0.0.1",
      credential: BridgeCredential(deviceID: "bad", credential: "bad")
    )
    Issue.record("invalid credential was accepted")
  } catch let error as BridgeError {
    #expect(error == .invalidCredential)
  }
  await #expect(throws: BridgeError.invalidPairingCode) {
    _ = try await BridgeClient.pair(
      host: "127.0.0.1", code: "12-456", deviceName: "Test iPhone")
  }

  let client = try BridgeClient(
    host: "127.0.0.1",
    credential: testCredential
  )
  do {
    try await client.send(
      text: "two\nlines", submit: true, to: "w1:p1", session: "default")
    Issue.record("control character was accepted")
  } catch let error as BridgeError {
    #expect(error == .invalidText)
  }
}

@Test func pendingRequestFailsWhenTransportCloses() async throws {
  let bridge = try FakeBridge(dropOnPing: true)
  let port = try await bridge.start()
  let client = try BridgeClient(
    host: "127.0.0.1",
    port: port,
    credential: testCredential
  )
  let connected = Task { () throws -> Void in
    for await event in client.events where event == .connectionState(.connected) {
      return
    }
    throw TestFailure.timeout
  }

  await client.start()
  try await withTimeout { try await connected.value }
  do {
    try await client.ping()
    Issue.record("ping unexpectedly succeeded")
  } catch let error as BridgeError {
    guard case .transport = error else {
      Issue.record("unexpected error: \(error)")
      return
    }
  }
  await client.stop()
  bridge.stop()
}

@Test func pendingRequestTimesOutWhenBridgeStaysOpen() async throws {
  let bridge = try FakeBridge(ignorePing: true)
  let port = try await bridge.start()
  let client = try BridgeClient(
    host: "127.0.0.1",
    port: port,
    credential: testCredential
  )
  let connected = Task { () throws -> Void in
    for await event in client.events where event == .connectionState(.connected) {
      return
    }
    throw TestFailure.timeout
  }

  await client.start()
  try await withTimeout { try await connected.value }
  do {
    try await withTimeout(seconds: 6) { try await client.ping() }
    Issue.record("ping unexpectedly succeeded")
  } catch let error as BridgeError {
    #expect(error == .requestTimedOut)
  }
  await client.stop()
  bridge.stop()
}

@Test func stopCancelsScheduledReconnect() async throws {
  let bridge = try FakeBridge(dropFirstConnection: true)
  let port = try await bridge.start()
  let client = try BridgeClient(
    host: "127.0.0.1",
    port: port,
    credential: testCredential
  )
  let reconnecting = Task { () throws -> Void in
    for await event in client.events {
      if case .connectionState(.reconnecting) = event {
        return
      }
    }
    throw TestFailure.timeout
  }

  await client.start()
  try await withTimeout { try await reconnecting.value }
  await client.stop()
  try await Task.sleep(for: .milliseconds(700))
  #expect(bridge.connectionCount == 1)
  bridge.stop()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTSLATE_BRIDGE_CREDENTIAL_FILE"] != nil))
func liveRustBridgeSmokeTest() async throws {
  let environment = ProcessInfo.processInfo.environment
  let address = environment["AGENTSLATE_BRIDGE_ADDRESS"] ?? "127.0.0.1:8765"
  guard let separator = address.lastIndex(of: ":"),
    let port = UInt16(address[address.index(after: separator)...]),
    let credentialFile = environment["AGENTSLATE_BRIDGE_CREDENTIAL_FILE"]
  else {
    throw BridgeError.invalidAddress
  }
  let host = String(address[..<separator])
  let credential = try JSONDecoder().decode(
    BridgeCredential.self, from: Data(contentsOf: URL(fileURLWithPath: credentialFile)))
  let client = try BridgeClient(host: host, port: port, credential: credential)
  let agents = Task { () throws -> [BridgeAgent] in
    for await event in client.events {
      if case .agents(_, let agents) = event {
        return agents
      }
    }
    throw TestFailure.timeout
  }

  await client.start()
  _ = try await withTimeout { try await agents.value }
  try await client.ping()
  await client.stop()
}
