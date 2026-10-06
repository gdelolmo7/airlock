import XCTest
import AirlockCore
@testable import AirlockApp

/// THE BUG THIS EXISTS FOR: the face was an agent-status mascot in an app that
/// is not only for agents. Expression and tint were two ternaries over session
/// state at the island call site, so somebody who never starts an agent — a
/// deliberate audience, with its own "I don't use coding agents" path in
/// onboarding — only ever saw a grey `.sleepy`, and nothing at all when music or
/// a meeting took the leading slot.
@MainActor
final class BloubFaceTests: XCTestCase {
    private typealias Face = BloubFace
    private func resolve(_ slot: CompactSlot,
                         _ ambient: Face.Ambient = .none) -> Face {
        Face.resolve(slot: slot, ambient: ambient)
    }

    // MARK: - The audience that never starts an agent

    /// THE regression. With agents off the ladder never yields an agent rung,
    /// so every one of these has to come from somewhere else — and each must be
    /// visibly distinct, or the character is decoration.
    func testANonAgentUserGetsAFullRangeOfStates() {
        let states: [Face.Ambient] = [
            .none,
            .init(isListening: true),
            .init(isThinking: true),
            .init(batteryCritical: true),
            .init(meetingSoon: true),
            .init(isOffline: true),
        ]
        let faces = states.map { resolve(.idle, $0) }
        // **This counts what `resolve` can return, NOT what a user can see, and
        // the difference matters.** `CompactIsland.leading` intercepts two of
        // these before a bloub is ever drawn: `meetingSoon` becomes a calendar
        // glyph and media becomes album art, so the orange meeting face below is
        // unreachable in the shipped ladder. Asserting five here and telling the
        // owner a non-agent user "gets five distinct states" was wrong for that
        // reason — this test never goes through the ladder.
        //
        // It is kept because the resolver's own coverage is still worth pinning.
        // What it does not prove is reachability.
        XCTAssertEqual(Set(faces.map(\.tint)).count, 5,
                       "the agent-free audience must get a range, not one grey")
        // Three, not four. Rest is `.attentive` by decision, so expression no
        // longer separates rest from an idle session — colour does. What
        // expression still has to do is mark the states that are NOT ordinary,
        // and there are three of those.
        XCTAssertGreaterThanOrEqual(Set(faces.map(\.expression)).count, 3)
        XCTAssertFalse(faces.allSatisfy(\.isDimmed), "some of them have to be able to shout")
    }

    /// Voice is the channel that means something to both audiences, so it takes
    /// its own colour rather than borrowing the one that means "an agent runs".
    func testAirlockWorkingIsNotTheSameColourAsAnAgentWorking() {
        XCTAssertEqual(resolve(.idle, .init(isListening: true)).tint, .assistant)
        XCTAssertEqual(resolve(.idle, .init(isThinking: true)).tint, .assistant)
        XCTAssertEqual(resolve(.agentLamp(attention: false, working: true)).tint, .working)
    }

    /// A key physically held outranks an agent: it is the gesture happening now,
    /// and it is the rung the non-agent audience actually reaches.
    func testAHeldKeyOutranksAWorkingAgent() {
        let face = resolve(.agentLamp(attention: true, working: true),
                           .init(isListening: true))
        XCTAssertEqual(face.tint, .assistant)
    }

    /// Working and idle-with-sessions used to differ ONLY by blink rate, once
    /// dimming stopped carrying it — a distinction you had to watch for seconds
    /// to see. The expression channel carries it now, and it has to keep doing
    /// so: two channels or it is not a signal.
    func testWorkingIsDistinctFromIdleByMoreThanBlinkRate() {
        let idle = resolve(.agentLamp(attention: false, working: false))
        let busy = resolve(.agentLamp(attention: false, working: true))
        XCTAssertNotEqual(idle.expression, busy.expression)
        XCTAssertNotEqual(idle.motion, busy.motion)
        XCTAssertEqual(idle.tint, busy.tint, "the colour is the brand, not the state")
    }

    /// THE requirement behind the neutral/sleepy choice: somebody who never
    /// starts an agent sits at rest nearly all the time, so a sleeping face
    /// there is their whole impression of the product. It says the app is off
    /// while the clipboard, the shelf and voice are all live.
    func testTheRestingFaceIsNeverAsleep() {
        let resting: [Face] = [
            resolve(.idle),
            resolve(.idle, .init(isOffline: true)),
            resolve(.agentLamp(attention: false, working: false)),
        ]
        for face in resting {
            XCTAssertNotEqual(face.expression, .sleepy)
            XCTAssertNotEqual(face.expression, .neutral, "neutral's eyes slant away — bored, not calm")
        }
    }

    // MARK: - Rest stays quiet

    /// **Rest is no longer dim, and that is a reversal.** The dim existed
    /// because "a solid tinted cloud at full strength is what made a notch with
    /// nothing happening look busy" — a real regression, on record.
    ///
    /// It was overturned once the cost became visible: rest is now the brand
    /// blue, and blue at 0.6 over black multiplies to #235890, a navy in no
    /// palette. Dimming an accent does not quieten it, it recolours it. The
    /// quietness rest still needs is carried by MOTION — breathing at 6.5s
    /// against working's 2.97s — which is a channel that survives being turned
    /// down.
    ///
    /// Offline stays dim because it stays grey, and grey survives a multiply.
    func testOnlyTheGreyStateIsDimmed() {
        XCTAssertFalse(resolve(.idle).isDimmed, "the mark is the mark")
        XCTAssertTrue(resolve(.idle, .init(isOffline: true)).isDimmed,
                      "offline is true rather than urgent — it must not shout")
        XCTAssertFalse(resolve(.idle, .init(batteryCritical: true)).isDimmed)
        XCTAssertFalse(resolve(.idle, .init(isListening: true)).isDimmed)
    }

    /// THE regression, reported off the notch: the resting agent lamp drew the
    /// brand blue at 0.6, which over black composites to #235890 — a navy that
    /// is in no palette and does not match the app icon two inches away. The old
    /// lamp survived it only because its blue was light enough to take a
    /// multiply. Dimming is for the body colour; an accent is the mark.
    func testAnAccentIsNeverDimmed() {
        let cases: [(CompactSlot, Face.Ambient)] = [
            (.agentLamp(attention: false, working: false), .none),
            (.agentLamp(attention: false, working: true), .none),
            (.agentLamp(attention: true, working: false), .none),
            (.completionTick, .none),
            (.idle, .init(isListening: true)),
            (.idle, .init(batteryCritical: true)),
            (.idle, .init(meetingSoon: true)),
        ]
        for (slot, ambient) in cases {
            let face = resolve(slot, ambient)
            XCTAssertNotEqual(face.tint, .body, "these are accent states")
            XCTAssertFalse(face.isDimmed, "\(slot) dims an accent into a colour nobody chose")
        }
    }

    /// And the other half: what IS dimmed is only ever the near-white body or
    /// the grey, both of which survive a multiply as themselves.
    func testOnlyTheQuietTintsAreDimmed() {
        for face in [resolve(.idle), resolve(.idle, .init(isOffline: true))] where face.isDimmed {
            XCTAssertTrue([.body, .resting].contains(face.tint))
        }
    }

    /// Motion has to stay a signal now that the resting island moves too. If
    /// rest and work blinked at the same rate the channel would say nothing.
    func testRestBreathesSlowerThanWorkBlinks() throws {
        let rest = try XCTUnwrap(resolve(.idle).motion.interval)
        let work = try XCTUnwrap(
            resolve(.agentLamp(attention: false, working: true)).motion.interval)
        XCTAssertGreaterThan(rest, work * 2,
                             "a resting blink that reads as working spends the channel")
    }

    /// **Rest IS an accent now — the brand blue — and this test used to forbid
    /// exactly that.**
    ///
    /// The reason it changed is the audience. `CompactIsland.leading` gates the
    /// two agent rungs behind `showsAgents`, so somebody who declines agents in
    /// onboarding can never reach blue or green at all: their mark was the
    /// resting one essentially always, and the resting one was a near-white
    /// dimmed to #918F8C. They pay the same €35 to look at a grey smudge that
    /// only gains colour when something is wrong.
    ///
    /// What must still never happen is rest reading as an ALARM. Blue is the
    /// product's own colour, not a warning; amber, red and green stay earned.
    func testRestIsTheBrandColourAndNeverAnAlarm() {
        XCTAssertEqual(resolve(.idle).tint, .working)
        for tint in [resolve(.idle).tint, resolve(.idle, .init(isOffline: true)).tint] {
            XCTAssertFalse([.attention, .error, .done].contains(tint),
                           "rest must not borrow a colour that means act now")
        }
    }

    // MARK: - The agent rungs still work

    func testAgentStatesKeepTheirColours() {
        XCTAssertEqual(resolve(.agentLamp(attention: true, working: false)).tint, .attention)
        XCTAssertEqual(resolve(.agentLamp(attention: false, working: true)).tint, .working)
        XCTAssertEqual(resolve(.completionTick).tint, .done)
        XCTAssertEqual(resolve(.completionTick).expression, .happy)
    }

    /// `scared` earns a job that is NOT the approval gate — the recorded rule
    /// that a character must not mug at somebody mid-decision stays intact.
    func testScaredIsForTheMachineNotTheGate() {
        XCTAssertEqual(resolve(.idle, .init(batteryCritical: true)).expression, .scared)
        XCTAssertNotEqual(resolve(.agentLamp(attention: true, working: false)).expression, .scared)
    }

    /// Ordered by what wants a decision now: a Mac about to die outranks a
    /// meeting, which outranks a network that is merely absent.
    func testUrgencyOrdering() {
        let all = Face.Ambient(isListening: false, isThinking: false,
                               batteryCritical: true, meetingSoon: true, isOffline: true)
        XCTAssertEqual(resolve(.idle, all).tint, .error)
        var noBattery = all; noBattery.batteryCritical = false
        XCTAssertEqual(resolve(.idle, noBattery).tint, .attention)
    }
}
