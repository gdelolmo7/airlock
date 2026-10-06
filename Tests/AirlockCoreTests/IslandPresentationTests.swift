import XCTest
@testable import AirlockCore

final class IslandPresentationTests: XCTestCase {
    private typealias Holds = IslandPresentation.Holds

    /// Every hold there is, written ONCE. Four separate hand-written lists is
    /// how a newly added hold gets asserted about in one test and forgotten in
    /// the other three — which is the same failure the option set itself exists
    /// to prevent at the call site.
    private static let each: [Holds] = [.pinned, .peeked, .hotkey, .dictating,
                                        .answering, .scrubbing, .onboarding, .guiding]
    private static let every: Holds = each.reduce(into: Holds()) { $0.formUnion($1) }

    private func resolve(screen: Bool = true,
                         holds: Holds = [],
                         content: Bool = false) -> IslandPresentation {
        IslandPresentation.resolve(hasTargetScreen: screen, holds: holds, hasContent: content)
    }

    // MARK: - The contract

    /// THE user-set rule: the island expands on its own ONLY when a person did
    /// something or something is waiting on them. Content is never enough.
    ///
    /// It matters because the notch is where the pointer crosses on its way to
    /// the menu bar. An island that opened for a finished build or a new track
    /// would be in the way, at the top of the screen, permanently.
    func testContentAloneNeverExpands() {
        XCTAssertEqual(resolve(content: true), .compact,
                       "a running session, music, an approaching meeting — all compact")
    }

    func testEveryHoldExpandsOnItsOwn() {
        for hold in Self.each {
            XCTAssertEqual(resolve(holds: hold), .expanded, "\(hold.rawValue)")
            XCTAssertEqual(resolve(holds: hold, content: true), .expanded)
        }
    }

    func testHoldsCombine() {
        XCTAssertEqual(resolve(holds: [.pinned, .peeked, .answering]), .expanded)
    }

    /// The status-menu toggle has to open an empty panel, or a user who has
    /// switched every widget off has no route back to settings.
    func testAHoldExpandsEvenWithNothingToShow() {
        XCTAssertEqual(resolve(holds: .pinned, content: false), .expanded)
    }

    // MARK: - Nothing happening

    /// It used to hide. It rests instead — `CompactSlot.idle` gives the ladder
    /// something to draw, and a surface that vanishes when it has nothing to
    /// say was reported as a crash four times.
    func testNothingHeldAndNothingToShowRests() {
        XCTAssertEqual(resolve(), .compact)
    }

    func testReleasingTheLastHoldFallsBackToContent() {
        XCTAssertEqual(resolve(holds: .peeked, content: true), .expanded)
        XCTAssertEqual(resolve(holds: [], content: true), .compact)
    }

    func testReleasingTheLastHoldWithNoContentRests() {
        XCTAssertEqual(resolve(holds: .hotkey, content: false), .expanded)
        XCTAssertEqual(resolve(holds: [], content: false), .compact)
    }

    // MARK: - Nowhere to draw

    /// Lid shut, no notched screen, external fallback off. This outranks
    /// everything — including a gate, which has nowhere to appear.
    func testNoScreenBeatsEverything() {
        XCTAssertEqual(resolve(screen: false), .hidden)
        XCTAssertEqual(resolve(screen: false, content: true), .hidden)
        for hold in Self.each {
            XCTAssertEqual(resolve(screen: false, holds: hold, content: true), .hidden)
        }
    }

    // MARK: - Shape

    /// Any hold at all is enough. Spelled as a set precisely because naming
    /// them one by one at the call site is how one gets left out of a condition.
    func testAnyHoldIsEnoughHoweverManyThereAre() {
        for hold in Self.each {
            XCTAssertEqual(resolve(holds: Self.every.subtracting(hold)), .expanded,
                           "dropping one leaves the rest, still expanded")
        }
        XCTAssertEqual(resolve(holds: Self.every.subtracting(Self.every)), .compact,
                       "no holds is the resting island, not nothing")
    }
}

/// The island rests rather than disappearing.
///
/// Reported four times as a crash — "the notch closed", "it wasn't there, as if
/// the app had quit" — and the sharpest version was self-inflicted: "pause the
/// music" removed the artwork that was the island's only content, so a command
/// that worked perfectly made the notch vanish and the vanishing read as the
/// failure.
final class IslandRestingStateTests: XCTestCase {

    private func resolve(holds: IslandPresentation.Holds = [],
                         content: Bool = false) -> IslandPresentation {
        IslandPresentation.resolve(hasTargetScreen: true, holds: holds, hasContent: content)
    }

    func testItRestsWithNothingToSay() {
        XCTAssertEqual(resolve(), .compact)
    }

    /// `hasContent` no longer decides whether the island EXISTS — only what its
    /// slots draw. Both answers resolve the same way.
    func testContentNoLongerDecidesExistence() {
        XCTAssertEqual(resolve(content: true), .compact)
        XCTAssertEqual(resolve(content: false), .compact)
    }

    /// Everything above the resting rung is untouched.
    func testHoldsAndTheMissingScreenStillOutrankIt() {
        XCTAssertEqual(resolve(holds: [.pinned]), .expanded)
        XCTAssertEqual(
            IslandPresentation.resolve(hasTargetScreen: false, holds: [.pinned], hasContent: true),
            .hidden, "nowhere to draw still outranks everything")
    }

    /// The one remaining route to `.hidden` wherever the island may rest — over
    /// a camera housing, always. Worth pinning, because there it is the ONLY
    /// one and a regression here would be invisible. A monitor whose menu bar
    /// is hidden is the exception, with its own rule: `IslandWithoutAStripTests`.
    func testTheOnlyWayToHideIsHavingNoScreen() {
        for holds: IslandPresentation.Holds in [[], [.pinned], [.peeked, .hotkey]] {
            for content in [true, false] {
                XCTAssertEqual(
                    IslandPresentation.resolve(hasTargetScreen: false, holds: holds,
                                               hasContent: content),
                    .hidden)
            }
        }
    }
}

/// Any display while its menu bar is hidden — a full-screen app in front, or
/// auto-hide. Monitors first; the notch joined them on 2026-10-04. The island may not REST there, because resting
/// would cover somebody's window (`VirtualCutout.canRest`). This is the case
/// `lastShown` and the linger were kept for.
final class IslandWithoutAStripTests: XCTestCase {
    private typealias Holds = IslandPresentation.Holds
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func resolve(holds: Holds = [], content: Bool = false, awaiting: Bool = false,
                         lastShown: Date? = nil, now: Date? = nil) -> IslandPresentation {
        IslandPresentation.resolve(hasTargetScreen: true, canRest: false, holds: holds,
                                   hasContent: content, awaitingOwner: awaiting,
                                   lastShown: lastShown, now: now ?? t0)
    }

    /// Anything that needs the owner still opens the panel: every hold expands
    /// exactly as it does over the notch.
    func testEveryHoldStillExpands() {
        for hold: Holds in [.pinned, .peeked, .hotkey, .dictating, .answering, .scrubbing, .onboarding, .guiding] {
            XCTAssertEqual(resolve(holds: hold), .expanded, "\(hold.rawValue)")
        }
    }

    /// Nothing held, nothing waiting, nothing to linger from: hidden.
    func testWithNothingItRestsHidden() {
        XCTAssertEqual(resolve(), .hidden)
    }

    /// Content is NOT a reason. Agent sessions run all day, so "content keeps
    /// it up" would mean "always up", over every full-screen window.
    func testContentAloneDoesNotBringItUp() {
        XCTAssertEqual(resolve(content: true), .hidden)
    }

    /// A gate or question nobody has answered keeps the island compact after
    /// its panel is collapsed — the amber dot is then the only sign on screen
    /// that an agent is blocked.
    func testSomethingAwaitingTheOwnerKeepsItCompact() {
        XCTAssertEqual(resolve(awaiting: true), .compact)
        XCTAssertEqual(resolve(holds: .pinned, awaiting: true), .expanded, "a hold still outranks it")
    }

    /// A panel that closes lands on the island and fades, rather than blinking
    /// out — for `linger`, and not one instant longer.
    func testItLingersAfterItsLastReasonThenHides() {
        let linger = IslandPresentation.linger
        XCTAssertEqual(resolve(lastShown: t0, now: t0), .compact)
        XCTAssertEqual(resolve(lastShown: t0, now: t0.addingTimeInterval(linger - 0.01)), .compact)
        XCTAssertEqual(resolve(lastShown: t0, now: t0.addingTimeInterval(linger)), .hidden,
                       "gone exactly at the deadline — the instant `lingerDeadline` wakes at")
        XCTAssertEqual(resolve(lastShown: t0, now: t0.addingTimeInterval(60)), .hidden)
    }

    /// The pointer at the top edge brings it back compact, like the menu bar —
    /// and never further: resting on it is what opens it.
    func testThePointerAtTheTopBringsItUpCompactOnly() {
        XCTAssertEqual(IslandPresentation.resolve(hasTargetScreen: true, canRest: false, holds: [],
                                                  hasContent: true, pointerAtTop: true, now: t0),
                       .compact)
        XCTAssertEqual(IslandPresentation.resolve(hasTargetScreen: true, canRest: false, holds: .peeked,
                                                  hasContent: true, pointerAtTop: true, now: t0),
                       .expanded, "a hold still outranks it")
    }

    /// It is not a reason the linger counts from: the island goes when the
    /// pointer goes, as the menu bar does.
    func testThePointerLeavingDoesNotLinger() {
        var shown = IslandPresentation.LastShown()
        shown.record(holds: [], awaitingOwner: false, now: t0)
        XCTAssertEqual(resolve(lastShown: shown.date, now: t0.addingTimeInterval(0.1)), .hidden)
    }

    func testNoScreenStillBeatsEverything() {
        XCTAssertEqual(IslandPresentation.resolve(hasTargetScreen: false, canRest: false, holds: .pinned,
                                                  hasContent: true, awaitingOwner: true,
                                                  lastShown: t0, now: t0),
                       .hidden)
    }

    /// The notch never reads any of this. `canRest` defaults to true, which is
    /// what every other caller gets, and there the island rests whatever the
    /// linger says.
    func testWhereItMayRestNothingHereApplies() {
        XCTAssertEqual(IslandPresentation.resolve(hasTargetScreen: true, holds: [], hasContent: false),
                       .compact)
        XCTAssertEqual(IslandPresentation.resolve(hasTargetScreen: true, canRest: true, holds: [],
                                                  hasContent: false, awaitingOwner: false,
                                                  lastShown: t0, now: t0.addingTimeInterval(3600)),
                       .compact)
    }

    // MARK: - The wake

    func testTheLingerWakesExactlyWhenResolveTurnsHidden() {
        let deadline = IslandPresentation.lingerDeadline(canRest: false, holds: [], awaitingOwner: false,
                                                         lastShown: t0)
        XCTAssertEqual(deadline, t0.addingTimeInterval(IslandPresentation.linger))
        guard let deadline else { return }
        XCTAssertEqual(resolve(lastShown: t0, now: deadline.addingTimeInterval(-0.001)), .compact)
        XCTAssertEqual(resolve(lastShown: t0, now: deadline), .hidden)
    }

    func testNothingToWakeForWhileItMayRestOrStillHasAReason() {
        XCTAssertNil(IslandPresentation.lingerDeadline(canRest: true, holds: [], awaitingOwner: false,
                                                       lastShown: t0),
                     "a menu bar to rest in: nothing lingers")
        XCTAssertNil(IslandPresentation.lingerDeadline(canRest: false, holds: .pinned, awaitingOwner: false,
                                                       lastShown: t0))
        XCTAssertNil(IslandPresentation.lingerDeadline(canRest: false, holds: [], awaitingOwner: true,
                                                       lastShown: t0))
        XCTAssertNil(IslandPresentation.lingerDeadline(canRest: false, holds: [], awaitingOwner: false,
                                                       lastShown: nil),
                     "never up, nothing to linger from")
    }

    // MARK: - When the linger counts from

    /// THE EDGE. `apply` runs on events, so a panel pinned and read in silence
    /// for a minute is seen held at T0 and released at T60 with nothing in
    /// between. The linger has to count from the release, or it is over before
    /// it begins and the panel closes to nothing.
    func testTheReleaseIsStampedNotTheLastPassThatSawTheHold() {
        var last = IslandPresentation.LastShown()
        last.record(holds: .pinned, awaitingOwner: false, now: t0)
        XCTAssertEqual(last.date, t0)

        let release = t0.addingTimeInterval(60)
        last.record(holds: [], awaitingOwner: false, now: release)
        XCTAssertEqual(last.date, release)
        XCTAssertEqual(resolve(lastShown: last.date, now: release.addingTimeInterval(1)), .compact,
                       "a second after closing, still on the island")
    }

    /// Only the release: passes after it must not re-stamp, or a stream of
    /// unrelated events would keep the linger from ever running out.
    func testPassesAfterTheReleaseDoNotExtendIt() {
        var last = IslandPresentation.LastShown()
        last.record(holds: .pinned, awaitingOwner: false, now: t0)
        for second in 1...3 {
            last.record(holds: [], awaitingOwner: false, now: t0.addingTimeInterval(TimeInterval(second)))
        }
        XCTAssertEqual(last.date, t0.addingTimeInterval(1))
    }

    /// A peek is the pointer resting on the island: when the pointer leaves,
    /// the island goes with it, as the top edge does.
    func testAPeekIsNotAReasonToLinger() {
        var last = IslandPresentation.LastShown()
        last.record(holds: .peeked, awaitingOwner: false, now: t0)
        last.record(holds: [], awaitingOwner: false, now: t0.addingTimeInterval(2))
        XCTAssertNil(last.date)
        XCTAssertEqual(resolve(lastShown: last.date, now: t0.addingTimeInterval(2.1)), .hidden)

        last.record(holds: [.peeked, .hotkey], awaitingOwner: false, now: t0.addingTimeInterval(3))
        XCTAssertEqual(last.date, t0.addingTimeInterval(3), "another hold beside it still counts")
    }

    /// Something awaiting the owner is a reason like a hold, so answering it is
    /// a release and the island lingers from there.
    func testAnsweringIsAReleaseToo() {
        var last = IslandPresentation.LastShown()
        last.record(holds: [], awaitingOwner: true, now: t0)
        let answered = t0.addingTimeInterval(30)
        last.record(holds: [], awaitingOwner: false, now: answered)
        XCTAssertEqual(last.date, answered)
    }

    /// Nothing that is not a reason ever stamps — content cannot even be
    /// passed — so a launch with nothing held has nothing to linger from.
    func testNoReasonNoStamp() {
        var last = IslandPresentation.LastShown()
        last.record(holds: [], awaitingOwner: false, now: t0)
        last.record(holds: [], awaitingOwner: false, now: t0.addingTimeInterval(5))
        XCTAssertNil(last.date)
    }
}
