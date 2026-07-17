import Foundation
import Testing

@testable import AgentSlateClient

@Test func agentFixturesAndUnknownStatus() throws {
  let data = Data(
    #"{"id":"w1:p1","kind":"codex","name":"reviewer","status":"paused","title":null,"workspace":"demo","cwd":"/tmp","future_field":true}"#
      .utf8)
  let agent = try JSONDecoder().decode(BridgeAgent.self, from: data)
  #expect(agent.kind == "codex")
  #expect(agent.name == "reviewer")
  #expect(agent.status == .unknown("paused"))
  #expect(agent.workspace == "demo")
}

@Test func wireMessagesRejectInvalidUTF8() {
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(WireMessage.self, from: Data([0xFF]))
  }
}

@Test func typedWireRequestEncodesOnlyItsRequiredFields() throws {
  let data = try JSONEncoder().encode(
    WireRequest(
      id: "1", payload: .sendKey(session: "team", agentID: "w1:p1", key: .shiftTab)))
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["version"] as? Int == 3)
  #expect(object["type"] as? String == "send_key")
  #expect(object["session"] as? String == "team")
  #expect(object["agent_id"] as? String == "w1:p1")
  #expect(object["key"] as? String == "shift_tab")
  #expect(object["credential"] == nil)
  #expect(object["text"] == nil)
}

@Test func typedActionRequestEncodesOnlyItsRequiredFields() throws {
  let data = try JSONEncoder().encode(
    WireRequest(
      id: "2", payload: .sendAction(session: "default", agentID: "w1:p1", action: .deny)))
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["version"] as? Int == 3)
  #expect(object["type"] as? String == "send_action")
  #expect(object["agent_id"] as? String == "w1:p1")
  #expect(object["session"] as? String == "default")
  #expect(object["action"] as? String == "deny")
  #expect(object["key"] == nil)
  #expect(object["text"] == nil)
}

@Test func typedWireMessageRejectsIncompleteSnapshots() {
  let data = Data(#"{"version":3,"type":"agent_snapshot","event_id":1}"#.utf8)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(WireMessage.self, from: data)
  }
}

@Test func pairingAndAuthenticationEncodeOnlyCredentialsTheyNeed() throws {
  let pairData = try JSONEncoder().encode(
    WireRequest(id: "pair", payload: .pair(code: "123456", deviceName: "Test iPhone")))
  let pair = try #require(JSONSerialization.jsonObject(with: pairData) as? [String: Any])
  #expect(pair["version"] as? Int == 3)
  #expect(pair["type"] as? String == "pair")
  #expect(pair["code"] as? String == "123456")
  #expect(pair["device_name"] as? String == "Test iPhone")
  #expect(pair["credential"] == nil)

  let credential = BridgeCredential(
    deviceID: String(repeating: "b", count: 32),
    credential: String(repeating: "a", count: 64)
  )
  let authData = try JSONEncoder().encode(
    WireRequest(id: "auth", payload: .authenticate(credential)))
  let auth = try #require(JSONSerialization.jsonObject(with: authData) as? [String: Any])
  #expect(auth["type"] as? String == "authenticate")
  #expect(auth["device_id"] as? String == credential.deviceID)
  #expect(auth["credential"] as? String == credential.credential)
  #expect(auth["code"] == nil)
}

@Test func pairedMessageDecodesCredential() throws {
  let data = Data(
    #"{"version":3,"id":"pair","type":"paired","device_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credential":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
      .utf8
  )
  let message = try JSONDecoder().decode(WireMessage.self, from: data)
  guard case .paired("pair", let credential) = message else {
    Issue.record("paired response did not decode")
    return
  }
  #expect(credential.deviceID == String(repeating: "b", count: 32))
  #expect(credential.credential == String(repeating: "a", count: 64))
}

@Test func reconnectDelayIsCappedAtFiveSeconds() {
  #expect(
    [1, 2, 3, 4, 5, 10].map(BridgeClient.reconnectDelayMilliseconds) == [
      500, 1_000, 2_000, 4_000, 5_000, 5_000,
    ])
}

@Test func frameDecoderHandlesSplitCombinedAndCRLFFrames() throws {
  var decoder = FrameDecoder()
  #expect(try decoder.append(Data("{\"a\":".utf8)).isEmpty)
  let frames = try decoder.append(Data("1}\r\n{\"b\":2}\n".utf8))
  #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
}

@Test func frameDecoderRejectsOversizedFrames() {
  var decoder = FrameDecoder()
  #expect(throws: BridgeError.self) {
    try decoder.append(Data(repeating: 0x61, count: FrameDecoder.maximumBytes + 1))
  }
}
