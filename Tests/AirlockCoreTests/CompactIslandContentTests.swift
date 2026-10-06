import XCTest
@testable import AirlockCore

/// Whether the island is on screen at all — `IslandPresentation.resolve`'s
/// `hasContent`, which the controller used to compute by hand beside the slots.
///
/// Two copies of that reasoning is how the trailing slot's comment came to
/// disagree with its own code, and a claimant the slots know about but
/// `hasContent` does not is simply invisible. So the two live together, and this
/// file is the record of what that cost and what it deliberately did not change.
final class CompactIslandContentTests: XCTestCase {
    private static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func input(_ build: (inout CompactIslandInput) -> Void) -> CompactIslandInput {
        var i = CompactIslandInput(now: Self.anchor)
        build(&i)
        return i
    }

    /// The expression `NotchController.apply()` computed by hand, transcribed.
    /// The toggle reads it folded in are already folded at the construction site
    /// — a disabled media or calendar widget nils its own state — so over a
    /// `CompactIslandInput` it is exactly this.
    private func legacyHasContent(_ i: CompactIslandInput) -> Bool {
        let ambient = i.hasMedia || i.meetingSoon
        let agent = (i.agentsEnabled && i.sessionCount > 0) || i.attentionCount > 0
        return ambient || agent
    }

    // MARK: - It does not change what was already on screen

    /// The one edit in this cluster that could move EXISTING behaviour, pinned
    /// before the hand-written expression was deleted: across the whole input
    /// space that existed before, the function agrees with the expression it
    /// replaces. The single deliberate divergence has its own test below and is
    /// excluded here by name.
    func testItAgreesWithTheExpressionItReplaces() {
        sweepLegacyInputs { name, i in
            guard !(i.completionTick && i.showsAgents && i.sessionCount == 0
                    && i.attentionCount == 0) else { return }
            XCTAssertEqual(CompactIsland.hasContent(i), legacyHasContent(i), name)
        }
    }

    /// THE divergence, and it is a fix rather than a regression: a ✓ pulsing for
    /// a session that vanished inside its own three seconds used to take the
    /// island away mid-pulse, which is a completion signal that is not seen.
    /// Compact only — the tick has never been a reason to expand.
    func testACompletionTickAloneKeepsTheIslandUp() {
        let i = input { $0.agentsEnabled = true; $0.completionTick = true; $0.sessionCount = 0 }
        XCTAssertTrue(CompactIsland.hasContent(i))
        XCTAssertFalse(legacyHasContent(i), "the old expression dropped it")
        XCTAssertEqual(
            IslandPresentation.resolve(hasTargetScreen: true, holds: [],
                                       hasContent: CompactIsland.hasContent(i)),
            .compact)
    }

    // MARK: - Sessions summon through the lamp

    /// **Taking the session count off the closed island (2026-09-30) did not
    /// change when the island comes up.** The count was never what summoned it:
    /// every input that drew the count also lit the lamp or the ✓ opposite, and
    /// `hasContent` reads that side first. Pinned across the whole legacy space,
    /// so that "summoning must not change" is a checked fact rather than an
    /// argument in a comment.
    func testOpenSessionsStillSummonTheIslandThroughTheLamp() {
        sweepLegacyInputs { name, i in
            guard i.showsAgents, i.sessionCount > 0 else { return }
            switch CompactIsland.leading(i) {
            case .agentLamp, .completionTick: break
            case let other: XCTFail("\(name): sessions shown, but the leading side is \(other)")
            }
            XCTAssertTrue(CompactIsland.hasContent(i), name)
        }
    }

    /// The same fact at the three places it could have gone wrong.
    func testTheCasesThatCouldHaveLeanedOnTheCount() {
        // Agents on, one session, nothing else: summoned by the lamp alone, with
        // the trailing side left empty rather than holding a "1".
        let alone = input { $0.agentsEnabled = true; $0.sessionCount = 1 }
        XCTAssertTrue(CompactIsland.hasContent(alone))
        XCTAssertEqual(CompactIsland.trailing(alone), .empty)

        // Agents switched off, sessions open, no gate: not summoned, as before —
        // the count was never drawn here, so there was nothing to lose.
        let hidden = input { $0.agentsEnabled = false; $0.sessionCount = 3 }
        XCTAssertFalse(CompactIsland.hasContent(hidden))

        // A gate while agents are off: summoned, by the amber lamp and dot.
        let gate = input { $0.agentsEnabled = false; $0.attentionCount = 1; $0.sessionCount = 1 }
        XCTAssertTrue(CompactIsland.hasContent(gate))
        XCTAssertEqual(CompactIsland.leading(gate), .agentLamp(attention: true, working: false))
        XCTAssertEqual(CompactIsland.trailing(gate), .attentionDot)
    }

    // MARK: - Drivers

    /// A dying battery with nothing else happening has to be able to summon the
    /// island, or the slot it claims is never rendered.
    func testACriticalBatteryIsADriver() {
        XCTAssertTrue(CompactIsland.hasContent(input { $0.batteryCritical = true }))
    }

    /// Switching to AirPods with nothing else on screen flashes the island
    /// compact and it goes away by itself — the shrink back is what `resolve`
    /// already does when content lapses.
    func testTheRouteAckIsADriverForExactlyItsWindow() {
        let t = Self.anchor
        let lit = input { $0.outputChangedAt = t; $0.outputDeviceName = "AirPods Pro" }
        XCTAssertTrue(CompactIsland.hasContent(lit))
        let over = input {
            $0.outputChangedAt = t.addingTimeInterval(-CompactIsland.routeAcknowledgement)
            $0.outputDeviceName = "AirPods Pro"
        }
        XCTAssertFalse(CompactIsland.hasContent(over))
    }

    /// Neither driver is ever a reason to EXPAND. That rule is
    /// `IslandPresentation`'s and this is the join with it: content, whatever
    /// kind, resolves compact.
    func testNoNewDriverCanExpandTheIsland() {
        let t = Self.anchor
        for i in [input { $0.batteryCritical = true },
                  input { $0.outputChangedAt = t },
                  input { $0.hasMedia = true }] {
            XCTAssertEqual(
                IslandPresentation.resolve(hasTargetScreen: true, holds: [],
                                           hasContent: CompactIsland.hasContent(i)),
                .compact)
        }
    }

    /// A track paused this morning must stop holding the island up, or what is
    /// on screen is two empty slots.
    func testRetiredMediaStopsBeingADriver() {
        let t = Self.anchor
        XCTAssertTrue(CompactIsland.hasContent(input {
            $0.hasMedia = true; $0.mediaPausedAt = t.addingTimeInterval(-60)
        }))
        XCTAssertFalse(CompactIsland.hasContent(input {
            $0.hasMedia = true; $0.mediaPausedAt = t.addingTimeInterval(-3600)
        }))
    }

    // MARK: - Passengers

    /// **The shelf count must never summon the island.** A shelf holding two
    /// files for a fortnight would otherwise pin a glyph over the menu bar for a
    /// fortnight — permanent chrome nobody asked for and which cannot be
    /// dismissed without emptying a folder. The natural one-liner
    /// (`trailing != .empty`) does exactly that, which is why this test exists
    /// with this comment on it: do not simplify the exclusion away.
    func testTheShelfCountNeverSummonsTheIsland() {
        for count in [1, 3, 40] {
            let i = input { $0.shelfCount = count }
            XCTAssertEqual(CompactIsland.trailing(i), .shelfCount(count))
            XCTAssertFalse(CompactIsland.hasContent(i), "\(count) files summoned the island")
        }
    }

    /// ...but it does fill a slot that something else already opened.
    func testTheShelfCountRidesAlongOnceSomethingElseIsThere() {
        let i = input { $0.shelfCount = 2; $0.hasMedia = true }
        XCTAssertTrue(CompactIsland.hasContent(i))
        XCTAssertEqual(CompactIsland.leading(i), .artwork)
        XCTAssertEqual(CompactIsland.trailing(i), .shelfCount(2))
    }

    /// **Keep-awake is a passenger too, for the shelf's reason at a different
    /// scale.** An assertion held from morning to night would otherwise be
    /// enough, on its own, to hold the island up from morning to night. Two
    /// passengers together are still no driver: the cup outranking the shelf
    /// decides the slot, never whether the island is summoned.
    func testKeepAwakeNeverSummonsTheIsland() {
        let alone = input { $0.keepingAwake = true }
        XCTAssertEqual(CompactIsland.trailing(alone), .keepingAwake)
        XCTAssertFalse(CompactIsland.hasContent(alone), "the cup summoned the island")

        let withTheShelf = input { $0.keepingAwake = true; $0.shelfCount = 3 }
        XCTAssertEqual(CompactIsland.trailing(withTheShelf), .keepingAwake)
        XCTAssertFalse(CompactIsland.hasContent(withTheShelf), "two passengers made a driver")
    }

    /// ...and like the shelf it fills a slot something else opened.
    func testKeepAwakeRidesAlongOnceSomethingElseIsThere() {
        let i = input { $0.keepingAwake = true; $0.hasMedia = true }
        XCTAssertTrue(CompactIsland.hasContent(i))
        XCTAssertEqual(CompactIsland.leading(i), .artwork)
        XCTAssertEqual(CompactIsland.trailing(i), .keepingAwake)
    }

    /// The presentation rule's side of the same fact: the cup never expands
    /// the island, and where the island may not rest it does not bring it up
    /// either — a passenger has no reason of its own to be on screen.
    func testKeepAwakeNeverExpandsTheIsland() {
        let cup = CompactIsland.hasContent(input { $0.keepingAwake = true })
        XCTAssertEqual(IslandPresentation.resolve(hasTargetScreen: true, holds: [], hasContent: cup),
                       .compact)
        XCTAssertEqual(IslandPresentation.resolve(hasTargetScreen: true, canRest: false,
                                                  holds: [], hasContent: cup),
                       .hidden)
    }

    func testNothingAtAllIsNoContent() {
        XCTAssertFalse(CompactIsland.hasContent(CompactIslandInput(now: Self.anchor)))
    }

    // MARK: - The legacy sweep

    private typealias Variant = (name: String, apply: (inout CompactIslandInput) -> Void)

    /// Only the axes that existed before this change, and no new field touched:
    /// the question is whether the replacement moved anything that was already
    /// on screen.
    private func sweepLegacyInputs(_ body: (String, CompactIslandInput) -> Void) {
        let axes: [[Variant]] = [
            [("agents off", { $0.agentsEnabled = false }), ("agents on", { $0.agentsEnabled = true })],
            [("no gate", { _ in }), ("gate", { $0.attentionCount = 1 })],
            [("0 sessions", { _ in }), ("1 session", { $0.sessionCount = 1 }),
             ("3 sessions", { $0.sessionCount = 3 })],
            [("no tick", { _ in }), ("tick", { $0.completionTick = true })],
            [("no media", { _ in }), ("paused", { $0.hasMedia = true }),
             ("playing", { $0.hasMedia = true; $0.mediaPlaying = true })],
            [("no meeting", { _ in }), ("meeting", { $0.meetingSoon = true })],
        ]
        func walk(_ remaining: ArraySlice<[Variant]>, _ name: String, _ i: CompactIslandInput) {
            guard let axis = remaining.first else { return body(name, i) }
            for variant in axis {
                var next = i
                variant.apply(&next)
                walk(remaining.dropFirst(), name.isEmpty ? variant.name : "\(name), \(variant.name)", next)
            }
        }
        walk(axes[...], "", CompactIslandInput(now: Self.anchor))
    }
}
