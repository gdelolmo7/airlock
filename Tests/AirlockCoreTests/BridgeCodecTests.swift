import XCTest
@testable import AirlockCore

final class BridgeCodecTests: XCTestCase {
    func testDirectiveRoundTrips() throws {
        let original = BridgeEnvelope.directive(HookDirective(action: .deny, reason: "nope"))
        let line = try BridgeCodec.encodeLine(original)
        XCTAssertEqual(line.last, 0x0A)

        let decoded = try BridgeCodec.decode(BridgeEnvelope.self, from: line.dropLast())
        guard case let .directive(directive) = decoded else {
            return XCTFail("expected a directive, got \(decoded)")
        }
        XCTAssertEqual(directive.action, .deny)
        XCTAssertEqual(directive.reason, "nope")
    }

    func testHookPayloadRoundTrips() throws {
        let payload = HookPayload(
            source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
            cwd: "/x", terminal: TerminalInfo(app: "iTerm.app"),
            payload: Data("{\"hook_event_name\":\"PreToolUse\"}".utf8),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let line = try BridgeCodec.encodeLine(BridgeEnvelope.hookPayload(payload))
        let decoded = try BridgeCodec.decode(BridgeEnvelope.self, from: line.dropLast())
        guard case let .hookPayload(back) = decoded else {
            return XCTFail("expected a hook payload, got \(decoded)")
        }
        XCTAssertEqual(back.source, "claude-code")
        XCTAssertTrue(back.wantsDirective)
        XCTAssertEqual(back.payload, payload.payload)
    }

    func testDrainLinesSplitsOnNewline() throws {
        var buffer = Data()
        buffer.append(try BridgeCodec.encodeLine(BridgeEnvelope.ack))
        buffer.append(try BridgeCodec.encodeLine(BridgeEnvelope.hello(protocolVersion: 1)))
        // A partial trailing line must remain buffered for the next read.
        buffer.append(Data("{\"partial".utf8))

        let envelopes = try BridgeCodec.drainLines(BridgeEnvelope.self, from: &buffer)
        XCTAssertEqual(envelopes.count, 2)
        XCTAssertFalse(buffer.isEmpty)
    }

    func testOversizedLineThrows() {
        var buffer = Data(repeating: UInt8(ascii: "x"), count: BridgeCodec.maxLineBytes + 10)
        XCTAssertThrowsError(try BridgeCodec.drainLines(BridgeEnvelope.self, from: &buffer))
    }
}
