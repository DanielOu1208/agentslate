import Foundation

public struct BridgeAgent: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let kind: String
  public let name: String
  public let status: AgentStatus
  public let title: String?
  public let workspace: String?
  public let cwd: String?

  public init(
    id: String,
    kind: String,
    name: String,
    status: AgentStatus,
    title: String? = nil,
    workspace: String? = nil,
    cwd: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.status = status
    self.title = title
    self.workspace = workspace
    self.cwd = cwd
  }
}

public struct BridgeSession: Codable, Hashable, Identifiable, Sendable {
  public let name: String
  public let isDefault: Bool

  public var id: String { name }

  public init(name: String, isDefault: Bool = false) {
    self.name = name
    self.isDefault = isDefault
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case isDefault = "default"
  }
}

public enum AgentStatus: Hashable, Sendable {
  case working
  case blocked
  case done
  case idle
  case unknown(String)
}

extension AgentStatus: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self =
      switch value {
      case "working": .working
      case "blocked": .blocked
      case "done": .done
      case "idle": .idle
      default: .unknown(value)
      }
  }

  public func encode(to encoder: Encoder) throws {
    let value =
      switch self {
      case .working: "working"
      case .blocked: "blocked"
      case .done: "done"
      case .idle: "idle"
      case .unknown(let value): value
      }
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public enum RemoteKey: String, Codable, CaseIterable, Sendable {
  case arrowUp = "arrow_up"
  case arrowDown = "arrow_down"
  case arrowLeft = "arrow_left"
  case arrowRight = "arrow_right"
  case enter
  case escape
  case tab
  case shiftTab = "shift_tab"
  case space
}

public enum RemoteAction: String, Codable, CaseIterable, Sendable {
  case accept
  case deny
}

public enum ConnectionState: Equatable, Sendable {
  case stopped
  case connecting
  case authenticating
  case connected
  case reconnecting(attempt: Int)
}

public enum HerdrAvailability: String, Equatable, Sendable {
  case connected
  case unavailable
}

public enum BridgeEvent: Equatable, Sendable {
  case connectionState(ConnectionState)
  case sessions([BridgeSession])
  case herdrAvailability(session: String, state: HerdrAvailability)
  case agents(session: String, agents: [BridgeAgent])
  case error(BridgeError)
}

public enum BridgeError: Error, Equatable, Sendable {
  case invalidAddress
  case invalidToken
  case invalidText
  case notConnected
  case requestTimedOut
  case authenticationFailed
  case protocolViolation(String)
  case remote(code: String, message: String)
  case transport(String)
}

extension BridgeError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidAddress: "The bridge address is invalid."
    case .invalidToken: "The token must be 64 lowercase hexadecimal characters."
    case .invalidText: "Text is too large or contains control characters."
    case .notConnected: "The bridge is not connected."
    case .requestTimedOut: "The bridge did not respond in time."
    case .authenticationFailed: "Bridge authentication failed."
    case .protocolViolation(let message): "Bridge protocol error: \(message)"
    case .remote(_, let message): message
    case .transport(let message): "Network error: \(message)"
    }
  }
}

enum WireRequestPayload: Sendable {
  case authenticate(token: String)
  case requestSnapshot(session: String)
  case focusAgent(session: String, agentID: String)
  case sendKey(session: String, agentID: String, key: RemoteKey)
  case sendAction(session: String, agentID: String, action: RemoteAction)
  case sendText(session: String, agentID: String, text: String, submit: Bool)
  case ping
}

struct WireRequest: Encodable, Sendable {
  let version = 2
  let id: String
  let payload: WireRequestPayload

  enum CodingKeys: String, CodingKey {
    case version, id, type, token, session, key, action, text, submit
    case agentID = "agent_id"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(id, forKey: .id)

    switch payload {
    case .authenticate(let token):
      try container.encode("authenticate", forKey: .type)
      try container.encode(token, forKey: .token)
    case .requestSnapshot(let session):
      try container.encode("request_snapshot", forKey: .type)
      try container.encode(session, forKey: .session)
    case .focusAgent(let session, let agentID):
      try container.encode("focus_agent", forKey: .type)
      try container.encode(session, forKey: .session)
      try container.encode(agentID, forKey: .agentID)
    case .sendKey(let session, let agentID, let key):
      try container.encode("send_key", forKey: .type)
      try container.encode(session, forKey: .session)
      try container.encode(agentID, forKey: .agentID)
      try container.encode(key, forKey: .key)
    case .sendAction(let session, let agentID, let action):
      try container.encode("send_action", forKey: .type)
      try container.encode(session, forKey: .session)
      try container.encode(agentID, forKey: .agentID)
      try container.encode(action, forKey: .action)
    case .sendText(let session, let agentID, let text, let submit):
      try container.encode("send_text", forKey: .type)
      try container.encode(session, forKey: .session)
      try container.encode(agentID, forKey: .agentID)
      try container.encode(text, forKey: .text)
      try container.encode(submit, forKey: .submit)
    case .ping:
      try container.encode("ping", forKey: .type)
    }
  }
}

enum WireMessage: Sendable {
  case authenticated(id: String)
  case sessionSnapshot([BridgeSession])
  case agentSnapshot(id: String?, session: String, agents: [BridgeAgent])
  case agentFocused(id: String)
  case inputAcknowledged(id: String)
  case pong(id: String)
  case herdrState(session: String, state: HerdrAvailability)
  case error(id: String?, code: String, message: String)
  case unknown(id: String?, type: String)

  var id: String? {
    switch self {
    case .authenticated(let id), .agentFocused(let id), .inputAcknowledged(let id), .pong(let id): id
    case .agentSnapshot(let id, _, _), .error(let id, _, _), .unknown(let id, _): id
    case .sessionSnapshot, .herdrState: nil
    }
  }
}

extension WireMessage: Decodable {
  private enum CodingKeys: String, CodingKey {
    case version, id, type, code, message, session, sessions, state, agents
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == 2 else {
      throw DecodingError.dataCorruptedError(
        forKey: .version,
        in: container,
        debugDescription: "unsupported protocol version"
      )
    }

    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "authenticated":
      self = .authenticated(id: try container.decode(String.self, forKey: .id))
    case "session_snapshot":
      self = .sessionSnapshot(try container.decode([BridgeSession].self, forKey: .sessions))
    case "agent_snapshot":
      self = .agentSnapshot(
        id: try container.decodeIfPresent(String.self, forKey: .id),
        session: try container.decode(String.self, forKey: .session),
        agents: try container.decode([BridgeAgent].self, forKey: .agents)
      )
    case "agent_focused":
      self = .agentFocused(id: try container.decode(String.self, forKey: .id))
    case "input_acknowledged":
      self = .inputAcknowledged(id: try container.decode(String.self, forKey: .id))
    case "pong":
      self = .pong(id: try container.decode(String.self, forKey: .id))
    case "herdr_state":
      let rawState = try container.decode(String.self, forKey: .state)
      guard let state = HerdrAvailability(rawValue: rawState) else {
        throw DecodingError.dataCorruptedError(
          forKey: .state,
          in: container,
          debugDescription: "invalid Herdr state"
        )
      }
      self = .herdrState(
        session: try container.decode(String.self, forKey: .session),
        state: state
      )
    case "error":
      self = .error(
        id: try container.decodeIfPresent(String.self, forKey: .id),
        code: try container.decode(String.self, forKey: .code),
        message: try container.decode(String.self, forKey: .message)
      )
    default:
      self = .unknown(
        id: try container.decodeIfPresent(String.self, forKey: .id),
        type: type
      )
    }
  }
}
