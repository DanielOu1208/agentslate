import Foundation
import Testing

@testable import HerdrRemoteClient

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
    WireRequest(id: "1", payload: .sendKey(agentID: "w1:p1", key: .arrowDown)))
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["version"] as? Int == 1)
  #expect(object["type"] as? String == "send_key")
  #expect(object["agent_id"] as? String == "w1:p1")
  #expect(object["key"] as? String == "arrow_down")
  #expect(object["token"] == nil)
  #expect(object["text"] == nil)
}

@Test func typedWireMessageRejectsIncompleteSnapshots() {
  let data = Data(#"{"version":1,"type":"agent_snapshot","event_id":1}"#.utf8)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(WireMessage.self, from: data)
  }
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
